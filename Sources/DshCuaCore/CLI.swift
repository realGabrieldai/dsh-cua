import Foundation

/// Hand-rolled argument parser. Dependency-free on purpose: the whole point of this
/// binary is that it drops onto a machine and runs with no package manager involved.
public struct Args {
    public let command: String
    public var flags: Set<String> = []
    public var options: [String: String] = [:]
    public var positionals: [String] = []

    /// Options that take no value. Everything else of the form `--name` consumes the
    /// next token as its value, or uses `--name=value`.
    static let booleanFlags: Set<String> = [
        "json", "quiet", "help", "h", "submit", "all", "version",
    ]

    public init(_ argv: [String]) throws {
        var rest = argv
        // Allow the command to be omitted entirely so `dsh-cua --help` and
        // `dsh-cua --version` work without a subcommand.
        if let first = rest.first, !first.hasPrefix("-") {
            self.command = first
            rest.removeFirst()
        } else {
            self.command = ""
        }

        var i = 0
        while i < rest.count {
            let token = rest[i]
            i += 1
            guard token.hasPrefix("--") else {
                positionals.append(token)
                continue
            }
            let body = String(token.dropFirst(2))
            if let eq = body.firstIndex(of: "=") {
                options[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                continue
            }
            if Args.booleanFlags.contains(body) {
                flags.insert(body)
                continue
            }
            // Value-taking option: consume the next token if there is one and it is not
            // itself an option.
            if i < rest.count, !rest[i].hasPrefix("--") {
                options[body] = rest[i]
                i += 1
            } else {
                flags.insert(body)
            }
        }
    }

    public func flag(_ name: String) -> Bool { flags.contains(name) }

    public func str(_ name: String) -> String? { options[name] }

    public func require(_ name: String) throws -> String {
        guard let v = options[name], !v.isEmpty else {
            throw CuaError(.badUsage, "missing required option --\(name)")
        }
        return v
    }

    public func int(_ name: String, default def: Int? = nil) throws -> Int {
        guard let raw = options[name] else {
            if let def { return def }
            throw CuaError(.badUsage, "missing required option --\(name)")
        }
        guard let v = Int(raw) else {
            throw CuaError(.badUsage, "--\(name) must be an integer, got '\(raw)'")
        }
        return v
    }

    public func double(_ name: String) throws -> Double {
        let raw = try require(name)
        guard let v = Double(raw) else {
            throw CuaError(.badUsage, "--\(name) must be a number, got '\(raw)'")
        }
        return v
    }

    /// Parses `x,y`.
    public func point(_ name: String) throws -> CGPointLike {
        let raw = try require(name)
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            throw CuaError(.badUsage, "--\(name) must be 'x,y', got '\(raw)'")
        }
        return CGPointLike(x: x, y: y)
    }
}

/// A tiny geometry type so the parser and its tests stay free of CoreGraphics.
public struct CGPointLike: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public let helpText = """
dsh-cua — native macOS computer-use for DSH (never steals focus)

USAGE
  dsh-cua <command> [options]

COMMANDS
  doctor                     Report environment and macOS permissions (never fails hard)
  request-permission         Trigger the macOS Accessibility / Screen Recording prompts
  selftest                   Run the built-in assertion suite (no XCTest needed)
  list-apps                  List running applications (frontmost first)
  list-windows               List windows, optionally for one app
  get-app-state              Dump the accessibility tree and (optionally) one window screenshot
  click                      Press an element by ref, or click global coordinates
  type-text                  Set an element's value, or type unicode text
  press-key                  Post a single key with optional modifiers
  scroll                     Post scroll wheel events
  drag                       Post a mouse drag between two global points

COMMON OPTIONS
  --json                     Emit one JSON object on stdout
  --quiet                    Suppress non-essential stderr output
  --timeout-ms <n>           Operation timeout (default 15000)
  --help                     Show this help

TARGETS
  --app <target>             bundle id (com.apple.Safari) | pid:501 | app name (Safari)

get-app-state
  --app <target>             Required
  --screenshot <path>        Capture ONLY the target window to this PNG
  --window <id>              Capture this CGWindowID instead of the focused window
  --max-depth <n>            Accessibility tree depth limit (default 12)
  --max-nodes <n>            Accessibility tree node limit (default 1500)

click
  --app <target>             Required
  --element <ref>            Element ref from the last get-app-state for this pid
  --x <n> --y <n>            Global display coordinates (top-left origin)
  --button left|right|middle  (default left)
  --count <n>                Click count (default 1)

type-text
  --app <target>             Required
  --text <string>            Required
  --element <ref>            Set this element's AXValue directly (no focus change)
  --submit                   Post Return afterwards

press-key
  --app <target> --key <name> [--modifiers cmd,shift,opt,ctrl]

scroll
  --app <target> --dx <n> --dy <n> [--x <n> --y <n>]

drag
  --app <target> --from <x,y> --to <x,y> [--button left]

ENVIRONMENT
  DSH_CUA_BIN                Override binary path (used by the MCP server)
  DSH_CUA_DRY_RUN=1          Resolve the plan but perform no input
  DSH_CUA_ALLOW_BLOCKED=1    Override the terminal/security-agent blocklist (dangerous)

EXIT CODES
  0 ok · 1 other · 2 usage · 3 app/window not found · 4 permission denied
  5 stale ref · 6 timeout · 7 focus changed (a bug — please report it)
"""
