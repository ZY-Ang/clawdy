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
  *) exit 2 ;;
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

# --- what a broken provider must never look like ------------------------------
# Each of these is a shape a half-written provider actually takes. None may
# produce exit 0: that is the code a loop reads as "nothing left to do".
badprov() { printf '#!/bin/sh\n%s\n' "$1" > "$TMP/bad"; chmod +x "$TMP/bad"; }
bad_assert() {
  ran=$((ran + 1))
  PR_WATCH_PROVIDER="$TMP/bad" sh "$BIN" ${3:-} >/dev/null 2>&1; rc=$?
  if [ "$rc" -eq "$2" ]; then printf 'ok   %-22s exit %s\n' "$1" "$rc"
  else fails=$((fails + 1)); printf 'FAIL %-22s exit %s, wanted %s\n' "$1" "$rc" "$2"; fi
}

# Exits 0 and prints nothing. The header promises this is "could not tell".
badprov 'exit 0'
bad_assert view-silent-zero 2

# Prints a clean, ready pull request but exits non-zero. Status beats stdout --
# a provider that reported failure has not told us the PR is fine.
badprov 'cat '"$TMP"'/clean-approved.json; exit 1'
bad_assert view-json-but-fails 2

# A directory passes -x, then fails at exec with a message naming neither the
# variable nor the cause.
# The old -x-only guard also exited 2 here -- by failing at exec with
# "Permission denied", naming neither the variable nor the cause. The fix is
# the message, so the message is what gets asserted.
ran=$((ran + 1))
out=$(PR_WATCH_PROVIDER="$TMP" sh "$BIN" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'not an executable file' \
   && ! printf '%s' "$out" | grep -q 'Permission denied'
then printf 'ok   %-22s exit 2, names the variable\n' provider-is-a-dir
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s: %s\n' provider-is-a-dir "$rc" "$out"; fi

# A bare name is resolved on PATH: rejecting it would contradict the exec that
# follows, which would have found it.
ran=$((ran + 1))
mkprov clean-approved; cp "$TMP/prov" "$TMP/onpath"
out=$(PATH="$TMP:$PATH" PR_WATCH_PROVIDER=onpath sh "$BIN" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then printf 'ok   %-22s resolved on PATH\n' provider-bare-name
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s: %s\n' provider-bare-name "$rc" "$out"; fi

# A list that exits 0 printing nothing is genuinely indistinguishable from "no
# open pull requests", which IS exit 0. Pinned so the reading is deliberate:
# the guard against a silent fall-through is the provider's obligation to exit
# non-zero on an unknown verb, documented in the header, not something pr-watch
# can detect. Changing this to 2 would report every empty queue as a failure.
badprov 'case "$1" in list) exit 0 ;; *) exit 2 ;; esac'
bad_assert list-empty-is-zero 0 --all

# --- config that is a typo, not a value ---------------------------------------
# Both used to end the run at exit 1 with no verdict printed -- and dash and
# bash disagreed about which way. Exit 1 means "not ready, reason on stdout".
ran=$((ran + 1))
mkprov clean-approved
PR_WATCH_INTERVAL=abc PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 --wait >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' bad-interval
else fails=$((fails + 1)); printf 'FAIL %-22s\n' bad-interval; fi
ran=$((ran + 1))
PR_WATCH_TIMEOUT=abc PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 --wait >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' bad-timeout
else fails=$((fails + 1)); printf 'FAIL %-22s\n' bad-timeout; fi

# --- the file seam wins on --all too -----------------------------------------
# Otherwise the data comes from the fixture but the number of pull requests
# iterated comes from a live host, and a test run reaches the network.
ran=$((ran + 1))
: > "$TMP/prov.log"; mkprov clean-approved
PR_WATCH_JSON="$TMP/clean-approved.json" PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" --all >/dev/null 2>&1
if [ ! -s "$TMP/prov.log" ]; then printf 'ok   %-22s provider untouched\n' all-json-wins
else fails=$((fails + 1)); printf 'FAIL %-22s log: %s\n' all-json-wins "$(tr '\n' ' ' < "$TMP/prov.log")"; fi

# --- --all aggregates to the WORST outcome, in either order -------------------
# "could not tell" must not be masked by a merely-not-ready sibling.
ran=$((ran + 1))
cat > "$TMP/mixed" <<MIXED
#!/bin/sh
case "\$1" in
  list) printf '42\\n43\\n' ;;
  view) if [ "\$2" = 42 ]; then cat "$TMP/behind.json"; else exit 1; fi ;;
  *) exit 2 ;;
esac
MIXED
chmod +x "$TMP/mixed"
PR_WATCH_PROVIDER="$TMP/mixed" sh "$BIN" --all >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2 beats 1\n' all-worst-wins
else fails=$((fails + 1)); printf 'FAIL %-22s\n' all-worst-wins; fi

