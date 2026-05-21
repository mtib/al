import Foundation
import AVFoundation
import Accelerate
import CSherpa

/// Transcription engine using Silero VAD + a sherpa-onnx offline ASR model.
///
/// The actual model is picked at preload time (see `ASRModel`). All current
/// options run via `SherpaOnnxOfflineRecognizer` so the VAD-chunked pipeline
/// shape is identical regardless of model.
///
/// **Pipeline per stream:**
///   1. 48 kHz AVAudioPCMBuffer → resample to 16 kHz mono Float32
///   2. Crosstalk suppression: mic samples zeroed when system audio voiced within 250 ms
///   3. 16 kHz samples fed in 512-sample chunks to a per-stream Silero VAD
///   4. When Silero signals a complete speech segment, ASR runs (CoreML)
///   5. Non-empty results emitted as Utterance values
///
/// **Shared state:** One `SherpaOnnxOfflineRecognizer` shared across both
/// streams, serialised with `recognizerLock`. Each stream owns its own
/// `SherpaOnnxVoiceActivityDetector` (Silero maintains per-stream state).
///
/// **Lifecycle invariant:** `unloadModel()` must only be called after all
/// `transcribe(audio:source:)` streams have terminated (audio source stopped,
/// AsyncStream exhausted). The `Pipeline` actor guarantees this by draining
/// the task group before calling `unloadModel()`.
final class SherpaEngine {

    // MARK: - Constants

    private let voiceThreshold: Float = 0.01
    private let crosstalkPersistSeconds: TimeInterval = 0.25
    private let vadChunkSize: Int = 512          // Silero requires exactly 512 samples at 16 kHz
    private let vadBufferSeconds: Float = 30.0   // max audio history kept by VAD

    // MARK: - Shared recognizer

    private var recognizer: OpaquePointer? // const SherpaOnnxOfflineRecognizer*
    private let recognizerLock = NSLock()

    // MARK: - Crosstalk suppression

    private var lastSystemVoicedAt: Date = .distantPast
    private let crosstalkLock = NSLock()

    private func markSystemVoiced() {
        let now = Date()
        crosstalkLock.lock()
        defer { crosstalkLock.unlock() }
        lastSystemVoicedAt = now
    }

    private func isCrosstalkActive() -> Bool {
        crosstalkLock.lock()
        defer { crosstalkLock.unlock() }
        return Date().timeIntervalSince(lastSystemVoicedAt) < crosstalkPersistSeconds
    }

    deinit { unloadModel() }

    // MARK: - Model lifecycle

