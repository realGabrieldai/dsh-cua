# Independent verification — dsh-cua

Verified commit `3d8b396` (clean clone at `/tmp/v2`), on macOS 27.2 / arm64 / Swift 6.4.
Method: reproduce everything from a pristine clone; treat every claim as unproven until
observed. Live tests were run against Finder, a non-frontmost app, while another app held
focus.

Verdicts: **确认** (reproduced), **存疑** (partly), **错误** (failed).

## 1. Clean build — 确认

```
$ git clone ~/Documents/deepseek/dsh-cua /tmp/v2 && cd /tmp/v2
$ ls -d .build          -> absent (no stale artifacts)
$ swift build -c release
Build complete! (19.94秒)
```

25 tracked files; the clone contains no build products. Build is reproducible from scratch.

## 2. Built-in test suite — 确认

```
$ ./.build/release/dsh-cua selftest --json
{"failed":0,"failures":[],"ok":true,"passed":81}
```

81 assertions, exit 0. Note the deliberate deviation from the original plan: there is no
XCTest target, because this machine has Command Line Tools only and ships no `XCTest`
module — `swift test` cannot compile here at all. The assertions live in
`Sources/DshCuaCore/SelfTest.swift` and run inside the binary. Documented in
`CONTRACT.md` §5.1.

## 3. CLI conformance — 确认

Every command in `CONTRACT.md` §1 exists and is documented in `--help`:

```
doctor · selftest · list-apps · list-windows · get-app-state · click · type-text ·
press-key · scroll · drag          → all present
```

All 21 contract flags are documented: `--json --quiet --timeout-ms --app --screenshot
--window --max-depth --max-nodes --element --x --y --button --count --text --submit --key
--modifiers --dx --dy --from --to`.

Every `--flag` that appears in `README.md` was cross-checked against the binary's `--help`:
**zero mismatches**.

Envelope shape, error codes and exit codes match §2 for all exercised paths
(`PERMISSION_DENIED`→4, `STALE_REF`→5, `BAD_USAGE`→2, success→0).

## 4. Focus preservation — the headline claim — 确认 (live)

Environment: Accessibility granted, Screen Recording **not** granted. Frontmost app was
recorded with `lsappinfo front` before and after each command; the CLI's own
`frontmostApp.unchanged` field was checked independently.

| Command | Kind | `frontmostApp.unchanged` | Frontmost app changed? |
|---|---|---|---|
| `list-apps` | read | true | no |
| `list-windows` | read | true | no |
| `doctor` | read | true | no |
| `get-app-state --app Finder` | read (460 AX nodes) | true | no |
| `click --app Finder --element e53` | **real input** | true | no |
| `click --app Finder --element e71` | **real input, `method=ax-press`** | true | no |
| `press-key --app Finder --key escape` | **real input** | true | no |
| `scroll --app Finder --dy 120` | **real input** | true | no |
| `type-text --app Finder --element e195` | **real input** | true | no |

The frontmost application (WeChat, then WPS Office) never changed across any of these,
including four real input-posting commands aimed at a background app.

Source audit over `Sources/`:

| Forbidden | Result |
|---|---|
| `activate(` | absent |
| `activateIgnoringOtherApps` | absent |
| `open -a` | absent |
| `CGWarpMouseCursorPosition` | absent |
| `CGEventPost(` (global tap) | absent |
| `post(tap:` | 1 hit — a **comment** in `Input.swift:62` explaining why it is not used |
| `CGWindowListCreateImage` | absent |
| `CGDisplayCreateImage` | absent |

| Required | Result |
|---|---|
| `SCContentFilter(desktopIndependentWindow:)` | present |
| `postToPid` | present |
| `AXUIElementPerformAction` | present |
| `AXUIElementCopyElementAtPosition` | present |
| `SCScreenshotManager.captureImage` | present |

## 5. Screenshot scoping — 确认

- The only capture call is `SCScreenshotManager.captureImage` with an
  `SCContentFilter(desktopIndependentWindow:)` built from one `CGWindowID`
  (`Capture.swift:67`). There is no display-wide filter anywhere.
- `get-app-state` without `--screenshot` never reaches `Capture.swift`; the capture is
  guarded by `if let path = args.str("screenshot")` in `Commands.getAppState`.
- With Screen Recording ungranted, `--screenshot` returns a clean `PERMISSION_DENIED`
  (exit 4) and **writes no file** — confirmed: `/tmp/finder-shot.png` did not exist after
  the call.

## 6. MCP conformance — 确认

`node mcp/test-server.mjs` → **31 checks passed, 0 failed**. Independently hand-driven over
stdio as well:

| Check | Result |
|---|---|
| `initialize` | returns `protocolVersion: 2024-11-05`, `serverInfo.name: dsh-cua` |
| `tools/list` | exactly the nine contract tool names, every `inputSchema` object-rooted |
| `tools/call doctor` | returns a parseable JSON envelope in a text block |
| unknown tool | `-32602` |
| unknown method | `-32601` |
| malformed JSON line | `-32700` reply, **loop survives** and keeps answering |
| stdout purity | only JSON-RPC frames; logs on stderr |
| injection surface | `execFile` with argument arrays; no shell strings |

## 7. Safety — 确认

- Blocked bundle ids are a real code path (`Safety.blockedBundleIds`) and are unit-tested;
  `com.apple.Terminal` and `com.googlecode.iterm2` throw `UNSUPPORTED`.
