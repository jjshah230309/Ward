import Foundation

// MARK: - What an enforcement action looks like

enum BrowserAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case redirect   // navigate the offending tab to the local block page
    case closeTab   // close the tab outright
    case hide       // hide the whole browser and throw up the shield
    var id: String { rawValue }
    var label: String {
        switch self {
        case .redirect: return "Redirect the tab"
        case .closeTab: return "Close the tab"
        case .hide:     return "Hide the browser"
        }
    }
}

enum AppAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case quit
    case hide
    case warn
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quit: return "Quit it"
        case .hide: return "Hide it"
        case .warn: return "Just warn me"
        }
    }
}

/// Turns Ward on for your study hours and off outside them, so it isn't something
/// you have to remember to switch on.
struct Schedule: Codable, Sendable, Equatable {
    var enabled: Bool = false
    /// Calendar weekdays: 1 = Sunday through 7 = Saturday. Weekdays by default.
    var days: Set<Int> = [2, 3, 4, 5, 6]
    /// Minutes from midnight.
    var start: Int = 9 * 60
    var end: Int = 18 * 60

    /// A schedule with no days, or a zero-length window, describes no time at all.
    /// Treated as "not in effect" rather than "always off" — otherwise deselecting
    /// every day switches Ward off with no boundary that could ever turn it back on.
    var isUsable: Bool { enabled && !days.isEmpty && start != end }

    static func label(_ minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    /// True when `date` falls inside the window. Handles a window that runs past
    /// midnight, where the end time is numerically before the start.
    func covers(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let h = parts.hour, let m = parts.minute
        else { return false }
        let now = h * 60 + m

        if start == end { return false }
        if start < end {
            return days.contains(weekday) && now >= start && now < end
        }
        // Overnight: the tail after midnight belongs to the previous day's window.
        if now >= start { return days.contains(weekday) }
        let yesterday = weekday == 1 ? 7 : weekday - 1
        return days.contains(yesterday) && now < end
    }

    var summary: String {
        let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let picked = (1...7).filter { days.contains($0) }
        let dayText: String
        if picked.count == 7 { dayText = "every day" }
        else if picked == [2, 3, 4, 5, 6] { dayText = "weekdays" }
        else if picked == [1, 7] { dayText = "weekends" }
        else if picked.isEmpty { dayText = "no days" }
        else { dayText = picked.map { names[$0] }.joined(separator: " ") }
        return "\(dayText), \(Schedule.label(start))\u{2013}\(Schedule.label(end))"
    }
}

/// A deliberate, self-expiring hole in the rules. Needing one blocked page shouldn't
/// mean switching the whole thing off — that's how a blocker ends up off for an hour.
struct Exception: Codable, Identifiable, Hashable, Sendable {
    /// Either a host ("reddit.com") or a normalised page title, depending on which
    /// kind of rule did the blocking.
    var value: String
    var isHost: Bool
    var label: String
    var until: Date

    var id: String { (isHost ? "h:" : "t:") + value }
    var isLive: Bool { until > Date() }
    var remaining: Int { max(0, Int(until.timeIntervalSinceNow.rounded(.up))) }
}

struct BlockedApp: Codable, Identifiable, Hashable, Sendable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

// MARK: - The rulebook

struct Rules: Codable, Sendable {

    var enabled: Bool = true

    /// Bumped whenever the shipped defaults gain entries worth handing to people who
    /// already have a rules.json. Files written before this existed decode as 0.
    var schemaVersion: Int = 0
    static let currentSchemaVersion = 3

    /// While this is in the future, the rulebook cannot be weakened or switched off.
    var lockUntil: Date?

    /// When the running commitment session began, so it can be summarised at the end.
    var lockStartedAt: Date?

    /// A pause that ends by itself. Turning Ward off "just for a second" and never
    /// turning it back on is the most common way a blocker stops working, so a pause
    /// carries its own deadline.
    var pauseUntil: Date?

