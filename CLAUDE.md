# Al (Always Listen) — context for Claude

A minimal, no-Xcode macOS menu-bar app that continuously transcribes the
microphone and system audio (independently) via sherpa-onnx (Silero VAD +
NeMo Parakeet TDT 0.6B v3 int8 ASR) and appends the resulting text to a
rolling log file under `~/Documents/al/`. No translation, no UI transcript, no
recordings.

> **Process rule for future edits**
>
> Any meaningful change to source layout, data flow, or runtime behavior
> MUST be reflected in this file in the same commit. Add numbered entries
> to "Things that have bitten us" when a real bug bites.

## How it's built

- Pure SwiftPM + pre-built sherpa-onnx dylibs (no Xcode, no CMake).
- `./build.sh` runs `tools/download-sherpa.sh` (idempotent download of
  sherpa-onnx dylibs + models), then `swift build -c release`, then wraps
  the binary into `build/Al.app/`. Use:
  ```sh
  LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh
  ```
  Reusing the same signing identity keeps TCC grants valid across rebuilds
  (grants are keyed on cert identity + bundle ID).
- Launch via `open build/Al.app` — never run the binary directly.

## Architecture

```
  Mic ────▶ RNNoise(mic) ───▶ SherpaEngine.transcribe(.mic) ──┐
                                                               ├─▶ TranscriptWriter
  System ─▶ RNNoise(sys) ───▶ SherpaEngine.transcribe(.system) ┘   (~/Documents/al/<yyyy-MM-dd>/<stamp>.txt,
                                                                     5-min rotation)
                                             ▲
                    Silero VAD (per-stream)  │  Parakeet TDT 0.6B v3 ASR (shared, CoreML)
                    detects speech segments ─┘  transcribes each segment
```

## VAD / ASR

Both streams use Silero VAD (sherpa-onnx, 512-sample chunks at 16 kHz):
- `threshold = 0.5` — speech probability threshold
- `min_silence_duration = 0.5s` — closes segment after 500 ms of silence
- `min_speech_duration = 0.1s` — ignores noise bursts < 100 ms

ASR: NeMo Parakeet TDT 0.6B v3 int8 (ONNX, ~600 MB unpacked), English-only,
CoreML provider (Metal/ANE acceleration on Apple Silicon). Higher accuracy
than Moonshine base, ~4× larger model. If CoreML EP throws on an op,
recognizer init crashes the app at startup — fall back to `provider = "cpu"`
in `SherpaEngine.preloadModel()` and confirm in `/tmp/al.log`.

## Files

| File | Role |
|---|---|
| `main.swift` | NSApplicationMain bootstrap; sets `.accessory` activation policy (no Dock icon). |
| `AppDelegate.swift` | Lifecycle owner. Holds `Pipeline` and `MenuBarController`. Drains pipeline on termination. |
| `MenuBarController.swift` | NSStatusItem with ear.fill SF Symbol. Menu: start/stop, open log, permissions shortcuts, quit. |
| `Pipeline.swift` | Top-level orchestrator. Wires sources→denoiser→engine→writer. Owns hourly RSS heartbeat. |
| `Types.swift` | `SourceTag` (mic/system), `AudioSource` protocol, `Utterance` struct. |
| `MicSource.swift` | AVAudioEngine mic capture, 48 kHz mono Float32. Auto-restarts on config change. |
| `SystemAudioSource.swift` | ScreenCaptureKit system audio capture, 48 kHz mono Float32. Exponential-backoff reconnect. |
| `DenoisingAudioSource.swift` | Wraps any AudioSource, applies RNNoiseProcessor. |
| `RNNoiseProcessor.swift` | Swift wrapper around vendored xiph/rnnoise v0.1.1. |
| `BufferBroadcaster.swift` | Fans AVAudioPCMBuffers out to multiple AsyncStream subscribers. |
| `SherpaEngine.swift` | Silero VAD + Parakeet TDT 0.6B v3 ASR via sherpa-onnx C API. Per-stream VAD, shared ASR model (NSLock). Crosstalk suppression (zeros mic samples when system audio voiced within 250 ms). |
| `TranscriptWriter.swift` | Swift actor. Appends utterance text to `~/Documents/al/<yyyy-MM-dd>/<stamp>.txt`. Rotates on 5-minute idle gap. |
| `Permissions.swift` | Non-prompting TCC status probes for microphone and screen recording. |
| `Log.swift` | Append-only logger to `/tmp/al.log`. Truncates on launch if > 5 MB. |
| `CRNNoise/` | Vendored xiph/rnnoise v0.1.1 (BSD 3-clause). |
| `CSherpa/` | SwiftPM bridge target linking libsherpa-onnx-c-api.dylib from `build/sherpa-prefix/`. |

## Manual smoke test

1. `tccutil reset Microphone local.mtib.al && tccutil reset ScreenCapture local.mtib.al`
2. `LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh && open build/Al.app`
3. Grant both permissions when prompted.
4. Speak a sentence. Shortly after you stop speaking (Silero closes the segment after ~500 ms of silence, then ASR runs), `tail -f /tmp/al.log` should show `SherpaEngine[mic]: "…"`.
5. `cat ~/Documents/al/**/*.txt | tail -5` — lines should appear.
6. Stop, wait 5+ min, Start, speak — a **new file** should appear in `~/Documents/al/<date>/`.
7. Memory check: `ps -o rss,command -p $(pgrep -f 'build/Al.app')` — RSS should plateau (~300 MB).
8. Quit — `/tmp/al.log` ends with `Al: bye`.

## Things that have bitten us

1. **CoreML provider can throw uncatchable C++ exceptions during recognizer
   init.** `Ort::ThrowOnError` → SIGABRT, before any Swift code can catch it.
   Stick with `provider = "cpu"` for transducer models like Parakeet unless
   you've verified every op compiles under CoreML EP.
