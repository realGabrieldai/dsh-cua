import ApplicationServices
import CoreGraphics
import Foundation

/// Thin, throwing wrapper over the Accessibility API.
public enum AX {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Maps a raw AXError onto our taxonomy so callers can branch on it.
    public static func check(_ err: AXError, _ context: String) throws {
        switch err {
        case .success: return
        case .apiDisabled, .notImplemented where !AXIsProcessTrusted():
            throw CuaError(
                .permissionDenied,
                "Accessibility permission is not granted for this binary",
                detail: ["hint": "System Settings → Privacy & Security → Accessibility"]
            )
        case .apiDisabled:
            throw CuaError(
                .permissionDenied,
                "Accessibility API disabled for this process",
                detail: ["hint": "System Settings → Privacy & Security → Accessibility"]
            )
        case .invalidUIElement, .invalidUIElementObserver:
            throw CuaError(.staleRef, "the accessibility element is no longer valid (\(context))")
        case .cannotComplete:
            throw CuaError(.timeout, "the application did not respond to \(context)")
        default:
            throw CuaError(.internal, "accessibility error \(err.rawValue) during \(context)")
        }
    }

    public static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    public static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let v = copy(element, attribute) else { return nil }
        if let s = v as? String { return s.isEmpty ? nil : s }
        if CFGetTypeID(v) == CFNumberGetTypeID() { return "\(v)" }
        return nil
    }

    public static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return (v as? Bool)
    }

    public static func point(_ element: AXUIElement, _ attribute: String) -> CGPointLike? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return CGPointLike(x: Double(p.x), y: Double(p.y))
    }

    public static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let v = copy(element, attribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return s
    }

    public static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let v = copy(element, kAXChildrenAttribute as String) else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    public static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    /// Gives an element keyboard focus through the accessibility API.
    ///
    /// This is worth trying before posting keystrokes: macOS only routes key events to the
    /// key window's first responder, so a background app normally cannot be typed into.
    /// Setting AXFocused sometimes works where a posted click does not, and it never moves
    /// the user's cursor.
    @discardableResult
    public static func setFocused(_ element: AXUIElement) -> Bool {
        let err = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        return err == .success
    }

    public static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    public static func perform(_ element: AXUIElement, _ action: String) throws {
        try check(AXUIElementPerformAction(element, action as CFString), "AXUIElementPerformAction(\(action))")
    }

    public static func setValue(_ element: AXUIElement, _ value: String) throws {
        try check(
            AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString),
            "AXUIElementSetAttributeValue"
        )
    }

    /// Hit-test: which element is under this global point? This is what makes
    /// coordinate clicking safe — we turn a coordinate back into a real element and press
    /// it, instead of blindly synthesising a click that could land anywhere.
    public static func element(at point: CGPointLike, in app: AXUIElement) -> AXUIElement? {
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
        guard err == .success else { return nil }
        return hit
    }
}

// MARK: - Tree

public struct AXNode {
    public let ref: String
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let enabled: Bool?
    public let focused: Bool?
    public let frame: (x: Double, y: Double, w: Double, h: Double)?
    public let actions: [String]
    public var children: [AXNode]

    public var json: J {
        var pairs: [(String, J)] = [
            ("ref", .s(ref)),
            ("role", .opt(role)),
            ("subrole", .opt(subrole)),
            ("title", .opt(title)),
            ("value", .opt(value)),
            ("enabled", .opt(enabled)),
            ("focused", .opt(focused)),
            ("actions", .arr(actions.map { J.s($0) })),
        ]
        if let f = frame {
            pairs.append(("frame", .obj([("x", .d(f.x)), ("y", .d(f.y)), ("w", .d(f.w)), ("h", .d(f.h))])))
        } else {
            pairs.append(("frame", .n))
        }
        pairs.append(("children", .arr(children.map { $0.json })))
        return .obj(pairs)
    }
}

public struct AXWalkResult {
    public let roots: [AXNode]
    public let nodes: Int
    public let truncated: Bool
    public let maxDepth: Int
    /// ref -> (role, title, center point) for the click-by-ref path.
    public let index: [String: SnapshotEntry]
}