    // Apps
    var blockedApps: [BlockedApp] = []
    var appAction: AppAction = .quit

    // Sites
    var allowedDomains: [String] = []
    var blockedDomains: [String] = []
    /// Sites whose *content* gets judged rather than being all-or-nothing.
    var inspectDomains: [String] = []
    /// Publishers you have vouched for by name. Everything they post is study, so no
    /// phrase list and no amount of model guessing gets a say. This is the answer to
    /// a title that names a person and nothing else — "Steve Vai — For The Love Of
    /// God" tells the model nothing about a guitar, but the channel does.
    var allowedChannels: [String] = []
    var blockedURLPatterns: [String] = []
    /// Time-boxed exceptions, pruned as they expire.
    var exceptions: [Exception] = []
    var browserAction: BrowserAction = .redirect

    // Content judgement
    /// Named things you never want, whatever else the title claims. These beat
    /// allow phrases outright — "minecraft" is a far more specific signal than
    /// "tutorial", so "Minecraft Redstone Tutorial" should not be a coin toss.
    var hardBlockPhrases: [String] = []
    var allowPhrases: [String] = []
    var denyPhrases: [String] = []
    var semanticEnabled: Bool = true
    /// How much closer to a distraction example a title must sit before it's blocked.
    var semanticMargin: Double = 0.03
    var studyExamples: [String] = []
    var distractionExamples: [String] = []

    /// Corrections. Kept apart from the curated examples so they stay reviewable and
    /// removable — a correction you regret should be one click to undo, not something
    /// quietly baked into the rulebook.
    var learnedDistraction: [String] = []
    var learnedStudy: [String] = []
    /// How near a title must sit to something you taught before that lesson applies.
    /// Tight on purpose — see the note in Semantic.score.
    var learnedRadius: Double = 0.45
    /// Read page metadata (tags, description) via the browser, not just the title.
    var deepInspection: Bool = true

    // Behaviour
    /// What stands between an impulse and switching Ward off.
    var challenge = ChallengeSettings()

    /// The quiz section: kept apart from `challenge` so practising for fun never
    /// quietly changes what guards your rules.
    var practiceKind: ChallengeKind = .arithmetic
    var practiceIQ: Int = IQ.default
    var practice = PracticeStats()

    /// The system prompt is shown once and never again. Repeating it on every launch
    /// is nagging, and it cannot fix the case where a stale entry is the problem.
    var askedForAccessibility: Bool = false

    /// False until the welcome has been dismissed, so a fresh copy explains itself.
    var setupDone: Bool = false

    var schedule = Schedule()

    /// System-wide shortcuts for correcting a verdict without switching apps.
    var hotkeysEnabled: Bool = true

    /// Interface zoom. Scales type and layout rather than magnifying pixels.
    var uiScale: Double = 1.0
    /// Whether Ward appears in the Dock and in Cmd-Tab.
    var showInDock: Bool = true
    /// Whether it keeps a menu bar icon. With both off it runs completely unseen;
    /// opening Ward again from Applications brings the window back.
    var showInMenuBar: Bool = true

    var pollInterval: Double = 1.0
    var shieldSeconds: Double = 3.5
    var playSound: Bool = true

    /// What the model actually compares against: curated examples plus what it's been taught.
    var correctionCount: Int { learnedStudy.count + learnedDistraction.count }

    /// Folds newly shipped default phrases into an existing rulebook without
    /// disturbing anything you've added — or resurrecting anything you deleted after
    /// this ran, since the version only moves forward once.
    mutating func migrateIfNeeded() -> Bool {
        guard schemaVersion < Rules.currentSchemaVersion else { return false }
        let fresh = Rules.default
        var added = false

        func union(_ path: WritableKeyPath<Rules, [String]>) {
            for item in fresh[keyPath: path] where !self[keyPath: path].contains(item) {
                self[keyPath: path].append(item)
                added = true
            }
        }

        // The model's vocabulary — phrases and examples — is what keeps improving,
        // so those come across. Your site lists are yours and are left alone.
        union(\.hardBlockPhrases)
        union(\.denyPhrases)
        union(\.allowPhrases)
        union(\.studyExamples)
        union(\.distractionExamples)
        union(\.inspectDomains)
        // Not `allowedChannels`: like the site lists, whom you trust is yours to say.

        schemaVersion = Rules.currentSchemaVersion
        return added
    }

