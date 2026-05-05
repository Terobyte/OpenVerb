<div align="center">

<img src="assets/openverb-app-icon-v2.svg" alt="OpenVerb" width="128" height="128" />

# OpenVerb

**Press a hotkey, talk, get text — anywhere on macOS, fully offline.**

```bash
npm install -g openverb-app
```

[![npm](https://img.shields.io/npm/v/openverb-app.svg?color=cb3837&logo=npm)](https://www.npmjs.com/package/openverb-app)
[![License: MIT](https://img.shields.io/badge/License-MIT-19E2D7.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-13+-black?logo=apple)]()
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-7C5CFF)]()

<img src="assets/screenshots/hud-processing.png" alt="OpenVerb HUD streaming a transcript" width="640" />

</div>

That's the whole install. The `npm` postinstall hook fetches the source, builds the C++ engine, downloads the Gemma 4 weights, sets up a stable code-signing identity in your login keychain, and copies `OpenVerb.app` into `/Applications`. ~5 minutes on a clean machine.

## Why OpenVerb (vs Superwhisper, Wispr, Whisper Flow)

|  | OpenVerb | Cloud dictation tools |
|--|--|--|
| **Price** | Free, MIT | $5–25 / month |
| **Audio leaves your laptop** | Never | Yes — every word is a `POST` |
| **Brains** | **One model.** Gemma 4 transcribes *and* polishes. | **Two.** Whisper for transcription, GPT‑4o for polish. |
| **RAM** | ~3 GB resident | ~6 GB (two model loads) |
| **Works on a plane** | Yes | No |
| **Apple Developer account needed** | No | n/a |
| **Source available** | Yes | No |

> **The "one brain" thing matters.** Competitors transcribe with Whisper, then ship the text to GPT‑4o for cleanup. That's two model loads, two privacy boundaries, two latency hops, and one cloud round‑trip. OpenVerb uses Gemma 4 E2B — Google's audio + text Gemma — for both. Half the RAM, no API hop, no subscription.

<div align="center">
<img src="assets/screenshots/hud-recording.png" alt="Recording HUD" width="560" />
<br/><br/>
<img src="assets/screenshots/preferences.png" alt="OpenVerb Preferences" width="640" />
</div>

## Requirements

| | |
|--|--|
| **macOS** | 13.0 Ventura or newer |
| **CPU** | Apple Silicon (M1/M2/M3/M4). Intel is not supported. |
| **RAM** | 8 GB minimum, 16 GB recommended |
| **Disk** | ~6 GB for the model weights |
| **Node.js** | any recent version (just for the install command) |
| **Permissions** | Microphone, Accessibility, Input Monitoring (granted on first launch) |

## Usage

| Action | Default shortcut |
|--|--|
| Start / stop dictation | `⌥Space` |
| Cancel current recording | `Esc` |
| Open settings | menu bar → ⚙ |

CLI:

```bash
ov              # launch the app (installs first if not yet installed)
ov update       # fetch latest source and rebuild
ov uninstall    # remove /Applications/OpenVerb.app
```

Don't have / want Node? Build directly from source — see [`BUILD.md`](BUILD.md).

## Privacy

- No network calls at runtime. Block OpenVerb at the firewall and it works exactly the same.
- No analytics, crash reporters, or "anonymous usage stats."
- Audio buffers are in memory only and zeroed when a session ends.

The only network call ever made is the one‑time model download from Hugging Face during install.

## Acknowledgements

- [`llama.cpp`](https://github.com/ggml-org/llama.cpp) — the C++ inference engine
- [Google Gemma](https://blog.google/technology/developers/gemma-3/) — the audio + text model family
- [WebRTC VAD](https://webrtc.org/) — voice activity detection

## License

MIT. See [`LICENSE`](LICENSE).
