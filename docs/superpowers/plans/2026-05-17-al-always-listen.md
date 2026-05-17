# Al (Always Listen) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that continuously transcribes the microphone and system audio (independently) via whisper.cpp large-v3-turbo and appends each transcribed utterance to a rolling text file in `~/.al/`, rotating to a new file whenever there is a gap of more than 5 minutes since the last utterance.

**Architecture:** Two independent capture pipelines (mic via `AVAudioEngine`, system audio via `ScreenCaptureKit`) each run through RNNoise and a voice-activity-based chunker. Both feed a single shared whisper.cpp context (NSLock-serialized around `whisper_full`). Transcribed text from either stream is funneled into a single `TranscriptWriter` actor that owns the current log file and rotates on a 5-minute idle gap. The UI is an `LSUIElement` (no Dock, no window) menu-bar widget — start/stop, status, open log folder. Sources auto-reconnect on stream failure with exponential backoff. No translation, no live HTTP stream, no WAV recording — just continuous transcription to a flat text log.

**Tech Stack:**
- Swift 6 (Package.swift), executable target pinned to `.swiftLanguageMode(.v5)`
- macOS 15+ (matches existing LiveTranslate baseline)
- `AVFoundation` (mic capture, format conversion)
- `ScreenCaptureKit` (system audio capture)
- `AppKit` (`NSStatusItem`, `NSMenu`)
- whisper.cpp v1.7.4 + ggml (Metal backend, large-v3-turbo Q5_0 model, ~570 MB)
- xiph/rnnoise v0.1.1 (vendored C, 48 kHz mono Float32)
- Reused signing identity from LiveTranslate: `LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev` (same self-signed cert; new bundle ID gets its own TCC grants)

---

## File Structure

Project root: `/Users/mtib/al/`. Layout mirrors the existing LiveTranslate repo (no `.xcodeproj`; SwiftPM + CMake for whisper.cpp). Files marked **(reuse)** are copied verbatim from `/Users/mtib/transcrybe-diy/` — they are battle-tested and unchanged for Al. Files marked **(adapt)** are derived from a transcrybe-diy counterpart but trimmed/altered for Al. Files marked **(new)** are written from scratch.

```
al/
├── Package.swift                                  (new — single executable + 2 C targets)
├── README.md                                      (new)
├── CLAUDE.md                                      (new — project orientation doc)
├── Info.plist                                     (new — LSUIElement = true)
├── .gitignore                                     (new)
├── build.sh                                       (adapt from LiveTranslate)
├── dev-setup.sh                                   (adapt — pre-downloads turbo model)
├── tools/
│   ├── build-whisper.sh                           (reuse — pinned to v1.7.4, large-v3-turbo Q5_0 default)
│   ├── make-icon.sh                               (adapt — uses SF Symbol "ear")
│   └── make-icon.swift                            (adapt — same)
├── models/                                        (gitignored — populated by dev-setup.sh)
├── external/whisper.cpp/                          (gitignored — cloned by build-whisper.sh)
├── build/                                         (gitignored)
├── Sources/
│   ├── CRNNoise/                                  (reuse entire directory verbatim — xiph rnnoise v0.1.1)
│   ├── CWhisper/                                  (reuse — same bridge target + module.modulemap)
│   └── Al/
│       ├── main.swift                             (new — NSApplicationMain bootstrap)
│       ├── AppDelegate.swift                      (new — owns Pipeline + MenuBarController lifetime)
│       ├── MenuBarController.swift                (new — NSStatusItem + NSMenu)
│       ├── Pipeline.swift                         (new — orchestrator, much simpler than LiveTranslate's)
│       ├── Types.swift                            (adapt — SourceTag, AudioSource protocol only; no Sentence/Translator/etc.)
│       ├── BufferBroadcaster.swift                (reuse)
│       ├── Log.swift                              (adapt — logs to /tmp/al.log)
│       ├── MicSource.swift                        (adapt from MicrophoneSource.swift — add auto-restart on config change)
│       ├── SystemAudioSource.swift                (adapt — add auto-reconnect on stream stop)
│       ├── DenoisingAudioSource.swift             (adapt — drop AGC and crosstalk-mute hooks; keep raw RNNoise wrap)
│       ├── RNNoiseProcessor.swift                 (reuse)
│       ├── WhisperEngine.swift                    (adapt from WhisperCppTranscriber.swift — drop lifecycle/UI/JSONL, emit one `Utterance` per closed chunk)
│       ├── TranscriptWriter.swift                 (new — actor, single shared file, 5-min rotation)
│       └── Permissions.swift                      (new — TCC mic + screen recording precheck)
└── docs/
    └── superpowers/plans/
        └── 2026-05-17-al-always-listen.md         (this file)
```

**One-responsibility split:**
- `Pipeline.swift` knows how to start/stop both sources and wire each one's `Utterance` stream to `TranscriptWriter`. It does **not** know about menu bar, files, or whisper internals.
- `TranscriptWriter.swift` owns the file handle and rotation rule. It does **not** know about audio or transcription.
- `WhisperEngine.swift` owns the whisper context and chunking. It emits `Utterance` values; it does **not** know where they go.
- `MenuBarController.swift` owns the `NSStatusItem`. It does **not** know about audio or files — it talks to `Pipeline` through a tiny interface.

---

## Task 1: Repo scaffold + Package.swift + .gitignore + CLAUDE.md

**Files:**
- Create: `/Users/mtib/al/.gitignore`
- Create: `/Users/mtib/al/Package.swift`
- Create: `/Users/mtib/al/CLAUDE.md`
- Create: `/Users/mtib/al/README.md` (skeleton, fleshed out in Task 14)

- [ ] **Step 1: `git init` the repo**

```bash
cd /Users/mtib/al
git init
git branch -m main
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
build/
external/
models/
.build/
.swiftpm/
.DS_Store
Sources/CWhisper/include/whisper.h
Sources/CWhisper/include/ggml*.h
*.xcuserstate
*.log
```

