# dsh-cua

**Native macOS computer-use for DSH — with the same tool surface as Codex's built-in CUA,
and a hard guarantee that it will never steal your screen.**

`dsh-cua` lets an agent read a native app's accessibility tree, click elements, type text,
press keys, scroll and drag — while you keep working. It is a Swift CLI, an MCP stdio
server, and a DSH skill.

This project exists because of a specific failure. The first attempt at this kind of
automation drove a real Chrome window over CDP to answer a question about a paper
database; Chrome came to the front on every single step and yanked the user out of
whatever they were doing. Screenshot-loop agents and browser-driving scripts have this
problem by construction. `dsh-cua` is built the other way round: **not stealing focus is
the feature**, and violating it is a hard error.

## How it differs

| | Codex built-in CUA | Screenshot-loop agents | **dsh-cua** |
|---|---|---|---|
| Mechanism | bundled `SkyComputerUseClient` helper (Accessibility + ScreenCaptureKit + synthetic input), reached via `codex app-server` | periodic full-screen grabs + coordinate clicks | Accessibility API first, `CGEventPostToPid` fallback |
| Needs Codex installed | yes | no | **no** |
| Capture scope | window | whole display | **one window, only when asked** |
| Moves your cursor | no | usually | **never** |
| Steals focus | no | often | **never — verified per call, exit 7 if it happens** |
| Interface | Codex-internal | varies | **CLI + MCP + DSH skill** |

