import Foundation

/// "a" / "an" before a swapped variant: "a thumbtack" becomes "an eraser" when the eraser
/// variant is shown. Sound rules, not spelling: "an hour", "a university", "an MBA", "a URL",
/// "an 8", "an 11". The case of the old article is kept ("A" -> "An", "AN" -> "A").
public enum Articles {
    /// The change that fixes the article before `position` (UTF-16) for `nextText`, or nil when
    /// no "a" / "an" precedes it or it is already right. Between the article and the position
    /// only spaces and tabs are allowed, plus opening markup (`*`, `_`, `~`, `[`, quotes).
    public static func fix(in text: String, before position: Int, nextText: String) -> Change? {
        let units = Array(text.utf16)
        guard position >= 0, position <= units.count else { return nil }
        var i = position
        while i > 0, openers.contains(units[i - 1]) { i -= 1 }
        let gapEnd = i
        while i > 0, units[i - 1] == 0x20 || units[i - 1] == 0x09 || units[i - 1] == 0xA0 { i -= 1 }
        guard i < gapEnd else { return nil }                // no space: not a separate word
        let wordEnd = i
        while i > 0, isLetter(units[i - 1]) { i -= 1 }
        let wordStart = i
        guard wordEnd - wordStart == 1 || wordEnd - wordStart == 2 else { return nil }
        if wordStart > 0, isWordChar(units[wordStart - 1]) { return nil }
        let old = String(utf16CodeUnits: Array(units[wordStart..<wordEnd]), count: wordEnd - wordStart)
        guard old.lowercased() == "a" || old.lowercased() == "an" else { return nil }
        guard let wantsAn = wantsAn(nextText) else { return nil }
        let new = cased(wantsAn ? "an" : "a", like: old)
        return new == old ? nil : Change(from: wordStart, to: wordEnd, insert: new)
    }

    /// True for "an", false for "a", nil when `text` has no word to judge.
    public static func wantsAn(_ text: String) -> Bool? {
        guard let word = firstWord(text), let first = word.first else { return nil }
        if first.isASCII, first.isNumber { return numberWantsAn(word) }
        // A letter on its own is read by its name: an X-ray, an F, a U-turn.
        let head = word.prefix { $0 != "-" }
        if head.count == 1 { return letterNameIsVowel(first) }
        if isAcronym(word) && !readsAsWord(word) { return letterNameIsVowel(first) }
        let lower = word.lowercased()
        if silentH.contains(where: { lower.hasPrefix($0) }) { return true }
        if lower == "one" || lower.hasPrefix("one-") || lower.hasPrefix("once") { return false }
        if consonantSoundPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return vowelSoundUniExceptions.contains(where: { lower.hasPrefix($0) })
        }
        return "aeiou".contains(lower.first!)
    }

    // MARK: Rules

    /// Silent "h": an hour, an honest, an heir, an herb.
    static let silentH = ["hour", "honest", "honor", "honour", "heir", "herb"]
    /// Vowel letters that sound like "you" or "w": a university, a one-off, a euro, a user.
    static let consonantSoundPrefixes = ["uni", "use", "usu", "usa", "uti", "ute", "uri", "uro", "ura", "ure", "uku",
                                         "ubi", "eu", "ewe", "uvu"]
    /// "un-" words that start with an "uh" sound: an unimportant, an uninformed, an unidentified.
    static let vowelSoundUniExceptions = ["unim", "unin", "unid", "unil", "unindent"]

    /// Letters whose English name starts with a vowel sound: an F, an MBA, an X-ray.
    static func letterNameIsVowel(_ c: Character) -> Bool { "AEFHILMNORSX".contains(Character(c.uppercased())) }

    /// Capitals read as a word, not letter by letter: NASA, NATO, IEEE (4+ letters, 2+ vowels,
    /// a vowel in the first two letters). MBA, URL, SQL, HTML are read as letters.
    static func readsAsWord(_ word: String) -> Bool {
        let letters = Array(word.filter { $0.isLetter }.uppercased())
        let vowels = letters.filter { "AEIOU".contains($0) }.count
        return letters.count >= 4 && vowels >= 2 && ("AEIOU".contains(letters[0]) || "AEIOU".contains(letters[1]))
    }

    /// 2+ letters, all capitals (digits allowed after the first): MBA, URL, FBI, MP3.
    static func isAcronym(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        guard letters.count >= 2, let f = word.first, f.isLetter else { return false }
        return letters.allSatisfy { $0.isUppercase }
    }

    /// an 8, an 80, an 800, an 11, an 18, an 11,000; a 1, a 100.
    static func numberWantsAn(_ word: String) -> Bool {
        let digits = String(word.prefix { $0.isNumber || $0 == "," })
        let groups = digits.split(separator: ",")
        guard let lead = groups.first.map(String.init), let first = lead.first else { return false }
        if first == "8" { return true }
        // The spoken lead group: "11,000" and "11000" start with "eleven"; "110" with "one".
        let leadLength = groups.count > 1 ? lead.count : (lead.count % 3 == 0 ? 3 : lead.count % 3)
        return leadLength == 2 && (lead.hasPrefix("11") || lead.hasPrefix("18"))
    }

    static let openers: Set<UInt16> = Set("*_~[\"'(\u{201C}\u{2018}".utf16)

    static func firstWord(_ text: String) -> String? {
        let trimmed = text.drop { !$0.isLetter && !$0.isNumber }
        let word = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "," || $0 == "-" }
        let w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: ",-"))
        return w.isEmpty ? nil : w
    }

    static func isLetter(_ u: UInt16) -> Bool {
        (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A)
    }

    static func isWordChar(_ u: UInt16) -> Bool {
        if isLetter(u) || (u >= 0x30 && u <= 0x39) || u == 0x27 || u == 0x2019 || u == 0x5F { return true }
        if u >= 0x80, let s = Unicode.Scalar(u) { return CharacterSet.letters.contains(s) }
        return false
    }

    static func cased(_ new: String, like old: String) -> String {
        guard let first = old.first, first.isUppercase else { return new }
        if old.count == 2 && old.allSatisfy({ $0.isUppercase }) { return new.uppercased() }
        return new.prefix(1).uppercased() + new.dropFirst()
    }
}
