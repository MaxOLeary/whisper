# Whisper speed

Goal:
Tap Option+Space, talk, tap Option+Space again, and the text pastes with no wait that grows with how long you spoke. Two words and a few sentences should feel the same. Superwhisper-class stop-to-paste, still fully local Parakeet.

Out of scope:
- Hold-to-talk, Fn, or key-release-to-paste. Record hotkey is tap to start, tap again to stop and paste.
- Live words on the card (later, after paste is fast)
- Parakeet EOU 120M as the default model (worse accuracy than TDT)
- Cloud STT, LLM cleanup changes, vocabulary/hotwords work
- Sherpa thread-count, wav I/O, or other side-path cuts sold as the speed fix
- **sherpa-onnx / k2-fsa is banned** (PRC origin). Do not keep it as engine or fallback. Replacement is FluidAudio (Fluid Inference, US) running NVIDIA Parakeet TDT on Apple Neural Engine.

Architecture (short):
In-process FluidAudio CoreML (NVIDIA Parakeet TDT v3 on the Apple Neural Engine). Capture grows a live sample stream. A serial segmenter on `whisper.work` closes a chunk on ~2s of trailing silence or a 15s cap and decodes that slice while talking. Second Option+Space finishes the tail, pastes via clipboard + Cmd+V, then a 350ms timer on main restores the clipboard. SwiftPM build. No sherpa, no websocket, no Proxy.swift.

Hotkey: tap `recordHotkey` starts, tap again stops and pastes. Do not rewrite `~/.config/whisper/config.json`. Change `Config.defaults.recordHotkey` to `alt+space` for new installs only. Cleanup chord stays as it is. Esc while recording closes the card immediately (no confirm), still transcribes and saves, does not paste.

Stages:
- [x] 1. Decode while talking. Capture grows a live sample stream. A serial segmenter on `whisper.work` closes a chunk on ~2s of trailing silence (with a voiced-audio minimum so noise does not fire) or a 15s cap, whichever first, and decodes that slice. Join segment texts with spaces. Second Option+Space closes the tail (drop a trailing unvoiced bit shorter than ~250ms), waits for the in-flight queue, pastes the joined text, hides the card. If any segment throws or returns empty when the audio was voiced, fall back once to a full-buffer `transcribe(samples)` so a take is never lost. Esc discard still drops the take and cancels queued work.
- [x] 2. Paste without blocking 350ms. `paste(_:)` still snapshots the clipboard, writes the transcript, posts Cmd+V. Restore the old clipboard on a later timer (start at 350ms, not on the transcription thread). Do not `Thread.sleep` in `paste`. Two-word takes must not wait on restore before the user can type.
- [x] 3. In-process FluidAudio CoreML (Parakeet TDT, Apple Neural Engine). Drop the sherpa websocket server, `Proxy.swift` loopback, and `sandbox-exec`. Same tap-toggle, same segmenter. `build.sh` becomes SwiftPM (or an equivalent that still produces `/Applications/Whisper.app` signed with "Postit Dev"). Whisper fallback stays for when Parakeet files are missing.

Verification (how we will know each stage worked):
- 1. Two-word take still pastes fast. A 4–5 sentence take pastes in well under a second after the second Option+Space. Log shows most decode ms overlapped the recording. Esc discard still works. Failed segment still pastes via full-buffer fallback. No FluidAudio in the binary.
- 2. Text is in the focused app before clipboard restore. Previous clipboard contents come back. No 350ms stall after paste.
- 3. Same Option+Space UX. `asr=` on a short take is lower than sherpa. `pgrep` shows no `sherpa-onnx-offline-websocket-server` while the app is running.

Current stage: done

---

# Whisper front end

