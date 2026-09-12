import Foundation
import AppKit
import SwiftUI

/// Everything that must never touch the main thread lives behind this class.
/// Reading a tab means an Apple Event round-trip into another app, which can stall;
/// a stalled browser must not become a stalled UI. All access is funnelled through
/// one serial queue, which is what makes the unchecked Sendable honest.
final class Sensor: @unchecked Sendable {

    struct Reading: Sendable {
        var context: PageContext
        var outcome: Judge.Explained
        var automationDenied: [String]
        var deepRefused: [String]
    }

    /// Only ever touched on `scriptQueue`.
    private let sense = BrowserSense()
    /// Pure computation, guarded by a lock rather than the script queue — judging a
    /// title takes a millisecond or two and must never queue behind an Apple Event
    /// that can stall for seconds.
    private let judge = Judge()
    private let judgeLock = NSLock()
    private let scriptQueue = DispatchQueue(label: "app.ward.applescript", qos: .userInitiated)

    private func decide(_ ctx: PageContext, _ rules: Rules) -> Judge.Explained {
        judgeLock.lock(); defer { judgeLock.unlock() }
        return judge.judge(ctx, rules: rules)
    }

    var semanticAvailable: Bool {
        judgeLock.lock(); defer { judgeLock.unlock() }
        return judge.semantic.isAvailable
    }

    /// Safe to call from the main thread: no Apple Events involved.
    func preview(_ ctx: PageContext, rules: Rules) -> Judge.Explained { decide(ctx, rules) }

    func inspect(pid: pid_t, info: BrowserInfo, rules: Rules,
                 then completion: @escaping @Sendable (Reading?) -> Void) {
        scriptQueue.async { [self] in
            guard let ctx = sense.read(pid: pid, info: info, deep: rules.deepInspection) else {
                completion(nil); return
            }
            completion(Reading(context: ctx,
                               outcome: decide(ctx, rules),
                               automationDenied: Array(sense.automationDenied),
                               deepRefused: Array(sense.deepRefused.values)))
        }
    }

    /// Acting on a tab means driving another application, which can hang for as long
    /// as the timeout allows. Always asynchronous, so a wedged browser can never
    /// wedge Ward's interface.
    func act(_ action: BrowserAction, info: BrowserInfo, target: String,
             then completion: @escaping @Sendable (Bool) -> Void) {
        scriptQueue.async { [self] in
            switch action {
            case .redirect: completion(sense.redirect(info, to: target))
            case .closeTab: completion(sense.closeTab(info))
            case .hide:     completion(false)
            }
        }
    }
}

/// The loop. Looks at what's in front of you, asks the Judge, and hands anything
/// that fails to the Enforcer.
@MainActor
final class Engine: ObservableObject {

    @Published private(set) var running = false
    @Published private(set) var nowWatching = ""
    @Published private(set) var nowVerdict = ""
    @Published private(set) var nowSource = ""
    /// Who published what's on screen, when the page says. Empty when deep reading
    /// is off or the page doesn't name one.
    @Published private(set) var nowChannel = ""
    @Published private(set) var automationDenied: [String] = []
    /// Polled, because macOS grants this in another application entirely and gives
    /// no notification when it changes.
    @Published private(set) var accessibilityOK = Permissions.accessibilityGranted
    /// Asked of the system directly. The old measure only went amber *after* Ward had
    /// tried a script and been refused, so a denied browser looked fine until the
    /// first block silently failed.
    @Published private(set) var automationOK = true
    @Published private(set) var automationDetail = "Reads exact URLs and redirects a tab."
    /// Why deep reading isn't working, when it isn't.
    @Published private(set) var deepRefused: [String] = []
    private var automationCountdown = 0
    /// The last page judged, kept so a correction has something to act on.
    @Published private(set) var lastContext: PageContext?
    @Published private(set) var lastVerdict: Verdict?
    @Published private(set) var lastTeach: TeachResult?
    /// What undoing would reverse, or nil when there's nothing to take back.
    @Published private(set) var undoDescription: String?
    private var undoAction: (@MainActor () -> Void)?

