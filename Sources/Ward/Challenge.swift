import Foundation

// MARK: - Settings

enum ChallengeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case typing, arithmetic, memory, blockSort, lightsOut, wait, mixed
    var id: String { rawValue }

    var label: String {
        switch self {
        case .typing:     return "Retype a passage"
        case .arithmetic: return "Work out a sum"
        case .memory:     return "Repeat a sequence"
        case .blockSort:  return "Sort the blocks"
        case .lightsOut:  return "Lights out"
        case .wait:       return "Sit and wait"
        case .mixed:      return "Surprise me"
        }
    }
    var blurb: String {
        switch self {
        case .typing:     return "Copy a block of text exactly. Tedious on purpose, and pasting doesn't work."
        case .arithmetic: return "A chain of sums to carry in your head. No calculator, and it won't accept a near miss."
        case .memory:     return "Watch a pattern, then repeat it. One wrong tile and the round starts over."
        case .blockSort:  return "Pour colours between tubes until each tube holds one colour. A careless pour digs you in deeper."
        case .lightsOut:  return "Every tap flips a tile and its neighbours. Get the whole board dark."
        case .wait:       return "Do nothing for a while. The timer only runs when this window is in front."
        case .mixed:      return "A different one each time, so you never get quick at any of them."
        }
    }
    var icon: String {
        switch self {
        case .typing:     return "keyboard"
        case .arithmetic: return "function"
        case .memory:     return "square.grid.3x3.fill"
        case .blockSort:  return "square.stack.3d.up.fill"
        case .lightsOut:  return "lightbulb.fill"
        case .wait:       return "hourglass"
        case .mixed:      return "dice"
        }
    }
}

/// The difficulty dial, framed as an IQ number. It is a dial, not a measurement —
/// nothing here assesses anything about you; it only decides how much work standing
/// between you and switching Ward off.
enum IQ {
    static let range = 70...200
    static let `default` = 110

    static func clamp(_ value: Int) -> Int { min(max(value, range.lowerBound), range.upperBound) }

    /// Plain language beats a pseudo-clinical label: what matters is how long this
    /// will take, not what the number is supposed to mean.
    static func effort(_ iq: Int) -> String {
        let spec = PuzzleSpec.forIQ(iq)
        switch iq {
        case ..<90:    return "Barely a speed bump. Enough to interrupt a reflex, no more."
        case 90..<110: return "A minute or so of deliberate effort."
        case 110..<135:return "Several minutes of real attention. You won't do it idly."
        case 135..<165:return "Hard work \u{2014} \(spec.typingWords) words, or \(spec.arithmeticSteps) steps carried in your head."
        default:       return "Punishing, and meant to be. \(spec.typingWords) words, or \(spec.arithmeticSteps) steps with squares in them."
        }
    }
}

/// Everything that varies with the dial. Kept as plain values so the scaling can be
/// tested directly, and so it is provable that no two points on the dial produce the
/// same batch of questions.
struct PuzzleSpec: Equatable, Sendable {
    var typingWords: Int
    var typingCommaEvery: Int
    var typingCapitalEvery: Int
    var arithmeticSteps: Int
    var arithmeticMax: Int
    var arithmeticSquares: Bool
    var memoryLength: Int
    var memoryFlashMs: Int
    var sortColours: Int
    var lightsGrid: Int
    var lightsTaps: Int
    var waitSeconds: Int

    static func forIQ(_ raw: Int) -> PuzzleSpec {
        let iq = IQ.clamp(raw)
        let span = Double(IQ.range.upperBound - IQ.range.lowerBound)
        let t = Double(iq - IQ.range.lowerBound) / span      // 0...1

        // Mildly super-linear: the bottom of the dial stays a token gesture, the
        // middle is already real work, and the top is punishing. A gentler curve put
        // the default below the old fixed setting, which was the thing that was too easy.
        let curve = { (exponent: Double) in pow(t, exponent) }

        return PuzzleSpec(
            typingWords: 8 + Int(curve(1.4) * 112),            // 8 - 120
            // These two shift on every single point of the dial, which is what makes
            // one IQ's batch of passages distinct from its neighbour's.
            typingCommaEvery: 3 + iq % 5,
            typingCapitalEvery: 4 + iq % 7,
            arithmeticSteps: 3 + Int(curve(1.2) * 14),         // 3 - 17
            arithmeticMax: 25 + (iq - IQ.range.lowerBound) * 4,
            arithmeticSquares: iq >= 135,
            memoryLength: 4 + Int(curve(1.2) * 16),            // 4 - 20
            memoryFlashMs: max(130, 540 - (iq - IQ.range.lowerBound) * 3),
            sortColours: 3 + Int(curve(1.1) * 4),              // 3 - 7
            lightsGrid: 3 + Int(curve(1.0) * 2),               // 3x3 - 5x5
            lightsTaps: 4 + Int(curve(1.2) * 14),              // 4 - 18, capped by the board
            waitSeconds: 5 + (iq - IQ.range.lowerBound) * 2)   // 5 - 265
    }
}