Goal:
A Superwhisper-style front end for Whisper, matching the three screenshots (menu bar dropdown, settings window with sidebar, history page) but simplified: no Modes, no Vocabulary, no Models library. Menu bar dropdown: Toggle Recording, History..., Settings... (⌘,), a microphone submenu, a mode submenu, version line, Quit. Settings window: full-height dark sidebar with Home, Configuration, Sound, History; mic name in the top-right of the toolbar. History page: search box, takes grouped by Today / Yesterday / date as rounded cards, click to copy. Home page: stats tiles (Average speed, Words, Apps used, Time saved) with an All time / This month / Today picker, and a "Get started" list that deep-links into the other pages. Looks the same as the screenshots; ours just has fewer rows.

Out of scope:
- Modes, Vocabulary, Models library pages and any "Create a mode" / "Add vocabulary" rows
- Transcribe File..., Check for Updates..., "What's new?" changelog, Pro badge
- Deleting or editing history entries (the md log is append-only)
- Changing the `~/Dictation/YYYY-MM.md` line format (Obsidian reads it as-is)
- Any cloud feature. Cleanup-mode LLM config stays a `.env` file; the UI only opens it.
- SMAppService "Open at Login" (the global rule is a LaunchAgent; the toggle manages that plist)
- Touching the record/transcribe pipeline (speed spec above owns it; its stage 2 is still open and independent of this build)

Architecture (short):
AppKit app stays the brain (`main.swift`: hotkeys, capture, engine, paste, menu). New SwiftUI views hosted in one `NSWindow` via `NSHostingController`, opened from the menu. One `AppStore: ObservableObject` (state, config, history, stats, mic list) is the bridge; `App` writes to it on the main thread, views only read it and call back into `App` through the store's closures. Files: `UI/SettingsWindow.swift` (window controller + `NavigationSplitView` sidebar + toolbar), `UI/HomeView.swift`, `UI/HistoryView.swift`, `UI/ConfigurationView.swift`, `UI/SoundView.swift`, `Stats.swift`. History is parsed from every `~/Dictation/*.md`. Per-take stats go to a new sidecar `~/Dictation/stats.jsonl` (`{ts, words, seconds, app}`) written next to `log()`; older takes count for words/takes only. Config writes go through one `Config.save(patch:)` that loads `config.json` as a dictionary, merges changed keys, and writes it back so unknown or hand-edited keys survive; then `reloadConfig()` runs so hotkeys and the engine pick it up live. Window: `.fullSizeContentView`, hidden title, transparent toolbar, sidebar material, 900x620 default, remembers frame. System appearance (dark in the screenshots).

