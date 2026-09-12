import SwiftUI
import AppKit
import Combine

extension Engine {
    static let shared = Engine()
}

/// Opening a scene needs SwiftUI's `openWindow`, which only exists inside a view —
/// and only in the process that has the scenes. Both halves of Ward ask for windows
/// through here, and this is what knows the difference.
@MainActor
enum WindowRouter {
    static var open: ((String) -> Void)?

    static func show(_ id: String, fallbackTitle: String) {
        // The agent has no scenes at all, so there is no window here to open —
        // opening one means starting the window app.
        if AppDelegate.isBackgroundLaunch { WardUI.open(id); return }
        NSApp.activate(ignoringOtherApps: true)
        if let open { open(id); return }
        NSApp.windows.first { $0.title == fallbackTitle }?.makeKeyAndOrderFront(nil)
    }
}

/// `openWindow` only exists inside a view. The dashboard is the one thing this
/// process always builds, so it is where the action gets captured — the menu bar,
/// which used to do this, now lives in the other process.
///
/// This is also where the window asserts itself. The process exists because
/// someone clicked something — the menu bar helper, a reopen, Spotlight — but the
/// click usually arrives via the agent, an accessory app with no right to hand
/// focus to what it launches. Launched that way, the dashboard is created and then
/// never ordered onto the screen: a window nobody sees, which reads as the click
/// having done nothing. Done here rather than in `didFinishLaunching` because only
/// this code runs at a moment the window certainly exists.
private struct CapturesWindowRouter: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            WindowRouter.open = { openWindow(id: $0) }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let dashboard = NSApp.windows.first(where: { $0.title == "Ward" }) {
                    dashboard.collectionBehavior.insert(.moveToActiveSpace)
                    dashboard.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

/// Process entry point. Which half of Ward this is, is decided here and nowhere
/// else — see the note at the top of `Agent.swift`.
@main
enum WardMain {
    static func main() {
        if AppDelegate.isBackgroundLaunch {
            WardAgentApp.main()
            return
        }
        // Wake the agent alongside the SwiftUI launch rather than in front of it:
        // this asks launchd whether the agent is alive, and waiting for that answer
        // held the first window back.
        if !CommandLine.arguments.contains("--render"),
           !CommandLine.arguments.contains("--doctor"),
           !CommandLine.arguments.contains("--dump-menu") {
            Thread.detachNewThread { Permissions.ensureAgentRunning() }
        }
        WardApp.main()
    }
}

struct WardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var store = Store.shared

    init() {
        // Before any scene exists. Left in didFinishLaunching, this ran *after*
        // SwiftUI had already built and shown a window, so reopening flashed up a
        // doomed window for a moment and then replaced it.
        AppDelegate.handOverIfAlreadyRunning()
    }

    private var scale: CGFloat { CGFloat(store.rules.uiScale) }