# The other order is the one that pins the guard: unreadable FIRST, then a
# merely-not-ready sibling, which must not overwrite the 2 with a 1.
ran=$((ran + 1))
cat > "$TMP/mixed2" <<MIXED2
#!/bin/sh
case "\$1" in
  list) printf '42\\n43\\n' ;;
  view) if [ "\$2" = 43 ]; then cat "$TMP/behind.json"; else exit 1; fi ;;
  *) exit 2 ;;
esac
MIXED2
chmod +x "$TMP/mixed2"
PR_WATCH_PROVIDER="$TMP/mixed2" sh "$BIN" --all >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s unreadable first still 2\n' all-worst-wins-rev
else fails=$((fails + 1)); printf 'FAIL %-22s\n' all-worst-wins-rev; fi

# --all must honour the view status too, not just its stdout -- the single-PR
# path pins this and the loop had no equivalent.
ran=$((ran + 1))
cat > "$TMP/allliar" <<LIAR
#!/bin/sh
case "\$1" in
  list) printf '42\\n' ;;
  view) cat "$TMP/clean-approved.json"; exit 1 ;;
  *) exit 2 ;;
esac
LIAR
chmod +x "$TMP/allliar"
PR_WATCH_PROVIDER="$TMP/allliar" sh "$BIN" --all >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' all-view-json-but-fails
else fails=$((fails + 1)); printf 'FAIL %-22s\n' all-view-json-but-fails; fi

# THE COLLISION. A provider that obeys "exit non-zero for an unknown verb" with
# a default arm and no wait arm used to get a silently no-op --wait: the
# fallback fired only on exactly 3, so the loop span forever on an instant
# exit 1 with nothing saying the wait had been skipped.
ran=$((ran + 1))
: > "$TMP/prov.log"
cat > "$TMP/nowaitarm" <<NW
#!/bin/sh
echo "\$@" >> "$TMP/prov.log"
case "\$1" in
  view) n=\$(grep -c '^view' "$TMP/prov.log")
        if [ "\$n" -lt 2 ]; then cat "$TMP/pending-checks.json"
        else cat "$TMP/clean-approved.json"; fi ;;
  *) exit 2 ;;
esac
NW
chmod +x "$TMP/nowaitarm"
out=$(PR_WATCH_PROVIDER="$TMP/nowaitarm" PR_WATCH_INTERVAL=1 PR_WATCH_TIMEOUT=20 sh "$BIN" 42 --wait 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^view' "$TMP/prov.log")" -ge 2 ]
then printf 'ok   %-22s no wait arm still polls\n' wait-default-arm-polls
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s, views %s\n' wait-default-arm-polls "$rc" "$(grep -c '^view' "$TMP/prov.log")"; fi

# An empty list from a provider that ALSO exits 0 for an unknown verb cannot be
# believed -- that is the fall-through shape, not an idle queue.
ran=$((ran + 1))
badprov 'case "$1" in list) exit 0 ;; esac'
PR_WATCH_PROVIDER="$TMP/bad" sh "$BIN" --all >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' list-empty-nonconforming
else fails=$((fails + 1)); printf 'FAIL %-22s\n' list-empty-nonconforming; fi

# --- a hiccup mid-poll is not an answer ---------------------------------------
# One failed view used to end the wait as though checks had settled.
ran=$((ran + 1))
: > "$TMP/prov.log"
cat > "$TMP/flaky" <<FLAKY
#!/bin/sh
echo "\$@" >> "$TMP/prov.log"
case "\$1" in
  wait) exit 3 ;;
  view) n=\$(grep -c '^view' "$TMP/prov.log")
        if [ "\$n" -eq 2 ]; then exit 4
        elif [ "\$n" -lt 4 ]; then cat "$TMP/pending-checks.json"
        else cat "$TMP/clean-approved.json"; fi ;;
  *) exit 2 ;;