    private let sensor = Sensor()
    private let enforcer = Enforcer.shared

    private var timer: Timer?
    private var busy = false
    private var observers: [NSObjectProtocol] = []

    private(set) lazy var semanticAvailable: Bool = sensor.semanticAvailable

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        scheduleTimer()

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                        object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            Task { @MainActor in Engine.shared.checkApp(pid: pid) }
        })
    }

    func stop() {
        running = false
        // Whatever was on screen a moment ago is no longer this process's business,
        // and a menu still reporting it would be reporting a page nobody is judging.
        nowWatching = ""; nowVerdict = ""; nowSource = ""; nowChannel = ""
        timer?.invalidate(); timer = nil
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        observers.removeAll()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = max(0.4, Store.shared.rules.pollInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in Engine.shared.tick() }
        }
        timer?.tolerance = interval * 0.25
        // A scheduled timer doesn't fire until a whole interval has passed, so without
        // this Ward spends its first second and a half not actually watching anything.
        tick()
    }

    func pollIntervalChanged() { if running { scheduleTimer() } }

    // MARK: One pass

    private var firstTickDone = false

    private func tick() {
        if !firstTickDone { firstTickDone = true; Permissions.mark("first tick") }
        let trusted = Permissions.accessibilityGranted
        if trusted != accessibilityOK { accessibilityOK = trusted }

        // Cheap, but not once a second.
        if automationCountdown <= 0 {
            automationCountdown = Int(5 / max(0.4, Store.shared.rules.pollInterval))
            refreshAutomationStatus()
        } else {
            automationCountdown -= 1
        }

        announceTransitions()
        Store.shared.applyScheduleIfDue()
        Store.shared.pruneExceptions()
        let rules = Store.shared.rules
        guard rules.isActive, !busy else { return }

        sweepApps(rules: rules)

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let info = Browsers.info(for: bundleID) else { return }

        busy = true
        let pid = front.processIdentifier

        sensor.inspect(pid: pid, info: info, rules: rules) { reading in
            Task { @MainActor in
                Engine.shared.finish(reading, info: info, pid: pid, rules: rules)
            }
        }
    }

    private func finish(_ reading: Sensor.Reading?, info: BrowserInfo, pid: pid_t, rules: Rules) {
        busy = false
        guard let reading else {
            nowWatching = ""; nowVerdict = ""; nowChannel = ""
            lastContext = nil; lastVerdict = nil
            return
        }
        lastContext = reading.context
        lastVerdict = reading.outcome.verdict

        automationDenied = reading.automationDenied
        deepRefused = reading.deepRefused
        let ctx = reading.context
        nowWatching = ctx.label
        nowChannel = ctx.channel
        nowSource = ctx.source == .automation ? "url" : "window title"
        nowVerdict = (reading.outcome.verdict.call == .block ? "blocked \u{2014} " : "fine \u{2014} ")
                   + reading.outcome.verdict.reason

        guard reading.outcome.verdict.call == .block else { return }
        enforcer.enforce(page: ctx, info: info, verdict: reading.outcome.verdict,
                         sensor: sensor, rules: rules)
    }

    /// One quiet confirmation when Ward resumes by itself, so you are never left
    /// guessing whether it is still watching.
    private func announceTransitions() {
        let store = Store.shared
        if let done = store.expireLockIfDue(), case .sessionEnded(let blocks, let minutes) = done {
            enforcer.present(
                title: "Session finished",
                reason: blocks == 0
                    ? "\(minutes) minutes, nothing had to be stopped."
                    : "\(minutes) minutes, \(blocks) stopped along the way.",
                rules: store.rules, chrome: false)
        }
        if store.expirePauseIfDue(), store.rules.enabled {
            enforcer.present(title: "Ward is back on",
                             reason: "The pause has run out.",
                             rules: store.rules, chrome: false)
        }
    }

    /// Reports on the browsers actually running, since asking about an app that isn't
    /// open tells you nothing.
    ///
    /// The asking happens off the main thread. It reads as a cheap lookup, but it is
    /// an Apple Event round-trip that can block without ever returning — and the
    /// first tick runs during launch, so doing it here froze Ward with its window
    /// half-drawn. See `Permissions.automationStates`.
    private func refreshAutomationStatus() {
        let names: [String: String] = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        ).reduce(into: [:]) { found, id in
            guard let info = Browsers.known[id], info.kind != .firefox else { return }
            found[id] = info.name
        }
        guard !names.isEmpty else {
            applyAutomationStatus(denied: [], pending: [], unanswered: [])
            return
        }

        Permissions.automationStates(for: Array(names.keys)) { states in
            var denied: [String] = []
            var pending: [String] = []
            var unanswered: [String] = []
            for (id, name) in names {
                switch states[id] {
                case .denied:   denied.append(name)
                case .notAsked: pending.append(name)
                case nil:       unanswered.append(name)
                default:        break
                }
            }
            Task { @MainActor in
                Engine.shared.applyAutomationStatus(denied: denied.sorted(),
                                                    pending: pending.sorted(),
                                                    unanswered: unanswered.sorted())
            }
        }
    }

    private func applyAutomationStatus(denied: [String], pending: [String],
                                       unanswered: [String]) {
        automationDenied = denied
        if !denied.isEmpty {
            automationOK = false
            automationDetail = "Denied for " + denied.joined(separator: ", ")
                             + ". Ward can only hide those windows, not redirect them."
        } else if !pending.isEmpty {
            automationOK = true
            automationDetail = "Not asked yet for " + pending.joined(separator: ", ")
                             + " — Ward asks the first time it needs to."
        } else if !unanswered.isEmpty {
            // "All good" would be a guess. macOS was asked and said nothing, so the
            // honest answer is that this one is unknown.
            automationOK = true
            automationDetail = "Couldn't check " + unanswered.joined(separator: ", ")
                             + " — macOS didn't answer. Ward finds out for real the "
                             + "first time it needs to redirect a tab."
        } else {
            automationOK = true
            automationDetail = "Reads exact URLs and redirects a tab."
        }
    }

    // MARK: Apps

    private func sweepApps(rules: Rules) {
        guard !rules.blockedApps.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            check(app, rules: rules)
        }
    }

    func checkApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        check(app, rules: Store.shared.rules)
    }

    private func check(_ app: NSRunningApplication, rules: Rules) {
        guard rules.isActive,
              let bundleID = app.bundleIdentifier,
              !Enforcer.protectedBundleIDs.contains(bundleID),
              let rule = rules.blockedApps.first(where: { $0.bundleID == bundleID })
        else { return }
        enforcer.enforce(app: app, named: rule.name, action: rules.appAction, rules: rules)
    }

    // MARK: Learning from corrections

    enum Correction { case shouldBlock, shouldAllow }

    struct TeachResult {
        var ok: Bool
        var headline: String
        var detail: String
        var candidates: [String] = []
        var blockingPhrase: String?
    }

    /// Applies a correction to whatever is on screen, then re-judges immediately so
    /// the page you're looking at is dealt with rather than only the next one.
    @discardableResult
    func teach(_ correction: Correction) -> TeachResult {
        guard let ctx = lastContext, !Semantic.normalise(ctx.title).isEmpty else {
            let r = TeachResult(ok: false, headline: "Nothing to learn from",
                                detail: "Ward can't see a page title right now.")
            lastTeach = r; return r
        }

        if correction == .shouldAllow, Store.shared.rules.isLocked {
            let r = TeachResult(
                ok: false, headline: "Locked in",
                detail: "While a commitment session is running, rules can be tightened but not loosened. Teach it this once the session ends.")
            lastTeach = r; return r
        }

        let key = Semantic.normalise(ctx.title)
        var rules = Store.shared.rules
        let host = ctx.host
        // Phrase and model rules only run on the sites you've asked to be judged by
        // content. Anywhere else, a lesson about the page is stored and then never
        // consulted by anything — which is what made this button useless on an
        // ordinary site. So do the thing that actually applies to the page in front
        // of you, and say which it was.
        let byContent = host.map { rules.judgesContent(on: $0) } ?? false
        var siteAction: String?

        switch correction {
        case .shouldBlock:
            rules.learnedStudy.removeAll { $0 == key }
            if let host, !byContent {
                rules.allowedDomains.removeAll { Rules.hostMatches(host, any: [$0]) }
                if !rules.blockedDomains.contains(host) { rules.blockedDomains.append(host) }
                siteAction = host
            } else if !rules.learnedDistraction.contains(key) {
                rules.learnedDistraction.append(key)
            }
        case .shouldAllow:
            rules.learnedDistraction.removeAll { $0 == key }
            if let host, !byContent {
                rules.blockedDomains.removeAll { Rules.hostMatches(host, any: [$0]) }
                if !rules.allowedDomains.contains(host) { rules.allowedDomains.append(host) }
                siteAction = host
            } else if !rules.learnedStudy.contains(key) {
                rules.learnedStudy.append(key)
            }
        }
        Store.shared.rules = rules

        let after = sensor.preview(ctx, rules: rules)
        let wanted: Verdict.Call = correction == .shouldBlock ? .block : .allow
        let stuck = after.verdict.call != wanted

        var result: TeachResult
        if correction == .shouldBlock {
            if let site = siteAction {
                result = TeachResult(
                    ok: !stuck,
                    headline: "Blocked \(site)",
                    detail: "This site isn't one Ward judges page by page, so the whole site is blocked now. It's in Sites \u{2192} Always blocked.")
            } else {
                result = TeachResult(
                    ok: !stuck,
                    headline: stuck ? "Learned, but not enough on its own" : "Learned \u{2014} blocked",
                    detail: stuck
                        ? "Similar titles will lean further toward distraction, but this one still reads as study. Add one of these as a never-allowed phrase to settle it outright."
                        : "This is blocked now, and titles like it will be too.",
                    candidates: stuck ? Teacher.candidates(from: ctx.title, rules: rules) : [])
            }
            if !stuck, let info = Browsers.info(for: ctx.browserBundleID) {
                enforcer.forget(ctx.signature)
                enforcer.enforce(page: ctx, info: info, verdict: after.verdict,
                                 sensor: sensor, rules: rules)
            }
        } else {
            if let site = siteAction {
                result = TeachResult(
                    ok: !stuck,
                    headline: "Allowed \(site)",
                    detail: "Added to Sites \u{2192} Always allowed, which beats every other rule.")
            } else {
                let phrase = stuck ? lastVerdict?.phrase : nil
                result = TeachResult(
                    ok: !stuck,
                    headline: stuck ? "Learned, but a phrase still blocks it" : "Learned \u{2014} allowed",
                    detail: stuck
                        ? "A phrase rule settles this before the model is reached. Remove it to let this through."
                        : "This is allowed now, and titles like it will be too.",
                    blockingPhrase: phrase)
            }
        }

        nowVerdict = (after.verdict.call == .block ? "blocked \u{2014} " : "fine \u{2014} ")
                   + after.verdict.reason
        lastVerdict = after.verdict

        setUndo(siteAction.map { "\($0) in your site list" }
                ?? (correction == .shouldBlock ? "lesson: should be blocked"
                                               : "lesson: should be allowed")) {
            var back = Store.shared.rules
            switch correction {
            case .shouldBlock:
                if let site = siteAction { back.blockedDomains.removeAll { $0 == site } }
                else { back.learnedDistraction.removeAll { $0 == key } }
            case .shouldAllow:
                if let site = siteAction { back.allowedDomains.removeAll { $0 == site } }
                else { back.learnedStudy.removeAll { $0 == key } }
            }
            Store.shared.rules = back
        }

        Store.shared.note(LogEntry(blocked: correction == .shouldBlock, what: ctx.label,
                                   reason: result.headline))
        lastTeach = result
        return result
    }

    /// Vouches for whoever published the page on screen, then re-judges it, so the
    /// thing you were looking at is dealt with rather than only the next one.
    func trustChannel() {
        let channel = nowChannel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channel.isEmpty,
              !Rules.channelIsTrusted(channel, in: Store.shared.rules.allowedChannels) else { return }
        Store.shared.rules.allowedChannels.append(channel)
        setUndo("trusted \u{201C}\(channel)\u{201D}") {
            Store.shared.rules.allowedChannels.removeAll { $0 == channel }
        }

        guard let ctx = lastContext else { return }
        let after = sensor.preview(ctx, rules: Store.shared.rules)
        lastVerdict = after.verdict
        nowVerdict = (after.verdict.call == .block ? "blocked \u{2014} " : "fine \u{2014} ")
                   + after.verdict.reason
        if after.verdict.call == .allow { enforcer.forget(ctx.signature) }
    }

    /// Promotes one suggested term to the never-allowed list and re-checks the page.
    func promote(_ phrase: String) {
        let value = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty, !Store.shared.rules.hardBlockPhrases.contains(value) else { return }
        Store.shared.rules.hardBlockPhrases.append(value)
        setUndo("phrase \u{201C}\(value)\u{201D}") {
            Store.shared.rules.hardBlockPhrases.removeAll { $0 == value }
        }

        guard let ctx = lastContext,
              let info = Browsers.info(for: ctx.browserBundleID) else { return }
        let after = sensor.preview(ctx, rules: Store.shared.rules)
        guard after.verdict.call == .block else { return }
        enforcer.forget(ctx.signature)
        enforcer.enforce(page: ctx, info: info, verdict: after.verdict,
                         sensor: sensor, rules: Store.shared.rules)
    }

    func clearTeachResult() { lastTeach = nil }

    /// Lets the page currently on screen through for a while, then forgets about it.
    func allowForNow(minutes: Int) {
        guard let ctx = lastContext, let verdict = lastVerdict else { return }
        Store.shared.allowTemporarily(ctx, verdict: verdict, minutes: minutes)
        enforcer.forget(ctx.signature)
        let after = sensor.preview(ctx, rules: Store.shared.rules)
        nowVerdict = (after.verdict.call == .block ? "blocked \u{2014} " : "fine \u{2014} ")
                   + after.verdict.reason
        lastVerdict = after.verdict
        setUndo("exception") {
            if let last = Store.shared.rules.exceptions.last {
                Store.shared.revokeException(last.id)
            }
        }
    }

    private func setUndo(_ description: String, _ action: @escaping @MainActor () -> Void) {
        undoDescription = description
        undoAction = action
    }

    /// Teaching is one click, so taking it back should be too — otherwise a misclick
    /// means hunting through the Content pane for the lesson you just added.
    func undoLastTeach() {
        undoAction?()
        undoAction = nil
        undoDescription = nil
        lastTeach = nil
    }

    /// Used only by `--render` so the teaching controls appear in a screenshot.
    func seedForPreview(title: String) {
        var ctx = PageContext()
        ctx.rawURL = "https://www.youtube.com/watch?v=preview"
        ctx.title = title
        ctx.browserName = "Safari"
        ctx.source = .automation
        lastContext = ctx
        let outcome = sensor.preview(ctx, rules: Store.shared.rules)
        lastVerdict = outcome.verdict
        nowWatching = title
        nowSource = "url"
        nowVerdict = (outcome.verdict.call == .block ? "blocked \u{2014} " : "fine \u{2014} ")
                   + outcome.verdict.reason
    }

    // MARK: Tuning aid

    /// Runs a made-up title through the same pipeline the real thing uses, so the
    /// rules can be tuned without hunting for a video that trips them.
    func preview(title: String, urlString: String = "https://www.youtube.com/watch?v=preview")
    -> Judge.Explained {
        var ctx = PageContext()
        ctx.rawURL = urlString
        ctx.title = title
        ctx.browserName = "Preview"
        return sensor.preview(ctx, rules: Store.shared.rules)
    }
}
