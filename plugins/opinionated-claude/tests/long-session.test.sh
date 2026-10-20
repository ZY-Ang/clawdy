#!/bin/sh
# The Stop hooks run under a 10 s timeout. A long session must neither slow them
# down nor change their verdict: they judge the current turn only.
#
#   sh plugins/opinionated-claude/tests/long-session.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOKS=$HERE/../hooks
TMP=${TMPDIR:-/tmp}/long-session-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
CLAUDE_HOOK_STATE_DIR=$TMP/explained; export CLAUDE_HOOK_STATE_DIR
command -v jq >/dev/null 2>&1 || { echo "long-session.test: jq required" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

# One earlier turn, about 10 KB of small lines, with a Monitor armed in it.
{ printf '{"type":"user","message":{"role":"user","content":"carry on"},"sessionId":"s"}\n'
  i=0
  while [ $i -lt 20 ]; do
    name=Bash; [ $i -eq 0 ] && name=Monitor
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t%s","name":"%s","input":{"command":"ls -la","description":"List"}}]},"sessionId":"s"}\n' $i $name
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":[{"type":"text","text":"file one\\nfile two\\nfile three, padded out with a few more words"}]}]},"sessionId":"s","toolUseResult":{"stdout":"file one\\nfile two","stderr":""}}\n' $i
    i=$((i+1))
  done
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done, all green."}]},"sessionId":"s"}\n'
} > "$TMP/block"

# grow <file> <times>  -- double the file in place
grow() { n=0; while [ $n -lt "$2" ]; do cat "$1" "$1" > "$1.2" && mv "$1.2" "$1"; n=$((n+1)); done; }

# About 90 MB of earlier turns: on the old full-file parse this took 4-9 s per hook.
cp "$TMP/block" "$TMP/prefix"; grow "$TMP/prefix" 13

# About 800 KB of tool results, for a current turn bigger than the first window.
grep tool_result "$TMP/block" > "$TMP/results"; grow "$TMP/results" 7

# final <text> [tool-name] [results-file]  -- the current turn, into $TMP/final
final() {
  { printf '{"type":"user","message":{"content":"go"}}\n'
    if [ -n "${2:-}" ]; then
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"%s","input":{"command":"x"}}]}}\n' "$2"
      [ -n "${3:-}" ] && cat "$3"
    fi
    printf '%s' "$1" | jq -Rc '{type:"assistant",message:{content:[{type:"text",text:.}]}}'
  } > "$TMP/final"
}

# run <hook> <transcript>  -> "<exit> <whole seconds>"
run() {
  s=$(date +%s)
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$2" | sh "$HOOKS/$1" >/dev/null 2>&1
  rc=$?
  echo "$rc $(( $(date +%s) - s ))"
}

# check <name> <hook> <want-exit>  -- $TMP/final alone, then after the long prefix
check() {
  cp "$TMP/final" "$TMP/small.jsonl"
  cat "$TMP/prefix" "$TMP/final" > "$TMP/long.jsonl"
  set -- "$1" "$2" "$3" $(run "$2" "$TMP/small.jsonl") $(run "$2" "$TMP/long.jsonl")
  if [ "$4" -eq "$3" ] && [ "$6" -eq "$3" ]; then ok "$1: exit $3, short and long session"
  else bad "$1: exit $3, short and long session" "short exit $4, long exit $6"; fi
  # Whole seconds: 1 or less means under 2 s, a fifth of the timeout.
  if [ "$7" -le 1 ]; then ok "$1: under 2 s on a long session"
  else bad "$1: under 2 s on a long session" "took about ${7}s"; fi
}

final "Done. Want me to open the PR?";      check "asking blocks"   no-permission-asking 2
final "Pushed; the PR is open.";            check "asking allows"   no-permission-asking 0
# The prefix arms a Monitor in every earlier turn; only this turn counts.
final "Filing both now.";                   check "announced blocks" no-announced-work 2
final "Filing both now." Monitor;           check "announced allows when armed" no-announced-work 0
final "Filed #64.";                         check "refs blocks"     no-bare-refs 2
final "Filed https://github.com/o/r/issues/64."; check "refs allows" no-bare-refs 0

# The armed call sits about 800 KB back, beyond the first window.
final "Filing both now." Monitor "$TMP/results";      check "announced finds an armed call far back in a big turn" no-announced-work 0

# Only the current turn is read: an unparseable line well before it is never seen.
printf 'not json\n' > "$TMP/corrupt"
cp "$TMP/block" "$TMP/tail"; grow "$TMP/tail" 6
judged() {
  final "$3"
  cat "$TMP/corrupt" "$TMP/tail" "$TMP/final" > "$TMP/c.jsonl"
  set -- "$1" "$2" $(run "$2" "$TMP/c.jsonl")
  if [ "$3" -eq 2 ]; then ok "$1: blocks without parsing earlier lines"
  else bad "$1: blocks without parsing earlier lines" "exit $3"; fi
}
judged "asking"    no-permission-asking "Want me to open the PR?"
judged "announced" no-announced-work    "Filing both now."
judged "refs"      no-bare-refs         "Filed #64."

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
