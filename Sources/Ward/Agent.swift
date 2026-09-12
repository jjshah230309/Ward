import SwiftUI
import AppKit
import CoreGraphics
import Combine

/// Ward is one binary that runs in two modes.
///
///  • Normal: the window app (`WardApp`). An ordinary Dock app that quits outright
///    when you close its window, leaving nothing in the Dock, Cmd-Tab or Force Quit.
///  • `--background`: this agent. No windows, no Dock icon — `.accessory` keeps it
///    out of everything except the menu bar. It holds the shield, keeps watching,
///    and is what makes Ward read as closed while it is still doing its job.
///
/// Keeping the two apart is the whole trick. A single process that merely hides its
/// window is still a running application, and macOS shows it as one.
enum WardIPC {
    /// The window app has started, and is taking the watching over.
    static let uiUp = Notification.Name("app.ward.ui.up")
    /// The window app has quit. Whatever it changed is on disk by now.
    static let uiDown = Notification.Name("app.ward.ui.down")
    /// Asks a running window app to bring a window forward.
    static let showDashboard = AppDelegate.showWindowNotification
    static let showSettings = Notification.Name("app.ward.showSettings")

    static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

// MARK: - Finding the window app

/// Asked of the window server rather than of the process list, because a process
/// with no window — the agent, or a copy still starting up — looks exactly like one
/// that has a window from the outside.
enum WardWindows {
    static func visibleElsewhere() -> Bool {
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        for window in list {
            guard (window[kCGWindowOwnerName as String] as? String) == "Ward",
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowOwnerPID as String] as? Int) != me else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            // A shield is a full-screen strip and the menu bar item is a sliver;
            // neither is a window someone can be brought back to.
            if (bounds["Height"] as? Double ?? 0) > 200 { return true }
        }
        return false
    }
}

/// Opening Ward's window means starting a *process*: the window app quits when its
/// last window closes, so most of the time there is nothing to raise.
enum WardUI {
    /// `open -n` insists on a new instance. A plain `open` is routed to whichever
    /// copy LaunchServices already knows about — which is the agent, a windowless
    /// process perfectly happy to be "reopened" without anything appearing.
    static func launch(_ arguments: [String] = []) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
                       + (arguments.isEmpty ? [] : ["--args"] + arguments)
        try? task.run()
    }

    /// Raise the window app if it is on screen, otherwise start one. Only ever
    /// "activate what's running" when there is a real window to activate; a
    /// windowless copy would swallow the request and nothing would appear.
    @MainActor
    static func open(_ windowID: String) {
        guard WardWindows.visibleElsewhere() else {
            WardUI.launch(windowID == "settings" ? ["--open", "settings"] : [])
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "app.ward.Ward"
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
            .forEach { $0.activate(options: [.activateAllWindows]) }
        WardIPC.post(windowID == "settings" ? WardIPC.showSettings : WardIPC.showDashboard)
    }
}

// MARK: - One agent only

/// Two agents would mean two pollers enforcing the same rules and two shields in the
/// menu bar. The launch agent, a stale copy and a hand-started one can all arrive at
/// once, so first past the post keeps the job.
enum AgentLock {
    private static var url: URL { Store.supportDir.appendingPathComponent("agent.pid") }

