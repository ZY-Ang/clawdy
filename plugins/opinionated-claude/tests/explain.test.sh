#!/bin/sh
# The same thirty-five lines, reprinted on every block, bury the one line that
# changed. These cases are about how much a block says -- never about what it
# catches, which the three sibling suites own.
#
#   sh plugins/opinionated-claude/tests/explain.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK=$HERE/../hooks/no-announced-work
REFS=$HERE/../hooks/no-bare-refs
TMP=${TMPDIR:-/tmp}/explain-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "explain.test: jq required" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"
        [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

CLAUDE_HOOK_STATE_DIR=$TMP/explained; export CLAUDE_HOOK_STATE_DIR

# A session IS its transcript path, so a case wanting a second session writes a
# second file rather than pretending.
session() {
  printf '%s' "$2" | jq -Rs '{type:"assistant",message:{content:[{type:"text",text:.}]}}' \
    > "$TMP/$1.jsonl"
}

# block <hook> <session-file> -> stderr, with the exit code on the last line.
block() {
  _out=$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$TMP/$2.jsonl" \
           | sh "$1" 2>&1 >/dev/null; echo "rc=$?")
  printf '%s' "$_out"
}

lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }

ANNOUNCE="That is the conflict.

I'll rebase onto main and push."

session s1 "$ANNOUNCE"
session s2 "$ANNOUNCE"

# --- the first block still teaches -------------------------------------------
# Cutting the rationale everywhere would fix the noise by deleting the thing it
# is noise about. The model has to be told why once.
first=$(block "$HOOK" s1)
case "$first" in *"Nothing will resume this turn"*) ok "the first block prints the rationale" ;;
                 *) bad "the first block prints the rationale" "$first" ;; esac
case "$first" in *rc=2*) ok "and still blocks" ;; *) bad "and still blocks" "$first" ;; esac

# --- the second says the same thing in three lines ---------------------------
second=$(block "$HOOK" s1)
case "$second" in *"Nothing will resume this turn"*)
    bad "a repeat drops the rationale" "still printed in full" ;;
  *) ok "a repeat drops the rationale" ;; esac
case "$second" in *rc=2*) ok "a repeat still blocks" ;; *) bad "a repeat still blocks" "$second" ;; esac

n1=$(lines "$first"); n2=$(lines "$second")
[ "$n2" -lt 6 ] && ok "a repeat is under six lines ($n2)" \
                || bad "a repeat is under six lines" "$n2 lines"
[ "$n1" -gt "$n2" ] && ok "and shorter than the first ($n1 -> $n2)" \
                    || bad "and shorter than the first" "$n1 -> $n2"

# --- and it is still actionable ----------------------------------------------
# A one-liner that only says "blocked" is the caveman failure: shorter, and
# impossible to act on without going to look up what it means.
case "$second" in *no-announced-work*) ok "the short form names the rule" ;;
                  *) bad "the short form names the rule" "$second" ;; esac
case "$second" in *"i'll"*) ok "and quotes what tripped it" ;;
                  *) bad "and quotes what tripped it" "$second" ;; esac
case "$second" in *"say what you did"*) ok "and names the fix" ;;
                  *) bad "and names the fix" "$second" ;; esac

# The escape belongs in the SHORT form above all, because a turn writing about
# the guard is blocked repeatedly and by then the long form has stopped coming.
case "$second" in *CLAUDE_ALLOW_ASKING=1*) ok "and names the escape" ;;
                  *) bad "and names the escape" "$second" ;; esac
case "$second" in *CLAUDE_HOOK_VERBOSE=1*) ok "and how to get the long form back" ;;
                  *) bad "and how to get the long form back" "$second" ;; esac

# --- per session, not once ever ----------------------------------------------
# Keyed on the session, so tomorrow's session is taught too. A global "already
# explained" would silence the hook for every session after the first.
other=$(block "$HOOK" s2)
case "$other" in *"Nothing will resume this turn"*) ok "a different session is taught too" ;;
                 *) bad "a different session is taught too" "$other" ;; esac

# --- per hook, not once per session ------------------------------------------
# no-bare-refs has never explained itself in this session, whatever its siblings
# have said.
session r1 "Filed #64, then #65."
r=$(block "$REFS" r1)
case "$r" in *"A reader cannot tell"*) ok "each hook explains itself once" ;;
             *) bad "each hook explains itself once" "$r" ;; esac

# --- the long form on demand -------------------------------------------------
v=$(CLAUDE_HOOK_VERBOSE=1 block "$HOOK" s1)
case "$v" in *"Nothing will resume this turn"*) ok "CLAUDE_HOOK_VERBOSE=1 brings it back" ;;
             *) bad "CLAUDE_HOOK_VERBOSE=1 brings it back" "$v" ;; esac

# --- unable to remember -> keep explaining -----------------------------------
# The failure has a direction: repeating an explanation costs a screen, losing
# it costs the model the reason it was blocked.
: > "$TMP/not-a-dir"
u=$(CLAUDE_HOOK_STATE_DIR=$TMP/not-a-dir/sub block "$HOOK" s1)
case "$u" in *"Nothing will resume this turn"*) ok "an unusable state dir stays verbose" ;;
             *) bad "an unusable state dir stays verbose" "$u" ;; esac
case "$u" in *rc=2*) ok "and still blocks" ;; *) bad "and still blocks" "$u" ;; esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
