import Foundation
import AVFoundation
import Accelerate
import CWhisper

/// Whisper.cpp transcription engine for Al.
///
/// **Model.** Bundled GGML file (ggml-large-v3-turbo-q5_0). Same model
/// resolution logic as LiveTranslate's WhisperCppTranscriber.
///
/// **Pipeline.**
///   1. Audio buffers arrive 48 kHz mono Float32.
///   2. Downsampled to 16 kHz mono for whisper (via AVAudioConverter).
///   3. A two-state RMS VAD (MONITORING → ACTIVE) opens chunks only after
///      0.1 s of consecutive voiced audio; chunks close on 2 s of silence
///      or 30 s max. The 0.1 s onset buffer is prepended to the chunk so
///      the triggering audio is not lost.
///   4. A separate worker task drains a bounded chunk queue and runs
///      whisper_full() serially so the accumulator is never stalled.
///   5. Each closed chunk produces one Utterance — whisper's segments
///      joined, trimmed, and stamped with wall-clock onset time.
final class WhisperEngine {

    // MARK: - Constants

    static let bundledModelName: String = "ggml-large-v3-turbo-q5_0"

    private let voiceThreshold: Float = 0.01
    private let minVoicedSeconds: Double = 0.1   // minimum voiced content before running whisper
    private let onsetSeconds: Double = 0.1
    private let endChunkAfterSilence: Double = 1.0
    private let maxChunkSeconds: Double = 10.0
    private let minWhisperInputSeconds: Double = 1.1
    private let voicePaddingSeconds: Double = 0.1
    private let previousChunkTailMaxChars: Int = 120
    private let maxPendingChunks: Int = 4

    // Derived constants at 16 kHz
    private var onsetSamples16k: Int { Int(onsetSeconds * 16_000) }
    private var endChunkSilenceSamples16k: Int { Int(endChunkAfterSilence * 16_000) }
    private var maxChunkSamples16k: Int { Int(maxChunkSeconds * 16_000) }
    private var minChunkSamples16k: Int { Int(minWhisperInputSeconds * 16_000) }
    private var minVoicedSamples16k: Int { Int(minVoicedSeconds * 16_000) }
    private var voicePaddingSamples16k: Int { Int(voicePaddingSeconds * 16_000) }

    // MARK: - Shared whisper context

    private var ctx: OpaquePointer?
    private var modelLoadError: Error?
    private let ctxInitLock = NSLock()
    private let ctxLock = NSLock()

    // MARK: - Pending chunk counter (reference type for safe cross-closure sharing)

