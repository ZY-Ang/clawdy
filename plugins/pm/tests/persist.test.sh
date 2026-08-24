#!/bin/sh
# The question reaches disk before it reaches GitHub, so nothing can lose it.
#
#   sh plugins/pm/tests/persist.test.sh
#
# The cases that matter are the ones where GitHub is unavailable: no gh, gh
# failing, gh returning nothing. In every one of those the note must exist and
# the exit code must say "kept locally", never "filed".

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
TMP=${TMPDIR:-/tmp}/persist-test.$$
mkdir -p "$TMP/bin" "$TMP/notes"
trap 'rm -rf "$TMP"' EXIT INT TERM

export CLAUDE_QUESTIONS_DIR=$TMP/notes
export CLAUDE_CODE_SESSION_ID=sess-test
export HOME=$TMP

# Notes are grouped under a per-session directory, so match by find rather
# than a fixed glob — the layout is free to change without editing every case.
notefiles() { find "$CLAUDE_QUESTIONS_DIR" -name '*.md' -type f 2>/dev/null; }
ingrep() { find "$CLAUDE_QUESTIONS_DIR" -name '*.md' -type f -exec grep -q "$1" {} + 2>/dev/null; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }
rc_is(){ if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, wanted $3"; fi; }
notes() { notefiles | wc -l | tr -d ' '; }
reset() { rm -rf "$CLAUDE_QUESTIONS_DIR"; mkdir -p "$CLAUDE_QUESTIONS_DIR"; }

# gh that succeeds, gh that fails, gh that returns nothing — and no gh at all.
gh_ok()      { printf '#!/bin/sh\n[ "$1" = "label" ] && exit 0\necho "https://github.com/o/r/issues/42"\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
# Same as gh_ok, but records its arguments. Asserting that sync REPLAYS the axes
# needs the call, not just the exit code.
GH_ARGS=$TMP/gh-args
gh_rec()     { printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$GH_ARGS"\n[ "$1" = "label" ] && exit 0\necho "https://github.com/o/r/issues/42"\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
export GH_ARGS
gh_fail()    { printf '#!/bin/sh\n[ "$1" = "label" ] && exit 0\nexit 1\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
gh_silent()  { printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
gh_absent()  { rm -f "$TMP/bin/gh"; }

# The sandbox PREPENDS rather than replaces: the scripts need a normal set of
# utilities, and enumerating them by hand is how a test breaks on the next
# machine. Only `gh` is controlled, so this is only sound if the host has none —
# assert that rather than assume it.
# These cases fake gh, so they need it absent from the PATH the code under
# test sees -- NOT absent from the operator's machine. This used to refuse and
# exit 1, the same code a real failure uses, so a full-suite run was red on
# any machine that has gh.
. "$HERE/lib/gh-free.sh"
PATH=$(gh_free_path "$TMP/nogh"); export PATH
call() { cmd=$1; shift; PATH="$TMP/bin:$PATH" sh "$BIN/$cmd" "$@"; }
# A task now requires the three ordering axes. These cases are about DURABILITY
# -- what happens when gh is missing, failing or silent -- so the axes are
# supplied once here rather than restated in every call.
AX="--priority med --urgency low --size s"

# --- no gh: the note is the whole point --------------------------------------
reset; gh_absent
call file-issue task "Retry logic is missing" $AX --body "found while fixing #12" >/dev/null 2>&1
rc_is "no gh -> exit 3, not a silent success" $? 3
[ "$(notes)" = "1" ] && ok "and the note exists" || bad "and the note exists" "$(notes) notes"
if ingrep '^- filed: no$'; then ok "marked unsent"; else bad "marked unsent"; fi
if ingrep 'found while fixing #12'; then ok "body preserved"; else bad "body preserved"; fi
out=$(call file-issue task "T2" $AX --body b 2>&1 >/dev/null)
case "$out" in *"kept on disk"*) ok "message names the file" ;; *) bad "message names the file" "$out" ;; esac

# --- gh present but failing --------------------------------------------------
reset; gh_fail
call file-issue task "Server rejects it" $AX --body b >/dev/null 2>&1
rc_is "gh failing -> exit 3" $? 3
[ "$(notes)" = "1" ] && ok "note still written" || bad "note still written"

# --- gh succeeding but printing nothing --------------------------------------
# A silent success is not a success: without a URL there is nothing to point the
# note at, and treating it as filed would lose the only reference.
reset; gh_silent
call file-issue task "Quiet gh" $AX --body b >/dev/null 2>&1
rc_is "gh returning no URL -> exit 3" $? 3
if ingrep '^- filed: no$'; then ok "and stays unsent"; else bad "and stays unsent"; fi

# --- the happy path ----------------------------------------------------------
reset; gh_ok
url=$(call file-issue task "It works" $AX --body b 2>/dev/null); rc=$?
rc_is "gh ok -> exit 0" "$rc" 0
[ "$url" = "https://github.com/o/r/issues/42" ] && ok "prints the URL" || bad "prints the URL" "$url"
if ingrep '^- filed: https://github.com/o/r/issues/42$'
then ok "note records where it went"; else bad "note records where it went"; fi

# --- ask-async takes the same path -------------------------------------------
reset; gh_absent
call ask-async "Keep invoice numbers?" --blocked-on access --context "delete path" --assume "keep them" >/dev/null 2>&1
rc_is "ask-async, no gh -> exit 3" $? 3
[ "$(notes)" = "1" ] && ok "ask-async persists too" || bad "ask-async persists too"
out=$(call ask-async "Q2" --blocked-on access --context c --assume a 2>&1 >/dev/null)
case "$out" in *"proceeding on the stated assumption"*) ok "and says work continues" ;;
  *) bad "and says work continues" "$out" ;; esac

# --- dry-run must not litter --------------------------------------------------
reset; gh_ok
call file-issue task "Dry" $AX --body b --dry-run >/dev/null 2>&1
[ "$(notes)" = "0" ] && ok "dry-run writes no note" || bad "dry-run writes no note"

# --- questions list -----------------------------------------------------------
reset; gh_absent
call file-issue task "Unsent one" $AX --body b >/dev/null 2>&1
call questions list >/dev/null 2>&1
rc_is "list exits 1 while anything is unsent" $? 1
out=$(call questions list 2>&1)
case "$out" in *"[unsent]"*) ok "and marks it [unsent]" ;; *) bad "and marks it [unsent]" "$out" ;; esac
case "$out" in *"questions sync"*) ok "and names the fix" ;; *) bad "and names the fix" ;; esac

