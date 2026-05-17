import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures system audio via ScreenCaptureKit. Emits 48 kHz mono Float32.
/// Auto-reconnects on stream-stopped errors with exponential backoff.
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "SystemAudioSource.samples", qos: .userInteractive)
    private let broadcaster = BufferBroadcaster()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private var shouldRun: Bool = false
    private var consecutiveFailures: Int = 0
    private var reconnectTask: Task<Void, Never>?

    var buffers: AsyncStream<AVAudioPCMBuffer> { broadcaster.stream }

    func start() async throws {
        shouldRun = true
        try await startStream()
    }

    func stop() async {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if let stream {
            self.stream = nil
            do { try await stream.stopCapture() }
            catch { Log.line("SystemAudio: stopCapture error: \(error)") }
        }
        broadcaster.finishAll()
        Log.line("SystemAudio: stopped")
    }

    private func startStream() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
        Log.line("SystemAudio: capture started")
    }

    private func scheduleReconnect() {
        guard shouldRun else { return }
        reconnectTask?.cancel()
        consecutiveFailures += 1
        let backoff = min(30.0, pow(2.0, Double(min(consecutiveFailures, 5))))
        Log.line("SystemAudio: reconnecting in \(backoff)s (failure #\(consecutiveFailures))")
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard let self, self.shouldRun else { return }
            do {
                try await self.startStream()
            } catch {
                Log.line("SystemAudio: reconnect failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = makePCMBuffer(from: sampleBuffer) else { return }
        if consecutiveFailures != 0 {
            consecutiveFailures = 0
            Log.line("SystemAudio: stream healthy — failure counter reset")
        }
        broadcaster.emit(pcm)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.line("SystemAudio: stream stopped with error: \(error.localizedDescription)")
        self.stream = nil
        scheduleReconnect()
    }

    private func makePCMBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sample.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return nil }
        if converter == nil
            || sourceFormat?.sampleRate != asbd.mSampleRate
            || sourceFormat?.channelCount != AVAudioChannelCount(asbd.mChannelsPerFrame) {
            var asbdCopy = asbd
            guard let src = AVAudioFormat(streamDescription: &asbdCopy) else { return nil }
            self.sourceFormat = src
            self.converter = AVAudioConverter(from: src, to: targetFormat)
        }
        guard let converter, let sourceFormat else { return nil }
        guard let srcBuffer = AVAudioPCMBuffer.fromCMSampleBuffer(sample, format: sourceFormat) else { return nil }
        let targetCapacity = AVAudioFrameCount(
            Double(srcBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate
        ) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else { return nil }
        var didFeed = false
        let status = converter.convert(to: outBuffer, error: nil) { _, outStatus in
            if didFeed { outStatus.pointee = .noDataNow; return nil }
            didFeed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        return status == .error ? nil : outBuffer
    }
}

enum SystemAudioError: LocalizedError {
    case noDisplay
    var errorDescription: String? {
        switch self { case .noDisplay: return "No display available for ScreenCaptureKit." }
    }
}

private extension AVAudioPCMBuffer {
    /// Build an AVAudioPCMBuffer from a CMSampleBuffer by copying PCM
    /// data into a fresh buffer (lifetime independent of CoreMedia).
    static func fromCMSampleBuffer(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let numSamples = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard numSamples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numSamples)
        else { return nil }
        buffer.frameLength = numSamples
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(numSamples), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
