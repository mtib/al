import Foundation
import AVFoundation

final class Pipeline: @unchecked Sendable {

    enum State { case stopped, starting, running, stopping }

    private(set) var state: State = .stopped
    private let stateLock = NSLock()

    private var micSource: DenoisingAudioSource?
    private var systemSource: DenoisingAudioSource?
    private var engine: WhisperEngine?
    private let writer = TranscriptWriter()
    private var runGroupTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    var onStatus: ((String) -> Void)?

    func start() async {
        stateLock.lock()
        guard state == .stopped else { stateLock.unlock(); return }
        state = .starting
        stateLock.unlock()

        let engine = WhisperEngine()
        do {
            try engine.preloadModel()
        } catch {
            Log.line("Pipeline: engine preload failed: \(error.localizedDescription)")
            stateLock.lock(); state = .stopped; stateLock.unlock()
            onStatus?("engine load failed")
            return
        }
        self.engine = engine

        let rawMic = MicSource()
        let rawSys = SystemAudioSource()
        let mic = DenoisingAudioSource(upstream: rawMic)
        let sys = DenoisingAudioSource(upstream: rawSys)

        var startedMic = false
        var startedSys = false

        do { try await mic.start(); self.micSource = mic; startedMic = true }
        catch { Log.line("Pipeline: mic start failed: \(error.localizedDescription)") }

        do { try await sys.start(); self.systemSource = sys; startedSys = true }
        catch { Log.line("Pipeline: system audio start failed: \(error.localizedDescription)") }

        guard startedMic || startedSys else {
            stateLock.lock(); state = .stopped; stateLock.unlock()
            onStatus?("no audio sources")
            return
        }

        let activeSources: [(DenoisingAudioSource, SourceTag)] = [
            startedMic ? (mic, .mic) : nil,
            startedSys ? (sys, .system) : nil,
        ].compactMap { $0 }

        stateLock.lock(); state = .running; stateLock.unlock()
        let label = activeSources.map { $0.1.rawValue }.joined(separator: "+")
        onStatus?("running (\(label))")
        Log.line("Pipeline: started \(label)")

        let capturedEngine = engine
        let capturedWriter = writer

        runGroupTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (source, tag) in activeSources {
                    group.addTask {
                        for await utt in capturedEngine.transcribe(audio: source.buffers, source: tag) {
                            await capturedWriter.append(utt)
                        }
                    }
                }
            }
            guard let self else { return }
            self.stateLock.lock(); self.state = .stopped; self.stateLock.unlock()
            self.onStatus?("stopped")
            Log.line("Pipeline: task group exited")
        }

        startHeartbeat()
    }

    func stop() async {
        stateLock.lock()
        guard state == .running || state == .starting else { stateLock.unlock(); return }
        state = .stopping
        stateLock.unlock()

        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Stop sources — closes broadcasters — engine streams drain naturally.
        if let mic = micSource { await mic.stop() }
        if let sys = systemSource { await sys.stop() }
        micSource = nil
        systemSource = nil

        await runGroupTask?.value
        runGroupTask = nil

        await writer.flush()
        engine?.unloadModel()
        engine = nil

        stateLock.lock(); state = .stopped; stateLock.unlock()
        onStatus?("stopped")
        Log.line("Pipeline: stopped")
    }

    func currentFile() async -> URL? {
        await writer.currentFileURL()
    }

    // MARK: - Heartbeat (hourly RSS log)

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                guard self != nil else { return }
                let rss = Self.residentMemoryBytes()
                Log.line(String(format: "Pipeline: heartbeat rss=%.1f MB", Double(rss) / 1_048_576))
            }
        }
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }
}
