import Foundation

// Checks the decision pipeline against your live rules.json, so tuning can be
// verified without hunting for a video that trips it.
//   ./check.sh                    run the built-in suite
//   ./check.sh "some video title" judge one title

let judge = Judge()

/// --margin <value> tries a different threshold without touching your saved rules.
let marginOverride: Double? = {
    guard let i = CommandLine.arguments.firstIndex(of: "--margin"),
          CommandLine.arguments.count > i + 1 else { return nil }
    return Double(CommandLine.arguments[i + 1])
}()

let rules: Rules = {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ward/rules.json")
    if let data = try? Data(contentsOf: url),
       let r = try? JSONDecoder.ward.decode(Rules.self, from: data) {
        FileHandle.standardError.write("using live rules from \(url.path)\n\n".data(using: .utf8)!)
        return r
    }
    FileHandle.standardError.write("no rules.json found — using defaults\n\n".data(using: .utf8)!)
    return .default
}().applying(margin: marginOverride)

extension Rules {
    /// Try a different threshold without touching the saved rules.
    func applying(margin: Double?) -> Rules {
        guard let margin else { return self }
        var copy = self
        copy.semanticMargin = margin
        FileHandle.standardError.write(
            "threshold overridden to \(margin)\n\n".data(using: .utf8)!)
        return copy
    }
}

func verdict(_ title: String) -> Judge.Explained {
    var ctx = PageContext()
    ctx.rawURL = "https://www.youtube.com/watch?v=check"
    ctx.title = title
    return judge.judge(ctx, rules: rules)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count > n ? String(s.prefix(n - 1)) + "\u{2026}" : s.padding(toLength: n, withPad: " ", startingAt: 0)
}

func line(_ title: String, _ r: Judge.Explained, mark: String) -> String {
    var out = "\(mark) \(r.verdict.call == .block ? "BLOCK" : "allow")  \(pad(title, 50))  \(r.verdict.reason)"
    if let s = r.score { out += String(format: "  [lean %+.3f]", s.lean) }
    return out
}

// Learning mode: --learn "title to teach" "title to test"
// Shows whether teaching one title actually moves a different, similar one.
let raw = Array(CommandLine.arguments.dropFirst())
if raw.first == "--learn", raw.count >= 3 {
    let taught = raw[1]
    var trial = rules
    func lean(_ t: String, _ r: Rules) -> Judge.Explained {
        var c = PageContext()
        c.rawURL = "https://www.youtube.com/watch?v=check"; c.title = t
        return Judge().judge(c, rules: r)
    }
    print("teaching as distraction: \(taught)\n")
    for probe in raw.dropFirst(2) {
        let before = lean(probe, trial)
        trial.learnedDistraction = [Semantic.normalise(taught)]
        let after = lean(probe, trial)
        trial.learnedDistraction = []
        let b = before.score?.lean, a = after.score?.lean
        if let b, let a {
            let flip = (b <= rules.semanticMargin && a > rules.semanticMargin) ? "  <- FLIPS TO BLOCKED" : ""
            print(String(format: "  %@  %+.3f -> %+.3f  (moved %+.3f)%@",
                         pad(probe, 44), b, a, a - b, flip))
        } else {
            print("  \(pad(probe, 44))  settled by a phrase before the model")
        }
    }
    exit(0)
}

// One-off mode
var args = raw
if let i = args.firstIndex(of: "--margin") {
    args.removeSubrange(i...min(i + 1, args.count - 1))
}
if !args.isEmpty {
    for t in args {
        let r = verdict(t)
        print(line(t, r, mark: "     "))
        if let s = r.score {
            print(String(format: "       study %.3f · distraction %.3f · threshold %+.3f",
                         s.studyDistance, s.distractionDistance, rules.semanticMargin))
            print("       nearest study:       \(s.nearestStudy)")
            print("       nearest distraction: \(s.nearestDistraction)")
        }
    }
    exit(0)
}

