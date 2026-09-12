import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Cmd-comma window: how Ward behaves and how it looks, kept apart from the
/// rulebook so the main window stays about what gets blocked.
struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            BehaviourSettings()
                .tabItem { Label("Behaviour", systemImage: "slider.horizontal.3") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520)
        .padding(18)
    }
}

struct GeneralSettings: View {
    @ObservedObject private var store = Store.shared
    @Environment(\.uiScale) private var scale

    @State private var restored = false

    private var whereItLives: String {
        switch (store.rules.showInDock, store.rules.showInMenuBar) {
        case (true, true):
            return "A normal app: Dock icon, Cmd-Tab, menu bar icon."
        case (true, false):
            return "Dock icon and Cmd-Tab, no menu bar icon."
        case (false, true):
            return "Menu bar only \u{2014} no Dock icon and nothing in Cmd-Tab."
        case (false, false):
            return "Completely unseen: no Dock icon, no Cmd-Tab, no menu bar icon. It keeps watching. Press \u{2303}\u{2325}\u{2318}W to bring this window back \u{2014} with nothing to click, that shortcut is the only way in, so leave shortcuts enabled."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(icon: "textformat.size", title: "Appearance",
                 subtitle: "Zoom changes the type size and re-lays the window out, so text stays sharp at any setting.") {
                HStack(spacing: 10) {
                    Button { store.zoom(-1) } label: {
                        Image(systemName: "minus").frame(width: 20)
                    }
                    .disabled(!store.canZoomOut)
                    .help("Zoom out (\u{2318}\u{2212})")

                    Text("\(Int(store.rules.uiScale * 100))%")
                        .wardFont(13, weight: .medium, monoDigits: true)
                        .frame(width: 58 * scale)

                    Button { store.zoom(1) } label: {
                        Image(systemName: "plus").frame(width: 20)
                    }
                    .disabled(!store.canZoomIn)
                    .help("Zoom in (\u{2318}+)")

                    Button("Actual size") { store.resetZoom() }
                        .disabled(abs(store.rules.uiScale - 1) < 0.001)

                    Spacer()
                }
                .controlSize(.large)

                Text("Sample text at this size \u{2014} the quick brown fox.")
                    .wardFont(12).foregroundStyle(.secondary)
            }

            Card(icon: "command", title: "System-wide shortcuts",
                 subtitle: "Correct a verdict without leaving what you're watching. Ward registers only these three combinations \u{2014} it does not watch your typing.") {
                Toggle("Enable shortcuts", isOn: $store.rules.hotkeysEnabled).wardFont(12)
                    .onChange(of: store.rules.hotkeysEnabled) { _ in restored = store.ensureAWayIn() }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(HotKeys.Action.allCases, id: \.rawValue) { action in
                        HStack {
                            Text(action.label).wardFont(11.5)
                                .foregroundStyle(store.rules.hotkeysEnabled ? .primary : .secondary)
                            Spacer()
                            Text(action.display)
                                .wardFont(11, weight: .medium, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
                .opacity(store.rules.hotkeysEnabled ? 1 : 0.5)
            }

            Card(icon: "dock.rectangle", title: "Where Ward lives",
                 subtitle: "Closing the window never quits Ward \u{2014} it carries on watching in the background either way.") {
                Toggle("Show in the Dock and in Cmd-Tab", isOn: $store.rules.showInDock)
                    .wardFont(12)
                    .onChange(of: store.rules.showInDock) { _ in restored = store.ensureAWayIn() }
                Toggle("Show an icon in the menu bar", isOn: $store.rules.showInMenuBar)
                    .wardFont(12)
                    .onChange(of: store.rules.showInMenuBar) { _ in restored = store.ensureAWayIn() }

                if restored {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "info.circle.fill").wardFont(11).foregroundStyle(.orange)
                        Text("The menu bar icon is back on. Turning off the Dock icon, the menu bar icon and the shortcuts together would leave no way to open this window \u{2014} reopening a running app only activates it.")
                            .wardFont(10.5).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.10)))
                }

                Text(whereItLives)
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }
}

struct BehaviourSettings: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChallengeCard()

            ScheduleCard()

            Card(icon: "timer", title: "Checking") {
                LabeledSlider(label: "Check every",
                              value: $store.rules.pollInterval, range: 0.5...5, step: 0.25,
                              readout: String(format: "%.2fs", store.rules.pollInterval)) {
                    engine.pollIntervalChanged()
                }
                Text("How often Ward looks at the front window. Faster catches things sooner and costs a little more battery.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(icon: "bell", title: "When something is blocked") {
                LabeledSlider(label: "Shield for",
                              value: $store.rules.shieldSeconds, range: 0...10, step: 0.5,
                              readout: store.rules.shieldSeconds == 0
                                  ? "off" : String(format: "%.1fs", store.rules.shieldSeconds))
                Toggle("Play a sound", isOn: $store.rules.playSound).wardFont(12)
            }

            Spacer(minLength: 0)
        }
    }
}

/// The friction between an impulse and switching Ward off.
struct ChallengeCard: View {
    @ObservedObject private var store = Store.shared
    @Environment(\.uiScale) private var scale