    var body: some Scene {
        Window("Ward", id: "dashboard") {
            Dashboard()
                .environment(\.uiScale, scale)
                .modifier(CapturesWindowRouter())
        }
        .defaultSize(width: 900, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Left to itself, SwiftUI appends its generated sidebar toggle to whatever
            // menu happens to be last — it was landing in Help. Declaring it puts it
            // back in View where it belongs.
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(
                        #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { Store.shared.zoom(1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(!store.canZoomIn)
                Button("Zoom Out") { Store.shared.zoom(-1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(!store.canZoomOut)
                Button("Actual Size") { Store.shared.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandGroup(after: .windowList) { OpenDashboardButton() }
            CommandGroup(replacing: .appSettings) { OpenSettingsButton() }
        }

        Window("Ward Settings", id: "settings") {
            SettingsWindow()
                .environment(\.uiScale, scale)
        }
        .defaultSize(width: 560, height: 480)
        .windowResizability(.contentMinSize)

        // No MenuBarExtra here on purpose. A MenuBarExtra scene keeps this windowed
        // app alive after its window closes, and a running application is exactly
        // what Ward must not be once you have closed it. The menu bar belongs to the
        // agent, which is built for having no windows at all.
    }
}

/// Which shield to show, kept in one place so the two processes can't disagree.
enum MenuBarIcon {
    static func name(for rules: Rules) -> String {
        if !rules.enabled { return "shield.slash" }
        if rules.isPaused { return "shield.lefthalf.filled" }
        return rules.isLocked ? "lock.shield.fill" : "shield.fill"
    }
}

/// Routed through `WindowRouter` rather than `openWindow` directly: in the agent
/// there is no scene for `openWindow` to open — the router is what knows to start
/// the window app instead.
struct OpenSettingsButton: View {
    var label = "Settings\u{2026}"

    var body: some View {
        Button(label) { AppDelegate.openSettings() }
            .keyboardShortcut(",", modifiers: .command)
    }
}

struct OpenDashboardButton: View {
    var label = "Ward Dashboard"

    var body: some View {
        Button(label) { AppDelegate.openDashboard() }
            .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

struct MenuContent: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var engine = Engine.shared

    var body: some View {
        Text(statusLine)

        if store.blockedToday > 0 {
            Text("\(store.blockedToday) stopped today"
                 + (store.blockedThisSession > 0 && store.blockedThisSession != store.blockedToday
                    ? "  \u{00B7}  \(store.blockedThisSession) this session" : ""))
        }

        if !engine.nowWatching.isEmpty
            && !(engine.nowVerdict.hasPrefix("blocked") && store.rules.isLocked) {
            Divider()
            let wrongNow = engine.nowVerdict.hasPrefix("blocked")
            Button((wrongNow ? "That was wrong \u{2014} allow it"
                             : "Should have been blocked")
                   + "   " + (wrongNow ? HotKeys.Action.allowThis.display
                                       : HotKeys.Action.blockThis.display)) {
                let wrong = engine.nowVerdict.hasPrefix("blocked")
                let result = engine.teach(wrong ? .shouldAllow : .shouldBlock)
                if !result.ok { AppDelegate.openDashboard() }
            }
        }

        if engine.nowVerdict.hasPrefix("blocked") && !store.rules.isLocked {
            Menu("Let this through\u{2026}") {
                ForEach([5, 15, 30], id: \.self) { minutes in
                    Button("For \(minutes) minutes") {
                        Challenges.shared.require(.exception) {
                            engine.allowForNow(minutes: minutes)
                        }
                    }
                }
            }
        }

        Divider()

        // Nothing here turns Ward off or pauses it: those commands are gone, not
        // hidden. "Resume now" only ever clears a pause left over from before.
        if store.rules.isPaused {
            Button("Resume now") { store.resume() }
        }

        if !store.rules.isActive {
            Button("Turn Ward on") { store.resume() }
        }

        OpenDashboardButton(label: "Open Ward\u{2026}")

        OpenSettingsButton()

        // No "Quit Ward" either. Quitting this process *was* the off switch: the
        // launch agent only restarts a copy that died badly, so a clean quit stopped
        // Ward until the next login. Removing the off switch while leaving this here
        // was removing the lock and leaving the door open.
    }

    private var statusLine: String {
        guard store.rules.enabled else { return "Ward is off" }
        if store.rules.isPaused {
            return "Paused \u{2014} back in \(Store.describe(seconds: store.rules.pauseRemaining))"
        }
        if store.rules.schedule.isUsable, !store.rules.schedule.covers(Date()) {
            return "Outside study hours"
        }
        if let until = store.rules.lockUntil, until > Date() {
            let mins = max(1, Int(until.timeIntervalSinceNow / 60))
            return "Locked in \u{2014} \(mins) min left"
        }
        return engine.nowWatching.isEmpty ? "Ward is watching"
                                          : "Watching: \(engine.nowWatching.prefix(40))"
    }
}

// MARK: - Lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {

    static let showWindowNotification = Notification.Name("app.ward.showWindow")

    /// Started by launchd rather than by a person: watch, but stay out of the way.
    static let isBackgroundLaunch = CommandLine.arguments.contains("--background")

    /// Two window apps would mean two of everything. "Is another Ward running?" is
    /// the wrong question now, though — the agent shares this bundle identifier and
    /// is *meant* to be running, so a process-list answer would make every launch
    /// hand over to it and quietly die. The right question is whether a window is
    /// already on screen to be brought forward, and only the window server can
    /// answer that.
    static func handOverIfAlreadyRunning() {
        guard !CommandLine.arguments.contains("--render"),
              !CommandLine.arguments.contains("--doctor"),
              !CommandLine.arguments.contains("--dump-menu"),
              !CommandLine.arguments.contains("--request-automation"),
              WardWindows.visibleElsewhere() else { return }

        WardIPC.post(showWindowNotification)
        let mine = ProcessInfo.processInfo.processIdentifier
        if let id = Bundle.main.bundleIdentifier {
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != mine }
                .forEach { $0.activate(options: [.activateAllWindows]) }
        }
        // Posting and exiting in the same breath can drop the message before it
        // leaves the process.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        Permissions.mark("a window is already open elsewhere, exiting")
        exit(0)
    }

    private var cancellables = Set<AnyCancellable>()
    private var zoomMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.mark("didFinishLaunching")
        // Fires the consent dialog for automating one app, then exits. It must run
        // in a copy of Ward that LaunchServices launched: appleeventsd answers the
        // permission question by looking the asker up in LaunchServices, and for a
        // process it has never heard of — a launchd agent, anything started from a
        // terminal — it looks forever and no dialog ever appears. `open -n` is what
        // makes this copy one it can find.
        if let i = CommandLine.arguments.firstIndex(of: "--request-automation"),
           CommandLine.arguments.count > i + 1 {
            let target = CommandLine.arguments[i + 1]
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: "tell application id \"\(target)\" to return name")
                _ = script?.executeAndReturnError(&error)
                let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
                try? "\(target): \(code == 0 ? "granted" : "error \(code)")\n"
                    .write(toFile: NSTemporaryDirectory() + "ward-automation-request.txt",
                           atomically: true, encoding: .utf8)
                exit(code == 0 ? 0 : 1)
            }
            return
        }
        // Layout check / README screenshots. Exits directly so the commitment lock
        // in applicationShouldTerminate doesn't get in the way.
        if let i = CommandLine.arguments.firstIndex(of: "--render") {
            let dir = CommandLine.arguments.count > i + 1
                ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            NSApp.setActivationPolicy(.accessory)
            PreviewShots.writeAll(to: dir)
            exit(0)
        }

        // Before the single-instance guard: the whole point is to ask what *this*
        // binary is told, and the guard would make it hand over and exit.
        if CommandLine.arguments.contains("--doctor") {
            Permissions.doctor { exit(0) }
            return
        }

        // Both the agent and a later launch ask for a window this way, so a request
        // is answered by a window appearing rather than by a process starting and
        // exiting.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: AppDelegate.showWindowNotification, object: nil, queue: .main) { _ in
            Permissions.mark("asked to show the window")
            Task { @MainActor in AppDelegate.openDashboard() }
        }
        dnc.addObserver(forName: WardIPC.showSettings, object: nil, queue: .main) { _ in
            Task { @MainActor in AppDelegate.openSettings() }
        }

