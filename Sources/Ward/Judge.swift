import Foundation

/// Whatever we managed to learn about what's on screen right now.
struct PageContext: Sendable {
    enum Source: String, Sendable { case automation, accessibility }
    var rawURL: String = ""
    var title: String = ""
    /// og:description, keywords, og:video:tag — only present with deep inspection on.
    var metadata: String = ""
    /// Who published it, when the page says so. Kept as its own field rather than
    /// left in `metadata`: a channel you have named is an exact answer, and mixing it
    /// into the text the model reads would turn it back into a guess.
    var channel: String = ""
    var browserBundleID: String = ""
    var browserName: String = ""
    var pid: pid_t = 0
    var source: Source = .accessibility

    var url: URL? { URL(string: rawURL) }
    var host: String? {
        guard let h = url?.host?.lowercased() else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    /// What the user would call this thing, for the log and the block page.
    var label: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return rawURL.isEmpty ? browserName : rawURL
    }
    var signature: String { rawURL.isEmpty ? title : rawURL }
}

/// The decision pipeline. Deterministic rules run first and always win; the model
/// only gets a say on sites you've asked it to judge, and only when nothing
/// explicit already applies.
final class Judge {

    let semantic = Semantic()

    struct Explained: Sendable {
        var verdict: Verdict
        var score: Semantic.Score?
    }

    // MARK: Entry point

    func judge(_ ctx: PageContext, rules: Rules) -> Explained {
        // Anything that isn't a real web page — the block page itself, about:blank,
        // local files, extensions — is left alone.
        guard let url = ctx.url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = ctx.host else {
            return Explained(verdict: .allow("not a web page"), score: nil)
        }

        // A live exception is a decision you already made; it comes before every rule
        // except the ones that decide this isn't a web page at all.
        let title = Semantic.normalise(ctx.title)
        for e in rules.exceptions where e.isLive {
            if e.isHost ? matches(host, any: [e.value]) : (!title.isEmpty && title == e.value) {
                return Explained(
                    verdict: .allow("you let this through",
                                    "\(Int(e.remaining / 60) + 1) min left"), score: nil)
            }
        }

        if matches(host, any: rules.allowedDomains) {
            return Explained(verdict: .allow("allowlisted site", host), score: nil)
        }

        for pattern in rules.blockedURLPatterns where !pattern.isEmpty {
            if ctx.rawURL.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return Explained(verdict: .block("blocked URL pattern", pattern, site: true),
                                 score: nil)
            }
        }

        if matches(host, any: rules.blockedDomains) {
            return Explained(verdict: .block("blocked site", host, site: true), score: nil)
        }

        if matches(host, any: rules.inspectDomains) {
            return judgeContent(ctx, rules: rules, host: host)
        }

        return Explained(verdict: .allow("no rule applies", host), score: nil)
    }

    // MARK: Content judgement

    private func judgeContent(_ ctx: PageContext, rules: Rules, host: String) -> Explained {
        let haystack = Semantic.normalise(ctx.title + " " + ctx.metadata)

        // A bare site name means a homepage, a search page or a still-loading tab.
        // There's nothing to judge yet, so don't guess. Asked of the title alone,
        // not the haystack: on pages like these the metadata describes the *site* —
        // YouTube's homepage carries its own marketing blurb — and judging that
        // blocked the homepage on arrival, before any video had been chosen. The
        // title is what names the thing actually being watched.
        let siteWord = host.split(separator: ".").first.map(String.init) ?? host
        let title = Semantic.normalise(ctx.title)
        if title.count < 12 || title == siteWord
            // A title carrying a URL is a page that hasn't named itself yet — a
            // still-loading tab, or a window title read before the page had one.
            // The address itself was already judged by the site rules above;
            // weighing its crumbs as content blocked a search results page.
            || ctx.title.contains("://") || ctx.title.contains("www.") {
            return Explained(verdict: .allow("nothing to judge yet", host), score: nil)
        }

        if let hard = firstPhrase(in: haystack, from: rules.hardBlockPhrases) {
            return Explained(verdict: .block("never allowed", "\u{201C}\(hard)\u{201D}",
                                            phrase: hard, hard: true), score: nil)
        }

        // Named a publisher, and that settles it — nothing softer gets a say. Placed
        // under the never-allowed list rather than over it, so "never" keeps meaning
        // never: vouching for a channel is not meant to be a way to un-say that.
        if Rules.channelIsTrusted(ctx.channel, in: rules.allowedChannels) {
            return Explained(verdict: .allow("trusted channel", ctx.channel), score: nil)
        }

        // Explicit phrases are the deterministic layer. When only one side fires it
        // settles the matter outright. When both fire — "Past Paper Walkthrough" is
        // study, "The History of Call of Duty" is not — neither wins by precedence;
        // the tie goes to the meaning model, which is the part that can actually read
        // the difference.
        let allowHit = firstPhrase(in: haystack, from: rules.allowPhrases)
        let denyHit  = firstPhrase(in: haystack, from: rules.denyPhrases)

        switch (allowHit, denyHit) {
        case (.some(let a), .none):
            return Explained(verdict: .allow("matched allow phrase", "\u{201C}\(a)\u{201D}",
                                            phrase: a), score: nil)
        case (.none, .some(let d)):
            return Explained(verdict: .block("matched block phrase", "\u{201C}\(d)\u{201D}",
                                            phrase: d), score: nil)
        default:
            break
        }
        let conflicted = allowHit != nil && denyHit != nil

        guard rules.semanticEnabled,
              let score = semantic.score(haystack,
                                         study: rules.studyExamples,
                                         distraction: rules.distractionExamples,
                                         learnedStudy: rules.learnedStudy,
                                         learnedDistraction: rules.learnedDistraction,
                                         learnedRadius: rules.learnedRadius) else {
            return Explained(verdict: conflicted
                             ? .allow("phrases disagreed, no model to break the tie", host)
                             : .allow("no phrase matched", host), score: nil)
        }

        if score.lean > rules.semanticMargin {
            let pct = String(format: "%.3f", score.lean)
            return Explained(
                verdict: .block(score.viaLearned ? "matches something you taught"
                                : conflicted ? "phrases disagreed, reads like a distraction"
                                             : "reads like a distraction",
                                "closest to \u{201C}\(score.nearestDistraction)\u{201D} (lean \(pct))"),
                score: score)
        }

        let pct = String(format: "%.3f", -score.lean)
        return Explained(
            verdict: .allow(score.viaLearned ? "matches something you taught"
                            : conflicted ? "phrases disagreed, reads like study"
                                         : "reads like study",
                            "closest to \u{201C}\(score.nearestStudy)\u{201D} (lean \(pct))"),
            score: score)
    }

    // MARK: Matching helpers

    /// Suffix match, so one entry covers every subdomain: youtube.com also catches
    /// m.youtube.com and music.youtube.com, but never notyoutube.com.
    func matches(_ host: String, any list: [String]) -> Bool {
        Rules.hostMatches(host, any: list)
    }

    /// Whole-word matching, so "edit" doesn't fire on "credit" and "gta" doesn't
    /// fire on "gtaacademy".
    func firstPhrase(in haystack: String, from phrases: [String]) -> String? {
        for phrase in phrases {
            let p = phrase.trimmingCharacters(in: .whitespaces).lowercased()
            guard !p.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: p)
            if haystack.range(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                              options: [.regularExpression]) != nil {
                return p
            }
        }
        return nil
    }
}