Stages:
- [x] 1. Window shell + menu. `UI/SettingsWindow.swift` with the sidebar (Home, Configuration, Sound, History; SF Symbols in colored rounded squares like the screenshot: house/orange, gearshape/gray, speaker.wave.2/gray, clock.arrow.circlepath/purple), placeholder pages, mic name + laptop icon top-right, sidebar footer "Whisper" + version pill. `AppStore` created and wired to `App` state. Menu bar dropdown rewritten to: Toggle Recording · History... · Settings... ⌘, · separator · mic submenu (every `AVCaptureDevice` audio input, check on `cfg.audioDevice`, picking one saves config) · mode submenu (Plain / Cleanup: which mode Toggle Recording uses) · separator · "Version x.y" disabled · Quit ⌘Q. The inline last-10 transcripts, Open Dictation Folder, Open Config Folder, Reload Config, Download model rows leave the menu (they move into pages in stage 3). History... opens the window on the History tab. Idle/recording/transcribing icon tint stays.
- [x] 2. History page. Parser over all `~/Dictation/*.md` files into `[Transcript]` newest first (reuse the `- **stamp** text` line rule from `loadHistory`). Search field in the toolbar area filters live (case-insensitive substring). Groups: Today, Yesterday, then "Mon, Sep 8" style, newest first. Card per take: rounded 14pt, subtle fill, text clamped to 2 lines, hover shows the time on the right and a copy icon, click copies and flashes "Copied". Right-click: Copy, Reveal in Finder (the month file). Window refreshes after every new take (store publishes). Empty state: "No takes yet. Press ⌥ Space to dictate." Performance: 5k lines parse under 100 ms on the M1 Air.
- [x] 3. Configuration + Sound pages, config writer. `Config.save(patch:)` as described. Configuration: Shortcuts group (Record, Cleanup: a hotkey-recorder control that shows keycaps and captures the next chord; Esc cancels), Microphone picker (same list as the menu), Language, Ignore taps shorter than (seconds stepper), Cleanup prompt (multi-line editor), Files group with "Open" buttons for `replacements.txt`, `.env`, the config folder, and the Dictation folder, Launch at login toggle (installs / removes `~/Library/LaunchAgents/com.maxoleary.whisper.plist` via `launchctl bootstrap` / `bootout`, reflects current state on open), and the whisper-fallback model download button only when engine is whisper and the file is missing. Sound: Sounds on/off, Start sound and Stop sound pickers (system sounds from `/System/Library/Sounds` plus "None"), play button next to each; new config keys `startSound` / `stopSound` (defaults Tink / Pop), `main.swift` reads them. Every change saves immediately and calls `reloadConfig()`.
- [x] 4. Home page + stats. `Stats.swift`: append one JSON line per pasted or saved take with word count, audio seconds, and the frontmost app's bundle name at paste time; reader aggregates by range (All time / This month / Today, a menu-style picker like the screenshot). Tiles: Average speed (words ÷ speech minutes), Words (total, includes pre-sidecar takes from the md files), Apps used (distinct apps), Time saved (words at 40 WPM typing minus speaking time, shown as "11 hours" / "42 min"). "Get started" rows: Start recording (record chord as keycaps on the right), Customize your shortcuts (opens Configuration), Pick your sounds (opens Sound), Browse your history (opens History). No "What's new?".

Verification (how we will know each stage worked):
- 1. Menu matches the first screenshot minus Transcribe File and Check for Updates. Settings... and ⌘, open the window; History... opens it on History. Picking a mic in the submenu changes `audioDevice` in `config.json` and the next take records from it. Window side by side with the Superwhisper screenshot: same sidebar width, same icon style, same footer. Dictation still works exactly as before.
- 2. Every line in every month file shows up once, newest first, in the right day group. Typing in search narrows instantly. Click copies the full text (paste it somewhere). A new take appears at the top without reopening the window.
- 3. Change the record chord in the UI, press the new chord: it records. `config.json` keeps a hand-added unknown key after a UI save. Launch at login toggle on: `launchctl print gui/$UID/com.maxoleary.whisper` lists it; off: it does not. Sound pickers: play button plays; a take uses the chosen start/stop sounds.
- 4. After three takes the tiles change; switching All time / Today changes them; Words for All time equals the word count of all md lines. Get started rows land on the right page.

Current stage: done

---

# Whisper compact visualizer

Goal:
On the existing waveform card, a small up/down control. Up collapses the visualizer into Superwhisper-style small mode: a frosted capsule docked at the top of the screen, semi-transparent, sitting in the chrome so you can keep working. Down restores the full 428x120 card. Recording and transcribing keep going either size. Next take opens in the last size you used.

Refs: Superwhisper screen recordings from 2026-09-15 (`1.15.11`, `1.17.22`) and screenshots `1.15.30`, `1.15.50`, `1.16.16`. Idle pill is five dots, flush with the top of the display, overlapping the menu bar / Safari tabs. Hover on Superwhisper grows extra buttons; ours does not copy those.

Out of scope:
- Always-on HUD when idle. The pill exists only while the visualizer is up (recording or transcribing). Hide still hides.
- Superwhisper's hover toolbar (Change mode, Start recording, Expand window). Compact hover only reveals the down-chevron.
- Live words on the card
- A settings-window toggle (`UserDefaults` is enough)
- Changing the full card's default position
- Record/transcribe pipeline, `config.json`, settings pages

