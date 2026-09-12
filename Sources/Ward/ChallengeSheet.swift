import SwiftUI
import AppKit

/// Stands between an impulse and switching Ward off. Cancelling always leaves the
/// rules as they were, so the safe direction is the easy one.
@MainActor
final class Challenges: ObservableObject {
    static let shared = Challenges()

    struct Pending: Identifiable {
        let id = UUID()
        let gate: Gate
        let puzzle: Puzzle
        let action: () -> Void
    }

    @Published var pending: Pending?

    /// Runs `action` straight away when this gate isn't guarded, otherwise puts a
    /// puzzle in the way first.
    func require(_ gate: Gate, then action: @escaping () -> Void) {
        let settings = Store.shared.rules.challenge
        let guarded: Bool
        switch gate {
        case .exception: guarded = settings.onException
        }

        // Whether this actually weakens anything. The old test was `isActive`, which
        // let the whole system be walked around: pause first (unguarded by default),
        // and turning Ward off then counted as "not a weakening" because it was
        // already inactive. A pause expires on its own; being switched off does not,
        // so turning off while paused is still a weakening.
        let weakens = Store.shared.rules.enabled
        guard guarded, weakens else { action(); return }

        pending = Pending(gate: gate,
                          puzzle: PuzzleMaker.makeUnseen(settings.kind, iq: settings.iq),
                          action: action)
        // The dashboard is where the window app presents the puzzle. The agent has
        // its own window for it, and launching the full app on top of that would
        // put two of them on screen.
        if !AppDelegate.isBackgroundLaunch { AppDelegate.openDashboard() }
    }

    /// A dry run from Settings, so you can see what you're signing up for. It changes
    /// nothing either way.
    func preview() {
        let settings = Store.shared.rules.challenge
        pending = Pending(gate: .exception,
                          puzzle: PuzzleMaker.makeUnseen(settings.kind, iq: settings.iq),
                          action: {})
        AppDelegate.openDashboard()
    }

    func succeed() {
        let action = pending?.action
        pending = nil
        action?()
    }

    func cancel() { pending = nil }
}

// MARK: - Sheet

struct ChallengeSheet: View {
    let pending: Challenges.Pending
    @ObservedObject private var challenges = Challenges.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.14))
                        .frame(width: 38 * scale, height: 38 * scale)
                    Image(systemName: "lock.fill")
                        .wardFont(16, weight: .semibold).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(pending.gate.title).wardFont(16, weight: .semibold)
                    Text("You asked for this. Finish it and Ward will stand down.")
                        .wardFont(11.5).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            PuzzleView(puzzle: pending.puzzle, done: challenges.succeed)

            HStack {
                Text("Cancel and everything stays exactly as it is.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { challenges.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520 * scale)
    }
}

/// Renders whichever puzzle it is handed. Shared by the gate and the quiz so the two
/// can never drift apart.
struct PuzzleView: View {
    let puzzle: Puzzle
    let done: () -> Void

    var body: some View {
        switch puzzle {
        case .typing(let passage):
            TypingChallenge(passage: passage, done: done)
        case .arithmetic(let steps, let answer):
            ArithmeticChallenge(steps: steps, answer: answer, done: done)
        case .memory(let sequence, let tiles, let flashMs):
            MemoryChallenge(sequence: sequence, tiles: tiles, flashMs: flashMs, done: done)
        case .blockSort(let tubes, let capacity):
            BlockSortChallenge(tubes: tubes, capacity: capacity, done: done)
        case .lightsOut(let grid, let lit):
            LightsOutChallenge(grid: grid, lit: lit, done: done)
        case .wait(let seconds):
            WaitChallenge(seconds: seconds, done: done)
        }
    }
}

// MARK: - Retype a passage

struct TypingChallenge: View {
    let passage: String
    let done: () -> Void

    @State private var typed = ""
    @State private var warning: String?
    @FocusState private var focused: Bool