    private var settings: Binding<ChallengeSettings> { $store.rules.challenge }

    /// What this point on the dial actually asks of you.
    private var demand: String {
        let spec = PuzzleSpec.forIQ(store.rules.challenge.iq)
        switch store.rules.challenge.kind {
        case .typing:
            return "\(spec.typingWords) words, a comma every \(spec.typingCommaEvery)"
        case .arithmetic:
            return "\(spec.arithmeticSteps) steps, numbers to \(spec.arithmeticMax)"
                 + (spec.arithmeticSquares ? ", with squares" : "")
        case .memory:
            return "\(spec.memoryLength) tiles at \(String(format: "%.2f", Double(spec.memoryFlashMs) / 1000))s each"
        case .blockSort:
            return "\(spec.sortColours) colours across \(spec.sortColours + 2) tubes"
        case .lightsOut:
            let cells = spec.lightsGrid * spec.lightsGrid
            return "\(spec.lightsGrid)\u{00D7}\(spec.lightsGrid) board, scrambled \(min(spec.lightsTaps, cells - 1)) deep"
        case .wait:
            return spec.waitSeconds < 60
                ? "\(spec.waitSeconds) seconds"
                : "\(spec.waitSeconds / 60)m \(spec.waitSeconds % 60)s"
        case .mixed:
            return "\(spec.typingWords) words · \(spec.arithmeticSteps) steps · \(spec.memoryLength) tiles"
        }
    }
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 7)]

    var body: some View {
        Card(icon: "lock.shield", title: "Getting past Ward",
             subtitle: "Switching a blocker off takes a second, which is exactly the problem. Put something in the way that a moment of weakness won't get through.") {

            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(ChallengeKind.allCases) { kind in
                    let on = store.rules.challenge.kind == kind
                    Button { settings.wrappedValue.kind = kind } label: {
                        VStack(spacing: 4) {
                            Image(systemName: kind.icon).wardFont(15)
                            Text(kind.label).wardFont(10.5).multilineTextAlignment(.center)
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
            .disabled(store.rules.isLocked)

            Text(store.rules.challenge.kind.blurb)
                .wardFont(11).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.4)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("IQ").wardFont(10, weight: .semibold, tracking: 0.8)
                    .foregroundStyle(.tertiary)
                Text("\(store.rules.challenge.iq)")
                    .wardFont(30, weight: .semibold, design: .rounded, monoDigits: true)
                    .foregroundStyle(.orange)
                    .frame(width: 58 * scale, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Slider(value: Binding(
                        get: { Double(store.rules.challenge.iq) },
                        set: { settings.wrappedValue.iq = IQ.clamp(Int($0.rounded())) }),
                        in: Double(IQ.range.lowerBound)...Double(IQ.range.upperBound))
                        .controlSize(.small)
                    HStack {
                        Text("\(IQ.range.lowerBound)").wardFont(9.5).foregroundStyle(.tertiary)
                        Spacer()
                        Text("\(IQ.range.upperBound)").wardFont(9.5).foregroundStyle(.tertiary)
                    }
                }
            }
            .disabled(store.rules.isLocked)

            Text(IQ.effort(store.rules.challenge.iq))
                .wardFont(11).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "ruler").wardFont(9.5).foregroundStyle(.tertiary)
                Text(demand).wardFont(10.5, monoDigits: true).foregroundStyle(.secondary)
                Spacer()
            }

            Text("A dial, not a measurement \u{2014} it decides how much work stands between you and switching Ward off, nothing more. Every point on it asks a different batch of questions, and none is ever repeated.")
                .wardFont(10.5).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 3) {
                Text("Ask me when I try to\u{2026}").wardFont(11).foregroundStyle(.secondary)
                Toggle("Let a blocked page through", isOn: settings.onException).wardFont(12)
                Text("Turning Ward off and pausing it aren't listed because they no "
                     + "longer exist \u{2014} there is nothing left to guard.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(store.rules.isLocked)

            HStack {
                Text("Cancelling a challenge always leaves the rules alone, so the safe way out is the easy one.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Try it") {
                    // A dry run: nothing changes whether you finish it or not.
                    Challenges.shared.preview()
                }
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Text("\(PuzzleLedger.shared.count) questions asked so far, none of them twice.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                Spacer()
                Button("Forget them") { PuzzleLedger.shared.reset() }
                    .controlSize(.small)
                    .disabled(store.rules.isLocked)
            }
        }
    }
}

/// Study hours. Ward turns itself on for the window and off outside it, so it is not
/// something you have to remember.
struct ScheduleCard: View {
    @ObservedObject private var store = Store.shared
    private let names = ["", "S", "M", "T", "W", "T", "F", "S"]

    private var startBinding: Binding<Date> {
        Binding(get: { Self.date(store.rules.schedule.start) },
                set: { store.rules.schedule.start = Self.minutes($0) })
    }
    private var endBinding: Binding<Date> {
        Binding(get: { Self.date(store.rules.schedule.end) },
                set: { store.rules.schedule.end = Self.minutes($0) })
    }

