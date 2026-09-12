import Foundation
import AppKit
import CoreServices

enum Permissions {

    // MARK: Accessibility

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Guards against a second system dialog within one run, whatever the saved flag
    /// says. Queued copies of that dialog are what made it look like it never went away.
    private static var promptedThisLaunch = false

    /// Only ever reached by clicking something. The system dialog is fired at most once
    /// ever — its single use is getting Ward listed in the Accessibility pane, and it
    /// cannot help at all when the real problem is a stale entry from an older build.
    @MainActor
    static func openAccessibilitySettings() {
        if !promptedThisLaunch && !Store.shared.rules.askedForAccessibility {
            promptedThisLaunch = true
            Store.shared.rules.askedForAccessibility = true
            Store.shared.save()          // persist before the dialog, not after
            _ = Accessibility.requestTrust()
        }
        openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: Automation (Apple Events)

    enum AutomationState: Sendable { case granted, denied, notAsked, appNotRunning, unknown(OSStatus) }

    /// Blocks the calling thread, and not for a bounded time — never call it from the
    /// main thread. `AEDeterminePermissionToAutomateTarget` is documented as blocking,
    /// and asking about an app whose consent has never been settled can block *for
    /// good*: the Apple Event manager decides the question needs the user, and waits
    /// for an answer that only the asking process's main thread could ever put on
    /// screen. Ask from the main thread and each is waiting on the other. Passing
    /// `false` for "ask if needed" is supposed to make it return -1744 instead, and
    /// for most targets it does — a running Safari is one where it does not.
    ///
    /// `automationStates(for:)` is the way to reach this from anywhere else.
    private static func blockingAutomationState(for bundleID: String) -> AutomationState {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else {
            return .unknown(-1)
        }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:   return .granted
        case -1743:   return .denied
        case -1744:   return .notAsked
        case -600:    return .appNotRunning
        default:      return .unknown(status)
        }
    }

    private static let probeLock = NSLock()
    /// Targets that have already failed to answer once. Asking them again only parks
    /// another thread on the same silence, so they are asked once and then left alone.
    private static var silentTargets: Set<String> = []
    private static var probing: Set<String> = []