Architecture (short):
Same `WavePanel` morphs. Do not spawn a second window. Resize the actual frame so a 428x120 window with a transparent hole cannot steal clicks on the tabs around the pill. `WaveView` draws compact as 5-7 live bars in a short band (mic level while recording, existing ripple while transcribing) and skips the footer. Dim chevron-up at the top-right of the full card; brightens on hover; click collapses. Compact: ~100x28, corner radius = half height, same `hudWindow` + dark wash + hairline. Not draggable. `place()` docks it top-center using `screen.frame` (not `visibleFrame`) so it overlaps the menu bar. Full card still uses saved `panelOrigin` and stays draggable. Persist `panelCompact` in `UserDefaults`; `show()` reads it. Meeting mode shares the panel, so it gets the same toggle. Files: `Panel.swift` only unless `show()` needs a one-line hook from `main.swift`.

Stages:
- [x] 1. Compact/full on `WavePanel`. Chevron, morph, top-dock, persist, dictation + meeting.

Verification (how we will know each stage worked):
- 1. Option+Space, click up: pill sits at the top of the screen over the tab bar, bars still move while you talk, tabs around it stay clickable. Click down: full card returns at its old spot. Next take opens compact. Esc still hides. Debrief meeting card does the same. After `./build.sh`, `Panel.swift.o` mtime is newer than `Panel.swift` (incremental release has skipped this file before).

Current stage: done

---

# Whisper notch pill

Goal:
Replace the frosted 100x28 compact pill with Superwhisper's notch pill: one black window at the top-center of the screen that changes shape through four states. Mockup (approved 2026-09-16, gear instead of sparkle): `mockups/notch-pill.html`. Reference screenshots: Desktop `Screenshot 2026-09-16 at 12.35.*.png`.

Out of scope:
- The full 428x120 card. It stays exactly as is (frosted, draggable, footer, chevron-up collapses to the pill).
- Live words on the pill, a mode picker on the pill, any settings UI for the pill.
- Record / transcribe / paste pipeline, `config.json`.

Architecture (short):
Same `WavePanel`, no second window. `compact == true` now means "pill mode"; `panelCompact` in `UserDefaults` still remembers it and the full card's chevron-up still switches into it. New `PillState` enum on `WaveView`: `idle`, `action`, `rec`, `mini`, `busy`. All pill states are horizontally centered on `screen.frame.midX` and flush with `screen.frame.maxY` (over the notch / hidden menu bar), placed on the screen under the mouse at show time and on `NSScreen.main` for the always-on idle. Corner radius is always half the height. All sizes in points:

- `idle`  44x8, top inset 8. Translucent capsule: white 18% fill, 1pt ring at white 35%. No blur, no shadow. Stays on screen whenever pill mode is on and nothing is recording (this replaces "hidden when not recording"). Not draggable.
- `action` 116x38 opaque black (`white: 0.04`), top inset 5, no window shadow. Opens while the mouse is over the capsule (damped spring, ~4% overshoot, 0.46s) and closes after the cursor has been off it for 0.2s (0.28s ease-in-out), with a 20Hz cursor poll as the closer. Three 30pt hit discs, 40pt apart, icons white 92%, hovered one 100% on a white-22% disc: `gearshape` (Settings), the Whisper five-bar glyph (Record), `arrow.up.left.and.arrow.down.right` (Expand = switch to the full card; with no take running the card is put away and the next take opens as the card). Lingering 0.7s on a button shows a hint in a small child window 4pt under the bar: near-black rounded box, 13pt text: "Settings", "Record  ⌥ Space" (the record hotkey as keycaps), "Expand window". Engine / meeting status text rides in the same hint under the rec/busy pill.
- `rec` 116x38 opaque black, top inset 5. Left: 30pt disc, 4pt in from the left edge, fill coral `#ef5b4a` at 32%, the five-bar glyph in full coral at 13pt. Clicking the disc = Stop. Right: ticker of 22 1.5pt white bars on a 3pt pitch, centered in the remaining width, bar alpha fading 45% -> 100% left to right. Ticker advances one bar every 3rd frame at 60fps. Clicking anywhere except the disc shrinks to `mini`.
- `mini` 54x22 opaque black, top inset 5. Six live 2pt bars on a 4pt pitch, symmetric bell shape scaled by the eased mic level, white 100%. Click grows back to `rec`. Persist `pillMini` in `UserDefaults` so the next take opens in the last of `rec` / `mini`.
- `busy` (transcribing / loading model) keeps the `rec` or `mini` shape; disc goes white 12% with the glyph white 55%, bars run the existing transcribing ripple. `hide()` in pill mode animates to `idle` instead of `orderOut`. `hide()` in full-card mode is unchanged.

