import Foundation
import AVFoundation

/// Microphone capture via `AVAudioEngine`. Emits 48 kHz mono Float32
/// `AVAudioPCMBuffer`s to every subscriber of `buffers`.
///
/// Auto-restart on config change: when the OS swaps the input device
/// (AirPods connect, HDMI attaches, headphones unplug),
/// AVAudioEngine posts `.AVAudioEngineConfigurationChange`. We listen,
/// debounce 200 ms, teardown + restart the engine transparently.
final class MicSource: NSObject, AudioSource {

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let broadcaster = BufferBroadcaster()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private var notificationToken: NSObjectProtocol?
    private var restartTask: Task<Void, Never>?

    var buffers: AsyncStream<AVAudioPCMBuffer> { broadcaster.stream }

    func start() async throws {
        try await startEngine()
        if notificationToken == nil {
            notificationToken = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Log.line("MicSource: configuration change — restarting engine")
                self?.scheduleRestart()
            }
        }
    }

    func stop() async {
        if let t = notificationToken {
            NotificationCenter.default.removeObserver(t)
            notificationToken = nil
        }
        restartTask?.cancel()
        restartTask = nil
        teardownEngine()
        broadcaster.finishAll()
        Log.line("MicSource: stopped")
    }

    // MARK: - Internals

    private func startEngine() async throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hw = input.outputFormat(forBus: 0)
        guard hw.sampleRate > 0 else {
            throw NSError(domain: "MicSource", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Input node has no format"])
        }
        guard let conv = AVAudioConverter(from: hw, to: targetFormat) else {
            throw NSError(domain: "MicSource", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create AVAudioConverter from \(hw) to \(targetFormat)"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in
            guard let self else { return }
            self.deliver(buf, converter: conv)
        }
        try engine.start()
        self.engine = engine
        self.converter = conv
        Log.line("MicSource: engine started @ \(hw.sampleRate) Hz \(hw.channelCount)ch")
    }

    private func teardownEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            self.teardownEngine()
            do {
                try await self.startEngine()
            } catch {
                Log.line("MicSource: restart failed: \(error.localizedDescription) — retrying in 2s")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.scheduleRestart()
            }
        }
    }

    private func deliver(_ buf: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let outCap = AVAudioFrameCount(
            Double(buf.frameLength) * targetFormat.sampleRate / buf.format.sampleRate
        ) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }
        var fed = false
        let status = converter.convert(to: out, error: nil) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buf
        }
        if status != .error { broadcaster.emit(out) }
    }
}
