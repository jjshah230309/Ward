import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Apps

struct AppsPane: View {
    @ObservedObject private var store = Store.shared

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 200), spacing: 9)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            Card(icon: "bolt.horizontal", title: "When a blocked app opens",
                 subtitle: "Ward watches for launches and sweeps every few seconds, so a blocked app can't sit running in the background.") {
                Picker("", selection: $store.rules.appAction) {
                    ForEach(AppAction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(store.rules.isLocked)
            }

            Card(icon: "square.grid.2x2", title: "Blocked apps",
                 count: store.rules.blockedApps.isEmpty ? nil : store.rules.blockedApps.count) {
                let missing = store.rules.blockedApps.filter {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) == nil
                }
                if !missing.isEmpty {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .wardFont(11).foregroundStyle(.orange)
                        Text("\(missing.count) entr\(missing.count == 1 ? "y" : "ies") "
                             + "(\(missing.map(\.name).joined(separator: ", "))) "
                             + "point at something that isn't installed, so they can never fire.")
                            .wardFont(10.5).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Remove") {
                            let ids = Set(missing.map(\.bundleID))
                            store.rules.blockedApps.removeAll { ids.contains($0.bundleID) }
                        }
                        .controlSize(.small)
                        .disabled(store.rules.isLocked)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.10)))
                }

                if store.rules.blockedApps.isEmpty {
                    EmptyHint(icon: "square.grid.2x2",
                              title: "No apps blocked",
                              message: "Add the ones that pull you in \u{2014} games, chat, whatever it is.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                        ForEach(store.rules.blockedApps) { app in
                            AppTile(app: app, locked: store.rules.isLocked) {
                                store.rules.blockedApps.removeAll { $0.bundleID == app.bundleID }
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Menu {
                        let candidates = runningCandidates()
                        if candidates.isEmpty {
                            Text("Nothing else is running")
                        } else {
                            ForEach(candidates, id: \.bundleID) { c in
                                Button(c.name) { add(bundleID: c.bundleID, name: c.name) }
                            }
                        }
                    } label: {
                        Label("Add a running app", systemImage: "plus.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 170)
                    .disabled(store.rules.isLocked)

                    Button {
                        chooseFromDisk()
                    } label: {
                        Label("Browse Applications", systemImage: "folder")
                    }
                    .buttonStyle(.link)
                    .disabled(store.rules.isLocked)

                    Spacer()
                }
                .wardFont(11.5)
                .padding(.top, 2)
            }

            Card(icon: "lock.shield", title: "Always safe", tone: .allow) {
                Text("Finder, Dock, System Settings and Ward itself can never be blocked, however the rules are edited \u{2014} blocking them would lock you out of your own machine.")
                    .wardFont(11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runningCandidates() -> [(bundleID: String, name: String)] {
        let existing = Set(store.rules.blockedApps.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      id != Bundle.main.bundleIdentifier,
                      !Enforcer.protectedBundleIDs.contains(id),
                      !existing.contains(id) else { return nil }
                return (id, name)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { (bundleID: $0.0, name: $0.1) }
    }

    private func add(bundleID: String, name: String) {
        guard !Enforcer.protectedBundleIDs.contains(bundleID),
              !store.rules.blockedApps.contains(where: { $0.bundleID == bundleID }) else { return }
        store.rules.blockedApps.append(BlockedApp(bundleID: bundleID, name: name))
    }

    private func chooseFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Block"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            add(bundleID: id, name: name)
        }
    }
}

struct AppTile: View {
    let app: BlockedApp
    let locked: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    /// An entry whose bundle id doesn't resolve to anything installed can never match
    /// a running app. It looks blocked and isn't.
    private var missing: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) == nil
    }

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(bundleID: app.bundleID)
            Text(app.name)
                .wardFont(11.5, weight: .medium)
                .lineLimit(1)
                .foregroundStyle(missing ? Color.secondary : Color.primary)
            if missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .wardFont(9).foregroundStyle(.orange)
                    .help("Nothing installed has the id \(app.bundleID), so this entry can never match. The app may have been removed or changed its identifier.")
            }
            Spacer(minLength: 0)
            if hovering && !locked {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .wardFont(11).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop blocking \(app.name)")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(missing ? "\(app.bundleID) \u{2014} not installed, so this rule never fires"
                      : app.bundleID)
    }
}