    private final class PendingCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock(); value += 1; lock.unlock()
        }

        /// Decrement and return true if the caller should SKIP processing
        /// (backlog exceeded max before decrement).
        func decrementAndShouldSkip(max: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let overLimit = value > max
            if value > 0 { value -= 1 }
            return overLimit
        }
    }

    // MARK: - Crosstalk suppression
    // When the system stream carries voiced audio, mic samples are zeroed so
    // speaker bleed doesn't get transcribed as microphone speech.

    private var lastSystemVoicedAt: Date = .distantPast
    private let crosstalkLock = NSLock()
    private let crosstalkPersistSeconds: TimeInterval = 0.25

    private func markSystemVoiced() {
        let now = Date()
        crosstalkLock.lock(); lastSystemVoicedAt = now; crosstalkLock.unlock()
    }

    private func isCrosstalkActive() -> Bool {
        crosstalkLock.lock()
        defer { crosstalkLock.unlock() }
        return Date().timeIntervalSince(lastSystemVoicedAt) < crosstalkPersistSeconds
    }

    // MARK: - Per-source continuity

    private var previousChunkTail: [SourceTag: String] = [:]
    private let tailLock = NSLock()

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    // MARK: - Model lifecycle

    /// Load the whisper_context eagerly. Idempotent — safe to call concurrently.
    func preloadModel() throws {
        ctxInitLock.lock()
        defer { ctxInitLock.unlock() }
        if ctx != nil { return }
        if let err = modelLoadError { throw err }

        let modelURL = try resolveModelURL()
        Log.line("WhisperEngine: loading model at \(modelURL.path)")

        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = false

        guard let loaded = whisper_init_from_file_with_params(modelURL.path, params) else {
            let err = WhisperEngineError.modelLoadFailed("whisper_init_from_file_with_params failed for \(modelURL.path)")
            modelLoadError = err
            throw err
        }
        ctx = loaded
        Log.line("WhisperEngine: model loaded")
    }

    /// Free the whisper_context. Idempotent.
    func unloadModel() {
        ctxInitLock.lock()
        defer { ctxInitLock.unlock() }
        if let c = ctx {
            whisper_free(c)
            ctx = nil
            modelLoadError = nil
            Log.line("WhisperEngine: model unloaded")
        }
    }

    // MARK: - Transcribe

    /// Consume 48 kHz mono Float32 PCM buffers, apply VAD chunking, run
    /// whisper, and emit Utterance values. Returns when `audio` terminates
    /// and the final in-flight chunk (if any) has been processed.
    func transcribe(
        audio: AsyncStream<AVAudioPCMBuffer>,
        source: SourceTag
    ) -> AsyncStream<Utterance> {
        AsyncStream<Utterance> { continuation in
            Task {
                do {
                    let loadedCtx = try self.loadedContext()
                    Log.line("WhisperEngine.transcribe[\(source.rawValue)]: starting")
                    await self.runChunkLoop(ctx: loadedCtx, audio: audio, source: source, continuation: continuation)
                    Log.line("WhisperEngine.transcribe[\(source.rawValue)]: finished")
                    continuation.finish()
                } catch {
                    Log.line("WhisperEngine.transcribe[\(source.rawValue)]: error \(error.localizedDescription)")
                    continuation.finish()
                }
            }
        }
    }

    // MARK: - Internal: chunk loop

    private struct ChunkBuffer {
        let samples16k: [Float]
        /// Index of first voiced sample within samples16k; nil → pure silence
        let voiceStart: Int?
        /// Index one past last voiced sample within samples16k
        let voiceEnd: Int
        let voicedSampleCount: Int
        let firstVoicedWallClock: Date
        let closeReason: String
        let index: Int
    }

    private func runChunkLoop(
        ctx: OpaquePointer,
        audio: AsyncStream<AVAudioPCMBuffer>,
        source: SourceTag,
        continuation: AsyncStream<Utterance>.Continuation
    ) async {
        let (chunkQueue, queueSink) = AsyncStream<ChunkBuffer>.makeStream()
        let tag = source.rawValue

        // Pending chunk counter — guards against OOM when worker lags
        let counter = PendingCounter()
        let ctxRef = WhisperContextRef(ptr: ctx)

        async let accumulate: Void = {
            await self.accumulateChunks(
                audio: audio,
                sink: queueSink,
                source: source,
                counter: counter
            )
            Log.line("accumulator[\(tag)]: done, closing queue")
            queueSink.finish()
        }()

        async let process: Void = {
            Log.line("worker[\(tag)]: started")
            for await chunk in chunkQueue {
                if counter.decrementAndShouldSkip(max: self.maxPendingChunks) {
                    Log.line("worker[\(tag)]: dropping chunk #\(chunk.index) — worker backpressure (pendingChunkCount exceeded \(self.maxPendingChunks))")
                    continue
                }
                if let utterance = await self.processChunk(ctx: ctxRef.ptr, chunk: chunk, source: source) {
                    continuation.yield(utterance)
                }
            }
            Log.line("worker[\(tag)]: queue closed, exiting")
        }()

        _ = await (accumulate, process)
    }

    private func accumulateChunks(
        audio: AsyncStream<AVAudioPCMBuffer>,
        sink: AsyncStream<ChunkBuffer>.Continuation,
        source: SourceTag,
        counter: PendingCounter
    ) async {
        let tag = source.rawValue
        let resampler = WhisperResampler()

        // VAD state machine
        enum VADState { case monitoring, active }
        var state: VADState = .monitoring

        // MONITORING state
        var preActivationBuffer: [Float] = []
        preActivationBuffer.reserveCapacity(onsetSamples16k)
        var consecutiveVoicedSamples: Int = 0
        var onsetStartWallClock: Date? = nil

        // ACTIVE state accumulators
        var chunkSamples: [Float] = []
        chunkSamples.reserveCapacity(maxChunkSamples16k)
        var silentSamples16k: Int = 0
        var totalSamples16k: Int = 0
        var voiceStart16k: Int? = nil        // local index in chunkSamples
        var voiceEnd16k: Int = 0             // local index (exclusive) in chunkSamples
        var voicedSampleCount: Int = 0
        var firstVoicedWallClock: Date = Date()
        var chunkIndex: Int = 0
        var bufferCount: Int = 0

        Log.line("accumulator[\(tag)]: started")

        for await buf in audio {
            if Task.isCancelled {
                Log.line("accumulator[\(tag)]: cancelled")
                return
            }
            bufferCount += 1

            guard var resampled = resampler.convert(buf), !resampled.isEmpty else { continue }

            // Compute RMS on the original 48 kHz buffer (same as LiveTranslate)
            guard let data = buf.floatChannelData?[0] else { continue }
            let n = Int(buf.frameLength)
            var ms: Float = 0
            vDSP_measqv(data, 1, &ms, vDSP_Length(n))
            let rms = sqrt(ms)
            var voiced = rms >= voiceThreshold

            let frameCount = resampled.count

            // Crosstalk suppression: zero mic samples during system audio activity
            if source == .mic && isCrosstalkActive() {
                resampled = [Float](repeating: 0, count: resampled.count)
                voiced = false
            }

            // System stream: stamp crosstalk timestamp on voiced frames
            if source == .system && voiced {
                markSystemVoiced()
            }

            switch state {
            case .monitoring:
                if voiced {
                    // Capture wall-clock at the first voiced frame of a new potential onset
                    if consecutiveVoicedSamples == 0 {
                        onsetStartWallClock = Date()
                    }
                    // Append to circular pre-activation buffer
                    preActivationBuffer.append(contentsOf: resampled)
                    // Keep only the last onsetSamples16k samples
                    if preActivationBuffer.count > onsetSamples16k {
                        let excess = preActivationBuffer.count - onsetSamples16k
                        preActivationBuffer.removeFirst(excess)
                    }
                    consecutiveVoicedSamples += frameCount

                    if consecutiveVoicedSamples >= onsetSamples16k {
                        // Transition to ACTIVE — prepend the pre-activation buffer
                        state = .active
                        firstVoicedWallClock = onsetStartWallClock ?? Date()

                        // The pre-activation buffer IS the start of the chunk
                        chunkSamples = preActivationBuffer
                        totalSamples16k = chunkSamples.count
                        // Voice covers the entire pre-activation region
                        voiceStart16k = 0
                        voiceEnd16k = chunkSamples.count
                        voicedSampleCount = chunkSamples.count
                        silentSamples16k = 0

                        // Reset pre-activation state
                        preActivationBuffer.removeAll(keepingCapacity: true)
                        consecutiveVoicedSamples = 0
                        onsetStartWallClock = nil

                        Log.line("accumulator[\(tag)]: VAD onset → ACTIVE at chunk #\(chunkIndex + 1) (rms=\(String(format: "%.3f", rms)))")
                    }
                } else {
                    // Silence in MONITORING — reset onset gate and clear pre-activation buffer
                    consecutiveVoicedSamples = 0
                    preActivationBuffer.removeAll(keepingCapacity: true)
                    onsetStartWallClock = nil
                }

            case .active:
                // Append to active chunk
                let offsetBefore = chunkSamples.count
                chunkSamples.append(contentsOf: resampled)
                totalSamples16k = chunkSamples.count

                if voiced {
                    silentSamples16k = 0
                    if voiceStart16k == nil { voiceStart16k = offsetBefore }
                    voiceEnd16k = chunkSamples.count
                    voicedSampleCount += frameCount
                } else {
                    silentSamples16k += frameCount
                }

                // Check close conditions
                let hitMax = totalSamples16k >= maxChunkSamples16k
                let silenceClose = silentSamples16k >= endChunkSilenceSamples16k

                if hitMax || silenceClose {
                    chunkIndex += 1
                    let reason = hitMax ? "max-chunk" : "silence"
                    Log.line("accumulator[\(tag)]: closing chunk #\(chunkIndex) (\(reason)), samples=\(chunkSamples.count), voiced=\(voicedSampleCount)")

                    counter.increment()
                    sink.yield(ChunkBuffer(
                        samples16k: chunkSamples,
                        voiceStart: voiceStart16k,
                        voiceEnd: voiceEnd16k,
                        voicedSampleCount: voicedSampleCount,
                        firstVoicedWallClock: firstVoicedWallClock,
                        closeReason: reason,
                        index: chunkIndex
                    ))

                    // Reset for next chunk
                    chunkSamples.removeAll(keepingCapacity: true)
                    silentSamples16k = 0
                    totalSamples16k = 0
                    voiceStart16k = nil
                    voiceEnd16k = 0
                    voicedSampleCount = 0
                    state = .monitoring
                }
            }
        }

        // Stream ended — flush any in-flight active chunk
        if case .active = state, !chunkSamples.isEmpty, voiceStart16k != nil {
            chunkIndex += 1
            Log.line("accumulator[\(tag)]: stream-end flush, chunk #\(chunkIndex), samples=\(chunkSamples.count)")
            counter.increment()
            sink.yield(ChunkBuffer(
                samples16k: chunkSamples,
                voiceStart: voiceStart16k,
                voiceEnd: voiceEnd16k,
                voicedSampleCount: voicedSampleCount,
                firstVoicedWallClock: firstVoicedWallClock,
                closeReason: "stream-end-flush",
                index: chunkIndex
            ))
        }

        Log.line("accumulator[\(tag)]: for-await ended naturally, buffersSeen=\(bufferCount), chunksEmitted=\(chunkIndex)")
    }

    private func processChunk(
        ctx: OpaquePointer,
        chunk: ChunkBuffer,
        source: SourceTag
    ) async -> Utterance? {
        let tag = source.rawValue

        guard let voiceStart = chunk.voiceStart else {
            Log.line("worker[\(tag)]: chunk #\(chunk.index) had no voice, skipping")
            return nil
        }

        // Gate on minimum voiced content — prevents whisper hallucinating
        // "Thank you." / "[Music]" on chunks with only a brief noise burst.
        if chunk.voicedSampleCount < minVoicedSamples16k {
            Log.line("worker[\(tag)]: chunk #\(chunk.index) too short (voiced=\(chunk.voicedSampleCount) < \(minVoicedSamples16k)), skipping")
            return nil
        }

        // Trim leading/trailing silence with 100 ms padding
        let padding = voicePaddingSamples16k
        let trimStart = max(0, voiceStart - padding)
        let trimEnd = min(chunk.samples16k.count, chunk.voiceEnd + padding)
        var trimmed: [Float]
        if trimStart == 0 && trimEnd == chunk.samples16k.count {
            trimmed = chunk.samples16k
        } else {
            trimmed = Array(chunk.samples16k[trimStart..<trimEnd])
        }

        // Pad to whisper's minimum length if needed
        let minSamples = minChunkSamples16k
        if trimmed.count < minSamples {
            let preLen = trimmed.count
            trimmed.append(contentsOf: repeatElement(0, count: minSamples - trimmed.count))
            Log.line("worker[\(tag)]: chunk #\(chunk.index) padded \(preLen) → \(trimmed.count) samples")
        }

        let prompt: String = tailLock.withLock { previousChunkTail[source] ?? "" }

        Log.line("worker[\(tag)]: chunk #\(chunk.index) → whisper_full (samples=\(trimmed.count), prompt=\"\(prompt.prefix(40))\")")
        let started = Date()

        let segments = await runWhisperLocked(ctx: ctx, samples: trimmed, initialPrompt: prompt)
        let elapsed = Date().timeIntervalSince(started)
        Log.line("worker[\(tag)]: chunk #\(chunk.index) ← whisper_full in \(String(format: "%.2f", elapsed))s, segments=\(segments.count)")

        let joined = segments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            Log.line("worker[\(tag)]: chunk #\(chunk.index) produced no text, skipping")
            return nil
        }

        tailLock.withLock {
            previousChunkTail[source] = String(joined.suffix(previousChunkTailMaxChars))
        }

        return Utterance(
            source: source,
            startedAt: chunk.firstVoicedWallClock,
            endedAt: Date(),
            text: joined
        )
    }

    // MARK: - Whisper helpers

    /// Safe Sendable wrapper for OpaquePointer to avoid bit-cast pattern across task boundaries.
    private struct WhisperContextRef: @unchecked Sendable {
        let ptr: OpaquePointer
    }

    private func runWhisperLocked(
        ctx: OpaquePointer,
        samples: [Float],
        initialPrompt: String
    ) async -> [String] {
        let lock = self.ctxLock
        let ctxRef = WhisperContextRef(ptr: ctx)
        return await Task.detached(priority: .userInitiated) {
            return Self.runWhisperUnderLock(lock: lock, ctx: ctxRef.ptr, samples: samples, initialPrompt: initialPrompt)
        }.value
    }

    private static func runWhisperUnderLock(
        lock: NSLock,
        ctx: OpaquePointer,
        samples: [Float],
        initialPrompt: String
    ) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (try? runWhisperSync(ctx: ctx, samples: samples, initialPrompt: initialPrompt)) ?? []
    }

    private static func runWhisperSync(
        ctx: OpaquePointer,
        samples: [Float],
        initialPrompt: String
    ) throws -> [String] {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.language = UnsafePointer(strdup("en")) // English-only; skips language detection
        params.no_context = true
        params.single_segment = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0.0
        params.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

        let result: Int32 = autoreleasepool {
            let inner: (UnsafePointer<CChar>?) -> Int32 = { promptPtr in
                params.initial_prompt = promptPtr
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
            if initialPrompt.isEmpty {
                return inner(nil)
            } else {
                return initialPrompt.withCString { ptr in inner(ptr) }
            }
        }

        if result != 0 {
            throw WhisperEngineError.whisperFailed("whisper_full returned \(result)")
        }

        let segCount = whisper_full_n_segments(ctx)
        var out: [String] = []
        out.reserveCapacity(Int(segCount))
        for i in 0..<segCount {
            if let cStr = whisper_full_get_segment_text(ctx, i) {
                let t = String(cString: cStr).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
            }
        }
        return out
    }

    // MARK: - Model resolution

    private func loadedContext() throws -> OpaquePointer {
        // Fast path: context already loaded (no preloadModel overhead).
        ctxInitLock.lock()
        if let c = ctx {
            ctxInitLock.unlock()
            return c
        }
        ctxInitLock.unlock()

        // Slow path: load. preloadModel() is idempotent and owns its own lock.
        try preloadModel()

        // Read back. If preloadModel() succeeded, ctx must be non-nil.
        ctxInitLock.lock()
        defer { ctxInitLock.unlock() }
        guard let c = ctx else {
            throw WhisperEngineError.modelNotFound
        }
        return c
    }

    private func resolveModelURL() throws -> URL {
        if let url = Bundle.main.url(forResource: Self.bundledModelName, withExtension: "bin") {
            return url
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Al/models/\(Self.bundledModelName).bin")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        throw WhisperEngineError.modelLoadFailed("Model \(Self.bundledModelName).bin not found in app Resources or ~/Documents/Al/models/")
    }
}

// MARK: - Errors

enum WhisperEngineError: LocalizedError {
    case modelLoadFailed(String)
    case modelNotFound
    case whisperFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let msg): return "WhisperEngine model load failed: \(msg)"
        case .modelNotFound: return "WhisperEngine: ctx nil after preloadModel"
        case .whisperFailed(let msg): return "whisper_full error: \(msg)"
        }
    }
}

// MARK: - 48→16 kHz resampler (same as LiveTranslate)

private final class WhisperResampler {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
    }()

    func convert(_ input: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || sourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
            sourceFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return nil }

        var supplied = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        var error: NSError?
        _ = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if let error {
            Log.line("WhisperResampler: convert failed: \(error.localizedDescription)")
            return nil
        }
        let n = Int(outBuf.frameLength)
        guard n > 0, let data = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: n))
    }
}