Prior art worth reading: [`codex-cua-mcp`](https://github.com/parassharmaa/codex-cua-mcp)
re-exposes Codex's CUA tools over MCP; [`axuse`](https://github.com/ctoldigital/axuse)
takes an accessibility-first approach over CDP; [`arc-cua`](https://github.com/shhivv/arc-cua)
is a fast macOS action layer for computer-use agents.

## Install

```bash
git clone <this repo> && cd dsh-cua
swift build -c release          # macOS 14+, Swift 5.9+ toolchain (builds on 5.10 and 6.x)
./.build/release/dsh-cua doctor --json
bash scripts/install-skill.sh   # installs the DSH skill
```

Then register the MCP server (see [mcp/README.md](mcp/README.md)) or just call the CLI.

## Permissions (read this first)

macOS will not let anything drive apps or capture windows without explicit consent, and
the consent is attached to **the binary**, not to your terminal:

| Permission | Needed for | System Settings pane |
|---|---|---|
| **Accessibility** | reading the AX tree, pressing elements, posting input | Privacy & Security → **Accessibility** |
| **Screen Recording** | `get-app-state --screenshot` only | Privacy & Security → **Screen & System Audio Recording** |

A locally built binary is unsigned, so you must add it manually with the `+` button.
`dsh-cua doctor` prints the exact path to add and whether each permission is currently
granted. Two gotchas: moving or rebuilding the binary can invalidate the grant (add the
final path, and re-add after a clean rebuild), and without Accessibility almost every
command returns `PERMISSION_DENIED` — which is not retryable, it means "grant it and try
again".

## Usage

Every command prints one JSON object. Add `--json` for a single compact line.

```bash
dsh-cua doctor --json
dsh-cua list-apps --json
dsh-cua list-windows --app Safari --json
dsh-cua get-app-state --app Safari --json                    # no capture, fast
dsh-cua get-app-state --app Safari --screenshot /tmp/s.png --json
dsh-cua click --app Safari --element e42 --json              # preferred
dsh-cua click --app Safari --x 812 --y 460 --json            # hit-tested first
dsh-cua type-text --app Notes --element e7 --text "hello" --json
dsh-cua press-key --app Safari --key return --json
dsh-cua scroll --app Safari --dx 0 --dy -600 --json
dsh-cua drag --app Finder --from "100,100" --to "400,400" --json
dsh-cua selftest --json
```

Illustrative output (contract shape; real values differ):

```json
{"ok":true,
 "app":{"name":"Safari","bundleId":"com.apple.Safari","pid":501},
 "windows":[{"id":4211,"title":"Apple","focused":true,"bounds":{"x":0,"y":0,"w":1440,"h":900}}],
 "tree":[{"ref":"e1","role":"AXWindow","title":"Apple","enabled":true,
          "frame":{"x":0,"y":0,"w":1440,"h":900},"actions":["AXRaise"],"children":[]}],
 "stats":{"nodes":312,"truncated":false,"maxDepth":12},
 "screenshot":null,
 "frontmostApp":{"bundleId":"com.apple.Safari","pid":501,"unchanged":true}}
```

`<target>` accepts a bundle id (`com.apple.Safari`), `pid:501`, or a name. On a localized
macOS the display name may be Chinese — the resolver also matches the bundle filename, so
`--app Finder` finds `访达` rather than some unrelated "… Finder Extension".

## Element refs

`get-app-state` assigns `e1`, `e2`, … to every node that has a frame, and caches them per
pid. A ref is valid **until the next `get-app-state` for that app**. Refs are not live
handles: the CLI replays the recorded child-index path (falling back to a hit test) and
verifies role and title still match. If the UI moved you get `STALE_REF` (exit 5) — re-read
the state and use the new ref instead of guessing.

Path replay is the primary mechanism because hit-testing alone is not reliable enough: for
overlay controls like scrollbars and text fields, `AXUIElementCopyElementAtPosition`
answers with the containing `AXGroup`, not the control.

## The no-focus-steal guarantee

Every command records the frontmost application before and after it does anything. If the
frontmost app changed, the command reports `FOCUS_CHANGED` and exits **7** — it is treated
as a bug in this tool, not as a warning to ignore.

Concretely:

- **Input** goes through `CGEvent.postToPid`, so events land in the target process's queue.
  The global HID tap is never used, and `CGWarpMouseCursorPosition` is never called.
- **Clicks** are resolved to a real element with `AXUIElementCopyElementAtPosition` and
  pressed with `AXPress` when possible, instead of being sprayed at coordinates.
- **Typing** writes the element's `AXValue` directly when it is settable — no keystrokes
  at all.
- **Capture** is window-scoped via `SCContentFilter(desktopIndependentWindow:)`. There is
  no full-display grab path in the codebase.
- The words `activate`, `activateIgnoringOtherApps`, and `open -a` do not appear in the
  input path.

Verify it yourself: run `dsh-cua get-app-state --app Finder --json` while another app is
frontmost and check that `frontmostApp.unchanged` is `true` and your frontmost app did not
change.

## Safety

- Terminals and the security agent are blocked outright: `Terminal`, `iTerm2`, `Warp`,
  `WezTerm`, `kitty`, `Hyper`, `SecurityAgent`, `System Settings`, `Keychain Access`.
  Blocked targets return `UNSUPPORTED`. `DSH_CUA_ALLOW_BLOCKED=1` overrides this — only
  with explicit consent.
- `AXSecureTextField` is refused; the tool will not type into password fields.
- `DSH_CUA_DRY_RUN=1` resolves the plan, reports it, and performs no input.
- `dsh-cua selftest` covers the blocklist, secure-field refusal, the envelope shape and
  every error/exit-code mapping.

## Development

```bash
make build        # swift build -c release
make test         # dsh-cua selftest --json  (73 assertions)
make mcp-test     # node mcp/test-server.mjs (31 protocol checks)
make lint
```

There is intentionally **no XCTest target**. This package has to build on machines with
only the Command Line Tools, where the `XCTest` module does not exist and `swift test`
cannot compile. The assertions live in `Sources/DshCuaCore/SelfTest.swift` and run through
the binary, so they work wherever the binary works. CI runs the same thing.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the frozen interface in
[CONTRACT.md](CONTRACT.md).

## Non-goals

Windows and Linux. OCR. Video capture. Driving your frontmost app on purpose. Solving
CAPTCHAs or bypassing TCC. If Screen Recording is not granted, everything except
`--screenshot` still works.

## License

MIT — see [LICENSE](LICENSE).
