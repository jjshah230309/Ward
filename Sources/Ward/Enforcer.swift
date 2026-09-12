import Foundation
import AppKit
import SwiftUI

@MainActor
final class Enforcer {

    static let shared = Enforcer()

    /// Quitting any of these would break the machine or lock the user out of
    /// turning Ward off, so they are never eligible however the rules are edited.
    static let protectedBundleIDs: Set<String> = [
        "app.ward.Ward",
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systempreferences", "com.apple.SystemPreferences",
        "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Spotlight", "com.apple.universalaccessAuthWarn"
    ]

    private var shield: ShieldWindow?
    /// Stops a single stubborn page from being re-blocked every tick.
    private var recentlyHandled: [String: Date] = [:]
    private let cooldown: TimeInterval = 6

    func shouldSkip(_ signature: String) -> Bool {
        if let last = recentlyHandled[signature], Date().timeIntervalSince(last) < cooldown {
            return true
        }
        return false
    }

    /// Drops the cooldown for one page, so a correction takes effect immediately
    /// rather than waiting out the window from when it was last allowed.
    func forget(_ signature: String) { recentlyHandled.removeValue(forKey: signature) }

    private func markHandled(_ signature: String) {
        recentlyHandled[signature] = Date()
        if recentlyHandled.count > 60 {
            let cutoff = Date().addingTimeInterval(-cooldown * 4)
            recentlyHandled = recentlyHandled.filter { $0.value > cutoff }
        }
    }

    // MARK: Apps

    func enforce(app: NSRunningApplication, named name: String, action: AppAction, rules: Rules) {
        guard let bundleID = app.bundleIdentifier,
              !Self.protectedBundleIDs.contains(bundleID),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard !shouldSkip("app:" + bundleID) else { return }
        markHandled("app:" + bundleID)

        switch action {
        case .quit:
            app.terminate()
            // Some apps sit on a save dialog; give them a moment, then insist.
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let still = NSRunningApplication(processIdentifier: pid), !still.isTerminated {
                    still.forceTerminate()
                }
            }
        case .hide:
            app.hide()
        case .warn:
            break
        }

        present(title: name, reason: action == .warn ? "you asked me to flag this" : "blocked app",
                rules: rules)
        Store.shared.note(LogEntry(blocked: true, what: name, reason: "blocked app"))
    }

    // MARK: Web pages

    func enforce(page ctx: PageContext, info: BrowserInfo,
                 verdict: Verdict, sensor: Sensor, rules: Rules) {
        guard !shouldSkip(ctx.signature) else { return }
        markHandled(ctx.signature)

        // The shield and the log are immediate; the browser work is not, because
        // driving another application can stall and this runs on the main thread.
        present(title: ctx.label, reason: verdict.reason, rules: rules)
        Store.shared.note(LogEntry(blocked: true, what: ctx.label,
                                   reason: verdict.reason
                                        + (verdict.detail.isEmpty ? "" : " \u{2014} " + verdict.detail)))

        let pid = ctx.pid
        guard rules.browserAction != .hide else { Enforcer.hide(pid); return }

        sensor.act(rules.browserAction, info: info,
                   target: blockPageURL(for: ctx, verdict: verdict)) { handled in
            // Firefox has no scripting, and Automation may not be granted. Either way,
            // move the window out of the way instead.
            if !handled { Task { @MainActor in Enforcer.hide(pid) } }
        }
    }

    private static func hide(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    private func blockPageURL(for ctx: PageContext, verdict: Verdict) -> String {
        var comps = URLComponents(url: Store.blockPageURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "what", value: String(ctx.label.prefix(180))),
            URLQueryItem(name: "why", value: verdict.detail.isEmpty ? verdict.reason
                                                                    : "\(verdict.reason) — \(verdict.detail)")
        ]
        return comps?.url?.absoluteString ?? Store.blockPageURL.absoluteString
    }

    // MARK: The shield

    func present(title: String, reason: String, rules: Rules, chrome: Bool = true) {
        if chrome && rules.playSound { NSSound(named: NSSound.Name("Funk"))?.play() }
        let seconds = chrome ? rules.shieldSeconds : min(2.0, max(1.4, rules.shieldSeconds))
        guard seconds > 0 else { return }
        shield?.dismiss()
        let w = ShieldWindow(what: title, why: reason, blocking: chrome)
        shield = w
        w.show(for: seconds)
    }
}

// MARK: - Full-screen interruption

@MainActor
final class ShieldWindow {

    /// One window per screen. A block is an interruption, and an interruption that
    /// only lands on the main display is invisible to anyone working on the other one.
    private var windows: [NSWindow] = []
    private var timer: Timer?
    private var keyMonitor: Any?

    private let blocking: Bool

    init(what: String, why: String, blocking: Bool = true) {
        self.blocking = blocking
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        for screen in screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                         .stationary, .ignoresCycle]
            window.ignoresMouseEvents = false
            window.hasShadow = false
            window.alphaValue = 0
            window.setFrame(screen.frame, display: false)
            window.contentView = NSHostingView(
                rootView: ShieldView(what: what, why: why, blocking: blocking))
            windows.append(window)
        }
    }

    func show(for seconds: TimeInterval) {
        for window in windows {
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 1
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return nil }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for window in windows {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                window.animator().alphaValue = 0
            } completionHandler: { window.orderOut(nil) }
        }
    }
}

private struct ShieldView: View {
    let what: String
    let why: String
    var blocking: Bool = true
    @State private var appeared = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(blocking ? 0.82 : 0.62))
                .background(.ultraThinMaterial)

            VStack(spacing: 18) {
                Image(systemName: "hand.raised.fill")
                    .wardFont(46, weight: .medium)
                    .foregroundStyle(.orange)
                    .symbolRenderingMode(.hierarchical)

                Text("Not right now.")
                    .wardFont(40, weight: .semibold, design: .rounded)
                    .foregroundStyle(.white)

                Text(what)
                    .wardFont(16, weight: .regular)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 560)

                Text(blocking ? why.uppercased() : "")
                    .wardFont(11, weight: .semibold)
                    .tracking(1.4)
                    .foregroundStyle(.orange.opacity(0.9))
                    .padding(.top, 2)

                Text("esc to dismiss")
                    .wardFont(11)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 14)
            }
            .padding(48)
            .scaleEffect(appeared ? 1 : 0.94)
            .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { appeared = true }
        }
    }
}
