import CoreGraphics
import Foundation

/// Synthetic input, delivered *to a process* rather than to the global HID stream.
///
/// `CGEventPostToPid` routes the event into the target application's event queue. The
/// physical cursor does not move, the frontmost application does not change, and the
/// user's pointer is never hijacked mid-drag. This is the whole reason the tool can be
/// used while someone is working.
public enum Input {
    // MARK: Keycodes

    /// ANSI virtual keycodes. Exposed for tests.
    public static let keycodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 76, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
        "f11": 103, "f13": 105, "f16": 106, "f14": 107, "f10": 109, "f12": 111,
        "f15": 113, "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118,
        "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    public static func keycode(for name: String) -> CGKeyCode? {
        let key = name.lowercased()
        if let code = keycodes[key] { return code }
        // Single character fallback, including uppercase -> lowercase keycode.
        if key.count == 1 { return keycodes[key] }
        return nil
    }

    public static func modifierFlags(for names: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for raw in names {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "", "none": continue
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                throw CuaError(.badUsage, "unknown modifier '\(raw)' (use cmd,shift,opt,ctrl)")
            }
        }
        return flags
    }

    // MARK: Posting

    private static var source: CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    public static func post(_ event: CGEvent, to pid: pid_t) {
        // Deliberately postToPid, never post(tap:): the global HID tap would move the
        // user's cursor and can change the frontmost application.
        event.postToPid(pid)
    }

    public static func key(_ name: String, modifiers: CGEventFlags, to pid: pid_t, down: Bool) throws {
        guard let code = keycode(for: name) else {
            throw CuaError(.badUsage, "unknown key '\(name)'", detail: ["hint": "see `dsh-cua --help`"])
        }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            throw CuaError(.internal, "could not create keyboard event")
        }
        event.flags = modifiers
        post(event, to: pid)
    }

    public static func tapKey(_ name: String, modifiers: CGEventFlags, to pid: pid_t) throws {
        try key(name, modifiers: modifiers, to: pid, down: true)
        try key(name, modifiers: modifiers, to: pid, down: false)
    }

    /// Types a string as unicode key events. Used only when the Accessibility path
    /// (setting AXValue) is unavailable.
    public static func typeText(_ text: String, to pid: pid_t) throws {
        for chunk in text.chunked(into: 20) {
            let utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw CuaError(.internal, "could not create keyboard event")
            }
            utf16.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: buffer.baseAddress)
            }
            post(down, to: pid)
            post(up, to: pid)
        }
    }

    public static func mouseButton(_ name: String) throws -> CGMouseButton {
        switch name.lowercased() {
        case "left", "": return .left
        case "right": return .right
        case "middle", "center": return .center
        default: throw CuaError(.badUsage, "unknown mouse button '\(name)'")
        }
    }

    private static func mouseTypes(_ button: CGMouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
        switch button {
        case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .center: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        default: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        }
    }

    public static func click(
        at point: CGPointLike,
        button: CGMouseButton,
        count: Int,
        to pid: pid_t
    ) throws {
        let types = mouseTypes(button)
        for _ in 0..<max(1, count) {
            for type in [types.down, types.up] {
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                    mouseButton: button
                ) else {
                    throw CuaError(.internal, "could not create mouse event")
                }
                post(event, to: pid)
            }
        }
    }

    public static func scroll(dx: Int, dy: Int, at point: CGPointLike?, to pid: pid_t) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        ) else {
            throw CuaError(.internal, "could not create scroll event")
        }
        if let point {
            event.location = CGPoint(x: point.x, y: point.y)
        }
        post(event, to: pid)
    }

    public static func drag(
        from: CGPointLike,
        to: CGPointLike,
        button: CGMouseButton,
        to pid: pid_t,
        steps: Int = 12
    ) throws {
        let types = mouseTypes(button)
        func event(_ type: CGEventType, _ p: CGPointLike) throws -> CGEvent {
            guard let e = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: CGPoint(x: p.x, y: p.y),
                mouseButton: button
            ) else { throw CuaError(.internal, "could not create drag event") }
            return e
        }
        post(try event(types.down, from), to: pid)
        let n = max(1, steps)
        for i in 1...n {
            let t = Double(i) / Double(n)
            let p = CGPointLike(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(try event(types.drag, p), to: pid)
        }
        post(try event(types.up, to), to: pid)
    }
}

extension String {
    func chunked(into size: Int) -> [String] {
        guard size > 0, count > size else { return [self] }
        var out: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if current.count >= size { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
