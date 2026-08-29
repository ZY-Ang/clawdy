#!/bin/sh
# --project must anchor to the repository root, and must not bake one person's
# home directory into a file that gets committed.
#
#   sh plugins/statusline/tests/install-paths.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../../.." && pwd)
SL=$ROOT/plugins/statusline/bin/claude-statusline-install
OC=$ROOT/plugins/opinionated-claude/bin/opinionated-claude-install
TMP=${TMPDIR:-/tmp}/install-paths.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "install-paths.test: jq required" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

mkproj() { rm -rf "$TMP/p" "$TMP/home"; mkdir -p "$TMP/p/deep/sub" "$TMP/home"
           ( cd "$TMP/p" && git init -q . ) >/dev/null 2>&1; }

# --- run from a SUBDIRECTORY, which is the ordinary case ----------------------
# Both wrote relative paths, so from a subdirectory they created files Claude
# Code never reads: a silent no-op that looked like a successful install.
mkproj
( cd "$TMP/p/deep/sub" && HOME="$TMP/home" sh "$OC" --project ) >/dev/null 2>&1
[ -f "$TMP/p/CLAUDE.md" ] && ok "opinionated-claude writes to the repo root" \
  || bad "opinionated-claude writes to the repo root" "$(find "$TMP/p" -name CLAUDE.md | head -1)"
[ -f "$TMP/p/deep/sub/CLAUDE.md" ] && bad "and not into the subdirectory" || ok "and not into the subdirectory"

mkproj
( cd "$TMP/p/deep/sub" && HOME="$TMP/home" sh "$SL" --project ) >/dev/null 2>&1
[ -f "$TMP/p/.claude/settings.json" ] && ok "statusline writes settings to the repo root" \
  || bad "statusline settings at the root" "$(find "$TMP/p" -name settings.json | head -1)"

# --- the committed file must not name one machine ----------------------------
cmd=$(jq -r '.statusLine.command' "$TMP/p/.claude/settings.json" 2>/dev/null)
case "$cmd" in
  /*) bad "the project command must not be an absolute path" "$cmd" ;;
  "") bad "no statusLine command was written" ;;
  *)  ok "the project command is relative, so it survives a clone" ;;
esac
case "$cmd" in
  *"$TMP/home"*) bad "the project command must not name a home directory" "$cmd" ;;
  *) ok "and names no home directory" ;;
esac
[ -x "$TMP/p/.claude/statusline.sh" ] && ok "the script itself lands inside the project" \
  || bad "script inside the project" "not at $TMP/p/.claude/statusline.sh"

# --- user scope is unchanged --------------------------------------------------
rm -rf "$TMP/home2"; mkdir -p "$TMP/home2"
( cd "$TMP" && HOME="$TMP/home2" sh "$SL" ) >/dev/null 2>&1
ucmd=$(jq -r '.statusLine.command' "$TMP/home2/.claude/settings.json" 2>/dev/null)
case "$ucmd" in
  "$TMP/home2"/*) ok "user scope still writes an absolute path under HOME" ;;
  *) bad "user scope unchanged" "$ucmd" ;;
esac

# --- outside a repository, --project must refuse -----------------------------
# Guessing a root would put the file somewhere arbitrary, which is the bug.
rm -rf "$TMP/norepo"; mkdir -p "$TMP/norepo"
( cd "$TMP/norepo" && HOME="$TMP/home" sh "$OC" --project ) >/dev/null 2>&1
[ $? -ne 0 ] && ok "opinionated-claude --project refuses outside a repository" \
  || bad "refuses outside a repository" "it wrote something instead"
( cd "$TMP/norepo" && HOME="$TMP/home" sh "$SL" --project ) >/dev/null 2>&1
[ $? -ne 0 ] && ok "statusline --project refuses outside a repository" \
  || bad "statusline refuses outside a repository"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
