#!/bin/sh
# A turn that announces work never does it. Nothing resumes a turn on its own.
#
#   sh plugins/opinionated-claude/tests/announced.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK=$HERE/../hooks/no-announced-work
TMP=${TMPDIR:-/tmp}/announced-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "announced.test: jq required" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

say() {
  printf '%s' "$1" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' \
    > "$TMP/t.jsonl"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/t.jsonl" \
    | sh "$HOOK" >/dev/null 2>&1
  echo $?
}
blocks() { if [ "$(say "$2")" -eq 2 ]; then ok "$1"; else bad "$1" "not blocked"; fi; }
allows() { if [ "$(say "$2")" -eq 0 ]; then ok "$1"; else bad "$1" "blocked, should not be"; fi; }

# The armed exemption is a fact about this turn's TOOL CALLS, so the fixture has
# to contain one. Prose claiming a monitor is not a monitor.
#   turn <tool-name> <input-json> <final-text>  ->  exit code
turn() {
  { printf '{"type":"user","message":{"content":"go"}}\n'
    [ -n "$1" ] && printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":%s}]}}\n' "$1" "$2"
    printf '%s' "$3" | jq -Rc '{type:"assistant",message:{content:[{type:"text",text:.}]}}'
  } > "$TMP/t.jsonl"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/t.jsonl" | sh "$HOOK" >/dev/null 2>&1
  echo $?
}
armed()   { if [ "$(turn "$2" "$3" "$4")" -eq 0 ]; then ok "$1"; else bad "$1" "blocked, but something was armed"; fi; }
unarmed() { if [ "$(turn "$2" "$3" "$4")" -eq 2 ]; then ok "$1"; else bad "$1" "allowed, but nothing was armed"; fi; }

# --- the three from the real session -----------------------------------------
blocks "'Filing both now'"        "Both are worth tracking.

Filing both now, then continuing with the merged-PR sweep."
blocks "'Next, ... sweeping'"     "That covers the branch inventory.

Next, per the approved plan: sweeping the 46 merged pull requests for missing
closing links."
blocks "'Now backfilling'"        "The taxonomy is agreed.

Now backfilling across all 118 open issues."

# --- first-person promises ----------------------------------------------------
blocks "\"I'll rebase and push\"" "That is the conflict.

I'll rebase onto main and push."
blocks "'I will file it'"         "Worth its own issue.

I will file it against the pm plugin."
blocks "'about to'"               "Ready to go.

I am about to open the PR."
blocks "'next I'"                 "Step one is done.

Next I run the suite against the rebased head."

# --- EXEMPTION 1: telling the human what to do is not a promise ---------------
# This is the house closing format. Block it and the guard is the first thing
# switched off, so it gets three cases rather than one.
allows "'Next action:' for the human"  "Merged and green.

