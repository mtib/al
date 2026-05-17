import Foundation

/// Append-only file logger at `/tmp/al.log`. Truncates on launch if > 5 MB.
/// Identical pattern to LiveTranslate's Log.swift; only the file path changes
/// so a side-by-side install of both apps doesn't clobber each other's log.
enum Log {
    private static let path = "/tmp/al.log"
    private static let queue = DispatchQueue(label: "Al.Log")
    private static var handle: FileHandle? = {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64, size > 5_000_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: path)
        try? h?.seekToEnd()
        return h
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func line(_ s: String) {
        let stamp = iso.string(from: Date())
        let bytes = "[\(stamp)] \(s)\n".data(using: .utf8) ?? Data()
        queue.async {
            try? handle?.write(contentsOf: bytes)
        }
    }
}