// Suite mode
let suite: [(String, [String], Verdict.Call)] = [
    ("study", [
        "Introduction to Linear Algebra — MIT 18.06 Lecture 1",
        "How to Solve Quadratic Equations | Algebra Basics",
        "Organic Chemistry: SN1 and SN2 Reactions Explained",
        "A-Level Physics Revision: Circular Motion",
        "Build a REST API with Node.js — Full Tutorial",
        "The French Revolution — Documentary",
        "Neural Networks: Backpropagation from scratch",
        "Study With Me • 2 Hour Pomodoro Session",
        "What is a Fourier Transform? Visual Introduction",
        "Cell Division: Mitosis and Meiosis compared",
        "Understanding Big O Notation for interviews",
    ], .allow),
    ("distraction", [
        "Minecraft Hardcore Survival — Episode 14",
        "I Spent 50 Hours in Elden Ring",
        "FUNNY FAILS COMPILATION 2024",
        "Man Utd vs Arsenal | Extended Highlights",
        "Reacting to my old TikToks",
        "MrBeast: I Built a $100,000 Maze",
        "Top 10 Anime Openings of All Time",
        "Valorant Radiant Ranked Gameplay",
        "Official Trailer | Dune Part Three",
        "we broke up... storytime",
        "Ranking every fast food burger in America",
        "24 Hours Living in an Airport",
    ], .block),
    ("educational about games/sport", [
        "The Economics of Video Games",
        "Chess Grandmaster Explains the Sicilian Defense",
        "How Video Game Physics Engines Actually Work",
        "The History of the Olympic Games",
    ], .allow),
    ("named things that are never allowed", [
        "Minecraft Redstone Tutorial for Beginners",
        "A Documentary on Fortnite's Rise and Fall",
        "The History of Call of Duty",
    ], .block),
    ("phrase conflicts", [
        "Past Paper Walkthrough: Edexcel Maths June 2023",
    ], .allow),
]

// Exceptions have properties worth pinning down: they expire, a site pass doesn't
// leak to other sites, and a page pass doesn't open the whole site.
func exceptionChecks() -> (Int, Int) {
    var pass = 0, total = 0
    func probe(_ name: String, _ url: String, _ title: String,
               _ r: Rules, _ expect: Verdict.Call) {
        total += 1
        var c = PageContext(); c.rawURL = url; c.title = title
        let v = judge.judge(c, rules: r).verdict
        let ok = v.call == expect
        if ok { pass += 1 }
        print("  \(ok ? "ok " : "\u{2717}\u{2717} ") \(pad(name, 44))  \(v.call == .block ? "BLOCK" : "allow")  \(v.reason)")
    }

    let yt = "https://www.youtube.com/watch?v=x"
    let reddit = "https://www.reddit.com/r/all"
    let soon = Date().addingTimeInterval(300)
    let past = Date().addingTimeInterval(-1)

    print("\u{2500}\u{2500} exceptions \u{2500}\u{2500}")
    var live = rules
    live.exceptions = [Exception(value: "reddit.com", isHost: true, label: "r", until: soon)]
    probe("site pass lets the site through", reddit, "reddit", live, .allow)
    probe("...and its subdomains", "https://old.reddit.com/r/x", "reddit", live, .allow)
    probe("...but not a different site", "https://twitter.com/x", "twitter", live, .block)
    probe("...and not video content", yt, "Minecraft Hardcore Survival", live, .block)

    var expired = rules
    expired.exceptions = [Exception(value: "reddit.com", isHost: true, label: "r", until: past)]
    probe("an expired pass stops working", reddit, "reddit", expired, .block)

    var byTitle = rules
    byTitle.exceptions = [Exception(value: Semantic.normalise("Minecraft Hardcore Survival"),
                                    isHost: false, label: "v", until: soon)]
    probe("page pass lets that page through", yt, "Minecraft Hardcore Survival", byTitle, .allow)
    probe("...but not another video", yt, "Valorant Ranked Gameplay", byTitle, .block)
    print("")
    return (pass, total)
}