        tidyMenus()

        if CommandLine.arguments.contains("--dump-menu") {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for top in NSApp.mainMenu?.items ?? [] {
                    print("[\(top.title)]")
                    for item in top.submenu?.items ?? [] where !item.title.isEmpty {
                        let mods = item.keyEquivalentModifierMask
                        var k = ""
                        if !item.keyEquivalent.isEmpty {
                            k = (mods.contains(.control) ? "ctrl+" : "")
                              + (mods.contains(.option) ? "opt+" : "")
                              + (mods.contains(.shift) ? "shift+" : "")
                              + (mods.contains(.command) ? "cmd+" : "") + item.keyEquivalent
                        }
                        print("   \(item.title)\(k.isEmpty ? "" : "   [\(k)]")")
                    }
                }
                exit(0)
            }
            return
        }

        Permissions.mark("guards done")

        // Past every mode that exits without running, so the agent is only told to
        // stand down for a launch that is actually going to take the job.
        WardIPC.post(WardIPC.uiUp)

        Store.shared.ensureAWayIn()
        applyActivationPolicy(Store.shared.rules.showInDock)
        Permissions.mark("Store loaded + activation policy")

        // Started with `--open settings`, which is how the agent's menu reaches a
        // window that does not exist yet. Late enough that the scene is built.
        if let i = CommandLine.arguments.firstIndex(of: "--open"),
           CommandLine.arguments.count > i + 1 {
            let id = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if id == "settings" { AppDelegate.openSettings() }
            }
        }


        Store.shared.$rules
            .map(\.showInDock)
            .removeDuplicates()
            .sink { [weak self] in self?.applyActivationPolicy($0) }
            .store(in: &cancellables)

        installZoomShortcuts()
        Permissions.mark("shortcuts installed")


        HotKeys.apply(enabled: Store.shared.rules.hotkeysEnabled)
        Store.shared.$rules
            .map(\.hotkeysEnabled)
            .removeDuplicates()
            .sink { HotKeys.apply(enabled: $0) }
            .store(in: &cancellables)

        Task { @MainActor in
            Permissions.mark("before Engine.shared")
            Engine.shared.start()
            Permissions.mark("Engine started")
            // Never raise a system dialog on launch. Ward opens its own window and
            // explains the situation there; the system prompt only fires if you press
            // the button, and only the first time. A background copy says nothing —
            // nobody is sitting there to read it.
            if !Permissions.accessibilityGranted, !AppDelegate.isBackgroundLaunch {
                AppDelegate.openDashboard()
            }
        }
    }

    /// A regular app gets a Dock icon, a menu bar and a place in Cmd-Tab. Accessory
    /// keeps Ward in the menu bar only — at the cost of Cmd-comma, which needs a
    /// menu bar to exist.
    private func applyActivationPolicy(_ showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    /// NavigationSplitView also emits its own sidebar toggle, which lands in Help with
    /// no shortcut. One of the two has to go, and the inert one is the right one.
    private func tidyMenus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            for top in NSApp.mainMenu?.items ?? [] {
                guard let menu = top.submenu, top.title != "View" else { continue }
                for item in menu.items
                where item.title == "Toggle Sidebar" && item.keyEquivalent.isEmpty {
                    menu.removeItem(item)
                }
            }
        }
    }

    /// Cmd-plus arrives as "=" on most layouts and "+" when shift is held, and the
    /// menu item can only claim one of them.
    private func installZoomShortcuts() {
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  let key = event.charactersIgnoringModifiers,
                  ["=", "+", "-", "0"].contains(key) else { return event }
            // Key events always arrive on the main thread; saying so avoids a hop
            // that would swallow the keystroke.
            MainActor.assumeIsolated {
                switch key {
                case "=", "+": Store.shared.zoom(1)
                case "-":      Store.shared.zoom(-1)
                default:       Store.shared.resetZoom()
                }
            }
            return nil
        }
    }

    @MainActor
    static func openDashboard() { WindowRouter.show("dashboard", fallbackTitle: "Ward") }

    @MainActor
    static func openSettings() { WindowRouter.show("settings", fallbackTitle: "Ward Settings") }

    /// Close the window and this process is finished: no Dock icon, no Cmd-Tab entry,
    /// nothing in Force Quit — Ward reads as closed, because it is. The watching
    /// carries on in the agent, which is built for having no windows.
    ///
    /// Lingering as a windowless process is what this replaces, and it was worse than
    /// it looked: reopening Ward only "activated" that ghost, so no window ever
    /// appeared.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Hand the watching back before going. The agent is listening for this, and
    /// picks up whatever the rules were changed to along the way.
    func applicationWillTerminate(_ notification: Notification) {
        Store.shared.save()
        Permissions.ensureAgentRunning()
        WardIPC.post(WardIPC.uiDown)
    }

    /// A commitment session means what it says. Closing this window no longer takes
    /// anything away, though — the agent carries on watching — so the lock only has
    /// to stand in the way when there is no agent left to take over.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Store.shared.rules.isLocked, !AgentLock.isRunning {
            let until = Store.shared.rules.lockUntil ?? Date()
            let mins = max(1, Int(until.timeIntervalSinceNow / 60))
            let alert = NSAlert()
            alert.messageText = "Ward is locked in"
            alert.informativeText = """
                You committed to a session with \(mins) minute\(mins == 1 ? "" : "s") left to run. \
                Ward will let go on its own when the timer is up.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Keep going")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return .terminateCancel
        }
        Store.shared.save()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Permissions.mark("reopen requested (visible windows: \(flag))")
        if !flag { Task { @MainActor in AppDelegate.openDashboard() } }
        return true
    }
}
