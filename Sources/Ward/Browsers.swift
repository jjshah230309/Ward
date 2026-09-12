import Foundation
import AppKit
import ApplicationServices

// MARK: - Which browsers we know how to talk to

enum BrowserKind { case safari, chromium, firefox }

struct BrowserInfo: Sendable {
    let bundleID: String
    let name: String
    let kind: BrowserKind
}

enum Browsers {
    static let known: [String: BrowserInfo] = {
        var m: [String: BrowserInfo] = [:]
        func add(_ id: String, _ name: String, _ kind: BrowserKind) {
            m[id] = BrowserInfo(bundleID: id, name: name, kind: kind)
        }
        add("com.apple.Safari", "Safari", .safari)
        add("com.apple.SafariTechnologyPreview", "Safari Technology Preview", .safari)
        add("com.google.Chrome", "Chrome", .chromium)
        add("com.google.Chrome.canary", "Chrome Canary", .chromium)
        add("com.brave.Browser", "Brave", .chromium)
        add("com.microsoft.edgemac", "Edge", .chromium)
        add("company.thebrowser.Browser", "Arc", .chromium)
        add("company.thebrowser.dia", "Dia", .chromium)
        add("com.vivaldi.Vivaldi", "Vivaldi", .chromium)
        add("com.operasoftware.Opera", "Opera", .chromium)
        add("com.pushplaylabs.sidekick", "Sidekick", .chromium)
        add("ai.perplexity.comet", "Comet", .chromium)
        add("org.mozilla.firefox", "Firefox", .firefox)
        add("app.zen-browser.zen", "Zen", .firefox)
        add("org.mozilla.librewolf", "LibreWolf", .firefox)
        return m
    }()

    static func info(for bundleID: String?) -> BrowserInfo? {
        guard let bundleID else { return nil }
        return known[bundleID]
    }
}

// MARK: - Running AppleScript safely

/// NSAppleScript is not thread-safe, so every call is funnelled through one serial
/// queue, with a timeout so a wedged browser can never wedge Ward.
final class ScriptRunner {

    enum Outcome {
        case ok(String)
        case notPermitted        // user hasn't granted Automation for this app
        case notRunning
        case failed(Int, String)
        case timedOut
    }

    private let queue = DispatchQueue(label: "app.ward.applescript", qos: .userInitiated)

    /// On timeout the caller walks away while the script is still running, so the
    /// result can't live in a captured var — the late write would race the read.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Outcome = .timedOut
        func set(_ v: Outcome) { lock.lock(); value = v; lock.unlock() }
        func get() -> Outcome { lock.lock(); defer { lock.unlock() }; return value }
    }

    func run(_ source: String, timeout: TimeInterval = 4.0) -> Outcome {
        let box = Box()
        let sem = DispatchSemaphore(value: 0)

        queue.async {
            guard let script = NSAppleScript(source: source) else {
                box.set(.failed(-1, "could not compile")); sem.signal(); return
            }
            var errorDict: NSDictionary?
            let result = script.executeAndReturnError(&errorDict)
            if let e = errorDict {
                let code = (e[NSAppleScript.errorNumber] as? Int) ?? 0
                let msg = (e[NSAppleScript.errorMessage] as? String) ?? "unknown"
                switch code {
                case -1743, -10004: box.set(.notPermitted)
                case -600, -609:    box.set(.notRunning)
                default:            box.set(.failed(code, msg))
                }
            } else {
                box.set(.ok(result.stringValue ?? ""))
            }
            sem.signal()
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut { return .timedOut }
        return box.get()
    }
}

// MARK: - Reading the front tab

final class BrowserSense {

    private let runner = ScriptRunner()
    /// Remembered so the UI can show why nothing is being read.
    private(set) var automationDenied = Set<String>()
    /// Browsers where injecting JavaScript was refused. Without this the deep-reading
    /// toggle reads as on and working while Ward quietly judges on the title alone.
    private(set) var deepRefused: [String: String] = [:]
    struct DeepRead { var channel = ""; var text = "" }
    private var lastDeepURL = ""
    private var lastDeepResult = DeepRead()

