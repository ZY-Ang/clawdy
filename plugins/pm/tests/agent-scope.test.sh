#!/bin/sh
# Several agents, one tracker. Ordering says what is most important; nothing
# said whose lane it is, so any agent could claim work another filed.
#
#   sh plugins/pm/tests/agent-scope.test.sh
#
# Fixtures throughout -- the queue reads BACKLOG_ISSUES_JSON and the claim reads
# BACKLOG_ISSUE_JSON, so none of this needs a backend.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
LIB=$HERE/../lib
TMP=${TMPDIR:-/tmp}/agent-scope-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

command -v jq >/dev/null 2>&1 || { echo "agent-scope.test: jq required" >&2; exit 1; }
. "$HERE/lib/gh-free.sh"
PATH=$(gh_free_path "$TMP/nogh"); export PATH

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"
        [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

# ---------------------------------------------------------------------------
# the library, on its own
# ---------------------------------------------------------------------------
. "$LIB/agent-scope.sh"

unset PM_AGENT 2>/dev/null || true
AGENT_OVERRIDE=""
[ -z "$(agent_name)" ]  && ok "unset: no name"           || bad "unset: no name" "got '$(agent_name)'"
[ -z "$(agent_label)" ] && ok "unset: no label"          || bad "unset: no label" "got '$(agent_label)'"

PM_AGENT=worker-1
[ "$(agent_name)" = worker-1 ]        && ok "PM_AGENT read"    || bad "PM_AGENT read" "$(agent_name)"
[ "$(agent_label)" = agent-worker-1 ] && ok "label form"       || bad "label form" "$(agent_label)"

AGENT_OVERRIDE=worker-2
[ "$(agent_name)" = worker-2 ] && ok "--agent beats PM_AGENT" || bad "--agent beats PM_AGENT" "$(agent_name)"
AGENT_OVERRIDE=""

# A name with a space becomes two labels, the second of which scopes nothing.
agent_name_ok "worker-1"   && ok "plain name accepted"      || bad "plain name accepted"
agent_name_ok "a.b_c-1"    && ok "dot underscore hyphen ok" || bad "dot underscore hyphen ok"
agent_name_ok "two words"  && bad "a space is refused"      || ok "a space is refused"
agent_name_ok ""           && bad "empty is refused"        || ok "empty is refused"

[ "$(agent_owner task agent-w2 size-s)" = w2 ] && ok "owner read from labels" \
                                               || bad "owner read from labels" "$(agent_owner task agent-w2 size-s)"
[ -z "$(agent_owner task size-s)" ] && ok "no owner when unlabelled" || bad "no owner when unlabelled"

PM_AGENT=worker-1
agent_may_claim task size-s          && ok "own agent: unlabelled claimable"  || bad "own agent: unlabelled claimable"
agent_may_claim task agent-worker-1  && ok "own agent: own item claimable"    || bad "own agent: own item claimable"
agent_may_claim task agent-worker-2  && bad "own agent: other refused"        || ok "own agent: other refused"
unset PM_AGENT
agent_may_claim task agent-worker-2  && ok "unset claims anything"            || bad "unset claims anything"

# ---------------------------------------------------------------------------
# backlog-queue
# ---------------------------------------------------------------------------
cat > "$TMP/issues.json" <<'JSON'
[
 {"number":1,"title":"mine","state":"OPEN","createdAt":"2026-01-01T00:00:00Z",
  "labels":[{"name":"task"},{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-s"},{"name":"agent-worker-1"}]},
 {"number":2,"title":"theirs","state":"OPEN","createdAt":"2026-01-01T00:00:00Z",
  "labels":[{"name":"task"},{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-s"},{"name":"agent-worker-2"}]},
 {"number":3,"title":"nobody's","state":"OPEN","createdAt":"2026-01-01T00:00:00Z",
  "labels":[{"name":"task"},{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-s"}]}
]
JSON

q() { BACKLOG_ISSUES_JSON=$TMP/issues.json BACKLOG_NOW=1800000000 "$BIN/backlog-queue" "$@" 2>&1; }

out=$(PM_AGENT=worker-1 q)
case "$out" in
  *"#1"*) case "$out" in *"#2"*) bad "queue hides another agent" "listed #2" ;;
                         *) case "$out" in *"#3"*) ok "queue keeps own and unlabelled" ;;
                                           *) bad "queue keeps own and unlabelled" "no #3" ;; esac ;; esac ;;
  *) bad "queue keeps own and unlabelled" "no #1 in: $out" ;;
esac

out=$(PM_AGENT=worker-1 q --all)
case "$out" in *"#2"*) ok "--all shows every lane" ;; *) bad "--all shows every lane" "$out" ;; esac

out=$(q)   # PM_AGENT unset
case "$out" in *"#2"*) ok "unset shows every lane" ;; *) bad "unset shows every lane" "$out" ;; esac

out=$(PM_AGENT=worker-1 q --agent worker-2)
case "$out" in *"#2"*) ok "--agent overrides for the queue too" ;;
               *) bad "--agent overrides for the queue too" "$out" ;; esac

# Hidden, not silently vanished: --blocked must account for it.
out=$(PM_AGENT=worker-1 q --blocked)
case "$out" in *"labelled for agent worker-2"*) ok "--blocked names the lane" ;;
               *) bad "--blocked names the lane" "$out" ;; esac