    /// Strips the state that only makes sense on the machine it came from.
    var portable: Rules {
        var copy = self
        copy.lockUntil = nil
        copy.pauseUntil = nil
        copy.exceptions = []
        return copy
    }

    /// Adds everything from `other` that this rulebook lacks — and only things that
    /// tighten. Allowed sites are deliberately excluded: they are the one list where
    /// adding an entry weakens the rules, and an import should never do that quietly.
    func merged(with other: Rules) -> Rules {
        var next = self
        func union(_ path: WritableKeyPath<Rules, [String]>) {
            for item in other[keyPath: path] where !next[keyPath: path].contains(item) {
                next[keyPath: path].append(item)
            }
        }
        union(\.blockedDomains); union(\.inspectDomains); union(\.blockedURLPatterns)
        // Deliberately not allowedChannels — importing one would loosen the rules.
        union(\.hardBlockPhrases); union(\.denyPhrases); union(\.allowPhrases)
        union(\.studyExamples); union(\.distractionExamples)
        union(\.learnedDistraction); union(\.learnedStudy)
        for app in other.blockedApps
        where !next.blockedApps.contains(where: { $0.bundleID == app.bundleID }) {
            next.blockedApps.append(app)
        }
        return next
    }

    /// Wholesale swap, but a running commitment session and this machine's interface
    /// preferences survive it.
    func replaced(by other: Rules) -> Rules {
        var next = other.portable
        next.lockUntil = lockUntil
        next.uiScale = uiScale
        next.showInDock = showInDock
        // An imported file carries its own `enabled`, and a file written while Ward
        // was off would switch it off on import — the one weakening an import is
        // never allowed to make.
        next.enabled = true
        return next
    }

    /// Phrases match on whole words, so if "gaming" is already a rule then adding
    /// "gaming pc" can never fire on anything the first one misses. Returns the
    /// existing phrase that already covers the candidate, if there is one.
    static func coveringPhrase(for candidate: String, in list: [String]) -> String? {
        let words = candidate.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        for existing in list {
            let e = existing.lowercased()
            guard e != candidate.lowercased() else { continue }
            let parts = e.split(separator: " ").map(String.init)
            guard !parts.isEmpty, parts.count <= words.count else { continue }
            // A contiguous run of whole words is what the matcher would find.
            for start in 0...(words.count - parts.count)
            where Array(words[start..<(start + parts.count)]) == parts {
                return existing
            }
        }
        return nil
    }

    /// Dock icon, menu bar icon and the shortcut are the only three routes to the
    /// window. With all three off there is no way to open Ward at all — reopening a
    /// running app just activates it — so the last one is always put back.
    @discardableResult
    mutating func ensureAWayIn() -> Bool {
        if showInDock || showInMenuBar || hotkeysEnabled { return false }
        showInMenuBar = true
        return true
    }

    /// Whether this publisher is one you have vouched for. Compared on the name with
    /// case, surrounding space and runs of space flattened, so "paul davids" typed
    /// into the box matches "Paul  Davids" as the page reports it.
    static func channelIsTrusted(_ channel: String, in list: [String]) -> Bool {
        let wanted = flattened(channel)
        guard !wanted.isEmpty else { return false }
        return list.contains { flattened($0) == wanted }
    }

