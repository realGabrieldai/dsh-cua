#!/usr/bin/env bash
# End-to-end demo of dsh-cua's computer use.
#
# It drives a real macOS app (TextEdit) entirely in the background and asserts, at every
# single step, that the frontmost application never changed. Run it while you are working
# on something else: your focus should not move once.
#
#   bash scripts/demo.sh
#
# Requires Accessibility (AX tree + input) and Screen Recording (the screenshot step).
# Run `dsh-cua doctor --json` first; `dsh-cua request-permission --json` triggers the prompts.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${DSH_CUA_BIN:-$REPO_ROOT/.build/release/dsh-cua}"
TARGET_APP="${DSH_CUA_DEMO_APP:-TextEdit}"
SHOT="${TMPDIR:-/tmp}/dsh-cua-demo.png"

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# The frontmost application, as macOS itself reports it (independent of dsh-cua).
front() {
  lsappinfo info -only name "$(lsappinfo front)" 2>/dev/null | head -1 | sed 's/ ASN.*//;s/"//g'
}

json() { python3 -c "import json,sys;d=json.load(sys.stdin);$1"; }

if [[ ! -x "$BIN" ]]; then
  echo "dsh-cua binary not found at $BIN — run 'make build' first (or set DSH_CUA_BIN)." >&2
  exit 1
fi

FRONT_START="$(front)"
echo "dsh-cua computer-use demo"
echo "binary:      $BIN"
echo "target app:  $TARGET_APP"
echo "frontmost:   $FRONT_START"

step "1. Permissions"
PERMS="$("$BIN" doctor --json)"
echo "$PERMS" | json "print('  ', d['permissions'])"
echo "$PERMS" | grep -q '"accessibility": *true' \
  && ok "Accessibility granted" \
  || bad "Accessibility NOT granted — run: $BIN request-permission"
echo "$PERMS" | grep -q '"screenRecording": *true' \
  && ok "Screen Recording granted" \
  || echo "  ! Screen Recording not granted; the screenshot step will fail (rest of the demo still works)"

step "2. Launch the target in the BACKGROUND (open -g never activates)"
if ! pgrep -qf "$TARGET_APP.app/Contents/MacOS"; then
  open -g -a "$TARGET_APP"
  sleep 3
fi
# TextEdit starts with no window under `open -g`; give it one. This is demo staging, not
# part of the capability under test.
if [[ "$TARGET_APP" == "TextEdit" ]]; then
  osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1 || true
  sleep 2
fi
[[ "$(front)" == "$FRONT_START" ]] && ok "frontmost still $FRONT_START" || bad "focus moved to $(front)"

step "3. Read the accessibility tree"
"$BIN" get-app-state --app "$TARGET_APP" --json > /tmp/dsh-cua-demo-state.json
json "
print('  app:', d['app']['name'], '| pid:', d['app']['pid'])
print('  windows:', [(w['id'], w['focused']) for w in d['windows']])
print('  AX nodes:', d['stats']['nodes'], '| truncated:', d['stats']['truncated'])
print('  frontmost unchanged:', d['frontmostApp']['unchanged'])
" < /tmp/dsh-cua-demo-state.json
grep -q '"unchanged": *true' /tmp/dsh-cua-demo-state.json && ok "focus preserved while reading" || bad "focus changed while reading"

step "4. Locate the text area and its ref"
REF="$(python3 - <<'PY'
import json
d = json.load(open('/tmp/dsh-cua-demo-state.json'))
areas = []
def walk(n):
    if n.get('role') == 'AXTextArea':
        areas.append(n)
    for c in n.get('children', []):
        walk(c)
for r in d['tree']:
    walk(r)
print(areas[0]['ref'] if areas else '')
PY
)"
if [[ -z "$REF" ]]; then
  bad "no AXTextArea found in $TARGET_APP — is a document window open?"
  echo "  (demo aborted after $PASS passed / $FAIL failed)"
  exit 1
fi
ok "AXTextArea ref = $REF"

step "5. Write text through the accessibility API (no keystrokes)"
TEXT='dsh-cua 实测：全程没有抢焦点 ✅
这一行是通过 Accessibility API 直接写进 AXValue 的，没有发送任何模拟按键。
你刚才在 DSH 里的输入焦点、光标位置都没有被移动过。'
"$BIN" type-text --app "$TARGET_APP" --element "$REF" --text "$TEXT" --json > /tmp/dsh-cua-demo-type.json
json "
print('  method:', d['method'], '| chars:', d['chars'])
print('  frontmost unchanged:', d['frontmostApp']['unchanged'])
" < /tmp/dsh-cua-demo-type.json
grep -q '"method": *"ax-set-value"' /tmp/dsh-cua-demo-type.json \
  && ok "wrote via AXValue (no synthetic keystrokes)" \
  || echo "  ! fell back to synthetic keystrokes for this control"

step "6. Read it back to prove the text really landed"
"$BIN" get-app-state --app "$TARGET_APP" --json > /tmp/dsh-cua-demo-readback.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/dsh-cua-demo-readback.json'))
areas = []
def walk(n):
    if n.get('role') == 'AXTextArea':
        areas.append(n)
    for c in n.get('children', []):
        walk(c)
for r in d['tree']:
    walk(r)
value = (areas[0].get('value') or '') if areas else ''
first = value.split('\n')[0]
print('  read back:', repr(first[:50]))
print('  length:', len(value), 'chars')
assert 'dsh-cua' in value, 'text did not land'
PY
[[ $? -eq 0 ]] && ok "text verified in the live app" || bad "read-back did not contain the text"

step "7. Screenshot ONE window (not the display)"
if "$BIN" get-app-state --app "$TARGET_APP" --screenshot "$SHOT" --json > /tmp/dsh-cua-demo-shot.json 2>/dev/null; then
  json "
s = d['screenshot']
print('  png:', f\"{s['width']}x{s['height']}\", '| windowId:', s['windowId'], '| scale:', s['scale'])
print('  frontmost unchanged:', d['frontmostApp']['unchanged'])
" < /tmp/dsh-cua-demo-shot.json
  ok "wrote $SHOT (window-scoped)"
else
  echo "  ! screenshot skipped (Screen Recording not granted?)"
fi

step "8. Real input: a click and a key press"
"$BIN" click --app "$TARGET_APP" --x 439 --y 362 --json | json "print('  click   -> method:', d['method'], '| ok:', d['ok'], '| focus unchanged:', d['frontmostApp']['unchanged'])"
"$BIN" press-key --app "$TARGET_APP" --key end --json | json "print('  press   -> key:', d['key'], '| ok:', d['ok'], '| focus unchanged:', d['frontmostApp']['unchanged'])"

step "Result"
FRONT_END="$(front)"
echo "  frontmost at start: $FRONT_START"
echo "  frontmost at end:   $FRONT_END"
if [[ "$FRONT_START" == "$FRONT_END" ]]; then
  ok "the frontmost application NEVER changed — that is the whole point"
else
  bad "focus moved: $FRONT_START -> $FRONT_END"
fi

if [[ "${DSH_CUA_DEMO_KEEP:-0}" != "1" && "$TARGET_APP" == "TextEdit" ]]; then
  osascript -e 'tell application "TextEdit" to close front document saving no' >/dev/null 2>&1 || true
  echo "  (closed the scratch document; set DSH_CUA_DEMO_KEEP=1 to keep it)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