struct ChallengeSettings: Codable, Sendable, Equatable {
    var kind: ChallengeKind = .typing
    var iq: Int = IQ.default
    /// Letting one blocked page through is the only weakening Ward still offers, so
    /// it is the only thing left to guard. Turning Ward off and pausing it used to
    /// live here too; they were removed rather than guarded — see `Gate`.
    var onException = false
}

extension ChallengeSettings {
    /// Hand-written so a settings file from before the dial existed still loads, with
    /// its old three-level setting mapped onto the nearest point.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        kind = (try? c.decodeIfPresent(ChallengeKind.self, forKey: .kind)).flatMap { $0 } ?? kind

        if let stored = (try? c.decodeIfPresent(Int.self, forKey: .iq)).flatMap({ $0 }) {
            iq = IQ.clamp(stored)
        } else if let old = (try? c.decodeIfPresent(String.self, forKey: .legacyDifficulty))
                    .flatMap({ $0 }) {
            iq = ["gentle": 90, "firm": 115, "brutal": 145][old] ?? IQ.default
        }

        onException = (try? c.decodeIfPresent(Bool.self, forKey: .onException)).flatMap { $0 } ?? onException
    }

    /// Written out without the legacy key, so the old setting fades away after the
    /// first save rather than lingering in the file forever.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(iq, forKey: .iq)
        try c.encode(onException, forKey: .onException)
    }

    enum CodingKeys: String, CodingKey {
        case kind, iq, onException
        case legacyDifficulty = "difficulty"
    }
}

/// How the quiz has gone. Nothing here affects the rules; it is just a scoreboard.
struct PracticeStats: Codable, Sendable, Equatable {
    var solved = 0
    var streak = 0
    var bestStreak = 0
    var totalSeconds: Double = 0
    /// Fastest time per puzzle kind.
    var best: [String: Double] = [:]

    var averageSeconds: Double { solved == 0 ? 0 : totalSeconds / Double(solved) }

    mutating func record(kind: ChallengeKind, seconds: Double) {
        solved += 1
        streak += 1
        bestStreak = max(bestStreak, streak)
        totalSeconds += seconds
        let key = kind.rawValue
        best[key] = min(best[key] ?? .greatestFiniteMagnitude, seconds)
    }

    mutating func giveUp() { streak = 0 }
}

/// What still has to be earned. Turning Ward off and pausing it were once gates
/// here; both are gone entirely. A gate you can pass is a gate you will pass on a
/// bad day, and the off switch was the one that mattered most.
enum Gate: String, Sendable, CaseIterable {
    case exception

    /// Named for what it is: everything a challenge can still stand in front of.
    /// If turning Ward off ever comes back, it comes back here and the check that
    /// reads this fails until someone has thought about it again.
    static var allRemaining: [Gate] { allCases }

    var title: String {
        switch self {
        case .exception: return "Let this through"
        }
    }
}

// MARK: - The puzzles

enum Puzzle: Sendable {
    case typing(passage: String)
    case arithmetic(steps: [String], answer: Int)
    case memory(sequence: [Int], tiles: Int, flashMs: Int)
    case blockSort(tubes: [[Int]], capacity: Int)
    case lightsOut(grid: Int, lit: Set<Int>)
    case wait(seconds: Int)

    var kind: ChallengeKind {
        switch self {
        case .typing:     return .typing
        case .arithmetic: return .arithmetic
        case .memory:     return .memory
        case .blockSort:  return .blockSort
        case .lightsOut:  return .lightsOut
        case .wait:       return .wait
        }
    }

    /// Identifies this exact question, so the same one is never handed out twice.
    /// A wait has nothing to vary but its length, so it has no signature to track.
    var signature: String? {
        switch self {
        case .typing(let passage):        return "t:" + passage
        case .arithmetic(let steps, _):   return "a:" + steps.joined(separator: "|")
        case .memory(let seq, _, _):      return "m:" + seq.map(String.init).joined(separator: ",")
        case .blockSort(let tubes, _):    return "b:" + tubes.map { $0.map(String.init).joined() }
                                                             .joined(separator: "|")
        case .lightsOut(let grid, let lit):
            return "l:\(grid):" + lit.sorted().map(String.init).joined(separator: ",")
        case .wait:                       return nil
        }
    }
}

