import SwiftUI
import AppKit

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case overview, apps, sites, content, history, practice, session
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .apps:     return "Apps"
        case .sites:    return "Sites"
        case .content:  return "Content"
        case .history:  return "History"
        case .practice: return "Practice"
        case .session:  return "Session"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "shield.lefthalf.filled"
        case .apps:     return "square.grid.2x2"
        case .sites:    return "globe"
        case .content:  return "wand.and.stars"
        case .history:  return "chart.bar.doc.horizontal"
        case .practice: return "gamecontroller"
        case .session:  return "timer"
        }
    }
}

struct Dashboard: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var challenges = Challenges.shared
    @State private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 186, max: 220)
        } detail: {
            ScrollView {
                Group {
                    switch pane ?? .overview {
                    case .overview: OverviewPane()
                    case .apps:     AppsPane()
                    case .sites:    SitesPane()
                    case .content:  ContentPane()
                    case .history:  HistoryPane()
                    case .practice: PracticePane()
                    case .session:  SessionPane()
                    }
                }
                .padding(18)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 620)
        .onAppear { Permissions.mark("dashboard on screen") }
        .sheet(isPresented: Binding(
            get: { !store.rules.setupDone },
            set: { if !$0 { store.rules.setupDone = true } })) {
            Welcome()
        }
        .sheet(item: $challenges.pending) { ChallengeSheet(pending: $0) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(store.rules.isActive
                              ? LinearGradient(colors: [.orange, .orange.opacity(0.72)],
                                               startPoint: .top, endPoint: .bottom)
                              : LinearGradient(colors: [Color.secondary.opacity(0.4),
                                                        Color.secondary.opacity(0.3)],
                                               startPoint: .top, endPoint: .bottom))
                        .frame(width: 28, height: 28)
                    Image(systemName: store.rules.isLocked ? "lock.fill"
                          : store.rules.isPaused ? "pause.fill" : "shield.fill")
                        .wardFont(13, weight: .semibold)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ward").wardFont(13, weight: .semibold)
                    Text(!store.rules.enabled ? "off"
                         : store.rules.isPaused ? "paused"
                         : store.rules.isLocked ? "locked in" : "watching")
                        .wardFont(10).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 14).padding(.bottom, 10)

            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.title, systemImage: p.icon)
                        .wardFont(12)
                        .tag(p)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(store.rules.isActive ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(!store.rules.enabled ? "Off" : store.rules.isPaused ? "Paused" : "On")
                    .wardFont(11).foregroundStyle(.secondary)
                Spacer()
                // On-only: there is no off switch anywhere in Ward any more.
                if !store.rules.isActive {
                    Button("Turn on") { store.resume() }
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
        }
    }
}

// MARK: - Overview

