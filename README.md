<p align="center">
  <img src="icon/icon-1024.png" width="128" alt="Whisper icon">
</p>

<h1 align="center">Whisper</h1>

<p align="center">Push-to-talk dictation for macOS. Everything runs on your Mac.</p>

---

Press a hotkey, talk, press it again. Whisper turns your voice into text
on this Mac - no cloud, no account, no telemetry - and your clipboard comes
back the way it was.

## Download

**[Download Whisper.zip](https://github.com/MaxOLeary/whisper/releases/latest/download/Whisper.zip)**

1. Open the zip. Out pops **Whisper**.
2. Drag Whisper into your **Applications** folder.
3. Open it.

<!-- remove after notarization -->
The first open shows a warning: "Apple could not verify Whisper is free of
malware". Click **Done**. Never click **Move to Trash**. Then:

1. Open **System Settings**, then **Privacy & Security**.
2. Scroll down to the **Security** section. Click **Open Anyway** next to
   the line about Whisper.
3. Confirm with Touch ID or your password, then open Whisper again.

That is it, once. Whisper is signed with an in-house certificate, not yet
an Apple one, so macOS can see who signed it but cannot check it against
Apple's list. (Right-clicking the app and choosing Open does not work on
macOS 15 or later, so skip that trick.)

## Requirements

An Apple Silicon Mac on macOS 14 or later. First launch downloads the speech
model (about 460 MB) on its own; the menu bar shows progress. Your first
meeting downloads the summary engine and Llama 3.2 3B (about 2 GB). Nothing
else to install. Everything runs on the Mac, nothing is uploaded.

## Hotkeys

| Press | What happens |
|---|---|
| `⌥ Space` | Start recording. Press again to stop and paste. |
| `⌘ ⌥ ⇧ Space` | Same, but an LLM tidies punctuation and filler words first. |
| `Esc` while recording | Closes the card right away and skips the paste. The take is still transcribed and saved to history and `~/Dictation`. |

Change the keys in Settings → Configuration, or in `~/.config/whisper/config.json`.

## First run

Grant the two permissions macOS asks for: **Accessibility** (hear the hotkey,
press ⌘V for you) and **Microphone**.

Transcription is NVIDIA Parakeet TDT v3 running locally through FluidAudio on
the Apple Neural Engine. Audio stays in RAM and is never written to disk.

## Meetings

Install [Postit](https://github.com/MaxOLeary/postit) and a speech bubble
appears in it. Click it: Whisper's card records the meeting (the footer says
Debrief), and when you stop, Llama writes notes plus the transcript and the
report opens as a Postit sticky. Notes and the audio land in `~/Debrief`
(change it with `meetingNotesDir` in `config.json`).

## Where things go

| Thing | Where |
|---|---|
| Transcripts | `~/Dictation/YYYY-MM.md`, one line per take |
| Per-take stats | `~/Dictation/stats.jsonl` (`ts`, words, audio seconds, app) |
| Meeting notes and audio | `~/Debrief` |
| Settings | `~/.config/whisper/config.json` |
| Summary engine (llama-server) | `~/.config/whisper/llama` |
| Llama 3.2 3B model | `~/.config/whisper/models` |
| Cleanup-mode LLM | `~/.config/whisper/.env` - local Ollama or xAI Grok |
| Vocabulary | `~/.config/whisper/vocabulary.txt` - words Parakeet should favor (off by default) |
| Replacements | `~/.config/whisper/replacements.txt` - `heard -> wanted`, whole words |

Replacements take effect the next time the Settings window is focused. They are plain find-and-replace,
case-insensitive on the left, exact on the right, so `vortex cfd -> VortexCFD`
does not need an LLM. `vocabulary.txt` is unused for now.

**History…** in the menu bar opens the history window. The dropdown also picks the microphone and the mode used by **Toggle Recording**.

## Start at login

Settings → Configuration has a Launch at login toggle. Same thing by hand:

```sh
cp com.maxoleary.whisper.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.maxoleary.whisper.plist
```

## Developer

Building from source needs the Xcode command line tools (`swift`). No Homebrew.

Mac fixes ship with a port note in [`ports/`](ports/README.md). If you have the newest Windows or Linux source, that file tells you how to make the same change, or says the change is Mac-only.

The Windows tray is [`windows/`](windows/README.md). On Windows, Python 3.12+, CMake, and the Visual Studio 2022 C++ build tools, then `pip install -r windows/requirements.txt` and `python windows/app.py`. The first run builds whisper.cpp v1.9.5. Meeting mode is not in that build.

```sh
./build.sh          # builds, signs, installs /Applications/Whisper.app
./build.sh --ship   # also zips, verifies, and uploads the GitHub release
open -a Whisper
```

`--ship` needs the signing cert on this Mac. Always launch with `open -a Whisper`
or from Finder - launched from a terminal, the mic permission lands on the
terminal instead.

Support commands:

```sh
/Applications/Whisper.app/Contents/MacOS/Whisper --ensure       # load Parakeet, print ready, exit
/Applications/Whisper.app/Contents/MacOS/Whisper --ensure-llm   # fetch or reuse llama-server + Llama 3.2 3B
```