enum PuzzleMaker {

    /// Deliberately dull words — the fallback for the freak case where the system
    /// dictionary can't be read.
    private static let fallbackWords = [
        "amber","anchor","autumn","barrel","beacon","bishop","bramble","canvas","cavern",
        "cinder","clover","compass","copper","crater","dapple","ember","fathom","ferry",
        "fossil","gable","garnet","gravel","harbor","hollow","ivory","kettle","lantern",
        "ledger","marble","meadow","mortar","nettle","orchard","parcel","pebble","pewter",
        "pillar","quarry","quilt","ribbon","saddle","satchel","shingle","silver","socket",
        "spindle","stanza","thicket","timber","trellis","velvet","walnut","willow","zenith"
    ]

    /// The whole dictionary macOS ships, filtered to plain lowercase words of a
    /// typeable length. A rota of fifty nouns let your fingers learn the passages;
    /// a pool of a hundred thousand means every one is stubbornly unfamiliar, which
    /// is the point. Read once, the first time a passage is needed.
    private static let words: [String] = {
        guard let raw = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)
        else { return fallbackWords }
        var pool: [String] = []
        pool.reserveCapacity(120_000)
        for line in raw.split(separator: "\n") {
            // Lowercase-only keeps out the proper nouns the file capitalises.
            guard (3...9).contains(line.count),
                  line.allSatisfy({ $0.isASCII && $0.isLowercase }) else { continue }
            pool.append(String(line))
        }
        return pool.count > 1000 ? pool : fallbackWords
    }()

    static func make(_ kind: ChallengeKind, iq: Int,
                     using generator: inout some RandomNumberGenerator) -> Puzzle {
        let spec = PuzzleSpec.forIQ(iq)
        let resolved: ChallengeKind = kind == .mixed
            ? [.typing, .arithmetic, .memory, .blockSort, .lightsOut, .wait]
                .randomElement(using: &generator)!
            : kind

        switch resolved {
        case .typing:
            var picked: [String] = []
            for _ in 0..<spec.typingWords {
                picked.append(words.randomElement(using: &generator)!)
            }
            // Comma and capital cadence come from the dial, so each point produces
            // passages shaped differently from its neighbours'.
            let passage = picked.enumerated().map { index, word -> String in
                let text = index % spec.typingCapitalEvery == spec.typingCapitalEvery - 1
                    ? word.capitalized : word
                if index == picked.count - 1 { return text + "." }
                return index % spec.typingCommaEvery == spec.typingCommaEvery - 1
                    ? text + "," : text
            }.joined(separator: " ")
            return .typing(passage: passage)

        case .arithmetic:
            let start = Int.random(in: 17...96, using: &generator)
            var running = start
            var steps = ["Start with \(start)."]
            let ceiling = 400 + spec.arithmeticMax * 12

            for _ in 0..<spec.arithmeticSteps {
                var choice = Int.random(in: 0...(spec.arithmeticSquares ? 4 : 3), using: &generator)
                // Everything stays comfortably positive and bounded: "round down"
                // past zero is ambiguous, and a number nobody would multiply by hand
                // stops being a challenge and becomes a wall.
                if running < 40 && choice == 1 { choice = 0 }
                if running > ceiling && (choice == 2 || choice == 4) { choice = 3 }

                switch choice {
                case 0:
                    let n = Int.random(in: 12...spec.arithmeticMax, using: &generator)
                    running += n; steps.append("Add \(n).")
                case 1:
                    let n = Int.random(in: 12...min(spec.arithmeticMax, running - 20), using: &generator)
                    running -= n; steps.append("Subtract \(n).")
                case 2:
                    let n = Int.random(in: 3...9, using: &generator)
                    running *= n; steps.append("Multiply by \(n).")
                case 4:
                    let n = Int.random(in: 4...19, using: &generator)
                    running += n * n; steps.append("Add \(n) squared.")
                default:
                    let n = [2, 3, 4, 5].randomElement(using: &generator)!
                    running -= running % n
                    running /= n
                    steps.append("Round down to a multiple of \(n), then divide by \(n).")
                }
            }
            return .arithmetic(steps: steps, answer: running)

        case .memory:
            let tiles = 9
            var sequence: [Int] = []
            for _ in 0..<spec.memoryLength {
                // Never the same tile twice running: that would be ambiguous to tap back.
                var next = Int.random(in: 0..<tiles, using: &generator)
                while next == sequence.last { next = Int.random(in: 0..<tiles, using: &generator) }
                sequence.append(next)
            }
            return .memory(sequence: sequence, tiles: tiles, flashMs: spec.memoryFlashMs)

        case .blockSort:
            let capacity = 4
            var colours = spec.sortColours
            // A random deal is very occasionally unwinnable, and a gate you cannot
            // pass is a lockout, not a challenge — so every deal is proved winnable
            // before it is handed out. If a size somehow keeps refusing (it doesn't,
            // in practice), step down a colour rather than spin forever.
            while true {
                for _ in 0..<200 {
                    var blocks: [Int] = []
                    for colour in 0..<colours {
                        blocks.append(contentsOf: Array(repeating: colour, count: capacity))
                    }
                    blocks.shuffle(using: &generator)
                    var tubes = stride(from: 0, to: blocks.count, by: capacity).map {
                        Array(blocks[$0..<($0 + capacity)])
                    }
                    tubes.append([]); tubes.append([])
                    if !BlockSort.solved(tubes, capacity: capacity),
                       BlockSort.solvable(tubes, capacity: capacity) {
                        return .blockSort(tubes: tubes, capacity: capacity)
                    }
                }
                if colours == 3 {
                    // Unreachable in practice; a one-pour deal beats an infinite loop.
                    return .blockSort(tubes: [[0, 0], [1, 1, 1, 1], [2, 2, 2, 2], [0, 0], []],
                                      capacity: capacity)
                }
                colours -= 1
            }

        case .lightsOut:
            let grid = spec.lightsGrid
            let cells = grid * grid
            let presses = min(spec.lightsTaps, cells - 1)
            for _ in 0..<500 {
                var pressed = Set<Int>()
                while pressed.count < presses {
                    pressed.insert(Int.random(in: 0..<cells, using: &generator))
                }
                var lit = Set<Int>()
                for cell in pressed { lit = LightsOut.press(cell, lit: lit, grid: grid) }
                // Boards this size have "quiet patterns" — press sets that cancel to
                // nothing. A board that starts dark is no challenge, so deal again.
                if lit.count >= 4 { return .lightsOut(grid: grid, lit: lit) }
            }
            return .lightsOut(grid: grid, lit: LightsOut.press(0, lit: [], grid: grid))

        case .wait:
            return .wait(seconds: spec.waitSeconds)

        case .mixed:
            var g = generator
            return make(.typing, iq: iq, using: &g)
        }
    }

    static func make(_ kind: ChallengeKind, iq: Int) -> Puzzle {
        var g = SystemRandomNumberGenerator()
        return make(kind, iq: iq, using: &g)
    }

    /// A question you have already been asked is one you can answer from memory, so
    /// the ledger is what keeps the friction real. Waits are exempt — there is
    /// nothing about "wait 90 seconds" to make unique.
    static func makeUnseen(_ kind: ChallengeKind, iq: Int,
                           ledger: PuzzleLedger = .shared) -> Puzzle {
        for _ in 0..<400 {
            let puzzle = make(kind, iq: iq)
            guard let signature = puzzle.signature else { return puzzle }
            if !ledger.contains(signature) {
                ledger.remember(signature)
                return puzzle
            }
        }
        // The pool at this setting is genuinely exhausted (only reachable at the very
        // bottom of the dial). Forget the oldest rather than refusing to ask anything.
        ledger.forgetOldest(200)
        let puzzle = make(kind, iq: iq)
        if let signature = puzzle.signature { ledger.remember(signature) }
        return puzzle
    }
}

