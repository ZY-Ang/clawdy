#!/bin/sh
# The dependency graph, written; and the issues that want to be one branch.
#
#   sh plugins/pm/tests/link-cluster.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
TMP=${TMPDIR:-/tmp}/lc-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null || { echo "lc.test: jq required" >&2; exit 1; }
if command -v gh >/dev/null 2>&1; then
  echo "lc.test: a real gh is on PATH; these cases fake it" >&2; exit 1
fi

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

CALLS=$TMP/gh-calls
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_CALLS"
# GH_FAIL_LINK reproduces the real 422 from #45, on stderr, where gh puts it.
case "$*" in
  *"method POST"*"dependencies"*)
    if [ "${GH_FAIL_LINK:-0}" = 1 ]; then
      echo 'gh: Invalid request.' >&2
      echo 'Invalid property /issue_id: is not of type `integer`. (HTTP 422)' >&2
      exit 1
    fi ;;
esac
case "$*" in
  *"repo view"*)   echo "o/n" ;;
  *"/issues/"*"/dependencies"*) : ;;
  *"api repos/"*)  echo "9911" ;;   # the NUMERIC id, deliberately not the number
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"; export GH_CALLS=$CALLS

cur()  { printf '%s\n' "$@" > "$TMP/cur.txt"; }
none() { : > "$TMP/cur.txt"; }
lk()   { : > "$CALLS"; PATH="$TMP/bin:$PATH" BACKLOG_LINK_JSON="$TMP/cur.txt" sh "$BIN/backlog-link" "$@" 2>&1; }
lkrc() { : > "$CALLS"; PATH="$TMP/bin:$PATH" BACKLOG_LINK_JSON="$TMP/cur.txt" sh "$BIN/backlog-link" "$@" >/dev/null 2>&1; echo $?; }

# --- backlog-link, read ------------------------------------------------------
cur 7 9
case "$(lk 12)" in *"#7"*) ok "reads the current blockers" ;; *) bad "reads blockers" "$(lk 12)" ;; esac
none
case "$(lk 12)" in *"blocked by nothing"*) ok "and says so when there are none" ;; *) bad "no blockers" "$(lk 12)" ;; esac

# --- write, and the id/number distinction ------------------------------------
cur 7
lk 12 --blocked-by 11 >/dev/null
if grep -q 'issue_id=9911' "$CALLS"; then ok "POSTs the numeric ID, not the issue number"
else bad "posts numeric id" "$(cat "$CALLS")"; fi

# #45: gh api -f sends a STRING and this endpoint requires an integer, so every
# call 422d. -F does type inference. The assertion above passes under BOTH
# flags, which is why it did not catch it -- the flag itself has to be checked.
if grep -q -- '-F issue_id=' "$CALLS"; then ok "with -F, so the id is sent as a JSON integer"
else bad "-F not -f" "$(cat "$CALLS")"; fi
if grep -q -- '-f issue_id=' "$CALLS"; then bad "still sending -f, which stringifies the id" "$(cat "$CALLS")"
else ok "and never -f, which would stringify it"; fi

# --- the backend's own words reach the caller --------------------------------
# The 422 named the property, the value, its type, the required type and the
# docs URL. All of it used to be discarded and replaced with "could not link".
cur 7
out=$(: > "$CALLS"; PATH="$TMP/bin:$PATH" BACKLOG_LINK_JSON="$TMP/cur.txt" GH_FAIL_LINK=1 \
      sh "$BIN/backlog-link" 12 --blocked-by 11 2>&1)
case "$out" in *"could not link"*) ok "a failed link still says so plainly" ;; *) bad "friendly line" "$out" ;; esac
case "$out" in *"HTTP 422"*) ok "and prints the backend diagnostic under it" ;; *) bad "surfaces gh stderr" "$out" ;; esac
case "$out" in *"issue_id"*) ok "including the property that was rejected" ;; *) bad "names the property" "$out" ;; esac
if grep -q 'issues/12/dependencies/blocked_by' "$CALLS"; then ok "against the blocked issue's URL"
else bad "correct URL" "$(cat "$CALLS")"; fi

# --- idempotence -------------------------------------------------------------
cur 7
case "$(lk 12 --blocked-by 7)" in *already*) ok "re-linking an existing edge reports, does not repeat" ;; *) bad "idempotent link" "$(lk 12 --blocked-by 7)" ;; esac
[ "$(lkrc 12 --blocked-by 7)" -eq 0 ] && ok "and exits 0" || bad "existing edge -> 0"
cur 7
lk 12 --blocked-by 7 >/dev/null
if grep -q 'method POST' "$CALLS"; then bad "re-linked an edge that existed" "$(cat "$CALLS")"
else ok "and sends no POST"; fi

# --- unlink ------------------------------------------------------------------
cur 7
lk 12 --unblock 7 >/dev/null
if grep -q 'method DELETE' "$CALLS"; then ok "unblocking DELETEs the edge"
else bad "unlink deletes" "$(cat "$CALLS")"; fi
cur 7
case "$(lk 12 --unblock 99)" in *"not present"*) ok "unblocking an edge that is not there is not an error" ;; *) bad "absent unlink" "$(lk 12 --unblock 99)" ;; esac

