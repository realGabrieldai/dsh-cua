# Architecture

## Process model

```
        ┌──────────────────────────────┐
        │  DSH / Claude Code / client  │
        └───────────┬──────────────────┘
                    │ MCP stdio (JSON-RPC, newline-delimited)
        ┌───────────▼──────────────────┐
        │  mcp/server.mjs              │   Node, stdlib only
        │  tools ↔ argv translation    │   execFile, argument arrays
        └───────────┬──────────────────┘
                    │ execFile(dsh-cua …)
        ┌───────────▼──────────────────┐
        │  dsh-cua (Swift executable)  │   one process per call
        │  ┌────────────────────────┐  │
        │  │ FocusGuard             │  │   frontmost before == after
        │  ├────────────────────────┤  │
        │  │ AX tree  │ Capture     │  │   Accessibility / ScreenCaptureKit
        │  │ Input    │ Safety      │  │   CGEvent.postToPid / blocklist
        │  └────────────────────────┘  │
        └───────────┬──────────────────┘
                    │ Accessibility API, ScreenCaptureKit, CGEvent
        ┌───────────▼──────────────────┐
        │  target macOS application    │
        └──────────────────────────────┘
```

The CLI is the only component that touches the system. The MCP server is a translator, and
the DSH skill is documentation. That keeps the safety and focus logic in exactly one place,
and it means the skill and the MCP server cannot drift from each other — both are generated
from the same frozen contract.

`DshCuaCore` is a library and `dsh-cua` is a thin `main.swift`. The split exists so the
assertion suite can live in the library and run inside the binary (see *Testing* below).

## Why accessibility-first instead of coordinates

A screenshot-loop agent decides "click at (812, 460)". That is a guess about pixels. It is
wrong whenever the window moved, the scroll position changed, a tooltip is under the
cursor, or the display scale differs — and when it is wrong, it clicks something else.

`dsh-cua` inverts it:

1. `get-app-state` walks the AX tree and records, for every node with a frame, a **ref**
   (`e1`, `e2`, …) plus its centre point, role and title.
2. `click --element e12` re-hit-tests that centre point, then checks that the live role and
   title still match what was recorded.
3. If they match and the element supports `AXPress`, the press goes through the
   Accessibility API — no synthetic event at all.
4. If the UI moved, the command fails with `STALE_REF` (exit 5) instead of clicking blind.

Coordinate clicks (`--x --y`) take the same route: hit-test first, press the element if it
can be pressed, and only fall back to a synthetic click when there is nothing pressable
under the point.

## Element refs are not handles

`AXUIElement` references go invalid the moment an app redraws, and they cannot be shared
between processes. So refs are deliberately *soft*: the snapshot on disk stores
`{ref, role, title, cx, cy, pid}` in `~/.cache/dsh-cua/snapshot-<pid>.json`, and every use
re-resolves through a hit test with verification. A ref is valid until the next
`get-app-state` for that pid. This trades a little speed for the property that matters:
a stale ref produces an error, never a wrong click.

## Focus preservation

Every command runs inside `FocusGuard`:

```
before = frontmostApplication()
payload = run command
after  = frontmostApplication()
if before.pid != after.pid -> FOCUS_CHANGED, exit 7
```

The mechanisms that make this hold:

| Action | Mechanism | Why it cannot steal focus |
|---|---|---|
| Keyboard / text | `CGEvent.postToPid` | event enters the target's queue directly |
| Text into a field | `AXUIElementSetAttributeValue(kAXValueAttribute)` | no event at all |
| Click | `AXUIElementPerformAction(kAXPressAction)` | accessibility action, not a pointer event |
| Click fallback | `CGEvent.postToPid` mouse events | cursor position is never set |
| Scroll | `CGEvent(scrollWheelEvent2Source:)` + `postToPid` | same |
| Capture | `SCContentFilter(desktopIndependentWindow:)` | renders one window off-screen |

There is no call to `NSRunningApplication.activate`, `activateIgnoringOtherApps`,
`CGWarpMouseCursorPosition`, or a global `post(tap:)` anywhere in the input path. The
`FOCUS_CHANGED` guard exists to catch the case where a future change introduces one.

Note the honest caveat: this tool cannot stop *the app you are driving* from raising its
own window as a side effect of the action you asked for (some apps do this on certain
buttons). What it guarantees is that **dsh-cua itself** never brings anything forward. If
an app raises itself, that is the app's behaviour, and the guard will correctly report
`FOCUS_CHANGED` so you can see it happened.

## Coordinate spaces

Two spaces are in play and mixing them is the classic bug:

- **AX / CGWindow bounds**: global, origin at the top-left of the main display, points.
- **CGEvent mouse location**: same origin and units, which is why the contract specifies
  global top-left points everywhere.

`SCStreamConfiguration` sizes are **pixels**, so window captures multiply by the backing
scale factor (default 2.0). The JSON reports both the requested `scale` and the resulting
pixel `width`/`height` so a consumer can map image pixels back to points.

## Failure taxonomy

One error code maps to exactly one exit code, and the MCP layer surfaces the code in the
tool result text so a model can branch on it without parsing English.

| Code | Exit | Meaning | Retryable? |
|---|---|---|---|
| `BAD_USAGE` | 2 | bad flags/arguments | fix the call |
| `APP_NOT_FOUND` | 3 | no such running app | re-list apps |
| `WINDOW_NOT_FOUND` | 3 | no such window | re-list windows |
| `PERMISSION_DENIED` | 4 | Accessibility or Screen Recording missing | **no** — ask the user to grant it |
| `STALE_REF` | 5 | the UI moved since the snapshot | re-run `get-app-state` |
| `TIMEOUT` | 6 | the app did not answer | maybe |
| `FOCUS_CHANGED` | 7 | dsh-cua stole focus — a bug | report it |
| `UNSUPPORTED` | 1 | blocked target or secure field | no |
| `INTERNAL` | 1 | unexpected | no |

`doctor` is the exception that proves the rule: it never fails hard, so it is always safe
as a preflight.

## Testing

There is no XCTest target, on purpose. The package must build on a machine with only the
Command Line Tools, and CLT ships neither `XCTest` nor `swift-testing`, so `swift test`
cannot compile there at all. Rather than make tests optional, the assertions live in
`Sources/DshCuaCore/SelfTest.swift` and are exposed as `dsh-cua selftest`. They cover
argument parsing, keycode and modifier mapping, point parsing, the safety blocklist and
secure-field refusal, the JSON envelope, every error→exit-code mapping, JSON determinism,
the focus comparison, and the `doctor` payload shape.

The MCP server has its own protocol test (`mcp/test-server.mjs`) that speaks to it over
stdio exactly like a client: `initialize`, `tools/list` (nine tools, object-rooted
schemas), `ping`, a `tools/call`, an unknown tool (`-32602`), an unknown method
(`-32601`), and a malformed line that must not kill the loop.

Both suites are permission-free by design: they pass on a machine where nothing has been
granted, which is what makes them usable in CI.
