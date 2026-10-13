import AppKit
import Darwin
import Foundation

/// Meeting mode (`--meeting`): same WavePanel as dictation, footer “Debrief”,
/// no paste. Stop writes a Debrief-shaped note and opens it in Postit.
enum Meeting {
    static let pingName = Notification.Name("com.maxoleary.whisper.meeting")
    /// Card keycaps and the stop chord: Option+Command+Space, not dictation's Option+Space.
    static let stopChord = "alt+cmd+space"
    static let stopHotkey = Hotkey.parse("cmd+alt+space")!
    static let engineLabel = "Parakeet TDT v3 (FluidAudio)"
    static let llamaLabel = "Llama 3.2 3B Instruct"
    static let contextTokens = 16384
    static let pingFile = Config.dir.appendingPathComponent("meeting.ping")
    static let lockFile = Config.dir.appendingPathComponent("instance.lock")
    private static var lockFD: Int32 = -1

    static let systemPrompt = """
You turn a rough speech-to-text transcript of a meeting into short, plain notes. Write like a person jotting notes for themselves, not like a corporate memo.

The transcript is automatic, so expect misheard words, missing punctuation, and unreliable speaker names. Use your best reading of garbled names and never invent people, decisions, tasks, or dates. Stick close to what was actually said.

Write numbers as digits (25, not twenty-five; 4.5%, not four and a half percent).

Length matches the meeting. A one-sentence meeting gets one or two lines. A ten-minute chat gets a handful of bullets. An hour-long meeting can get more. Never pad to hit a length.

Reply in GitHub-flavoured Markdown with no preamble and no closing remarks:

## Notes

- Short bullets, casual and direct, in everyday words. Say what was talked about and what came of it. No buzzwords, no "stakeholders", "alignment", "leverage", "synergy", or anything that sounds like a press release.

Only add these sections if there is something real to put in them. Leave them out entirely otherwise. Don't repeat a point that already appears in another section: if a task is in To do, it doesn't need to be in Notes or Decisions too.

## Decisions

- One line per thing that was actually settled.

## To do

- [ ] **Name** - the task, plus the due date if one was said. Use **Unassigned** only if an owner really wasn't clear.
"""

    // MARK: Single instance

    /// Exclusive lock so `open -n` does not spawn a second dictation app.
    static func tryBecomePrimary() -> Bool {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            Darwin.close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    static func notifyPrimary() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try? "\(Date().timeIntervalSince1970)".write(to: pingFile, atomically: true, encoding: .utf8)
        DistributedNotificationCenter.default().postNotificationName(
            pingName, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func consumePing() -> Bool {
        guard FileManager.default.fileExists(atPath: pingFile.path),
              let s = try? String(contentsOf: pingFile, encoding: .utf8),
              let t = TimeInterval(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            try? FileManager.default.removeItem(at: pingFile)
            return false
        }
        try? FileManager.default.removeItem(at: pingFile)
        return Date().timeIntervalSince1970 - t < 5
    }

    // MARK: Notes dir / archive names (same shape as Debrief note.js)

    /// `meetingNotesDir` from config.json. If unset, Debrief's old `.env`
    /// NOTES_DIR is read once and persisted so the fallback never runs again.
    static func notesDir(cfg: Config) -> URL {
        if let raw = cfg.meetingNotesDir, !raw.isEmpty { return expandHome(raw) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let envFile = home.appendingPathComponent(".config/debrief/.env")
        if let raw = envValue("NOTES_DIR", file: envFile) {
            Config.save(patch: ["meetingNotesDir": raw], current: cfg)
            NSLog("Whisper meeting: notes dir \(raw) taken from Debrief's .env and saved to config.json")
            return expandHome(raw)
        }
        return home.appendingPathComponent("Debrief")
    }

    static func slot(in dir: URL, when: Date = Date()) -> (base: String, markdown: URL, audio: URL) {
        let c = Calendar.current
        let y = c.component(.year, from: when)
        let mo = c.component(.month, from: when)
        let d = c.component(.day, from: when)
        let h = c.component(.hour, from: when)
        let mi = c.component(.minute, from: when)
        let base0 = String(format: "%04d-%02d-%02d-%02d%02d", y, mo, d, h, mi)
        var name = base0
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).md").path)
            || FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(name).m4a").path) {
            name = "\(base0)-\(n)"
            n += 1
        }
        return (name, dir.appendingPathComponent("\(name).md"), dir.appendingPathComponent("\(name).m4a"))
    }

    static func humanDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        func pad(_ n: Int) -> String { String(format: "%02d", n) }
        if h > 0 { return "\(h)h \(pad(m))m" }
        if m > 0 { return "\(m)m \(pad(sec))s" }
        return "\(sec)s"
    }

