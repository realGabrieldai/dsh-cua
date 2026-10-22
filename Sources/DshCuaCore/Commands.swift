import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum Runner {
    /// Entry point used by both the CLI and the tests.
    public static func run(argv: [String]) async -> Int32 {
        let args: Args
        do {
            args = try Args(argv)
        } catch let error as CuaError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            print(JSONWriter.encode(error.json))
            return error.exitCode.rawValue
        } catch {
            print(JSONWriter.encode(CuaError(.internal, "\(error)").json))
            return ExitCode.other.rawValue
        }

        if args.flag("help") || args.flag("h") || args.command == "help" {
            print(helpText)
            return ExitCode.ok.rawValue
        }
        if args.command.isEmpty {
            FileHandle.standardError.write(Data("missing command\n".utf8))
            print(JSONWriter.encode(CuaError(.badUsage, "missing command", detail: ["hint": "run `dsh-cua --help`"]).json))
            return ExitCode.usage.rawValue
        }
        if args.command == "--version" || args.flag("version") {
            print("dsh-cua 1.0.0")
            return ExitCode.ok.rawValue
        }

        // `selftest` replaces `swift test` on CLT-only machines (no XCTest module).
        if args.command == "selftest" {
            let outcome = SelfTest.run()
            emit(outcome.json, pretty: !args.flag("json"))
            return outcome.failed == 0 ? ExitCode.ok.rawValue : ExitCode.other.rawValue
        }

        do {
            let payload = try await dispatch(args)
            emit(payload, pretty: !args.flag("json"))
            return ExitCode.ok.rawValue
        } catch let error as CuaError {
            if !args.flag("quiet") {
                FileHandle.standardError.write(Data((error.description + "\n").utf8))
            }
            emit(error.json, pretty: !args.flag("json"))
            return error.exitCode.rawValue
        } catch {
            let wrapped = CuaError(.internal, "\(error)")
            if !args.flag("quiet") {
                FileHandle.standardError.write(Data((wrapped.description + "\n").utf8))
            }
            emit(wrapped.json, pretty: !args.flag("json"))
            return ExitCode.other.rawValue
        }
    }

    private static func emit(_ payload: J, pretty: Bool) {
        let encoded = JSONWriter.encode(payload)
        if pretty, let data = encoded.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(
               withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
           ),
           let text = String(data: prettyData, encoding: .utf8) {
            print(text)
        } else {
            print(encoded)
        }
    }

    // MARK: - Focus guard

    /// Runs a command body and proves afterwards that the frontmost application did not
    /// change. See CONTRACT.md §0.4 — a focus steal is a hard failure.
    private static func guarded(_ body: () async throws -> J) async throws -> J {
        let before = FrontmostSnapshot.capture()
        var payload = try await body()
        let after = FrontmostSnapshot.capture()

        // focusChangeRequested is only ever set by an explicit --activate, in which case the
        // caller asked for the change; failing here would hide the one fact they need.
        if !before.sameFocus(as: after), !FocusGuard.focusChangeRequested {
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

        if case .o(var pairs) = payload {
            if FocusGuard.focusChangeRequested {
                pairs.append(("activated", .b(true)))
                pairs.append(("focusChanged", .b(!before.sameFocus(as: after))))
            }
            pairs.append(("frontmostApp", .obj([
                ("bundleId", .opt(after.bundleId)),
                ("pid", after.pid.map { J.i(Int($0)) } ?? .n),
                ("name", .opt(after.name)),
                ("unchanged", .b(true)),
            ])))
            payload = .o(pairs)
        }
        return payload
    }

    // MARK: - Dispatch

    private static func dispatch(_ args: Args) async throws -> J {
        switch args.command {
        case "doctor":
            return try await guarded { doctor() }
        case "request-permission":
            return try await guarded { requestPermission() }
        case "list-apps":
            return try await guarded { listApps(args) }
        case "list-windows":
            return try await guarded { try listWindows(args) }
        case "get-app-state":
            return try await guarded { try await getAppState(args) }
        case "click":
            return try await guarded { try click(args) }
        case "type-text":
            return try await guarded { try typeText(args) }
        case "press-key":
            return try await guarded { try pressKey(args) }
        case "scroll":
            return try await guarded { try scroll(args) }
        case "drag":
            return try await guarded { try drag(args) }
        default:
            throw CuaError(.badUsage, "unknown command '\(args.command)'", detail: ["hint": "run `dsh-cua --help`"])
        }
    }

    // MARK: - Commands

    static func doctor() -> J {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = "\(v.majorVersion).\(v.minorVersion)"
        let binary = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "dsh-cua"
        let ax = AX.isTrusted
        let screen = Capture.hasPermission
        return .obj([
            ("ok", .b(true)),
            ("macos", .s(version)),
            ("binary", .s(binary)),
            ("permissions", .obj([
                ("accessibility", .b(ax)),
                ("screenRecording", .b(screen)),
            ])),
            ("permissionHints", .obj([
                ("accessibility", .s("System Settings → Privacy & Security → Accessibility")),
                ("screenRecording", .s("System Settings → Privacy & Security → Screen & System Audio Recording")),
            ])),
            ("screenRecordingApi", .s("SCScreenshotManager")),
            ("dryRun", .b(Safety.dryRun)),
        ])
    }

    /// Triggers the macOS permission prompts instead of making the user hunt through
    /// System Settings. Accessibility uses `AXIsProcessTrustedWithOptions(prompt: true)`;
    /// Screen Recording uses `CGRequestScreenCaptureAccess()`.
    ///
    /// Note for users: macOS attributes the grant to the *responsible process*, so if this
    /// binary was launched by a host app, granting that host is usually what actually
    /// sticks. That is why the payload reports both what was requested and what is true now.
    static func requestPermission() -> J {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trustedNow = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        let screenAlready = Capture.hasPermission
        if !screenAlready {
            Capture.requestPermission()
        }

        return .obj([
            ("ok", .b(true)),
            ("requested", .obj([
                ("accessibility", .b(true)),
                ("screenRecording", .b(!screenAlready)),
            ])),
            ("permissionsNow", .obj([
                ("accessibility", .b(trustedNow)),
                ("screenRecording", .b(Capture.hasPermission)),
            ])),
            ("settings", .obj([
                ("accessibility", .s("System Settings → Privacy & Security → Accessibility")),
                ("screenRecording", .s("System Settings → Privacy & Security → Screen & System Audio Recording")),
            ])),
            ("note", .s(
                "If no dialog appeared, the permission was already decided; toggle it manually in the "
                    + "System Settings pane above. macOS may attribute the grant to the app that launched "
                    + "this binary, so grant that app too if the binary itself does not stick."
            )),
        ])
    }

    static func listApps(_ args: Args) -> J {
        let apps = Apps.list(includeAll: args.flag("all"))
        return .obj([
            ("ok", .b(true)),
            ("apps", .arr(apps.map { $0.json })),
        ])
    }

    static func listWindows(_ args: Args) throws -> J {
        var pid: pid_t?
        var appName: String?
        if let spec = args.str("app") {
            let app = try Apps.resolve(spec)
            pid = app.pid
            appName = app.name
        }
        let windows = Windows.list(pid: pid)
        let focusedId = pid.flatMap { focusedWindowId(pid: $0) }
        return .obj([
            ("ok", .b(true)),
            ("app", appName.map { J.s($0) } ?? .n),
            ("windows", .arr(windows.map { w in
                var pairs: [(String, J)] = []
                if case .o(let inner) = w.json { pairs = inner }
                pairs.append(("focused", .b(focusedId == w.id)))
                return .obj(pairs)
            })),
        ])
    }

    static func getAppState(_ args: Args) async throws -> J {
        let app = try Apps.resolve(try args.require("app"))
        let maxDepth = try args.int("max-depth", default: 12)
        let maxNodes = try args.int("max-nodes", default: 1500)

        let walk = try AXTree.walk(pid: app.pid, maxDepth: maxDepth, maxNodes: maxNodes)
        AXTree.saveSnapshot(pid: app.pid, index: walk.index)

        let windows = Windows.list(pid: app.pid)
        let focusedId = focusedWindowId(pid: app.pid)

        var windowsJson: [J] = windows.map { w in
            .obj([
                ("id", .i(Int(w.id))),
                ("title", .opt(w.title)),
                ("focused", .b(focusedId == w.id)),
                ("bounds", .obj([("x", .d(w.x)), ("y", .d(w.y)), ("w", .d(w.w)), ("h", .d(w.h))])),
            ])
        }

        var screenshotJson: J = .n
        if let path = args.str("screenshot") {
            let requested = args.str("window").flatMap { UInt32($0) }
            guard let targetId = requested ?? focusedId ?? windows.first?.id else {
                throw CuaError(.windowNotFound, "app '\(app.name)' has no capturable window")
            }
            let shot = try await Capture.window(id: CGWindowID(targetId), to: path)
            screenshotJson = .obj([
                ("path", .s(shot.path)),
                ("width", .i(shot.width)),
                ("height", .i(shot.height)),
                ("windowId", .i(Int(shot.windowId))),
                ("scale", .d(shot.scale)),
            ])
        }

        if windowsJson.isEmpty { windowsJson = [] }

        return .obj([
            ("ok", .b(true)),
            ("app", .obj([
                ("name", .s(app.name)),
                ("bundleId", .opt(app.bundleId)),
                ("pid", .i(Int(app.pid))),
            ])),
            ("windows", .arr(windowsJson)),
            ("tree", .arr(walk.roots.map { $0.json })),
            ("stats", .obj([
                ("nodes", .i(walk.nodes)),
                ("truncated", .b(walk.truncated)),
                ("maxDepth", .i(walk.maxDepth)),
            ])),
            ("screenshot", screenshotJson),
        ])
    }

    static func click(_ args: Args) throws -> J {
        let app = try Apps.resolve(try args.require("app"))
        try Safety.assertInputAllowed(bundleId: app.bundleId, appName: app.name)
        _ = try Safety.activateIfRequested(pid: app.pid, args: args)
        let button = try Input.mouseButton(args.str("button") ?? "left")
        let count = try args.int("count", default: 1)

        var target: J = .n
        var method = "cg-event"
        var point: CGPointLike

        if let ref = args.str("element") {
            let resolved = try AXTree.resolve(ref: ref, pid: app.pid)
            try Safety.assertNotSecure(
                role: AX.string(resolved.element, kAXRoleAttribute as String),
                subrole: AX.string(resolved.element, kAXSubroleAttribute as String)
            )
            point = CGPointLike(x: resolved.entry.cx, y: resolved.entry.cy)
            let actions = AX.actions(resolved.element)
            let role = AX.string(resolved.element, kAXRoleAttribute as String)
            let title = AX.string(resolved.element, kAXTitleAttribute as String)
            target = .obj([
                ("ref", .s(ref)),
                ("role", .opt(role)),
                ("title", .opt(title)),
                ("resolution", .s(resolved.method)),
            ])
            if let action = args.str("action") {
                // Arbitrary named AX action: this is how you drive things that have no
                // press — scroll areas (AXScrollDownByPage), expanders, tabs, etc.
                let available = AX.actions(resolved.element)
                guard available.contains(action) else {
                    throw CuaError(
                        .unsupported,
                        "element '\\(ref)' does not support action '\\(action)'",
                        detail: ["available": available.joined(separator: ", ")]
                    )
                }
                method = "ax-action:\(action)"
                if !Safety.dryRun { try AX.perform(resolved.element, action) }
            } else if actions.contains(kAXPressAction as String) {
                method = "ax-press"
                if !Safety.dryRun { try AX.perform(resolved.element, kAXPressAction as String) }
            } else if AX.isSettable(resolved.element, kAXValueAttribute as String) {
                method = "ax-set-value"
                // A click on a settable control means "focus it"; setting AXValue here
                // would destroy data, so fall through to a targeted click instead.
                method = "cg-event"
                if !Safety.dryRun { try Input.click(at: point, button: button, count: count, to: app.pid) }
            } else {
                if !Safety.dryRun { try Input.click(at: point, button: button, count: count, to: app.pid) }
            }
        } else {
            let x = try args.double("x")
            let y = try args.double("y")
            point = CGPointLike(x: x, y: y)
            let appElement = AXUIElementCreateApplication(app.pid)
            if let hit = AX.element(at: point, in: appElement) {
                let role = AX.string(hit, kAXRoleAttribute as String)
                let title = AX.string(hit, kAXTitleAttribute as String)
                try Safety.assertNotSecure(role: role, subrole: AX.string(hit, kAXSubroleAttribute as String))
                target = .obj([("role", .opt(role)), ("title", .opt(title))])
                if AX.actions(hit).contains(kAXPressAction as String) {
                    method = "ax-press"
                    if !Safety.dryRun { try AX.perform(hit, kAXPressAction as String) }
                } else if !Safety.dryRun {
                    try Input.click(at: point, button: button, count: count, to: app.pid)
                }
            } else if !Safety.dryRun {
                try Input.click(at: point, button: button, count: count, to: app.pid)
            }
        }

        return .obj([
            ("ok", .b(true)),
            ("app", .s(app.name)),
            ("target", target),
            ("point", .obj([("x", .d(point.x)), ("y", .d(point.y))])),
            ("method", .s(method)),
            ("dryRun", .b(Safety.dryRun)),
        ])
    }

    static func typeText(_ args: Args) throws -> J {
        let app = try Apps.resolve(try args.require("app"))
        try Safety.assertInputAllowed(bundleId: app.bundleId, appName: app.name)
        _ = try Safety.activateIfRequested(pid: app.pid, args: args)
        let text = try args.require("text")
        // Some controls are settable but only react to real typing. A search field that
        // filters as you type is the classic case: assigning AXValue updates the text but
        // the app never runs its search path, so the results silently do not change.
        // `--keystrokes` forces the event route.
        let forceKeystrokes = args.flag("keystrokes")

        var method = "cg-event"
        var target: J = .n
        var focused = false

        if let ref = args.str("element") {
            let resolved = try AXTree.resolve(ref: ref, pid: app.pid)
            let role = AX.string(resolved.element, kAXRoleAttribute as String)
            try Safety.assertNotSecure(role: role, subrole: AX.string(resolved.element, kAXSubroleAttribute as String))
            target = .obj([
                ("ref", .s(ref)),
                ("role", .opt(role)),
                ("title", .opt(AX.string(resolved.element, kAXTitleAttribute as String))),
            ])
            if !forceKeystrokes, AX.isSettable(resolved.element, kAXValueAttribute as String) {
                method = "ax-set-value"
                if !Safety.dryRun { try AX.setValue(resolved.element, text) }
            } else if !Safety.dryRun {
                // Key events only reach the key window's first responder, so ask the
                // accessibility API to focus the control first. It often works where a
                // posted click does not, and it never moves the user's cursor.
                focused = AX.setFocused(resolved.element)
                try Input.typeText(text, to: app.pid)
            }
        } else if !Safety.dryRun {
            try Input.typeText(text, to: app.pid)
        }

        // "Submit" should commit the field, and the accessibility action for that is
        // AXConfirm — which works without the app being frontmost. A Return keystroke only
        // reaches the field when the app is active and the field holds first responder, so
        // it is the fallback, not the default.
        var submitMethod = "none"
        if args.flag("submit"), !Safety.dryRun {
            var confirmed = false
            if let ref = args.str("element"),
               let resolved = try? AXTree.resolve(ref: ref, pid: app.pid),
               AX.actions(resolved.element).contains(kAXConfirmAction as String) {
                try AX.perform(resolved.element, kAXConfirmAction as String)
                submitMethod = "ax-confirm"
                confirmed = true
            }
            if !confirmed {
                try Input.tapKey("return", modifiers: [], to: app.pid)
                submitMethod = "cg-event-return"
            }
        }

        return .obj([
            ("ok", .b(true)),
            ("app", .s(app.name)),
            ("target", target),
            ("method", .s(method)),
            ("chars", .i(text.count)),
            ("axFocused", .b(focused)),
            ("submitMethod", .s(submitMethod)),
            ("dryRun", .b(Safety.dryRun)),
        ])
    }

    static func pressKey(_ args: Args) throws -> J {
        let app = try Apps.resolve(try args.require("app"))
        try Safety.assertInputAllowed(bundleId: app.bundleId, appName: app.name)
        _ = try Safety.activateIfRequested(pid: app.pid, args: args)
        let key = try args.require("key")
        let modifiers = try Input.modifierFlags(
            for: (args.str("modifiers") ?? "").split(separator: ",").map(String.init)
        )
        guard Input.keycode(for: key) != nil else {
            throw CuaError(.badUsage, "unknown key '\(key)'")
        }
        if !Safety.dryRun { try Input.tapKey(key, modifiers: modifiers, to: app.pid) }
        return .obj([
            ("ok", .b(true)),
            ("app", .s(app.name)),
            ("key", .s(key)),
            ("modifiers", .arr((args.str("modifiers") ?? "").split(separator: ",").map { J.s(String($0)) })),
            ("method", .s("cg-event")),
            ("dryRun", .b(Safety.dryRun)),
        ])
    }

    static func scroll(_ args: Args) throws -> J {
        let app = try Apps.resolve(try args.require("app"))
        try Safety.assertInputAllowed(bundleId: app.bundleId, appName: app.name)
        let dx = try args.int("dx", default: 0)
        let dy = try args.int("dy", default: 0)
        var point: CGPointLike?
        if args.str("x") != nil, args.str("y") != nil {
            point = CGPointLike(x: try args.double("x"), y: try args.double("y"))
        }
        if !Safety.dryRun { try Input.scroll(dx: dx, dy: dy, at: point, to: app.pid) }
        return .obj([
            ("ok", .b(true)),
            ("app", .s(app.name)),
            ("dx", .i(dx)),
            ("dy", .i(dy)),
            ("method", .s("cg-event")),
            ("dryRun", .b(Safety.dryRun)),
        ])
    }

    static func drag(_ args: Args) throws -> J {
        let app = try Apps.resolve(try args.require("app"))
        try Safety.assertInputAllowed(bundleId: app.bundleId, appName: app.name)
        let from = try args.point("from")
        let to = try args.point("to")
        let button = try Input.mouseButton(args.str("button") ?? "left")
        if !Safety.dryRun { try Input.drag(from: from, to: to, button: button, to: app.pid) }
        return .obj([
            ("ok", .b(true)),
            ("app", .s(app.name)),
            ("from", .obj([("x", .d(from.x)), ("y", .d(from.y))])),
            ("to", .obj([("x", .d(to.x)), ("y", .d(to.y))])),
            ("method", .s("cg-event")),
            ("dryRun", .b(Safety.dryRun)),
        ])
    }

    // MARK: - Helpers

    /// The CGWindowID of the app's focused AX window, matched by frame.
    static func focusedWindowId(pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let raw = AX.copy(appElement, kAXFocusedWindowAttribute as String) else { return nil }
        let focused = raw as! AXUIElement
        guard let pos = AX.point(focused, kAXPositionAttribute as String),
              let size = AX.size(focused, kAXSizeAttribute as String) else { return nil }
        for window in Windows.list(pid: pid) {
            if abs(window.x - pos.x) < 2, abs(window.y - pos.y) < 2,
               abs(window.w - Double(size.width)) < 2, abs(window.h - Double(size.height)) < 2 {
                return window.id
            }
        }
        return nil
    }
}
