import Foundation
import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts for correcting a verdict without leaving what you're watching.
///
/// Uses Carbon's `RegisterEventHotKey`, which asks the system to deliver exactly these
/// combinations and nothing else. A global keyboard monitor would work too, but it
/// would mean watching every keystroke you type anywhere — not a reasonable trade for
/// a convenience shortcut.
enum HotKeys {

    enum Action: UInt32, CaseIterable {
        case blockThis = 1
        case allowThis = 2
        case turnOn = 3
        case showWindow = 4

        var keyCode: UInt32 {
            switch self {
            case .blockThis:   return UInt32(kVK_ANSI_B)
            case .allowThis:   return UInt32(kVK_ANSI_A)
            case .turnOn:      return UInt32(kVK_ANSI_P)
            case .showWindow:  return UInt32(kVK_ANSI_W)
            }
        }
        var label: String {
            switch self {
            case .blockThis:   return "Block what I'm looking at"
            case .allowThis:   return "Allow what I'm looking at"
            case .turnOn:      return "Turn Ward back on"
            case .showWindow:  return "Open Ward's window"
            }
        }
        var display: String {
            switch self {
            case .blockThis:   return "\u{2303}\u{2325}\u{2318}B"
            case .allowThis:   return "\u{2303}\u{2325}\u{2318}A"
            case .turnOn:      return "\u{2303}\u{2325}\u{2318}P"
            case .showWindow:  return "\u{2303}\u{2325}\u{2318}W"
            }
        }
    }

    /// Control-Option-Command: three modifiers, so nothing in a browser or editor
    /// is likely to want the same combination.
    private static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let signature: OSType = 0x57415244   // 'WARD'

    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    static var isRegistered: Bool { !refs.isEmpty }

    static func register() {
        guard !isRegistered else { return }
        installHandlerIfNeeded()

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.rawValue)
            let status = RegisterEventHotKey(action.keyCode, modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr { refs.append(ref) }
        }
    }

    static func unregister() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    static func apply(enabled: Bool) {
        enabled ? register() : unregister()
    }

    // MARK: Dispatch

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let ok = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard ok == noErr, let action = Action(rawValue: id.id) else { return noErr }
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.perform(action) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @MainActor
    private static func perform(_ action: Action) {
        switch action {
        case .showWindow:
            // The guaranteed way back. With no Dock icon and no menu bar item there is
            // otherwise nothing to click, and reopening the app only activates it.
            AppDelegate.openDashboard()

        case .turnOn:
            let store = Store.shared
            guard !store.rules.isActive else {
                flash("Ward is already on", "There is no way to switch it off.")
                return
            }
            store.resume()
            flash("Ward is back on", "")

        case .blockThis, .allowThis:
            let result = Engine.shared.teach(action == .blockThis ? .shouldBlock : .shouldAllow)
            flash(result.headline, result.detail)
            // A correction that needs a decision deserves the window; a clean one doesn't.
            if !result.ok && !result.candidates.isEmpty { AppDelegate.openDashboard() }
        }
    }

    /// A brief confirmation, since the point of a hotkey is not having to look away.
    @MainActor
    private static func flash(_ title: String, _ detail: String) {
        Enforcer.shared.present(title: title, reason: detail,
                                rules: Store.shared.rules, chrome: false)
    }
}
