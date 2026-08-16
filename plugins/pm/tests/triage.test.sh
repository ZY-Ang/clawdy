#!/bin/sh
# What is wrong with the backlog itself. Every case is a shape measured on a
# real backlog, and both directions are pinned: a check that only ever fires is
# indistinguishable from one that always fires.
#
#   sh plugins/pm/tests/triage.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/backlog-triage
TMP=${TMPDIR:-/tmp}/triage-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null || { echo "triage.test: jq required" >&2; exit 1; }

export BACKLOG_NOW=1787184000          # 2026-08-20T00:00:00Z
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

iss()  { cat > "$TMP/i.json"; }
deps() { cat > "$TMP/d.json"; }
t()    { BACKLOG_ISSUES_JSON="$TMP/i.json" sh "$BIN" "$@" 2>&1; }
td()   { BACKLOG_ISSUES_JSON="$TMP/i.json" BACKLOG_DEPS_JSON="$TMP/d.json" sh "$BIN" "$@" 2>&1; }
rc()   { BACKLOG_ISSUES_JSON="$TMP/i.json" sh "$BIN" "$@" >/dev/null 2>&1; echo $?; }
rcd()  { BACKLOG_ISSUES_JSON="$TMP/i.json" BACKLOG_DEPS_JSON="$TMP/d.json" sh "$BIN" "$@" >/dev/null 2>&1; echo $?; }

CLEAN='[{"number":2,"title":"ok","state":"OPEN",
 "labels":[{"name":"task"},{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
 "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[],"blockedBy":[]}]'

# --- a clean backlog is silent and exits 0 -----------------------------------
printf '%s' "$CLEAN" > "$TMP/i.json"
[ "$(rc)" -eq 0 ] && ok "a clean backlog exits 0" || bad "clean -> 0" "$(t)"
case "$(t)" in *"nothing to fix"*) ok "and says so" ;; *) bad "says nothing to fix" "$(t)" ;; esac

# --- cycles: the one that always means 1 -------------------------------------
printf '%s' "$CLEAN" > "$TMP/i.json"
deps <<'JSON'
[{"number":1,"blockedBy":[2]},{"number":2,"blockedBy":[3]},{"number":3,"blockedBy":[1]}]
JSON
[ "$(rcd --only cycles)" -eq 1 ] && ok "a seeded cycle exits non-zero" || bad "cycle -> 1" "$(td --only cycles)"
case "$(td --only cycles)" in *"1 -> 2 -> 3 -> 1"*) ok "and names the whole loop" ;; *) bad "names the loop" "$(td --only cycles)" ;; esac
# Reported once, not once per member -- three lines for one problem reads as three.
c=$(td --only cycles | grep -c ' -> ')
[ "$c" -eq 1 ] && ok "one cycle is reported once, not once per member" || bad "cycle dedup" "got $c lines"

deps <<'JSON'
[{"number":1,"blockedBy":[2]},{"number":2,"blockedBy":[]}]
JSON
[ "$(rcd --only cycles)" -eq 0 ] && ok "an acyclic graph is not a cycle" || bad "acyclic -> 0" "$(td --only cycles)"

# A two-node loop is the shape most likely to be missed by a dedup keyed on the
# raw path: its two rotations are 1->2->1 and 2->1->2.
deps <<'JSON'
[{"number":1,"blockedBy":[2]},{"number":2,"blockedBy":[1]}]
JSON
c=$(td --only cycles | grep -c ' -> ')
[ "$c" -eq 1 ] && ok "a two-node loop reports once" || bad "two-node dedup" "got $c"

