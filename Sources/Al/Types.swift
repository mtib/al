import Foundation
import AVFoundation

/// Tag identifying which audio stream a buffer / utterance originated from.
enum SourceTag: String, Hashable, Sendable {
    case mic
    case system
}

/// Common interface for `MicSource` and `SystemAudioSource`.
/// Both must emit 48 kHz mono Float32 PCM buffers via `buffers`.
/// `stop()` must end every live `buffers` subscription so the
/// recognition pipeline drains naturally; a fresh `start()` after
/// must spin a brand-new broadcaster.
protocol AudioSource: AnyObject {
    var buffers: AsyncStream<AVAudioPCMBuffer> { get }
    func start() async throws
    func stop() async
}

/// One closed-chunk transcription, ready to write to disk.
/// Emitted by `WhisperEngine` once per voiced chunk that produced
/// non-empty text.
struct Utterance: Sendable {
    let source: SourceTag
    /// Wall-clock time the first voiced frame in the chunk arrived.
    /// Used by `TranscriptWriter` to name/rotate the output file.
    let startedAt: Date
    /// Wall-clock time the chunk closed (silence or max-chunk hit).
    let endedAt: Date
    /// Joined whisper output for the chunk, trimmed of whitespace.
    /// Always non-empty (empty results are filtered in WhisperEngine).
    let text: String
}
