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

# --- an external provider stands in for gh ----------------------------------
# The gate logic is the part worth sharing; the host-specific fetch is not. A
# provider is any executable answering three verbs, so an operator can point
# pr-watch at private review infrastructure without forking the script.
mkprov() {
  cat > "$TMP/prov" <<PROV
#!/bin/sh
echo "\$@" >> "$TMP/prov.log"
case "\$1" in
  list) printf '42\\n43\\n' ;;
  view) cat "$TMP/$1.json" ;;
  wait) exit ${2:-3} ;;
esac
PROV
  chmod +x "$TMP/prov"
}

prov_assert() {
  ran=$((ran + 1))
  out=$(PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" ${3:-} 2>&1); rc=$?
  if [ "$rc" -eq "$2" ]; then printf 'ok   %-22s exit %s\n' "$1" "$rc"
  else fails=$((fails + 1)); printf 'FAIL %-22s exit %s, wanted %s\n' "$1" "$rc" "$2"
       printf '%s\n' "$out" | sed 's/^/       | /'; fi
}

: > "$TMP/prov.log"; mkprov clean-approved
prov_assert provider-view 0

# The verb and the id both have to reach the provider, or --all fetches the
# wrong PR and every verdict is about someone else's branch.
ran=$((ran + 1))
: > "$TMP/prov.log"; mkprov clean-approved
PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 >/dev/null 2>&1
if grep -qx 'view 42' "$TMP/prov.log"
then printf 'ok   %-22s\n' provider-gets-id
else fails=$((fails + 1)); printf 'FAIL %-22s log: %s\n' provider-gets-id "$(cat "$TMP/prov.log")"; fi

# --all was unreachable through the old file seam: it called gh directly, so
# the multi-PR path had no test at all.
ran=$((ran + 1))
: > "$TMP/prov.log"; mkprov clean-approved
out=$(PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" --all 2>&1)
if grep -qx list "$TMP/prov.log" && grep -qx 'view 42' "$TMP/prov.log" && grep -qx 'view 43' "$TMP/prov.log"
then printf 'ok   %-22s\n' provider-all-lists
else fails=$((fails + 1)); printf 'FAIL %-22s log: %s\n' provider-all-lists "$(cat "$TMP/prov.log" | tr '\n' ' ')"; fi

# A provider that cannot answer is "could not tell", never "ready". This is the
# exit code the whole loop branches on, so it gets pinned directly.
ran=$((ran + 1))
cat > "$TMP/broken" <<'BROKEN'
#!/bin/sh
exit 9
BROKEN
chmod +x "$TMP/broken"
PR_WATCH_PROVIDER="$TMP/broken" sh "$BIN" >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' provider-fails
else fails=$((fails + 1)); printf 'FAIL %-22s did not report 2\n' provider-fails; fi

ran=$((ran + 1))
PR_WATCH_PROVIDER="$TMP/does-not-exist" sh "$BIN" >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' provider-missing
else fails=$((fails + 1)); printf 'FAIL %-22s did not report 2\n' provider-missing; fi

# The file seam is what the cases above all use, so it must keep winning over a
# provider -- otherwise setting PR_WATCH_PROVIDER in a shell silently rewrites
# every fixture-based result in this file.
ran=$((ran + 1))
mkprov behind
out=$(PR_WATCH_JSON="$TMP/clean-approved.json" PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 2>&1)
if [ $? -eq 0 ]; then printf 'ok   %-22s file seam wins\n' provider-vs-json
else fails=$((fails + 1)); printf 'FAIL %-22s provider overrode PR_WATCH_JSON\n' provider-vs-json; fi

# --wait: a provider that implements it is called once and believed. The exit
# code is asserted too: the branch that skips the poll is an AND-list under
# set -e, and getting that wrong swallows the verdict rather than printing it.
ran=$((ran + 1))
: > "$TMP/prov.log"; mkprov clean-approved 0
out=$(PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 --wait 2>&1); rc=$?
if grep -qx 'wait 42' "$TMP/prov.log" && [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'READY TO MERGE'
then printf 'ok   %-22s exit 0, verdict printed\n' provider-wait-used
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s log: %s out: %s\n' provider-wait-used "$rc" "$(cat "$TMP/prov.log" | tr '\n' ' ')" "$out"; fi

# --wait: a provider that opts out (exit 3) must not stall the loop -- pr-watch
# polls view itself, so waiting works on every backend rather than only the
# ones that implemented it.
ran=$((ran + 1))
: > "$TMP/prov.log"
cat > "$TMP/pollprov" <<POLL
#!/bin/sh
echo "\$@" >> "$TMP/prov.log"
case "\$1" in
  wait) exit 3 ;;
  view) n=\$(grep -c '^view' "$TMP/prov.log")
        if [ "\$n" -lt 2 ]; then cat "$TMP/pending-checks.json"
        else cat "$TMP/clean-approved.json"; fi ;;
esac
POLL
chmod +x "$TMP/pollprov"
out=$(PR_WATCH_PROVIDER="$TMP/pollprov" PR_WATCH_INTERVAL=0 sh "$BIN" 42 --wait 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^view' "$TMP/prov.log")" -ge 2 ]
then printf 'ok   %-22s polled to settled\n' provider-wait-polls
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s, views %s\n' provider-wait-polls "$rc" "$(grep -c '^view' "$TMP/prov.log")"; fi

# --- argument handling ------------------------------------------------------
ran=$((ran + 1))
sh "$BIN" --nonsense >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' unknown-option
else fails=$((fails + 1)); printf 'FAIL %-22s did not reject\n' unknown-option; fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
