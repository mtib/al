# Al — Always Listen

A macOS menu-bar widget that continuously transcribes your microphone and system audio to plain-text log files under `~/.al/`. On-device via whisper.cpp large-v3-turbo; nothing leaves the machine.

Sibling project to [LiveTranslate](../transcrybe-diy/); reuses its RNNoise wrapper, CWhisper bridge, and build scripts.

## What it does

- Two independent capture streams (mic via `AVAudioEngine`, system audio via `ScreenCaptureKit`) each run through RNNoise noise suppression.
- Each stream's audio is voice-activity–detected with a **0.1 s onset gate** (a chunk only opens after 0.1 s of continuous non-silence), closed on **2 s of silence** or a **30 s hard cap**.
- Voiced chunks are transcribed by whisper.cpp large-v3-turbo (on-device, Metal-accelerated).
- Each transcribed chunk is appended as one line to the current log file.
- If more than **5 minutes** have elapsed since the last line, a new file is opened named after the new chunk's start time.
- Both streams interleave into the same file by arrival order.

## Build

```sh
./dev-setup.sh                                           # one-time: install cmake, download model (~570 MB)
LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh  # build + bundle + sign
open build/Al.app                                        # launch (always via open, not direct exec)
```

The build script reuses LiveTranslate's signing-identity env var. Al's bundle ID (`local.mtib.al`) is distinct from LiveTranslate's, so each app gets its own TCC grants. If you don't have a `LiveTranslateDev` cert yet, create one in Keychain Access → Certificate Assistant → Self-Signed Root → Code Signing, name `LiveTranslateDev`.

## Menu

Click the ear icon in the menu bar:

| Item | Behaviour |
|---|---|
| _Idle_ / _Running (mic+sys)_ | Decorative status row. |
| Start / Stop Listening | Toggles the pipeline. Model loads on first Start (~500 ms). |
| Open Current Log | Opens the file being written in the default text editor. |
| Open Log Folder | Opens `~/.al/` in Finder (creates it if needed). |
| Microphone: ✓ / ✗ | TCC status; click to open System Settings → Microphone. |
| System Audio: ✓ / ✗ | TCC status; click to open System Settings → Screen Recording. |
| Quit Al | Drains the pipeline, flushes the file, exits. |

## File format

Plain text. One whisper chunk per line. No timestamps in the body (the filename is the timestamp). No source tag. Both mic and system audio interleave by arrival time.

**Filename:** `~/.al/yyyy-MM-ddTHH-mm-ss.txt` — local time, colons replaced with dashes for shell/CLI compatibility.

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
ls -la ~/.al/                                            # output files
cat ~/.al/*.txt | tail -20                               # recent transcriptions
ps -o rss,command -p $(pgrep -f 'build/Al.app')         # memory usage
pkill -f 'build/Al.app/Contents/MacOS/Al'               # force-quit
```

## Resilience

- **Mic:** auto-restarts the `AVAudioEngine` on `AVAudioEngineConfigurationChange` (device swap, AirPods connect, etc.) with a 200 ms debounce.
- **System audio:** reconnects `SCStream` on `didStopWithError` with exponential backoff (1 → 2 → 4 → … → 30 s). Failure counter resets on first healthy sample.
- **Whisper chunk queue:** capped at 4 pending chunks. If whisper falls behind, oldest chunks are dropped (transcription gaps preferred over OOM).
- **Hourly heartbeat:** logs resident memory to `/tmp/al.log` so long-run memory growth is visible.

## Limitations

- **Crosstalk:** if the mic picks up system audio through the speakers, both streams may produce a line for the same utterance. Acceptable for "log everything"; addressable later with a crosstalk gate.
- **30 s mel context:** whisper.cpp's mel-spectrogram window is 30 s. The hard cap matches this limit; a continuous monologue longer than 30 s without any pause will be split at the cap.
- **Silence hallucinations:** whisper occasionally fabricates phrases ("Thanks for watching!") on near-silent input. Chunks under 1.1 s are filtered; some residual hallucination is possible on very-low-energy audio that passes the onset gate.