- [ ] **Step 3: Create `Package.swift`**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Al",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CRNNoise",
            path: "Sources/CRNNoise",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .unsafeFlags([
                    "-Wno-implicit-function-declaration",
                    "-Wno-null-dereference",
                ]),
            ]
        ),
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L./build/whisper-prefix/lib",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-blas",
                    "-lggml-metal",
                    "-lc++",
                ]),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .executableTarget(
            name: "Al",
            dependencies: ["CRNNoise", "CWhisper"],
            path: "Sources/Al",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
```

- [ ] **Step 4: Create `CLAUDE.md` skeleton**

```markdown
# Al (Always Listen) — context for Claude

A minimal, no-Xcode macOS menu-bar app that continuously transcribes the
microphone and system audio (independently) via whisper.cpp and appends
the resulting text to a rolling log file under `~/.al/`. Sibling project
to LiveTranslate; reuses its RNNoise wrapper, CWhisper bridge, and build
scripts. No translation, no UI transcript, no recordings.

> **Process rule for future edits**
>
> Any meaningful change to source layout, data flow, or runtime behavior
> MUST be reflected in this file in the same commit. Add numbered entries
> to "Things that have bitten us" when a real bug bites.

## How it's built

- Pure SwiftPM + CMake for whisper.cpp (no Xcode). Same toolchain as
  LiveTranslate.
- `./build.sh` runs `tools/build-whisper.sh`, then `swift build -c release`,
  then wraps the binary into `build/Al.app/`, copies the GGML model into
  Resources, and codesigns. Use:
  ```sh
  LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh
  ```
  to reuse the existing self-signed cert (keeps TCC grants across
  rebuilds).
- Launch via `open build/Al.app` — never run the binary directly.

## Architecture

```
  Mic ────▶ RNNoise(mic) ───▶ WhisperEngine.transcribe(.mic) ──┐
                                                                ├─▶ TranscriptWriter
  System ─▶ RNNoise(sys) ───▶ WhisperEngine.transcribe(.system) ┘   (~/.al/<stamp>.txt,
                                                                     5-min rotation)
                                              ▲
                                              │ shared whisper_context
                                              │ (NSLock around whisper_full)
```

## Files

(Filled in per task as files are created.)

## Things that have bitten us

(Empty — add when bugs bite.)
```

- [ ] **Step 5: Create `README.md` skeleton**

```markdown
# Al — Always Listen

A macOS menu-bar widget that continuously transcribes your microphone
and system audio to a plain-text log under `~/.al/`. On-device via
whisper.cpp; nothing leaves the machine.

## Build

```sh
./dev-setup.sh                                       # one-time: caches model
LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh
open build/Al.app
```

(See full README in Task 14.)
```

- [ ] **Step 6: Commit**

```bash
git add .gitignore Package.swift CLAUDE.md README.md
git commit -m "scaffold Al repo: Package.swift, .gitignore, doc skeletons"
```

---

## Task 2: Vendor CRNNoise + RNNoiseProcessor + BufferBroadcaster + Log + Types

These are unchanged or near-unchanged copies from LiveTranslate. Bringing them in first lets every subsequent task assume they exist.

**Files:**
- Create directory: `Sources/CRNNoise/` (full copy from `/Users/mtib/transcrybe-diy/Sources/CRNNoise/`)
- Create: `Sources/Al/RNNoiseProcessor.swift` (verbatim copy from `/Users/mtib/transcrybe-diy/Sources/LiveTranslate/RNNoiseProcessor.swift`)
- Create: `Sources/Al/BufferBroadcaster.swift` (verbatim copy from `/Users/mtib/transcrybe-diy/Sources/LiveTranslate/BufferBroadcaster.swift`)
- Create: `Sources/Al/Log.swift` (adapt: change path constant to `/tmp/al.log`)
- Create: `Sources/Al/Types.swift` (new — much smaller than LiveTranslate's)

- [ ] **Step 1: Copy CRNNoise verbatim**

```bash
cp -R /Users/mtib/transcrybe-diy/Sources/CRNNoise /Users/mtib/al/Sources/
```

Verify the directory landed:
```bash
ls Sources/CRNNoise/include/rnnoise.h && ls Sources/CRNNoise/LICENSE
```

- [ ] **Step 2: Copy RNNoiseProcessor.swift verbatim**

```bash
cp /Users/mtib/transcrybe-diy/Sources/LiveTranslate/RNNoiseProcessor.swift /Users/mtib/al/Sources/Al/
```

- [ ] **Step 3: Copy BufferBroadcaster.swift verbatim**

```bash
cp /Users/mtib/transcrybe-diy/Sources/LiveTranslate/BufferBroadcaster.swift /Users/mtib/al/Sources/Al/
```

- [ ] **Step 4: Create `Sources/Al/Log.swift`** — adapted from LiveTranslate (rename path)

```swift
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
```

- [ ] **Step 5: Create `Sources/Al/Types.swift`** — new, trimmed

```swift
import Foundation
import AVFoundation

/// Tag identifying which audio stream a buffer / utterance originated from.
/// Used in log lines and (internally) to keep per-source state in
/// `WhisperEngine` (e.g. the `initial_prompt` continuity string).
enum SourceTag: String, Hashable, Sendable {
    case mic
    case system
}

/// Common interface for `MicSource` and `SystemAudioSource` so `Pipeline`
/// can drive them uniformly. Both must:
///   - emit 48 kHz mono Float32 PCM buffers via `buffers`
///     (RNNoise's native rate — see `RNNoiseProcessor`),
///   - be re-startable: `stop()` must end every live `buffers`
///     subscription so the recognition pipeline drains naturally, and a
///     fresh `start()` after must spin a brand-new broadcaster.
protocol AudioSource: AnyObject {
    var buffers: AsyncStream<AVAudioPCMBuffer> { get }
    func start() async throws
    func stop() async
}

/// One closed-chunk transcription, ready to write. Emitted by
/// `WhisperEngine` once per chunk that produced non-empty text. Empty/
/// silence/whisper-rejected chunks never produce an Utterance.
struct Utterance: Sendable {
    let source: SourceTag
    /// Wall-clock time the chunk's first voiced sample arrived.
    /// Used by `TranscriptWriter` to decide rotation (gap > 5 min →
    /// new file named after this timestamp).
    let startedAt: Date
    /// Wall-clock time the chunk closed (silence or max-chunk).
    let endedAt: Date
    /// Whisper's joined output for the chunk, trimmed. Never empty
    /// (empty results are filtered upstream).
    let text: String
}
```

- [ ] **Step 6: Build to confirm the C target + reused files compile**

```bash
cd /Users/mtib/al
swift build 2>&1 | tail -20
```

Expected: build error about missing `main.swift` / `@main` in the executable target — that's fine, we'll add `main.swift` in Task 9. CRNNoise + the reused Swift files should compile.

- [ ] **Step 7: Commit**

```bash
git add Sources/CRNNoise Sources/Al
git commit -m "vendor CRNNoise, RNNoiseProcessor, BufferBroadcaster, Log, Types"
```

---

## Task 3: CWhisper bridge target + build-whisper.sh + dev-setup.sh

Brings in the whisper.cpp bridge and the model-download tooling. Identical to LiveTranslate, with the default model bumped from `ggml-small-q5_1` to `ggml-large-v3-turbo-q5_0` per the spec.

**Files:**
- Create directory: `Sources/CWhisper/` (full copy from LiveTranslate)
- Create: `tools/build-whisper.sh` (reuse verbatim — but read it to confirm `MODEL_NAME` default)
- Create: `dev-setup.sh` (adapt — pre-downloads only the turbo model)

- [ ] **Step 1: Copy CWhisper bridge directory**

```bash
cp -R /Users/mtib/transcrybe-diy/Sources/CWhisper /Users/mtib/al/Sources/
# Clear any cached headers that might have been copied; they'll be
# regenerated by build-whisper.sh on first build.
rm -f /Users/mtib/al/Sources/CWhisper/include/whisper.h \
      /Users/mtib/al/Sources/CWhisper/include/ggml*.h
```

Verify:
```bash
ls Sources/CWhisper/include/         # should contain bridge header(s), no whisper.h
cat Sources/CWhisper/dummy.c         # should exist
```

- [ ] **Step 2: Copy tools/build-whisper.sh**

```bash
mkdir -p tools
cp /Users/mtib/transcrybe-diy/tools/build-whisper.sh tools/
chmod +x tools/build-whisper.sh
```

The script's default `MODEL_NAME` is already `ggml-large-v3-turbo-q5_0.bin` — confirm:
```bash
grep '^MODEL_NAME=' tools/build-whisper.sh
```
Expected output:
```
MODEL_NAME="${WHISPER_MODEL:-ggml-large-v3-turbo-q5_0.bin}"
```

- [ ] **Step 3: Create `dev-setup.sh`** — adapted, single-model

```bash
#!/usr/bin/env bash
# One-time setup: ensure cmake is present, pre-download the GGML model
# into the repo-local models/ cache so build.sh doesn't re-fetch on a
# fresh checkout.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v cmake >/dev/null 2>&1; then
    echo "Installing cmake via Homebrew..."
    brew install cmake
fi

mkdir -p models
MODEL="ggml-large-v3-turbo-q5_0.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL}"

if [[ -s "models/${MODEL}" ]]; then
    echo "✓ ${MODEL} already cached"
else
    echo "→ downloading ${MODEL} (~570 MB)"
    curl -L --fail --progress-bar -o "models/${MODEL}.partial" "${URL}"
    mv "models/${MODEL}.partial" "models/${MODEL}"
fi

echo "✓ dev-setup complete. Next: LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh"
```

Make it executable:
```bash
chmod +x dev-setup.sh
```

- [ ] **Step 4: Pre-build whisper.cpp once to confirm the toolchain works**

```bash
./tools/build-whisper.sh 2>&1 | tail -20
```

Expected: clones whisper.cpp v1.7.4 into `external/`, builds via CMake, drops `build/whisper-prefix/lib/libwhisper.a` and friends, mirrors headers into `Sources/CWhisper/include/`. First run takes ~1 minute on Apple Silicon.

Verify:
```bash
ls build/whisper-prefix/lib/*.a
ls Sources/CWhisper/include/whisper.h
```

- [ ] **Step 5: Confirm SwiftPM links against the bridge**

```bash
swift build 2>&1 | tail -10
```

Expected: still fails for missing `@main` / `main.swift`. CWhisper itself should compile silently.

- [ ] **Step 6: Commit**

```bash
git add Sources/CWhisper tools/build-whisper.sh dev-setup.sh
git commit -m "add CWhisper bridge + build-whisper.sh + dev-setup.sh"
```

(Note: `external/` and `build/` are gitignored, so they don't get committed.)

---

## Task 4: MicSource + SystemAudioSource + DenoisingAudioSource (with auto-reconnect)

Audio capture for both streams. Adapted from LiveTranslate's `MicrophoneSource.swift` and `SystemAudioSource.swift`. Two changes vs. the originals:

1. `MicSource` listens for `AVAudioEngineConfigurationChangeNotification` and restarts the engine in place (LiveTranslate doesn't bother — the user is in the app and notices a stall; Al runs unattended for hours, so we must self-heal).
2. `SystemAudioSource` adds an exponential-backoff reconnect loop on `didStopWithError`.

`DenoisingAudioSource` is copied without the AGC and without the crosstalk-mute hooks — those were tuned for a single mixed recognizer; Al's two independent whisper streams don't need them. (Crosstalk is still a real concern — see Task 5 for the cheaper fix.)

**Files:**
- Create: `Sources/Al/MicSource.swift`
- Create: `Sources/Al/SystemAudioSource.swift`
- Create: `Sources/Al/DenoisingAudioSource.swift`

- [ ] **Step 1: Create `Sources/Al/MicSource.swift`**

```swift
import Foundation
import AVFoundation

/// Microphone capture via `AVAudioEngine`. Emits 48 kHz mono Float32
/// `AVAudioPCMBuffer`s to every subscriber of `buffers`.
///
/// Auto-restart on configuration change: when the OS swaps the input
/// device (AirPods connect, HDMI display attaches, headphones unplug),
/// `AVAudioEngine` posts `.AVAudioEngineConfigurationChange`. The
/// engine itself stays alive but the input node's format becomes
/// invalid; subsequent taps deliver garbage or nothing. We listen for
/// the notification, tear the tap + engine down, and re-`start()` —
/// transparent to the rest of the pipeline because the broadcaster
/// keeps fanning out to the same subscribers.
final class MicSource: NSObject, AudioSource {

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var hwFormat: AVAudioFormat?
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
        // Subscribe to config-change notifications once. Engine will
        // be replaced under us on each restart; the handler reads
        // `self.engine` lazily so it always sees the current one.
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
        let conv = AVAudioConverter(from: hw, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            self.deliver(buf, converter: conv)
        }
        try engine.start()
        self.engine = engine
        self.hwFormat = hw
        self.converter = conv
        Log.line("MicSource: engine started @ \(hw.sampleRate) Hz \(hw.channelCount)ch")
    }

    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        hwFormat = nil
    }

    private func scheduleRestart() {
        // Coalesce: drop any in-flight restart and start a fresh one.
        // 200 ms debounce gives the OS time to settle on the new device.
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
        if status != .error {
            broadcaster.emit(out)
        }
    }
}
```

- [ ] **Step 2: Create `Sources/Al/SystemAudioSource.swift`**

Adapted from LiveTranslate's version. Adds `reconnectLoop`. (Sample conversion helper at the bottom is copied verbatim.)

```swift
import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Captures system audio via `ScreenCaptureKit`. Emits 48 kHz mono
/// Float32 buffers. Auto-reconnects on stream-stopped errors with
/// exponential backoff (1s, 2s, 4s, …, capped at 30s). Reconnect
/// resets on the first successful sample, so a long-running stream
/// that briefly hiccups doesn't accumulate backoff state.
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

    // MARK: - Internals

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

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let pcm = makePCMBuffer(from: sampleBuffer) else { return }
        // First sample after a (re)connect — reset failure counter so a
        // long-lived stream that occasionally blips doesn't accumulate
        // backoff.
        if consecutiveFailures != 0 {
            consecutiveFailures = 0
            Log.line("SystemAudio: stream healthy — failure counter reset")
        }
        broadcaster.emit(pcm)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.line("SystemAudio: stream stopped with error: \(error.localizedDescription)")
        self.stream = nil
        scheduleReconnect()
    }

    // MARK: - Sample conversion (verbatim from LiveTranslate)

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
        switch self {
        case .noDisplay: return "No display available for ScreenCaptureKit."
        }
    }
}

private extension AVAudioPCMBuffer {
    static func fromCMSampleBuffer(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let numSamples = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard numSamples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numSamples)
        else { return nil }
        buffer.frameLength = numSamples
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(numSamples),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
```

- [ ] **Step 3: Create `Sources/Al/DenoisingAudioSource.swift`**

A simplified version of LiveTranslate's — drops the AGC envelope follower and crosstalk-mute coupling, keeps the per-source RNNoise wrap.

```swift
import Foundation
import AVFoundation

/// Wraps an upstream `AudioSource`, runs every emitted buffer through
/// its own `RNNoiseProcessor`, and re-broadcasts the denoised samples.
/// One denoiser instance per upstream — its hidden RNN state is per-
/// stream, never shared.
///
/// Format invariant: input and output are both 48 kHz mono Float32 in
/// the ±1 range; RNNoise's int16-scale handling is internal to
/// `RNNoiseProcessor`.
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
        // Pump: drain upstream, feed RNNoise, drain into a fresh
        // buffer per upstream frame, emit. Runs forever until either
        // upstream closes its broadcaster or pumpTask is cancelled.
        pumpTask = Task { [weak self] in
            guard let self else { return }
            for await buf in self.upstream.buffers {
                guard let outBuf = self.denoise(buf) else { continue }
                self.broadcaster.emit(outBuf)
            }
            // Upstream ended — propagate.
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
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            return nil
        }
        guard let outCh = outBuf.floatChannelData?[0] else { return nil }
        let written = denoiser.drain(into: outCh, count: count)
        outBuf.frameLength = AVAudioFrameCount(written)
        return written > 0 ? outBuf : nil
    }
}
```

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: still fails on missing `main.swift`/entry point. Audio sources should compile.

- [ ] **Step 5: Commit**

```bash
git add Sources/Al/MicSource.swift Sources/Al/SystemAudioSource.swift Sources/Al/DenoisingAudioSource.swift
git commit -m "add audio sources: mic (auto-restart) + system (exp backoff reconnect) + denoiser"
```

---

## Task 5: WhisperEngine — long-chunk transcription, shared context

The biggest single piece. Adapted from LiveTranslate's `WhisperCppTranscriber.swift` (850 lines). Key changes:

- **Drop everything UI-shaped:** no `inflightChunks`, no `onChunkLifecycle`, no `SessionSnapshot`. The engine emits `Utterance` values via a per-call `AsyncStream<Utterance>`.
- **VAD chunking rules (RMS-based):**
  - `onsetSeconds = 0.1` — a chunk only opens AFTER 0.1 s of continuous voiced frames. The 0.1 s pre-activation buffer is included in the chunk once opened (not discarded). This prevents a single-frame click or noise burst from opening a chunk.
  - `endChunkAfterSilence = 2.0` — once a chunk is open, close it after 2 s of continuous silence.
  - `maxChunkSeconds = 30.0` — hard cap; force-close regardless of silence.
  - `minWhisperInputSeconds = 1.1` — whisper's mel-spectrogram threshold; chunks under this are padded with trailing zeros or dropped.
  - Between utterances the engine is idle (RMS monitoring only, no accumulation). No "continuous accumulate + hope whisper filters silence" — only accumulate when active.
- **Drop the crosstalk-mute coupling.** With long chunks and 30 s caps, the crosstalk-on-mic problem will produce occasional duplicate lines in the log (one from system, one from mic). That's acceptable for Al's "log everything" use case — and we can revisit if it's bad in practice. (Logged as a known limitation in CLAUDE.md once we hit it.)
- **Drop the recorder + SRT writers.** Al doesn't record audio.
- **Bounded chunk queue.** If whisper is slower than realtime on one stream (large-v3-turbo is borderline at ~3× RT for one stream, ~1.5× for two contending), the accumulator could outrun the worker for hours. Cap the queue at 4 chunks; drop oldest if exceeded and log a warning (transcription gaps are preferable to OOM after a 12-hour run).
- **`autoreleasepool` around `whisper_full`** — large-v3-turbo allocates significant transient buffers; without explicit drain, ARC can hold them across calls. Important for the long-run leak budget.

Because the LiveTranslate version is 850 lines, this task quotes only the parts that change. The unchanged scaffolding (model load with NSLock, ggml param init, post-call segment join, `previousChunkTail` continuity, ≥1.1 s padding) is copied straight over.

**Files:**
- Create: `Sources/Al/WhisperEngine.swift`

- [ ] **Step 1: Start by copying the source verbatim, then we'll trim**

```bash
cp /Users/mtib/transcrybe-diy/Sources/LiveTranslate/WhisperCppTranscriber.swift Sources/Al/WhisperEngine.swift
```

- [ ] **Step 2: Open `Sources/Al/WhisperEngine.swift` and rename the class + remove UI types**

Apply these structural edits:

1. **Rename** the class from `WhisperCppTranscriber` to `WhisperEngine` (whole file).
2. **Delete** every reference to:
   - `onChunkLifecycle` callback and all `ChunkLifecycle` cases (`listening`, `transcribing`, `completed`, `dropped`)
   - `SessionSnapshot`, `SessionSentence`, `Sentence`
   - `previousChunkTail` is **kept** — same purpose (initial_prompt continuity per source)
   - `lastSystemVoicedAt` and `crosstalkPersistSeconds` — drop the whole crosstalk-mute block, including its NSLock and per-buffer queries
3. **Replace** the public API. The new signature:

```swift
/// Drive transcription for one source. Consumes 48 kHz mono Float32
/// PCM from `audio`, accumulates into RMS-VAD chunks, runs whisper
/// on each, and yields one `Utterance` per chunk that produces
/// non-empty text. Empty / silence / sub-1.1s chunks are silently
/// dropped (whisper hallucinates on short audio — see CLAUDE.md
/// lesson "Whisper silently drops audio under ~1 s").
///
/// Multiple concurrent `transcribe(audio:source:)` calls (mic +
/// system) share one `whisper_context`; `whisper_full` is
/// serialized with an `NSLock` (whisper.cpp's context is single-
/// threaded). Per-source `previousChunkTail` keeps the
/// `initial_prompt` continuity strings independent.
///
/// The returned stream terminates when `audio` terminates AND the
/// final in-flight chunk has been processed.
func transcribe(audio: AsyncStream<AVAudioPCMBuffer>, source: SourceTag) -> AsyncStream<Utterance>
```

4. **Change** the chunking constants:

```swift
/// Max real-time gap of silence inside a chunk before we close it
/// and ship to whisper. 2.0 s tolerates normal sentence-internal
/// pauses; Al has no UI latency budget so long chunks are fine.
private let endChunkAfterSilence: TimeInterval = 2.0
/// Hard cap on chunk length. 30 s lets a continuous monologue stay
/// in one chunk; longer than that risks whisper running into its
/// 30-s context window. (whisper.cpp's mel buffer is 30 s.)
private let maxChunkSeconds: TimeInterval = 30.0
/// Minimum total chunk length before silence-close is allowed.
/// Below this, whisper's mel-spectrogram threshold (100 frames at
/// 10 ms) discards the audio and returns zero segments. We pad
/// shorter clips with trailing zeros as a final safety net.
private let minWhisperInputSeconds: TimeInterval = 1.1
```

5. **Add** the bounded chunk queue. Inside the `accumulator` task, before yielding a closed `ChunkBuffer` into the queue, add:

```swift
// Backpressure: if whisper is falling behind, drop the oldest
// pending chunk rather than growing the queue forever. Better to
// lose a sentence than to OOM during a long unattended run.
//
// Implementation note: the queue here is the `AsyncStream`
// continuation, which doesn't expose size. So we keep a parallel
// counter behind an NSLock and check it before yielding.
queueLock.lock()
let queued = pendingChunkCount
pendingChunkCount += 1
queueLock.unlock()
if queued >= maxPendingChunks {
    Log.line("WhisperEngine[\(source.rawValue)]: chunk queue full (\(queued)) — dropping oldest")
    // Drop semantics: we can't pop from the AsyncStream itself, so
    // instead the worker increments a "skip next N" counter when it
    // sees pendingChunkCount > maxPendingChunks. See the worker
    // below.
}
continuation.yield(chunkBuffer)
```

And in the worker loop, after dequeuing a `ChunkBuffer`:

```swift
queueLock.lock()
pendingChunkCount -= 1
let backlog = pendingChunkCount
queueLock.unlock()
if backlog >= maxPendingChunks {
    // We're behind. Drain this chunk without running whisper to
    // catch up. Log so it's visible in /tmp/al.log.
    Log.line("WhisperEngine[\(source.rawValue)]: dropping chunk to catch up (backlog=\(backlog))")
    continue
}
```

Declare these as instance properties:

```swift
private let queueLock = NSLock()
private var pendingChunkCount: Int = 0
private let maxPendingChunks: Int = 4
```

6. **Wrap `whisper_full` in an autoreleasepool**:

```swift
autoreleasepool {
    ctxLock.lock()
    let rc = whisper_full(ctx, params, samples, Int32(samples.count))
    ctxLock.unlock()
    if rc != 0 {
        Log.line("WhisperEngine[\(source.rawValue)]: whisper_full rc=\(rc)")
        return
    }
    // … segment join + Utterance construction …
}
```

7. **Replace the final emit** — instead of constructing a `SessionSnapshot`, build an `Utterance`:

```swift
let joined = joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
guard !joined.isEmpty else { return }
let utt = Utterance(
    source: source,
    startedAt: chunk.firstVoicedWallClock,
    endedAt: Date(),
    text: joined
)
continuation.yield(utt)
```

Where `firstVoicedWallClock` is added to the internal `ChunkBuffer` struct: stamp it once at first voiced sample (so file rotation in Task 6 sees the true utterance-start moment, not the chunk-open moment which might be earlier when leading silence existed).

8. **Bundled model name** — change the constant:

```swift
static let bundledModelName: String = "ggml-large-v3-turbo-q5_0"
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: still fails on missing `@main`, but `WhisperEngine.swift` should compile cleanly. If you get errors about unresolved references (e.g. `Sentence`, `SessionSnapshot`), you missed a deletion — grep the file for those names and remove the remaining usages.

- [ ] **Step 4: Commit**

```bash
git add Sources/Al/WhisperEngine.swift
git commit -m "add WhisperEngine: long-chunk (2s silence / 30s cap), bounded queue, shared ctx"
```

---

## Task 6: TranscriptWriter — file rotation actor

The file-writer for `~/.al/`. Pure logic; no audio. Worth designing carefully because it's where the spec's rotation rule lives and where the long-run resilience story bottoms out.

**Behaviour:**
- Single shared file across both sources. Lines are interleaved in arrival order (no per-source files; user said "add that text to a text file", singular).
- One actor — serial — receives `Utterance` values. (`actor` is appropriate here; not `@MainActor`, no UI hop.)
- On each utterance:
  1. Compute `gap = utterance.startedAt - lastWriteEndedAt`.
  2. If `gap > 5 min` or no file is open: close current file (if any), open a new file at `~/.al/<utterance.startedAt as ISO-8601 with colons replaced by dashes>.txt`.
  3. Append `utterance.text + "\n"`.
  4. Update `lastWriteEndedAt = utterance.endedAt`.
- `~/.al/` is created on first write (mkdir -p semantics) — never on app launch, because the spec ties the directory's existence to "actually heard something."
- File handle is held open between writes (one less `open` syscall per line). Closed on rotation and on `flush()`. macOS auto-recovers from `~/.al` being deleted mid-run only if we don't hold a stale fd — so we re-`fopen` if a write fails with `EBADF` / `ENOENT` (one retry, then give up that utterance and log).
- `flush()` is called from `AppDelegate.applicationWillTerminate` so a clean Quit doesn't lose the last in-memory bytes.

**Filename format:**

```
2026-05-17T14-30-45.txt
```

Why `-` instead of `:`? Default macOS Finder is fine with `:` (it remaps to `/` display-side), but command-line tools and most editors are not. Colons in filenames break SCP, rsync, tar, half of bash one-liners. `-` is universally safe.

**Files:**
- Create: `Sources/Al/TranscriptWriter.swift`

- [ ] **Step 1: Create `Sources/Al/TranscriptWriter.swift`**

```swift
import Foundation

/// Append `Utterance.text` lines to a single rolling file under
/// `~/.al/`. Rotates to a new file whenever the gap between the
/// previous utterance's `endedAt` and the next utterance's
/// `startedAt` exceeds `rotationIdleSeconds` (5 minutes by spec).
///
/// Both audio sources funnel through here, so a long session
/// looks like:
///
///   ~/.al/2026-05-17T14-30-45.txt   ← Mon afternoon block
///   ~/.al/2026-05-17T18-12-03.txt   ← evening block (>5 min gap)
///   ~/.al/2026-05-18T09-04-22.txt   ← Tue morning
///
/// Each line is one closed whisper chunk's joined transcription,
/// plain text, no source tag, no timestamp. The filename is the
/// only timestamp in the system — that's deliberate; the user said
/// "just plain text, each chunk in a new line."
actor TranscriptWriter {

    /// Idle gap that triggers a new file. Spec: 5 minutes.
    static let rotationIdleSeconds: TimeInterval = 5 * 60

    /// Resolved at init from `FileManager.default.homeDirectoryForCurrentUser`.
    /// Created lazily on first write — never at startup, because the
    /// spec says the file (and directory) is tied to actually hearing
    /// something.
    let baseDir: URL

    private var handle: FileHandle?
    private var currentFile: URL?
    private var lastEnd: Date?

    /// File-name timestamp formatter. Filesystem-safe (no colons),
    /// sortable lexically. Local time, not UTC — the user is browsing
    /// these files in Finder.
    private let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    init(baseDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".al", isDirectory: true)) {
        self.baseDir = baseDir
    }

    /// Append one utterance. Rotates the file if more than 5 minutes
    /// elapsed since the previous write's end. Creates `~/.al/` on
    /// first call. Survives the file being deleted out from under
    /// us — re-opens and retries once.
    func append(_ utt: Utterance) {
        do {
            try ensureFile(forUtterance: utt)
            try writeLine(utt.text)
            lastEnd = utt.endedAt
        } catch {
            Log.line("TranscriptWriter: write failed: \(error.localizedDescription) — retrying once")
            // Drop the handle and try once more. Recovers from a deleted
            // file / directory while we held a stale fd.
            try? handle?.close()
            handle = nil
            currentFile = nil
            do {
                try ensureFile(forUtterance: utt)
                try writeLine(utt.text)
                lastEnd = utt.endedAt
            } catch {
                Log.line("TranscriptWriter: retry failed: \(error.localizedDescription) — dropping utterance")
            }
        }
    }

    /// Close the current file. Called from AppDelegate's terminate
    /// handler so a clean Quit doesn't strand bytes in the buffer
    /// cache. Safe to call when nothing is open. Idempotent.
    func flush() {
        do { try handle?.synchronize() } catch { /* best-effort */ }
        try? handle?.close()
        handle = nil
        currentFile = nil
    }

    // MARK: - Internals

    private func ensureFile(forUtterance utt: Utterance) throws {
        // Decision: do we need a new file?
        let needNewFile: Bool = {
            guard handle != nil, currentFile != nil else { return true }
            guard let last = lastEnd else { return true }
            return utt.startedAt.timeIntervalSince(last) > Self.rotationIdleSeconds
        }()
        guard needNewFile else { return }

        // Close old.
        try? handle?.close()
        handle = nil
        currentFile = nil

        // Make sure ~/.al/ exists.
        try FileManager.default.createDirectory(
            at: baseDir,
            withIntermediateDirectories: true
        )

        // Build the path. If a file at the exact second already exists
        // (e.g. test re-run within the same second), append "-1", "-2",
        // … to avoid clobbering.
        let stamp = stampFormatter.string(from: utt.startedAt)
        var url = baseDir.appendingPathComponent("\(stamp).txt")
        var suffix = 0
        while FileManager.default.fileExists(atPath: url.path) {
            suffix += 1
            url = baseDir.appendingPathComponent("\(stamp)-\(suffix).txt")
            if suffix > 99 {
                // Should be unreachable in practice; bail out.
                throw NSError(domain: "TranscriptWriter", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "too many same-second files"])
            }
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        self.handle = h
        self.currentFile = url
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

    /// Read-only accessor for the menu bar: which file is currently
    /// being written to? `nil` if nothing has been transcribed yet
    /// this run.
    func currentFileURL() -> URL? { currentFile }
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build 2>&1 | tail -10
```

Expected: still fails for missing `@main`. TranscriptWriter compiles.

- [ ] **Step 3: Commit**

```bash
git add Sources/Al/TranscriptWriter.swift
git commit -m "add TranscriptWriter: ~/.al/<stamp>.txt with 5-min idle rotation"
```

---

## Task 7: Permissions precheck

Light wrapper that probes mic + screen-recording status without actually starting the streams. Used by `MenuBarController` to decorate the menu ("Microphone: granted / denied") and by `Pipeline` at start time to skip dead streams.

**Files:**
- Create: `Sources/Al/Permissions.swift`

- [ ] **Step 1: Create `Sources/Al/Permissions.swift`**

```swift
import Foundation
import AVFoundation
import ScreenCaptureKit

/// Probes TCC grant state for mic and screen recording without
/// triggering the prompts. The prompts themselves fire on first
/// `AVAudioEngine.start()` and first `SCStream.startCapture()` —
/// nothing for us to do at probe time, the OS handles the UI.
///
/// Used by `MenuBarController` to label menu items so the user can
/// see at a glance whether a stream is going to work, and by
/// `Pipeline` to skip starting a stream we know is denied (rather
/// than fail noisily and trigger the reconnect loop).
enum Permissions {

    enum Status {
        case granted
        case denied
        case notDetermined
    }

    static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .denied
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    /// ScreenCaptureKit has no synchronous probe. We test by asking
    /// for shareable content with a short timeout — success means
    /// granted, the documented `SCStreamError` codes for permission
    /// failure map to `.denied`, anything else stays `.notDetermined`.
    static func screenRecordingStatus() async -> Status {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return .granted
        } catch let e as NSError where e.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            // SCStreamErrorUserDeclined = -3801 — has been seen but isn't
            // in the public header. Treat any SCK error as denied; the
            // start path will re-attempt and produce a proper error if
            // the actual reason is something else.
            return .denied
        } catch {
            return .notDetermined
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Al/Permissions.swift
git commit -m "add Permissions probe (mic + screen recording, no prompt side-effects)"
```

---

## Task 8: Pipeline orchestrator

Wires the two sources through `DenoisingAudioSource` → `WhisperEngine` → `TranscriptWriter`. Owns the start/stop lifecycle. Much smaller than LiveTranslate's `Pipeline.swift` (665 lines) because there's no UI, no translation, no archive zipping.

**Files:**
- Create: `Sources/Al/Pipeline.swift`

- [ ] **Step 1: Create `Sources/Al/Pipeline.swift`**

```swift
import Foundation

/// Top-level orchestrator. Owns:
///   - one `MicSource` + its `DenoisingAudioSource` wrap,
///   - one `SystemAudioSource` + its `DenoisingAudioSource` wrap,
///   - one shared `WhisperEngine`,
///   - one `TranscriptWriter`.
///
/// `start()` is idempotent — calling it while already running is a
/// no-op. `stop()` is also idempotent and drains the in-flight chunk
/// from both sources before returning (see LiveTranslate's lesson
/// "Cancelling runTask aborts the recognition mid-flight" — same
/// shutdown rule applies: end the audio sources, let the recognition
/// pipeline drain naturally, only then cancel the supervising task).
///
/// Sources that fail to start (e.g. denied permission) are logged
/// and skipped — the other one keeps running. This matters because
/// the menu bar app might be launched before the user has granted
/// screen recording; we still want the mic to work in the meantime.
final class Pipeline: @unchecked Sendable {

    enum State { case stopped, starting, running, stopping }

    private(set) var state: State = .stopped
    private let stateLock = NSLock()

    private var micSource: DenoisingAudioSource?
    private var systemSource: DenoisingAudioSource?
    private var engine: WhisperEngine?
    private let writer = TranscriptWriter()
    private var runGroupTask: Task<Void, Never>?

    /// Called by MenuBarController; safe to call from any thread.
    /// Reports a quick status string back via `onStatus` so the menu
    /// can update — `nil` means "nothing changed visibly", a string
    /// like "running (mic+sys)" or "permission denied: screen" is the
    /// user-facing label.
    var onStatus: ((String) -> Void)?

    func start() async {
        stateLock.lock()
        guard state == .stopped else { stateLock.unlock(); return }
        state = .starting
        stateLock.unlock()

        // Engine first — it's the slow part (loads the GGML model,
        // ~500 ms). We do it before starting audio so the first chunk
        // doesn't have to wait.
        let engine = WhisperEngine()
        do {
            try engine.preloadModel()
        } catch {
            Log.line("Pipeline: engine preload failed: \(error.localizedDescription)")
            stateLock.lock()
            state = .stopped
            stateLock.unlock()
            onStatus?("engine load failed")
            return
        }
        self.engine = engine

        let rawMic = MicSource()
        let rawSys = SystemAudioSource()
        let mic = DenoisingAudioSource(upstream: rawMic)
        let sys = DenoisingAudioSource(upstream: rawSys)

        var startedAny = false
        do {
            try await mic.start()
            self.micSource = mic
            startedAny = true
        } catch {
            Log.line("Pipeline: mic start failed: \(error.localizedDescription)")
        }
        do {
            try await sys.start()
            self.systemSource = sys
            startedAny = true
        } catch {
            Log.line("Pipeline: system audio start failed: \(error.localizedDescription)")
        }

        guard startedAny else {
            stateLock.lock()
            state = .stopped
            stateLock.unlock()
            onStatus?("no audio sources")
            return
        }

        // Spawn the supervising task group. Two child tasks consume
        // utterances from the engine; a third (sentinel) keeps the
        // group alive even if both audio streams happen to be torn
        // down briefly during reconnect.
        runGroupTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                if let mic = self.micSource {
                    let micStream = engine.transcribe(audio: mic.buffers, source: .mic)
                    group.addTask { [weak self] in
                        for await utt in micStream {
                            await self?.writer.append(utt)
                        }
                    }
                }
                if let sys = self.systemSource {
                    let sysStream = engine.transcribe(audio: sys.buffers, source: .system)
                    group.addTask { [weak self] in
                        for await utt in sysStream {
                            await self?.writer.append(utt)
                        }
                    }
                }
            }
            // Task group exited — both engine streams finished, meaning
            // both audio sources have closed their broadcasters. Either
            // the user pressed Stop (state is .stopping) or both
            // sources died beyond recovery. Either way, we're stopped.
            self.stateLock.lock()
            self.state = .stopped
            self.stateLock.unlock()
            self.onStatus?("stopped")
        }

        stateLock.lock()
        state = .running
        stateLock.unlock()
        let parts = [
            micSource != nil ? "mic" : nil,
            systemSource != nil ? "sys" : nil
        ].compactMap { $0 }.joined(separator: "+")
        onStatus?("running (\(parts))")
        Log.line("Pipeline: started \(parts)")
    }

    func stop() async {
        stateLock.lock()
        guard state == .running || state == .starting else { stateLock.unlock(); return }
        state = .stopping
        stateLock.unlock()

        // End audio sources — broadcasters close — engine streams
        // drain naturally (see LiveTranslate lesson #17). Then the
        // task group ends and our supervising task returns.
        if let mic = micSource { await mic.stop() }
        if let sys = systemSource { await sys.stop() }
        micSource = nil
        systemSource = nil

        // Wait for the supervising task to finish draining.
        await runGroupTask?.value
        runGroupTask = nil

        await writer.flush()
        engine?.unloadModel()
        engine = nil

        stateLock.lock()
        state = .stopped
        stateLock.unlock()
        onStatus?("stopped")
        Log.line("Pipeline: stopped")
    }

    /// Snapshot for the menu bar.
    func currentFile() async -> URL? {
        await writer.currentFileURL()
    }
}
```

- [ ] **Step 2: Add `preloadModel()` and `unloadModel()` to `WhisperEngine`**

In `Sources/Al/WhisperEngine.swift`, add these two methods at the top of the class body (they wrap the existing model-load code that was previously called lazily on first `transcribe`):

```swift
/// Load the GGML model into a `whisper_context` eagerly. Called
/// by Pipeline at start so the first audio chunk doesn't pay the
/// ~500 ms load cost. Idempotent — second call is a no-op.
func preloadModel() throws {
    ctxLock.lock()
    defer { ctxLock.unlock() }
    guard ctx == nil else { return }
    // … existing model-load body lifted out of ensureContextLoaded() …
}

