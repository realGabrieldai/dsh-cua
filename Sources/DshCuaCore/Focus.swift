import AppKit
import Foundation

/// The headline guarantee of this tool lives here.
///
/// Codex's CUA and every screenshot-loop agent tend to end up activating the app they
/// are driving, which yanks the user's screen out from under them. We never do that:
/// we record the frontmost application before a command does anything observable and
/// compare it afterwards. A difference is treated as a defect, not a warning.
public struct FrontmostSnapshot {
    public let bundleId: String?
    public let pid: pid_t?
    public let name: String?

    public init(bundleId: String?, pid: pid_t?, name: String?) {
        self.bundleId = bundleId
        self.pid = pid
        self.name = name
    }

    public static func capture() -> FrontmostSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return FrontmostSnapshot(bundleId: nil, pid: nil, name: nil)
        }
        return FrontmostSnapshot(
            bundleId: app.bundleIdentifier,
            pid: app.processIdentifier,
            name: app.localizedName
        )
    }

    /// Two snapshots are the "same focus" when the pid matches. Bundle id is a fallback
    /// for processes that report no pid.
    public func sameFocus(as other: FrontmostSnapshot) -> Bool {
        if let a = pid, let b = other.pid { return a == b }
        return bundleId == other.bundleId
    }

    public var json: J {
        .obj([
            ("bundleId", .opt(bundleId)),
            ("pid", pid.map { J.i(Int($0)) } ?? .n),
            ("name", .opt(name)),
        ])
    }
}

/// Wraps a command body so that focus is verified no matter which exit path is taken.
public enum FocusGuard {
    /// Runs `body`, then verifies the frontmost application did not change.
    /// On a change the caller gets a `FOCUS_CHANGED` error and exit code 7.
    public static func run(
        targetPid: pid_t?,
        _ body: () throws -> J
    ) throws -> J {
        let before = FrontmostSnapshot.capture()
        var payload = try body()
        let after = FrontmostSnapshot.capture()

        if !before.sameFocus(as: after) {
            throw CuaError(
                .focusChanged,
                "the frontmost application changed during the command "
                    + "(\(before.bundleId ?? before.name ?? "?") -> \(after.bundleId ?? after.name ?? "?")); "
                    + "this is a bug in dsh-cua, please report it",
                detail: [
                    "before": JSONWriter.encode(before.json),
                    "after": JSONWriter.encode(after.json),
                ]
            )
        }

        // Attach the frontmost-app report to every successful payload.
        if case .o(var pairs) = payload {
            pairs.append(("frontmostApp", .obj([
                ("bundleId", .opt(after.bundleId)),
                ("pid", after.pid.map { J.i(Int($0)) } ?? .n),
                ("unchanged", .b(true)),
            ])))
            payload = .o(pairs)
        }
        return payload
    }
}
