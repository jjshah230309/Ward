import Foundation

/// Turns a correction into something that generalises.
///
/// Two things happen when you say "that should have been blocked". The title is added
/// to the model's distraction examples, which immediately pulls anything similar to
/// the same side. And the specific terms in it are offered up as never-allowed
/// phrases, because "forza horizon" as a named thing is a far stronger rule than any
/// nudge to the embedding.
enum Teacher {

    private static let stopwords: Set<String> = [
        "a","an","the","and","or","but","if","then","than","that","this","these","those",
        "is","are","was","were","be","been","being","am","do","does","did","doing",
        "i","you","he","she","it","we","they","me","him","her","us","them","my","your",
        "his","its","our","their","mine","yours","ours","theirs",
        "in","on","at","to","from","with","without","for","of","by","about","into",
        "over","under","up","down","out","off","again","once","here","there","when",
        "where","why","how","what","which","who","whom","all","any","both","each",
        "few","more","most","other","some","such","no","nor","not","only","own","same",
        "so","too","very","can","will","just","dont","should","now","new","best","top",
        "vs","ep","episode","part","full","official","video","watch","live","hd","4k",
        "vol","season","update","one","two","three"
    ]

    private static func tokens(_ text: String) -> [String] {
        Semantic.normalise(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" })
            .map(String.init)
            .filter { $0.count > 1 && Int($0) == nil }
    }

    /// Phrases worth offering, most specific first: adjacent word pairs before single
    /// words, and nothing already covered by an existing rule.
    static func candidates(from title: String, rules: Rules) -> [String] {
        let words = tokens(title)
        guard !words.isEmpty else { return [] }

        let existing = rules.hardBlockPhrases + rules.denyPhrases + rules.allowPhrases

        // Words already spoken for by a rule that fires on this title. Offering
        // "horizon" when "forza" already catches it is noise at best, and at worst a
        // far broader rule than intended.
        var covered = Set<String>()
        for phrase in existing {
            let parts = phrase.split(separator: " ").map(String.init)
            guard parts.allSatisfy({ words.contains($0) }) else { continue }
            covered.formUnion(parts)
        }

        let taken = Set(existing)
        var out: [String] = []

        func offer(_ phrase: String) {
            let parts = phrase.split(separator: " ").map(String.init)
            guard !taken.contains(phrase),
                  !out.contains(phrase),
                  parts.allSatisfy({ !covered.contains($0) }) else { return }
            out.append(phrase)
        }

        for i in 0..<max(0, words.count - 1) {
            let a = words[i], b = words[i + 1]
            guard !stopwords.contains(a), !stopwords.contains(b) else { continue }
            offer("\(a) \(b)")
        }
        for word in words where !stopwords.contains(word) && word.count > 2 {
            offer(word)
        }
        return Array(out.prefix(6))
    }
}
