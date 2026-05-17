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
  to reuse the existing self-signed cert (keeps TCC grants across rebuilds).
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

## VAD Chunking Rules

Both streams use identical RMS-based VAD chunking in WhisperEngine:
- `onsetSeconds = 0.1` — chunk only opens after 0.1s of consecutive voiced frames; those frames are included in the chunk
- `endChunkAfterSilence = 1.0` — close chunk after 1s of silence
- `maxChunkSeconds = 10.0` — hard cap regardless of silence
- `minWhisperInputSeconds = 1.1` — pad short chunks; drop if zero voice detected
- Between chunks: RMS monitoring only, no buffer accumulation

## Files

| File | Role |
|---|---|
| `main.swift` | NSApplicationMain bootstrap; sets `.accessory` activation policy (no Dock icon). |
| `AppDelegate.swift` | Lifecycle owner. Holds `Pipeline` and `MenuBarController`. Drains pipeline on termination. |
| `MenuBarController.swift` | `NSStatusItem` with ear.fill SF Symbol. Menu: start/stop, open log, permissions shortcuts, quit. Refreshes permission status on every menu open. |
| `Pipeline.swift` | Top-level orchestrator. Wires sources→denoiser→engine→writer. Owns hourly RSS heartbeat. Shutdown: stop sources → await task group drain → flush writer → unload model. |
| `Types.swift` | `SourceTag` (mic/system), `AudioSource` protocol, `Utterance` struct. |
| `MicSource.swift` | `AVAudioEngine` mic capture, 48 kHz mono Float32. Auto-restarts on `AVAudioEngineConfigurationChange` (200 ms debounce, exponential retry). |
| `SystemAudioSource.swift` | `ScreenCaptureKit` system audio capture, 48 kHz mono Float32. Reconnects on `didStopWithError` with exponential backoff (capped at 30 s); resets counter on first healthy sample. |
| `DenoisingAudioSource.swift` | Wraps any `AudioSource`, applies `RNNoiseProcessor`, re-broadcasts denoised 48 kHz Float32. One denoiser instance per stream. |
| `RNNoiseProcessor.swift` | Swift wrapper around vendored xiph/rnnoise v0.1.1. Buffers arbitrary input into 480-sample frames at 48 kHz; ±32768 ↔ ±1 scaling. |
| `BufferBroadcaster.swift` | Fans `AVAudioPCMBuffer`s out to multiple `AsyncStream` subscribers. `finishAll()` closes all active subscriptions. |
| `WhisperEngine.swift` | RMS VAD chunker + whisper.cpp transcriber. MONITORING/ACTIVE state machine: 0.1 s onset gate, 2 s silence close, 30 s hard cap, 1.1 s minimum. Shared `whisper_context` serialized with NSLock. Per-source `initial_prompt` continuity. Bounded chunk queue (max 4, drop-oldest). `preloadModel()` / `unloadModel()` for explicit memory control. |
| `TranscriptWriter.swift` | Swift `actor`. Appends utterance text to `~/.al/<stamp>.txt`. Rotates to a new file on 5-minute idle gap. Lazy directory creation. Retry-once on write failure. |
| `Permissions.swift` | Non-prompting TCC status probes for microphone and screen recording. |
| `Log.swift` | Append-only logger to `/tmp/al.log`. Truncates on launch if > 5 MB. |
| `CRNNoise/` | Vendored xiph/rnnoise v0.1.1 (BSD 3-clause; GRU weights in `rnn_data.c`). |
| `CWhisper/` | SwiftPM bridge target linking `libwhisper.a` + `libggml*.a` from `build/whisper-prefix/`. |

## Manual smoke test

Re-run after meaningful pipeline changes.

1. `tccutil reset Microphone local.mtib.al && tccutil reset ScreenCapture local.mtib.al`
2. `LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh && open build/Al.app`
3. Click ear icon → **Start Listening**. Grant both permissions when prompted.
4. Speak a sentence. Play a YouTube clip with speech. After 2+ s of silence, `tail -f /tmp/al.log` should show a chunk closing and `TranscriptWriter: opened …`.
5. `cat ~/.al/*.txt | tail -5` — lines should appear.
6. Stop, wait 5+ min, Start, speak — a **new file** should appear in `~/.al/`.
7. Memory check after 30 min: `ps -o rss,command -p $(pgrep -f 'build/Al.app')` — RSS should plateau (model loaded into Metal, ~2 GB total).
8. Quit — `/tmp/al.log` ends with `Al: bye`.

## Things that have bitten us

(Empty — add when bugs bite.)