// The schedule's awkward case is a window that runs past midnight: the hours after
// midnight belong to the previous day's entry, not that morning's.
func scheduleChecks() -> (Int, Int) {
    var pass = 0, total = 0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    func at(_ day: Int, _ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 8, day: day, hour: h, minute: m))!
    }
    func probe(_ name: String, _ s: Schedule, _ d: Date, _ expect: Bool) {
        total += 1
        let got = s.covers(d, calendar: cal)
        if got == expect { pass += 1 }
        print("  \(got == expect ? "ok " : "\u{2717}\u{2717} ") \(pad(name, 44))  \(got ? "on" : "off")")
    }

    print("\u{2500}\u{2500} schedule \u{2500}\u{2500}")
    var day = Schedule(); day.enabled = true                    // Mon-Fri 09:00-18:00
    probe("Mon 10:00 inside", day, at(24, 10, 0), true)
    probe("Mon 18:00 is the end, exclusive", day, at(24, 18, 0), false)
    probe("Sat is not a weekday", day, at(29, 10, 0), false)

    var night = Schedule(); night.enabled = true
    night.start = 20 * 60; night.end = 2 * 60                   // Mon-Fri 20:00-02:00
    probe("Mon 21:00 inside", night, at(24, 21, 0), true)
    probe("Tue 01:00 is Monday's tail", night, at(25, 1, 0), true)
    probe("Sat 01:00 is Friday's tail", night, at(29, 1, 0), true)
    probe("Sat 21:00 is not covered", night, at(29, 21, 0), false)

    var zero = Schedule(); zero.enabled = true; zero.start = 600; zero.end = 600
    probe("an empty window covers nothing", zero, at(24, 10, 0), false)
    print("")
    return (pass, total)
}

// Importing someone else's rulebook must never loosen yours. That is the whole
// safety property of merge, so it gets pinned down.
func backupChecks() -> (Int, Int) {
    var pass = 0, total = 0
    func probe(_ name: String, _ condition: Bool) {
        total += 1
        if condition { pass += 1 }
        print("  \(condition ? "ok " : "\u{2717}\u{2717} ") \(pad(name, 44))")
    }

    print("\u{2500}\u{2500} backup \u{2500}\u{2500}")

    var mine = Rules.default
    mine.blockedDomains = ["reddit.com"]
    mine.allowedDomains = ["wikipedia.org"]
    mine.hardBlockPhrases = ["minecraft"]
    mine.blockedApps = [BlockedApp(bundleID: "com.a.b", name: "A")]
    mine.lockUntil = Date().addingTimeInterval(600)
    mine.uiScale = 1.5

    var theirs = Rules.default
    theirs.blockedDomains = ["x.com"]
    theirs.allowedDomains = ["twitch.tv"]        // an allow they added; must not carry over
    theirs.hardBlockPhrases = ["fortnite"]
    theirs.blockedApps = [BlockedApp(bundleID: "com.c.d", name: "C")]
    theirs.uiScale = 0.8

    let merged = mine.merged(with: theirs)
    probe("merge keeps what you had", merged.blockedDomains.contains("reddit.com"))
    probe("merge adds their blocked sites", merged.blockedDomains.contains("x.com"))
    probe("merge adds their phrases", merged.hardBlockPhrases.contains("fortnite"))
    probe("merge adds their apps", merged.blockedApps.contains { $0.bundleID == "com.c.d" })
    probe("merge does NOT add their allow-list", !merged.allowedDomains.contains("twitch.tv"))
    probe("merge leaves your allow-list intact", merged.allowedDomains.contains("wikipedia.org"))
    probe("merge does not touch your zoom", merged.uiScale == 1.5)

    let replaced = mine.replaced(by: theirs)
    probe("replace takes their sites", replaced.blockedDomains == ["x.com"])
    probe("replace keeps a running lock", replaced.lockUntil != nil)
    probe("replace keeps your zoom", replaced.uiScale == 1.5)

    var transient = mine
    transient.pauseUntil = Date().addingTimeInterval(60)
    transient.exceptions = [Exception(value: "a.com", isHost: true, label: "a",
                                      until: Date().addingTimeInterval(60))]
    let out = transient.portable
    probe("export drops the pause", out.pauseUntil == nil)
    probe("export drops exceptions", out.exceptions.isEmpty)
    probe("export drops the lock", out.lockUntil == nil)
    print("")

    print("\u{2500}\u{2500} redundant phrases \u{2500}\u{2500}")
    let list = ["gaming", "let's play", "call of duty"]
    func cover(_ name: String, _ candidate: String, _ expect: String?) {
        total += 1
        let got = Rules.coveringPhrase(for: candidate, in: list)
        let ok = got == expect
        if ok { pass += 1 }
        print("  \(ok ? "ok " : "\u{2717}\u{2717} ") \(pad(name, 44))  \(got ?? "not covered")")
    }
    cover("\"gaming pc\" is covered by \"gaming\"", "gaming pc", "gaming")
    cover("\"best gaming chair\" is covered too", "best gaming chair", "gaming")
    cover("\"call of duty warzone\" is covered", "call of duty warzone", "call of duty")
    cover("\"gamer\" is a different word", "gamer", nil)
    cover("\"pc gaming setup\" is covered", "pc gaming setup", "gaming")
    cover("a broader phrase is not redundant", "call of", nil)
    cover("something unrelated", "chemistry", nil)
    print("")
    return (pass, total)
}

