import Foundation
import NaturalLanguage

/// On-device meaning-matching. No network, no downloaded model — NLEmbedding ships
/// inside macOS. A title is embedded once, then compared against two sets of example
/// sentences; whichever side it lands nearer to wins.
final class Semantic {

    struct Score: Sendable {
        var studyDistance: Double
        var distractionDistance: Double
        var nearestStudy: String
        var nearestDistraction: String
        /// True when the winning side was decided by something you taught it.
        var studyViaLearned = false
        var distractionViaLearned = false
        /// Positive means it leans toward distraction.
        var lean: Double { studyDistance - distractionDistance }
        var viaLearned: Bool { lean > 0 ? distractionViaLearned : studyViaLearned }
    }

    /// Loading the model costs about 100ms. Eager, that lands squarely on launch and
    /// delays the window; lazy, it happens on the sensor queue the first time a page
    /// is actually judged. Every access is already serialised behind the judge lock.
    private lazy var embedding = NLEmbedding.sentenceEmbedding(for: .english)

    private typealias Prototype = (text: String, vec: [Double])
    private var studyVectors: [Prototype] = []
    private var distractionVectors: [Prototype] = []
    private var learnedStudyVectors: [Prototype] = []
    private var learnedDistractionVectors: [Prototype] = []
    private var builtFrom: [[String]] = []

    private var cache: [String: Score] = [:]
    private var cacheOrder: [String] = []

    var isAvailable: Bool { embedding != nil }

    // MARK: Prototypes

    private func rebuildIfNeeded(_ groups: [[String]]) {
        guard builtFrom != groups else { return }
        func build(_ list: [String]) -> [Prototype] {
            list.compactMap { t in vector(for: t).map { (t, $0) } }
        }
        studyVectors = build(groups[0])
        distractionVectors = build(groups[1])
        learnedStudyVectors = build(groups[2])
        learnedDistractionVectors = build(groups[3])
        builtFrom = groups
        cache.removeAll(); cacheOrder.removeAll()
    }

    private func vector(for text: String) -> [Double]? {
        guard let embedding else { return nil }
        let cleaned = Semantic.normalise(text)
        guard !cleaned.isEmpty else { return nil }
        if let v = embedding.vector(for: cleaned), !v.isEmpty { return v }
        return nil
    }

    // MARK: Scoring

    /// `learnedRadius` is what stops a correction doing collateral damage. A taught
    /// title is an arbitrary sentence, and in a space where most distances sit between
    /// 0.4 and 0.7, being merely *nearest* is a weak signal — one stray example can
    /// end up closest to something entirely unrelated. So a learned example only gets
    /// a vote when the title is genuinely near it; beyond that radius it is ignored.
    func score(_ text: String,
               study: [String], distraction: [String],
               learnedStudy: [String] = [], learnedDistraction: [String] = [],
               learnedRadius: Double = 0.45) -> Score? {
        rebuildIfNeeded([study, distraction, learnedStudy, learnedDistraction])
        guard !studyVectors.isEmpty, !distractionVectors.isEmpty else { return nil }

        let key = "\(learnedRadius)|" + Semantic.normalise(text)
        if let hit = cache[key] { return hit }
        guard let v = vector(for: text) else { return nil }

        func nearest(_ set: [Prototype], within limit: Double = .greatestFiniteMagnitude)
        -> (distance: Double, text: String)? {
            var best = Double.greatestFiniteMagnitude
            var who = ""
            for item in set {
                let d = Semantic.cosineDistance(v, item.vec)
                if d < best { best = d; who = item.text }
            }
            guard best <= limit else { return nil }
            return who.isEmpty ? nil : (best, who)
        }

        func combine(_ curated: [Prototype], _ learned: [Prototype])
        -> (Double, String, Bool) {
            let c = nearest(curated)!
            guard let l = nearest(learned, within: learnedRadius), l.distance < c.distance else {
                return (c.distance, c.text, false)
            }
            return (l.distance, l.text, true)
        }

        let (sd, sWho, sLearned) = combine(studyVectors, learnedStudyVectors)
        let (dd, dWho, dLearned) = combine(distractionVectors, learnedDistractionVectors)

        let s = Score(studyDistance: sd, distractionDistance: dd,
                      nearestStudy: sWho, nearestDistraction: dWho,
                      studyViaLearned: sLearned, distractionViaLearned: dLearned)

        cache[key] = s
        cacheOrder.append(key)
        if cacheOrder.count > 400 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return s
    }

    // MARK: Maths

    /// Cosine distance in the same 0...2 range NLEmbedding reports, so the margin
    /// slider means the same thing whichever path produced the number.
    static func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - (dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// Strip the furniture that video titles collect so the embedding sees the topic:
    /// channel suffixes, episode numbers, view counts, emoji, bracketed tags.
    static func normalise(_ raw: String) -> String {
        var s = raw.lowercased()
        for suffix in [" - youtube", " — youtube", " - vimeo", " | vimeo",
                       " - google chrome", " — google chrome", " - safari", " — safari",
                       " — mozilla firefox", " - mozilla firefox", " and 1 more page",
                       " - brave", " — brave", " - microsoft edge", " — microsoft edge"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^\p{L}\p{N}\s'&+#-]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
