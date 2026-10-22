# dsh-cua MCP server

Exposes the `dsh-cua` CLI as an MCP stdio server, so any MCP client gets the same tool
surface as Codex's built-in CUA (`list_apps`, `get_app_state`, `click`, `type_text`,
`press_key`, `scroll`, `drag`) plus `list_windows` and `doctor`.

Stdlib only — Node 18+, no `npm install`.

## Build the CLI first

```bash
swift build -c release      # produces .build/release/dsh-cua
node mcp/test-server.mjs    # verifies the protocol without needing any TCC permission
```

The server finds the binary in this order: `$DSH_CUA_BIN` → `./.build/release/dsh-cua` →
`./.build/debug/dsh-cua` → `dsh-cua` on `PATH`.

## Register with DSH

```json
{
  "mcpServers": {
    "dsh-cua": {
      "command": "node",
      "args": ["/absolute/path/to/dsh-cua/mcp/server.mjs"],
      "env": { "DSH_CUA_BIN": "/absolute/path/to/dsh-cua/.build/release/dsh-cua" }
    }
  }
}
```

## Register with Claude Code

```bash
claude mcp add dsh-cua -- node /absolute/path/to/dsh-cua/mcp/server.mjs
```

## Tools

| Tool | Notes |
|---|---|
| `doctor` | Call first. Reports macOS version and both permissions; never fails hard. |
| `list_apps` | Frontmost first, with pid and window count. |
| `list_windows` | CGWindowID + bounds; titles need Screen Recording. |
| `get_app_state` | Accessibility tree + stable refs; optional single-window screenshot returned as an MCP image block. |
| `click` | Prefer `element`; `x`/`y` are hit-tested back to an element before falling back to a synthetic click. |
| `type_text` | Writes `AXValue` directly when possible, so no keystrokes and no focus change. |
| `press_key` | `key` plus optional `modifiers`. |
| `scroll` | Pixel scroll wheel events. |
| `drag` | Two global points. |

## Environment

| Variable | Effect |
|---|---|
| `DSH_CUA_BIN` | Path to the CLI binary. |
| `DSH_CUA_TIMEOUT_MS` | Per-call timeout (default 30000). |
| `DSH_CUA_DRY_RUN=1` | Resolve the plan, perform no input. |
| `DSH_CUA_ALLOW_BLOCKED=1` | Allow terminal/security-agent targets. Dangerous. |

## Protocol behaviour

- Newline-delimited JSON-RPC 2.0. Unknown methods → `-32601`; unknown tools → `-32602`;
  a malformed line gets `-32700` and the loop keeps running.
- A CLI failure becomes a normal tool result with `isError: true` and the CLI's error code
  in the text, so the model can react (`PERMISSION_DENIED` means "ask the user to grant
  access", not "retry").
- Nothing but JSON-RPC frames is ever written to stdout; logs go to stderr.