/// Remembers which questions have been asked, across restarts.
final class PuzzleLedger: @unchecked Sendable {
    static let shared = PuzzleLedger()

    private let lock = NSLock()
    private var seen: [String]
    private var index: Set<String>
    private let cap = 5000

    private static var url: URL { Store.supportDir.appendingPathComponent("puzzles-seen.json") }

    init(loading: Bool = true) {
        let stored: [String]
        if loading, let data = try? Data(contentsOf: PuzzleLedger.url),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            stored = list
        } else {
            stored = []
        }
        seen = stored
        index = Set(stored)
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return seen.count }

    func contains(_ signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return index.contains(signature)
    }

    func remember(_ signature: String) {
        lock.lock()
        seen.append(signature)
        index.insert(signature)
        if seen.count > cap {
            let dropped = seen.prefix(seen.count - cap)
            seen.removeFirst(seen.count - cap)
            for item in dropped where !seen.contains(item) { index.remove(item) }
        }
        let snapshot = seen
        lock.unlock()
        save(snapshot)
    }

    func forgetOldest(_ n: Int) {
        lock.lock()
        let dropped = seen.prefix(min(n, seen.count))
        seen.removeFirst(min(n, seen.count))
        for item in dropped { index.remove(item) }
        let snapshot = seen
        lock.unlock()
        save(snapshot)
    }

    func reset() {
        lock.lock(); seen = []; index = []; lock.unlock()
        save([])
    }

    private func save(_ snapshot: [String]) {
        guard !Store.readOnly, self === PuzzleLedger.shared else { return }
        DispatchQueue.global(qos: .background).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: PuzzleLedger.url, options: .atomic)
        }
    }
}