struct AppIcon: View {
    let bundleID: String
    var body: some View {
        Group {
            if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path.path)).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Sites

struct SitesPane: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            Card(icon: "arrow.uturn.left", title: "When a blocked page is open",
                 subtitle: "Firefox can't be redirected \u{2014} it has no scripting support, so Ward hides its window instead.") {
                Picker("", selection: $store.rules.browserAction) {
                    ForEach(BrowserAction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(store.rules.isLocked)
            }

            ChipEditor(title: "Judged by content", icon: "wand.and.stars",
                       hint: "Not blocked outright. Every page on these sites is judged on what it actually is \u{2014} this is where the Content rules apply.",
                       tone: .accent, mono: true, placeholder: "youtube.com",
                       items: $store.rules.inspectDomains, locked: store.rules.isLocked)

            HStack(alignment: .top, spacing: 14) {
                ChipEditor(title: "Always allowed", icon: "checkmark.circle",
                           hint: "Checked first \u{2014} beats every other rule.",
                           tone: .allow, mono: true, placeholder: "wikipedia.org",
                           items: $store.rules.allowedDomains, locked: store.rules.isLocked)

                ChipEditor(title: "Always blocked", icon: "xmark.circle",
                           hint: "Whole sites. Subdomains included.",
                           tone: .hard, mono: true, placeholder: "reddit.com",
                           items: $store.rules.blockedDomains, locked: store.rules.isLocked)
            }

            ChipEditor(title: "Blocked URL patterns", icon: "chevron.left.forwardslash.chevron.right",
                       hint: "Regular expressions matched against the whole URL.",
                       tone: .hard, mono: true, placeholder: #"youtube\.com/shorts/"#,
                       items: $store.rules.blockedURLPatterns, locked: store.rules.isLocked,
                       problems: Rules.patternProblems(store.rules.blockedURLPatterns))
        }
    }
}

// MARK: - Content