    private var progress: Int { PuzzleCheck.typingProgress(typed, passage) }
    private var mistake: Bool { PuzzleCheck.typingHasMistake(typed, passage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // The part already typed correctly dims, so you can see where you are.
            Text(attributed)
                .wardFont(12.5, design: .monospaced)
                .textSelection(.disabled)
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045)))

            TextField("Type it out", text: $typed, axis: .vertical)
                .textFieldStyle(.plain)
                .wardFont(12.5, design: .monospaced)
                .lineLimit(3...6)
                .focused($focused)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(mistake ? Color.red.opacity(0.5)
                                              : Color.primary.opacity(0.1), lineWidth: 0.8)))
                .onChange(of: typed) { [previous = typed] next in
                    if PuzzleCheck.looksPasted(previous: previous, next: next) {
                        typed = ""
                        warning = "Pasting doesn't count. Type it."
                        return
                    }
                    warning = nil
                    if PuzzleCheck.typingAccepted(next, passage) { done() }
                }

            HStack {
                Text(warning ?? (mistake ? "That doesn't match \u{2014} back up and fix it."
                                         : "\(progress) of \(passage.count) characters"))
                    .wardFont(10.5)
                    .foregroundStyle(warning != nil || mistake ? Color.red : .secondary)
                Spacer()
            }
        }
        .onAppear { focused = true }
    }

    private var attributed: AttributedString {
        var out = AttributedString(passage)
        if let upto = out.index(out.startIndex, offsetByCharacters: progress) as AttributedString.Index?,
           progress > 0 {
            out[out.startIndex..<upto].foregroundColor = .secondary.opacity(0.35)
        }
        return out
    }
}

// MARK: - Work out a sum

struct ArithmeticChallenge: View {
    let steps: [String]
    let answer: Int
    let done: () -> Void

    @State private var typed = ""
    @State private var wrong = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .wardFont(10, weight: .semibold, monoDigits: true)
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .trailing)
                        Text(step).wardFont(12.5)
                    }
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045)))

            HStack(spacing: 8) {
                TextField("Answer", text: $typed)
                    .textFieldStyle(.plain)
                    .wardFont(14, weight: .medium, monoDigits: true)
                    .focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(wrong ? Color.red.opacity(0.5)
                                                : Color.primary.opacity(0.1), lineWidth: 0.8)))
                    .frame(width: 140)
                    .onSubmit(check)
                Button("Check", action: check)
                    .disabled(typed.isEmpty)
                Spacer()
            }

            Text(wrong ? "Not right. Work through it again."
                       : "No calculator. It only takes the exact number.")
                .wardFont(10.5)
                .foregroundStyle(wrong ? Color.red : .secondary)
        }
        .onAppear { focused = true }
    }

    private func check() {
        if PuzzleCheck.arithmeticAccepted(typed, answer) { done() }
        else { wrong = true; typed = "" }
    }
}

// MARK: - Repeat a sequence

struct MemoryChallenge: View {
    let sequence: [Int]
    let tiles: Int
    let flashMs: Int
    let done: () -> Void

    @State private var lit: Int?
    @State private var playing = true
    @State private var entered: [Int] = []
    @State private var message = "Watch."

    private let columns = [GridItem(.adaptive(minimum: 54, maximum: 72), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<tiles, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(lit == index ? Color.orange : Color.primary.opacity(0.07))
                        .frame(height: 54)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                        .onTapGesture { tap(index) }
                }
            }
            .disabled(playing)
            .opacity(playing ? 0.75 : 1)

            HStack {
                Text(message).wardFont(11).foregroundStyle(.secondary)
                Spacer()
                Text("\(entered.count) / \(sequence.count)")
                    .wardFont(10.5, monoDigits: true).foregroundStyle(.tertiary)
            }
        }
        .task { await play() }
    }

    private func play() async {
        playing = true
        entered = []
        message = "Watch."
        try? await Task.sleep(nanoseconds: 500_000_000)
        let on = UInt64(flashMs) * 1_000_000
        let off = UInt64(max(90, flashMs / 3)) * 1_000_000
        for tile in sequence {
            lit = tile
            try? await Task.sleep(nanoseconds: on)
            lit = nil
            try? await Task.sleep(nanoseconds: off)
        }
        playing = false
        message = "Now repeat it."
    }

    private func tap(_ index: Int) {
        guard !playing else { return }
        if sequence[entered.count] == index {
            entered.append(index)
            if entered.count == sequence.count { done() }
        } else {
            message = "Wrong tile. Watch it again."
            Task { await play() }
        }
    }
}

// MARK: - Sort the blocks

struct BlockSortChallenge: View {
    let start: [[Int]]
    let capacity: Int
    let done: () -> Void

    @State private var tubes: [[Int]]
    @State private var selected: Int?
    @State private var moves = 0

    init(tubes: [[Int]], capacity: Int, done: @escaping () -> Void) {
        self.start = tubes
        self.capacity = capacity
        self.done = done
        _tubes = State(initialValue: tubes)
    }