Drawing: the pill states must not sit on `hudWindow` material. Keep `PillEffectView` for the full card; in pill mode it must leave the view hierarchy entirely (hidden is not enough: a behind-window blur keeps shaping the window with its mask, which drew lens-shaped pills) so `idle` is a translucent capsule and the others are solid black. In pill mode the window is one fixed 132x48 box flush with the top of the screen and never resizes; the capsule (`WaveView.shape`) is animated inside it by a `CADisplayLink` (`morphTick`), because resizing the window per frame went through the window server and flickered. Fill and contents crossfade with the shape only when idle is one end of the morph; black-to-black morphs stay solid. Hover via an `NSTrackingArea` on the whole box (`activeAlways`, `mouseEnteredAndExited`, `mouseMoved`), with every cursor check against the drawn capsule, not the window. The panel stays `nonactivatingPanel`; clicking a button must not bring Whisper to the front, and Ghostty keeps focus.

Wiring: `WavePanel` gets three closures set from `main.swift`: `onRecord` (calls `toggleRecording()`), `onStop` (calls `toggleRecording()` too, which already picks meeting vs dictation stop), `onSettings` (calls `openSettings()`). Esc behavior unchanged. At launch, if `panelCompact` is true, show the idle pill. `startRecording` in pill mode morphs `idle` -> `rec`/`mini` in place. Meeting mode uses the same pill.

Stages:
- [x] 1. `Panel.swift`: `PillState`, geometry, drawing (outline, black fill, disc, glyph, icons, both tickers), hover tracking, click routing through the three closures, morph animations, `hide()` -> `idle`, `pillMini` persistence. Full card untouched. Compiles with the closures unset.
- [x] 2. `main.swift` wiring: set the closures, show the idle pill at launch when `panelCompact`, `startRecording` / `stopRecording` / meeting paths keep working through the pill. `./build.sh`, install, launch with `open -a`.

Verification (how we will know each stage worked):
- 1. `./build.sh` passes; `Panel.swift.o` mtime is newer than `Panel.swift`. Reading the diff: the full-card code paths are byte-for-byte the same except where the chevron hands off to pill mode.
- 2. App running with pill mode on: a faint outline sits top-center with nothing else showing. Hover: black bar with gear / bars / expand; mouse away: outline again. Click bars: Tink, red disc + moving ticker, no focus change in Ghostty. Click the ticker: shrinks to six bars; click again: grows. Click the disc: Pop, disc goes grey while transcribing, text pastes, pill fades back to the outline. Hotkey start/stop and Esc do the same things. Expand: the full 428x120 card at its old spot; chevron-up on the card: back to the outline. Quit and relaunch: pill comes back in the state it was left in. Debrief meeting: same pill, disc click ends the meeting.

Current stage: done (built + installed 2026-09-16; second pass same day: smaller pills, top inset, instant hover close, hover hints; third pass 2026-09-17: fixed-size 132x48 pill window with the capsule animated inside it via CADisplayLink, spring open, hover-delayed Superwhisper-style hint, idle 44x8, action/rec 116 wide, hint dismissed on expand/take)
