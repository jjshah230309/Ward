import SwiftUI

struct HistoryPane: View {
    @ObservedObject private var store = Store.shared
    @Environment(\.uiScale) private var scale

    @State private var entries: [LogEntry] = []
    @State private var stats = Stats()
    @State private var filter = ""

    private var shown: [LogEntry] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.what.lowercased().contains(needle) || $0.reason.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack(spacing: 9) {
                StatTile(value: "\(stats.today)", label: "today",
                         icon: "hand.raised.fill", tone: stats.today > 0 ? .block : .neutral)
                StatTile(value: "\(stats.week)", label: "this week", icon: "calendar")
                StatTile(value: stats.busiestHour.map { String(format: "%02d:00", $0) } ?? "\u{2014}",
                         label: "worst hour", icon: "clock")
                StatTile(value: "\(entries.count)", label: "on record", icon: "tray.full")
            }

            Card(icon: "chart.bar", title: "Last seven days") {
                if stats.days.allSatisfy({ $0.count == 0 }) {
                    EmptyHint(icon: "chart.bar",
                              title: "Nothing recorded yet",
                              message: "Blocks appear here as they happen, and survive a restart.")
                } else {
                    WeekChart(days: stats.days)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                Card(icon: "arrow.up.right", title: "Stopped most often",
                     count: stats.topItems.isEmpty ? nil : stats.topItems.count) {
                    if stats.topItems.isEmpty {
                        Text("Nothing yet.").wardFont(11).foregroundStyle(.tertiary)
                    } else {
                        RankedList(rows: stats.topItems, tone: .block)
                    }
                }
                Card(icon: "questionmark.circle", title: "Why they were stopped",
                     count: stats.topReasons.isEmpty ? nil : stats.topReasons.count) {
                    if stats.topReasons.isEmpty {
                        Text("Nothing yet.").wardFont(11).foregroundStyle(.tertiary)
                    } else {
                        RankedList(rows: stats.topReasons, tone: .accent)
                    }
                }
            }

            Card(icon: "list.bullet", title: "Everything",
                 count: entries.isEmpty ? nil : entries.count) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").wardFont(9.5).foregroundStyle(.tertiary)
                    TextField("Filter\u{2026}", text: $filter)
                        .textFieldStyle(.plain).wardFont(11)
                    Spacer()
                    Button("Refresh") { reload() }.controlSize(.small)
                    Button("Clear") {
                        History.clear(); entries = []; stats = Stats()
                    }
                    .controlSize(.small)
                    .disabled(entries.isEmpty || store.rules.isLocked)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.045)))

                if shown.isEmpty {
                    Text(entries.isEmpty ? "Nothing recorded yet."
                                         : "Nothing matches \u{201C}\(filter)\u{201D}.")
                        .wardFont(11).foregroundStyle(.tertiary).padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shown.prefix(200)) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.at, format: .dateTime.day().month().hour().minute())
                                    .wardFont(10, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 118 * scale, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.what).wardFont(11.5).lineLimit(1)
                                    Text(entry.reason).wardFont(10)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            Divider().opacity(0.25)
                        }
                    }
                    if shown.count > 200 {
                        Text("Showing the most recent 200 of \(shown.count).")
                            .wardFont(10).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        entries = store.loadHistory()
        stats = Stats.build(from: entries)
    }
}

/// A plain bar per day. Seven numbers don't need axes or a legend to be readable.
private struct WeekChart: View {
    let days: [(date: Date, count: Int)]
    @Environment(\.uiScale) private var scale

    var body: some View {
        let peak = max(days.map(\.count).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 4) {
                    Text("\(day.count)")
                        .wardFont(10, weight: .medium, monoDigits: true)
                        .foregroundStyle(day.count == 0 ? .tertiary : .secondary)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(day.count == 0
                              ? AnyShapeStyle(Color.secondary.opacity(0.14))
                              : AnyShapeStyle(LinearGradient(
                                    colors: [.orange, .orange.opacity(0.55)],
                                    startPoint: .top, endPoint: .bottom)))
                        .frame(height: max(4, CGFloat(day.count) / CGFloat(peak) * 68 * scale))
                    Text(day.date, format: .dateTime.weekday(.abbreviated))
                        .wardFont(9.5).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

private struct RankedList: View {
    let rows: [(name: String, count: Int)]
    let tone: Tone

    var body: some View {
        let peak = max(rows.map(\.count).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).wardFont(11).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(row.count)")
                            .wardFont(10, weight: .medium, monoDigits: true)
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        Capsule()
                            .fill(tone.color.opacity(0.35))
                            .frame(width: max(2, geo.size.width * CGFloat(row.count) / CGFloat(peak)),
                                   height: 3)
                    }
                    .frame(height: 3)
                }
            }
        }
    }
}
