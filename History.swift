import Foundation

/// Reads every `~/Dictation/YYYY-MM.md` into takes and groups them by day for
/// the History page. Pure functions, no AppKit, so it is cheap to test.
enum History {
    /// Every take in every month file under `dir`, newest first. Month files
    /// are named `yyyy-MM.md` and `log()` appends in time order, so "newest
    /// first" is: newest file first, each file's lines reversed.
    static func load(dir: URL) -> [Transcript] {
        let fm = FileManager.default
        // contentsOfDirectory returns nothing through a symlinked folder.
        let dir = dir.resolvingSymlinksInPath()
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var out: [Transcript] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var month: [Transcript] = []
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if let t = parse(line: line) { month.append(t) }
            }
            out.append(contentsOf: month.reversed())
        }
        // Filename order is not a date (`notes.md` sorts ahead of `2026-09.md`).
        out.sort { $0.date > $1.date }
        return out
    }

    /// One `- **yyyy-MM-dd HH:mm** text` line, the same rule `log()` writes.
    static func parse(line: Substring) -> Transcript? {
        guard line.hasPrefix("- **") else { return nil }
        let body = line.dropFirst(4)
        guard let close = body.range(of: "** ") else { return nil }
        guard let d = date(fromStamp: body[..<close.lowerBound]) else { return nil }
        return Transcript(date: d, text: String(body[close.upperBound...]))
    }

    /// Newlines become spaces so a take is always one markdown line.
    static func flatten(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }

    /// The line `log()` writes and `parse(line:)` reads. Same stamp shape as
    /// `date(fromStamp:)`, built from calendar fields so it is safe off-main.
    static func line(date: Date, text: String) -> String {
        "- **\(stamp(from: date))** \(flatten(text))\n"
    }

    /// `yyyy-MM.md` next to `log()`, from the same calendar fields as the stamp.
    static func monthFile(for date: Date, in dir: URL) -> URL {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        let name = String(format: "%04d-%02d.md", c.year ?? 0, c.month ?? 0)
        return dir.appendingPathComponent(name)
    }

    /// The month file a take lives in (for Reveal in Finder).
    static func file(for take: Transcript, in dir: URL) -> URL {
        monthFile(for: take.date, in: dir)
    }

    // MARK: Grouping

    struct DayGroup: Identifiable {
        let day: Date
        let title: String
        let takes: [Transcript]
        var id: Date { day }
    }

    /// One group per calendar day, newest day first. Titles: Today, Yesterday,
    /// then "Mon, Sep 8" (with the year if it is not this year).
    static func group(_ takes: [Transcript], now: Date = Date()) -> [DayGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let thisYear = cal.component(.year, from: now)

        var buckets: [Date: [Transcript]] = [:]
        for t in takes {
            buckets[cal.startOfDay(for: t.date), default: []].append(t)
        }
        return buckets.keys.sorted(by: >).map { d in
            let title: String
            if d == today { title = "Today" }
            else if d == yesterday { title = "Yesterday" }
            else if cal.component(.year, from: d) == thisYear { title = dayFmt.string(from: d) }
            else { title = dayYearFmt.string(from: d) }
            let dayTakes = (buckets[d] ?? []).sorted { $0.date > $1.date }
            return DayGroup(day: d, title: title, takes: dayTakes)
        }
    }

    // MARK: Formatting

    static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f }()
    static let dayYearFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d, yyyy"; return f }()
    static let timeFmt: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()

    /// `yyyy-MM-dd HH:mm` from calendar fields. Matches `date(fromStamp:)`.
    static func stamp(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// "alt+space" -> "⌥ Space", for the empty-state hint.
    static func keycaps(_ hotkey: String) -> String {
        hotkey.lowercased().split(separator: "+").map { tok -> String in
            switch tok.trimmingCharacters(in: .whitespaces) {
            case "cmd", "command", "meta", "lcmd", "rcmd": return "⌘"
            case "ropt", "ralt", "roption": return "R⌥"
            case "lopt", "lalt", "loption": return "L⌥"
            case "alt", "opt", "option": return "⌥"
            case "shift", "lshift", "rshift": return "⇧"
            case "ctrl", "control", "lctrl", "rctrl": return "⌃"
            case let k: return k.prefix(1).uppercased() + k.dropFirst()
            }
        }.joined(separator: " ")
    }

    /// Hand-parsed `yyyy-MM-dd HH:mm`. DateFormatter is too slow for 5k lines.
    private static let cal = Calendar.current
    static func date(fromStamp s: Substring) -> Date? {
        let u = Array(s.utf8)
        guard u.count == 16, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x20, u[13] == 0x3A else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b {
                let c = Int(u[i]) - 48
                guard c >= 0, c <= 9 else { return nil }
                v = v * 10 + c
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10),
              let h = num(11, 13), let mi = num(14, 16),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60 else { return nil }
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))
    }
}