struct ContentPane: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var engine = Engine.shared

    @State private var testTitle = "MrBeast: I Built a $100,000 Maze"
    @State private var result: Judge.Explained?
    @State private var health: Canary.Health?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            tester

            scopeNotice

            tidyNotice

            ChipEditor(title: "Never allowed", icon: "hand.raised.fill",
                       hint: "Beats every other content rule, including allow phrases. Game names and formats belong here \u{2014} \u{201C}minecraft\u{201D} is a far more specific signal than \u{201C}tutorial\u{201D}.",
                       tone: .hard, placeholder: "fortnite",
                       items: $store.rules.hardBlockPhrases, locked: store.rules.isLocked,
                       checkRedundancy: true)

            HStack(alignment: .top, spacing: 14) {
                ChipEditor(title: "Allow phrases", icon: "checkmark.circle",
                           hint: "Settles it alone. Against a block phrase, the model decides.",
                           tone: .allow, placeholder: "lecture",
                           items: $store.rules.allowPhrases, locked: store.rules.isLocked,
                       checkRedundancy: true)

                ChipEditor(title: "Block phrases", icon: "minus.circle",
                           hint: "Settles it alone. Against an allow phrase, the model decides.",
                           tone: .block, placeholder: "vlog",
                           items: $store.rules.denyPhrases, locked: store.rules.isLocked,
                       checkRedundancy: true)
            }

            ChipEditor(title: "Trusted channels", icon: "checkmark.seal",
                       hint: "Everything these publishers post is study. Settles it before phrases and the model \u{2014} the answer for a title that names a person and nothing else. Easiest added with the button on the Overview while you're watching them; the never-allowed list still wins.",
                       tone: .allow, placeholder: "3Blue1Brown",
                       items: $store.rules.allowedChannels, locked: store.rules.isLocked)

            Card(icon: "brain", title: "Meaning matching",
                 subtitle: "When phrases say nothing, or disagree, these examples decide. Add ones that sound like your subjects and your rabbit holes.") {
                Toggle("Judge titles by meaning, not just keywords", isOn: $store.rules.semanticEnabled)
                    .wardFont(12)
                    .disabled(!engine.semanticAvailable)
                Toggle("Read page tags and description, not just the title",
                       isOn: $store.rules.deepInspection)
                    .wardFont(12)
                if store.rules.deepInspection, !engine.deepRefused.isEmpty {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .wardFont(11).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Deep reading is switched on but being refused")
                                .wardFont(11.5, weight: .semibold)
                            ForEach(engine.deepRefused, id: \.self) { reason in
                                Text(reason).wardFont(10.5).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Ward is judging on the title alone until then.")
                                .wardFont(10.5).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12)))
                } else {
                    Text("Deep reading needs \u{201C}Allow JavaScript from Apple Events\u{201D} in your browser's Develop menu. Without it Ward just uses the title.")
                        .wardFont(10.5).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.rules.correctionCount > 0 {
                    Divider().opacity(0.4).padding(.vertical, 2)
                    LabeledSlider(label: "Lesson reach",
                                  value: $store.rules.learnedRadius, range: 0.25...0.7, step: 0.01,
                                  readout: String(format: "%.2f", store.rules.learnedRadius))
                    Text("How near a title must sit to something you taught before that lesson counts. Widen it and corrections spread further \u{2014} but a lesson about one video starts touching unrelated ones.")
                        .wardFont(10.5).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if store.rules.correctionCount > 0 {
                HStack(alignment: .top, spacing: 14) {
                    SentenceEditor(title: "Taught: distraction", icon: "graduationcap",
                                   hint: "Titles you said should have been blocked. These pull similar ones the same way.",
                                   tone: .hard,
                                   items: $store.rules.learnedDistraction,
                                   locked: store.rules.isLocked)
                    SentenceEditor(title: "Taught: study", icon: "graduationcap",
                                   hint: "Titles you said were fine. Remove one if you change your mind.",
                                   tone: .allow,
                                   items: $store.rules.learnedStudy,
                                   locked: store.rules.isLocked)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                SentenceEditor(title: "This is study", icon: "book",
                               hint: "What you're here for.", tone: .allow,
                               items: $store.rules.studyExamples, locked: store.rules.isLocked)
                SentenceEditor(title: "This is a distraction", icon: "hand.raised",
                               hint: "What pulls you away.", tone: .hard,
                               items: $store.rules.distractionExamples, locked: store.rules.isLocked)
            }
        }
        .onAppear { judge(); refresh() }
    }

    // MARK: The tester

    private var tester: some View {
        Card(icon: "text.viewfinder", title: "Try a title",
             subtitle: "Paste anything and watch where it lands. This runs the same pipeline the real thing uses.",
             tone: .accent) {

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .wardFont(11).foregroundStyle(.tertiary)
                TextField("Paste a video title\u{2026}", text: $testTitle)
                    .textFieldStyle(.plain)
                    .wardFont(13)
                    .onChange(of: testTitle) { _ in judge() }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8))
            )

            if let r = result {
                let blocked = r.verdict.call == .block
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: blocked ? "hand.raised.fill" : "checkmark.circle.fill")
                            .wardFont(10, weight: .semibold)
                        Text(blocked ? "Blocked" : "Allowed")
                            .wardFont(11.5, weight: .semibold)
                    }
                    .foregroundStyle(blocked ? Color.red : Color.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((blocked ? Color.red : Color.green).opacity(0.13)))

                    Text(r.verdict.detail.isEmpty ? r.verdict.reason
                                                  : "\(r.verdict.reason) \u{2014} \(r.verdict.detail)")
                        .wardFont(11).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

            }

            Divider().opacity(0.4).padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SectionLabel(text: "Threshold")
                    Spacer()
                    Text(String(format: "%+.3f", store.rules.semanticMargin))
                        .wardFont(10.5, weight: .medium, monoDigits: true)
                        .foregroundStyle(.secondary)
                }

                LeanScale(threshold: store.rules.semanticMargin,
                          lean: result?.score?.lean,
                          caption: result?.score.map { String(format: "lean %+.3f", $0.lean) })

                Slider(value: $store.rules.semanticMargin, in: -0.05...0.15)
                    .controlSize(.small)
                    .disabled(store.rules.isLocked)
                    .onChange(of: store.rules.semanticMargin) { _ in refresh() }

                Text("Lower blocks more. Clear study lands well left, clear distraction well right, and genuinely ambiguous titles cluster near the middle.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                healthNotice
            }
        }
    }

    /// Every rule on this pane only runs on the sites listed under Sites \u{2192} Judged by
    /// content. Off that list the whole layer is skipped, so a phrase that looks like a
    /// blanket ban is nothing of the sort. Say where these apply, and say it loudly when
    /// the list is empty and none of them can fire at all.
    @ViewBuilder private var scopeNotice: some View {
        let sites = store.rules.inspectDomains
        let ruleCount = store.rules.hardBlockPhrases.count + store.rules.denyPhrases.count
                      + store.rules.allowPhrases.count
        if sites.isEmpty {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .wardFont(11).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("None of these rules can fire").wardFont(11.5, weight: .semibold)
                    Text("No sites are judged by content, so all \(ruleCount) phrases and \(store.rules.studyExamples.count + store.rules.distractionExamples.count) examples here are inert. Add a site under Sites \u{2192} Judged by content.")
                        .wardFont(10.5).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.12)))
        } else {
            HStack(spacing: 6) {
                Image(systemName: "info.circle").wardFont(10).foregroundStyle(.tertiary)
                Text("These apply on \(sites.prefix(3).joined(separator: ", "))"
                     + (sites.count > 3 ? " and \(sites.count - 3) more" : "")
                     + " \u{2014} nowhere else. To stop a whole site, block it under Sites.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    /// Phrase lists grow as you teach, and a phrase an existing one already covers is
    /// dead weight that will never change an outcome. Point them out rather than
    /// letting the lists silently fill with rules that do nothing.
    @ViewBuilder private var tidyNotice: some View {
        let dead = deadPhrases()
        if !dead.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.rays").wardFont(11).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(dead.count) phrase\(dead.count == 1 ? "" : "s") can never fire")
                        .wardFont(11.5, weight: .semibold)
                    Text(dead.prefix(3).map { "\u{201C}\($0.phrase)\u{201D} is already caught by \u{201C}\($0.covered)\u{201D}" }
                            .joined(separator: ", ")
                         + (dead.count > 3 ? ", and \(dead.count - 3) more" : ""))
                        .wardFont(10.5).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Tidy up") { tidy(dead) }
                    .controlSize(.small)
                    .disabled(store.rules.isLocked)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08)))
        }
    }

    private func deadPhrases() -> [(phrase: String, covered: String, list: Int)] {
        let lists = [store.rules.hardBlockPhrases, store.rules.denyPhrases, store.rules.allowPhrases]
        var out: [(String, String, Int)] = []
        for (index, list) in lists.enumerated() {
            for phrase in list {
                if let cover = Rules.coveringPhrase(for: phrase, in: list) {
                    out.append((phrase, cover, index))
                }
            }
        }
        return out.map { (phrase: $0.0, covered: $0.1, list: $0.2) }
    }

    private func tidy(_ dead: [(phrase: String, covered: String, list: Int)]) {
        for item in dead {
            switch item.list {
            case 0: store.rules.hardBlockPhrases.removeAll { $0 == item.phrase }
            case 1: store.rules.denyPhrases.removeAll { $0 == item.phrase }
            default: store.rules.allowPhrases.removeAll { $0 == item.phrase }
            }
        }
    }

    /// Warns when the current threshold is quietly costing you real study material,
    /// or letting obvious distraction through, with the offending titles named.
    @ViewBuilder private var healthNotice: some View {
        if let h = health, !h.ok {
            let tooTight = !h.falseBlocks.isEmpty
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .wardFont(11).foregroundStyle(.orange)
                    Text(tooTight
                         ? "This threshold blocks \(h.falseBlocks.count) title\(h.falseBlocks.count == 1 ? "" : "s") that look like study"
                         : "This threshold lets \(h.misses.count) obvious distraction\(h.misses.count == 1 ? "" : "s") through")
                        .wardFont(11, weight: .semibold)
                    Spacer(minLength: 0)
                    if abs(store.rules.semanticMargin - 0.03) > 0.001 {
                        Button("Use default") {
                            store.rules.semanticMargin = 0.03
                            refresh()
                        }
                        .controlSize(.small)
                        .disabled(store.rules.isLocked)
                    }
                }
                ForEach(tooTight ? h.falseBlocks : h.misses, id: \.self) { title in
                    Text("\u{2022} " + title)
                        .wardFont(10.5).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.10)))
        }
    }

    private func judge() {
        result = testTitle.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : engine.preview(title: testTitle)
    }

    private func refresh() {
        health = Canary.check { engine.preview(title: $0).verdict.call }
    }
}

