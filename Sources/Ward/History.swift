import Foundation

/// Blocks were only ever kept in memory, so every restart wiped the record — which
/// makes it impossible to see whether any of this is working. One JSON object per
/// line, appended, cheap to write and easy to read back.
enum History {

    static var url: URL { Store.supportDir.appendingPathComponent("events.jsonl") }

    private static let maxLines = 20_000
    private static let queue = DispatchQueue(label: "app.ward.history", qos: .background)

    static func append(_ entry: LogEntry) {
        guard !Store.readOnly else { return }
        queue.async {
            guard let data = try? JSONEncoder.ward.encode(entry),
                  var line = String(data: data, encoding: .utf8) else { return }
            line = line.replacingOccurrences(of: "\n", with: " ") + "\n"
            guard let bytes = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: bytes)
            } else {
                try? bytes.write(to: url, options: .atomic)
            }
        }
    }

    static func load(limit: Int = 3000) -> [LogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n").suffix(limit)
        let decoder = JSONDecoder.ward
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(LogEntry.self, from: data)
        }
    }

    /// Keeps the file from growing without bound. Cheap because it only runs at launch.
    static func trim() {
        guard !Store.readOnly else { return }
        queue.async {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard lines.count > maxLines else { return }
            let kept = lines.suffix(maxLines).joined(separator: "\n") + "\n"
            try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    static func clear() {
        guard !Store.readOnly else { return }
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}

/// What the History pane shows: enough to tell whether any of this is helping.
struct Stats {
    var today = 0
    var week = 0
    var days: [(date: Date, count: Int)] = []
    var topItems: [(name: String, count: Int)] = []
    var topReasons: [(name: String, count: Int)] = []
    var busiestHour: Int?

    static func build(from entries: [LogEntry], calendar: Calendar = .current) -> Stats {
        var s = Stats()
        let blocks = entries.filter(\.blocked)
        let startOfToday = calendar.startOfDay(for: Date())

        // Seven days ending today, so an empty day still shows as a gap.
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)
            else { continue }
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let count = blocks.filter { $0.at >= day && $0.at < next }.count
            s.days.append((day, count))
            s.week += count
            if offset == 0 { s.today = count }
        }

        func tally(_ key: (LogEntry) -> String) -> [(String, Int)] {
            var counts: [String: Int] = [:]
            for b in blocks { counts[key(b), default: 0] += 1 }
            return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                         .prefix(6).map { ($0.key, $0.value) }
        }
        s.topItems = tally { String($0.what.prefix(70)) }
        // Strip the trailing detail so "matched block phrase - x" groups with its kin.
        s.topReasons = tally { $0.reason.components(separatedBy: " \u{2014} ").first ?? $0.reason }

        var byHour: [Int: Int] = [:]
        for b in blocks {
            byHour[calendar.component(.hour, from: b.at), default: 0] += 1
        }
        s.busiestHour = byHour.max { $0.value < $1.value }?.key
        return s
    }
}