    private static let palette: [Color] = [
        Color(red: 0.91, green: 0.30, blue: 0.24),
        Color(red: 0.20, green: 0.51, blue: 0.96),
        Color(red: 0.30, green: 0.69, blue: 0.31),
        Color(red: 0.95, green: 0.61, blue: 0.07),
        Color(red: 0.61, green: 0.35, blue: 0.95),
        Color(red: 0.10, green: 0.66, blue: 0.62),
        Color(red: 0.94, green: 0.38, blue: 0.66),
    ]
    /// A second channel besides colour, so the game isn't unplayable for
    /// colour-blind eyes.
    private static let glyphs = ["circle.fill", "triangle.fill", "square.fill",
                                 "diamond.fill", "star.fill", "heart.fill", "hexagon.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .bottom, spacing: 9) {
                ForEach(tubes.indices, id: \.self) { index in
                    tube(index)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: tubes)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selected)

            HStack {
                Text(selected == nil
                     ? "Tap a tube to pick it up, then a tube to pour into."
                     : "Pour onto the same colour, or into an empty tube.")
                    .wardFont(10.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(moves) pours").wardFont(10.5, monoDigits: true).foregroundStyle(.tertiary)
                Button("Start over") { tubes = start; selected = nil; moves = 0 }
                    .controlSize(.small)
            }
        }
    }

    private func tube(_ index: Int) -> some View {
        let lifted = selected == index
        return VStack(spacing: 3) {
            ForEach((0..<capacity).reversed(), id: \.self) { slot in
                block(tube: index, slot: slot)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(lifted ? Color.orange.opacity(0.6) : Color.primary.opacity(0.08),
                              lineWidth: lifted ? 1.2 : 0.8)))
        .offset(y: lifted ? -5 : 0)
        .contentShape(Rectangle())
        .onTapGesture { tap(index) }
    }

    @ViewBuilder
    private func block(tube: Int, slot: Int) -> some View {
        if slot < tubes[tube].count {
            let colour = tubes[tube][slot]
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Self.palette[colour % Self.palette.count])
                .frame(width: 34, height: 22)
                .overlay(Image(systemName: Self.glyphs[colour % Self.glyphs.count])
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.55)))
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 34, height: 22)
        }
    }

    private func tap(_ index: Int) {
        guard let from = selected else {
            if !tubes[index].isEmpty { selected = index }
            return
        }
        if from == index { selected = nil; return }
        if let next = BlockSort.pour(tubes, from: from, to: index, capacity: capacity) {
            tubes = next
            moves += 1
            selected = nil
            if BlockSort.solved(tubes, capacity: capacity) { done() }
        } else {
            // Not a legal pour — treat the tap as picking a different tube up.
            selected = tubes[index].isEmpty ? nil : index
        }
    }
}

// MARK: - Lights out

struct LightsOutChallenge: View {
    let grid: Int
    let start: Set<Int>
    let done: () -> Void

    @State private var lit: Set<Int>
    @State private var taps = 0

    init(grid: Int, lit: Set<Int>, done: @escaping () -> Void) {
        self.grid = grid
        self.start = lit
        self.done = done
        _lit = State(initialValue: lit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 7), count: grid),
                      spacing: 7) {
                ForEach(0..<grid * grid, id: \.self) { cell in
                    let on = lit.contains(cell)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(on ? Color.orange : Color.primary.opacity(0.07))
                        .frame(height: 46)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
                        .onTapGesture { tap(cell) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045)))
            .animation(.easeOut(duration: 0.12), value: lit)

            HStack {
                Text("A tap flips that tile and its neighbours. Dark wins.")
                    .wardFont(10.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(lit.count) lit \u{00B7} \(taps) taps")
                    .wardFont(10.5, monoDigits: true).foregroundStyle(.tertiary)
                Button("Start over") { lit = start; taps = 0 }
                    .controlSize(.small)
            }
        }
    }

    private func tap(_ cell: Int) {
        lit = LightsOut.press(cell, lit: lit, grid: grid)
        taps += 1
        if lit.isEmpty { done() }
    }
}

// MARK: - Sit and wait

struct WaitChallenge: View {
    let seconds: Int
    let done: () -> Void

    @State private var remaining: Double
    @State private var active = true

    init(seconds: Int, done: @escaping () -> Void) {
        self.seconds = seconds
        self.done = done
        _remaining = State(initialValue: Double(seconds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                Text("\(Int(remaining.rounded(.up)))")
                    .wardFont(40, weight: .semibold, design: .rounded, monoDigits: true)
                    .foregroundStyle(active ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(active ? "seconds to go" : "paused \u{2014} bring this window back")
                        .wardFont(12).foregroundStyle(.secondary)
                    ProgressView(value: Double(seconds) - remaining, total: Double(seconds))
                        .frame(width: 220)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045)))

            Text("The clock only runs while this window is in front, so switching away won't get you there faster.")
                .wardFont(10.5).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            active = NSApp.isActive
            guard active else { return }
            remaining = max(0, remaining - 0.1)
            if remaining <= 0 { done() }
        }
    }
}