// A challenge you cannot solve would be worse than no challenge at all, so the
// arithmetic chain is re-derived from the wording of its own instructions.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

func challengeChecks() -> (Int, Int) {
    var pass = 0, total = 0
    func probe(_ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if ok { pass += 1 }
        print("  \(ok ? "ok " : "\u{2717}\u{2717} ") \(pad(name, 44))  \(detail)")
    }

    print("\u{2500}\u{2500} challenges \u{2500}\u{2500}")

    // Follow the printed instructions literally and see if they reach the answer.
    func solve(_ steps: [String]) -> Int? {
        var value: Int?
        for step in steps {
            let numbers = step.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if step.hasPrefix("Start"), let n = numbers.first { value = n; continue }
            guard var v = value, let n = numbers.first else { return nil }
            if step.hasPrefix("Add") && step.contains("squared") { v += n * n }
            else if step.hasPrefix("Add") { v += n }
            else if step.hasPrefix("Subtract") { v -= n }
            else if step.hasPrefix("Multiply") { v *= n }
            else if step.hasPrefix("Round") { v -= ((v % n) + n) % n; v /= n }
            else { return nil }
            value = v
        }
        return value
    }

    var solvable = 0, checked = 0
    var negatives = 0, biggest = 0
    for seed in UInt64(1)...120 {
        for iq in stride(from: 70, through: 200, by: 10) {
            var rng = SeededRNG(seed &+ UInt64(iq))
            guard case .arithmetic(let steps, let answer) =
                    PuzzleMaker.make(.arithmetic, iq: iq, using: &rng) else { continue }
            checked += 1
            if solve(steps) == answer { solvable += 1 }
            var value = 0
            for step in steps {
                let n = step.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first ?? 0
                if step.hasPrefix("Start") { value = n }
                else if step.hasPrefix("Add") && step.contains("squared") { value += n * n }
                else if step.hasPrefix("Add") { value += n }
                else if step.hasPrefix("Subtract") { value -= n }
                else if step.hasPrefix("Multiply") { value *= n }
                else if step.hasPrefix("Round") { value -= value % n; value /= n }
                if value < 0 { negatives += 1 }
                biggest = max(biggest, value)
            }
            if answer < 0 { negatives += 1 }
        }
    }
    probe("every arithmetic chain reaches its answer", solvable == checked,
          "\(solvable)/\(checked) across the whole dial")
    probe("no step ever goes negative", negatives == 0, "largest value seen \(biggest)")
    probe("nothing grows past what a person would do", biggest < 60_000, "\(biggest)")

    // "Each IQ point should have a different batch of questions."
    var duplicateSpecs: [Int] = []
    for iq in IQ.range.lowerBound..<IQ.range.upperBound {
        if PuzzleSpec.forIQ(iq) == PuzzleSpec.forIQ(iq + 1) { duplicateSpecs.append(iq) }
    }
    probe("every point on the dial differs from the next", duplicateSpecs.isEmpty,
          duplicateSpecs.isEmpty ? "\(IQ.range.count) distinct points"
                                 : "same at \(duplicateSpecs.prefix(4))")

    // Harder as it goes up, never easier.
    var regressions = 0
    for iq in IQ.range.lowerBound..<IQ.range.upperBound {
        let a = PuzzleSpec.forIQ(iq), b = PuzzleSpec.forIQ(iq + 1)
        if b.typingWords < a.typingWords || b.arithmeticSteps < a.arithmeticSteps
            || b.memoryLength < a.memoryLength || b.waitSeconds < a.waitSeconds
            || b.memoryFlashMs > a.memoryFlashMs || b.sortColours < a.sortColours
            || b.lightsGrid < a.lightsGrid || b.lightsTaps < a.lightsTaps { regressions += 1 }
    }
    probe("difficulty never goes backwards", regressions == 0, "\(regressions) regressions")

    let low = PuzzleSpec.forIQ(70), high = PuzzleSpec.forIQ(200)
    probe("the dial actually spans a range",
          low.typingWords < 12 && high.typingWords >= 110 && high.waitSeconds > 240,
          "\(low.typingWords)-\(high.typingWords) words, wait to \(high.waitSeconds)s")

    // The default must not be softer than the fixed "firm" setting it replaced.
    let standard = PuzzleSpec.forIQ(IQ.default)
    probe("the default is harder than the old fixed level",
          standard.typingWords > 22 && standard.arithmeticSteps > 5,
          "\(standard.typingWords) words, \(standard.arithmeticSteps) steps")

    // The ledger must not hand back a question it has already asked.
    let ledger = PuzzleLedger(loading: false)
    var signatures = Set<String>()
    var repeats = 0
    for _ in 0..<300 {
        let p = PuzzleMaker.makeUnseen(.typing, iq: 110, ledger: ledger)
        if let sig = p.signature, !signatures.insert(sig).inserted { repeats += 1 }
    }
    probe("300 questions, none repeated", repeats == 0, "\(signatures.count) distinct")

    // At the very bottom the pool is small; it must still return something rather
    // than spinning forever.
    let tiny = PuzzleLedger(loading: false)
    var produced = 0
    for _ in 0..<400 {
        _ = PuzzleMaker.makeUnseen(.memory, iq: 70, ledger: tiny)
        produced += 1
    }
    probe("a small pool still always answers", produced == 400, "\(produced)/400")

    probe("exact typing accepted", PuzzleCheck.typingAccepted("amber willow", "amber willow"))
    probe("near miss rejected", !PuzzleCheck.typingAccepted("amber willo", "amber willow"))
    probe("wrong case rejected", !PuzzleCheck.typingAccepted("Amber willow", "amber willow"))
    probe("trailing space forgiven", PuzzleCheck.typingAccepted("amber willow  ", "amber willow"))
    probe("paste detected", PuzzleCheck.looksPasted(previous: "am", next: "amber willow"))
    probe("normal typing not flagged", !PuzzleCheck.looksPasted(previous: "amb", next: "ambe"))
    // "amber wi" is eight characters, then the typed text diverges.
    probe("progress counts the good prefix",
          PuzzleCheck.typingProgress("amber wix", "amber willow") == 8)
    probe("arithmetic exact only", PuzzleCheck.arithmeticAccepted("42", 42)
          && !PuzzleCheck.arithmeticAccepted("43", 42))

    // The games must never deal an impossible board — a gate you cannot pass is a
    // lockout, not a challenge.
    var sortDeals = 0, sortGood = 0
    for seed in UInt64(1)...40 {
        for iq in stride(from: 70, through: 200, by: 26) {
            var rng = SeededRNG(seed &* 7919 &+ UInt64(iq))
            guard case .blockSort(let tubes, let capacity) =
                    PuzzleMaker.make(.blockSort, iq: iq, using: &rng) else { continue }
            sortDeals += 1
            if !BlockSort.solved(tubes, capacity: capacity),
               BlockSort.solvable(tubes, capacity: capacity),
               tubes.reduce(0, { $0 + $1.count }) == (tubes.count - 2) * capacity {
                sortGood += 1
            }
        }
    }
    probe("every block-sort deal can be won", sortDeals > 0 && sortGood == sortDeals,
          "\(sortGood)/\(sortDeals) across the dial")

    var lightDeals = 0, lightGood = 0
    for seed in UInt64(1)...40 {
        for iq in stride(from: 70, through: 200, by: 26) {
            var rng = SeededRNG(seed &* 104_729 &+ UInt64(iq))
            guard case .lightsOut(let grid, let lit) =
                    PuzzleMaker.make(.lightsOut, iq: iq, using: &rng) else { continue }
            lightDeals += 1
            // Solvable by construction (a scramble is taps, and taps undo taps);
            // what matters is that it never starts dark and stays on the board.
            if !lit.isEmpty, lit.allSatisfy({ (0..<grid * grid).contains($0) }) { lightGood += 1 }
        }
    }
    probe("no lights-out board starts already dark", lightDeals > 0 && lightGood == lightDeals,
          "\(lightGood)/\(lightDeals) across the dial")
    probe("pressing a tile twice undoes it",
          LightsOut.press(4, lit: LightsOut.press(4, lit: [], grid: 3), grid: 3).isEmpty)

    // The typing pool is the system dictionary now, not a rota of 54 nouns.
    var drawn = Set<String>()
    var wordRNG = SeededRNG(99)
    for _ in 0..<40 {
        guard case .typing(let passage) =
                PuzzleMaker.make(.typing, iq: 140, using: &wordRNG) else { continue }
        for word in passage.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted) where !word.isEmpty {
            drawn.insert(word)
        }
    }
    probe("typing passages draw from a deep pool", drawn.count > 400,
          "\(drawn.count) distinct words in 40 passages")

    print("")
    return (pass, total)
}

