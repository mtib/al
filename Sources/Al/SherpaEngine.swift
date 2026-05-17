import Foundation
import AVFoundation
import Accelerate
import CSherpa

/// Transcription engine using Silero VAD + Moonshine ASR via sherpa-onnx.
///
/// **Pipeline per stream:**
///   1. 48 kHz AVAudioPCMBuffer → resample to 16 kHz mono Float32
///   2. Crosstalk suppression: mic samples zeroed when system audio voiced within 250 ms
///   3. 16 kHz samples fed in 512-sample chunks to a per-stream Silero VAD
///   4. When Silero signals a complete speech segment, Moonshine ASR runs (CoreML)
///   5. Non-empty results emitted as Utterance values
///
/// **Shared state:** One `SherpaOnnxOfflineRecognizer` (Moonshine) shared across
/// both streams, serialised with `recognizerLock`. Each stream owns its own
/// `SherpaOnnxVoiceActivityDetector` (Silero maintains per-stream state).
final class SherpaEngine {

    // MARK: - Constants

    private let voiceThreshold: Float = 0.01
    private let crosstalkPersistSeconds: TimeInterval = 0.25
    private let vadChunkSize: Int = 512          // Silero requires exactly 512 samples at 16 kHz
    private let vadBufferSeconds: Float = 30.0   // max audio history kept by VAD

    // MARK: - Shared recognizer

    private var recognizer: OpaquePointer? // const SherpaOnnxOfflineRecognizer*
    private let recognizerLock = NSLock()
    private var isLoaded = false

    // MARK: - Crosstalk suppression

    private var lastSystemVoicedAt: Date = .distantPast
    private let crosstalkLock = NSLock()

    private func markSystemVoiced() {
        let now = Date()
        crosstalkLock.lock(); lastSystemVoicedAt = now; crosstalkLock.unlock()
    }

    private func isCrosstalkActive() -> Bool {
        crosstalkLock.lock()
        defer { crosstalkLock.unlock() }
        return Date().timeIntervalSince(lastSystemVoicedAt) < crosstalkPersistSeconds
    }

    deinit { unloadModel() }

    // MARK: - Model lifecycle

