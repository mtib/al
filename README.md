# Al — Always Listen

A macOS menu-bar widget that continuously transcribes your microphone
and system audio to plain-text log files under `~/.al/`. On-device via
whisper.cpp; nothing leaves the machine.

## Build

```sh
./dev-setup.sh                                       # one-time: caches model
LIVETRANSLATE_SIGN_IDENTITY=LiveTranslateDev ./build.sh
open build/Al.app
```

(Full README in final task.)