public struct SnapshotEntry: Codable {
    public let ref: String
    public let role: String?
    public let title: String?
    public let cx: Double
    public let cy: Double
    public let pid: pid_t
    /// Child-index path from the app's window array, e.g. [0, 3, 2] = windows[0] -> child 3 -> child 2.
    /// This is the primary re-resolution mechanism; hit-testing alone is not enough because
    /// `AXUIElementCopyElementAtPosition` returns the *container* for overlay controls
    /// (scrollbars, text fields), which would make every such ref look stale.
    public let path: [Int]
}

public enum AXTree {
    /// Depth- and node-limited walk. Children of uninteresting containers are still
    /// visited, but we stop descending once the budget is exhausted and say so.
    public static func walk(
        pid: pid_t,
        maxDepth: Int = 12,
        maxNodes: Int = 1500
    ) throws -> AXWalkResult {
        guard AX.isTrusted else {
            throw CuaError(
                .permissionDenied,
                "Accessibility permission is not granted for this binary",
                detail: [
                    "hint": "System Settings → Privacy & Security → Accessibility",
                    "binary": Bundle.main.executablePath ?? CommandLine.arguments.first ?? "dsh-cua",
                ]
            )
        }
        let app = AXUIElementCreateApplication(pid)

        var counter = 0
        var truncated = false
        var deepest = 0
        var index: [String: SnapshotEntry] = [:]

        func build(_ element: AXUIElement, depth: Int, path: [Int]) -> AXNode? {
            if counter >= maxNodes {
                truncated = true
                return nil
            }
            counter += 1
            deepest = max(deepest, depth)

            let ref = "e\(counter)"
            let role = AX.string(element, kAXRoleAttribute as String)
            let subrole = AX.string(element, kAXSubroleAttribute as String)
            let title = AX.string(element, kAXTitleAttribute as String)
            let valueRaw = AX.string(element, kAXValueAttribute as String)
            // Never leak the contents of password fields into the transcript.
            let value = (role == "AXSecureTextField") ? "<secure>" : valueRaw
            let enabled = AX.bool(element, kAXEnabledAttribute as String)
            let focused = AX.bool(element, kAXFocusedAttribute as String)
            let actions = AX.actions(element)

            var frame: (x: Double, y: Double, w: Double, h: Double)?
            if let pos = AX.point(element, kAXPositionAttribute as String),
               let size = AX.size(element, kAXSizeAttribute as String) {
                frame = (pos.x, pos.y, Double(size.width), Double(size.height))
                index[ref] = SnapshotEntry(
                    ref: ref, role: role, title: title,
                    cx: pos.x + Double(size.width) / 2,
                    cy: pos.y + Double(size.height) / 2,
                    pid: pid,
                    path: path
                )
            }

            var kids: [AXNode] = []
            if depth < maxDepth {
                let childElements = AX.children(element)
                for (childIndex, child) in childElements.enumerated() {
                    if counter >= maxNodes { truncated = true; break }
                    if let node = build(child, depth: depth + 1, path: path + [childIndex]) {
                        kids.append(node)
                    }
                }
            } else if !AX.children(element).isEmpty {
                truncated = true
            }

            return AXNode(
                ref: ref, role: role, subrole: subrole, title: title, value: value,
                enabled: enabled, focused: focused, frame: frame, actions: actions, children: kids
            )
        }

        var roots: [AXNode] = []
        // Prefer real windows so the tree starts at something meaningful.
        var windowElements = (AX.copy(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        if windowElements.isEmpty, let focusedWindow = AX.copy(app, kAXFocusedWindowAttribute as String) {
            windowElements = [focusedWindow as! AXUIElement]
        }
        if windowElements.isEmpty {
            for (childIndex, child) in AX.children(app).enumerated() {
                if counter >= maxNodes { truncated = true; break }
                if let node = build(child, depth: 1, path: [childIndex]) { roots.append(node) }
            }
        } else {
            for (windowIndex, window) in windowElements.enumerated() {
                if counter >= maxNodes { truncated = true; break }
                if let node = build(window, depth: 0, path: [windowIndex]) { roots.append(node) }
            }
        }

        return AXWalkResult(roots: roots, nodes: counter, truncated: truncated, maxDepth: deepest, index: index)
    }

    // MARK: Snapshot cache

    public static func cacheDirectory() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("dsh-cua", isDirectory: true)
    }

    public static func snapshotURL(pid: pid_t) -> URL {
        cacheDirectory().appendingPathComponent("snapshot-\(pid).json")
    }

    public static func saveSnapshot(pid: pid_t, index: [String: SnapshotEntry]) {
        let dir = cacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = index.values.sorted { $0.ref < $1.ref }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: snapshotURL(pid: pid), options: .atomic)
    }

