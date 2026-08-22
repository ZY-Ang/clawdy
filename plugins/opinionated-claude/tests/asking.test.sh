#!/bin/sh
# A turn that ends by asking permission is a hang: the work stops, the human is
# now blocking, and the answer was always going to be yes.
#
#   sh plugins/opinionated-claude/tests/asking.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK=$HERE/../hooks/no-permission-asking
TMP=${TMPDIR:-/tmp}/asking-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "asking.test: jq required" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }

# say <text> -> exit code of the hook for a turn ending in that text
say() {
  printf '%s' "$1" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' \
    > "$TMP/t.jsonl"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/t.jsonl" \
    | sh "$HOOK" >/dev/null 2>&1
  echo $?
}
blocks() { if [ "$(say "$2")" -eq 2 ]; then ok "$1"; else bad "$1" "not blocked"; fi; }
allows() { if [ "$(say "$2")" -eq 0 ]; then ok "$1"; else bad "$1" "blocked, should not be"; fi; }

# --- the ones observed in a real session -------------------------------------
blocks "'Want me to build it?'"          "Pushed the fix.

Want me to build the other half?"
blocks "'Should I ...?'"                 "Done.

Should I also update the docs?"
blocks "'Shall I ...?'"                  "Committed.

Shall I push this?"
blocks "'Would you like me to ...?'"     "Fixed.

Would you like me to open a PR?"
# The one that started this. It reads as decisive and is still a hang: the turn
# ends, and nothing happens until a human replies.
blocks "'unless you say otherwise'"      "That is the next thing.

I'll do it unless you say otherwise."
blocks "'say the word and'"              "Ready.

Say the word and I will merge it."
blocks "'let me know if you'"            "Deployed.

Let me know if you want the rollback too."

# --- handing the decision back, in a sentence that is not a question ----------
# The one that got through. It asks mid-line and closes with a statement, so the
# line ends in "." and the old end-of-line "?" anchor never fired.
blocks "asks mid-line, closes on 'your call'" "Next -- nonprd. Want me to build the flip now: set namespaceQualifiedSANsOnly true in nonprd values, devloop to mergeable, and hand you the merge? Or soak sbx a while first -- your call."
blocks "'your call' alone"                 "sbx is green.

Roll nonprd now or soak a week -- your call."
blocks "'up to you'"                       "Both work.

Up to you which one lands first."
blocks "'your choice'"                     "Ready either way.

Squash or rebase, your choice."
blocks "'whichever you prefer'"            "Done.

I can land it as one commit or three, whichever you prefer."
blocks "'let me know which'"               "Two options here.

Let me know which you want."
# A question mark anywhere after the phrase counts, not only at the line end.
blocks "question mark mid-line"           "Pushed.

Should I also bump the version? I will hold otherwise."

# --- the hand-back in imperative clothing --------------------------------------
# The exact sentence that prompted these, ending a turn where the tracked issue
# for the work was already open. An open issue IS the go-ahead.
blocks "'say go'"                       "#22 is still open, so nothing is lost.

Next action, if you want it: say go and I will build backlog-claim first."
blocks "'if you want it'"               "That is the remaining half.

The claim protocol is next if you want it."
blocks "'give me the word'"             "Branch is ready.

Give me the word and I will push."
blocks "'let me know when'"             "Done for now.

Let me know when you want the rest."
blocks "'happy to'"                     "That covers the ordering half.

Happy to build the claim half too."

# --- the window: the ask is the last SENTENCE, not the last line ---------------
# "say the word" was in the list from the start and still got through, which is
# why the guard read as intermittent. Three closing lines is not the tell -- a
# hand-back followed by next steps sits further back than that.
blocks "hand-back, then a numbered list" "Say the word and I will push.

1. merge #31
2. merge #32
3. then triage"
blocks "hand-back, then sign-off lines"  "Say the word and I will push.

Meanwhile the suite is green.

Nothing else is blocked.

That is everything."
blocks "'your call', then a list"        "Roll nonprd now or soak a week -- your call.

Either way:
- sbx stays as it is
- the cert rotates on its own"

# --- reporting, not asking ----------------------------------------------------
allows "reporting what was done"         "Pushed as abc1234. PR #20, 238 tests pass."
allows "stating an assumption instead"   "Two readings were possible. I took the narrower one --
kept the limits, dropped the arithmetic -- and said so in the commit."
allows "naming a filed question"         "Genuinely blocked on a credential, so I filed #41 and
carried on with the rest."
# A retrospective ABOUT asking is not asking. The tell is always at the end,
# which is why only the closing lines are scanned.
allows "discussing asking, in the middle" "I should have pushed it rather than asking.
Want me to is the phrase I keep reaching for, and it is a stall.

Fixed in 9fe9c24 -- the hook now blocks it."

# --- safety rails -------------------------------------------------------------
ran=$((ran+1))
printf '{"transcript_path":"%s","stop_hook_active":true}' "$TMP/t.jsonl" > "$TMP/in"
printf '%s' "Want me to?" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
if sh "$HOOK" < "$TMP/in" >/dev/null 2>&1; then ok "stop_hook_active stops it re-blocking"
else fails=$((fails+1)); printf 'FAIL stop_hook_active stops it re-blocking\n'; fi

ran=$((ran+1))
if printf '%s' "Want me to?" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl" &&
   printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | CLAUDE_ALLOW_ASKING=1 sh "$HOOK" >/dev/null 2>&1
then ok "CLAUDE_ALLOW_ASKING=1 overrides"
else fails=$((fails+1)); printf 'FAIL CLAUDE_ALLOW_ASKING=1 overrides\n'; fi

ran=$((ran+1))
if printf '{"transcript_path":"/nope/missing.jsonl"}' | sh "$HOOK" >/dev/null 2>&1
then ok "a missing transcript stands down rather than blocking"
else fails=$((fails+1)); printf 'FAIL missing transcript stands down\n'; fi

ran=$((ran+1))
if printf '' | sh "$HOOK" >/dev/null 2>&1
then ok "empty input stands down"; else fails=$((fails+1)); printf 'FAIL empty input stands down\n'; fi

# --- the message has to say what to do instead --------------------------------
printf '%s' "Want me to?" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
out=$(printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | sh "$HOOK" 2>&1 >/dev/null)
case "$out" in *'Pushed, PR #12'*) ok "shows the replacement phrasing" ;; *) bad "shows the replacement phrasing" ;; esac
case "$out" in *ask-async*) ok "and the escape for a real blocker" ;; *) bad "and the escape for a real blocker" ;; esac
# The mention case: a message ABOUT the guard trips it, and the block must say
# so at the point of failure rather than leaving the agent to guess (#4).
case "$out" in *'merely MENTIONS'*) ok "and says a mention trips it too" ;; *) bad "and says a mention trips it too" ;; esac
case "$out" in *'CLAUDE_ALLOW_ASKING=1'*) ok "and names the escape as the intended out" ;; *) bad "and names the escape as the intended out" ;; esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
