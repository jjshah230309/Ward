import SwiftUI

// MARK: - Interface scale
//
// Zoom has to change type size, not blow up a bitmap, so nothing is ever soft.
// The factor rides the environment and every piece of text goes through one
// modifier, which means a change re-lays-out the whole window at native sharpness.

private struct UIScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

struct ScaledFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    var weight: Font.Weight = .regular
    var design: Font.Design = .default
    var monoDigits = false
    var tracking: CGFloat = 0

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight, design: design)
        return content
            .font(monoDigits ? font.monospacedDigit() : font)
            .tracking(tracking * scale)
    }
}

extension View {
    /// Every bit of text in Ward goes through this so zoom stays crisp.
    func wardFont(_ size: CGFloat, weight: Font.Weight = .regular,
                  design: Font.Design = .default, monoDigits: Bool = false,
                  tracking: CGFloat = 0) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design,
                            monoDigits: monoDigits, tracking: tracking))
    }
}

/// Fixed dimensions — icon boxes, dots, paddings — have to move with the type or
/// the layout comes apart at the extremes.
struct Scaled: ViewModifier {
    @Environment(\.uiScale) private var scale
    let base: CGFloat
    let apply: (CGFloat) -> AnyView
    func body(content: Content) -> some View { apply(base * scale) }
}

extension EnvironmentValues {
    func px(_ v: CGFloat) -> CGFloat { v * uiScale }
}

// MARK: - Palette

enum Tone {
    case neutral, allow, block, hard, accent

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .allow:   return .green
        case .block:   return .orange
        case .hard:    return .red
        case .accent:  return .orange
        }
    }
    var fill: Color   { self == .neutral ? Color.secondary.opacity(0.10) : color.opacity(0.14) }
    var stroke: Color { self == .neutral ? Color.secondary.opacity(0.22) : color.opacity(0.35) }
    var label: Color  { self == .neutral ? Color.primary.opacity(0.75)   : color }
}

// MARK: - Wrapping layout
//
// Phrase lists are short tokens, and a scrolling column shows five of twenty-one.
// Flowing them means the whole rulebook is visible at a glance.

struct Flow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                       proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Chip

struct Chip: View {
    let text: String
    var tone: Tone = .neutral
    var mono: Bool = false
    var warning: String?
    var onDelete: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            if warning != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
            Text(text)
                .wardFont(mono ? 11 : 11.5, design: mono ? .monospaced : .default)
                .foregroundStyle(tone.label)
                .lineLimit(1)
            if hovering, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .wardFont(7.5, weight: .bold)
                        .foregroundStyle(tone.label.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(
            Capsule().fill(tone.fill)
                .overlay(Capsule().strokeBorder(tone.stroke, lineWidth: 0.8))
        )
        .onHover { hovering = $0 && onDelete != nil }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(warning ?? "")
    }
}


// MARK: - Card

struct Card<Content: View>: View {
    var icon: String? = nil
    var title: String? = nil
    var subtitle: String? = nil
    var tone: Tone = .neutral
    var count: Int? = nil
    var padding: CGFloat = 14
    /// Rarely-edited sections can fold away so a pane stays scannable.
    var collapsible: Bool = false
    var startCollapsed: Bool = false
    @ViewBuilder var content: Content