# --- sync ---------------------------------------------------------------------
gh_ok
call questions sync >/dev/null 2>&1
rc_is "sync exits 0 when everything went" $? 0
[ "$(notes)" = "1" ] && ok "sync does not breed duplicate notes" \
  || bad "sync does not breed duplicate notes" "$(notes) notes — NO_PERSIST not honoured"
if ingrep '^- filed: https://'; then ok "and marks the original filed"
else bad "and marks the original filed"; fi
# The note is filed but still OPEN, so list correctly reports work outstanding.
out=$(call questions list 2>&1)
case "$out" in *"[unsent]"*) bad "nothing is unsent after sync" "$out" ;; *) ok "nothing is unsent after sync" ;; esac

reset; gh_absent
call questions sync >/dev/null 2>&1
rc_is "sync without gh -> exit 1" $? 1

# --- the axes must survive the durability path --------------------------------
# The requirement is only worth having if a note that never reached the tracker
# comes back ranked. Replaying it without the axes would reintroduce the exact
# decay through the one path nobody looks at.
rm -rf "$TMP/notes"; gh_absent
call file-issue task "Axed note" --priority high --urgency low --size s --severity security --body b >/dev/null 2>&1
note=$(find "$TMP/notes" -name '*.md' 2>/dev/null | head -1)
if [ -n "$note" ]; then
  for pair in "priority: high" "urgency: low" "size: s" "severity: security"; do
    if grep -q -- "- $pair" "$note"; then ok "note records $pair"
    else bad "note records $pair" "$(cat "$note")"; fi
  done
  : > "$GH_ARGS"; gh_rec
  out=$(call questions sync 2>&1)
  case "$out" in *sent*) ok "sync re-files the note" ;; *) bad "sync re-files the note" "$out" ;; esac
  # file-issue turns --priority high into --label priority-high, so the assertion
  # is on what gh was actually asked for, not on the flag that produced it.
  create=$(grep '^issue create' "$TMP/gh-args" 2>/dev/null | head -1)
  case "$create" in *"--label priority-high"*) ok "and replays priority-high" ;;
    *) bad "replays the axes on sync" "$create" ;; esac
  case "$create" in *"--label security"*) ok "and replays the severity" ;;
    *) bad "replays the severity" "$create" ;; esac
  # The metadata must not have leaked into the re-sent body.
  case "$create" in *"- priority: high"*) bad "note metadata leaked into the body" "$create" ;;
    *) ok "and the metadata stayed out of the body" ;; esac
else
  bad "a note was written for the axed task"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