    static func stamp(_ when: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        return f.string(from: when)
    }

    static func iso(_ when: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: when)
    }

    static func buildNote(when: Date, durationSeconds: Double, summary: String?,
                          summaryError: String?, transcript: String, audioFile: URL) -> String {
        let summarized: String
        if summary != nil {
            summarized = "local (llama.cpp) \(llamaLabel)"
        } else {
            summarized = "none"
        }
        let front = [
            "---",
            "date: \(iso(when))",
            "duration: \(humanDuration(durationSeconds))",
            "audio: \(audioFile.lastPathComponent)",
            "transcribed_with: \(engineLabel)",
            "summarized_with: \(summarized)",
            "---",
            "",
        ].joined(separator: "\n")

        var body: [String] = []
        body.append("# Meeting — \(stamp(when))")
        body.append("")
        if let summary, !summary.isEmpty {
            body.append(summary.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if let summaryError {
            body.append("## Summary")
            body.append("")
            body.append("_The summary step failed: \(summaryError)_")
            body.append("")
            body.append("_The full transcript below is complete and untouched._")
        } else {
            body.append("## Summary")
            body.append("")
            body.append("_No local Llama model is configured, so no summary was generated._")
        }
        body.append("")
        body.append("---")
        body.append("")
        body.append("## Transcript")
        body.append("")
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        body.append(t.isEmpty ? "_Nothing was transcribed._" : t)
        body.append("")
        return front + body.joined(separator: "\n")
    }

    // MARK: Llama 3.2 3B (LocalLLM downloads it, or reuses ~/.config/debrief)

    static var llamaDir: URL { LocalLLM.llamaDir() }
    static var llamaServer: URL { LocalLLM.llamaServer() }
    static var gguf: URL { LocalLLM.gguf() }

    /// `.text` is the markdown body; `.failed` is a one-line error for the note.
    enum Summary { case text(String); case failed(String) }

    static func summarize(_ transcript: String, when: Date, seconds: Double,
                          onStatus: ((String) -> Void)? = nil) -> Summary {
        if case .failed(let msg) = LocalLLM.ensure(onStatus: onStatus) {
            return .failed(msg)
        }
        let port = pickPort()
        let p = Process()
        p.executableURL = llamaServer
        p.arguments = [
            "-m", gguf.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(contextTokens),
            "-ngl", "99",
            "-fa", "on",
            "-ctk", "q8_0", "-ctv", "q8_0",
            "--no-webui",
            "--log-disable",
        ]
        var env = ProcessInfo.processInfo.environment
        env["DYLD_LIBRARY_PATH"] = llamaDir.path
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return .failed("llama-server failed to start: \(error)") }
        defer {
            p.terminate()
            let deadline = Date().addingTimeInterval(2)
            while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        onStatus?("Loading model…")

        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        let readyDeadline = Date().addingTimeInterval(120)
        var ready = false
        while Date() < readyDeadline {
            if !p.isRunning {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return .failed("llama-server exited before it was ready \(err.suffix(300))")
            }
            if httpOK(health) { ready = true; break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard ready else { return .failed("llama-server did not become ready in time") }
        onStatus?("Summarizing…")

        let fitted = fitTranscript(transcript)
        let user = [
            "Meeting date: \(stamp(when))",
            "Duration: \(humanDuration(seconds))",
            "Speaker labels are not available in this transcript.",
            "",
            "Transcript:",
            "",
            fitted,
        ].joined(separator: "\n")

        let body: [String: Any] = [
            "model": "llama3.2-3b",
            "temperature": 0.2,
            "max_tokens": 1500,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ],
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failed("Could not encode the chat request")
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = 15 * 60
        do {
            let data = try httpSync(req, timeout: 15 * 60 + 5)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  var text = msg["content"] as? String else {
                return .failed("The local model returned an empty summary.")
            }
            text = text.replacingOccurrences(of: "<think>[\\s\\S]*?</think>\\s*",
                                             with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .failed("The local model returned an empty summary.") }
            return .text(text)
        } catch {
            return .failed("\(error)")
        }
    }

    private static func fitTranscript(_ text: String) -> String {
        let maxChars = Int(Double(contextTokens - 2500) * 3.5)
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars))
            + "\n\n[Transcript truncated here: the meeting was longer than the local model can read at once.]"
    }

    private static func pickPort() -> Int {
        for port in 18765...18780 {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { continue }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            addr.sin_port = in_port_t(port).bigEndian
            var on: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            Darwin.close(sock)
            if ok { return port }
        }
        return 18765
    }

    private static func httpOK(_ url: URL) -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1
        return (try? httpSync(req, timeout: 1.5)) != nil
    }

    private static func httpSync(_ req: URLRequest, timeout: TimeInterval) throws -> Data {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        var err: Error?
        var status = 0
        URLSession.shared.dataTask(with: req) { data, resp, error in
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            out = data
            err = error
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw URLError(.timedOut)
        }
        if let err { throw err }
        if !(200..<300).contains(status) {
            let snippet = String(data: out ?? Data(), encoding: .utf8) ?? ""
            throw NSError(domain: "Meeting", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(snippet.prefix(300))"])
        }
        return out ?? Data()
    }

    private static func envValue(_ key: String, file: URL) -> String? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in raw.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            guard k == key else { continue }
            var v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
                v = String(v.dropFirst().dropLast())
            }
            return v.isEmpty ? nil : v
        }
        return nil
    }

    private static func expandHome(_ p: String) -> URL {
        if p == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if p.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(p.dropFirst(2)))
        }
        return URL(fileURLWithPath: p)
    }
}