Next action: open the ruleset and add \`suite\` to required status checks."
allows "an imperative list"            "All three are green.

1. merge #31
2. merge #32
3. then run \`claude plugin update pm\`"
allows "'merge it, then run'"          "#32 is green on 0d529d3.

Merge it, then run the plugin update to pick up the new commands."

# The verbatim closing format this repo's own adhd skill prescribes. If this
# ever starts failing, the guard blocks correct output and will be turned off
# rather than fixed -- which is why it is pinned as its own case.
allows "the adhd closer, verbatim"     "Still open: #22, tracking backlog-triage.

Next action: open the ruleset page and add \`suite\` to required status checks --
two minutes, and it is the one that makes all that CI actually gate something."

# --- first-person progressive: the subject is the whole tell ------------------
# Raised in review on #36. "i am filing now" was caught only because the verb
# and the adverb happened to be adjacent. One object between them defeated it,
# and a sentence with no adverb at all never stood a chance.
blocks "'I am filing now'"           "Both are worth tracking.

I am filing now."
blocks "'I am filing BOTH now'"      "Both are worth tracking.

I am filing both now."
blocks "'I am starting the backfill' (no adverb anywhere)" "The taxonomy is agreed.

I am starting the backfill."
blocks "'I am running the sweep now'" "That covers the inventory.

I am running the sweep now."
blocks "\"I'm rebasing onto main\""   "That is the conflict.

I'm rebasing #28 onto main."
blocks "'We are sweeping' (plural)"  "Agreed on the plan.

We are sweeping the merged PRs."
# The past tense is what a report uses, and it must stay clear.
allows "'I filed both, then swept'"  "I filed both, then swept the merged PRs."

# --- the open class, and the closed one --------------------------------------
# Raised in review: why not just match every -ing form? Because a bare match
# blocks reports too. Measured on fifteen real sentences: 5/5 announcements
# caught, and all ten reports caught with them. The exclusions are what make it
# usable, and they are the closed class -- perception, cognition, state.
blocks "an -ing verb nobody listed"  "That is the plan.

I am provisioning the new volume."
blocks "another unlisted verb"       "Agreed.

I'm drafting the migration now."
allows "'I am seeing ...' (perception)"  "I am seeing 375 assertions pass."
allows "'I am holding ...' (state)"      "I am holding #28 in draft until #23 lands."
allows "\"I'm missing context\""         "I'm missing context on that one."
allows "'I am assuming ...' (cognition)" "I am assuming you meant the ordering half."
allows "'I am leaning towards ...'"      "I am leaning towards the narrower reading."
allows "'I am taking that as approval'"  "I am taking that as approval."

# --- EXEMPTION 2: armedness is read from the tool calls, not from the prose ----
# The first version matched phrases and was wrong in BOTH directions: it blocked
# "the suite is running; I will report when it lands" with a monitor genuinely
# armed, and allowed "Monitor armed. I will report the CI result." with nothing
# armed at all. The second is the one that matters -- an exemption an agent can
# claim by typing it is not a guard.
P="The suite is running; I will report when it lands."

armed   "a real Monitor call exempts it"      Monitor                '{}'                       "$P"
armed   "so does send_later"                  mcp__x__send_later     '{}'                       "$P"
armed   "so does a backgrounded Bash"         Bash                   '{"run_in_background":true}' "$P"
# A subagent runs in the background and notifies on completion -- the same
# return path as the other three. Task is Claude Code's name for the call.
# (#69: the list once omitted it, and a turn with a review agent genuinely in
# flight was blocked.)
armed   "so does a background agent"          Agent                  '{}'                       "$P"
armed   "so does Claude Code's Task call"     Task                   '{}'                       "$P"
unarmed "the same sentence, nothing armed"    ""                     '{}'                       "$P"
unarmed "a FOREGROUND Bash is not a return path" Bash                '{"run_in_background":false}' "$P"
unarmed "claiming 'Monitor armed' is not arming one" "" '{}' "Monitor armed.

I will report the CI result."

# --- reports, which look similar and must pass -------------------------------
allows "past tense report"        "Filed #41 and #42, both labelled task."
allows "'now green' after a verb" "Rebased onto a295971 and pushed. CI is now green."
allows "a plain result"           "Swept 46 merged PRs; 12 carried no closing link."

# --- safety rails -------------------------------------------------------------
ran=$((ran+1))
printf '%s' "I'll do it now." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
if printf '{"transcript_path":"%s","stop_hook_active":true}' "$TMP/t.jsonl" | sh "$HOOK" >/dev/null 2>&1
then ok "stop_hook_active stops it re-blocking"
else fails=$((fails+1)); printf 'FAIL stop_hook_active\n'; fi

ran=$((ran+1))
if printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | CLAUDE_ALLOW_ASKING=1 sh "$HOOK" >/dev/null 2>&1
then ok "CLAUDE_ALLOW_ASKING=1 overrides, same switch as the sibling"
else fails=$((fails+1)); printf 'FAIL escape hatch\n'; fi

ran=$((ran+1))
if printf '{"transcript_path":"/nope/missing.jsonl"}' | sh "$HOOK" >/dev/null 2>&1
then ok "a missing transcript stands down"
else fails=$((fails+1)); printf 'FAIL missing transcript\n'; fi

ran=$((ran+1))
if printf '' | sh "$HOOK" >/dev/null 2>&1
then ok "empty input stands down"; else fails=$((fails+1)); printf 'FAIL empty input\n'; fi

# --- the message has to say what to do instead --------------------------------
printf '%s' "Filing both now." | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' > "$TMP/t.jsonl"
out=$(printf '{"transcript_path":"%s"}' "$TMP/t.jsonl" | sh "$HOOK" 2>&1 >/dev/null)
case "$out" in *'Filed #41 and #42'*) ok "shows the replacement phrasing" ;; *) bad "replacement phrasing" ;; esac
case "$out" in *'arm something'*) ok "and the escape for work that cannot finish" ;; *) bad "names the arming escape" ;; esac
case "$out" in *HUMAN*) ok "and says telling the human is not what it blocks" ;; *) bad "names the human exemption" ;; esac
# The mention case: a message ABOUT the guard trips it, and the block must say
# so at the point of failure rather than leaving the agent to guess (#4).
case "$out" in *'merely MENTIONS'*) ok "and says a mention trips it too" ;; *) bad "and says a mention trips it too" ;; esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
