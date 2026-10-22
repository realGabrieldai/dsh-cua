import Foundation

// MARK: - Error taxonomy (CONTRACT.md §2)

/// Stable machine-readable error codes. The string values are part of the public
/// interface: the MCP server and downstream agents branch on them, so never rename.
public enum CuaErrorCode: String {
    case badUsage = "BAD_USAGE"
    case appNotFound = "APP_NOT_FOUND"
    case windowNotFound = "WINDOW_NOT_FOUND"
    case permissionDenied = "PERMISSION_DENIED"
    case staleRef = "STALE_REF"
    case timeout = "TIMEOUT"
    case focusChanged = "FOCUS_CHANGED"
    case unsupported = "UNSUPPORTED"
    case `internal` = "INTERNAL"
}

/// Process exit codes (CONTRACT.md §2).
public enum ExitCode: Int32 {
    case ok = 0
    case usage = 2
    case appNotFound = 3
    case permissionDenied = 4
    case staleRef = 5
    case timeout = 6
    case focusChanged = 7
    case other = 1
}

public struct CuaError: Error, CustomStringConvertible {
    public let code: CuaErrorCode
    public let message: String
    public let detail: [String: Any]

    public init(_ code: CuaErrorCode, _ message: String, detail: [String: Any] = [:]) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public var description: String { "\(code.rawValue): \(message)" }

    public var exitCode: ExitCode {
        switch code {
        case .badUsage: return .usage
        case .appNotFound, .windowNotFound: return .appNotFound
        case .permissionDenied: return .permissionDenied
        case .staleRef: return .staleRef
        case .timeout: return .timeout
        case .focusChanged: return .focusChanged
        case .unsupported, .internal: return .other
        }
    }

    public var json: J {
        var pairs: [(String, J)] = [("code", .s(code.rawValue)), ("message", .s(message))]
        if !detail.isEmpty { pairs.append(("detail", J.fromAny(detail))) }
        return .obj([("ok", .b(false)), ("error", .obj(pairs))])
    }
}

// MARK: - JSON helpers

/// Minimal JSON value type so command implementations can build their payload
/// declaratively without `Any` gymnastics.
public enum J: Encodable {
    case s(String)
    case i(Int)
    case d(Double)
    case b(Bool)
    case n
    case a([J])
    case o([(String, J)])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .s(let v): try c.encode(v)
        case .i(let v): try c.encode(v)
        case .d(let v): try c.encode(v)
        case .b(let v): try c.encode(v)
        case .n: try c.encodeNil()
        case .a(let v): try c.encode(v)
        case .o(let pairs):
            var k = encoder.container(keyedBy: DynKey.self)
            for (key, value) in pairs { try k.encode(value, forKey: DynKey(key)) }
        }
    }

    static func obj(_ pairs: [(String, J)]) -> J { .o(pairs) }
    static func arr(_ items: [J]) -> J { .a(items) }
    static func opt(_ value: String?) -> J { value.map { J.s($0) } ?? .n }
    static func opt(_ value: Int?) -> J { value.map { J.i($0) } ?? .n }
    static func opt(_ value: Bool?) -> J { value.map { J.b($0) } ?? .n }

    /// Bridges loosely-typed `detail` dictionaries into the typed tree.
    public static func fromAny(_ value: Any) -> J {
        switch value {
        case let s as String: return .s(s)
        case let b as Bool: return .b(b)
        case let i as Int: return .i(i)
        case let d as Double: return .d(d)
        case let a as [Any]: return .a(a.map { fromAny($0) })
        case let o as [String: Any]:
            return .o(o.map { ($0.key, fromAny($0.value)) }.sorted { $0.0 < $1.0 })
        default: return .n
        }
    }
}

struct DynKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public enum JSONWriter {
    /// Deterministic, key-sorted, non-pretty JSON on one line — one object per run.
    public static func encode(_ value: J) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":{"code":"INTERNAL","message":"failed to encode JSON"}}"#
        }
        return s
    }
}