    private static func flattened(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Suffix match, so one entry covers every subdomain: youtube.com also catches
    /// m.youtube.com, but never notyoutube.com. Shared with the Judge so the two can
    /// never disagree about what a rule covers.
    static func hostMatches(_ host: String, any list: [String]) -> Bool {
        for entry in list {
            let e = entry.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
            guard !e.isEmpty else { continue }
            let bare = e.hasPrefix("www.") ? String(e.dropFirst(4)) : e
            if host == bare || host.hasSuffix("." + bare) { return true }
        }
        return false
    }

    /// Whether the phrase and model rules run at all for this host. They only apply on
    /// the sites you've asked to be judged by content; everywhere else a lesson about a
    /// page can never fire, because nothing ever consults it.
    func judgesContent(on host: String) -> Bool {
        Rules.hostMatches(host, any: inspectDomains)
    }

    /// A malformed pattern silently never matches, which looks identical to a rule
    /// that simply isn't firing. Name the broken ones instead.
    static func patternProblems(_ patterns: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for p in patterns where !p.isEmpty {
            do { _ = try NSRegularExpression(pattern: p) }
            catch { out[p] = "Not a valid regular expression - this rule never matches." }
        }
        return out
    }

    var isLocked: Bool {
        guard let lockUntil else { return false }
        return lockUntil > Date()
    }

    var liveExceptions: [Exception] { exceptions.filter(\.isLive) }

    var isPaused: Bool {
        guard let pauseUntil else { return false }
        return pauseUntil > Date()
    }

    /// What the engine actually asks: on, and not sitting out a pause.
    var isActive: Bool { enabled && !isPaused }

    var pauseRemaining: Int {
        guard let pauseUntil else { return 0 }
        return max(0, Int(pauseUntil.timeIntervalSinceNow.rounded(.up)))
    }

    static let `default`: Rules = {
        var r = Rules()
        r.schemaVersion = Rules.currentSchemaVersion

        r.blockedApps = []

        r.blockedDomains = [
            "reddit.com", "twitter.com", "x.com", "instagram.com", "facebook.com",
            "tiktok.com", "twitch.tv", "netflix.com", "9gag.com", "snapchat.com",
            "pinterest.com", "roblox.com", "discord.com", "primevideo.com",
            "hulu.com", "disneyplus.com", "crunchyroll.com"
        ]

        r.allowedDomains = [
            "wikipedia.org", "khanacademy.org", "scholar.google.com", "arxiv.org",
            "jstor.org", "notion.so", "desmos.com", "wolframalpha.com",
            "stackoverflow.com", "overleaf.com", "coursera.org", "edx.org",
            "brilliant.org", "physicsandmathstutor.com", "savemyexams.com"
        ]

        // Sites where the answer depends on *what* you're looking at.
        r.inspectDomains = [
            "youtube.com", "youtu.be", "vimeo.com", "dailymotion.com",
            "bilibili.com", "odysee.com", "rumble.com", "nebula.tv"
        ]

        r.blockedURLPatterns = [
            #"youtube\.com/shorts/"#,
            #"youtube\.com/gaming"#,
            #"youtube\.com/feed/trending"#
        ]

        // A phrase hit is a hard, deterministic answer — it beats the model.
        r.hardBlockPhrases = [
            "minecraft", "fortnite", "roblox", "valorant", "call of duty", "warzone",
            "fifa", "ea fc", "gta", "elden ring", "league of legends", "counter-strike",
            "gameplay", "let's play", "lets play", "speedrun", "mukbang",
            "storytime", "story time", "grwm", "get ready with me",
            "forza", "gran turismo", "need for speed", "apex legends", "overwatch",
            "rocket league", "fall guys", "among us", "genshin", "honkai",
            "clash of clans", "brawl stars", "pubg", "rainbow six", "battlefield",
            "red dead", "cyberpunk 2077", "assassin's creed", "the sims",
            "animal crossing", "super mario", "zelda", "pokemon", "skyrim",
            "terraria", "stardew valley", "rust", "dota",
            "madden", "nba 2k", "wwe 2k", "f1 24", "f1 25"
        ]

        r.denyPhrases = [
            "walkthrough", "no commentary playthrough", "montage",
            "funny moments", "fail compilation",
            "prank", "reaction", "tier list", "unboxing", "vlog", "asmr",
            "highlights", "full match", "best goals", "trailer", "teaser",
            "tiktok compilation", "try not to laugh", "drama explained", "beef",
            "edit", "amv", "meme",
            "day in my life", "day in the life", "haul", "room tour",
            "gossip", "exposed", "clapback", "24 hours", "i spent",
            "ranking every", "taste test", "worst to best"
        ]

        r.allowPhrases = [
            "lecture", "tutorial", "course", "revision", "exam", "past paper",
            "explained", "derivation", "proof", "chapter", "textbook", "syllabus",
            "documentary", "how it works",
            "problem set", "worked example", "study with me", "introduction to", "fundamentals of", "masterclass", "seminar",
            "explains", "explaining", "explainer", "analysis of", "history of",
            "guide to", "deep dive", "case study", "lesson", "theorem",
            "how it actually works", "step by step",
            // Playing an instrument is a skill being practised, not an evening lost.
            // These are the words a player's titles actually use.
            "guitar", "guitars", "guitarist", "fretboard", "fingerstyle",
            "tablature", "guitar tab", "guitar tabs", "chord", "chords",
            "chord progression", "riff", "riffs", "strumming", "picking",
            "alternate picking", "sweep picking", "arpeggio", "arpeggios",
            "pentatonic", "barre chord", "capo", "scale shapes",
            "music theory", "how to play", "backing track", "practice routine",
            "luthier", "pickups", "guitar tone", "amp settings"
        ]

        r.studyExamples = [
            "a university lecture explaining a topic in depth",
            "a step by step tutorial teaching a technical skill",
            "an educational explanation of a scientific concept",
            "a worked example solving an exam question",
            "a documentary about history or science",
            "a programming tutorial building a project",
            "revision notes and exam preparation for a school subject",
            "an academic seminar or conference talk",
            "a maths problem solved on a whiteboard",
            "an explainer breaking down how something works",
            // Educational content *about* games or sport is still study; without
            // these the model reads the topic and stops there.
            "an academic analysis of the video game industry and its economics",
            "an engineering breakdown of how game graphics and physics are built",
            "a history documentary about sport and the olympic movement",
            "a strategy lesson teaching chess openings and theory",
            "a critical analysis of film-making technique and cinematography",
            // Learning an instrument. Without these a guitarist's name on its own —
            // no lesson word anywhere in the title — read as entertainment, and the
            // "a music video or song" example on the other side pulled it further.
            "a guitar lesson teaching a song or a playing technique",
            "a guitarist demonstrating technique and playing through a piece",
            "music theory explained for someone learning an instrument",
            "a breakdown of chords, scales and fretboard positions",
            "a masterclass in instrumental technique by a skilled player",
            "an explanation of guitar gear, amplifiers and tone"
        ]

        r.distractionExamples = [
            "a video game walkthrough with gameplay commentary",
            "a funny meme compilation for entertainment",
            "a vlog about someone's daily life",
            "a reaction video to another creator's content",
            "sports match highlights and best goals",
            "a celebrity drama and gossip video",
            "a movie trailer or teaser for entertainment",
            "a prank video on the street",
            "an esports tournament match",
            "a music video or song",
            "a live stream of someone playing a game",
            "an unboxing and product hype video",
            // Vlog and stunt formats, which share no vocabulary with gaming.
            "a personal storytime about relationship drama",
            "a day in the life lifestyle vlog with a morning routine",
            "an endurance stunt where someone does something for 24 hours",
            "ranking or taste testing food for entertainment",
            "a challenge video made to chase views",
            "an internet drama commentary about a creator"
        ]

        return r
    }()
}

// MARK: - Decisions

struct Verdict: Sendable {
    enum Call { case allow, block }
    var call: Call
    var reason: String
    var detail: String = ""
    /// Set when a phrase settled it, so a correction can point at what to change.
    var phrase: String?
    /// True when the phrase came from the never-allowed tier.
    var phraseWasHard = false
    /// True when a site or URL rule stopped it, rather than anything about the content.
    var fromSiteRule = false