/// Free the `whisper_context`. Called by Pipeline at stop to
/// release the ~1.5 GB of resident memory the turbo model holds.
/// Important for the menu-bar use case — the user expects the
/// memory back when they pause listening for the night.
func unloadModel() {
    ctxLock.lock()
    if let c = ctx { whisper_free(c) }
    ctx = nil
    ctxLock.unlock()
}
```

And replace the previous `ensureContextLoaded()` callsites with `try preloadModel()` (or remove `ensureContextLoaded()` entirely and have `transcribe` assume the context is loaded — Pipeline now guarantees it).

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: still fails for missing `@main`. Pipeline compiles.

- [ ] **Step 4: Commit**

```bash
git add Sources/Al/Pipeline.swift Sources/Al/WhisperEngine.swift
git commit -m "add Pipeline; engine preload/unload to bound resident memory while idle"
```

---

## Task 9: MenuBarController — NSStatusItem + menu

The visible UI. A single icon in the menu bar, click to drop a menu with:

- Status row (disabled, decorative): `Idle` / `Listening (mic+sys)` / `Error: …`
- Start / Stop (one item, label toggles)
- Open Current Log (disabled when no current file)
- Open Log Folder (`~/.al/`)
- ─────
- Permissions: Microphone (✓/✗), System Audio (✓/✗) — click to open System Settings
- ─────
- Quit Al

**Files:**
- Create: `Sources/Al/MenuBarController.swift`

- [ ] **Step 1: Create `Sources/Al/MenuBarController.swift`**

```swift
import AppKit