    /// Answers on the main queue with whatever came back within `timeout`. A missing
    /// entry means the system never replied — a state worth reporting rather than one
    /// worth waiting on.
    ///
    /// One thread per target rather than one queue for all of them: a browser that
    /// never answers must not hide the answers for the others behind it, which is
    /// exactly what a shared queue would do. They are threads of Ward's own rather
    /// than the shared pool, so a parked probe isn't squatting on a worker the rest
    /// of the app needs.
    static func automationStates(for bundleIDs: [String],
                                 timeout: TimeInterval = 2,
                                 then completion: @escaping @Sendable ([String: AutomationState]) -> Void) {
        probeLock.lock()
        let ask = bundleIDs.filter { !silentTargets.contains($0) && !probing.contains($0) }
        probing.formUnion(ask)
        probeLock.unlock()

        // A probe can outlive the caller that gave up on it, so the answers cannot
        // live in a captured var — that late write would race the read.
        let answers = Answers()
        let group = DispatchGroup()

        for id in ask {
            group.enter()
            let probe = Thread {
                let state = blockingAutomationState(for: id)
                answers.set(id, state)
                probeLock.lock()
                probing.remove(id)
                silentTargets.remove(id)   // it answered after all
                probeLock.unlock()
                group.leave()
            }
            probe.name = "app.ward.automation-probe"
            probe.stackSize = 512 * 1024
            probe.start()
        }

        let delivered = Once()
        func deliver() {
            guard delivered.claim() else { return }
            let snapshot = answers.all()
            DispatchQueue.main.async { completion(snapshot) }
        }

        group.notify(queue: .global(qos: .utility)) { deliver() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            probeLock.lock()
            // Whatever is still out there has had its chance; don't ask it again.
            silentTargets.formUnion(probing)
            probeLock.unlock()
            deliver()
        }
    }

    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: AutomationState] = [:]
        func set(_ key: String, _ state: AutomationState) {
            lock.lock(); value[key] = state; lock.unlock()
        }
        func all() -> [String: AutomationState] {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    /// The timeout and the last answer race each other; only one of them gets to reply.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }

    /// Fires the consent dialog by actually trying something harmless.
    static func requestAutomation(for bundleID: String) {
        let script = "tell application id \"\(bundleID)\" to return name"
        DispatchQueue.global(qos: .userInitiated).async {
            _ = NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }

    static func openAutomationSettings() {
        openSettings("com.apple.preference.security?Privacy_Automation")
    }

    static func openSettings(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:\(path)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Timing

    /// `WARD_TIMING=1 /Applications/Ward.app/Contents/MacOS/Ward` prints how long each
    /// phase of launch took, measured from when the kernel actually started the
    /// process rather than from the first line of our own code.
    private static let processStart: CFAbsoluteTime = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return CFAbsoluteTimeGetCurrent() }
        let started = Double(info.kp_proc.p_starttime.tv_sec)
                    + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
        return started - kCFAbsoluteTimeIntervalSince1970
    }()

    private static let timingOn = ProcessInfo.processInfo.environment["WARD_TIMING"] != nil

    static func mark(_ phase: String) {
        guard timingOn else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - processStart) * 1000
        let line = String(format: "[timing] %7.1f ms  %@\n", ms, phase)
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    // MARK: Diagnosis

    /// `Ward --doctor` answers the one question that can't be answered from outside:
    /// what the system tells *this binary* when it asks. System Settings showing a
    /// toggle is not the same thing.
    /// Asynchronous because the automation question is: `doctor` reports what the
    /// system says, and "it never answered" is one of the things it can say.
    static func doctor(then finish: @escaping @Sendable () -> Void) {
        @Sendable func line(_ k: String, _ v: String) {
            print("  \(k.padding(toLength: 22, withPad: " ", startingAt: 0)) \(v)")
        }
        print("\nWard permissions report")
        line("bundle", Bundle.main.bundleURL.path)
        line("bundle id", Bundle.main.bundleIdentifier ?? "?")
        line("accessibility", AXIsProcessTrusted() ? "GRANTED" : "NOT GRANTED")

        let ids = ["com.apple.Safari", "com.google.Chrome", "com.brave.Browser",
                   "company.thebrowser.Browser", "com.microsoft.edgemac"]
        automationStates(for: ids, timeout: 4) { states in
            for id in ids {
                let name = Browsers.known[id]?.name ?? id
                let state: String
                switch states[id] {
                case .granted:        state = "granted"
                case .denied:         state = "DENIED"
                case .notAsked:       state = "not asked yet"
                case .appNotRunning:  state = "(not running)"
                case .unknown(let s): state = "unknown (\(s))"
                case nil:             state = "NO ANSWER \u{2014} the system never replied"
                }
                line("automation \u{2192} \(name)", state)
            }
            line("login agent", agentInstalled ? "installed" : "not installed")
            print("")
            finish()
        }
    }

    // MARK: Staying on

    static let agentLabel = "app.ward.agent"

    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var agentInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// The path of the binary inside whatever bundle is currently running.
    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
    }

    @discardableResult
    static func installAgent() -> Bool {
        let plist: [String: Any] = [
            "Label": agentLabel,
            // --background says "start watching, don't show yourself". Without it a
            // login-started copy would open its window and pull focus.
            "ProgramArguments": [executablePath, "--background"],
            "RunAtLoad": true,
            // Restart only when Ward died badly. Plain `true` restarts it even after a
            // clean exit, which meant a copy that started, found another already
            // running and stepped aside was immediately started again — a loop that
            // ran 32 times and yanked the window forward on every pass.
            "KeepAlive": ["SuccessfulExit": false],
            // Without this a crash on launch would spin launchd flat out.
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        do {
            let dir = agentPlistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0)
            try data.write(to: agentPlistURL, options: .atomic)
        } catch {
            return false
        }
        _ = launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])   // ignore if absent
        return launchctl(["bootstrap", "gui/\(getuid())", agentPlistURL.path])
    }

    /// Ward keeps watching after its window closes, and once the window app has
    /// quit the agent is all that is left — so make sure one is up before that
    /// happens. launchd's copy is preferred, since that is the one that also comes
    /// back at login; without the login agent installed a plain child process does
    /// the same job for this session, so closing the window still leaves Ward
    /// watching even if you never asked it to start at login.
    static func ensureAgentRunning() {
        guard !AgentLock.isRunning else { return }
        if agentInstalled {
            _ = launchctl(["bootstrap", "gui/\(getuid())", agentPlistURL.path])
            _ = launchctl(["kickstart", "gui/\(getuid())/\(agentLabel)"])
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executablePath)
            task.arguments = ["--background"]
            try? task.run()
        }
    }

    @discardableResult
    static func removeAgent() -> Bool {
        _ = launchctl(["bootout", "gui/\(getuid())/\(agentLabel)"])
        try? FileManager.default.removeItem(at: agentPlistURL)
        return true
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
