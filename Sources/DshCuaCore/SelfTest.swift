import Foundation

/// Built-in self-test.
///
/// Why this exists instead of an XCTest target: this project must build on a machine
/// with only the Command Line Tools installed. CLT ships no `XCTest` module and no
/// `swift-testing`, so `swift test` cannot compile there at all. Rather than make the
/// test suite optional, the assertions live in the binary and run with
/// `dsh-cua selftest` — same checks, zero framework dependency, and it works everywhere
/// the binary itself works. CI runs both this and (when Xcode is present) `swift test`.
public enum SelfTest {
    public struct Outcome {
        public let passed: Int
        public let failed: Int
        public let failures: [String]

        public var json: J {
            .obj([
                ("ok", .b(failed == 0)),
                ("passed", .i(passed)),
                ("failed", .i(failed)),
                ("failures", .arr(failures.map { J.s($0) })),
            ])
        }
    }

    final class Harness {
        var passed = 0
        var failures: [String] = []

        func expect(_ condition: Bool, _ label: String) {
            if condition { passed += 1 } else { failures.append(label) }
        }

        func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) {
            expect(a == b, "\(label): expected \(b), got \(a)")
        }

        func expectThrows(_ label: String, _ code: CuaErrorCode? = nil, _ body: () throws -> Void) {
            do {
                try body()
                failures.append("\(label): expected a throw, but nothing was thrown")
            } catch let error as CuaError {
                if let code, error.code != code {
                    failures.append("\(label): expected \(code.rawValue), got \(error.code.rawValue)")
                } else {
                    passed += 1
                }
            } catch {
                failures.append("\(label): threw a non-CuaError: \(error)")
            }
        }
    }

    public static func run() -> Outcome {
        let h = Harness()

        // ---- Args ----
        if let args = try? Args(["click", "--app", "Safari", "--json", "--x", "10", "--y", "20", "extra"]) {
            h.expectEqual(args.command, "click", "args.command")
            h.expectEqual(args.str("app"), "Safari", "args --app")
            h.expectEqual(args.str("x"), "10", "args --x")
            h.expect(args.flag("json"), "args --json flag")
            h.expectEqual(args.positionals, ["extra"], "args positionals")
        } else {
            h.failures.append("args: basic parse failed")
        }

        if let args = try? Args(["get-app-state", "--app=com.apple.Safari", "--max-depth=5"]) {
            h.expectEqual(args.str("app"), "com.apple.Safari", "args --name=value form")
            h.expectEqual((try? args.int("max-depth")) ?? -1, 5, "args int option")
        } else {
            h.failures.append("args: equals form failed")
        }

        if let args = try? Args(["type-text", "--app", "Notes", "--submit", "--text", "hello"]) {
            h.expect(args.flag("submit"), "boolean flag does not swallow the next token")
            h.expectEqual(args.str("text"), "hello", "option after boolean flag")
        } else {
            h.failures.append("args: boolean flag ordering failed")
        }

        // An empty argv is not a parse error: the runner turns it into BAD_USAGE, and
        // `dsh-cua --help` needs to parse with no command at all.
        if let empty = try? Args([]) {
            h.expect(empty.command.isEmpty, "args: empty argv yields an empty command")
        } else {
            h.failures.append("args: empty argv should still parse")
        }
        if let helpOnly = try? Args(["--help"]) {
            h.expect(helpOnly.flag("help"), "args: --help with no command sets the help flag")
        } else {
            h.failures.append("args: --help alone should parse")
        }
        if let args = try? Args(["click", "--app", "Safari"]) {
            h.expectThrows("args: require() on a missing option", .badUsage) { _ = try args.require("element") }
        }
        if let args = try? Args(["scroll", "--dx", "abc"]) {
            h.expectThrows("args: non-numeric int", .badUsage) { _ = try args.int("dx") }
        }
        if let args = try? Args(["drag", "--from", "1,2", "--to", "3.5,4.5"]) {
            h.expectEqual(try? args.point("from"), CGPointLike(x: 1, y: 2), "args point parse")
            h.expectEqual(try? args.point("to"), CGPointLike(x: 3.5, y: 4.5), "args point parse (decimals)")
        }
        if let args = try? Args(["drag", "--from", "1"]) {
            h.expectThrows("args: malformed point", .badUsage) { _ = try args.point("from") }
        }

        // ---- Keycodes / modifiers ----
        h.expectEqual(Input.keycode(for: "return"), 36, "keycode return")
        h.expectEqual(Input.keycode(for: "space"), 49, "keycode space")
        h.expectEqual(Input.keycode(for: "escape"), 53, "keycode escape")
        h.expectEqual(Input.keycode(for: "left"), 123, "keycode left")
        h.expectEqual(Input.keycode(for: "a"), 0, "keycode a")
        h.expectEqual(Input.keycode(for: "A"), 0, "keycode uppercase maps to the same key")
        h.expect(Input.keycode(for: "definitely-not-a-key") == nil, "keycode unknown returns nil")

        h.expectEqual(try? Input.modifierFlags(for: ["cmd", "shift"]), [.maskCommand, .maskShift], "modifiers cmd+shift")
        h.expectEqual(try? Input.modifierFlags(for: ["opt"]), [.maskAlternate], "modifier opt")
        h.expectEqual(try? Input.modifierFlags(for: ["ctrl"]), [.maskControl], "modifier ctrl")
        h.expectEqual(try? Input.modifierFlags(for: []), [], "modifiers empty")
        h.expectThrows("modifier: unknown name", .badUsage) { _ = try Input.modifierFlags(for: ["hyper"]) }

        h.expectEqual(try? Input.mouseButton("left"), .left, "mouse left")
        h.expectEqual(try? Input.mouseButton("right"), .right, "mouse right")
        h.expectEqual(try? Input.mouseButton("middle"), .center, "mouse middle")
        h.expectThrows("mouse: unknown button", .badUsage) { _ = try Input.mouseButton("thumb") }

        h.expectEqual("abcdef".chunked(into: 2), ["ab", "cd", "ef"], "chunking even")
        h.expectEqual("abc".chunked(into: 10), ["abc"], "chunking smaller than size")
        h.expectEqual("abcd".chunked(into: 2), ["ab", "cd"], "chunking exact")

        // ---- Safety ----
        h.expectThrows("safety: Terminal is blocked", .unsupported) {
            try Safety.assertInputAllowed(bundleId: "com.apple.Terminal", appName: "Terminal")
        }
        h.expectThrows("safety: iTerm2 is blocked", .unsupported) {
            try Safety.assertInputAllowed(bundleId: "com.googlecode.iterm2", appName: "iTerm2")
        }
        do {
            try Safety.assertInputAllowed(bundleId: "com.apple.Safari", appName: "Safari")
            try Safety.assertInputAllowed(bundleId: nil, appName: "Unknown")
            h.passed += 2
        } catch {
            h.failures.append("safety: ordinary apps should be allowed, got \(error)")
        }
        h.expectThrows("safety: secure text field refused", .unsupported) {
            try Safety.assertNotSecure(role: "AXSecureTextField", subrole: nil)
        }
        do {
            try Safety.assertNotSecure(role: "AXTextField", subrole: nil)
            h.passed += 1
        } catch {
            h.failures.append("safety: ordinary text field should be allowed")
        }

        // ---- Envelope / exit codes ----
        if case .o(let pairs) = CuaError(.appNotFound, "nope", detail: ["hint": "try list-apps"]).json {
            h.expectEqual(pairs.count, 2, "error envelope has ok+error")
            h.expectEqual(pairs[0].0, "ok", "error envelope first key")
            if case .b(let ok) = pairs[0].1 { h.expect(!ok, "error envelope ok=false") } else {
                h.failures.append("error envelope ok must be a bool")
            }
            h.expectEqual(pairs[1].0, "error", "error envelope second key")
        } else {
            h.failures.append("error envelope must be an object")
        }

        h.expectEqual(CuaError(.badUsage, "").exitCode, .usage, "exit code BAD_USAGE")
        h.expectEqual(CuaError(.appNotFound, "").exitCode, .appNotFound, "exit code APP_NOT_FOUND")
        h.expectEqual(CuaError(.windowNotFound, "").exitCode, .appNotFound, "exit code WINDOW_NOT_FOUND")
        h.expectEqual(CuaError(.permissionDenied, "").exitCode, .permissionDenied, "exit code PERMISSION_DENIED")
        h.expectEqual(CuaError(.staleRef, "").exitCode, .staleRef, "exit code STALE_REF")
        h.expectEqual(CuaError(.timeout, "").exitCode, .timeout, "exit code TIMEOUT")
        h.expectEqual(CuaError(.focusChanged, "").exitCode, .focusChanged, "exit code FOCUS_CHANGED")

        // The MCP server branches on these strings; renaming one is a breaking change.
        h.expectEqual(CuaErrorCode.badUsage.rawValue, "BAD_USAGE", "code BAD_USAGE")
        h.expectEqual(CuaErrorCode.appNotFound.rawValue, "APP_NOT_FOUND", "code APP_NOT_FOUND")
        h.expectEqual(CuaErrorCode.windowNotFound.rawValue, "WINDOW_NOT_FOUND", "code WINDOW_NOT_FOUND")
        h.expectEqual(CuaErrorCode.permissionDenied.rawValue, "PERMISSION_DENIED", "code PERMISSION_DENIED")
        h.expectEqual(CuaErrorCode.staleRef.rawValue, "STALE_REF", "code STALE_REF")
        h.expectEqual(CuaErrorCode.timeout.rawValue, "TIMEOUT", "code TIMEOUT")
        h.expectEqual(CuaErrorCode.focusChanged.rawValue, "FOCUS_CHANGED", "code FOCUS_CHANGED")
        h.expectEqual(CuaErrorCode.unsupported.rawValue, "UNSUPPORTED", "code UNSUPPORTED")
        h.expectEqual(CuaErrorCode.internal.rawValue, "INTERNAL", "code INTERNAL")

        // ---- JSON writer ----
        let a = JSONWriter.encode(.obj([("b", .i(2)), ("a", .i(1))]))
        let b = JSONWriter.encode(.obj([("a", .i(1)), ("b", .i(2))]))
        h.expectEqual(a, b, "JSON output is deterministic regardless of key order")
        h.expectEqual(a, #"{"a":1,"b":2}"#, "JSON key ordering")
        h.expectEqual(JSONWriter.encode(.obj([("x", .opt(String?.none))])), #"{"x":null}"#, "optional encodes as null")
        h.expectEqual(JSONWriter.encode(.obj([("x", .opt("y"))])), #"{"x":"y"}"#, "optional encodes as string")

        // ---- Focus guard ----
        let same1 = FrontmostSnapshot(bundleId: "com.apple.Safari", pid: 10, name: "Safari")
        let same2 = FrontmostSnapshot(bundleId: "com.apple.Safari", pid: 10, name: "Safari")
        let other = FrontmostSnapshot(bundleId: "com.apple.Terminal", pid: 11, name: "Terminal")
        h.expect(same1.sameFocus(as: same2), "focus: identical snapshots match")
        h.expect(!same1.sameFocus(as: other), "focus: different pids differ")
        let noPid1 = FrontmostSnapshot(bundleId: "com.apple.Safari", pid: nil, name: "Safari")
        let noPid2 = FrontmostSnapshot(bundleId: "com.apple.Safari", pid: nil, name: "Safari")
        h.expect(noPid1.sameFocus(as: noPid2), "focus: falls back to bundle id without a pid")

        // ---- doctor shape (must hold with or without TCC permissions) ----
        if case .o(let pairs) = Runner.doctor() {
            let keys = Set(pairs.map { $0.0 })
            for expected in ["ok", "macos", "binary", "permissions", "permissionHints", "screenRecordingApi"] {
                h.expect(keys.contains(expected), "doctor exposes '\(expected)'")
            }
        } else {
            h.failures.append("doctor must return an object")
        }

        return Outcome(passed: h.passed, failed: h.failures.count, failures: h.failures)
    }
}