- `AXSecureTextField` refusal is implemented and tested.
- `DSH_CUA_DRY_RUN=1` resolved and reported a plan while performing no input (observed on
  `click` and `type-text`).

## 8. Skill packaging — 确认

`scripts/install-skill.sh` run twice against a temp `DSH_HOME`:

```
run1 exit=0 -> computer-use/SKILL.md
run2 exit=0 (idempotent)
```

It creates only `skills/computer-use/`, and the real `~/.dsh/skills/computer-use` was
**not** created (confirmed absent afterwards). `SKILL.md` follows the same
frontmatter/structure as the working `cnki-paper-download` skill and names only commands
that exist in the contract.

## 9. Defects found and fixed during verification

**Blocker — element refs were unusable for a large class of controls.** The first
implementation re-resolved refs by hit-testing the remembered centre point only. For
overlay controls the hit test returns the containing `AXGroup`, so a correct ref was
rejected:

```
$ dsh-cua click --app Finder --element e71
{"ok":false,"error":{"code":"STALE_REF",
 "message":"element 'e71' changed role (AXButton -> AXGroup); the UI moved"}}
```

`e71` is a scrollbar page button and `e80`/`e195` are text fields — all legitimately
unresolvable, which made the `ax-press` path effectively dead code. Fixed in `3d8b396` by
recording the child-index path from the app's window array and replaying it first, keeping
the hit test as a fallback. Re-verified live:

```
$ dsh-cua click --app Finder --element e71
{"ok":true,"method":"ax-press",
 "target":{"ref":"e71","resolution":"ax-path","role":"AXButton"},
 "frontmostApp":{...,"unchanged":true}}
```

Repeat calls re-resolve correctly, so refs are re-derived rather than cached.

**Major — `--app Finder` matched the wrong process.** Name matching used a substring
fallback and matched *"Adobe Content Synchronizer Finder Extension"*; on a localized macOS
the real Finder is named `访达`. Fixed by scoring candidates against bundle id, localized
name **and bundle filename**, preferring `.regular` activation policy. Now resolves to
`访达`, and `--app Safari` to `Safari浏览器`.

**Minor — `dsh-cua --help` exited 2.** The argument parser required a command token.
Fixed; `--help` and `--version` now work with no subcommand, and a truly empty argv still
returns `BAD_USAGE` (exit 2).

## 10. Screenshot success path — 确认 (re-tested after Screen Recording was granted)

An earlier revision of this report listed the capture success path as unverified, because
Screen Recording had not been granted. It has since been granted, and the path was tested
for real against a live window (Microsoft Edge, 1470×923 pt):

```
$ dsh-cua get-app-state --app "Microsoft Edge" --screenshot /tmp/edge-shot.png --json
{"ok":true,
 "screenshot":{"path":"/tmp/edge-shot.png","width":2940,"height":1846,"windowId":12643,"scale":2},
 "frontmostApp":{...,"unchanged":true}}
$ file /tmp/edge-shot.png
PNG image data, 2940 x 1846, 8-bit/color RGBA, non-interlaced
```

`2940×1846` is exactly the window's `1470×923` points × the 2.0 backing scale, which is
positive evidence that the capture is **window-scoped and not a display grab** — a
full-screen capture of this machine would have different dimensions. The image was
inspected and contains the real window content. The frontmost application was unchanged.

## 11. `request-permission` — 确认

Added so users do not have to hunt through System Settings. Exercises
`AXIsProcessTrustedWithOptions(prompt: true)` and `CGRequestScreenCaptureAccess()`, and
always exits 0. Run on this machine it reported
`permissionsNow: {accessibility: true, screenRecording: false}` before the grant and
`screenRecording: true` afterwards. Caveat: Accessibility was already granted here, so only
the Screen Recording branch produced an actual OS prompt.

## 12. CI — 确认 (green)

```
$ gh run list --limit 1
completed  success  ci  ci  main  push  39789973227
$ gh run view 39789973227
✓ build-and-test in 28s
```

The first run failed in 20s:

```
error: 'dsh-cua': package 'dsh-cua' is using Swift tools version 6.0.0
but the installed version is 5.10.0
```

`macos-14` runners ship Swift 5.10. Fixed by lowering the manifest to tools-version 5.9
(which also gives the Swift 5 language mode this code wants) rather than pinning a newer
runner, so the package builds on the wider toolchain range. Re-pushed as `f0801d5`.

Final end-to-end acceptance, cloned from the public remote:

```
$ git clone https://github.com/realGabrieldai/dsh-cua.git /tmp/final
$ swift build -c release                     -> Build complete! (19.68秒)
$ ./.build/release/dsh-cua selftest --json    -> {"passed":81,"failed":0,"ok":true}
$ node mcp/test-server.mjs                   -> 31 checks passed, 0 failed
```

## 13. Not verified — stated honestly

- **No live AX press was attempted on a state-changing control.** The presses executed were
  an inert status-bar static text and a scrollbar page button. A press that mutates user
  data was deliberately avoided; the code path itself is exercised and reports
  `method=ax-press`.
- **The focus guard's `FOCUS_CHANGED` failure branch never fired in a live run**, because
  nothing stole focus. It is covered by unit assertions on the comparison logic and by
  source inspection only.
- **No live test on a second macOS version.** Everything here is macOS 27.2 / arm64.
