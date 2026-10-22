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

        func build(_ element: AXUIElement, depth: Int) -> AXNode? {
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
                    pid: pid
                )
            }

            var kids: [AXNode] = []
            if depth < maxDepth {
                for child in AX.children(element) {
                    if counter >= maxNodes { truncated = true; break }
                    if let node = build(child, depth: depth + 1) { kids.append(node) }
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
            for child in AX.children(app) {
                if counter >= maxNodes { truncated = true; break }
                if let node = build(child, depth: 1) { roots.append(node) }
            }
        } else {
            for window in windowElements {
                if counter >= maxNodes { truncated = true; break }
                if let node = build(window, depth: 0) { roots.append(node) }
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
    /// invalid whenever the app redraws. Instead we remember where the element was and
    /// hit-test that point again, then verify role and title still match. A mismatch is
    /// a STALE_REF, never a blind click.
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
        guard let hit = AX.element(at: CGPointLike(x: entry.cx, y: entry.cy), in: app) else {
            throw CuaError(
                .staleRef,
                "nothing is under the remembered position of '\(ref)' any more",
                detail: ["ref": ref, "x": entry.cx, "y": entry.cy]
            )
        }
        let liveRole = AX.string(hit, kAXRoleAttribute as String)
        let liveTitle = AX.string(hit, kAXTitleAttribute as String)
        if let expected = entry.role, let live = liveRole, expected != live {
            throw CuaError(
                .staleRef,
                "element '\(ref)' changed role (\(expected) -> \(live)); the UI moved",
                detail: ["ref": ref, "expectedRole": expected, "liveRole": live]
            )
        }
        if let expected = entry.title, let live = liveTitle, expected != live {
            throw CuaError(
                .staleRef,
                "element '\(ref)' changed title; the UI moved",
                detail: ["ref": ref, "expectedTitle": expected, "liveTitle": live]
            )
        }
        return (hit, entry, "ax-hit-test")
    }
}