    /// True when this process may go on to be the agent.
    static func claim() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let held = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           held != mine,
           let other = NSRunningApplication(processIdentifier: held),
           other.bundleIdentifier == Bundle.main.bundleIdentifier,
           !other.isTerminated {
            return false
        }
        try? String(mine).write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Is an agent alive right now? Read rather than claimed, so asking doesn't
    /// take the job.
    static var isRunning: Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let held = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              held != ProcessInfo.processInfo.processIdentifier,
              let other = NSRunningApplication(processIdentifier: held),
              other.bundleIdentifier == Bundle.main.bundleIdentifier else { return false }
        return !other.isTerminated
    }

    static func release() {
        let mine = ProcessInfo.processInfo.processIdentifier
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == mine else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - The agent

/// No `Window` scene anywhere: a scene would give this process a window to show, a
/// Dock icon to go with it, and an entry in Cmd-Tab. The menu bar item is its only
/// visible presence.
struct WardAgentApp: App {
    @NSApplicationDelegateAdaptor(AgentDelegate.self) private var delegate
    @ObservedObject private var store = Store.shared

    var body: some Scene {
        // Same guard as the window app used to need: SwiftUI writes back to this
        // binding while updating scenes, and a struct assignment fires @Published
        // even when the value is identical.
        MenuBarExtra(isInserted: Binding(
            get: { store.rules.showInMenuBar },
            set: { if $0 != store.rules.showInMenuBar { store.rules.showInMenuBar = $0 } })) {
            MenuContent()
        } label: {
            Image(systemName: MenuBarIcon.name(for: store.rules))
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate {

    private var cancellables = Set<AnyCancellable>()
    private var challenge: ChallengeWindow?
    /// Whether this process is currently the one doing the watching.
    private var watching = false
    /// When the window app last said it was going. macOS sends this leftover process
    /// a reopen the instant the copy it routed to quits, and honouring that would
    /// bounce a new window straight back up.
    private var lastUIDown = Date.distantPast

    /// Before anything is on screen, so a losing copy leaves no trace of itself.
    func applicationWillFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard AgentLock.claim() else {
            Permissions.mark("agent: another one has the job, exiting")
            exit(0)
        }
        Permissions.mark("agent: willFinishLaunching")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: WardIPC.uiUp, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.standDown() }
        }
        dnc.addObserver(forName: WardIPC.uiDown, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.lastUIDown = Date()
                self?.takeOver()
            }
        }

        // The window app owns the job the moment it exists, so don't start watching
        // underneath one that is already up.
        if windowAppRunning { standDown() } else { takeOver() }

        // `uiDown` is a courtesy, and a process that is force-quit, killed or
        // crashes never sends one. Ward quietly not watching because of that would
        // be worse than Ward never starting, so the handover doesn't rest on it:
        // the workspace says so immediately, and the timer catches the rest.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            Task { @MainActor in self?.reclaimIfAlone() }
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reclaimIfAlone() }
        }

        Store.shared.$rules
            .map(\.hotkeysEnabled)
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self, self.watching else { return }
                HotKeys.apply(enabled: on)
            }
            .store(in: &cancellables)

        // The window app puts a puzzle up as a sheet on its dashboard. This process
        // has no dashboard, so it needs somewhere of its own to put one — otherwise
        // a pause asked for from the menu waits forever on a sheet nobody can see.
        Challenges.shared.$pending
            .receive(on: RunLoop.main)
            .sink { [weak self] pending in
                self?.challenge?.close()
                self?.challenge = pending.map { ChallengeWindow($0) }
            }
            .store(in: &cancellables)

        Permissions.mark("agent: running")
    }

    /// Exactly one process enforces at a time. While the window app is up it takes
    /// the job: it is the one the user is looking at, and the one that already has a
    /// window to put a puzzle or a verdict in front of them. The agent takes it back
    /// the moment that process goes away.
    private func standDown() {
        guard watching else { return }
        watching = false
        Engine.shared.stop()
        HotKeys.apply(enabled: false)
        Permissions.mark("agent: stood down, the window app is watching")
    }

    /// Any Ward process other than this one is the window app: `AgentLock` sees to
    /// it that there is never a second agent.
    private var windowAppRunning: Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "app.ward.Ward"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != mine && !$0.isTerminated }
    }

    private func reclaimIfAlone() {
        guard !watching, !windowAppRunning else { return }
        takeOver()
    }

    private func takeOver() {
        guard !watching else { return }
        watching = true
        // Whatever the window app changed while it had the job is on disk by now.
        Store.shared.reloadFromDisk()
        Engine.shared.start()
        HotKeys.apply(enabled: Store.shared.rules.hotkeysEnabled)
        Permissions.mark("agent: watching")
    }

    /// The agent shares the app's bundle, so reopening Ward from the Dock, Spotlight
    /// or Finder is routed to this windowless process rather than opening a window.
    /// Intercept it and start the real thing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Permissions.mark("agent: reopen requested (visible windows: \(flag))")
        guard Date().timeIntervalSince(lastUIDown) > 2.5 else { return false }
        WardUI.open("dashboard")
        return false
    }

    /// Opening an accessory app promotes it to a foreground one — which would put the
    /// agent in the Dock and in Cmd-Tab, the exact thing it exists to avoid. Guarded,
    /// so activating merely to show a puzzle doesn't churn the policy.
    func applicationDidBecomeActive(_ note: Notification) {
        Permissions.mark("agent: became active")
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Nothing in Ward asks this process to quit any more, so the only thing that
    /// reaches here is the system: logging out, restarting, shutting down. Standing
    /// in the way of *that* would be holding a Mac hostage rather than holding a
    /// commitment, so it goes quietly and comes back at the next login.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Store.shared.save()
        return .terminateNow
    }

    func applicationWillTerminate(_ note: Notification) {
        Store.shared.save()
        AgentLock.release()
    }
}

/// A window that exists only while a puzzle is unanswered. Deliberately plain: the
/// puzzle is the same view the dashboard shows, so the two can never drift apart.
@MainActor
final class ChallengeWindow {
    private var window: NSWindow?

    init(_ pending: Challenges.Pending) {
        let scale = CGFloat(Store.shared.rules.uiScale)
        let view = ChallengeSheet(pending: pending).environment(\.uiScale, scale)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560 * scale, height: 340),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Ward"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
