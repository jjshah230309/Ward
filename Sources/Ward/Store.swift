import Foundation
import SwiftUI

/// Everything persistent lives here. One JSON file, hand-editable.
@MainActor
final class Store: ObservableObject {

    static let shared = Store()

    @Published var rules: Rules { didSet { scheduleSave() } }
    @Published private(set) var log: [LogEntry] = []
    @Published var blockedThisSession: Int = 0
    /// Blocks since midnight, read back from the record so a restart doesn't reset it.
    @Published private(set) var blockedToday: Int = 0

    private var saveWork: DispatchWorkItem?
    /// `--render` exists to photograph the interface, which sometimes means posing it
    /// with settings you don't want kept. Nothing it does reaches disk.
    nonisolated static let readOnly = CommandLine.arguments.contains("--render")
    private var blockPageDomains: [String] = []

    nonisolated static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Ward", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    nonisolated static var configURL: URL { supportDir.appendingPathComponent("rules.json") }
    nonisolated static var blockPageURL: URL { supportDir.appendingPathComponent("blocked.html") }

    private init() {
        if let data = try? Data(contentsOf: Store.configURL),
           var decoded = try? JSONDecoder.ward.decode(Rules.self, from: data) {
            _ = decoded.migrateIfNeeded()
            // A rulebook already on disk means this isn't a first run, whatever the
            // file says — the welcome is for fresh copies, not for people mid-setup.
            decoded.setupDone = true
            rules = decoded
        } else {
            rules = .default
        }
        blockPageDomains = rules.allowedDomains
        writeBlockPage()
        History.trim()
        let since = Calendar.current.startOfDay(for: Date())
        blockedToday = History.load(limit: 4000).filter { $0.blocked && $0.at >= since }.count
        save()
    }