/// Owns the NSStatusItem and its NSMenu. Talks to `Pipeline` through
/// a tiny callback interface; never accesses audio / files directly.
/// Lives on the MainActor because AppKit demands it.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let pipeline: Pipeline

    private let startStopItem = NSMenuItem(title: "Start Listening", action: nil, keyEquivalent: "")
    private let statusRow = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let openCurrentLogItem = NSMenuItem(title: "Open Current Log", action: nil, keyEquivalent: "")
    private let micPermItem = NSMenuItem(title: "Microphone: checking…", action: nil, keyEquivalent: "")
    private let sysPermItem = NSMenuItem(title: "System Audio: checking…", action: nil, keyEquivalent: "")

    init(pipeline: Pipeline) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.pipeline = pipeline
        super.init()
        configureButton()
        buildMenu()
        wireCallbacks()
        Task { await self.refreshPermissions() }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        // SF Symbol "ear.fill" — universally read as "listening". Falls
        // back to plain "ear" if the fill variant is unavailable on the
        // current macOS.
        let img = NSImage(systemSymbolName: "ear.fill", accessibilityDescription: "Al")
            ?? NSImage(systemSymbolName: "ear", accessibilityDescription: "Al")
        img?.isTemplate = true
        button.image = img
        button.toolTip = "Al — Always Listen"
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())

        startStopItem.target = self
        startStopItem.action = #selector(toggleListening)
        menu.addItem(startStopItem)

        openCurrentLogItem.target = self
        openCurrentLogItem.action = #selector(openCurrentLog)
        menu.addItem(openCurrentLogItem)

        let openFolderItem = NSMenuItem(title: "Open Log Folder", action: #selector(openLogFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(.separator())

        micPermItem.target = self
        micPermItem.action = #selector(openMicSettings)
        menu.addItem(micPermItem)

        sysPermItem.target = self
        sysPermItem.action = #selector(openScreenSettings)
        menu.addItem(sysPermItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Al", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func wireCallbacks() {
        pipeline.onStatus = { [weak self] label in
            Task { @MainActor in
                self?.statusRow.title = label.prefix(1).uppercased() + label.dropFirst()
                self?.startStopItem.title = label.hasPrefix("running") ? "Stop Listening" : "Start Listening"
            }
        }
    }

    // MARK: - Menu delegate — refresh state every open

    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            await self.refreshPermissions()
            let url = await self.pipeline.currentFile()
            self.openCurrentLogItem.title = url == nil
                ? "Open Current Log (none yet)"
                : "Open Current Log (\(url!.lastPathComponent))"
            self.openCurrentLogItem.isEnabled = url != nil
        }
    }

    // MARK: - Actions

    @objc private func toggleListening() {
        Task {
            switch pipeline.state {
            case .running:  await pipeline.stop()
            case .stopped:  await pipeline.start()
            case .starting, .stopping: break
            }
        }
    }

    @objc private func openCurrentLog() {
        Task {
            if let url = await pipeline.currentFile() {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func openLogFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".al")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(dir)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openScreenSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Permissions row updates

    private func refreshPermissions() async {
        let mic = Permissions.microphoneStatus()
        micPermItem.title = "Microphone: \(label(mic))"

        let sys = await Permissions.screenRecordingStatus()
        sysPermItem.title = "System Audio: \(label(sys))"
    }

    private func label(_ s: Permissions.Status) -> String {
        switch s {
        case .granted:        return "✓ granted"
        case .denied:         return "✗ denied — click to open Settings"
        case .notDetermined:  return "not asked yet"
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: still fails for missing `@main`. MenuBarController compiles.

- [ ] **Step 3: Commit**

```bash
git add Sources/Al/MenuBarController.swift
git commit -m "add MenuBarController: NSStatusItem with start/stop, log open, perms shortcuts"
```

---

## Task 10: AppDelegate + main.swift + Info.plist

The entry point. `LSUIElement=true` so the app has no Dock icon and no window, just the menu bar. `applicationWillTerminate` triggers `Pipeline.stop()` + `writer.flush()` for a clean shutdown.

**Files:**
- Create: `Sources/Al/main.swift`
- Create: `Sources/Al/AppDelegate.swift`
- Create: `Info.plist`

- [ ] **Step 1: Create `Sources/Al/AppDelegate.swift`**

```swift
import AppKit

/// The app's lifecycle owner. Holds one `Pipeline` and one
/// `MenuBarController`. Pipeline does NOT auto-start on launch —
/// the user has to click Start in the menu. (Rationale: on a fresh
/// install the screen-recording permission isn't granted yet; auto-
/// starting would surface as a denied-stream error before the user
/// has even seen the menu.)
final class AppDelegate: NSObject, NSApplicationDelegate {

    let pipeline = Pipeline()
    var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line("Al: launched")
        // Build the menu bar on the MainActor — AppKit requires it,
        // and applicationDidFinishLaunching already runs there.
        menuBar = MenuBarController(pipeline: pipeline)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.line("Al: terminating — draining pipeline")
        // Block the main thread briefly so the writer flushes. Quit
        // is the only path that gets us here; the user is OK with a
        // sub-second wait for a clean shutdown.
        let group = DispatchGroup()
        group.enter()
        Task {
            await pipeline.stop()
            group.leave()
        }
        _ = group.wait(timeout: .now() + 5)
        Log.line("Al: bye")
    }
}
```

- [ ] **Step 2: Create `Sources/Al/main.swift`**

We're on Swift 6 + macOS 15, but `@main` on `NSApplicationDelegate` requires the AppKit lifecycle to be wired manually for `LSUIElement` apps. Using a `main.swift` bootstrap is the cleanest way for a no-Xcode SwiftPM executable:

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory matches LSUIElement=true in Info.plist; redundant but harmless,
// and means even if the user removes LSUIElement we still don't show in Dock.
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 3: Create `Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Al</string>
    <key>CFBundleDisplayName</key>
    <string>Al</string>
    <key>CFBundleIdentifier</key>
    <string>local.mtib.al</string>
    <key>CFBundleVersion</key>
    <string>0.1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleExecutable</key>
    <string>Al</string>
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <!-- Menu-bar-only: no Dock icon, no main window. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Al transcribes microphone audio on-device with whisper.cpp; nothing leaves your Mac.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Al transcribes audio playing through your Mac (no video frames are kept) so you have a searchable text record of what you listened to.</string>
</dict>
</plist>
```

- [ ] **Step 4: Build for real**

```bash
swift build 2>&1 | tail -10
```

Expected: success. The Swift target now has an entry point.

- [ ] **Step 5: Commit**

```bash
git add Sources/Al/main.swift Sources/Al/AppDelegate.swift Info.plist
git commit -m "add AppDelegate + main.swift + Info.plist (LSUIElement menu-bar app)"
```

---

## Task 11: build.sh + icon tooling

The bundle-and-sign script. Adapted from LiveTranslate's `build.sh` with three differences:
- App name → `Al`, model name kept at `ggml-large-v3-turbo-q5_0.bin`.
- Default model already matches LiveTranslate's recent default; no override needed.
- Icon uses SF Symbol `ear.fill` instead of LiveTranslate's logo.

Signing identity reuses `LIVETRANSLATE_SIGN_IDENTITY` (defaults to `-` for ad-hoc, set to `LiveTranslateDev` to persist TCC grants). The env var name is kept as-is to match the user's `.zshrc`.

**Files:**
- Create: `build.sh`
- Create: `tools/make-icon.sh`
- Create: `tools/make-icon.swift`

- [ ] **Step 1: Create `build.sh`**

```bash
#!/usr/bin/env bash
# Build Al and wrap it into a proper .app bundle.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="Al"
APP_DIR="build/${APP_NAME}.app"

./tools/build-whisper.sh

echo "→ swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_DIR}/Contents/Info.plist"

MODEL_NAME="${WHISPER_MODEL:-ggml-large-v3-turbo-q5_0.bin}"
cp "build/whisper-models/${MODEL_NAME}" "${APP_DIR}/Contents/Resources/${MODEL_NAME}"

./tools/make-icon.sh build/icon
cp build/icon/icon.icns "${APP_DIR}/Contents/Resources/icon.icns"

# Reuse LiveTranslate's signing identity by env-var name — the user
# keeps `export LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev` in
# ~/.zshrc and we want both apps to honour it. TCC grants are keyed
# on (cert identity, bundle id), and Al's bundle id is distinct
# (local.mtib.al vs local.mtib.livetranslate), so Al gets its own
# grants without conflicting with LiveTranslate's.
SIGN_IDENTITY="${LIVETRANSLATE_SIGN_IDENTITY:--}"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}" >/dev/null
if [[ "${SIGN_IDENTITY}" != "-" ]]; then
    echo "  signed with identity: ${SIGN_IDENTITY}"
fi

echo "✓ built ${APP_DIR}"
echo "  run with: open ${APP_DIR}"
```

```bash
chmod +x build.sh
```

- [ ] **Step 2: Create `tools/make-icon.swift`** — small Swift program that renders an SF Symbol to a PNG suite for `iconutil`

```swift
import AppKit

// Render SF Symbol "ear.fill" at every iconset resolution into
// <out_dir>/icon.iconset/, then iconutil-compile into icon.icns.
// Usage: swift make-icon.swift <out_dir>

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <out_dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
let iconset = outDir.appendingPathComponent("icon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"),
    (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"),
    (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]

guard let base = NSImage(systemSymbolName: "ear.fill", accessibilityDescription: nil) else {
    FileHandle.standardError.write("symbol not found\n".data(using: .utf8)!)
    exit(1)
}

for (px, label) in sizes {
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.7, weight: .regular)
    guard let img = base.withSymbolConfiguration(cfg) else { continue }
    let target = NSImage(size: NSSize(width: px, height: px))
    target.lockFocus()
    NSColor.black.setFill()  // ignored — template image; iconutil handles tinting
    let rect = NSRect(x: 0, y: 0, width: px, height: px)
    img.draw(in: rect)
    target.unlockFocus()
    guard let tiff = target.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let url = iconset.appendingPathComponent("icon_\(label).png")
    try? png.write(to: url)
}

// iconutil
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("icon.icns").path]
try? task.run()
task.waitUntilExit()
```

- [ ] **Step 3: Create `tools/make-icon.sh`** — invokes the Swift program

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-build/icon}"
mkdir -p "${OUT_DIR}"

if [[ -f "${OUT_DIR}/icon.icns" ]]; then
    echo "✓ icon already rendered at ${OUT_DIR}/icon.icns"
    exit 0
fi

echo "→ rendering icon"
swift tools/make-icon.swift "${OUT_DIR}"
test -f "${OUT_DIR}/icon.icns" || { echo "✗ icon.icns not produced"; exit 1; }
echo "✓ icon at ${OUT_DIR}/icon.icns"
```

```bash
chmod +x tools/make-icon.sh
```

- [ ] **Step 4: Run a full build end-to-end**

```bash
LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh
```

Expected: builds whisper.cpp (no-op after Task 3), builds Swift, wraps into `build/Al.app`, copies model + icon, signs. Final line: `✓ built build/Al.app`.

Verify:
```bash
ls -la build/Al.app/Contents/MacOS/Al
ls build/Al.app/Contents/Resources/
codesign -dv build/Al.app 2>&1 | grep Authority
```

The `codesign -dv` line should show `Authority=LiveTranslateDev` if signing succeeded.

- [ ] **Step 5: Commit**

```bash
git add build.sh tools/make-icon.sh tools/make-icon.swift
git commit -m "add build.sh + icon tooling (reuses LIVETRANSLATE_SIGN_IDENTITY)"
```

---

## Task 12: Manual smoke test — first end-to-end run

No XCTest available, so verification is manual. Be deliberate about it.

- [ ] **Step 1: Reset any stale TCC grants** (only if you're re-testing after a previous attempt)

```bash
tccutil reset Microphone local.mtib.al 2>/dev/null || true
tccutil reset ScreenCapture local.mtib.al 2>/dev/null || true
```

- [ ] **Step 2: Launch the app**

```bash
open build/Al.app
```

Expected: an "ear" icon appears in the menu bar. No Dock icon. No window.

- [ ] **Step 3: Open the menu — verify layout**

Click the ear icon. The menu should show:
- `Idle`  (disabled)
- `─────`
- `Start Listening`
- `Open Current Log (none yet)`  (disabled)
- `Open Log Folder`
- `─────`
- `Microphone: not asked yet`
- `System Audio: not asked yet`
- `─────`
- `Quit Al`

- [ ] **Step 4: Press Start. Grant permissions.**

macOS prompts for Microphone — Grant.
macOS prompts for Screen Recording — Grant. (For the screen recording grant to take effect for some macOS versions, the OS may ask you to relaunch the app. If it does, quit and re-open via `open build/Al.app`, then press Start again.)

The menu status row should now read `Running (mic+sys)`.

- [ ] **Step 5: Speak a sentence into the mic, then play a YouTube clip with audible speech.**

```bash
tail -f /tmp/al.log
```

Expected log entries (interleaved with whisper.cpp's own ggml output to stderr):
```
TranscriptWriter: opened 2026-05-17T14-30-45.txt
```

After ~2 seconds of silence following your sentence, you should see:
```
WhisperEngine[mic]: closed chunk 2.4s
```
and then text being written to the file.

- [ ] **Step 6: Verify the output file**

```bash
ls -la ~/.al/
cat ~/.al/*.txt
```

Expected: one file at `~/.al/<today's date>.txt`, with one line per utterance from both sources interleaved by time of arrival.

- [ ] **Step 7: Verify rotation** (smoke test — actual 5-min gap is real-time)

Hard to test the 5-minute rule without waiting 5 minutes. Validate the logic by pressing Stop, waiting 5+ minutes, then pressing Start and speaking again. The new utterance should land in a *new* file (different timestamp).

If you don't want to wait, temporarily set `rotationIdleSeconds = 30` in `TranscriptWriter.swift`, rebuild, test, then revert.

- [ ] **Step 8: Verify long-running stability (light)**

Leave it running for at least 30 minutes with intermittent audio. Check:

```bash
# Resident memory should be stable — turbo model is ~1.5 GB, plus working
# set; expect ~2 GB total, not climbing.
ps -o pid,rss,command -p $(pgrep -f 'build/Al.app/Contents/MacOS/Al')

# No runaway log growth
ls -lh /tmp/al.log

# No abandoned files
ls -la ~/.al/
```

Memory should plateau (turbo model loaded into Metal) and stay flat. CPU should idle near 0% between utterances, spike during whisper inference.

- [ ] **Step 9: Verify clean shutdown**

Press Quit. Verify the last in-flight utterance was written (`cat ~/.al/*.txt | tail`) and that `/tmp/al.log` ends with `Al: bye`.

- [ ] **Step 10: Document the smoke test in CLAUDE.md**

Append to `CLAUDE.md`:

```markdown
## Manual smoke test

Re-run after meaningful changes to the pipeline / writer / sources.

1. `tccutil reset Microphone local.mtib.al && tccutil reset ScreenCapture local.mtib.al`
2. `LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh && open build/Al.app`
3. Click ear icon → Start. Grant permissions.
4. Speak; play a clip. `tail -f /tmp/al.log` shows chunks closing; `~/.al/<stamp>.txt` accumulates lines.
5. Stop, wait 5+ minutes, Start, speak — verify a new file is created.
6. `ps -o rss,command -p $(pgrep -f 'build/Al.app/Contents/MacOS/Al')` after 30 min — resident memory should be flat.
7. Quit — last utterance lands in the file; `/tmp/al.log` ends with `Al: bye`.
```

- [ ] **Step 11: Commit any fixes plus the docs update**

```bash
git add CLAUDE.md
git commit -m "manual smoke test passes; document procedure in CLAUDE.md"
```

---

## Task 13: Long-run resilience — autoreleasepool audit + leak watchdog

After the smoke test confirms a 30-minute run is clean, we still want defense-in-depth for runs measured in days. Two safeguards:

1. **Audit every long-lived buffer or accumulator** for unbounded growth.
2. **Add a periodic heartbeat log** that prints resident memory once per hour. If memory is creeping, the log will show it long before macOS notices.

**Files:**
- Modify: `Sources/Al/Pipeline.swift` (add heartbeat task)
- Modify: `Sources/Al/WhisperEngine.swift` (audit `previousChunkTail` cap, autoreleasepool placement, chunk buffer release)

- [ ] **Step 1: Add `heartbeatTask` to Pipeline**

In `Pipeline.swift`, inside `start()` after the task group is spawned (or as a separate sibling task — either is fine):

```swift
heartbeatTask = Task { [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)  // 1 hour
        guard self != nil else { return }
        let rss = Self.residentMemoryBytes()
        Log.line(String(format: "Pipeline: heartbeat rss=%.1f MB", Double(rss) / 1_048_576))
    }
}
```

And the helper:

```swift
private static func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}
```

Property:

```swift
private var heartbeatTask: Task<Void, Never>?
```

Cancel it in `stop()`:

```swift
heartbeatTask?.cancel()
heartbeatTask = nil
```

- [ ] **Step 2: Audit `WhisperEngine.previousChunkTail`**

Verify there's a cap (LiveTranslate's was 120 chars). Add or confirm:

```swift
// Cap previous-chunk tail at 120 chars to bound the param size on
// initial_prompt and prevent unbounded growth across thousands of
// chunks.
private let previousChunkTailMaxChars: Int = 120
```

And after constructing the tail:

```swift
if tail.count > previousChunkTailMaxChars {
    tail = String(tail.suffix(previousChunkTailMaxChars))
}
```

- [ ] **Step 3: Verify autoreleasepool placement**

Already wrapped in Task 5 step 6. Confirm by reading the file:

```bash
grep -n autoreleasepool Sources/Al/WhisperEngine.swift
```

Expected: at least one match around the `whisper_full` call.

- [ ] **Step 4: Run a longer smoke (1 hour minimum)**

Same procedure as Task 12 step 8 but leave for 1+ hour with audio coming through. Then:

```bash
grep heartbeat /tmp/al.log
```

Expected: one line per hour, each showing roughly the same RSS (within ±50 MB jitter — Metal allocator slack).

- [ ] **Step 5: Commit**

```bash
git add Sources/Al/Pipeline.swift Sources/Al/WhisperEngine.swift
git commit -m "long-run defence: hourly RSS heartbeat, bounded chunk-tail string"
```

---

## Task 14: README + final polish

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md` (fill in the "Files" section + any "Things that have bitten us" from Task 12-13)

- [ ] **Step 1: Flesh out README.md**

```markdown
# Al — Always Listen

A macOS menu-bar widget that continuously transcribes your microphone
and system audio to plain-text log files under `~/.al/`. Runs on-device
via whisper.cpp large-v3-turbo; nothing leaves the machine.

Sibling project to [LiveTranslate](https://github.com/mtib/transcrybe-diy);
reuses its RNNoise wrapper, CWhisper bridge, and build scripts.

## Behaviour

- Two independent capture streams (mic + system audio) feed one shared
  whisper.cpp context (NSLock-serialized).
- Each closed utterance (silence > 2 s, or chunk > 30 s) writes one
  line to the current log file.
- If 5+ minutes have elapsed since the last utterance, a new file is
  opened named after the next utterance's start time.
- Filenames are `yyyy-MM-ddTHH-mm-ss.txt` in local time.
- Auto-restart on input-device changes (mic) and ScreenCaptureKit
  stream failures (system audio).

## Build

```sh
./dev-setup.sh                                           # one-time: install cmake, download model
LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh  # build + sign
open build/Al.app                                        # launch
```

The build script reuses LiveTranslate's signing-identity env var so both
apps share the same self-signed cert (and therefore persist TCC grants
across rebuilds independently).

If you don't have a `LiveTranslateDev` cert yet: open Keychain Access →
Certificate Assistant → Create a Certificate → Identity Type: Self-Signed
Root, Certificate Type: Code Signing, name: `LiveTranslateDev`. Then
re-run `./build.sh`.

## Menu

Click the ear icon in the menu bar:

| Item | Behaviour |
|---|---|
| _Idle_ / _Running (mic+sys)_ | Decorative status. |
| Start / Stop Listening | Toggles the pipeline. |
| Open Current Log | Opens the file currently being written. |
| Open Log Folder | Opens `~/.al/` in Finder. |
| Microphone: ✓ / ✗ | Status; click to open System Settings → Microphone. |
| System Audio: ✓ / ✗ | Status; click to open System Settings → Screen Recording. |
| Quit Al | Drains the pipeline, flushes the file, exits. |

## File format

Plain text. One whisper-chunk transcription per line. No timestamps in
the file (the filename is the timestamp); no source tag. Both mic and
system audio land in the same file, interleaved by arrival.

## Debug

```sh
tail -f /tmp/al.log                                  # internal log
ls -la ~/.al/                                        # output files
pkill -f 'build/Al.app/Contents/MacOS/Al'            # force-quit
tccutil reset Microphone local.mtib.al               # drop mic grant
tccutil reset ScreenCapture local.mtib.al            # drop screen grant
```

## Limitations

- Crosstalk: if the mic picks up the system's audio through the
  speakers, you'll see two lines in the file — one from each stream.
  Acceptable for "log everything"; we can revisit if it's bad in
  practice.
- The whisper.cpp model is 30 s mel-context — a 30-s continuous
  monologue with no breaks may have its tail clipped. The 30-s
  `maxChunkSeconds` cap matches that limit; longer silence-broken
  speech is split naturally.
- Whisper hallucinates fragments like "Thanks for watching!" on
  near-silent input. We filter chunks under 1.1 s; some bleed-through
  remains for the truly-quiet-but-not-silent case.
```

- [ ] **Step 2: Fill in CLAUDE.md's "Files" table**

Replace the `(Filled in per task…)` line with a real table mirroring LiveTranslate's `CLAUDE.md` files section. Each row: file path | one-sentence role description.

- [ ] **Step 3: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "flesh out README and CLAUDE.md docs"
```

---

## Task 15: Optional — push the repo

- [ ] **Step 1: Decide whether to push**

If the user wants this on GitHub or another remote, ask which name. If not, leave it local. Default: local-only until the user requests otherwise.

- [ ] **Step 2 (if pushing):**

```bash
gh repo create al --private --source=. --remote=origin --push
```

Or set a remote manually:

```bash
git remote add origin git@github.com:<user>/al.git
git push -u origin main
```

---

## Done criteria

- `open build/Al.app` shows an ear icon in the menu bar, no Dock entry.
- Start → both streams come up; menu shows `Running (mic+sys)`.
- Speaking into the mic + playing system audio → utterances appear as lines in `~/.al/<stamp>.txt`.
- 5-minute idle gap → a new file is created with the new utterance's stamp.
- 1-hour smoke run with `tail -f /tmp/al.log` shows stable RSS in the hourly heartbeat lines.
- Quit → last utterance is flushed; log ends with `Al: bye`.
- Both `MicSource` config-change restart and `SystemAudioSource` reconnect loop have been observed firing at least once during smoke runs (force a mic device swap; press macOS's "stop sharing" if it surfaces).