    // The one-liner each family understands.
    private func readScript(_ info: BrowserInfo) -> String? {
        switch info.kind {
        case .safari:
            return """
            tell application id "\(info.bundleID)"
                try
                    if (count of windows) is 0 then return ""
                    set d to front document
                    return (URL of d) & linefeed & (name of d)
                on error
                    return ""
                end try
            end tell
            """
        case .chromium:
            return """
            tell application id "\(info.bundleID)"
                try
                    if (count of windows) is 0 then return ""
                    set t to active tab of front window
                    return (URL of t) & linefeed & (title of t)
                on error
                    return ""
                end try
            end tell
            """
        case .firefox:
            return nil   // Firefox exposes no scripting dictionary; Accessibility only.
        }
    }

    /// Best available reading of the front tab, degrading gracefully:
    /// AppleScript (exact URL) -> Accessibility (window title, and Firefox's URL bar).
    func read(pid: pid_t, info: BrowserInfo, deep: Bool) -> PageContext? {
        var ctx = PageContext()
        ctx.browserBundleID = info.bundleID
        ctx.browserName = info.name
        ctx.pid = pid

        if let script = readScript(info) {
            switch runner.run(script) {
            case .ok(let raw) where !raw.isEmpty:
                let parts = raw.components(separatedBy: "\n")
                ctx.rawURL = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                ctx.title = parts.dropFirst().joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ctx.source = .automation
                automationDenied.remove(info.bundleID)
            case .notPermitted:
                automationDenied.insert(info.bundleID)
            case .ok, .notRunning, .failed, .timedOut:
                break
            }
        }

        // Fill the gaps from the accessibility tree.
        if ctx.rawURL.isEmpty || ctx.title.isEmpty {
            if let axTitle = Accessibility.frontWindowTitle(pid: pid),
               ctx.title.isEmpty {
                ctx.title = axTitle
            }
            if ctx.rawURL.isEmpty,
               let bar = Accessibility.addressBarValue(pid: pid) {
                ctx.rawURL = bar.contains("://") ? bar : "https://" + bar
            }
        }

        if ctx.rawURL.isEmpty && ctx.title.isEmpty { return nil }

        if deep, !ctx.rawURL.isEmpty {
            let read = deepRead(info, url: ctx.rawURL)
            ctx.metadata = read.text
            ctx.channel = read.channel
        }
        return ctx
    }

    // MARK: Page metadata via injected JavaScript

    /// Only pages that declare themselves to be about a piece of content (og:type
    /// video or article) get their description read. On a homepage or a search page
    /// the same tags describe the *site* — YouTube's say "enjoy the videos and music
    /// you love" — and judging that blocked a search for a maths video before any
    /// video had been chosen.
    /// Returns the channel on the first line and everything else on the second, so
    /// the publisher stays an exact string rather than becoming words in a haystack.
    private static let metadataJS = """
    (function(){function m(n){var e=document.querySelector('meta[property="'+n+'"]')||document.querySelector('meta[name="'+n+'"]');return e&&e.content?e.content:''}var ty=m('og:type');if(ty.indexOf('video')!==0&&ty.indexOf('article')!==0)return '';var t=[];var q=document.querySelectorAll('meta[property="og:video:tag"]');for(var i=0;i<q.length&&i<25;i++){t.push(q[i].content)}var out=[m('og:title'),m('og:description').slice(0,400),t.join(', '),m('keywords').slice(0,300)];var c=document.querySelector('ytd-channel-name a, #owner a.yt-simple-endpoint, link[itemprop=\"name\"]');var name=c?(c.textContent||c.getAttribute('content')||'').trim():'';return name+"\\n"+out.filter(Boolean).join(' . ')})()
    """