    func preloadModel(_ model: ASRModel = .parakeet110m) throws {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        guard recognizer == nil else { return }

        let modelsDir = Self.resolveModelsDir()
        var config = SherpaOnnxOfflineRecognizerConfig()
        let threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        let methodStr = "greedy_search" as NSString
        let providerStr = "coreml" as NSString
        // Strong refs to keep NSString-derived utf8String pointers alive across the C call.
        var keepAlive: [NSString] = [methodStr, providerStr]

        switch model {
        case .parakeet110m:
            // NVIDIA NeMo Parakeet TDT-CTC 110M — English, single-file CTC head.
            let dir = modelsDir.appendingPathComponent("sherpa-onnx-nemo-parakeet_tdt_ctc_110m-en-36000-int8")
            let modelStr     = dir.appendingPathComponent("model.int8.onnx").path as NSString
            let tokensStr    = dir.appendingPathComponent("tokens.txt").path as NSString
            let modelTypeStr = "nemo_ctc" as NSString
            keepAlive.append(contentsOf: [modelStr, tokensStr, modelTypeStr])
            config.model_config.nemo_ctc.model = modelStr.utf8String
            config.model_config.tokens         = tokensStr.utf8String
            config.model_config.model_type     = modelTypeStr.utf8String
            Log.line("SherpaEngine: loading Parakeet TDT-CTC 110M (en) at \(dir.path)")

        case .fastConformerMultilingual:
            // NeMo FastConformer CTC, EN/DE/ES/FR, single-file CTC head.
            let dir = modelsDir.appendingPathComponent("sherpa-onnx-nemo-fast-conformer-ctc-en-de-es-fr-14288-int8")
            let modelStr     = dir.appendingPathComponent("model.int8.onnx").path as NSString
            let tokensStr    = dir.appendingPathComponent("tokens.txt").path as NSString
            let modelTypeStr = "nemo_ctc" as NSString
            keepAlive.append(contentsOf: [modelStr, tokensStr, modelTypeStr])
            config.model_config.nemo_ctc.model = modelStr.utf8String
            config.model_config.tokens         = tokensStr.utf8String
            config.model_config.model_type     = modelTypeStr.utf8String
            Log.line("SherpaEngine: loading FastConformer CTC multilingual (en/de/es/fr) at \(dir.path)")

        case .parakeet06b:
            // NeMo Parakeet TDT 0.6B v3 — encoder/decoder/joiner transducer.
            // Heavy: ~465 MB on disk, ≥1.5 GB RSS in use, not realtime on M1 Air.
            // Kept as an opt-in option for users with headroom (M1 Pro+, Air+ Studio Display, etc.).
            let dir = modelsDir.appendingPathComponent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
            let encoderStr   = dir.appendingPathComponent("encoder.int8.onnx").path as NSString
            let decoderStr   = dir.appendingPathComponent("decoder.int8.onnx").path as NSString
            let joinerStr    = dir.appendingPathComponent("joiner.int8.onnx").path as NSString
            let tokensStr    = dir.appendingPathComponent("tokens.txt").path as NSString
            let modelTypeStr = "nemo_transducer" as NSString
            keepAlive.append(contentsOf: [encoderStr, decoderStr, joinerStr, tokensStr, modelTypeStr])
            config.model_config.transducer.encoder = encoderStr.utf8String
            config.model_config.transducer.decoder = decoderStr.utf8String
            config.model_config.transducer.joiner  = joinerStr.utf8String
            config.model_config.tokens             = tokensStr.utf8String
            config.model_config.model_type         = modelTypeStr.utf8String
            Log.line("SherpaEngine: loading Parakeet TDT 0.6B v3 (en) at \(dir.path)")

        case .moonshineTiny:
            let dir = modelsDir.appendingPathComponent("sherpa-onnx-moonshine-tiny-en-int8")
            let preprocessorStr    = dir.appendingPathComponent("preprocess.onnx").path as NSString
            let encoderStr         = dir.appendingPathComponent("encode.int8.onnx").path as NSString
            let uncachedDecoderStr = dir.appendingPathComponent("uncached_decode.int8.onnx").path as NSString
            let cachedDecoderStr   = dir.appendingPathComponent("cached_decode.int8.onnx").path as NSString
            let tokensStr          = dir.appendingPathComponent("tokens.txt").path as NSString
            let modelTypeStr       = "moonshine" as NSString
            keepAlive.append(contentsOf: [preprocessorStr, encoderStr, uncachedDecoderStr, cachedDecoderStr, tokensStr, modelTypeStr])
            config.model_config.moonshine.preprocessor    = preprocessorStr.utf8String
            config.model_config.moonshine.encoder         = encoderStr.utf8String
            config.model_config.moonshine.uncached_decoder = uncachedDecoderStr.utf8String
            config.model_config.moonshine.cached_decoder  = cachedDecoderStr.utf8String
            config.model_config.tokens                    = tokensStr.utf8String
            config.model_config.model_type                = modelTypeStr.utf8String
            Log.line("SherpaEngine: loading Moonshine Tiny (en) at \(dir.path)")
        }
        config.model_config.provider    = providerStr.utf8String
        config.model_config.num_threads = threads
        config.decoding_method          = methodStr.utf8String

        guard let r = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw SherpaEngineError.modelLoadFailed("SherpaOnnxCreateOfflineRecognizer returned nil")
        }
        recognizer = r
        _ = keepAlive  // ensure ARC keeps the NSStrings alive across the C call
        Log.line("SherpaEngine: model loaded")
    }

    func unloadModel() {
        recognizerLock.lock()
        defer { recognizerLock.unlock() }
        if let r = recognizer {
            SherpaOnnxDestroyOfflineRecognizer(r)
            recognizer = nil
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
                continuation.finish()
                Log.line("SherpaEngine.transcribe[\(source.rawValue)]: finished")
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
        silero.min_silence_duration = 1.0
        silero.min_speech_duration  = 0.1
        silero.window_size          = Int32(vadChunkSize)
        silero.max_speech_duration  = 30.0  // C++ default; 0 causes immediate threshold spike

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
        var pendingBuf: [Float] = []
        var pendingIdx: Int = 0
        // `micGated` tracks whether the mic stream is currently bypassed by
        // crosstalk. The system stream never gates itself.
        var micGated: Bool = false

        Log.line("SherpaEngine[\(tag)]: VAD loop started")

        for await buf in audio {
            if Task.isCancelled { break }

            // Crosstalk gate: when system audio is currently voiced, drop the
            // mic stream off the pipeline entirely — no resample, no VAD, no
            // ASR. This frees CPU/ANE for the (single, NSLock-serialised)
            // recognizer instance and avoids re-transcribing speaker bleed.
            // On gate entry we flush the mic VAD so any in-progress segment
            // closes cleanly before we go quiet.
            if source == .mic {
                if isCrosstalkActive() {
                    if !micGated {
                        micGated = true
                        SherpaOnnxVoiceActivityDetectorFlush(vad)
                        drainSegments(vad: vad, recognizer: recognizer, source: source, continuation: continuation)
                        Log.line("SherpaEngine[mic]: gated (system audio active)")
                    }
                    continue
                } else if micGated {
                    micGated = false
                    Log.line("SherpaEngine[mic]: ungated")
                }
            }

            guard let samples16k = resampler.convert(buf) else { continue }

            // Stamp system voice activity timestamp for crosstalk suppression.
            // RMS check on the raw 48 kHz buffer (cheap, no extra alloc).
            if source == .system, let data = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength)
                var meanSquare: Float = 0
                vDSP_measqv(data, 1, &meanSquare, vDSP_Length(n))
                if sqrt(meanSquare) >= voiceThreshold { markSystemVoiced() }
            }

            pendingBuf.append(contentsOf: samples16k)

            // Feed complete 512-sample chunks to Silero without O(n) copies.
            // Compact aggressively (after every drain) so the buffer head doesn't
            // sit on kilobytes of stale samples on M1 Air under sustained load.
            while pendingBuf.count - pendingIdx >= vadChunkSize {
                pendingBuf.withUnsafeBufferPointer { ptr in
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(
                        vad, ptr.baseAddress!.advanced(by: pendingIdx), Int32(vadChunkSize))
                }
                pendingIdx += vadChunkSize
                drainSegments(vad: vad, recognizer: recognizer, source: source, continuation: continuation)
            }
            if pendingIdx >= vadChunkSize {
                pendingBuf.removeFirst(pendingIdx)
                pendingIdx = 0
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
                } else {
                    Log.line("SherpaEngine[\(source.rawValue)]: segment produced no text (\(samplesCopy.count) samples)")
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
