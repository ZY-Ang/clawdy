#!/bin/sh
# Exercise every branch of pr-watch's gate without gh, auth or the network.
#
#   sh plugins/devloop/tests/pr-watch.test.sh
#
# pr-watch reads PR_WATCH_JSON in place of calling gh, so the fixtures below are
# gh-shaped JSON. Each case asserts an exit code, because the exit code is what a
# loop branches on -- a wrong one is the failure that matters, not wrong wording.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/pr-watch
TMP=${TMPDIR:-/tmp}/pr-watch-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

PASS='[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'
FAIL='[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE"}]'
PEND='[{"__typename":"CheckRun","name":"build","status":"IN_PROGRESS","conclusion":null}]'
CTXP='[{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}]'
CTXF='[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]'
CTXQ='[{"__typename":"StatusContext","context":"ci/legacy","state":"PENDING"}]'

fails=0 ran=0

# case <name> <want-exit> <isDraft> <state> <mergeable> <mergeStateStatus> <review> <rollup>
case_() {
  name=$1 want=$2
  cat > "$TMP/$name.json" <<EOF
{"number":42,"title":"Add a thing that works","isDraft":$3,"state":"$4",
 "mergeable":"$5","mergeStateStatus":"$6","reviewDecision":$7,
 "statusCheckRollup":$8}
EOF
  assert "$name" "$want"
}

assert() {
  ran=$((ran + 1))
  out=$(PR_WATCH_JSON="$TMP/$1.json" sh "$BIN" 2>&1); rc=$?
  if [ "$rc" -eq "$2" ]; then
    printf 'ok   %-22s exit %s\n' "$1" "$rc"
  else
    fails=$((fails + 1))
    printf 'FAIL %-22s exit %s, wanted %s\n' "$1" "$rc" "$2"
    printf '%s\n' "$out" | sed 's/^/       | /'
  fi
}

# --- exit 0: nothing left on our side ---------------------------------------
case_ clean-approved    0 false OPEN MERGEABLE CLEAN     '"APPROVED"'        "$PASS"
case_ clean-noreview    0 false OPEN MERGEABLE CLEAN     'null'              "$PASS"
case_ clean-reviewreq   0 false OPEN MERGEABLE CLEAN     '"REVIEW_REQUIRED"' "$PASS"
case_ no-checks         0 false OPEN MERGEABLE CLEAN     'null'              '[]'
case_ has-hooks         0 false OPEN MERGEABLE HAS_HOOKS '"APPROVED"'        "$PASS"
case_ ctx-pass          0 false OPEN MERGEABLE CLEAN     'null'              "$CTXP"
# Green, no conflicts, waiting only on a required review: the one moment asking
# for review is correct. Reporting this as "not ready" would stall the loop.
case_ blocked-reviewreq 0 false OPEN MERGEABLE BLOCKED   '"REVIEW_REQUIRED"' "$PASS"

# --- exit 1: not ready, and it must say why ---------------------------------
# Already approved yet still BLOCKED means a required check or ruleset is unmet,
# which is a different situation from the case above and must not pass.
case_ blocked-approved  1 false OPEN   MERGEABLE   BLOCKED  '"APPROVED"'          "$PASS"
case_ behind            1 false OPEN   MERGEABLE   BEHIND   'null'                "$PASS"
case_ unstable          1 false OPEN   MERGEABLE   UNSTABLE 'null'                "$PASS"
case_ dirty             1 false OPEN   CONFLICTING DIRTY    'null'                "$PASS"
case_ mergeable-unknown 1 false OPEN   UNKNOWN     UNKNOWN  'null'                "$PASS"
case_ draft             1 true  OPEN   MERGEABLE   DRAFT    'null'                "$PASS"
case_ failed-checks     1 false OPEN   MERGEABLE   UNSTABLE 'null'                "$FAIL"
case_ pending-checks    1 false OPEN   MERGEABLE   UNSTABLE 'null'                "$PEND"
case_ changes-requested 1 false OPEN   MERGEABLE   BLOCKED  '"CHANGES_REQUESTED"' "$PASS"
case_ merged            1 false MERGED MERGEABLE   CLEAN    '"APPROVED"'          "$PASS"
case_ closed            1 false CLOSED UNKNOWN     UNKNOWN  'null'                "$PASS"
case_ ctx-fail          1 false OPEN   MERGEABLE   UNSTABLE 'null'                "$CTXF"
case_ ctx-pending       1 false OPEN   MERGEABLE   UNSTABLE 'null'                "$CTXQ"

# --- exit 2: could not tell. Never 0. ---------------------------------------
echo '{ not json'  > "$TMP/malformed.json"; assert malformed 2
: > "$TMP/empty.json";                      assert empty     2

# --- fields that must survive the shell ------------------------------------
# A null reviewDecision used to render as an empty TSV field; tab is an IFS
# whitespace character, so the shell collapsed the run and every later field
# shifted by one. Both of these regress that.
printf '%s\n' '{"number":7,"title":"\tfix\ttabs","isDraft":false,"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":null,"statusCheckRollup":[]}' > "$TMP/tab-title.json"
assert tab-title 0
printf '%s\n' '{"number":8,"title":"","isDraft":false,"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":null,"statusCheckRollup":[]}' > "$TMP/empty-title.json"
assert empty-title 0

# --- argument handling ------------------------------------------------------
ran=$((ran + 1))
sh "$BIN" --nonsense >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' unknown-option
else fails=$((fails + 1)); printf 'FAIL %-22s did not reject\n' unknown-option; fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
