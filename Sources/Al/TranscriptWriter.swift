import Foundation

actor TranscriptWriter {

    static let rotationIdleSeconds: TimeInterval = 5 * 60
    /// Gap between utterances above this threshold starts a new line; below it joins with a space.
    static let newlineGapSeconds: TimeInterval = 3.0

    let baseDir: URL

    private var handle: FileHandle?
    private var currentFile: URL?
    private var lastEnd: Date?
    /// True when the write cursor is at the start of a line (nothing written yet, or last char was \n).
    private var atLineStart: Bool = true

    private let dateFolderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

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
        // Drop utterances that are entirely punctuation/whitespace.
        guard !isPunctuationOnly(utt.text) else {
            Log.line("TranscriptWriter: dropped punctuation-only — \"\(utt.text.prefix(40))\"")
            return
        }
        let gap = lastEnd.map { utt.startedAt.timeIntervalSince($0) } ?? 0
        do {
            try ensureFile(forUtterance: utt)
            try writeText(utt.text, gap: gap)
            lastEnd = utt.endedAt
        } catch {
            Log.line("TranscriptWriter: write failed — retrying once: \(error.localizedDescription)")
            try? handle?.close()
            handle = nil
            currentFile = nil
            atLineStart = true
            do {
                try ensureFile(forUtterance: utt)
                try writeText(utt.text, gap: gap)
                lastEnd = utt.endedAt
            } catch {
                Log.line("TranscriptWriter: retry failed — dropping: \"\(utt.text.prefix(40))\"")
            }
        }
    }

    func flush() {
        // Terminate the last line if we left it open.
        if !atLineStart, let handle {
            try? handle.write(contentsOf: Data("\n".utf8))
        }
        do { try handle?.synchronize() } catch {}
        try? handle?.close()
        handle = nil
        currentFile = nil
        atLineStart = true
    }

    func currentFileURL() -> URL? { currentFile }

    // MARK: - Internals

    private static let stripSet = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)

    private func isPunctuationOnly(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { $0.trimmingCharacters(in: Self.stripSet).isEmpty }
    }

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

        let dateDir = baseDir.appendingPathComponent(
            dateFolderFormatter.string(from: utt.startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let stamp = stampFormatter.string(from: utt.startedAt)
        var url = dateDir.appendingPathComponent("\(stamp).txt")
        var suffix = 0
        while FileManager.default.fileExists(atPath: url.path) {
            suffix += 1
            guard suffix <= 99 else {
                throw NSError(domain: "TranscriptWriter", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "too many same-second files"])
            }
            url = dateDir.appendingPathComponent("\(stamp)-\(suffix).txt")
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        currentFile = url
        atLineStart = true
        Log.line("TranscriptWriter: opened \(url.lastPathComponent)")
    }

    /// Writes `text` with a leading separator chosen by the gap since the last utterance:
    /// - first on line → no prefix
    /// - gap < `newlineGapSeconds` → space (join words on the same line)
    /// - gap ≥ `newlineGapSeconds` → newline (start a fresh line)
    /// No trailing newline is written; `flush()` closes the last line.
    private func writeText(_ text: String, gap: TimeInterval) throws {
        guard let handle else {
            throw NSError(domain: "TranscriptWriter", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no open file"])
        }
        let prefix: String
        if atLineStart {
            prefix = ""
        } else if gap >= Self.newlineGapSeconds {
            prefix = "\n"
        } else {
            prefix = " "
        }
        try handle.write(contentsOf: Data((prefix + text).utf8))
        atLineStart = false
    }
}