    public static func loadSnapshot(pid: pid_t) -> [String: SnapshotEntry] {
        guard let data = try? Data(contentsOf: snapshotURL(pid: pid)),
              let list = try? JSONDecoder().decode([SnapshotEntry].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.ref, $0) })
    }

    /// Re-resolves a ref from the last snapshot into a live element.
    ///
    /// We deliberately do not cache AXUIElement references across processes: they go
    /// invalid whenever the app redraws. Two mechanisms, in order:
    ///
    /// 1. **Path walk** — replay the recorded child-index path from the app's window array.
    ///    This is the reliable one, and the reason it exists is that hit-testing is not
    ///    reliable: `AXUIElementCopyElementAtPosition` answers with the containing
    ///    `AXGroup` for overlay controls such as scrollbars and text fields.
    /// 2. **Hit test** — fall back to the remembered centre point, which still works for
    ///    plain leaf elements.
    ///
    /// Either way the live role and title must still match, so a moved UI yields
    /// `STALE_REF` rather than a click on the wrong control.
    public static func resolve(ref: String, pid: pid_t) throws -> (element: AXUIElement, entry: SnapshotEntry, method: String) {
        let snapshot = loadSnapshot(pid: pid)
        guard let entry = snapshot[ref] else {
            throw CuaError(
                .staleRef,
                "unknown element ref '\(ref)' for pid \(pid)",
                detail: ["hint": "run get-app-state again; refs are only valid until the next snapshot"]
            )
        }

        let app = AXUIElementCreateApplication(pid)

        if let element = resolveByPath(entry.path, app: app, entry: entry) {
            return (element, entry, "ax-path")
        }

        var mismatch = "the element could not be found again"
        if let hit = AX.element(at: CGPointLike(x: entry.cx, y: entry.cy), in: app) {
            let liveRole = AX.string(hit, kAXRoleAttribute as String)
            let liveTitle = AX.string(hit, kAXTitleAttribute as String)
            if rolesCompatible(entry.role, liveRole), titlesCompatible(entry.title, liveTitle) {
                return (hit, entry, "ax-hit-test")
            }
            mismatch = "the control at that position changed "
                + "(role \(entry.role ?? "?") -> \(liveRole ?? "?"))"
        }

        throw CuaError(
            .staleRef,
            "element '\(ref)' is no longer where it was: \(mismatch)",
            detail: ["ref": ref, "expectedRole": entry.role ?? "?", "path": entry.path.map(String.init).joined(separator: "/")]
        )
    }

    /// Walks `path` (window index, then child indices) and checks the result still matches.
    static func resolveByPath(_ path: [Int], app: AXUIElement, entry: SnapshotEntry) -> AXUIElement? {
        guard let windowIndex = path.first else { return nil }
        let windows = (AX.copy(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        guard windowIndex < windows.count else { return nil }

        var current = windows[windowIndex]
        for childIndex in path.dropFirst() {
            let children = AX.children(current)
            guard childIndex < children.count else { return nil }
            current = children[childIndex]
        }

        guard rolesCompatible(entry.role, AX.string(current, kAXRoleAttribute as String)) else { return nil }
        guard titlesCompatible(entry.title, AX.string(current, kAXTitleAttribute as String)) else { return nil }
        return current
    }

    /// `nil` on either side means "unknown", which we accept; otherwise it must be equal.
    static func rolesCompatible(_ expected: String?, _ live: String?) -> Bool {
        guard let expected else { return true }
        guard let live else { return false }
        return expected == live
    }

    static func titlesCompatible(_ expected: String?, _ live: String?) -> Bool {
        guard let expected else { return true }
        return expected == live
    }
}