# ---------------------------------------------------------------------------
# backlog-claim -- the guardrail. A queue filter alone is routed around by
# claiming the number directly.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/repo" && cd "$TMP/repo"
git init -q . 2>/dev/null; git config user.email a@b; git config user.name t
git commit -q --allow-empty -m init 2>/dev/null

claim_of() {   # <labels-json> ; prints "exit|first stderr line"
  printf '{"number":9,"title":"a thing","state":"OPEN","labels":%s}\n' "$1" > "$TMP/one.json"
  _e=$(BACKLOG_ISSUE_JSON=$TMP/one.json "$BIN/backlog-claim" 9 --dry-run 2>&1 >/dev/null; echo "rc=$?")
  printf '%s|%s' "${_e##*rc=}" "$(printf '%s' "$_e" | head -1)"
}

r=$(PM_AGENT=worker-1 claim_of '[{"name":"agent-worker-2"}]')
case "$r" in 1\|*belongs\ to\ agent*) ok "claim refuses another agent" ;;
             *) bad "claim refuses another agent" "$r" ;; esac

r=$(PM_AGENT=worker-1 claim_of '[{"name":"agent-worker-1"}]')
case "$r" in 1\|*belongs\ to\ agent*) bad "claim allows own item" "$r" ;;
             *) ok "claim allows own item" ;; esac

r=$(PM_AGENT=worker-1 claim_of '[{"name":"task"}]')
case "$r" in 1\|*belongs\ to\ agent*) bad "claim allows unlabelled" "$r" ;;
             *) ok "claim allows unlabelled" ;; esac

r=$(claim_of '[{"name":"agent-worker-2"}]')   # PM_AGENT unset
case "$r" in 1\|*belongs\ to\ agent*) bad "unset claims anything" "$r" ;;
             *) ok "unset claims anything" ;; esac

r=$(PM_AGENT=worker-1 claim_of '[{"name":"agent-worker-2"}]' )
case "$r" in 1\|*) ok "refusal exits 1, not 2" ;; *) bad "refusal exits 1, not 2" "$r" ;; esac

# ---------------------------------------------------------------------------
# file-issue and ask-async -- the stamp, and the note that replays it
# ---------------------------------------------------------------------------
GH_ARGS=$TMP/gh-args; export GH_ARGS
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$GH_ARGS"\n[ "$1" = "label" ] && exit 0\necho "https://github.com/o/r/issues/42"\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
CLAUDE_QUESTIONS_DIR=$TMP/q; export CLAUDE_QUESTIONS_DIR
AX="--priority med --urgency low --size s"

filed() { : > "$GH_ARGS"; rm -rf "$TMP/q"; mkdir -p "$TMP/q"
          PATH="$TMP/bin:$PATH" sh "$BIN/file-issue" task "$1" $AX --body b >/dev/null 2>&1
          cat "$GH_ARGS"; }

out=$(PM_AGENT=worker-1 filed "stamped")
case "$out" in *agent-worker-1*) ok "file-issue stamps the agent label" ;;
               *) bad "file-issue stamps the agent label" "$out" ;; esac

out=$(filed "unstamped")
case "$out" in *agent-*) bad "unset stamps nothing" "$out" ;; *) ok "unset stamps nothing" ;; esac

out=$(PM_AGENT="two words" filed "bad name")
case "$out" in *agent-*) bad "an unusable name is refused, not stamped" "$out" ;;
               *) ok "an unusable name is refused, not stamped" ;; esac

# The note carries it, so `questions sync` re-files into the same lane rather
# than replaying the question unlabelled.
#
# `find -exec grep -q` is NOT the assertion here. With no notes on disk find
# still exits 0, so both directions of that test pass whatever the code does --
# which is how the first draft of this reported a green stamp for a run that
# had filed nothing at all.
asked() {   # <question> ; writes notes under $TMP/q, prints the count found
  rm -rf "$TMP/q"; mkdir -p "$TMP/q"
  PATH="$TMP/bin:$PATH" sh "$BIN/ask-async" "$1" --blocked-on decision \
    --irreversible "it posts to a shared tracker" --context c --assume a >/dev/null 2>&1
  find "$TMP/q" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
}
noteline() { find "$TMP/q" -name '*.md' -type f -exec cat {} + 2>/dev/null | sed -n "s/^- $1: //p" | head -1; }

n=$(PM_AGENT=worker-1 asked "which one?")
if [ "$n" -eq 0 ]; then bad "the note records the agent" "ask-async wrote no note"
elif [ "$(noteline agent)" = worker-1 ]; then ok "the note records the agent"
else bad "the note records the agent" "agent field: '$(noteline agent)'"; fi

n=$(asked "no agent?")
if [ "$n" -eq 0 ]; then bad "unset writes no agent line" "ask-async wrote no note"
elif [ -z "$(noteline agent)" ]; then ok "unset writes no agent line"
else bad "unset writes no agent line" "agent field: '$(noteline agent)'"; fi

# sync replays it: the axis loop must carry `agent` or the lane is lost on retry.
grep -q 'for _ax in .*agent' "$BIN/questions" && ok "sync replays the agent field" \
  || bad "sync replays the agent field" "questions does not replay agent"

cd "$HERE"
echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