    var body: some View {
        Card(icon: "calendar", title: "Study hours",
             subtitle: store.rules.schedule.enabled
                 ? "Ward switches itself on for \(store.rules.schedule.summary). You can still override it by hand; the schedule only takes over at the next boundary."
                 : "Have Ward turn itself on at set times.") {
            Toggle("Follow a schedule", isOn: $store.rules.schedule.enabled)
                .wardFont(12)
                .disabled(store.rules.isLocked)

            if store.rules.schedule.enabled {
                HStack(spacing: 5) {
                    ForEach(1...7, id: \.self) { day in
                        let on = store.rules.schedule.days.contains(day)
                        Button {
                            if on { store.rules.schedule.days.remove(day) }
                            else { store.rules.schedule.days.insert(day) }
                        } label: {
                            Text(names[day])
                                .wardFont(11, weight: .medium)
                                .frame(width: 24, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(on ? Color.orange.opacity(0.85)
                                             : Color.primary.opacity(0.06)))
                                .foregroundStyle(on ? Color.white : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .disabled(store.rules.isLocked)

                HStack(spacing: 10) {
                    DatePicker("From", selection: startBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Text("to").wardFont(11).foregroundStyle(.secondary)
                    DatePicker("To", selection: endBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(store.rules.schedule.covers(Date()) ? "in hours now" : "outside hours")
                            .wardFont(10.5)
                            .foregroundStyle(store.rules.schedule.covers(Date())
                                             ? Color.green : Color.secondary)
                    }
                }
                .disabled(store.rules.isLocked)

                if store.rules.schedule.enabled && !store.rules.schedule.isUsable {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .wardFont(11).foregroundStyle(.orange)
                        Text(store.rules.schedule.days.isEmpty
                             ? "No days are selected, so this schedule describes no time at all. It is being ignored rather than leaving Ward switched off."
                             : "The start and end are the same, so this window is empty. It is being ignored.")
                            .wardFont(10.5).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.10)))
                }

                if store.rules.schedule.end < store.rules.schedule.start {
                    Text("This window runs past midnight. The hours after midnight count as part of the day it started on.")
                        .wardFont(10.5).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: (minutes / 60) % 24,
                              minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
    private static func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

struct AdvancedSettings: View {
    @ObservedObject private var store = Store.shared
    @State private var agentOn = Permissions.agentInstalled
    @State private var backupNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(icon: "power", title: "Always on") {
                // Install-only, for the same reason there is no off switch: turning
                // this off boots the background agent out and deletes its job, which
                // stops Ward completely and is the tidiest off switch in the app.
                if agentOn {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.seal.fill")
                            .wardFont(11).foregroundStyle(.green)
                        Text("Starts at login, and restarts if it's ever killed.")
                            .wardFont(12)
                        Spacer(minLength: 0)
                    }
                } else {
                    Button("Keep Ward running in the background") {
                        Permissions.installAgent()
                        agentOn = Permissions.agentInstalled
                    }
                    .controlSize(.small)
                }
                Text("Runs a launchd agent from ~/Library/LaunchAgents/\(Permissions.agentLabel).plist. "
                     + "Removing it is a deliberate job for Terminal, not a switch in here.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(icon: "arrow.up.arrow.down.square", title: "Backup",
                 subtitle: "Everything you've tuned lives in one file. Merging only ever adds rules, so importing can't quietly unblock something.") {
                HStack(spacing: 8) {
                    Button("Export\u{2026}") { exportRules() }
                    Button("Import\u{2026}") { importRules() }
                        .disabled(store.rules.isLocked)
                    Spacer()
                    if let note = backupNote {
                        Text(note).wardFont(10.5).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .controlSize(.small)
            }

            Card(icon: "doc.text", title: "Rules file",
                 subtitle: "Plain JSON, hand-editable. A missing or misspelled key falls back to its default rather than discarding the file.") {
                HStack(spacing: 8) {
                    Text(Store.configURL.path)
                        .wardFont(10, design: .monospaced).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([Store.configURL])
                    }
                    Button("Reload") { store.reloadFromDisk() }
                        .disabled(store.rules.isLocked)
                    Button("Reset") { store.rules = .default }
                        .disabled(store.rules.isLocked)
                }
                .controlSize(.small)
            }

            Spacer(minLength: 0)
        }
        .onAppear { agentOn = Permissions.agentInstalled }
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ward-rules.json"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupNote = store.exportRules(to: url) ? "Exported" : "Could not write that file"
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let (incoming, summary) = Store.preview(url) else {
            backupNote = "That file isn't a Ward rulebook"
            return
        }

        let alert = NSAlert()
        alert.messageText = "Import these rules?"
        alert.informativeText = """
            \(url.lastPathComponent) contains \(summary.describe).

            Merge adds anything you don't already have and changes nothing else.             Replace swaps your whole rulebook for this one.
            """
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.importRules(incoming, mode: .merge)
            backupNote = "Merged"
        case .alertSecondButtonReturn:
            store.importRules(incoming, mode: .replace)
            backupNote = "Replaced"
        default:
            backupNote = nil
        }
    }
}