extension App {
    func installMeetingObserver() {
        DistributedNotificationCenter.default().addObserver(
            forName: Meeting.pingName, object: nil, queue: .main
        ) { [weak self] _ in self?.handleMeetingPing() }
    }

    func handleMeetingPing() {
        _ = Meeting.consumePing()
        switch state {
        case .recording, .transcribing:
            panel.orderFrontRegardless()
            panel.invalidateShadow()
            if meetingActive {
                panel.wave.footerLeft = "Debrief"
                panel.wave.needsDisplay = true
            }
        case .idle:
            meetingGen += 1
            meetingActive = true
            statusItem.isVisible = false
            startRecording(.plain)
        }
    }

    /// Esc: drop the take. No transcript, no Llama, no sticky.
    func cancelMeeting() {
        guard meetingActive else { return }
        meetingGen += 1
        takeGen += 1
        meetingActive = false
        take = nil
        _ = capture.stop()
        DispatchQueue.main.async {
            self.state = .idle
            self.statusItem.isVisible = true
            self.panel.hide()
        }
        NSLog("Whisper meeting: cancelled")
    }

    func endMeetingSession() {
        meetingActive = false
        take = nil
        DispatchQueue.main.async {
            self.state = .idle
            self.statusItem.isVisible = true
            self.panel.hide()
        }
    }

    func setMeetingStatus(_ text: String) {
        DispatchQueue.main.async {
            self.panel.setFooterLeft(text)
        }
    }

    /// After Parakeet: Llama summary, write NOTES_DIR `.md` + `.m4a`, open Postit once.
    func finishMeeting(samples: [Float], text: String, seconds: Double, expectedGen: Int) {
        guard meetingGen == expectedGen, meetingActive else { return }
        defer {
            if meetingGen == expectedGen { endMeetingSession() }
        }
        let when = Date()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var summary: String?
        var summaryError: String?
        if trimmed.isEmpty {
            summaryError = "nothing was transcribed"
        } else {
            switch Meeting.summarize(trimmed, when: when, seconds: seconds,
                                     onStatus: { self.setMeetingStatus($0) }) {
            case .text(let s): summary = s
            case .failed(let e): summaryError = e
            }
        }
        guard meetingGen == expectedGen else { return }

        let dir = Meeting.notesDir(cfg: cfg)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slot = Meeting.slot(in: dir, when: when)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("debrief-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        if writeWav(samples, to: tmp) {
            let (_, err, code) = run("/usr/bin/afconvert",
                                     ["-f", "m4af", "-d", "aac", tmp.path, slot.audio.path])
            if code != 0 {
                NSLog("Whisper meeting: afconvert failed (\(code)) \(err.suffix(200))")
            }
        }

        let md = Meeting.buildNote(when: when, durationSeconds: seconds, summary: summary,
                                   summaryError: summaryError, transcript: trimmed, audioFile: slot.audio)
        guard meetingGen == expectedGen else { return }
        do {
            try md.write(to: slot.markdown, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Whisper meeting: write failed \(error)")
            notify("Debrief", "Could not write the meeting note.")
            return
        }
        _ = run("/usr/bin/open", ["-a", "Postit", slot.markdown.path])
        notify("Debrief", "Meeting note ready")
        NSLog("Whisper meeting: wrote \(slot.markdown.lastPathComponent)")
    }
}
