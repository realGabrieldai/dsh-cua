#!/usr/bin/env bash
# Install the computer-use skill into the DSH skills directory.
# Idempotent: safe to re-run, and it never clobbers an unrelated skill directory.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SKILL_SRC="$REPO_ROOT/skill"
SKILL_NAME="computer-use"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DEST="$DSH_HOME/skills/$SKILL_NAME"

if [[ ! -f "$SKILL_SRC/SKILL.md" ]]; then
  echo "error: $SKILL_SRC/SKILL.md not found" >&2
  exit 1
fi

# Refuse to delete something we did not create.
if [[ -e "$DEST" && ! -f "$DEST/SKILL.md" ]]; then
  echo "error: $DEST exists but is not a dsh-cua skill; refusing to overwrite it" >&2
  exit 1
fi

mkdir -p "$DEST"
cp -f "$SKILL_SRC/SKILL.md" "$DEST/SKILL.md"

echo "installed skill: $DEST/SKILL.md"

BIN="$REPO_ROOT/.build/release/dsh-cua"
if [[ -x "$BIN" ]]; then
  echo "binary:          $BIN"
else
  echo "binary:          not built yet — run 'make build' (or 'swift build -c release')"
fi

echo
echo "The binary needs two macOS permissions before it can do anything:"
echo "  Accessibility      → System Settings → Privacy & Security → Accessibility"
echo "  Screen Recording   → System Settings → Privacy & Security → Screen & System Audio Recording"
echo "Add the binary itself (the path printed above), then verify with:"
echo "  $BIN doctor --json"
