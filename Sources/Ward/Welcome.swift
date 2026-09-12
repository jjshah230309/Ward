import SwiftUI
import AppKit

/// What a fresh copy shows once. Ward is useless without Accessibility and much
/// weaker without Automation, and neither is obvious from a menu bar icon, so the
/// first thing it does is ask for them and show whether they took.
struct Welcome: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var engine = Engine.shared
    @Environment(\.uiScale) private var scale

    @State private var picked: Set<String> = []
    /// Permission status is polled because macOS grants it in another app entirely.
    @State private var tick = 0

    private var running: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      id != Bundle.main.bundleIdentifier,
                      !Enforcer.protectedBundleIDs.contains(id) else { return nil }
                return (id, name)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { (bundleID: $0.0, name: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.orange, .orange.opacity(0.7)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 48 * scale, height: 48 * scale)
                    Image(systemName: "shield.fill")
                        .wardFont(22, weight: .semibold).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ward keeps you on task").wardFont(20, weight: .semibold)
                    Text("It watches the window in front of you and steps in when it isn't study \u{2014} not just which site, but which video.")
                        .wardFont(12).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card(icon: "lock.open", title: "Two permissions",
                 subtitle: "macOS grants these in System Settings. Ward can't ask for them directly \u{2014} the buttons open the right panel.") {
                let _ = tick   // re-read the live status on every poll
                VStack(spacing: 0) {
                    PermissionRow(
                        title: "Accessibility \u{2014} required",
                        detail: "Reads the title of the window you're looking at. Nothing works without it.",
                        ok: engine.accessibilityOK,
                        action: { Permissions.openAccessibilitySettings() })
                    Divider().opacity(0.4)
                    PermissionRow(
                        title: "Automation \u{2014} recommended",
                        detail: "Reads the exact address and can send a tab elsewhere. Without it Ward hides the window instead.",
                        ok: engine.automationOK,
                        action: { Permissions.openAutomationSettings() })
                }
            }

            Card(icon: "square.grid.2x2", title: "Anything you'd rather not open?",
                 subtitle: "Pick a few now, or skip this and add them later.",
                 count: picked.isEmpty ? nil : picked.count) {
                if running.isEmpty {
                    Text("Nothing else is running at the moment.")
                        .wardFont(11).foregroundStyle(.tertiary)
                } else {
                    ScrollView {
                        Flow(spacing: 5, lineSpacing: 5) {
                            ForEach(running, id: \.bundleID) { app in
                                let on = picked.contains(app.bundleID)
                                Button {
                                    if on { picked.remove(app.bundleID) }
                                    else { picked.insert(app.bundleID) }
                                } label: {
                                    HStack(spacing: 5) {
                                        AppIcon(bundleID: app.bundleID)
                                        Text(app.name).wardFont(11)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule()
                                        .fill(on ? Color.red.opacity(0.16) : Color.primary.opacity(0.05))
                                        .overlay(Capsule().strokeBorder(
                                            on ? Color.red.opacity(0.4) : Color.primary.opacity(0.08),
                                            lineWidth: 0.8)))
                                    .foregroundStyle(on ? Color.red : Color.primary.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 120 * scale)
                }
            }

            HStack {
                Text("You can change all of this later, and the rules file is plain JSON.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                Spacer()
                Button("Start") { finish() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560 * scale)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            tick &+= 1
        }
    }

    private func finish() {
        for id in picked {
            guard let name = running.first(where: { $0.bundleID == id })?.name else { continue }
            if !store.rules.blockedApps.contains(where: { $0.bundleID == id }) {
                store.rules.blockedApps.append(BlockedApp(bundleID: id, name: name))
            }
        }
        store.rules.setupDone = true
    }
}
