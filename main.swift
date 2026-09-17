// Whisper - local push-to-talk dictation for macOS.
//
// Tap the hotkey, talk, tap again. Mic PCM (AVAudioEngine, 16 kHz in RAM) is
// segmented on pauses and decoded while you speak (FluidAudio Parakeet TDT
// on the Neural Engine), then pasted via clipboard -> Cmd+V into whatever
// has focus, then the old clipboard comes back.
// Everything runs on this Mac; nothing leaves it unless you opt into
// cleanup mode in ~/.config/whisper/.env (local Ollama, or xAI Grok —
// never OpenAI/Google/Anthropic endpoints).
//
// Build: ./build.sh   (see README.md)

import AppKit
import AVFoundation
import Foundation

// MARK: - Config

struct Config: Codable {
    var modelPath: String
    var ffmpegPath: String
    var whisperPath: String
    var audioDevice: String      // mic localizedName as shown in the menu; "" or "0" = system default
    var threads: Int
    var serverPort: Int          // whisper-server keeps the model warm in RAM
    var language: String
    var recordHotkey: String     // e.g. "cmd+alt+space", or "ralt" for right Option alone
    var cleanupHotkey: String    // e.g. "cmd+alt+shift+space"
    var sounds: Bool
    var minSeconds: Double       // ignore taps shorter than this
    var cleanupPrompt: String
    // Optional so an older config.json still decodes; nil means the default.
    var startSound: String?      // system sound name; nil = Tink; "" / "none" = silent
    var stopSound: String?       // nil = Pop
    var engine: String?          // "parakeet" (default) or "whisper"
    var parakeetModel: String?   // folder under models/; nil = best installed build
    var hotwordsScore: Double?   // set (e.g. 1) to turn on vocabulary.txt hotwords; nil = off
    var meetingNotesDir: String? // Meeting notes folder; nil = ~/Debrief

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/whisper", isDirectory: true)
    static let file = dir.appendingPathComponent("config.json")
    static let envFile = dir.appendingPathComponent(".env")
    static let modelsDir = dir.appendingPathComponent("models", isDirectory: true)
    static let vocabularyFile = dir.appendingPathComponent("vocabulary.txt")
    static let hotwordsFile = dir.appendingPathComponent(".hotwords")   // generated from vocabulary.txt
    static let replacementsFile = dir.appendingPathComponent("replacements.txt")

    var engineName: String { engine ?? "parakeet" }

    static var defaults: Config {
        Config(
            modelPath: modelsDir.appendingPathComponent("ggml-base.en.bin").path,
            ffmpegPath: "/opt/homebrew/bin/ffmpeg",
            whisperPath: "/opt/homebrew/bin/whisper-cli",
            audioDevice: "0",
            threads: 4,
            serverPort: 8765,
            language: "en",
            recordHotkey: "alt+space",
            cleanupHotkey: "cmd+alt+shift+space",
            sounds: true,
            minSeconds: 0.35,
            cleanupPrompt: "You clean up voice dictation. Fix punctuation and capitalization, "
                + "remove filler words (um, uh, like, you know), fix obvious transcription "
                + "slips, keep the speaker's wording and meaning otherwise. Return only the "
                + "cleaned text, no commentary, no quotes.",
            startSound: "Tink",
            stopSound: "Pop",
            engine: "parakeet"
        )
    }

    /// System sound name to play, or "" for silence. Missing key uses `fallback`.
    static func soundName(_ stored: String?, fallback: String) -> String {
        guard let stored else { return fallback }
        let s = stored.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.lowercased() == "none" { return "" }
        return s
    }

