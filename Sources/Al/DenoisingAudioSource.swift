import Foundation
import AVFoundation

/// Wraps an upstream `AudioSource`, applies RNNoiseProcessor to every
/// buffer, and re-broadcasts denoised 48 kHz mono Float32 samples.
/// One denoiser per stream — RNN state is never shared.
final class DenoisingAudioSource: AudioSource {

    private let upstream: AudioSource
    private let denoiser = RNNoiseProcessor()
    private let broadcaster = BufferBroadcaster()
    private var pumpTask: Task<Void, Never>?
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    var buffers: AsyncStream<AVAudioPCMBuffer> { broadcaster.stream }

    init(upstream: AudioSource) {
        self.upstream = upstream
    }

    func start() async throws {
        try await upstream.start()
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await buf in self.upstream.buffers {
                guard let out = self.denoise(buf) else { continue }
                self.broadcaster.emit(out)
            }
            self.broadcaster.finishAll()
        }
    }

    func stop() async {
        await upstream.stop()
        pumpTask?.cancel()
        pumpTask = nil
        broadcaster.finishAll()
        denoiser.reset()
    }

    private func denoise(_ inBuf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let count = Int(inBuf.frameLength)
        guard count > 0, let inCh = inBuf.floatChannelData?[0] else { return nil }
        denoiser.feed(samples: inCh, count: count)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        guard let outCh = outBuf.floatChannelData?[0] else { return nil }
        let written = denoiser.drain(into: outCh, count: count)
        outBuf.frameLength = AVAudioFrameCount(written)
        return written > 0 ? outBuf : nil
    }
}