// "Should have been blocked" has to act on the layer that actually applies to the page
// in front of you. On a site Ward doesn't judge page by page, storing a lesson about
// the title is a no-op — nothing ever consults it.
func teachingChecks() -> (Int, Int) {
    var pass = 0, total = 0
    func probe(_ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if ok { pass += 1 }
        print("  \(ok ? "ok " : "\u{2717}\u{2717} ") \(pad(name, 46))  \(detail)")
    }

    print("\u{2500}\u{2500} teaching \u{2500}\u{2500}")

    var r = Rules.default
    r.blockedDomains = []
    r.allowedDomains = []

    probe("youtube is judged page by page", r.judgesContent(on: "youtube.com"))
    probe("m.youtube.com too", r.judgesContent(on: "m.youtube.com"))
    probe("an ordinary site is not", !r.judgesContent(on: "crazygames.com"))
    probe("nor is a lookalike domain", !r.judgesContent(on: "notyoutube.com"))

    // The heart of it: a lesson stored for a non-inspected host can never fire.
    var lessonOnly = r
    lessonOnly.learnedDistraction = [Semantic.normalise("Free Online Games at Poki - Play Now")]
    var c = PageContext()
    c.rawURL = "https://poki.com/"; c.title = "Free Online Games at Poki - Play Now"
    let stillAllowed = judge.judge(c, rules: lessonOnly).verdict.call == .allow
    probe("a lesson alone cannot block such a site", stillAllowed,
          "which is why teaching must block the site instead")

    // Blocking the host is what works.
    var sited = r
    sited.blockedDomains = ["poki.com"]
    probe("blocking the host does work",
          judge.judge(c, rules: sited).verdict.call == .block)

    // And the reverse: allowing must beat a blocked site.
    var allowed = sited
    allowed.allowedDomains = ["poki.com"]
    probe("allowing the host beats blocking it",
          judge.judge(allowed_ctx(), rules: allowed).verdict.call == .allow)

    func allowed_ctx() -> PageContext {
        var x = PageContext()
        x.rawURL = "https://poki.com/"; x.title = "Free Online Games at Poki - Play Now"
        return x
    }
    print("")
    return (pass, total)
}

