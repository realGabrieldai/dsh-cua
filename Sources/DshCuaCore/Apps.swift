import AppKit
import CoreGraphics
import Foundation

public struct AppInfo {
    public let name: String
    public let bundleId: String?
    public let pid: pid_t
    public let active: Bool
    public let hidden: Bool
    public let windowCount: Int

    public var json: J {
        .obj([
            ("name", .s(name)),
            ("bundleId", .opt(bundleId)),
            ("pid", .i(Int(pid))),
            ("active", .b(active)),
            ("hidden", .b(hidden)),
            ("windowCount", .i(windowCount)),
        ])
    }
}

public struct WindowInfo {
    public let id: CGWindowID
    public let pid: pid_t
    public let app: String
    public let title: String?
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public let layer: Int
    public let onScreen: Bool

    public var json: J {
        .obj([
            ("id", .i(Int(id))),
            ("pid", .i(Int(pid))),
            ("app", .s(app)),
            ("title", .opt(title)),
            ("bounds", .obj([("x", .d(x)), ("y", .d(y)), ("w", .d(w)), ("h", .d(h))])),
            ("layer", .i(layer)),
            ("onScreen", .b(onScreen)),
        ])
    }
}

public enum Apps {
    /// Every running application with a real UI, frontmost first then alphabetical.
    public static func list(includeAll: Bool = false) -> [AppInfo] {
        let windowsByPid = Dictionary(grouping: Windows.list(pid: nil), by: { $0.pid })
        var out: [AppInfo] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName else { continue }
            let count = windowsByPid[app.processIdentifier]?.count ?? 0
            let regular = app.activationPolicy == .regular
            if !includeAll && !regular { continue }
            if !includeAll && count == 0 && !app.isActive { continue }
            out.append(
                AppInfo(
                    name: name,
                    bundleId: app.bundleIdentifier,
                    pid: app.processIdentifier,
                    active: app.isActive,
                    hidden: app.isHidden,
                    windowCount: count
                )
            )
        }
        return out.sorted { a, b in
            if a.active != b.active { return a.active }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Resolves a contract target: `com.apple.Safari`, `pid:501`, or `Safari`.
    public static func resolve(_ spec: String) throws -> AppInfo {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CuaError(.badUsage, "empty --app target") }

        if trimmed.lowercased().hasPrefix("pid:") {
            guard let pid = pid_t(trimmed.dropFirst(4)) else {
                throw CuaError(.badUsage, "--app pid:<n> requires a numeric pid")
            }
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                throw CuaError(.appNotFound, "no running application with pid \(pid)")
            }
            let count = Windows.list(pid: pid).count
            return AppInfo(
                name: app.localizedName ?? "pid:\(pid)",
                bundleId: app.bundleIdentifier,
                pid: pid,
                active: app.isActive,
                hidden: app.isHidden,
                windowCount: count
            )
        }

        let running = NSWorkspace.shared.runningApplications

        // Score every candidate rather than taking the first hit. On a localized macOS the
        // display name is not the English one ("访达" for Finder), so we also match the
        // bundle filename. Without this, `--app Finder` happily matched
        // "Adobe Content Synchronizer Finder Extension".
        var best: (app: NSRunningApplication, score: Int)?

        for app in running {
            var score = 0
            let bundleId = app.bundleIdentifier ?? ""
            let localized = app.localizedName ?? ""
            let file = app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
            let needle = trimmed.lowercased()

            if bundleId == trimmed { score = 100 }
            else if bundleId.lowercased() == needle { score = 90 }
            else if localized == trimmed { score = 80 }
            else if localized.lowercased() == needle { score = 70 }
            else if file.lowercased() == needle { score = 60 }
            else if localized.lowercased().hasPrefix(needle) { score = 40 }
            else if file.lowercased().hasPrefix(needle) { score = 35 }
            else if localized.lowercased().contains(needle) { score = 20 }
            else if file.lowercased().contains(needle) { score = 15 }

            guard score > 0 else { continue }
            // Real apps win over background helpers and extensions at equal score.
            if app.activationPolicy == .regular { score += 5 }
            if let current = best {
                if score > current.score { best = (app, score) }
            } else {
                best = (app, score)
            }
        }

        if let best { return info(for: best.app) }

        throw CuaError(
            .appNotFound,
            "no running application matches '\(trimmed)'",
            detail: ["hint": "use `dsh-cua list-apps --all` to see candidates"]
        )
    }

    private static func info(for app: NSRunningApplication) -> AppInfo {
        let pid = app.processIdentifier
        return AppInfo(
            name: app.localizedName ?? "pid:\(pid)",
            bundleId: app.bundleIdentifier,
            pid: pid,
            active: app.isActive,
            hidden: app.isHidden,
            windowCount: Windows.list(pid: pid).count
        )
    }
}

public enum Windows {
    /// Window list from CoreGraphics. Titles are only populated when Screen Recording is
    /// granted; everything else works without it.
    public static func list(pid: pid_t?) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var out: [WindowInfo] = []
        for entry in raw {
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let ownerPid = entry[kCGWindowOwnerPID as String] as? Int
            else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            // Layer 0 is the normal window plane; skip menu bars, docks, tooltips.
            if layer != 0 { continue }
            if let pid, pid_t(ownerPid) != pid { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "?"
            let title = entry[kCGWindowName as String] as? String
            var x = 0.0, y = 0.0, w = 0.0, h = 0.0
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] {
                x = boundsDict["X"] as? Double ?? 0
                y = boundsDict["Y"] as? Double ?? 0
                w = boundsDict["Width"] as? Double ?? 0
                h = boundsDict["Height"] as? Double ?? 0
            }
            if w <= 1 || h <= 1 { continue }
            out.append(
                WindowInfo(
                    id: CGWindowID(number),
                    pid: pid_t(ownerPid),
                    app: owner,
                    title: (title?.isEmpty ?? true) ? nil : title,
                    x: x, y: y, w: w, h: h,
                    layer: layer,
                    onScreen: true
                )
            )
        }
        return out.sorted { a, b in
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }
    }

    /// The window we treat as "the app's window": prefer the largest visible window, which
    /// is almost always the real document window rather than a palette or popover.
    public static func primary(for pid: pid_t) -> WindowInfo? {
        let candidates = list(pid: pid)
        return candidates.max { ($0.w * $0.h) < ($1.w * $1.h) }
    }
}
