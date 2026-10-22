---
name: computer-use
description: Drive macOS apps natively without stealing the user's screen — read an app's accessibility tree, click elements, type text, press keys, scroll and drag. Use for GUI automation on this Mac (filling a form in a native app, clicking through a desktop app, driving a browser you already have open), for "computer use" / "control my screen" / "操作我的电脑" / "帮我点一下" requests, and whenever a task needs a GUI instead of a shell. Prefer this over launching a visible browser window or any screenshot-loop approach.
---

# Computer Use (macOS)

`dsh-cua` drives macOS applications through the Accessibility API and posts input
directly to the target process. It **never brings a window to the front, never moves the
physical cursor, and never changes the frontmost application**. If focus does change, the
command fails with `FOCUS_CHANGED` (exit 7) rather than quietly ruining whatever the user
was doing.

That guarantee is the reason this tool exists. Do not work around it: never call `open -a`,
never `osascript ... activate`, never start a visible browser to get something done.

## Binary

```bash
CUA="${DSH_CUA_BIN:-dsh-cua}"     # or ./dsh-cua/.build/release/dsh-cua from a checkout
"$CUA" doctor --json
```

Always start with `doctor`. It never fails hard and tells you whether Accessibility
(AX tree + input) and Screen Recording (window screenshots) are granted. Missing
Accessibility makes almost everything return `PERMISSION_DENIED`; missing Screen
Recording only breaks `--screenshot`.

## Workflow

1. `doctor` — confirm permissions.
2. `list-apps` — find the target (`--all` to include background agents).
3. `get-app-state --app <target>` — read the accessibility tree. Add `--screenshot <path>`
   **only when the tree is not enough**; it captures one window and needs Screen Recording.
4. Act. **Prefer `--element <ref>` over coordinates** — a ref is re-resolved and pressed
   through the AX API, so it cannot land on the wrong thing. Coordinates are hit-tested
   back to an element first, and only fall back to a synthetic click.
5. `get-app-state` again to confirm the UI actually changed. Never assume a click worked.

## Commands

| Task | Command |
|---|---|
| Permissions / environment | `dsh-cua doctor --json` |
| Find an app | `dsh-cua list-apps [--all] --json` |
| List windows | `dsh-cua list-windows [--app <target>] --json` |
| Read an app | `dsh-cua get-app-state --app <target> [--screenshot <png>] [--window <id>] --json` |
| Click | `dsh-cua click --app <target> (--element e12 \| --x N --y N) [--button left\|right\|middle] [--count N] --json` |
| Type | `dsh-cua type-text --app <target> --text "..." [--element e12] [--submit] --json` |
| Key | `dsh-cua press-key --app <target> --key return [--modifiers cmd,shift] --json` |
| Scroll | `dsh-cua scroll --app <target> --dx 0 --dy -400 [--x N --y N] --json` |
| Drag | `dsh-cua drag --app <target> --from "x,y" --to "x,y" --json` |

`<target>` is a bundle id (`com.apple.Safari`), `pid:501`, or an app name (`Safari`).
On a localized macOS the display name may be Chinese — the resolver also matches the
bundle filename, so `Finder` finds `访达`.

## Element refs

`get-app-state` assigns `e1`, `e2`, … to every node that has a frame, and caches them per
pid. A ref is valid **until the next `get-app-state` for that app**. Refs are not live
handles: the CLI replays the recorded child-index path (falling back to a hit test) and
verifies role and title still match. If the UI moved you get `STALE_REF` (exit 5) — re-read
the state and use the new ref instead of guessing.

## Safety

- Terminals (`Terminal`, `iTerm2`, `Warp`, `WezTerm`, `kitty`, `Hyper`) and the security
  agent are **blocked**; calls return `UNSUPPORTED`. `DSH_CUA_ALLOW_BLOCKED=1` overrides
  it — only with explicit user consent.
- `AXSecureTextField` is refused; password fields are never typed into.
- `DSH_CUA_DRY_RUN=1` resolves and reports the plan while performing no input. Use it to
  preview a risky sequence.

## Errors

Every command prints one JSON object. Failures look like:

```json
{"ok":false,"error":{"code":"PERMISSION_DENIED","message":"…","detail":{"hint":"…"}}}
```

Codes: `BAD_USAGE`, `APP_NOT_FOUND`, `WINDOW_NOT_FOUND`, `PERMISSION_DENIED`, `STALE_REF`,
`TIMEOUT`, `FOCUS_CHANGED`, `UNSUPPORTED`, `INTERNAL`. Exit codes: 2 usage, 3 not found,
4 permission, 5 stale ref, 6 timeout, 7 focus changed.

`PERMISSION_DENIED` is not retryable — tell the user which System Settings pane to open
and which binary to add, then stop. Do not try to bypass TCC.

## MCP

If this session uses the MCP server instead of the CLI, the same operations are exposed as
`doctor`, `list_apps`, `list_windows`, `get_app_state`, `click`, `type_text`, `press_key`,
`scroll`, `drag`. `get_app_state` returns the screenshot as an image block when you pass
`screenshot`.
