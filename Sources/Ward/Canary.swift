import Foundation

/// A threshold set too low fails quietly: you only notice when a lecture you needed
/// gets blocked, and by then you've lost the thread. These are titles that are
/// unambiguously study material, run through the real pipeline so the interface can
/// say "your current setting would block this" before it happens to you.
enum Canary {

    static let studyTitles = [
        "Understanding Big O Notation for interviews",
        "How to Solve Quadratic Equations | Algebra Basics",
        "Cell Division: Mitosis and Meiosis compared",
        "What is a Fourier Transform? Visual Introduction",
        "Neural Networks: Backpropagation from scratch",
        "The Economics of Video Games",
        "How Video Game Physics Engines Actually Work",
        "An introduction to statistical significance",
        "Balancing chemical equations step by step",
        "Essay structure for A-Level History"
    ]

    /// Titles that should clearly be stopped. If the threshold drifts too high these
    /// start slipping through, which is the opposite failure and just as worth saying.
    static let distractionTitles = [
        "I Built a $100,000 Maze",
        "Top 10 Anime Openings of All Time",
        "Ranking every fast food burger in America",
        "Reacting to my old TikToks"
    ]

    struct Health {
        var falseBlocks: [String]
        var misses: [String]
        var ok: Bool { falseBlocks.isEmpty && misses.isEmpty }
    }

    static func check(_ judge: (String) -> Verdict.Call) -> Health {
        Health(falseBlocks: studyTitles.filter { judge($0) == .block },
               misses: distractionTitles.filter { judge($0) == .allow })
    }
}
