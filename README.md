# Al — Always Listen

A macOS menu-bar widget that continuously transcribes your microphone and system audio to plain-text log files under `~/Documents/al/`. On-device via sherpa-onnx (Silero VAD + Parakeet TDT ASR); nothing leaves the machine.

## What it does

- Two independent capture streams (mic via `AVAudioEngine`, system audio via `ScreenCaptureKit`) each run through RNNoise noise suppression.
- Each stream's audio is resampled to 16 kHz and fed to a per-stream Silero VAD (ONNX). Silero emits speech segments after ~500 ms of post-speech silence.
- Each speech segment is transcribed by NeMo Parakeet TDT 0.6B v3 int8 (ONNX, CPU, English-only, ~600 MB unpacked).
- Each transcribed segment is appended as one line to the current log file.
- If more than **5 minutes** have elapsed since the last line, a new file is opened named after the new segment's start time.
- Both streams interleave into the same file by arrival order.

## Build

```sh
LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh  # downloads models, builds, bundles, signs
open build/Al.app                                        # launch (always via open, not direct exec)
```

`build.sh` calls `tools/download-sherpa.sh` first — that script downloads the sherpa-onnx dylibs (~50 MB) and models (~470 MB, mostly Parakeet) idempotently. Pass `--force` to re-download.

The build script reuses LiveTranslate's signing-identity env var. Al's bundle ID (`local.mtib.al`) is distinct from LiveTranslate's, so each app gets its own TCC grants. If you don't have a `LiveTranslateDev` cert yet, create one in Keychain Access → Certificate Assistant → Self-Signed Root → Code Signing, name `LiveTranslateDev`.

## Menu

Click the ear icon in the menu bar:

| Item | Behaviour |
|---|---|
| _Idle_ / _Running (mic+sys)_ | Decorative status row. |
| Start / Stop Listening | Toggles the pipeline. Model loads on first Start (~1–2 s). |
| Open Current Log | Opens the file being written in the default text editor. |
| Open Log Folder | Opens `~/Documents/al/` in Finder (creates it if needed). |
| Microphone: ✓ / ✗ | TCC status; click to open System Settings → Microphone. |
| System Audio: ✓ / ✗ | TCC status; click to open System Settings → Screen Recording. |
| Quit Al | Drains the pipeline, flushes the file, exits. |

## File format

Plain text. No timestamps in the body (the filename is the timestamp). No source tag. Both mic and system audio interleave by arrival time.

ASR segments arriving within **3 seconds** of each other are space-joined on the same line. A new line starts when there is a gap longer than 3 seconds. A new file opens after **5 minutes** of silence.

**Filename:** `~/Documents/al/yyyy-MM-dd/yyyy-MM-ddTHH-mm-ss.txt` — local time, colons replaced with dashes for shell/CLI compatibility.

## Permissions

On first Start, macOS prompts for:
- **Microphone** — mic transcription
- **Screen Recording** — system audio capture via ScreenCaptureKit (no video frames are retained)

Both prompts use the usage descriptions from `Info.plist`. Grants persist across rebuilds when `LIVETRANSLATE_SIGN_IDENTITY` is set (TCC keys on certificate identity, not binary hash).

Reset grants:
```sh
tccutil reset Microphone local.mtib.al
tccutil reset ScreenCapture local.mtib.al
```

## Debug

```sh
tail -f /tmp/al.log                                      # real-time internal log
ls -la ~/Documents/al/                                            # output folders by date
find ~/Documents/al -name '*.txt' | xargs tail -5                 # recent transcriptions
ps -o rss,command -p $(pgrep -f 'build/Al.app')         # memory usage (~300 MB expected)
pkill -f 'build/Al.app/Contents/MacOS/Al'               # force-quit
```

## Resilience

- **Mic:** auto-restarts the `AVAudioEngine` on `AVAudioEngineConfigurationChange` (device swap, AirPods connect, etc.) with a 200 ms debounce.
- **System audio:** reconnects `SCStream` on `didStopWithError` with exponential backoff (1 → 2 → 4 → … → 30 s). Failure counter resets on first healthy sample.
- **Crosstalk suppression:** mic samples are zeroed when system audio RMS exceeds threshold within the last 250 ms.
- **Hourly heartbeat:** logs resident memory to `/tmp/al.log` so long-run memory growth is visible.