// MARK: - The games themselves

/// The block-sorting game, kept apart from its view so the maker can prove a deal
/// is winnable before asking anyone to win it.
enum BlockSort {

    /// One pour, or nil when the rules don't allow it: the moving colour must land
    /// on its own colour or an empty tube, and only as much of the top run moves as
    /// there is room for.
    static func pour(_ tubes: [[Int]], from a: Int, to b: Int, capacity: Int) -> [[Int]]? {
        guard a != b, let colour = tubes[a].last else { return nil }
        guard tubes[b].isEmpty || tubes[b].last == colour else { return nil }
        let room = capacity - tubes[b].count
        guard room > 0 else { return nil }
        var run = 0
        for block in tubes[a].reversed() {
            if block == colour { run += 1 } else { break }
        }
        let moving = min(run, room)
        var next = tubes
        next[a].removeLast(moving)
        next[b].append(contentsOf: Array(repeating: colour, count: moving))
        return next
    }

    static func solved(_ tubes: [[Int]], capacity: Int) -> Bool {
        tubes.allSatisfy { tube in
            tube.isEmpty || (tube.count == capacity && tube.allSatisfy { $0 == tube[0] })
        }
    }

    /// Search over game states, pruned to the moves worth making. A typical deal at
    /// Ward's sizes settles in a few thousand states; the budget is a guard rail,
    /// not a limit anything real hits.
    static func solvable(_ start: [[Int]], capacity: Int, budget: Int = 120_000) -> Bool {
        func fingerprint(_ tubes: [[Int]]) -> String {
            tubes.map { $0.map(String.init).joined(separator: " ") }
                .sorted().joined(separator: "|")
        }
        var visited: Set<String> = [fingerprint(start)]
        var stack = [start]
        while let tubes = stack.popLast() {
            if solved(tubes, capacity: capacity) { return true }
            guard visited.count < budget else { return false }
            for a in tubes.indices where !tubes[a].isEmpty {
                let uniform = tubes[a].allSatisfy { $0 == tubes[a][0] }
                // A finished tube has nowhere better to be.
                if uniform, tubes[a].count == capacity { continue }
                var triedEmpty = false
                for b in tubes.indices {
                    if tubes[b].isEmpty {
                        // Every empty tube is the same destination, and moving a
                        // uniform tube into one is the same position again.
                        if triedEmpty || uniform { continue }
                        triedEmpty = true
                    }
                    guard let next = pour(tubes, from: a, to: b, capacity: capacity)
                    else { continue }
                    if visited.insert(fingerprint(next)).inserted { stack.append(next) }
                }
            }
        }
        return false
    }
}

/// Lights-out: pressing a tile flips it and its orthogonal neighbours. Shared by
/// the maker and the view, so the scramble and the play obey the same rule.
enum LightsOut {
    static func press(_ cell: Int, lit: Set<Int>, grid: Int) -> Set<Int> {
        var next = lit
        let row = cell / grid, column = cell % grid
        for (dr, dc) in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)] {
            let r = row + dr, c = column + dc
            guard (0..<grid).contains(r), (0..<grid).contains(c) else { continue }
            let neighbour = r * grid + c
            if !next.insert(neighbour).inserted { next.remove(neighbour) }
        }
        return next
    }
}

// MARK: - Checking

enum PuzzleCheck {

    /// Exact match, whitespace at the ends forgiven. Anything looser and you can get
    /// away with skimming, which defeats the point.
    static func typingAccepted(_ typed: String, _ passage: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == passage
    }

    /// How much of the passage has been typed correctly, for the progress readout.
    static func typingProgress(_ typed: String, _ passage: String) -> Int {
        let a = Array(typed), b = Array(passage)
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }

    static func typingHasMistake(_ typed: String, _ passage: String) -> Bool {
        typingProgress(typed, passage) < typed.count
    }

    /// A jump of several characters in one edit is a paste, which would skip the
    /// entire exercise.
    static func looksPasted(previous: String, next: String) -> Bool {
        next.count - previous.count > 2
    }

    static func arithmeticAccepted(_ typed: String, _ answer: Int) -> Bool {
        Int(typed.trimmingCharacters(in: .whitespaces)) == answer
    }
}
