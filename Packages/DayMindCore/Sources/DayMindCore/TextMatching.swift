import Foundation

/// Lightweight fuzzy matching used to find "the plumber reminder" among stored reminders.
public enum TextMatching {
    static let stopWords: Set<String> = ["the", "a", "an", "to", "my", "me", "for", "of", "and", "at", "on", "in", "with", "about", "reminder", "task", "that", "this", "it"]

    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { stem($0) }
    }

    /// Very small stemmer: strips plural/tense suffixes so "calls" matches "call".
    static func stem(_ w: String) -> String {
        var s = w
        for suffix in ["ing", "ed", "es", "s"] where s.count > suffix.count + 2 && s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        return s
    }

    /// 0…1 similarity: token overlap weighted toward the query, plus a bonus for substring containment.
    public static func score(query: String, against candidate: String) -> Double {
        let all = tokens(query)
        let filtered = all.filter { !stopWords.contains($0) }
        let q = filtered.isEmpty ? all : filtered
        let c = tokens(candidate)
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        let cset = Set(c)
        let hits = q.filter { token in cset.contains(token) || c.contains { $0.hasPrefix(token) || token.hasPrefix($0) && $0.count > 3 } }.count
        var score = Double(hits) / Double(q.count)
        if candidate.lowercased().contains(query.lowercased()) { score = max(score, 0.9) }
        return min(score, 1)
    }

    /// Ranks candidates by score; drops those under `threshold`.
    public static func rank<T>(_ items: [T], query: String, text: (T) -> String, threshold: Double = 0.5) -> [(item: T, score: Double)] {
        items.map { ($0, score(query: query, against: text($0))) }
            .filter { $0.1 >= threshold }
            .sorted { $0.1 > $1.1 }
            .map { (item: $0.0, score: $0.1) }
    }
}