    static func allow(_ r: String, _ d: String = "", phrase: String? = nil) -> Verdict {
        .init(call: .allow, reason: r, detail: d, phrase: phrase)
    }
    static func block(_ r: String, _ d: String = "", phrase: String? = nil,
                      hard: Bool = false, site: Bool = false) -> Verdict {
        .init(call: .block, reason: r, detail: d, phrase: phrase,
              phraseWasHard: hard, fromSiteRule: site)
    }
}

struct LogEntry: Identifiable, Codable, Sendable {
    var id = UUID()
    var at = Date()
    var blocked: Bool
    var what: String
    var reason: String
}

// MARK: - Forgiving decode
//
// The synthesised decoder throws on any missing key, which would mean one typo in a
// hand-edited rules.json silently resets every rule. Every field falls back instead.

extension Rules {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Rules()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: k)) .flatMap { $0 } ?? fallback
        }
        self.init()
        enabled            = v(.enabled, d.enabled)
        schemaVersion      = v(.schemaVersion, 0)
        lockUntil          = (try? c.decodeIfPresent(Date.self, forKey: .lockUntil)) ?? nil
        pauseUntil         = (try? c.decodeIfPresent(Date.self, forKey: .pauseUntil)) ?? nil
        lockStartedAt      = (try? c.decodeIfPresent(Date.self, forKey: .lockStartedAt)) ?? nil
        blockedApps        = v(.blockedApps, d.blockedApps)
        appAction          = v(.appAction, d.appAction)
        allowedDomains     = v(.allowedDomains, d.allowedDomains)
        blockedDomains     = v(.blockedDomains, d.blockedDomains)
        inspectDomains     = v(.inspectDomains, d.inspectDomains)
        allowedChannels    = v(.allowedChannels, d.allowedChannels)
        blockedURLPatterns = v(.blockedURLPatterns, d.blockedURLPatterns)
        exceptions         = v(.exceptions, [Exception]())
        browserAction      = v(.browserAction, d.browserAction)
        hardBlockPhrases   = v(.hardBlockPhrases, d.hardBlockPhrases)
        allowPhrases       = v(.allowPhrases, d.allowPhrases)
        denyPhrases        = v(.denyPhrases, d.denyPhrases)
        semanticEnabled    = v(.semanticEnabled, d.semanticEnabled)
        semanticMargin     = v(.semanticMargin, d.semanticMargin)
        studyExamples      = v(.studyExamples, d.studyExamples)
        distractionExamples = v(.distractionExamples, d.distractionExamples)
        learnedDistraction = v(.learnedDistraction, d.learnedDistraction)
        learnedStudy       = v(.learnedStudy, d.learnedStudy)
        learnedRadius      = v(.learnedRadius, d.learnedRadius)
        deepInspection     = v(.deepInspection, d.deepInspection)
        challenge          = v(.challenge, d.challenge)
        practiceKind       = v(.practiceKind, d.practiceKind)
        practiceIQ         = IQ.clamp(v(.practiceIQ, d.practiceIQ))
        practice           = v(.practice, d.practice)
        setupDone          = v(.setupDone, d.setupDone)
        askedForAccessibility = v(.askedForAccessibility, d.askedForAccessibility)
        schedule           = v(.schedule, d.schedule)
        hotkeysEnabled     = v(.hotkeysEnabled, d.hotkeysEnabled)
        uiScale            = min(max(v(.uiScale, d.uiScale), 0.8), 2.0)
        showInDock         = v(.showInDock, d.showInDock)
        showInMenuBar      = v(.showInMenuBar, d.showInMenuBar)
        pollInterval       = v(.pollInterval, d.pollInterval)
        shieldSeconds      = v(.shieldSeconds, d.shieldSeconds)
        playSound          = v(.playSound, d.playSound)
    }
}