// Six bugs of one shape: settings that look active and quietly do nothing.
func noOpChecks() -> (Int, Int) {
    var pass = 0, total = 0
    func probe(_ name: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if ok { pass += 1 }
        print("  \(ok ? "ok " : "\u{2717}\u{2717} ") \(pad(name, 46))  \(detail)")
    }

    print("\u{2500}\u{2500} silent no-ops \u{2500}\u{2500}")

    // 1. There is no off switch. The one gate left is the narrow one.
    probe("the only gate left is letting one page through",
          Gate.allRemaining == [.exception], "off and pause are gone, not guarded")
    // A schedule was the last thing that could switch Ward off by itself. Walk a
    // whole week past a one-minute window — the case that would otherwise leave Ward
    // off all day — and check it never does anything but turn Ward on or stand aside.
    let narrow = Schedule(enabled: true, days: [2, 3, 4, 5, 6],
                          start: 9 * 60, end: 9 * 60 + 1)
    var effects = Set<String>()
    var when = Date()
    for _ in 0..<(7 * 24 * 6) {
        effects.insert(String(describing: Store.scheduleEffect(narrow, at: when)))
        when = when.addingTimeInterval(600)
    }
    probe("a schedule can only ever turn Ward on",
          effects.isSubset(of: ["turnOn", "leaveAlone"]) && Store.ScheduleEffect.allCases.count == 2,
          "a week of ten-minute steps saw \(effects.sorted().joined(separator: ", "))")

    // 2. The last route to the window can't be closed.
    var r = Rules.default
    r.showInDock = false; r.showInMenuBar = false; r.hotkeysEnabled = false
    let restored = r.ensureAWayIn()
    probe("closing the last way in is undone", restored && r.showInMenuBar)
    var keep = Rules.default
    keep.showInDock = false; keep.showInMenuBar = false; keep.hotkeysEnabled = true
    probe("...but two of three off is left alone", !keep.ensureAWayIn())

    // 3. A schedule describing no time is ignored, not obeyed.
    var none = Schedule(); none.enabled = true; none.days = []
    probe("a schedule with no days is not usable", !none.isUsable)
    var empty = Schedule(); empty.enabled = true; empty.start = 600; empty.end = 600
    probe("a zero-length window is not usable", !empty.isUsable)
    var fine = Schedule(); fine.enabled = true
    probe("an ordinary schedule still is", fine.isUsable)

    // 4. Pages that haven't named themselves yet are not guessed at. The window
    // title falls back to the URL while a page loads (and on the search page the
    // metadata is site boilerplate); neither is content to judge.
    var loading = PageContext()
    loading.rawURL = "https://www.youtube.com/results?search_query=trig"
    loading.title = "Personal \u{2014} https://www.youtube.com/results?search_query=differentiation+of+trig+functions"
    probe("a URL for a title is not judged",
          judge.judge(loading, rules: Rules.default).verdict.reason == "nothing to judge yet")
    var searching = PageContext()
    searching.rawURL = "https://www.youtube.com/results?search_query=trig"
    searching.title = "differentiation of trig functions - YouTube"
    probe("a plain search title is judged as itself",
          judge.judge(searching, rules: Rules.default).verdict.call == .allow,
          "reads as study, not as YouTube's marketing blurb")

    // 5. Guitar is a skill being practised, not an evening lost.
    var guitarRules = Rules.default
    guitarRules.schemaVersion = 0
    _ = guitarRules.migrateIfNeeded()
    func guitarCall(_ title: String, _ metadata: String = "") -> Bool {
        var g = PageContext()
        g.rawURL = "https://www.youtube.com/watch?v=x"
        g.title = title + " - YouTube"
        g.metadata = metadata
        return judge.judge(g, rules: guitarRules).verdict.call == .allow
    }

    // A title that says what it is gets through on the title alone.
    let guitarTitles = [
        "How to play Sweet Child O' Mine - guitar lesson",
        "Pentatonic scale shapes explained",
        "Fingerstyle arrangement of Hotel California",
        "Guitar tone secrets - tube amps explained",
        "Alternate picking exercises for speed",
        "Barre chords finally explained",
        "John Mayer - Slow Dancing In A Burning Room"
    ]
    let titleAllowed = guitarTitles.filter { guitarCall($0) }.count
    probe("guitar content is not blocked", titleAllowed == guitarTitles.count,
          "\(titleAllowed)/\(guitarTitles.count) allowed on the title alone")

    // A bare player's name says nothing about an instrument \u{2014} no set of examples
    // can teach the model that Steve Vai plays guitar, and adding some was measured
    // to change nothing. What settles it is the page's own tags, which is what deep
    // inspection reads.
    let bare = [
        ("Steve Vai - For The Love Of God",
         "steve vai, guitar, guitar solo, instrumental . channel Steve Vai"),
        ("Polyphia - Playing God",
         "polyphia, guitar, instrumental, fingerstyle . channel Polyphia"),
        ("Guthrie Govan solo", "guitar, guitarist, solo, fusion . channel Guthrie Govan"),
    ]
    probe("a guitarist's name is settled by the page's own tags",
          bare.allSatisfy { guitarCall($0.0, $0.1) },
          "title alone: \(bare.filter { guitarCall($0.0) }.count)/\(bare.count), needs automation on")

    // ...but a guitar-shaped video game is still a video game.
    var gh = PageContext()
    gh.rawURL = "https://www.youtube.com/watch?v=y"
    gh.title = "Guitar Hero 3 expert gameplay - YouTube"
    probe("a guitar video game still isn't guitar practice",
          judge.judge(gh, rules: guitarRules).verdict.call == .block,
          "hard-block phrases run before allow phrases")

    // Migration has to reach a rulebook written before any of this existed.
    var old2 = Rules.default
    old2.schemaVersion = 2
    old2.allowPhrases = ["lecture"]
    old2.studyExamples = ["a university lecture explaining a topic in depth"]
    _ = old2.migrateIfNeeded()
    probe("an existing rulebook gains the guitar rules",
          old2.allowPhrases.contains("guitar") && old2.allowPhrases.contains("lecture"),
          "\(old2.allowPhrases.count) allow phrases, nothing of yours removed")

    // 6. A channel you have vouched for settles it, and knows its place in the order.
    var trusting = Rules.default
    trusting.allowedChannels = ["Steve Vai", "3Blue1Brown"]
    func onChannel(_ title: String, _ channel: String, _ rules: Rules) -> Verdict.Call {
        var c = PageContext()
        c.rawURL = "https://www.youtube.com/watch?v=x"
        c.title = title + " - YouTube"
        c.channel = channel
        return judge.judge(c, rules: rules).verdict.call
    }
    probe("a trusted channel settles a title the model got wrong",
          onChannel("For The Love Of God", "Steve Vai", trusting) == .allow,
          "the same title without the channel: "
          + "\(onChannel("For The Love Of God", "", trusting) == .allow ? "allowed" : "blocked")")
    probe("a trusted channel beats a block phrase",
          onChannel("My reaction to the new album", "Steve Vai", trusting) == .allow,
          "a block phrase would otherwise settle it")
    probe("but never-allowed still means never",
          onChannel("Minecraft speedrun", "Steve Vai", trusting) == .block,
          "vouching for a publisher is not a way to un-say that")
    probe("an untrusted channel changes nothing",
          onChannel("For The Love Of God", "Some Other Channel", trusting) == .block)
    func onURL(_ url: String, _ title: String, _ channel: String) -> Verdict.Call {
        var c = PageContext()
        c.rawURL = url; c.title = title; c.channel = channel
        return judge.judge(c, rules: trusting).verdict.call
    }
    probe("a blocked site is still blocked whoever published it",
          onURL("https://www.instagram.com/p/x", "anything", "Steve Vai") == .block,
          "site rules run before content is looked at")
    probe("a short is still a short",
          onURL("https://www.youtube.com/shorts/abc", "a guitar lick", "Steve Vai") == .block,
          "url patterns run before content too")
    probe("names match despite case and spacing",
          Rules.channelIsTrusted("  steve   VAI ", in: ["Steve Vai"])
          && !Rules.channelIsTrusted("Steve", in: ["Steve Vai"])
          && !Rules.channelIsTrusted("", in: ["Steve Vai"]),
          "flattened, but not a partial match")
    probe("trust is never imported or migrated in",
          Rules.default.allowedChannels.isEmpty
          && Rules.default.merged(with: trusting).allowedChannels.isEmpty,
          "whom you trust is yours to say")

    // 7. An import must never be able to switch Ward off.
    var off = Rules.default
    off.enabled = false
    probe("replacing the rulebook can't switch Ward off",
          Rules.default.replaced(by: off).enabled,
          "a file written while Ward was off would otherwise carry that across")
    probe("merging can't either", Rules.default.merged(with: off).enabled)

    // 8. Content rules only reach the sites judged by content.
    var scoped = Rules.default
    probe("content rules reach youtube", scoped.judgesContent(on: "youtube.com"))
    scoped.inspectDomains = []
    probe("with no such sites they reach nothing",
          !scoped.judgesContent(on: "youtube.com"),
          "\(scoped.hardBlockPhrases.count + scoped.denyPhrases.count + scoped.allowPhrases.count) phrases inert")
    print("")
    return (pass, total)
}

var passed = 0, total = 0
for (name, titles, expect) in suite {
    print("\u{2500}\u{2500} \(name) \u{2500}\u{2500} expecting \(expect == .block ? "BLOCK" : "allow")")
    for t in titles {
        total += 1
        let r = verdict(t)
        let ok = r.verdict.call == expect
        if ok { passed += 1 }
        print(line(t, r, mark: ok ? "  ok " : "  \u{2717}\u{2717} "))
    }
    print("")
}
let (ePass, eTotal) = exceptionChecks()
passed += ePass; total += eTotal
let (sPass, sTotal) = scheduleChecks()
passed += sPass; total += sTotal
let (bPass, bTotal) = backupChecks()
passed += bPass; total += bTotal
let (cPass, cTotal) = challengeChecks()
passed += cPass; total += cTotal
let (tPass, tTotal) = teachingChecks()
passed += tPass; total += tTotal
let (nPass, nTotal) = noOpChecks()
passed += nPass; total += nTotal

print("\(passed)/\(total) passed")
exit(passed == total ? 0 : 1)
