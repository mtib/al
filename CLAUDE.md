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
- `endChunkAfterSilence = 2.0` — close chunk after 2s of silence
- `maxChunkSeconds = 30.0` — hard cap regardless of silence
- `minWhisperInputSeconds = 1.1` — pad short chunks; drop if zero voice detected
- Between chunks: RMS monitoring only, no buffer accumulation

## Files

(Filled in per task as files are created.)

## Things that have bitten us

(Empty — add when bugs bite.)
