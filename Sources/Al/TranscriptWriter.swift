import Foundation

actor TranscriptWriter {

    static let rotationIdleSeconds: TimeInterval = 5 * 60

    let baseDir: URL

    private var handle: FileHandle?
    private var currentFile: URL?
    private var lastEnd: Date?

    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    init(baseDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".al", isDirectory: true)) {
        self.baseDir = baseDir
    }

    func append(_ utt: Utterance) {
        do {
            try ensureFile(forUtterance: utt)
            try writeLine(utt.text)
            lastEnd = utt.endedAt
        } catch {
            Log.line("TranscriptWriter: write failed: \(error.localizedDescription) — retrying once")
            try? handle?.close()
            handle = nil
            currentFile = nil
            do {
                try ensureFile(forUtterance: utt)
                try writeLine(utt.text)
                lastEnd = utt.endedAt
            } catch {
                Log.line("TranscriptWriter: retry failed — dropping utterance: \(utt.text.prefix(40))")
            }
        }
    }

    func flush() {
        do { try handle?.synchronize() } catch {}
        try? handle?.close()
        handle = nil
        currentFile = nil
    }

    func currentFileURL() -> URL? { currentFile }

    // MARK: - Internals

    private func ensureFile(forUtterance utt: Utterance) throws {
        let needNew: Bool = {
            guard handle != nil, currentFile != nil else { return true }
            guard let last = lastEnd else { return true }
            return utt.startedAt.timeIntervalSince(last) > Self.rotationIdleSeconds
        }()
        guard needNew else { return }

        try? handle?.close()
        handle = nil
        currentFile = nil

        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let stamp = stampFormatter.string(from: utt.startedAt)
        var url = baseDir.appendingPathComponent("\(stamp).txt")
        var suffix = 0
        while FileManager.default.fileExists(atPath: url.path) {
            suffix += 1
            guard suffix <= 99 else {
                throw NSError(domain: "TranscriptWriter", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "too many same-second files"])
            }
            url = baseDir.appendingPathComponent("\(stamp)-\(suffix).txt")
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        currentFile = url
        Log.line("TranscriptWriter: opened \(url.lastPathComponent)")
    }

    private func writeLine(_ text: String) throws {
        guard let handle else {
            throw NSError(domain: "TranscriptWriter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no open file"])
        }
        let line = (text + "\n").data(using: .utf8) ?? Data()
        try handle.write(contentsOf: line)
    }
}