// MARK: - Session

struct SessionPane: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var engine = Engine.shared
    @State private var lockMinutes: Double = 50
    @State private var agentOn = Permissions.agentInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            lockCard

            Card(icon: "gearshape", title: "Everything else") {
                Text("How often Ward checks, the shield, the sound, start-at-login and the rules file all live in Settings.")
                    .wardFont(11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    AppDelegate.openSettings()
                } label: {
                    Label("Open Settings\u{2026}", systemImage: "gearshape")
                        .wardFont(12)
                }
            }
        }
    }

    private var lockCard: some View {
        Card(icon: store.rules.isLocked ? "lock.fill" : "lock.open",
             title: "Commitment session",
             tone: store.rules.isLocked ? .accent : .neutral) {
            if store.rules.isLocked {
                let until = store.rules.lockUntil ?? Date()
                let mins = max(1, Int(until.timeIntervalSinceNow / 60))
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(mins)")
                            .wardFont(32, weight: .semibold, design: .rounded)
                            .foregroundStyle(.orange)
                        Text("minutes left").wardFont(10).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Unlocks at \(until.formatted(date: .omitted, time: .shortened))")
                            .wardFont(12, weight: .medium)
                        Text("Rules can be tightened but not loosened, Ward won't quit, and the switch stays on. It lets go on its own.")
                            .wardFont(11).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Int(lockMinutes))")
                            .wardFont(32, weight: .semibold, design: .rounded)
                        Text("minutes").wardFont(10).foregroundStyle(.secondary)
                    }
                    .frame(width: 62, alignment: .leading)

                    VStack(alignment: .leading, spacing: 7) {
                        Slider(value: $lockMinutes, in: 10...480, step: 5).controlSize(.small)
                        HStack(spacing: 6) {
                            ForEach([25, 50, 90, 120], id: \.self) { m in
                                Button("\(m)m") { lockMinutes = Double(m) }
                                    .buttonStyle(.plain)
                                    .wardFont(10.5)
                                    .foregroundStyle(Int(lockMinutes) == m ? Color.orange : .secondary)
                                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                                    .background(Capsule().fill(Int(lockMinutes) == m
                                        ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.09)))
                            }
                            Spacer()
                        }
                    }
                }

                Button {
                    store.startSession(minutes: lockMinutes)
                } label: {
                    Label("Lock in for \(Int(lockMinutes)) minutes", systemImage: "lock")
                        .wardFont(12, weight: .medium)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)

                Text("Capped at 8 hours. If you ever need out early, the README has a one-line escape hatch \u{2014} it's friction, never a trap.")
                    .wardFont(10.5).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let readout: String
    var onChange: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 9) {
            Text(label).wardFont(12).frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .onChange(of: value) { _ in onChange?() }
            Text(readout)
                .wardFont(10.5, weight: .medium, monoDigits: true)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
