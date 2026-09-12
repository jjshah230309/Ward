import SwiftUI

/// The same puzzles, with nothing riding on them. Useful for finding out what a
/// setting on the dial actually feels like before you make your rules depend on it,
/// and reasonable enough as a warm-up between pieces of work.
struct PracticePane: View {
    @ObservedObject private var store = Store.shared
    @Environment(\.uiScale) private var scale

    @State private var puzzle: Puzzle?
    @State private var startedAt: Date?
    @State private var lastSeconds: Double?
    @State private var solvedThisSitting = 0

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 7)]

    private var stats: PracticeStats { store.rules.practice }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack(spacing: 9) {
                StatTile(value: "\(stats.solved)", label: "solved",
                         icon: "checkmark.circle.fill",
                         tone: stats.solved > 0 ? .allow : .neutral)
                StatTile(value: "\(stats.streak)", label: "streak", icon: "flame.fill",
                         tone: stats.streak >= 3 ? .block : .neutral)
                StatTile(value: "\(stats.bestStreak)", label: "best run", icon: "trophy")
                StatTile(value: stats.solved == 0 ? "\u{2014}"
                                : String(format: "%.0fs", stats.averageSeconds),
                         label: "average", icon: "stopwatch")
            }

            if let puzzle {
                playing(puzzle)
            } else {
                setup
            }
        }
    }

    // MARK: Choosing what to play

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(icon: "gamecontroller", title: "Pick a puzzle",
                 subtitle: "Separate from the setting that guards your rules \u{2014} playing here changes nothing.") {
                LazyVGrid(columns: columns, spacing: 7) {
                    ForEach(ChallengeKind.allCases) { kind in
                        let on = store.rules.practiceKind == kind
                        Button { store.rules.practiceKind = kind } label: {
                            VStack(spacing: 4) {
                                Image(systemName: kind.icon).wardFont(15)
                                Text(kind.label).wardFont(10.5)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(on ? Color.orange.opacity(0.15) : Color.primary.opacity(0.045))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(on ? Color.orange.opacity(0.45)
                                                     : Color.primary.opacity(0.07), lineWidth: 0.8)))
                            .foregroundStyle(on ? Color.orange : Color.primary.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("IQ").wardFont(10, weight: .semibold, tracking: 0.8)
                        .foregroundStyle(.tertiary)
                    Text("\(store.rules.practiceIQ)")
                        .wardFont(28, weight: .semibold, design: .rounded, monoDigits: true)
                        .foregroundStyle(.orange)
                        .frame(width: 56 * scale, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(store.rules.practiceIQ) },
                        set: { store.rules.practiceIQ = IQ.clamp(Int($0.rounded())) }),
                        in: Double(IQ.range.lowerBound)...Double(IQ.range.upperBound))
                        .controlSize(.small)
                }

                HStack(spacing: 6) {
                    Image(systemName: "ruler").wardFont(9.5).foregroundStyle(.tertiary)
                    Text(demand).wardFont(10.5, monoDigits: true).foregroundStyle(.secondary)
                    Spacer()
                    if let best = stats.best[store.rules.practiceKind.rawValue] {
                        Text(String(format: "best %.1fs", best))
                            .wardFont(10.5, monoDigits: true).foregroundStyle(.tertiary)
                    }
                }

                Button { next() } label: {
                    Label("Start", systemImage: "play.fill")
                        .wardFont(12, weight: .medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
            }

            if stats.solved > 0 {
                Card(icon: "chart.bar", title: "Fastest so far") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ChallengeKind.allCases.filter { $0 != .mixed }) { kind in
                            HStack(spacing: 7) {
                                Image(systemName: kind.icon).wardFont(10)
                                    .foregroundStyle(.secondary).frame(width: 16)
                                Text(kind.label).wardFont(11.5)
                                Spacer()
                                if let best = stats.best[kind.rawValue] {
                                    Text(String(format: "%.1fs", best))
                                        .wardFont(11, weight: .medium, monoDigits: true)
                                } else {
                                    Text("not yet").wardFont(10.5).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Button("Reset scores") {
                        store.rules.practice = PracticeStats()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Playing

    private func playing(_ puzzle: Puzzle) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(icon: puzzle.kind.icon, title: puzzle.kind.label,
                 subtitle: solvedThisSitting > 0
                     ? "\(solvedThisSitting) this sitting. Nothing rides on it \u{2014} stop whenever."
                     : "Nothing rides on this one. Stop whenever you like.",
                 tone: .accent) {
                PuzzleView(puzzle: puzzle) { solved() }

                HStack {
                    if let lastSeconds {
                        Text(String(format: "last one took %.1fs", lastSeconds))
                            .wardFont(10.5, monoDigits: true).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Skip") { skip() }.controlSize(.small)
                    Button("Stop") { stop() }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Actions

    private var demand: String {
        let spec = PuzzleSpec.forIQ(store.rules.practiceIQ)
        switch store.rules.practiceKind {
        case .typing:     return "\(spec.typingWords) words to copy"
        case .arithmetic: return "\(spec.arithmeticSteps) steps, numbers to \(spec.arithmeticMax)"
                                 + (spec.arithmeticSquares ? ", with squares" : "")
        case .memory:     return "\(spec.memoryLength) tiles at \(String(format: "%.2f", Double(spec.memoryFlashMs) / 1000))s each"
        case .blockSort:  return "\(spec.sortColours) colours across \(spec.sortColours + 2) tubes"
        case .lightsOut:  return "\(spec.lightsGrid)\u{00D7}\(spec.lightsGrid) board, "
                               + "scrambled \(min(spec.lightsTaps, spec.lightsGrid * spec.lightsGrid - 1)) deep"
        case .wait:       return spec.waitSeconds < 60 ? "\(spec.waitSeconds) seconds"
                                                       : "\(spec.waitSeconds / 60)m \(spec.waitSeconds % 60)s"
        case .mixed:      return "one of the six, at random"
        }
    }

    private func next() {
        puzzle = PuzzleMaker.makeUnseen(store.rules.practiceKind, iq: store.rules.practiceIQ)
        startedAt = Date()
    }

    private func solved() {
        let seconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        lastSeconds = seconds
        solvedThisSitting += 1
        var stats = store.rules.practice
        stats.record(kind: puzzle?.kind ?? store.rules.practiceKind, seconds: seconds)
        store.rules.practice = stats
        next()
    }

    private func skip() {
        var stats = store.rules.practice
        stats.giveUp()
        store.rules.practice = stats
        next()
    }

    private func stop() {
        puzzle = nil
        startedAt = nil
        solvedThisSitting = 0
    }
}