    /// replacements.txt: one `heard -> wanted` per line, # comments allowed.
    /// The left side matches whole words, ignoring case; the right side is
    /// pasted exactly. Plain find-and-replace, no AI, so it only ever touches
    /// the words you listed.
    static func loadReplacements() -> [(NSRegularExpression, String)] {
        var rules: [(NSRegularExpression, String)] = []
        for t in lines(of: replacementsFile) {
            guard let arrow = t.range(of: "->") else { continue }
            let from = t[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let to = t[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty else { continue }
            // \b needs a word character on each side; fall back to plain lookarounds for things like "c++".
            let pat = "(?<![\\w])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\w])"
            if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                rules.append((re, NSRegularExpression.escapedTemplate(for: to)))
            }
        }
        return rules
    }

    static func applyReplacements(_ rules: [(NSRegularExpression, String)], to text: String) -> String {
        var out = text
        for (re, template) in rules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }

    /// Starter files, written once alongside the first config.json so the
    /// folder explains itself. Deleting one later keeps it gone.
    static func writeTemplates() {
        let templates = [
            (vocabularyFile, """
            # Words Parakeet should lean toward when unsure. One per line.
            # Unused until FluidAudio vocabulary boosting is wired. See README.
            Whisper

            """),
            (replacementsFile, """
            # Plain find-and-replace on every take: heard -> wanted
            # Left side matches whole words, any capitalization. No AI involved.
            vortex cfd -> VortexCFD

            """),
        ]
        for (url, text) in templates where !FileManager.default.fileExists(atPath: url.path) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = defaults
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(cfg) { try? data.write(to: file) }
        writeTemplates()
        return cfg
    }

    /// Merge a few keys into config.json without touching anything else in
    /// it, so hand-edited or unknown keys survive a UI save. If the file is
    /// missing or not valid JSON right now, start from `current` (the config
    /// the app is running with) instead of an empty dict, so a later load()
    /// can never fall back to defaults because of a UI save.
    static func save(patch: [String: Any], current: Config) {
        var dict = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        if dict == nil, let data = try? JSONEncoder().encode(current) {
            dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        var out = dict ?? [:]
        for (k, v) in patch { out[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: out,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Non-blank, non-comment lines of a text file, trimmed. Missing file = [].
    static func lines(of url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Reads KEY=VALUE lines from ~/.config/whisper/.env (no accounts, no telemetry).
    static func env() -> [String: String] {
        var out: [String: String] = [:]
        for line in lines(of: envFile) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v
        }
        return out
    }
}

// MARK: - Hotkey parsing

/// A chord: some modifiers plus (optionally) one key. With no key it's a
/// modifier-only chord like "ralt" (hold right Option).
struct Hotkey {
    var flags: CGEventFlags = []          // generic modifiers (cmd/alt/shift/ctrl)
    var deviceBits: UInt64 = 0            // left/right-specific bits (e.g. right Option)
    var keyCode: Int64? = nil

    static let keyCodes: [String: Int64] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53,
        "delete": 51, "backspace": 51, "grave": 50, "`": 50, "minus": 27, "equal": 24,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    // NX_DEVICE*KEYMASK bits, the left/right-specific modifier flags.
    static let lcmd: UInt64 = 0x08, rcmd: UInt64 = 0x10
    static let lalt: UInt64 = 0x20, ralt: UInt64 = 0x40
    static let lshift: UInt64 = 0x02, rshift: UInt64 = 0x04
    static let lctrl: UInt64 = 0x01, rctrl: UInt64 = 0x2000

    static func parse(_ s: String) -> Hotkey? {
        var hk = Hotkey()
        for tok in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch tok {
            case "cmd", "command", "meta": hk.flags.insert(.maskCommand)
            case "alt", "opt", "option": hk.flags.insert(.maskAlternate)
            case "shift": hk.flags.insert(.maskShift)
            case "ctrl", "control": hk.flags.insert(.maskControl)
            case "lcmd": hk.flags.insert(.maskCommand); hk.deviceBits |= lcmd
            case "rcmd": hk.flags.insert(.maskCommand); hk.deviceBits |= rcmd
            case "lalt", "lopt", "loption": hk.flags.insert(.maskAlternate); hk.deviceBits |= lalt
            case "ralt", "ropt", "roption": hk.flags.insert(.maskAlternate); hk.deviceBits |= ralt
            case "lshift": hk.flags.insert(.maskShift); hk.deviceBits |= lshift
            case "rshift": hk.flags.insert(.maskShift); hk.deviceBits |= rshift
            case "lctrl": hk.flags.insert(.maskControl); hk.deviceBits |= lctrl
            case "rctrl": hk.flags.insert(.maskControl); hk.deviceBits |= rctrl
            default:
                guard let code = keyCodes[tok] else { return nil }
                hk.keyCode = code
            }
        }
        return (hk.flags.isEmpty && hk.keyCode == nil) ? nil : hk
    }

    /// `cmd+alt+space` from a keyDown. Needs at least one modifier, or an F-key,
    /// so a stray letter never becomes the record chord. Nil = keep listening.
    static func string(flags: CGEventFlags, keyCode: Int64) -> String? {
        guard let name = namesByCode[keyCode] else { return nil }
        let hasMod = !flags.intersection(modifierMask).isEmpty
        let isFn = fnCodes.contains(keyCode)
        guard hasMod || isFn else { return nil }
        var parts: [String] = []
        if flags.contains(.maskCommand) { parts.append("cmd") }
        if flags.contains(.maskAlternate) { parts.append("alt") }
        if flags.contains(.maskShift) { parts.append("shift") }
        if flags.contains(.maskControl) { parts.append("ctrl") }
        parts.append(name)
        return parts.joined(separator: "+")
    }

    /// Canonical token per key code. Aliases in `keyCodes` collapse here
    /// (enter -> return, esc -> escape).
    static let namesByCode: [Int64: String] = {
        var out: [Int64: String] = [:]
        for (name, code) in keyCodes where out[code] == nil { out[code] = name }
        for name in ["space", "return", "tab", "escape", "delete", "grave", "minus", "equal"] {
            if let c = keyCodes[name] { out[c] = name }
        }
        return out
    }()

    static let fnCodes: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    static let modifierMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]

    /// True when exactly these modifiers (and the right-side bits, if any) are held.
    func modifiersHeld(_ f: CGEventFlags) -> Bool {
        guard f.intersection(Hotkey.modifierMask) == flags else { return false }
        return f.rawValue & deviceBits == deviceBits
    }
}

// MARK: - State

enum Mode { case plain, cleanup }
/// Where a take is. Named RecordState so it never shadows SwiftUI.State.
enum RecordState { case idle, recording(Mode), transcribing }

struct Transcript: Identifiable {
    let id = UUID()
    let date: Date
    let text: String
}

/// One Option+Space take. `gen` lets Esc discard drop in-flight segment jobs.
final class StreamTake {
    let gen: Int
    var texts: [String] = []
    var decodeMs: Double = 0
    var unhealthy = false
    init(gen: Int) { self.gen = gen }
}


// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg = Config.load()
    var replacements = Config.loadReplacements()
    var recordHK: Hotkey!
    var cleanupHK: Hotkey!

    var statusItem: NSStatusItem!
    var state: RecordState = .idle {
        didSet { DispatchQueue.main.async { self.refreshIcon(); self.store.state = self.state } }
    }
    /// Bridge to the SwiftUI window (UI/SettingsWindow.swift).
    let store = AppStore()
    lazy var settings = SettingsWindowController(store: store)
    /// Which mode the menu's Toggle Recording uses (the hotkeys pick their own).
    var menuMode: Mode = .plain
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    var history: [Transcript] = [] { didSet { store.history = history } }

    var tap: CFMachPort?
    var preview: NSSound?
    let panel = WavePanel()
    let capture = Capture()
    let segmenter = Segmenter()
    let work = DispatchQueue(label: "whisper.work")
    var takeGen = 0
    var take: StreamTake?
    /// Postit meeting: WavePanel footer says Debrief, stop writes a note, no paste.
    var meetingActive = false
    /// Bumped on start and on Esc cancel so an in-flight finishMeeting drops the take.
    var meetingGen = 0
    /// Original clipboard, held until the delayed restore. Shared across
    /// overlapping pastes so a second take does not snapshot the first take.
    var savedClipboard: [[NSPasteboard.PasteboardType: Data]]?
    var clipboardRestore: DispatchWorkItem?

    static let dictationDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Dictation", isDirectory: true)

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let r = Hotkey.parse(cfg.recordHotkey) else { fatal("Bad recordHotkey in config.json: \(cfg.recordHotkey)") }
        guard let c = Hotkey.parse(cfg.cleanupHotkey) else { fatal("Bad cleanupHotkey in config.json: \(cfg.cleanupHotkey)") }
        recordHK = r; cleanupHK = c

        // Transcripts are private: owner-only dir, and log() keeps files 600.
        try? FileManager.default.createDirectory(at: App.dictationDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: App.dictationDir.path)
        loadHistory()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu(); menu.delegate = self
        menu.autoenablesItems = false   // we set isEnabled ourselves in menuNeedsUpdate
        statusItem.menu = menu
        refreshIcon()
        installMainMenu()
        store.toggleRecording = { [weak self] in self?.toggleRecording() }
        store.save = { [weak self] patch in self?.updateConfig(patch) }
        store.refresh = { [weak self] in self?.refreshUIState() }
        store.captureHotkey = { [weak self] field in self?.beginHotkeyCapture(field) }
        store.openItem = { [weak self] id in self?.openItem(id) }
        store.setLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
        store.downloadModel = { [weak self] in self?.downloadModel() }
        store.playSound = { [weak self] name in self?.previewSound(name) }
        syncStore()
        refreshUIState()
        // Dev hook, same as clicking Settings… in the dropdown. Post it from any
        // process with DistributedNotificationCenter (see eval/open-settings.swift).
        // It only opens the window; nothing else is reachable this way.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.maxoleary.whisper.openSettings"), object: nil, queue: .main
        ) { [weak self] _ in self?.settings.show(page: .home) }
        capture.onLevel = { [weak self] level in self?.panel.push(level: level) }
        // Notch pill buttons. toggleRecording already picks meeting vs dictation stop.
        panel.onRecord = { [weak self] in self?.toggleRecording() }
        panel.onStop = { [weak self] in self?.toggleRecording() }
        panel.onSettings = { [weak self] in self?.openSettings() }
        panel.recordHotkey = cfg.recordHotkey
        // Pill mode: the idle outline is always on screen, from launch.
        if UserDefaults.standard.bool(forKey: "panelCompact") { panel.showIdle() }
        installMeetingObserver()

        // Accessibility is what lets us watch keys globally and press Cmd+V.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            // Keep polling until the user flips the switch, then install the tap.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                if AXIsProcessTrusted() { t.invalidate(); self.installTap() }
            }
        } else {
            installTap()
        }
        if checkModel(quiet: true) { startEngine() }
        if CommandLine.arguments.contains("--meeting") || Meeting.consumePing() {
            handleMeetingPing()
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        takeGen += 1
        take = nil
        _ = capture.stop()
        server?.terminate()
        restoreClipboard()
    }

    // MARK: Engine (FluidAudio in-process; whisper-server only if engine is whisper)

    let parakeet = ParakeetEngine()
    var server: Process?
    var serverURL: URL { URL(string: "http://127.0.0.1:\(cfg.serverPort)/inference")! }

    func startEngine() {
        server?.terminate(); server = nil
        _ = run("/usr/bin/pkill", ["-f", "whisper-server.*--port \(cfg.serverPort)"])
        if cfg.engineName == "parakeet" {
            parakeet.latinOnly = ParakeetEngine.usesLatinScript(cfg.language)
            parakeet.start()
            return
        }
        startWhisperServer()
    }

    func startWhisperServer() {
        let exe = URL(fileURLWithPath: cfg.whisperPath).deletingLastPathComponent().appendingPathComponent("whisper-server")
        guard FileManager.default.fileExists(atPath: exe.path) else {
            NSLog("Whisper: no whisper-server next to whisper-cli; falling back to whisper-cli per press")
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-m", cfg.modelPath, "-t", String(cfg.threads), "-l", cfg.language,
                       "--host", "127.0.0.1", "--port", String(cfg.serverPort)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); server = p } catch { NSLog("Whisper: whisper-server failed: \(error)") }
    }

    func serverAlive() -> Bool {
        guard let s = server, s.isRunning else { return false }
        return true
    }

    func fatal(_ msg: String) -> Never {
        let a = NSAlert(); a.messageText = "Whisper"; a.informativeText = msg; a.runModal()
        exit(1)
    }

    // MARK: Event tap

    func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let app = Unmanaged<App>.fromOpaque(refcon!).takeUnretainedValue()
            return app.handle(type: type, event: event)
        }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: callback,
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap = tap else {
            NSLog("Whisper: could not create event tap (Accessibility not granted?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags
        let key = event.getIntegerValueField(.keyboardEventKeycode)

        if let field = store.hotkeyCapture {
            return handleCapture(field: field, type: type, event: event, flags: flags, key: key)
        }

        let chords: [(Hotkey, Mode)] = [(cleanupHK!, .cleanup), (recordHK!, .plain)]
        let escape: Int64 = 53

        switch state {
        case .idle:
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return Unmanaged.passUnretained(event) }
                // Esc closes a lingering result card early. In pill mode the
                // window is always up, so only a non-idle pill counts.
                if key == escape, panel.showsResult {
                    DispatchQueue.main.async { self.panel.hide() }
                    return nil
                }
                for (hk, mode) in chords where hk.keyCode == key && hk.modifiersHeld(flags) {
                    startRecording(mode)
                    return nil   // swallow so the app underneath never sees it
                }
            } else if type == .keyUp {
                // Swallow the matching key-up too, so Finder never sees a full press.
                for (hk, _) in chords where hk.keyCode == key && hk.modifiersHeld(flags) { return nil }
            } else if type == .flagsChanged {
                for (hk, mode) in chords where hk.keyCode == nil && hk.modifiersHeld(flags) {
                    startRecording(mode)
                    break
                }
            }
        case .recording:
            // Dictation: tap the record/cleanup chord again to stop and paste.
            // Meeting: Option+Command+Space stops (not Option+Space). Esc
            // closes the card; the take still transcribes.
            if type == .keyDown {
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
                if key == escape {
                    if meetingActive { cancelMeeting() } else { stopRecording(shouldPaste: false) }
                    return nil
                }
                if meetingActive {
                    let mh = Meeting.stopHotkey
                    if mh.keyCode == key && mh.modifiersHeld(flags) {
                        stopRecording(); return nil
                    }
                    // Swallow dictation chords so Option+Space doesn't stop
                    // a meeting or insert a non-breaking space underneath.
                    for (hk, _) in chords where hk.keyCode == key && hk.modifiersHeld(flags) {
                        return nil
                    }
                } else {
                    for (hk, _) in chords where hk.keyCode == key && hk.modifiersHeld(flags) {
                        stopRecording(); return nil
                    }
                }
            } else if type == .keyUp {
                if key == escape { return nil }
                if meetingActive, Meeting.stopHotkey.keyCode == key { return nil }
                for (hk, _) in chords where hk.keyCode == key { return nil }
            } else if type == .flagsChanged {
                if meetingActive { break }
                for (hk, _) in chords where hk.keyCode == nil && hk.modifiersHeld(flags) {
                    stopRecording(); break
                }
            }
        case .transcribing:
            // Dictation: Esc hides the card; the take still pastes.
            // Meeting: Esc cancels — no transcript, no sticky.
            if type == .keyDown, key == escape {
                if meetingActive {
                    cancelMeeting()
                } else {
                    DispatchQueue.main.async { self.panel.hide() }
                }
                return nil
            }
            if type == .keyUp, key == escape { return nil }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Swallow the next chord into `recordHotkey` / `cleanupHotkey`. Esc with
    /// no modifiers cancels. Letters without a modifier stay listening.
    func handleCapture(field: AppStore.HotkeyCapture, type: CGEventType, event: CGEvent,
                       flags: CGEventFlags, key: Int64) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            if key == 53, flags.intersection(Hotkey.modifierMask).isEmpty {
                DispatchQueue.main.async { self.store.hotkeyCapture = nil }
                return nil
            }
            if let s = Hotkey.string(flags: flags, keyCode: key) {
                DispatchQueue.main.async {
                    self.store.hotkeyCapture = nil
                    let other = field == .record ? self.cfg.cleanupHotkey : self.cfg.recordHotkey
                    guard s != other else { return }
                    let keyName = field == .record ? "recordHotkey" : "cleanupHotkey"
                    self.updateConfig([keyName: s])
                }
                return nil
            }
            return nil
        }
        if type == .keyUp { return nil }
        return Unmanaged.passUnretained(event)
    }

    func beginHotkeyCapture(_ field: AppStore.HotkeyCapture) {
        if store.hotkeyCapture == field { store.hotkeyCapture = nil; return }
        store.hotkeyCapture = field
    }

    // MARK: Recording

    func startRecording(_ mode: Mode) {
        store.hotkeyCapture = nil
        guard checkModel(quiet: false) else {
            if meetingActive {
                meetingActive = false
                DispatchQueue.main.async { self.statusItem.isVisible = true }
            }
            return
        }
        takeGen += 1
        let gen = takeGen
        take = StreamTake(gen: gen)
        segmenter.reset()
        capture.onChunk = { [weak self] chunk in
            self?.work.async { self?.ingest(chunk, gen: gen) }
        }
        guard capture.start(deviceName: cfg.audioDevice) else {
            take = nil
            capture.onChunk = nil
            if meetingActive {
                meetingActive = false
                DispatchQueue.main.async { self.statusItem.isVisible = true }
            }
            alert("Couldn't open the microphone.")
            return
        }
        state = .recording(mode)
        playTakeSound(Config.soundName(cfg.startSound, fallback: "Tink"))
        let engineStatus = cfg.engineName == "parakeet" ? parakeet.status : ""
        DispatchQueue.main.async {
            self.panel.show(mode: mode,
                            hotkey: self.meetingActive ? Meeting.stopChord : self.cfg.recordHotkey,
                            footer: self.meetingActive ? "Debrief" : nil,
                            closeLabel: self.meetingActive ? "Cancel" : "Close")
            // Engine still downloading or loading: show that in the footer.
            if !engineStatus.isEmpty { self.panel.setFooterLeft(engineStatus) }
        }
    }

    /// Second hotkey tap: stop, transcribe, paste. Esc: same, but the card
    /// closes now and nothing is pasted (`shouldPaste == false`).
    func stopRecording(shouldPaste: Bool = true) {
        guard case .recording(let mode) = state else { return }
        state = .transcribing
        playTakeSound(Config.soundName(cfg.stopSound, fallback: "Pop"))
        let samples = capture.stop()
        let gen = take?.gen ?? takeGen
        let tStop = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            if self.meetingActive {
                self.panel.transcribing(status: "Transcribing…")
            } else if shouldPaste {
                self.panel.transcribing()
            } else {
                self.panel.hide()
            }
        }

        let app = frontmostAppName()
        let meetingGenAtStop = meetingGen
        work.async {
            self.finishTake(samples: samples, mode: mode, gen: gen, tStop: tStop,
                            shouldPaste: shouldPaste, app: app, meetingGen: meetingGenAtStop)
        }
    }

    func ingest(_ samples: [Float], gen: Int) {
        guard take?.gen == gen else { return }
        for chunk in segmenter.push(samples) {
            decodeSegment(chunk, gen: gen)
        }
    }

    func decodeSegment(_ chunk: Segmenter.Chunk, gen: Int) {
        guard chunk.voiced, take?.gen == gen else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let text = transcribe(chunk.samples, waitForServer: false)
        let dt = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard let take, take.gen == gen else { return }
        take.decodeMs += dt
        let secs = Double(chunk.samples.count) / Capture.sampleRate
        if text.isEmpty {
            take.unhealthy = true
            NSLog("Whisper: segment %.1fs empty in %.0fms — will fall back", secs, dt)
        } else {
            take.texts.append(text)
            NSLog("Whisper: segment %.1fs in %.0fms", secs, dt)
        }
    }

    func finishTake(samples: [Float], mode: Mode, gen: Int, tStop: CFAbsoluteTime, shouldPaste: Bool, app: String,
                    meetingGen expectedMeetingGen: Int = 0) {
        let inMeeting = meetingActive
        var pasted = false
        defer {
            if !inMeeting {
                self.take = nil
                self.state = .idle
                if !pasted { DispatchQueue.main.async { self.panel.hide() } }
            }
        }
        guard take?.gen == gen else {
            if inMeeting { endMeetingSession() }
            return
        }

        let overlapped = take?.decodeMs ?? 0
        let liveOk = take?.unhealthy == false && !(take?.texts.isEmpty ?? true)
        let seconds = Double(samples.count) / Capture.sampleRate
        guard seconds >= cfg.minSeconds else {
            if inMeeting { endMeetingSession() }
            return
        }

        var fallback = false
        var text: String
        if liveOk {
            // Pauses already decoded while talking. Only run the tail.
            if samples.count > segmenter.consumed {
                for chunk in segmenter.push(Array(samples[segmenter.consumed...])) {
                    decodeSegment(chunk, gen: gen)
                }
            }
            if let tail = segmenter.finalize() {
                decodeSegment(tail, gen: gen)
            }
            guard take?.gen == gen else { return }
            if let take, !take.unhealthy, !take.texts.isEmpty {
                text = take.texts.joined(separator: " ")
            } else {
                fallback = true
                text = transcribe(samples, waitForServer: true)
            }
        } else {
            // No live segments (two words, or no ~2s pause): one Parakeet call,
            // same as before stage 1. Do not decode the tail and then the
            // whole buffer.
            segmenter.reset()
            fallback = take?.unhealthy == true
            text = transcribe(samples, waitForServer: true)
        }

        let tAsr = CFAbsoluteTimeGetCurrent()
        if inMeeting {
            guard meetingActive, meetingGen == expectedMeetingGen else { return }
            finishMeeting(samples: samples, text: text, seconds: seconds, expectedGen: expectedMeetingGen)
            NSLog("Whisper meeting: %.1fs audio, overlapped=%.0fms asr=%.0fms fallback=%d",
                  seconds, overlapped, (tAsr - tStop) * 1000, fallback ? 1 : 0)
            return
        }
        guard !text.isEmpty else {
            if cfg.sounds { DispatchQueue.main.async { NSSound(named: "Basso")?.play() } }
            NSLog("Whisper: %.1fs audio, overlapped=%.0fms asr=%.0fms empty fallback=%d",
                  seconds, overlapped, (tAsr - tStop) * 1000, fallback ? 1 : 0)
            return
        }

        if mode == .cleanup, let cleaned = cleanup(text) { text = cleaned }
        text = Config.applyReplacements(replacements, to: text)

        pasted = true
        let now = Date()
        let shown = History.flatten(text)
        log(shown, at: now)
        let entry = Stats.Take(date: now, words: Stats.wordCount(shown), seconds: seconds, app: app)
        Stats.append(entry, in: App.dictationDir)
        DispatchQueue.main.async {
            self.history.insert(Transcript(date: now, text: shown), at: 0)
            self.store.stats.insert(entry, at: 0)
            self.panel.hide()
        }
        if shouldPaste { paste(text) }
        NSLog("Whisper: %.1fs audio, overlapped=%.0fms asr=%.0fms paste=%.0fms segments=%d fallback=%d",
              seconds, overlapped, (tAsr - tStop) * 1000,
              (CFAbsoluteTimeGetCurrent() - tAsr) * 1000,
              take?.texts.count ?? 0, fallback ? 1 : 0)
    }

    // MARK: Transcribe

    func transcribe(_ samples: [Float], waitForServer: Bool = true) -> String {
        // FluidAudio stays loaded in-process. Right after launch it may still
        // be compiling CoreML, so retry briefly before falling back to whisper.
        // Live segments skip the retry so a miss just marks the take unhealthy
        // and the full buffer runs once at stop.
        if cfg.engineName == "parakeet" {
            if waitForServer && !parakeet.isReady {
                let engineStatus = parakeet.status
                if !engineStatus.isEmpty {
                    DispatchQueue.main.async { self.panel.setFooterLeft(engineStatus) }
                }
            }
            let waits: [TimeInterval] = waitForServer ? [0, 0.4, 0.8, 1.6, 3.2] : [0]
            for wait in waits {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if parakeet.isReady {
                    return clean(parakeet.transcribe(samples))
                }
            }
            if !waitForServer { return "" }
            NSLog("Whisper: FluidAudio not ready, falling back to whisper-cli")
        } else if serverAlive() {
            let waits: [TimeInterval] = waitForServer ? [0, 0.4, 0.8, 1.6, 3.2] : [0]
            for wait in waits {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                if let text = withTempWav(samples, { self.transcribeViaServer($0) }) { return clean(text) }
                if !serverAlive() { break }
            }
        } else if waitForServer {
            DispatchQueue.main.async { self.startEngine() }
        }
        if !waitForServer { return "" }
        return withTempWav(samples) { wav in
            let (out, _, _) = self.run(self.cfg.whisperPath, [
                "-m", self.cfg.modelPath, "-f", wav.path, "-l", self.cfg.language,
                "-t", String(self.cfg.threads), "-nt", "-np",
            ])
            return self.clean(out)
        } ?? ""
    }

    /// Drops [BLANK_AUDIO], (music), [MUSIC] and friends; joins lines.
    func clean(_ out: String) -> String {
        let lines = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") && !$0.hasPrefix("(") }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper fallback still wants a file. Parakeet never hits this.
    func withTempWav(_ samples: [Float], _ body: (URL) -> String?) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard writeWav(samples, to: url) else { return nil }
        return body(url)
    }

    func writeWav(_ samples: [Float], to url: URL) -> Bool {
        let n = samples.count
        var data = Data()
        data.reserveCapacity(44 + n * 2)
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }
        func u16(_ v: UInt16) { let x = v.littleEndian; withUnsafeBytes(of: x) { data.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { let x = v.littleEndian; withUnsafeBytes(of: x) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + n * 2)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1); u32(UInt32(Capture.sampleRate)); u32(UInt32(Capture.sampleRate * 2))
        u16(2); u16(16)
        ascii("data"); u32(UInt32(n * 2))
        for s in samples {
            let x = max(-1 as Float, min(1 as Float, s))
            let v = Int16((x * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
        }
        do { try data.write(to: url, options: .atomic); return true }
        catch { NSLog("Whisper: wav write failed: \(error)"); return false }
    }

    func transcribeViaServer(_ wav: URL) -> String? {
        guard let data = try? Data(contentsOf: wav) else { return nil }
        let boundary = "whisper-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "text")
        field("no_timestamps", "true")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: serverURL)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { d, r, e in
            defer { sem.signal() }
            guard let d = d, e == nil, (r as? HTTPURLResponse)?.statusCode == 200 else {
                NSLog("Whisper server error: \(e?.localizedDescription ?? "http")"); return
            }
            result = String(data: d, encoding: .utf8)
        }.resume()
        sem.wait()
        return result
    }

    // MARK: Cleanup (optional LLM pass — local Ollama or xAI Grok ONLY;
    // this app never talks to OpenAI, Google, or Anthropic endpoints)

    func cleanup(_ text: String) -> String? {
        let env = Config.env()
        var req: URLRequest
        var body: [String: Any]
        var extract: ([String: Any]) -> String?

        if let model = env["OLLAMA_MODEL"], !model.isEmpty {
            // Fully local: talks only to an Ollama server on this Mac.
            req = URLRequest(url: URL(string: env["OLLAMA_URL"] ?? "http://127.0.0.1:11434/api/chat")!)
            body = ["model": model, "stream": false,
                    "messages": [["role": "system", "content": cfg.cleanupPrompt],
                                 ["role": "user", "content": text]]]
            extract = { json in
                ((json["message"] as? [String: Any])?["content"] as? String)
            }
        } else if let key = env["XAI_API_KEY"], !key.isEmpty {
            req = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
            req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": env["LLM_MODEL"] ?? "grok-4-fast-non-reasoning",
                    "messages": [["role": "system", "content": cfg.cleanupPrompt],
                                 ["role": "user", "content": text]]]
            extract = { json in
                (((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String)
            }
        } else {
            return nil   // no provider configured: cleanup mode is just a plain paste
        }

        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 25
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            guard let data = data, err == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("Whisper cleanup failed: \(err?.localizedDescription ?? "no data")"); return
            }
            if let s = extract(json)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                result = s
            } else {
                NSLog("Whisper cleanup: unexpected response shape (body not logged)")
            }
        }.resume()
        sem.wait()
        return result
    }

    // MARK: Paste + clipboard restore

    /// Snapshot, write the take, post ⌘V, return. Restore runs 350ms later on
    /// main, not on `whisper.work`, so a two-word take is not stuck behind sleep.
    func paste(_ text: String) {
        DispatchQueue.main.async { self.pasteOnMain(text) }
    }

    private func pasteOnMain(_ text: String) {
        let pb = NSPasteboard.general
        if savedClipboard == nil {
            savedClipboard = (pb.pasteboardItems ?? []).map { item in
                var d: [NSPasteboard.PasteboardType: Data] = [:]
                for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
                return d
            }
        }

        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        clipboardRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreClipboard() }
        clipboardRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func restoreClipboard() {
        clipboardRestore?.cancel()
        clipboardRestore = nil
        guard let saved = savedClipboard else { return }
        savedClipboard = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        if !saved.isEmpty {
            let items: [NSPasteboardItem] = saved.map { d in
                let it = NSPasteboardItem()
                for (t, data) in d { it.setData(data, forType: t) }
                return it
            }
            pb.writeObjects(items)
        }
    }

    // MARK: Log + history

    func log(_ text: String, at now: Date) {
        let file = History.monthFile(for: now, in: App.dictationDir)
        let line = History.line(date: now, text: text)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? ("# Dictation \(file.deletingPathExtension().lastPathComponent)\n\n" + line)
                .write(to: file, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Every take from every month file, newest first (History.swift).
    func loadHistory() {
        history = History.load(dir: App.dictationDir)
        store.stats = Stats.load(dir: App.dictationDir)
    }

    /// App the take was aimed at. Settings can steal frontmost; fall back to
    /// whoever was in front when the window opened.
    func frontmostAppName() -> String {
        let me = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != me {
            return app.localizedName ?? app.bundleIdentifier ?? ""
        }
        return settings.recordedAppName()
    }

    // MARK: Menu

    /// Menu bar glyph: the app-icon five bars (tall, low, mid, low, tall).
    /// Template image, so the bar tints it.
    static let glyph: NSImage = {
        let size: CGFloat = 22
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            // App-icon rects (1024 grid, center 512) mapped onto 22pt, y-up.
            let bars: [(x: CGFloat, y: CGFloat, h: CGFloat)] = [
                (287, 292, 440), (391, 530, 202), (495, 362, 291),
                (599, 530, 202), (703, 292, 440)]
            let s: CGFloat = 0.034
            NSColor.black.setFill()
            for b in bars {
                let w = 34 * s
                let h = b.h * s
                let x = 11 + (b.x + 17 - 512) * s - w / 2
                let yTop = 11 + (512 - b.y) * s        // y-up: icon-grid top edge
                NSRect(x: x, y: yTop - h, width: w, height: h).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }()

    func refreshIcon() {
        guard let b = statusItem.button else { return }
        let (tint, tip): (NSColor?, String)
        switch state {
        case .idle: (tint, tip) = (nil, "Whisper: press \(cfg.recordHotkey) to dictate")
        case .recording: (tint, tip) = (.systemRed, "Recording…")
        case .transcribing: (tint, tip) = (.systemOrange, "Transcribing…")
        }
        b.image = App.glyph
        b.contentTintColor = tint
        b.toolTip = tip
    }

    /// Superwhisper-shaped dropdown: actions, then mic + mode pickers, then
    /// version and Quit. Transcripts live in the History window now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // First run: Parakeet is downloading or compiling. Say so up top.
        let engineStatus = parakeet.status
        if !engineStatus.isEmpty {
            menu.addItem(withTitle: engineStatus, action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(.separator())
        }
        let toggleTitle: String
        switch state {
        case .idle: toggleTitle = "Toggle Recording"
        case .recording: toggleTitle = "Stop Recording"
        case .transcribing: toggleTitle = "Transcribing…"
        }
        let toggle = menu.addItem(withTitle: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        if case .transcribing = state { toggle.isEnabled = false }
        menu.addItem(withTitle: "History…", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())

        // Microphone ▸ System default + every input, check on the one config.json names.
        let (micName, micSymbol) = micDisplay()
        let micItem = NSMenuItem(title: micName, action: nil, keyEquivalent: "")
        micItem.image = NSImage(systemSymbolName: micSymbol, accessibilityDescription: nil)
        let micMenu = NSMenu()
        let chosen = Capture.device(named: cfg.audioDevice)
        let def = NSMenuItem(title: "System default", action: #selector(pickMic(_:)), keyEquivalent: "")
        def.target = self; def.representedObject = ""; def.state = chosen == nil ? .on : .off
        micMenu.addItem(def)
        micMenu.addItem(.separator())
        for d in Capture.inputDevices() {
            let it = NSMenuItem(title: d.localizedName, action: #selector(pickMic(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.localizedName
            it.state = d.uniqueID == chosen?.uniqueID ? .on : .off
            micMenu.addItem(it)
        }
        micItem.submenu = micMenu
        menu.addItem(micItem)

        // Mode ▸ Plain / Cleanup, for the menu's Toggle Recording.
        let modeItem = NSMenuItem(title: menuMode == .cleanup ? "Cleanup" : "Plain", action: nil, keyEquivalent: "")
        modeItem.image = NSImage(systemSymbolName: "text.bubble.fill", accessibilityDescription: nil)
        let modeMenu = NSMenu()
        for (title, mode) in [("Plain", Mode.plain), ("Cleanup", Mode.cleanup)] {
            let it = NSMenuItem(title: title, action: #selector(pickMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode == .cleanup ? "cleanup" : "plain"
            it.state = mode == menuMode ? .on : .off
            modeMenu.addItem(it)
        }
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Version \(App.version)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// The one place that decides what the mic row and the window toolbar
    /// say: the chosen device's name, or "System default" + whatever macOS
    /// would use, with a laptop glyph for the built-in mic and a mic glyph otherwise.
    func micDisplay() -> (name: String, symbol: String) {
        let chosen = Capture.device(named: cfg.audioDevice)
        let shown = chosen ?? AVCaptureDevice.default(for: .audio)
        let builtIn = shown.map { $0.deviceType == .microphone && $0.localizedName.lowercased().contains("macbook") } ?? true
        return (chosen?.localizedName ?? "System default", builtIn ? "laptopcomputer" : "mic")
    }

    /// Minimal main menu. The bar is never visible for a menu bar app, but
    /// AppKit routes ⌘, ⌘W ⌘Q and the Edit key equivalents (⌘C/V/A/Z in any
    /// text field) through it, so without one none of them work in the window.
    func installMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func toggleRecording() {
        switch state {
        case .idle: startRecording(menuMode)
        case .recording: stopRecording()
        case .transcribing: break
        }
    }
    @objc func openHistory() { settings.show(page: .history) }
    @objc func openSettings() { settings.show(page: .home) }

    @objc func pickMic(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        updateConfig(["audioDevice": name])
    }

    /// Write a few keys, re-read the file, refresh what depends on it. Only
    /// engine-related keys restart the engine; a mic or hotkey change must
    /// not kill whisper-server or block the main thread on pkill.
    func updateConfig(_ patch: [String: Any]) {
        Config.save(patch: patch, current: cfg)
        cfg = Config.load()
        replacements = Config.loadReplacements()
        parakeet.latinOnly = ParakeetEngine.usesLatinScript(cfg.language)
        if let r = Hotkey.parse(cfg.recordHotkey) { recordHK = r }
        if let c = Hotkey.parse(cfg.cleanupHotkey) { cleanupHK = c }
        panel.recordHotkey = cfg.recordHotkey
        refreshIcon()
        syncStore()
        let engineKeys: Set<String> = ["engine", "modelPath", "parakeetModel", "serverPort", "threads", "language", "whisperPath"]
        if !engineKeys.isDisjoint(with: patch.keys), checkModel(quiet: true) { startEngine() }
    }
    @objc func pickMode(_ sender: NSMenuItem) {
        menuMode = (sender.representedObject as? String) == "cleanup" ? .cleanup : .plain
    }

    /// Push the config-derived bits the window shows. (`history` and `state`
    /// reach the store from their own didSets.)
    func syncStore() {
        let (name, symbol) = micDisplay()
        store.micName = name
        store.micSymbol = symbol
        store.recordHotkey = cfg.recordHotkey
        store.cleanupHotkey = cfg.cleanupHotkey
        store.audioDevice = cfg.audioDevice
        store.language = cfg.language
        store.minSeconds = cfg.minSeconds
        if store.cleanupPrompt != cfg.cleanupPrompt { store.cleanupPrompt = cfg.cleanupPrompt }
        store.sounds = cfg.sounds
        store.startSound = Config.soundName(cfg.startSound, fallback: "Tink")
        store.stopSound = Config.soundName(cfg.stopSound, fallback: "Pop")
        store.engineName = cfg.engineName
        store.modelMissing = cfg.engineName == "whisper" && !FileManager.default.fileExists(atPath: cfg.modelPath)
    }

    /// Mic list, login-item state, replacements. Cheap; called when the
    /// window becomes key so an external edit of replacements.txt is picked up.
    func refreshUIState() {
        replacements = Config.loadReplacements()
        store.mics = Capture.inputDevices().map(\.localizedName)
        store.launchAtLogin = loginItemLoaded()
        syncStore()
    }

    func playTakeSound(_ name: String) {
        guard cfg.sounds, !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    /// Preview from the Sound page. Works even when Sounds is off, so you
    /// can hear a pick before turning them on. Stops the previous preview.
    func previewSound(_ name: String) {
        preview?.stop()
        preview = nil
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.lowercased() != "none" else { return }
        if let s = NSSound(named: NSSound.Name(n)) {
            preview = s
            s.play()
            return
        }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(n).aiff")
        preview = NSSound(contentsOf: url, byReference: true)
        preview?.play()
    }

    func openItem(_ id: String) {
        switch id {
        case "replacements":
            Config.writeTemplates()
            NSWorkspace.shared.open(Config.replacementsFile)
        case "env":
            if !FileManager.default.fileExists(atPath: Config.envFile.path) {
                let starter = """
                # Local Ollama, or xAI Grok. Leave blank to skip cleanup.
                # OLLAMA_MODEL=
                # OLLAMA_URL=http://127.0.0.1:11434/api/chat
                # XAI_API_KEY=
                # LLM_MODEL=grok-4-fast-non-reasoning

                """
                try? starter.write(to: Config.envFile, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(Config.envFile)
        case "configDir":
            NSWorkspace.shared.open(Config.dir)
        case "dictation":
            NSWorkspace.shared.open(App.dictationDir)
        default: break
        }
    }

    static let loginLabel = "com.maxoleary.whisper"
    static var loginPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(loginLabel).plist")
    }
    var loginTarget: String { "gui/\(getuid())/\(App.loginLabel)" }
    var loginDomain: String { "gui/\(getuid())" }

    func loginItemLoaded() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["print", loginTarget]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func setLaunchAtLogin(_ on: Bool) {
        if on {
            writeLoginPlist()
            if !loginItemLoaded() {
                _ = run("/bin/launchctl", ["bootstrap", loginDomain, App.loginPlist.path])
            }
        } else {
            if loginItemLoaded() {
                _ = run("/bin/launchctl", ["bootout", loginTarget])
            }
            try? FileManager.default.removeItem(at: App.loginPlist)
        }
        store.launchAtLogin = loginItemLoaded()
    }

    func writeLoginPlist() {
        let url = App.loginPlist
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>            <string>\(App.loginLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>-a</string>
                <string>/Applications/Whisper.app</string>
            </array>
            <key>RunAtLoad</key>        <true/>
            <key>ProcessType</key>      <string>Interactive</string>
        </dict>
        </plist>
        """
        try? xml.write(to: url, atomically: true, encoding: .utf8)
    }

    @objc func reloadConfig() {
        cfg = Config.load()
        replacements = Config.loadReplacements()
        if let r = Hotkey.parse(cfg.recordHotkey) { recordHK = r }
        if let c = Hotkey.parse(cfg.cleanupHotkey) { cleanupHK = c }
        refreshIcon()
        syncStore()
        if checkModel(quiet: true) { startEngine() }
    }

    // MARK: Model

    @discardableResult
    /// Can the selected engine transcribe? Parakeet downloads/compiles CoreML
    /// on first launch. Whisper needs a ggml model, which we offer to download.
    func checkModel(quiet: Bool) -> Bool {
        if cfg.engineName == "parakeet" { return true }
        if FileManager.default.fileExists(atPath: cfg.modelPath) { return true }
        if !quiet {
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "Whisper model not found"
                a.informativeText = "Expected it at:\n\(self.cfg.modelPath)\n\nDownload base.en now (about 150 MB, one time)?"
                a.addButton(withTitle: "Download"); a.addButton(withTitle: "Later")
                if a.runModal() == .alertFirstButtonReturn { self.downloadModel() }
            }
        }
        return false
    }

    @objc func downloadModel() {
        let name = URL(fileURLWithPath: cfg.modelPath).lastPathComponent
        let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)"
        let dest = cfg.modelPath
        state = .transcribing   // reuse the "busy" icon while downloading
        work.async {
            let (_, err, code) = self.run("/usr/bin/curl", ["-L", "--fail", "--progress-bar", "-o", dest + ".part", url])
            if code == 0 {
                try? FileManager.default.removeItem(atPath: dest)
                try? FileManager.default.moveItem(atPath: dest + ".part", toPath: dest)
                self.notify("Model ready", "\(name) downloaded. Press \(self.cfg.recordHotkey) to dictate.")
                DispatchQueue.main.async { self.startEngine(); self.syncStore() }
            } else {
                try? FileManager.default.removeItem(atPath: dest + ".part")
                self.alert("Model download failed (curl exit \(code)).\n\(err.suffix(300))")
            }
            DispatchQueue.main.async { self.state = .idle; self.syncStore() }
        }
    }

    // MARK: Helpers

    func run(_ exe: String, _ args: [String]) -> (String, String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return ("", "\(error)", -1) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: o, encoding: .utf8) ?? "", String(data: e, encoding: .utf8) ?? "", p.terminationStatus)
    }

    func alert(_ msg: String) {
        DispatchQueue.main.async {
            let a = NSAlert(); a.messageText = "Whisper"; a.informativeText = msg; a.runModal()
        }
    }

    func notify(_ title: String, _ body: String) {
        // Plain osascript notification: no UserNotifications entitlement dance needed.
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        _ = run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\""])
    }
}

// Headless: fetch (or reuse) llama-server + the Llama GGUF, print progress,
// exit 0 when ready. `--ensure-llm <dir>` installs under <dir> instead of
// ~/.config/whisper and always downloads (support tool and test hook).
if let i = CommandLine.arguments.firstIndex(of: "--ensure-llm") {
    let args = CommandLine.arguments
    let custom = args.count > i + 1 && !args[i + 1].hasPrefix("-")
    let base = custom ? URL(fileURLWithPath: args[i + 1], isDirectory: true) : Config.dir
    print("Installing under \(base.path)")
    switch LocalLLM.ensure(baseDir: base, reuseDebrief: !custom, onStatus: { print($0); fflush(stdout) }) {
    case .ready:
        print("ready: \(LocalLLM.llamaServer(baseDir: base).path)")
        print("ready: \(LocalLLM.gguf(baseDir: base).path)")
        if !custom {
            print("notes dir: \(Meeting.notesDir(cfg: Config.load()).path)")
        }
        exit(0)
    case .failed(let msg):
        print("failed: \(msg)")
        exit(1)
    }
}

if CommandLine.arguments.contains("--transcribe") || CommandLine.arguments.contains("--ensure") {
    TranscribeCLI.run()
    exit(0)
}

if !Meeting.tryBecomePrimary() {
    if CommandLine.arguments.contains("--meeting") {
        Meeting.notifyPrimary()
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