# --- the deps seam REPLACES, so a case states its whole graph -----------------
iss <<'JSON'
[{"number":1,"title":"a","state":"OPEN","labels":[{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[],"blockedBy":[{"number":2}]},
 {"number":2,"title":"b","state":"OPEN","labels":[{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[],"blockedBy":[{"number":1}]}]
JSON
deps <<'JSON'
[{"number":1,"blockedBy":[]},{"number":2,"blockedBy":[]}]
JSON
[ "$(rcd --only cycles)" -eq 0 ] && ok "the deps seam replaces the issues' edges, never merges" \
  || bad "deps replaces" "$(td --only cycles)"
# and without the seam the same fixture DOES cycle, so the case above means something
[ "$(rc --only cycles)" -eq 1 ] && ok "and the same fixture cycles when the seam is unset" \
  || bad "fixture cycles unseamed" "$(t --only cycles)"

# --- stale claims -------------------------------------------------------------
iss <<'JSON'
[{"number":3,"title":"quiet","state":"OPEN","labels":[{"name":"claimed"},{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-m"}],
  "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(rc --only stale)" -eq 1 ] && ok "a claim quiet past STALE_HOURS is reported" || bad "stale -> 1" "$(t --only stale)"
case "$(t --only stale)" in *456h*) ok "and says how long" ;; *) bad "says how long" "$(t --only stale)" ;; esac
[ "$(BACKLOG_ISSUES_JSON=$TMP/i.json STALE_HOURS=9999 sh "$BIN" --only stale >/dev/null 2>&1; echo $?)" -eq 0 ] \
  && ok "STALE_HOURS moves the line" || bad "STALE_HOURS honoured"

iss <<'JSON'
[{"number":3,"title":"busy","state":"OPEN","labels":[{"name":"claimed"},{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-m"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(rc --only stale)" -eq 0 ] && ok "a fresh claim is not stale" || bad "fresh claim clean" "$(t --only stale)"

# --- missing axes -------------------------------------------------------------
iss <<'JSON'
[{"number":1,"title":"bare","state":"OPEN","labels":[{"name":"task"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(rc --only axes)" -eq 1 ] && ok "an issue with no axes is reported" || bad "axes -> 1" "$(t --only axes)"
case "$(t --only axes)" in *"missing priority, urgency, size"*) ok "and names which are missing" ;; *) bad "names missing axes" "$(t --only axes)" ;; esac
case "$(t --only axes)" in *"arrival order"*) ok "and says why a flat order is the failure" ;; *) bad "explains flatness" ;; esac

iss <<'JSON'
[{"number":1,"title":"partly","state":"OPEN","labels":[{"name":"priority-high"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[],"blockedBy":[]}]
JSON
case "$(t --only axes)" in *"missing urgency"*) ok "a partly-labelled issue names only the gap" ;; *) bad "partial axes" "$(t --only axes)" ;; esac

# A question is not queued, so it is not expected to carry ordering axes.
iss <<'JSON'
[{"number":1,"title":"a question","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[{"author":"a","body":"🤖\n\nq"}],"blockedBy":[]}]
JSON
[ "$(rc --only axes)" -eq 0 ] && ok "a needs-human issue is not asked for axes" || bad "question exempt from axes" "$(t --only axes)"

# --- needs-human, wrong in the direction that hides work ----------------------
iss <<'JSON'
[{"number":4,"title":"answered","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z",
  "comments":[{"author":"a","body":"🤖\n\nasking"},{"author":"h","body":"yes, do it"}],"blockedBy":[]}]
JSON
[ "$(rc --only human)" -eq 1 ] && ok "answered but still labelled is reported" || bad "human -> 1" "$(t --only human)"

iss <<'JSON'
[{"number":5,"title":"waiting","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z",
  "comments":[{"author":"a","body":"🤖\n\nasking"}],"blockedBy":[]}]
JSON
[ "$(rc --only human)" -eq 0 ] && ok "a genuinely unanswered question is left alone" || bad "unanswered clean" "$(t --only human)"

# The agent replying to its own question must not read as an answer -- that is
# the bug reply-issue was built for, seen from the other side.
iss <<'JSON'
[{"number":5,"title":"agent spoke last","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z",
  "comments":[{"author":"h","body":"go ahead"},{"author":"a","body":"🤖\n\ndone, one more thing"}],"blockedBy":[]}]
JSON
[ "$(rc --only human)" -eq 0 ] && ok "an agent replying last is still waiting, not answered" || bad "agent-last still waiting" "$(t --only human)"

# --- closed issues are not the backlog ---------------------------------------
iss <<'JSON'
[{"number":9,"title":"done","state":"CLOSED","labels":[{"name":"task"}],
  "createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T23:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(rc)" -eq 0 ] && ok "a closed issue is not triaged" || bad "closed ignored" "$(t)"

# --- could not tell is never clean --------------------------------------------
printf 'not json' > "$TMP/i.json"
[ "$(rc)" -eq 2 ] && ok "unparseable input -> 2, never 0" || bad "unparseable -> 2" "$(t)"
printf '%s' "$CLEAN" > "$TMP/i.json"
printf 'not json' > "$TMP/d.json"
[ "$(rcd --only cycles)" -eq 2 ] && ok "an unreadable deps file -> 2" || bad "bad deps -> 2" "$(td --only cycles)"

# --- flags --------------------------------------------------------------------
printf '%s' "$CLEAN" > "$TMP/i.json"
[ "$(rc --only nope)" -eq 2 ] && ok "an unknown --only value -> 2" || bad "bad --only -> 2"
[ "$(rc --nope)" -eq 2 ]      && ok "unknown option -> 2"          || bad "unknown option -> 2"
[ "$(rc --help)" -eq 0 ]      && ok "--help -> 0"                  || bad "--help -> 0"
[ "$(BACKLOG_ISSUES_JSON=$TMP/i.json STALE_HOURS=0 sh "$BIN" >/dev/null 2>&1; echo $?)" -eq 2 ] \
  && ok "STALE_HOURS below 1 -> 2" || bad "STALE_HOURS validated"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