esac
FLAKY
chmod +x "$TMP/flaky"
out=$(PR_WATCH_PROVIDER="$TMP/flaky" PR_WATCH_INTERVAL=1 PR_WATCH_TIMEOUT=30 sh "$BIN" 42 --wait 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^view' "$TMP/prov.log")" -ge 4 ]
then printf 'ok   %-22s polled past the hiccup\n' wait-survives-hiccup
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s, views %s\n' wait-survives-hiccup "$rc" "$(grep -c '^view' "$TMP/prov.log")"; fi

# --- --help must show the contract it documents -------------------------------
ran=$((ran + 1))
h=$(sh "$BIN" --help 2>&1)
if printf '%s' "$h" | grep -q PR_WATCH_PROVIDER && printf '%s' "$h" | grep -q 'wait <id>'
then printf 'ok   %-22s names the provider verbs\n' help-covers-provider
else fails=$((fails + 1)); printf 'FAIL %-22s help was truncated\n' help-covers-provider; fi

# --- the cap, and the value class that motivated it ---------------------------
# Past intmax `[ -gt ]` ERRORS rather than answering false, the AND-list fails,
# and execution carries on -- so the enormous value sailed through the check
# written to stop it, and --wait became a silent no-op on a pending PR.
ran=$((ran + 1))
mkprov clean-approved
out=$(PR_WATCH_TIMEOUT=99999999999999999999 PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 --wait 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qE 'larger than a week|too large to compare' \
   && ! printf '%s' "$out" | grep -qi 'illegal number'
then printf 'ok   %-22s exit 2, no [ error\n' timeout-past-intmax
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s: %s\n' timeout-past-intmax "$rc" "$out"; fi

ran=$((ran + 1))
PR_WATCH_TIMEOUT=604801 PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' timeout-over-a-week
else fails=$((fails + 1)); printf 'FAIL %-22s\n' timeout-over-a-week; fi
ran=$((ran + 1))
PR_WATCH_TIMEOUT=604800 PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 >/dev/null 2>&1
if [ $? -eq 0 ]; then printf 'ok   %-22s accepted\n' timeout-exactly-a-week
else fails=$((fails + 1)); printf 'FAIL %-22s\n' timeout-exactly-a-week; fi

# A length guard counts characters, not magnitude. At seven it called 0000001
# "larger than a week", which is a false statement in an error message.
ran=$((ran + 1))
out=$(PR_WATCH_TIMEOUT=0000001 PR_WATCH_PROVIDER="$TMP/prov" sh "$BIN" 42 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then printf 'ok   %-22s accepted\n' timeout-zero-padded
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s: %s\n' timeout-zero-padded "$rc" "$out"; fi

# --- provider stdout is not a trusted list of ids -----------------------------
# gh's --json number could only emit digits. A provider's stdout cannot, and an
# unquoted `for n in $nums` glob-expands: a list printing `*` produced one
# verdict block per file in the working directory.
ran=$((ran + 1))
cat > "$TMP/globprov" <<GLOB
#!/bin/sh
case "\$1" in list) printf '*\\n' ;; view) cat "$TMP/clean-approved.json" ;; *) exit 2 ;; esac
GLOB
chmod +x "$TMP/globprov"
out=$(cd "$TMP" && PR_WATCH_PROVIDER="$TMP/globprov" sh "$BIN" --all 2>&1); rc=$?
if [ "$rc" -eq 2 ] && [ "$(printf '%s' "$out" | grep -c 'state OPEN')" -eq 0 ]
then printf 'ok   %-22s exit 2, nothing iterated\n' list-glob-rejected
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s, %s blocks\n' list-glob-rejected "$rc" "$(printf '%s' "$out" | grep -c 'state OPEN')"; fi

# The same defect wearing different clothes: an error message printed to stdout
# instead of stderr must not be read as a pull request id.
ran=$((ran + 1))
cat > "$TMP/errprov" <<ERRP
#!/bin/sh
case "\$1" in list) echo "error: token expired" ;; *) exit 2 ;; esac
ERRP
chmod +x "$TMP/errprov"
# Exit 2 alone proves nothing here: without validation the words are iterated
# as fake ids, each fetch fails, and 2 falls out anyway. The message and the
# absence of per-"id" blocks are what distinguish the two.
out=$(PR_WATCH_PROVIDER="$TMP/errprov" sh "$BIN" --all 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'must print ids as digits' \
   && ! printf '%s' "$out" | grep -q 'could not read'
then printf 'ok   %-22s exit 2, names the cause\n' list-prose-rejected
else fails=$((fails + 1)); printf 'FAIL %-22s exit %s: %s\n' list-prose-rejected "$rc" "$out"; fi

# --- a provider that reads stdin must not hang the run ------------------------
# The probe passes a deliberately bogus verb, which is exactly what reaches a
# CLI's "did you mean...? [y/N]". An unattended loop's stdin is open and never
# delivers, so one prompt there hangs forever.
ran=$((ran + 1))
cat > "$TMP/stdinprov" <<STDIN
#!/bin/sh
case "\$1" in list) exit 0 ;; view) cat "$TMP/clean-approved.json" ;; *) read x; exit 0 ;; esac
STDIN
chmod +x "$TMP/stdinprov"
mkfifo "$TMP/fifo" 2>/dev/null || :
( sleep 20 > "$TMP/fifo" & ) 2>/dev/null
timeout 5 sh -c "PR_WATCH_PROVIDER='$TMP/stdinprov' sh '$BIN' --all" < "$TMP/fifo" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 124 ]; then printf 'ok   %-22s did not hang (exit %s)\n' provider-reads-stdin "$rc"
else fails=$((fails + 1)); printf 'FAIL %-22s hung until killed\n' provider-reads-stdin; fi

# --- argument handling ------------------------------------------------------
ran=$((ran + 1))
sh "$BIN" --nonsense >/dev/null 2>&1
if [ $? -eq 2 ]; then printf 'ok   %-22s exit 2\n' unknown-option
else fails=$((fails + 1)); printf 'FAIL %-22s did not reject\n' unknown-option; fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
