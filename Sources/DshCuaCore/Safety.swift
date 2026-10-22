import Foundation

/// Refuse to drive things that can hurt the user, mirroring the safety posture of
/// Codex's bundled CUA helper (which blocks terminal apps outright).
public enum Safety {
    /// Bundle ids we never send input to. Terminals can run arbitrary commands, and the
    /// security agent can change the machine's authorization state.
    public static let blockedBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "co.zeit.hyper",
        "com.apple.SecurityAgent",
        "com.apple.systempreferences",
        "com.apple.keychainaccess",
    ]

    public static var allowBlocked: Bool {
        ProcessInfo.processInfo.environment["DSH_CUA_ALLOW_BLOCKED"] == "1"
    }

    public static var dryRun: Bool {
        ProcessInfo.processInfo.environment["DSH_CUA_DRY_RUN"] == "1"
    }

    /// Throws unless the target may receive input.
    public static func assertInputAllowed(bundleId: String?, appName: String?) throws {
        guard !allowBlocked else { return }
        guard let bundleId, !bundleId.isEmpty else {
            // Without a bundle id we cannot prove the target is safe. Apps launched from
            // a path or a helper process land here; allow them but keep the check for
            // anything identifiable.
            return
        }
        if blockedBundleIds.contains(bundleId) {
            throw CuaError(
                .unsupported,
                "refusing to drive '\(appName ?? bundleId)': it is on the safety blocklist "
                    + "(terminals and security agents are never automated). "
                    + "Set DSH_CUA_ALLOW_BLOCKED=1 only if you fully understand the risk.",
                detail: ["bundleId": bundleId, "blocked": true]
            )
        }
    }

    /// AX roles that hold secrets. Typing into these would defeat the point of the field.
    public static let secureRoles: Set<String> = ["AXSecureTextField"]

    public static func assertNotSecure(role: String?, subrole: String?) throws {
        if let role, secureRoles.contains(role) {
            throw CuaError(
                .unsupported,
                "refusing to type into a secure text field (AXSecureTextField)",
                detail: ["role": role]
            )
        }
        if let subrole, subrole == "AXSecureTextField" {
            throw CuaError(.unsupported, "refusing to type into a secure text field", detail: ["subrole": subrole])
        }
    }
}