struct OverviewPane: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var engine = Engine.shared

    private var blocking: Bool { engine.nowVerdict.hasPrefix("blocked") }

    private var heroIcon: String {
        if !store.rules.enabled { return "shield.slash" }
        if store.rules.isPaused { return "pause.circle.fill" }
        return store.rules.isLocked ? "lock.shield.fill" : "shield.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            hero

            staleGrantNotice

            HStack(spacing: 9) {
                StatTile(value: "\(store.blockedToday)", label: "stopped today",
                         icon: "hand.raised.fill",
                         tone: store.blockedToday > 0 ? .block : .neutral)
                StatTile(value: "\(store.rules.blockedApps.count)", label: "apps",
                         icon: "square.grid.2x2.fill")
                StatTile(value: "\(store.rules.blockedDomains.count)", label: "sites",
                         icon: "globe")
                StatTile(value: "\(store.rules.hardBlockPhrases.count + store.rules.denyPhrases.count)",
                         label: "phrases", icon: "text.magnifyingglass")
            }

            liveCard

            exceptionsCard

            HStack(alignment: .top, spacing: 14) {
                permissionsCard
                activityCard
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(store.rules.isActive ? Color.orange.opacity(0.13)
                                               : Color.secondary.opacity(0.10))
                    .frame(width: 54, height: 54)
                Image(systemName: heroIcon)
                    .wardFont(24, weight: .medium)
                    .foregroundStyle(store.rules.isActive ? Color.orange : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(headline).wardFont(19, weight: .semibold)
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    Text(subtitle).wardFont(12).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if store.rules.isPaused {
                Button("Resume now") { store.resume() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .controlSize(.large)
            }

            if store.rules.isActive {
                // Deliberately not a switch. Ward can be turned on and cannot be
                // turned off, and a control that looks like it flips both ways would
                // be an invitation to try.
                Label("On for good", systemImage: "lock.fill")
                    .wardFont(11, weight: .medium)
                    .foregroundStyle(.secondary)
                    .help("Ward has no off switch. Edit rules.json by hand to change that.")
            } else {
                Button("Turn Ward on") { store.resume() }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .controlSize(.large)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(store.rules.isActive ? Color.orange.opacity(0.06)
                                           : Color.secondary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(store.rules.isActive ? Color.orange.opacity(0.20)
                                                           : Color.primary.opacity(0.07),
                                      lineWidth: 0.8))
        )
    }

    private var headline: String {
        if !store.rules.enabled { return "Ward is off" }
        if store.rules.isPaused { return "Ward is paused" }
        return "Ward is on"
    }

    private var subtitle: String {
        if !store.rules.enabled {
            if store.rules.schedule.isUsable {
                return "Outside study hours \u{2014} \(store.rules.schedule.summary)."
            }
            return "Nothing is being checked right now."
        }
        if store.rules.isPaused {
            return "Back on in \(Store.describe(seconds: store.rules.pauseRemaining)) \u{2014} it resumes on its own."
        }
        if let until = store.rules.lockUntil, until > Date() {
            let mins = max(1, Int(until.timeIntervalSinceNow / 60))
            return "Locked in for another \(mins) minute\(mins == 1 ? "" : "s")."
        }
        if store.rules.schedule.isUsable {
            return "Study hours \u{2014} \(store.rules.schedule.summary)."
        }
        return "Watching the front window about every \(String(format: "%.1f", store.rules.pollInterval))s."
    }

    // MARK: Live + teaching

    private var liveCard: some View {
        Card(icon: "eye", title: "Right now") {
            if engine.nowWatching.isEmpty {
                HStack(spacing: 7) {
                    Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text("No browser in front \u{2014} nothing to judge.")
                        .wardFont(12).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text(engine.nowWatching)
                        .wardFont(13, weight: .medium)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: blocking ? "hand.raised.fill" : "checkmark")
                                .wardFont(8.5, weight: .bold)
                            Text(engine.nowVerdict).wardFont(10.5, weight: .medium)
                        }
                        .foregroundStyle(blocking ? Color.red : Color.green)
                        .padding(.horizontal, 7).padding(.vertical, 2.5)
                        .background(Capsule().fill((blocking ? Color.red : Color.green).opacity(0.13)))

                        if !engine.nowSource.isEmpty {
                            Text("read from \(engine.nowSource)")
                                .wardFont(10).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }

                    // Trusting a channel has to be one click from the thing you are
                    // looking at. Typed by hand into a list it would have to be
                    // spelled exactly, which nobody manages twice running.
                    if !engine.nowChannel.isEmpty {
                        let trusted = Rules.channelIsTrusted(engine.nowChannel,
                                                             in: store.rules.allowedChannels)
                        HStack(spacing: 6) {
                            Image(systemName: trusted ? "checkmark.seal.fill" : "person.crop.circle")
                                .wardFont(9.5)
                                .foregroundStyle(trusted ? AnyShapeStyle(Color.green)
                                                         : AnyShapeStyle(.tertiary))
                            Text(engine.nowChannel)
                                .wardFont(10.5).foregroundStyle(.secondary).lineLimit(1)
                            if trusted {
                                Text("trusted").wardFont(10).foregroundStyle(.green)
                            } else if !store.rules.isLocked {
                                Button("Always allow this channel") { engine.trustChannel() }
                                    .controlSize(.small)
                            }
                            Spacer()
                        }
                    }

                    Divider().opacity(0.4)
                    teaching
                }
            }
        }
    }

    /// Correcting a verdict belongs next to the verdict, not buried in settings.
    @ViewBuilder private var teaching: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("Got it wrong?")
                    .wardFont(11).foregroundStyle(.secondary)

                Button {
                    engine.teach(.shouldBlock)
                } label: {
                    Label("Should be blocked", systemImage: "hand.raised")
                        .wardFont(11)
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(blocking)

                Button {
                    engine.teach(.shouldAllow)
                } label: {
                    Label("Should be allowed", systemImage: "checkmark")
                        .wardFont(11)
                }
                .controlSize(.small)
                .disabled(!blocking || store.rules.isLocked)
                .help(store.rules.isLocked
                      ? "Rules can't be loosened during a commitment session"
                      : "Teach Ward that this was fine")

                Menu("Just this once\u{2026}") {
                    ForEach([5, 15, 30], id: \.self) { minutes in
                        Button("Let through for \(minutes) minutes") {
                            Challenges.shared.require(.exception) {
                                engine.allowForNow(minutes: minutes)
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 108)
                .controlSize(.small)
                .disabled(!blocking || store.rules.isLocked)
                .help("A one-off pass that expires by itself, without changing any rule")

                Spacer()
                if store.rules.correctionCount > 0 {
                    Text("\(store.rules.correctionCount) taught")
                        .wardFont(10).foregroundStyle(.tertiary)
                }
            }

            if let t = engine.lastTeach {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: t.ok ? "checkmark.circle.fill" : "info.circle.fill")
                            .wardFont(11)
                            .foregroundStyle(t.ok ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.headline).wardFont(11.5, weight: .semibold)
                            Text(t.detail).wardFont(10.5).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        if let undo = engine.undoDescription {
                            Button {
                                engine.undoLastTeach()
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                                    .wardFont(10.5)
                            }
                            .controlSize(.small)
                            .help("Take back the \(undo)")
                        }
                        Button {
                            engine.clearTeachResult()
                        } label: {
                            Image(systemName: "xmark").wardFont(8, weight: .bold)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    if !t.candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Never allow anything mentioning\u{2026}")
                                .wardFont(10).foregroundStyle(.tertiary)
                            Flow(spacing: 5, lineSpacing: 5) {
                                ForEach(t.candidates, id: \.self) { term in
                                    Button { engine.promote(term) } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "plus")
                                                .wardFont(7, weight: .bold)
                                            Text(term).wardFont(11)
                                        }
                                        .foregroundStyle(Color.red)
                                        .padding(.horizontal, 8).padding(.vertical, 3.5)
                                        .background(Capsule().fill(Color.red.opacity(0.13))
                                            .overlay(Capsule().strokeBorder(Color.red.opacity(0.3),
                                                                            lineWidth: 0.8)))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Block every title containing \u{201C}\(term)\u{201D}")
                                }
                            }
                        }
                    }

                    if let phrase = t.blockingPhrase {
                        Button {
                            store.rules.hardBlockPhrases.removeAll { $0 == phrase }
                            store.rules.denyPhrases.removeAll { $0 == phrase }
                            engine.clearTeachResult()
                        } label: {
                            Label("Remove the phrase \u{201C}\(phrase)\u{201D}", systemImage: "trash")
                                .wardFont(11)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04)))
            }
        }
    }

    /// The confusing case: System Settings lists Ward as allowed, but the system tells
    /// Ward otherwise. That happens because an ad-hoc signature's identity is a hash of
    /// the code, so the entry you approved belongs to the previous build.
    @ViewBuilder private var staleGrantNotice: some View {
        if !engine.accessibilityOK {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .wardFont(13).foregroundStyle(.orange)
                    Text("Ward can't read your windows yet")
                        .wardFont(13, weight: .semibold)
                    Spacer(minLength: 0)
                    Button("Open Accessibility settings") {
                        Permissions.openAccessibilitySettings()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent).tint(.orange)
                }
                Text("If System Settings already shows Ward switched on, that entry belongs to an older build of the app \u{2014} macOS identifies an ad-hoc signed app by a hash of its code, so rebuilding makes a new one. The switch looks right and does nothing.")
                    .wardFont(11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1.  Select Ward in the list and press \u{2212}")
                    Text("2.  Press + and choose /Applications/Ward.app")
                    Text("3.  This panel turns green on its own \u{2014} no restart needed")
                }
                .wardFont(11).foregroundStyle(.secondary)
                Text("Running ./setup-signing.sh once stops this happening on future rebuilds.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.30), lineWidth: 0.8)))
        }
    }

    // MARK: Exceptions

    @ViewBuilder private var exceptionsCard: some View {
        let live = store.rules.liveExceptions
        if !live.isEmpty {
            Card(icon: "clock.badge.checkmark", title: "Let through for now",
                 tone: .accent, count: live.count) {
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(live) { e in
                            HStack(spacing: 8) {
                                Image(systemName: e.isHost ? "globe" : "play.rectangle")
                                    .wardFont(10).foregroundStyle(.secondary)
                                Text(e.label).wardFont(11.5).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(Store.describe(seconds: e.remaining) + " left")
                                    .wardFont(10, monoDigits: true).foregroundStyle(.tertiary)
                                Button {
                                    store.revokeException(e.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .wardFont(10).foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("End this exception now")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        Card(icon: "checkmark.shield", title: "Permissions") {
            VStack(spacing: 0) {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Reads the title of the window you're looking at.",
                    ok: engine.accessibilityOK,
                    action: { Permissions.openAccessibilitySettings() })
                Divider().opacity(0.4)
                PermissionRow(
                    title: "Automation",
                    detail: engine.automationDetail,
                    ok: engine.automationOK,
                    action: { Permissions.openAutomationSettings() })
                Divider().opacity(0.4)
                PermissionRow(
                    title: "On-device model",
                    detail: engine.semanticAvailable
                        ? "Apple's sentence embeddings. Nothing leaves this Mac."
                        : "Unavailable \u{2014} phrase rules only.",
                    ok: engine.semanticAvailable,
                    action: nil)
            }
        }
    }

    // MARK: Activity

    private var activityCard: some View {
        Card(icon: "clock.arrow.circlepath", title: "Recently stopped",
             count: store.log.isEmpty ? nil : store.log.count) {
            if store.log.isEmpty {
                EmptyHint(icon: "checkmark.circle",
                          title: "Nothing stopped yet",
                          message: "Blocks show up here as they happen.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.log.prefix(7)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.at, format: .dateTime.hour().minute())
                                .wardFont(10, design: .monospaced)
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.what).wardFont(11.5).lineLimit(1)
                                Text(entry.reason).wardFont(10)
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        if entry.id != store.log.prefix(7).last?.id { Divider().opacity(0.3) }
                    }
                }
            }
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let ok: Bool
    let action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).wardFont(12, weight: .medium)
                Text(detail).wardFont(10.5).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if !ok, let action {
                Button("Grant", action: action)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .padding(.vertical, 6)
    }
}