# --- several at once, which is the shape a class fix uses --------------------
none
lk 10 --blocked-by 11,12 >/dev/null
n=$(grep -c 'method POST' "$CALLS")
[ "$n" -eq 2 ] && ok "a comma list links each one" || bad "comma list" "got $n POSTs"

# --- refusals ----------------------------------------------------------------
cur 7
[ "$(lkrc 12 --blocked-by 12)" -eq 1 ] && ok "an issue cannot block itself" || bad "self-link refused"
[ "$(lkrc 12 --blocked-by 7 --unblock 9)" -eq 2 ] && ok "add and remove in one call -> 2" || bad "both -> 2"
[ "$(lkrc 12 --blocked-by abc)" -eq 2 ] && ok "a non-number blocker -> 2" || bad "non-number -> 2"
[ "$(lkrc)" -eq 2 ] && ok "no issue number -> 2" || bad "no number -> 2"
[ "$(lkrc 12 --nope)" -eq 2 ] && ok "unknown option -> 2" || bad "unknown option -> 2"
[ "$(lkrc 12 --help)" -eq 0 ] && ok "backlog-link --help -> 0" || bad "link --help"

cur 7
lk 12 --blocked-by 11 --dry-run >/dev/null
if [ -s "$CALLS" ] && grep -q 'method' "$CALLS"; then bad "--dry-run wrote something" "$(cat "$CALLS")"
else ok "--dry-run changes nothing"; fi

# --- backlog-cluster ---------------------------------------------------------
cl()   { BACKLOG_ISSUES_JSON="$TMP/c.json" sh "$BIN/backlog-cluster" "$@" 2>&1; }
clrc() { BACKLOG_ISSUES_JSON="$TMP/c.json" sh "$BIN/backlog-cluster" "$@" >/dev/null 2>&1; echo $?; }

cat > "$TMP/c.json" <<'JSON'
[{"number":1,"title":"a hole in plugins/pm/bin/backlog-queue","state":"OPEN","labels":[],"body":"","comments":[]},
 {"number":2,"title":"another in plugins/pm/bin/backlog-queue","state":"OPEN","labels":[],"body":"","comments":[]},
 {"number":3,"title":"third","state":"OPEN","labels":[],"body":"see plugins/pm/bin/backlog-queue","comments":[]},
 {"number":4,"title":"docs","state":"OPEN","labels":[{"name":"area-docs"}],"body":"","comments":[]},
 {"number":5,"title":"more docs","state":"OPEN","labels":[{"name":"area-docs"}],"body":"","comments":[]},
 {"number":6,"title":"a design question naming nothing","state":"OPEN","labels":[],"body":"none","comments":[]},
 {"number":7,"title":"alone in plugins/pm/lib/deps.sh","state":"OPEN","labels":[],"body":"","comments":[]}]
JSON

# The extensionless path is the case the first version missed entirely: every
# binary in this repo is a shell script with no extension, and requiring one
# meant the dominant file shape matched nothing.
case "$(cl)" in *"plugins/pm/bin/backlog-queue"*) ok "clusters an EXTENSIONLESS path" ;; *) bad "extensionless path" "$(cl)" ;; esac
case "$(cl)" in *"(3 issues"*) ok "and counts all three, body as well as title" ;; *) bad "counts 3" "$(cl)" ;; esac
case "$(cl)" in *area-docs*) ok "area-* labels cluster too" ;; *) bad "area cluster" "$(cl)" ;; esac
case "$(cl)" in *"#7"*) bad "a file with one issue was reported as a cluster" ;; *) ok "one issue is not a cluster" ;; esac
# Ordering: biggest group first, so the batch worth doing is the one read first.
first=$(cl | grep 'issues, one branch' | head -1)
case "$first" in *"backlog-queue"*) ok "the biggest cluster is listed first" ;; *) bad "ordered by size" "$first" ;; esac

[ "$(clrc --min 3)" -eq 0 ] && ok "--min 3 keeps the group of three" || bad "--min 3"
case "$(cl --min 3)" in *area-docs*) bad "--min 3 kept a pair" "$(cl --min 3)" ;; *) ok "and drops the pair" ;; esac
[ "$(clrc --min 9)" -eq 1 ] && ok "nothing clustering -> exit 1" || bad "no clusters -> 1"

case "$(cl --unkeyed)" in *"#6"*) ok "--unkeyed lists the issue naming no file" ;; *) bad "unkeyed" "$(cl --unkeyed)" ;; esac
case "$(cl --unkeyed)" in *"#1"*) bad "--unkeyed listed a keyed issue" ;; *) ok "and only that one" ;; esac
case "$(cl --unkeyed)" in *starve*) ok "and says why those are the ones that matter" ;; *) bad "explains starving" ;; esac

printf 'not json' > "$TMP/c.json"
[ "$(clrc)" -eq 2 ] && ok "unparseable input -> 2" || bad "cluster unparseable -> 2"
[ "$(clrc --min 1)" -eq 2 ] && ok "--min below 2 -> 2" || bad "--min 1 -> 2"
[ "$(clrc --nope)" -eq 2 ] && ok "unknown option -> 2" || bad "cluster unknown option"
[ "$(clrc --help)" -eq 0 ] && ok "backlog-cluster --help -> 0" || bad "cluster --help"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