    private func deepRead(_ info: BrowserInfo, url: String) -> DeepRead {
        // Metadata only changes when the page does, and injecting JS is the expensive
        // part of a poll, so one read per URL is plenty.
        if url == lastDeepURL { return lastDeepResult }

        let js = ScriptRunner.escapeForAppleScript(Self.metadataJS)
        let source: String
        switch info.kind {
        case .safari:
            source = """
            tell application id "\(info.bundleID)"
                try
                    return do JavaScript "\(js)" in front document
                on error
                    return ""
                end try
            end tell
            """
        case .chromium:
            source = """
            tell application id "\(info.bundleID)"
                try
                    return execute front window's active tab javascript "\(js)"
                on error
                    return ""
                end try
            end tell
            """
        case .firefox:
            return DeepRead()
        }

        var text = ""
        switch runner.run(source, timeout: 3.0) {
        case .ok(let raw):
            text = raw
            deepRefused.removeValue(forKey: info.bundleID)
        case .notPermitted:
            deepRefused[info.bundleID] = "Automation is denied for \(info.name)."
        case .failed:
            // Overwhelmingly this is "Allow JavaScript from Apple Events" being off;
            // the browser refuses the injection rather than returning nothing.
            deepRefused[info.bundleID] =
                "\(info.name) won't run JavaScript from another app. Turn on "
                + "\u{201C}Allow JavaScript from Apple Events\u{201D} in its Develop menu."
        case .notRunning, .timedOut:
            break
        }
        // First line is the channel, the rest is everything the model reads.
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let read = DeepRead(
            channel: parts.first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "",
            text: parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        lastDeepURL = url
        lastDeepResult = read
        return read
    }

    // MARK: Acting on the front tab

    @discardableResult
    func redirect(_ info: BrowserInfo, to target: String) -> Bool {
        let t = ScriptRunner.escapeForAppleScript(target)
        let source: String
        switch info.kind {
        case .safari:
            source = "tell application id \"\(info.bundleID)\" to set URL of front document to \"\(t)\""
        case .chromium:
            source = "tell application id \"\(info.bundleID)\" to set URL of active tab of front window to \"\(t)\""
        case .firefox:
            return false
        }
        if case .ok = runner.run(source) { lastDeepURL = ""; return true }
        return false
    }

    @discardableResult
    func closeTab(_ info: BrowserInfo) -> Bool {
        let source: String
        switch info.kind {
        case .safari:
            source = "tell application id \"\(info.bundleID)\" to close front document"
        case .chromium:
            source = "tell application id \"\(info.bundleID)\" to close active tab of front window"
        case .firefox:
            return false
        }
        if case .ok = runner.run(source) { lastDeepURL = ""; return true }
        return false
    }
}

extension ScriptRunner {
    /// Only backslashes and double quotes need care — the payloads use single quotes.
    static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Accessibility fallback

enum Accessibility {

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// The accessibility API hands back an untyped CFTypeRef. Checking the type id
    /// before casting means a surprise from another process can't crash Ward.
    private static func asElement(_ raw: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func frontWindowTitle(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let raw = attribute(app, kAXFocusedWindowAttribute as String),
              let window = asElement(raw) else { return nil }
        return attribute(window, kAXTitleAttribute as String) as? String
    }

    /// Firefox has no AppleScript support, so the URL has to be lifted out of the
    /// address bar itself. Bounded search — the tree can be enormous.
    static func addressBarValue(pid: pid_t) -> String? {
        guard isTrusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let raw = attribute(app, kAXFocusedWindowAttribute as String),
              let window = asElement(raw) else { return nil }

        var frontier: [AXUIElement] = [window]
        var visited = 0
        for _ in 0..<8 {
            var next: [AXUIElement] = []
            for element in frontier {
                visited += 1
                if visited > 900 { return nil }

                if let role = attribute(element, kAXRoleAttribute as String) as? String,
                   role == kAXTextFieldRole as String,
                   let value = attribute(element, kAXValueAttribute as String) as? String {
                    let v = value.trimmingCharacters(in: .whitespaces)
                    if looksLikeURL(v) { return v }
                }
                if let kids = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
                    next.append(contentsOf: kids.prefix(60))
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return nil
    }

    private static func looksLikeURL(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(" "), s.count > 3 else { return false }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return true }
        guard let dot = s.firstIndex(of: "."), dot != s.startIndex else { return false }
        return s.range(of: #"^[\w.-]+\.[a-z]{2,}(/|$|\?|#)"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }
}
