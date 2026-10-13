import Foundation

/// Spelled-out numbers become digits before a take is pasted or written to a
/// meeting note: "twenty five" -> "25", "four point five" -> "4.5",
/// "twenty first" -> "21st", "twenty twenty six" -> "2026".
///
/// Parakeet writes digits on its own most of the time ("25 apples", "$3.50")
/// but not always, and short takes come back spelled out more often. This is
/// plain word matching, no AI, so it only ever touches number words.
///
/// "one" is the one word that is usually not a number ("one of them", "no
/// one", "this one"), so on its own it only turns into 1 next to a unit
/// ("one percent"), after a label ("step one"), or beside another number
/// ("one or two"). Every other number word converts.
enum Numbers {
    static func digitize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let words = tokenize(text)
        guard !words.isEmpty else { return text }

        var out = ""
        var cursor = text.startIndex
        var i = 0
        while i < words.count {
            guard let run = parseRun(words, from: i) else { i += 1; continue }
            let convert: Bool
            if run.numberWords >= 2 {
                convert = true
            } else if run.kind == .ordinal {
                convert = run.value >= 10
            } else if run.value == 1 && run.kind == .unit {
                convert = oneIsANumber(words, at: i)
            } else {
                convert = run.kind != .scale
            }
            if convert {
                let first = words[i]
                let last = words[run.end - 1]
                out += text[cursor..<first.range.lowerBound]
                out += run.rendered
                cursor = last.range.upperBound
            }
            i = run.end
        }
        out += text[cursor...]
        return out
    }

    // MARK: Vocabulary

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    /// "second" is deliberately absent: "twenty second delay" is a duration.
    /// So are "hundredth" and up, which are usually fractions.
    private static let ordinals: [String: Int] = [
        "first": 1, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16,
        "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
        "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90,
    ]

    /// After a lone "one", these make it a count: "one percent", "one hour".
    private static let unitsAfterOne: Set<String> = [
        "percent", "dollar", "dollars", "cent", "cents", "buck", "bucks", "o'clock",
        "am", "pm", "hour", "hours", "hr", "hrs", "minute", "minutes", "min", "mins",
        "second", "seconds", "sec", "secs", "day", "days", "week", "weeks", "month", "months",
        "year", "years", "meter", "meters", "metre", "metres", "mile", "miles", "foot", "feet",
        "inch", "inches", "pound", "pounds", "lb", "lbs", "kilogram", "kilograms", "kg",
        "gram", "grams", "mm", "cm", "km", "millimeter", "millimeters", "centimeter",
        "centimeters", "kilometer", "kilometers", "degree", "degrees", "liter", "liters",
        "litre", "litres", "gallon", "gallons", "ounce", "ounces", "oz", "knot", "knots",
        "psi", "hertz", "hz", "volt", "volts", "amp", "amps", "watt", "watts", "byte", "bytes",
        "kb", "mb", "gb", "tb", "x",
    ]
    /// Before a lone "one", these make it a label: "step one", "number one".
    private static let labelsBeforeOne: Set<String> = [
        "number", "chapter", "page", "version", "step", "phase", "part", "level", "figure",
        "section", "item", "option", "room", "floor", "gate", "iteration", "take", "round",
        "week", "day", "stage", "grade", "table", "line", "row", "column", "tier", "plus",
        "minus", "times", "equals",
    ]
    /// "one or two", "one to ten": a number word on the far side settles it.
    private static let joiners: Set<String> = ["or", "to", "and", "through", "by"]

    private enum Kind { case unit, teen, tens, scale, ordinal }

    private static func kind(of w: String) -> (Kind, Int)? {
        if let v = units[w] { return (.unit, v) }
        if let v = teens[w] { return (.teen, v) }
        if let v = tens[w] { return (.tens, v) }
        if let v = scales[w] { return (.scale, v) }
        if let v = ordinals[w] { return (.ordinal, v) }
        return nil
    }

    private static func isNumberWord(_ w: String) -> Bool {
        kind(of: w) != nil || w.allSatisfy(\.isNumber)
    }

    // MARK: Tokens

    private struct Word {
        let text: String            // lowercased
        let range: Range<String.Index>
        let gapBefore: String       // text between the previous word and this one
    }

    private static let wordPattern = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]+(?:'[\\p{L}]+)*")

    private static func tokenize(_ text: String) -> [Word] {
        let ns = NSRange(text.startIndex..., in: text)
        var words: [Word] = []
        var prevEnd = text.startIndex
        for m in wordPattern.matches(in: text, range: ns) {
            guard let r = Range(m.range, in: text) else { continue }
            words.append(Word(text: text[r].lowercased(), range: r, gapBefore: String(text[prevEnd..<r.lowerBound])))
            prevEnd = r.upperBound
        }
        return words
    }

    // MARK: Parsing

    private struct Run {
        let end: Int            // index after the last word of the run
        let numberWords: Int    // not counting "and" or "point"
        let kind: Kind          // of the only word when numberWords == 1
        let value: Int
        let rendered: String
    }

    /// One number spoken as a phrase, starting at `start`. Nil when the word
    /// there is not a number word. Words only join across a single space or
    /// hyphen, so "five, six" stays two numbers.
    private static func parseRun(_ words: [Word], from start: Int) -> Run? {
        var i = start
        var total = 0          // finished thousands/millions groups
        var current = 0        // the group being spoken now
        var count = 0
        var lastKind: Kind? = nil
        var sawScale = false
        var firstKind: Kind = .unit
        var ordinal: Int? = nil
        var decimals: String? = nil

        func joined(_ k: Int) -> Bool {
            k == start || words[k].gapBefore == " " || words[k].gapBefore == "-"
        }
        /// Can a small number word (one..ninety) add onto `current`?
        func groupOpen(for k: Kind) -> Bool {
            guard let lk = lastKind else { return true }
            if lk == .scale { return true }
            return lk == .tens && current % 10 == 0 && k == .unit   // "twenty" + "five"
        }

        // "a hundred", "a thousand"
        if (words[i].text == "a" || words[i].text == "an"),
           i + 1 < words.count, joined(i + 1), scales[words[i + 1].text] != nil {
            current = 1
            count = 1
            i += 1
        } else if kind(of: words[i].text) == nil {
            return nil
        }

        loop: while i < words.count, joined(i) {
            let w = words[i].text

            if w == "and" {
                guard lastKind == .scale, i + 1 < words.count, joined(i + 1),
                      let (nk, _) = kind(of: words[i + 1].text), nk != .scale else { break }
                i += 1
                continue
            }
            if w == "point" {
                // Digits after the point are read one at a time: "three point one four".
                guard count > 0, ordinal == nil else { break }
                var j = i + 1
                var digits = ""
                while j < words.count, joined(j), let (k, v) = kind(of: words[j].text), k == .unit {
                    digits.append(String(v))
                    j += 1
                }
                guard !digits.isEmpty else { break }
                decimals = digits
                count += digits.count
                i = j
                break
            }
            guard let (k, v) = kind(of: w) else { break }
            if count == 0 { firstKind = k }

            switch k {
            case .unit, .teen, .tens:
                if groupOpen(for: k) {
                    current += v
                } else if k != .unit, !sawScale, total == 0, (1...99).contains(current) {
                    // Two groups read back to back: "twenty twenty six" -> 2026,
                    // "nineteen ninety five" -> 1995, "one twenty" -> 120.
                    total = current * 100
                    current = v
                } else {
                    break loop          // "five six": two separate numbers
                }
            case .scale:
                if v == 100 {
                    guard lastKind != .scale, current > 0 else { break loop }   // "hundred" needs "a" or a count
                    current *= 100
                } else {
                    if lastKind == nil && current == 0 { break loop }           // "thousand" on its own
                    if lastKind == .scale, let lv = scales[words[i - 1].text], lv != 100 { break loop }
                    total += max(current, 1) * v
                    current = 0
                }
                sawScale = true
            case .ordinal:
                // Ends the run: "twenty first" -> 21st.
                guard groupOpen(for: v < 10 ? .unit : .teen) else { break loop }
                current += v
                ordinal = total + current
                count += 1
                lastKind = k
                i += 1
                break loop
            }
            count += 1
            lastKind = k
            i += 1
        }

        guard count > 0 else { return nil }
        let value = total + current
        var rendered = String(value)
        if let decimals { rendered += "." + decimals }
        if let ordinal { rendered = String(ordinal) + ordinalSuffix(ordinal) }
        return Run(end: i, numberWords: count, kind: count == 1 ? firstKind : .unit,
                   value: value, rendered: rendered)
    }

    private static func ordinalSuffix(_ n: Int) -> String {
        let m = n % 100
        if (11...13).contains(m) { return "th" }
        switch n % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// A lone "one" at `i`: is it a count?
    private static func oneIsANumber(_ words: [Word], at i: Int) -> Bool {
        let prev = i > 0 ? words[i - 1].text : nil
        let next = i + 1 < words.count ? words[i + 1].text : nil
        if let next, unitsAfterOne.contains(next) { return true }
        if let prev, labelsBeforeOne.contains(prev) || prev.allSatisfy(\.isNumber) { return true }
        if let next, joiners.contains(next), i + 2 < words.count, isNumberWord(words[i + 2].text) { return true }
        if let prev, joiners.contains(prev), i >= 2, isNumberWord(words[i - 2].text) { return true }
        return false
    }
}