    func preloadModel() throws {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        guard !isLoaded else { return }

        let modelsDir = Self.resolveModelsDir()
        let moonshineDir = modelsDir.appendingPathComponent("sherpa-onnx-moonshine-base-en-int8")

        // Keep NSString objects alive across the C call — ARC would otherwise release them.
        let preprocessorStr = moonshineDir.appendingPathComponent("preprocess.onnx").path as NSString
        let encoderStr      = moonshineDir.appendingPathComponent("encode.int8.onnx").path as NSString
        let uncachedStr     = moonshineDir.appendingPathComponent("uncached_decode.int8.onnx").path as NSString
        let cachedStr       = moonshineDir.appendingPathComponent("cached_decode.int8.onnx").path as NSString
        let tokensStr       = moonshineDir.appendingPathComponent("tokens.txt").path as NSString
        let providerStr     = "coreml" as NSString
        let methodStr       = "greedy_search" as NSString

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.model_config.moonshine.preprocessor     = preprocessorStr.utf8String
        config.model_config.moonshine.encoder          = encoderStr.utf8String
        config.model_config.moonshine.uncached_decoder = uncachedStr.utf8String
        config.model_config.moonshine.cached_decoder   = cachedStr.utf8String
        config.model_config.tokens                     = tokensStr.utf8String
        config.model_config.provider                   = providerStr.utf8String
        config.model_config.num_threads                = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        config.decoding_method                         = methodStr.utf8String

        Log.line("SherpaEngine: loading Moonshine model at \(moonshineDir.path)")
        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaEngineError.modelLoadFailed("SherpaOnnxCreateOfflineRecognizer returned nil")
        }
        recognizer = r
        isLoaded = true
        Log.line("SherpaEngine: model loaded")
    }

    func unloadModel() {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        if let r = recognizer {
            SherpaOnnxDestroyOfflineRecognizer(r)
            recognizer = nil
            isLoaded = false
            Log.line("SherpaEngine: model unloaded")
        }
    }

    // MARK: - Transcribe

    func transcribe(
        audio: AsyncStream<AVAudioPCMBuffer>,
        source: SourceTag
    ) -> AsyncStream<Utterance> {
        AsyncStream { continuation in
            Task {
                let rec: OpaquePointer? = self.recognizerLock.withLock { self.recognizer }
                guard let rec else {
                    Log.line("SherpaEngine.transcribe[\(source.rawValue)]: no recognizer loaded")
                    continuation.finish()
                    return
                }
                Log.line("SherpaEngine.transcribe[\(source.rawValue)]: starting")
                await self.runVADLoop(recognizer: rec, audio: audio, source: source, continuation: continuation)
                Log.line("SherpaEngine.transcribe[\(source.rawValue)]: finished")
                continuation.finish()
            }
        }
    }

    // MARK: - VAD loop

    private func runVADLoop(
        recognizer: OpaquePointer,
        audio: AsyncStream<AVAudioPCMBuffer>,
        source: SourceTag,
        continuation: AsyncStream<Utterance>.Continuation
    ) async {
        let tag = source.rawValue
        let modelsDir = Self.resolveModelsDir()

        let vadModelStr = modelsDir.appendingPathComponent("silero_vad.onnx").path as NSString
        let vadProviderStr = "cpu" as NSString  // CPU is fastest for tiny Silero model

        var silero = SherpaOnnxSileroVadModelConfig()
        silero.model                = vadModelStr.utf8String
        silero.threshold            = 0.5
        silero.min_silence_duration = 0.5
        silero.min_speech_duration  = 0.1
        silero.window_size          = Int32(vadChunkSize)

        var vadConfig = SherpaOnnxVadModelConfig()
        vadConfig.silero_vad  = silero
        vadConfig.sample_rate = 16000
        vadConfig.num_threads = 2
        vadConfig.provider    = vadProviderStr.utf8String

        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&vadConfig, vadBufferSeconds) else {
            Log.line("SherpaEngine[\(tag)]: failed to create VAD")
            return
        }
        defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }

        let resampler = SherpaResampler()
        var pending: [Float] = []

        Log.line("SherpaEngine[\(tag)]: VAD loop started")

        for await buf in audio {
            if Task.isCancelled { break }
            guard var samples16k = resampler.convert(buf) else { continue }

            // Crosstalk suppression: zero mic during system audio activity
            if source == .mic && isCrosstalkActive() {
                samples16k = [Float](repeating: 0, count: samples16k.count)
            }

            // Stamp system voice activity timestamp for crosstalk suppression
            if source == .system, let data = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength)
                var ms: Float = 0
                vDSP_measqv(data, 1, &ms, vDSP_Length(n))
                if sqrt(ms) >= voiceThreshold { markSystemVoiced() }
            }

            pending.append(contentsOf: samples16k)

            // Feed complete 512-sample chunks to Silero
            while pending.count >= vadChunkSize {
                let chunk = Array(pending.prefix(vadChunkSize))
                pending.removeFirst(vadChunkSize)
                chunk.withUnsafeBufferPointer { ptr in
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, ptr.baseAddress, Int32(vadChunkSize))
                }
                drainSegments(vad: vad, recognizer: recognizer, source: source, continuation: continuation)
            }
        }

        // Flush any remaining speech in the VAD buffer
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        drainSegments(vad: vad, recognizer: recognizer, source: source, continuation: continuation)

        Log.line("SherpaEngine[\(tag)]: VAD loop finished")
    }

    // MARK: - Drain VAD segments

    private func drainSegments(
        vad: OpaquePointer,
        recognizer: OpaquePointer,
        source: SourceTag,
        continuation: AsyncStream<Utterance>.Continuation
    ) {
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let segPtr = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            // Copy samples out before Pop/Destroy invalidate the pointer
            let n = Int(segPtr.pointee.n)
            let samplesCopy: [Float]
            if let rawSamples = segPtr.pointee.samples, n > 0 {
                samplesCopy = Array(UnsafeBufferPointer(start: rawSamples, count: n))
            } else {
                samplesCopy = []
            }
            SherpaOnnxVoiceActivityDetectorPop(vad)
            SherpaOnnxDestroySpeechSegment(segPtr)

            if !samplesCopy.isEmpty {
                if let utt = runASR(recognizer: recognizer, samples: samplesCopy, source: source) {
                    continuation.yield(utt)
                }
            }
        }
    }

    // MARK: - ASR

    private func runASR(
        recognizer: OpaquePointer,
        samples: [Float],
        source: SourceTag
    ) -> Utterance? {
        guard !samples.isEmpty else { return nil }

        recognizerLock.lock()
        defer { recognizerLock.unlock() }

        guard let streamPtr = SherpaOnnxCreateOfflineStream(recognizer) else { return nil }
        defer { SherpaOnnxDestroyOfflineStream(streamPtr) }

        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxAcceptWaveformOffline(streamPtr, 16000, buf.baseAddress, Int32(samples.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, streamPtr)

        guard let resultPtr = SherpaOnnxGetOfflineStreamResult(streamPtr) else { return nil }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(resultPtr) }

        guard let cText = resultPtr.pointee.text else { return nil }
        let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        Log.line("SherpaEngine[\(source.rawValue)]: \"\(text.prefix(80))\"")
        let now = Date()
        return Utterance(source: source, startedAt: now, endedAt: now, text: text)
    }

    // MARK: - Model path resolution

    static func resolveModelsDir() -> URL {
        if let bundleURL = Bundle.main.resourceURL {
            let candidate = bundleURL.appendingPathComponent("sherpa-models")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/sherpa-models")
    }
}

// MARK: - Errors

enum SherpaEngineError: LocalizedError {
    case modelLoadFailed(String)
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let msg): return "SherpaEngine model load failed: \(msg)"
        }
    }
}

// MARK: - 48 → 16 kHz resampler

private final class SherpaResampler {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
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
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        var error: NSError?
        _ = converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
        if let error { Log.line("SherpaResampler: \(error.localizedDescription)"); return nil }
        let n = Int(outBuf.frameLength)
        guard n > 0, let data = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: n))
    }
}
