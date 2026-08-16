#!/bin/sh
# A question has a life after it is asked: answered, closed, or gone stale.
# These cover that, and the reminder that stops "noted" from meaning nothing.
#
#   sh plugins/pm/tests/lifecycle.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
HOOK=$HERE/../hooks/remind-open-questions
TMP=${TMPDIR:-/tmp}/lifecycle-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

if command -v gh >/dev/null 2>&1; then
  echo "lifecycle.test: a real gh is on PATH; the no-gh cases would be meaningless" >&2; exit 1
fi
export CLAUDE_QUESTIONS_DIR=$TMP/notes
export CLAUDE_CODE_SESSION_ID=sess-aaaa
export HOME=$TMP

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }
rc_is(){ if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, wanted $3"; fi; }
q()   { PATH="$TMP/bin:$PATH" sh "$BIN/questions" "$@"; }
# Questions go through ask-async, which is the only door that takes them now.
# Tasks still go through file-issue.
ask() { PATH="$TMP/bin:$PATH" sh "$BIN/ask-async" "$1" \
          --blocked-on access --context "test" --assume "carrying on" >/dev/null 2>&1; }
task() { PATH="$TMP/bin:$PATH" sh "$BIN/file-issue" task "$1" --body "${2:-b}" >/dev/null 2>&1; }
idof(){ sed -n 's/^- id: //p' "$(find "$CLAUDE_QUESTIONS_DIR" -name "*$1*.md"|head -1)" 2>/dev/null|head -1; }
reset(){ rm -rf "$CLAUDE_QUESTIONS_DIR"; }

# --- asking leaves an open note with an id -----------------------------------
reset
ask "Keep invoice numbers"
ID=$(idof keep-invoice)
[ -n "$ID" ] && ok "note gets an id ($ID)" || bad "note gets an id"
[ -d "$CLAUDE_QUESTIONS_DIR/sess-aaaa" ] && ok "grouped under its session" || bad "grouped under its session"
q >/dev/null 2>&1; rc_is "list exits 1 while a question is open" $? 1
case "$(q 2>&1)" in *"$ID"*) ok "and names the id" ;; *) bad "and names the id" ;; esac

# --- answering closes it, and keeps the answer WITH the question -------------
q answer "$ID" "Keep them - invoices stay immutable" >/dev/null 2>&1
rc_is "answer exits 0" $? 0
f=$(find "$CLAUDE_QUESTIONS_DIR" -name '*.md'|head -1)
grep -q '^- status: answered$' "$f" && ok "status becomes answered" || bad "status becomes answered"
grep -q 'invoices stay immutable' "$f" && ok "the answer is stored in the note itself" \
  || bad "the answer is stored in the note itself" "question and answer must not drift apart"
grep -q '^- answered-at: ' "$f" && ok "and timestamped" || bad "and timestamped"
q >/dev/null 2>&1; rc_is "list exits 0 once nothing is open" $? 0

q answer nosuch "x" >/dev/null 2>&1; rc_is "answering an unknown id -> 2" $? 2
q answer "$ID" >/dev/null 2>&1;      rc_is "answer without text -> 2"     $? 2

# --- closing without an answer ------------------------------------------------
reset; ask "Which timeout"
ID2=$(idof which-timeout)
q close "$ID2" --reason superseded >/dev/null 2>&1; rc_is "close exits 0" $? 0
f2=$(find "$CLAUDE_QUESTIONS_DIR" -name '*.md'|head -1)
grep -q '^- status: closed$' "$f2" && ok "status becomes closed" || bad "status becomes closed"
grep -q '^- closed-reason: superseded$' "$f2" && ok "and records why" || bad "and records why"

# --- prune never removes an open question ------------------------------------
reset
ask "Old and unanswered"
task "Old and closed"
CID=$(idof old-and-closed); q close "$CID" --reason obsolete >/dev/null 2>&1
# Backdate both well past the threshold.
find "$CLAUDE_QUESTIONS_DIR" -name '*.md' -exec touch -t 202001010000 {} \;
q prune --older-than 30d >/dev/null 2>&1; rc_is "prune exits 0" $? 0
grep -rq 'Old and unanswered' "$CLAUDE_QUESTIONS_DIR" 2>/dev/null \
  && ok "an OPEN question survives prune however old" \
  || bad "an OPEN question survives prune however old" "age makes it worth reading, not disposable"
# `a && bad || ok` fires BOTH when bad's own last command returns non-zero.
if grep -rq 'Old and closed' "$CLAUDE_QUESTIONS_DIR" 2>/dev/null
then bad "a closed one is pruned"; else ok "a closed one is pruned"; fi
q prune >/dev/null 2>&1; rc_is "prune without --older-than -> 2" $? 2

# --- stale filter -------------------------------------------------------------
reset; ask "Fresh one"
case "$(q --stale 7d 2>&1)" in *"Fresh one"*) bad "a fresh question is not stale" ;; *) ok "a fresh question is not stale" ;; esac
find "$CLAUDE_QUESTIONS_DIR" -name '*.md' -exec touch -t 202001010000 {} \;
case "$(q --stale 7d 2>&1)" in *"Fresh one"*) ok "an old one is" ;; *) bad "an old one is" ;; esac

# --- session naming -----------------------------------------------------------
q name "homelab bring-up" >/dev/null 2>&1
case "$(q --all 2>&1)" in *"homelab bring-up"*) ok "listings use the session name" ;;
  *) bad "listings use the session name" "$(q --all 2>&1)" ;; esac
rm -f "$CLAUDE_QUESTIONS_DIR/sess-aaaa/.name"
case "$(q --all 2>&1)" in *fresh-one*) ok "and fall back to the topic slug" ;;
  *) bad "and fall back to the topic slug" "$(q --all 2>&1)" ;; esac

# --- the reminder hook --------------------------------------------------------
reset
[ -z "$(sh "$HOOK" 2>&1)" ] && ok "hook is silent with no notes" || bad "hook is silent with no notes"
ask "Should deletes keep invoice numbers"
HID=$(idof should-deletes)
out=$(sh "$HOOK" 2>&1)
case "$out" in *"$HID"*) ok "hook names the open question" ;; *) bad "hook names the open question" "$out" ;; esac
case "$out" in *"questions answer"*) ok "and gives the exact command" ;; *) bad "and gives the exact command" ;; esac
case "$out" in *BEFORE*) ok "and says record before replying" ;; *) bad "and says record before replying" ;; esac
sh "$HOOK" >/dev/null 2>&1; rc_is "hook exits 0 — it reminds, never blocks" $? 0

q answer "$HID" "yes" >/dev/null 2>&1
[ -z "$(sh "$HOOK" 2>&1)" ] && ok "hook goes quiet once answered" || bad "hook goes quiet once answered"

# Another session's open question is not this human's to answer right now.
reset; ask "Mine"
out=$(CLAUDE_CODE_SESSION_ID=sess-bbbb sh "$HOOK" 2>&1)
[ -z "$out" ] && ok "hook ignores other sessions' questions" || bad "hook ignores other sessions' questions" "$out"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
