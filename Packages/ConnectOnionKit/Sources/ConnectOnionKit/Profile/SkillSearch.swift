import Foundation

// Skill Search matches prefix first, then substring, then letters in order
public enum SkillSearch {
    public static func rank(_ names: [String], query: String) -> [String] {
        let needle = fold(query)
        guard !needle.isEmpty else {
            return names
        }
        var prefix: [String] = []
        var substring: [String] = []
        var letters: [String] = []
        for name in names {
            let haystack = fold(name)
            if haystack.hasPrefix(needle) {
                prefix.append(name)
            } else if haystack.contains(needle) {
                substring.append(name)
            } else if hasLettersInOrder(needle, in: haystack) {
                letters.append(name)
            }
        }
        return prefix + substring + letters
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func hasLettersInOrder(_ needle: String, in haystack: String) -> Bool {
        var remaining = needle.makeIterator()
        guard var wanted = remaining.next() else {
            return true
        }
        for character in haystack where character == wanted {
            guard let next = remaining.next() else {
                return true
            }
            wanted = next
        }
        return false
    }
}