    // MARK: Saving

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func save() {
        guard !Store.readOnly else { return }
        guard let data = try? JSONEncoder.ward.encode(rules) else { return }
        try? data.write(to: Store.configURL, options: .atomic)
        if rules.allowedDomains != blockPageDomains {
            blockPageDomains = rules.allowedDomains
            writeBlockPage()
        }
    }

    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: Store.configURL),
              var decoded = try? JSONDecoder.ward.decode(Rules.self, from: data) else { return }
        _ = decoded.migrateIfNeeded()
        // Reloading is for picking up hand edits, not for ending a session early.
        // Editing lockUntil out of the file and pressing Reload used to do exactly that.
        if rules.isLocked {
            decoded.lockUntil = rules.lockUntil
            decoded.enabled = true
        }
        rules = decoded
    }

    // MARK: Session transitions
    //
    // Ward changes state on its own — a pause runs out, a session finishes. Doing that
    // silently leaves you unsure whether it is actually watching, so each transition
    // says so once.

    enum Transition { case pauseEnded, sessionEnded(blocks: Int, minutes: Int) }

    func startSession(minutes: Double) {
        rules.lockStartedAt = Date()
        rules.lockUntil = Date().addingTimeInterval(minutes * 60)
        rules.pauseUntil = nil
        rules.enabled = true
    }

    /// Clears a finished commitment session and reports what it was worth.
    func expireLockIfDue() -> Transition? {
        guard let until = rules.lockUntil, until <= Date() else { return nil }
        let started = rules.lockStartedAt ?? until
        let minutes = max(1, Int(until.timeIntervalSince(started) / 60))
        let blocks = History.load(limit: 4000)
            .filter { $0.blocked && $0.at >= started && $0.at <= until }.count
        rules.lockUntil = nil
        rules.lockStartedAt = nil
        return .sessionEnded(blocks: blocks, minutes: minutes)
    }

    // MARK: Ways in

    /// Dock icon, menu bar icon and the shortcut are the only three routes to the
    /// window. With all three off there is no way to open Ward at all — reopening a
    /// running app just activates it — so the last one is always put back.
    @discardableResult
    func ensureAWayIn() -> Bool {
        var next = rules
        guard next.ensureAWayIn() else { return false }
        rules = next
        return true
    }

    // MARK: Backup

    /// Transient state has no business in a backup — importing a file shouldn't
    /// hand you someone else's countdown or drop you into their commitment session.
    func exportRules(to url: URL) -> Bool {
        guard !Store.readOnly else { return false }
        guard let data = try? JSONEncoder.ward.encode(rules.portable) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    enum ImportMode { case replace, merge }

    struct ImportSummary {
        var apps = 0, blockedSites = 0, allowedSites = 0, phrases = 0, lessons = 0
        var describe: String {
            "\(apps) apps, \(blockedSites) blocked sites, \(allowedSites) allowed sites, "
            + "\(phrases) phrases, \(lessons) lessons"
        }
    }

    static func preview(_ url: URL) -> (Rules, ImportSummary)? {
        guard let data = try? Data(contentsOf: url),
              var r = try? JSONDecoder.ward.decode(Rules.self, from: data) else { return nil }
        _ = r.migrateIfNeeded()
        let s = ImportSummary(
            apps: r.blockedApps.count,
            blockedSites: r.blockedDomains.count,
            allowedSites: r.allowedDomains.count,
            phrases: r.hardBlockPhrases.count + r.denyPhrases.count + r.allowPhrases.count,
            lessons: r.correctionCount)
        return (r, s)
    }

    /// Merging only ever adds, so importing someone else's rulebook can't quietly
    /// unblock something you had blocked.
    func importRules(_ incoming: Rules, mode: ImportMode) {
        guard !rules.isLocked else { return }
        rules = mode == .merge ? rules.merged(with: incoming) : rules.replaced(by: incoming)
    }

    // MARK: Schedule

    private var lastScheduleState: Bool?

    /// Applies the schedule only when it crosses a boundary, so switching Ward on by
    /// hand inside a window isn't undone a second later.
    ///
    /// A schedule can only ever switch Ward *on*. It used to switch it off outside
    /// study hours, which — now that nothing else can turn Ward off — would have made
    /// it the way to do it: set a one-minute window and Ward is off all day. The
    /// boundary is still tracked either way, so entering the window still turns it on.
    /// Everything a schedule is allowed to do. There is deliberately no case for
    /// switching Ward off: the guarantee is in the type, so restoring that behaviour
    /// would mean adding a case here and having every switch over it stop compiling.
    enum ScheduleEffect: CaseIterable { case turnOn, leaveAlone }

    nonisolated static func scheduleEffect(_ schedule: Schedule, at date: Date) -> ScheduleEffect {
        schedule.isUsable && schedule.covers(date) ? .turnOn : .leaveAlone
    }

    @discardableResult
    func applyScheduleIfDue() -> Bool {
        guard rules.schedule.isUsable else { lastScheduleState = nil; return false }
        let inside = rules.schedule.covers(Date())
        guard lastScheduleState != inside else { return false }
        lastScheduleState = inside
        switch Store.scheduleEffect(rules.schedule, at: Date()) {
        case .leaveAlone:
            return false
        case .turnOn:
            rules.enabled = true
            rules.pauseUntil = nil
            return true
        }
    }

    // MARK: Exceptions

    /// Granularity follows whatever did the blocking: a site rule earns a site-wide
    /// pass, anything about the content earns a pass for that page only.
    func allowTemporarily(_ ctx: PageContext, verdict: Verdict, minutes: Int) {
        guard !rules.isLocked else { return }
        let title = Semantic.normalise(ctx.title)
        let host = ctx.host ?? ""

        let e: Exception
        if verdict.fromSiteRule || title.isEmpty {
            guard !host.isEmpty else { return }
            e = Exception(value: host, isHost: true, label: host,
                          until: Date().addingTimeInterval(Double(minutes) * 60))
        } else {
            e = Exception(value: title, isHost: false,
                          label: String(ctx.label.prefix(70)),
                          until: Date().addingTimeInterval(Double(minutes) * 60))
        }
        rules.exceptions.removeAll { $0.id == e.id }
        rules.exceptions.append(e)
    }

    func revokeException(_ id: String) {
        rules.exceptions.removeAll { $0.id == id }
    }

    @discardableResult
    func pruneExceptions() -> Bool {
        let before = rules.exceptions.count
        let live = rules.exceptions.filter(\.isLive)
        guard live.count != before else { return false }
        rules.exceptions = live
        return true
    }

    // MARK: Pausing
    //
    // There is no longer anything that starts a pause. `resume` and `expirePauseIfDue`
    // remain because a rulebook written before that change can still carry a live
    // `pauseUntil`, and it has to be possible to get out of it.

    func resume() {
        rules.pauseUntil = nil
        rules.enabled = true
    }

    /// Clears a pause that has run out so the interface stops claiming to be paused.
    /// Returns true when something actually changed.
    @discardableResult
    func expirePauseIfDue() -> Bool {
        guard let until = rules.pauseUntil, until <= Date() else { return false }
        rules.pauseUntil = nil
        return true
    }

    /// "40s", "6 min", "1h 5m" — short enough for a menu title.
    static func describe(seconds: Int) -> String {
        if seconds < 60 { return "\(max(1, seconds))s" }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: Zoom

    static let zoomSteps: [Double] = [0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]

    func zoom(_ direction: Int) {
        let current = rules.uiScale
        let index = Store.zoomSteps.enumerated()
            .min(by: { abs($0.element - current) < abs($1.element - current) })?.offset ?? 2
        let next = min(max(index + direction, 0), Store.zoomSteps.count - 1)
        rules.uiScale = Store.zoomSteps[next]
    }

    func resetZoom() { rules.uiScale = 1.0 }
    var canZoomIn: Bool { rules.uiScale < Store.zoomSteps.last! - 0.001 }
    var canZoomOut: Bool { rules.uiScale > Store.zoomSteps.first! + 0.001 }

    // MARK: Log

    func note(_ entry: LogEntry) {
        log.insert(entry, at: 0)
        if log.count > 250 { log.removeLast(log.count - 250) }
        if entry.blocked {
            blockedThisSession += 1
            blockedToday += 1
        }
        History.append(entry)
    }

    /// Reads the whole record back for the History pane. Off the hot path, so it
    /// simply reloads rather than trying to keep a live mirror in memory.
    func loadHistory() -> [LogEntry] {
        History.load().sorted { $0.at > $1.at }
    }

    /// Guard rail: while a commitment session is running, rules can only get stricter.
    var canWeaken: Bool { !rules.isLocked }

    // MARK: The page a redirected tab lands on

    /// The page a redirected tab lands on. Regenerated whenever the rules change so
    /// the shortcuts stay in step with your allow-list — a block that only says "no"
    /// leaves you sitting on a dead page, which is exactly when you go looking for
    /// something else to do.
    func writeBlockPage() {
        let picks = rules.allowedDomains.prefix(8).map { domain -> String in
            let host = domain.hasPrefix("http") ? domain : "https://" + domain
            let name = domain.replacingOccurrences(of: "www.", with: "")
            return "<a class=\"go\" href=\"\(host)\">\(name)</a>"
        }.joined()

        let shortcuts = picks.isEmpty ? "" : """
            <div class="back">
              <div class="lbl">Back to it</div>
              <div class="links">\(picks)</div>
            </div>
            """

        let html = """
        <!doctype html><meta charset="utf-8"><title>Blocked &middot; Ward</title>
        <style>
          :root{color-scheme:dark light}
          *{box-sizing:border-box}
          body{margin:0;min-height:100vh;display:grid;place-items:center;
               background:#0d1117;color:#e6edf3;
               font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
          .card{max-width:38rem;padding:3rem 2.5rem;text-align:center}
          .mark{width:60px;height:60px;margin:0 auto 1.6rem;border-radius:17px;
                background:linear-gradient(145deg,#f0883e,#db6d28);display:grid;place-items:center;
                font-size:27px;box-shadow:0 12px 32px -12px rgba(219,109,40,.7)}
          h1{margin:0 0 .5rem;font-size:1.55rem;letter-spacing:-.02em;font-weight:650}
          p{margin:0;color:#8b949e;font-size:.95rem}
          .what{margin-top:1.6rem;padding:.8rem 1.1rem;border:1px solid #21262d;border-radius:10px;
                background:#161b22;color:#c9d1d9;font-size:.9rem;word-break:break-word}
          .why{margin-top:.55rem;font-size:.75rem;color:#6e7681;letter-spacing:.04em;
               text-transform:uppercase}
          .back{margin-top:2.2rem;padding-top:1.6rem;border-top:1px solid #21262d}
          .lbl{font-size:.7rem;letter-spacing:.09em;text-transform:uppercase;color:#6e7681;
               margin-bottom:.8rem}
          .links{display:flex;flex-wrap:wrap;gap:.45rem;justify-content:center}
          .go{display:inline-block;padding:.42rem .85rem;border-radius:99px;
              border:1px solid #30363d;background:#161b22;color:#adbac7;
              text-decoration:none;font-size:.82rem;transition:.12s}
          .go:hover{background:#21262d;color:#e6edf3;border-color:#484f58}
          .hint{margin-top:1.8rem;font-size:.75rem;color:#484f58}
          @media (prefers-color-scheme: light){
            body{background:#f6f8fa;color:#1f2328}
            .what{background:#fff;border-color:#d1d9e0;color:#32383f}
            .back{border-color:#d1d9e0}
            .go{background:#fff;border-color:#d1d9e0;color:#424a53}
            .go:hover{background:#f6f8fa;color:#1f2328}
          }
        </style>
        <div class="card">
          <div class="mark">&#9899;</div>
          <h1>Not right now.</h1>
          <p>Ward stopped this one so you can keep going.</p>
          <div class="what" id="what">&mdash;</div>
          <div class="why" id="why"></div>
          \(shortcuts)
          <div class="hint">Genuinely need this? Ward's menu bar can let it through for a few minutes.</div>
        </div>
        <script>
          var p = new URLSearchParams(location.search);
          if (p.get('what')) document.getElementById('what').textContent = p.get('what');
          if (p.get('why'))  document.getElementById('why').textContent  = p.get('why');
        </script>
        """
        try? html.data(using: .utf8)?.write(to: Store.blockPageURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var ward: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var ward: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