    @State private var override: Bool?
    private var expanded: Bool { override ?? !startCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || icon != nil {
                HStack(spacing: 7) {
                    if let icon {
                        Image(systemName: icon)
                            .wardFont(11, weight: .semibold)
                            .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
                    }
                    if let title {
                        Text(title).wardFont(12.5, weight: .semibold)
                    }
                    if let count {
                        Text("\(count)")
                            .wardFont(10, weight: .medium, monoDigits: true)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                    if collapsible {
                        Image(systemName: "chevron.right")
                            .wardFont(9, weight: .semibold)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard collapsible else { return }
                    withAnimation(.easeOut(duration: 0.18)) { override = !expanded }
                }
                if let subtitle {
                    Text(subtitle)
                        .wardFont(11)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if expanded { content }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
}

// MARK: - Chip editor

struct ChipEditor: View {
    let title: String
    let icon: String
    let hint: String
    var tone: Tone = .neutral
    var mono: Bool = false
    var placeholder: String = "Add\u{2026}"
    @Binding var items: [String]
    var locked: Bool = false
    /// Entries that are present but broken, with the reason to show on hover.
    var problems: [String: String] = [:]
    /// When set, an entry an existing rule already covers is refused with a reason.
    var checkRedundancy: Bool = false

    @State private var draft = ""
    @State private var filter = ""
    @State private var note: String?
    @FocusState private var focused: Bool

    /// Past a couple of dozen entries, scanning stops working and you need to search.
    private var showFilter: Bool { items.count >= 18 }

    private var shown: [(offset: Int, element: String)] {
        let all = Array(items.enumerated()).map { (offset: $0.offset, element: $0.element) }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { $0.element.contains(needle) }
    }

    var body: some View {
        Card(icon: icon, title: title, subtitle: hint, tone: tone, count: items.count) {
            if showFilter {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .wardFont(9.5).foregroundStyle(.tertiary)
                    TextField("Filter \(items.count) entries\u{2026}", text: $filter)
                        .textFieldStyle(.plain).wardFont(11)
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .wardFont(9.5).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.045)))
            }

            if items.isEmpty {
                Text("Nothing here yet.")
                    .wardFont(11).foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else if shown.isEmpty {
                Text("Nothing matches \u{201C}\(filter)\u{201D}.")
                    .wardFont(11).foregroundStyle(.tertiary).padding(.vertical, 4)
            } else {
                Flow(spacing: 5, lineSpacing: 5) {
                    ForEach(shown, id: \.offset) { index, item in
                        Chip(text: item,
                             tone: problems[item] == nil ? tone : .block,
                             mono: mono,
                             warning: problems[item],
                             onDelete: locked ? nil : { items.remove(at: index) })
                    }
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .wardFont(9, weight: .bold)
                    .foregroundStyle(.tertiary)
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .wardFont(11.5)
                    .focused($focused)
                    .onSubmit(add)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(focused ? 0.07 : 0.04))
                    .overlay(Capsule().strokeBorder(
                        focused ? tone.stroke : Color.primary.opacity(0.08), lineWidth: 0.8))
            )
            .disabled(locked)

            if let note {
                Text(note).wardFont(10.5).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return }
        if items.contains(value) {
            note = "\u{201C}\(value)\u{201D} is already in this list."
            draft = ""
            return
        }
        if checkRedundancy, let covering = Rules.coveringPhrase(for: value, in: items) {
            note = "\u{201C}\(covering)\u{201D} already catches anything \u{201C}\(value)\u{201D} would."
            draft = ""
            return
        }
        items.append(value)
        draft = ""
        note = nil
    }
}

// MARK: - Sentence editor
//
// The example sentences are prose, not tokens, so they get rows rather than chips.

struct SentenceEditor: View {
    let title: String
    let icon: String
    let hint: String
    var tone: Tone
    @Binding var items: [String]
    var locked: Bool = false

    @State private var draft = ""

    var body: some View {
        Card(icon: icon, title: title, subtitle: hint, tone: tone, count: items.count,
             collapsible: true, startCollapsed: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    SentenceRow(text: item, tone: tone,
                                onDelete: locked ? nil : { items.remove(at: index) })
                    if index < items.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .wardFont(9, weight: .bold).foregroundStyle(.tertiary)
                TextField("Describe something you'd \(tone == .allow ? "watch" : "avoid")\u{2026}",
                          text: $draft)
                    .textFieldStyle(.plain)
                    .wardFont(11.5)
                    .onSubmit(add)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(
                Capsule().fill(Color.primary.opacity(0.04))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8))
            )
            .disabled(locked)
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !items.contains(value) else { draft = ""; return }
        items.append(value)
        draft = ""
    }
}

private struct SentenceRow: View {
    let text: String
    let tone: Tone
    var onDelete: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(tone.color.opacity(0.5))
                .frame(width: 4, height: 4).padding(.top, 5.5)
            Text(text)
                .wardFont(11.5)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if hovering, let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .wardFont(10).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let value: String
    let label: String
    var icon: String
    var tone: Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).wardFont(9.5, weight: .semibold)
                Text(label.uppercased())
                    .wardFont(9, weight: .semibold, tracking: 0.5)
            }
            .foregroundStyle(tone == .neutral ? Color.secondary : tone.color)
            Text(value)
                .wardFont(17, weight: .semibold, design: .rounded)
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tone == .neutral ? Color.secondary.opacity(0.07) : tone.color.opacity(0.10))
        )
    }
}

// MARK: - The lean scale
//
// The threshold is an abstract number until you can see where a real title lands
// against it, so the tester's result is drawn on the same ruler.

struct LeanScale: View {
    let threshold: Double
    var lean: Double?
    var caption: String?

    private let lo = -0.25, hi = 0.25

    private func fraction(_ v: Double) -> Double {
        min(max((v - lo) / (hi - lo), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.green.opacity(0.55), .green.opacity(0.2),
                                     .orange.opacity(0.25), .red.opacity(0.6)],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(height: 7)

                    // Where blocking begins.
                    Rectangle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 1.6, height: 15)
                        .offset(x: w * fraction(threshold) - 0.8)

                    if let lean {
                        Circle()
                            .fill(lean > threshold ? Color.red : Color.green)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor),
                                                           lineWidth: 1.5))
                            .frame(width: 11, height: 11)
                            .offset(x: w * fraction(lean) - 5.5)
                            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    }
                }
                .frame(height: 16)
            }
            .frame(height: 16)

            HStack {
                Text("reads like study").wardFont(9).foregroundStyle(.green.opacity(0.9))
                Spacer()
                Text(caption ?? "settled before the model was reached")
                    .wardFont(9, monoDigits: true)
                    .foregroundStyle(caption == nil ? .tertiary : .secondary)
                Spacer()
                Text("reads like a distraction").wardFont(9).foregroundStyle(.red.opacity(0.85))
            }
        }
    }
}

// MARK: - Small helpers

struct EmptyHint: View {
    let icon: String, title: String, message: String
    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).wardFont(22).foregroundStyle(.tertiary)
            Text(title).wardFont(12, weight: .medium)
            Text(message).wardFont(11).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .wardFont(9.5, weight: .semibold, tracking: 0.7)
            .foregroundStyle(.tertiary)
    }
}
