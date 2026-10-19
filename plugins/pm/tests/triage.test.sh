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

# --- a claim is worked on its pull request, not on the issue -----------------
# The issue goes quiet the moment backlog-claim comments on it, because the work
# moves to the PR. Reading the issue clock fired on every claim done correctly.
# Each case: the issue itself has been quiet for 456h.
claimed() {
  cat > "$TMP/i.json" <<JSON
[{"number":3,"title":"claimed work","state":"OPEN","labels":[{"name":"claimed"},{"name":"priority-med"},{"name":"urgency-low"},{"name":"size-m"}],
  "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","blockedBy":[],
  "comments":[$1]}]
JSON
}
CLAIM='{"author":"bot","body":"🤖\n\nClaimed -> `claude/the-work` (from `main`) at 2026-08-01T00:00:00Z.\n\nhttps://example/pull/7"}'
prs() { printf '%s' "$1" > "$TMP/p.json"; }
tp()  { BACKLOG_ISSUES_JSON="$TMP/i.json" BACKLOG_PRS_JSON="$TMP/p.json" sh "$BIN" "$@" 2>&1; }
rcp() { BACKLOG_ISSUES_JSON="$TMP/i.json" BACKLOG_PRS_JSON="$TMP/p.json" sh "$BIN" "$@" >/dev/null 2>&1; echo $?; }

# What actually happened: issue 99 "quiet for 62h" while its PR sat ready to merge.
claimed "$CLAIM"
prs '{"claude/the-work":{"draft":false,"updatedAt":"2026-08-01T00:00:00Z"}}'
[ "$(rcp --only stale)" -eq 0 ] && ok "a claim whose PR is ready for review is not stale" \
  || bad "ready-for-review is a human turn" "$(tp --only stale)"

prs '{"claude/the-work":{"draft":true,"updatedAt":"2026-08-19T23:00:00Z"}}'
[ "$(rcp --only stale)" -eq 0 ] && ok "a draft PR that moved an hour ago is not stale, however quiet the issue" \
  || bad "draft PR activity counts" "$(tp --only stale)"

prs '{"claude/the-work":{"draft":true,"updatedAt":"2026-08-18T00:00:00Z"}}'
[ "$(rcp --only stale)" -eq 1 ] && ok "a draft PR quiet past STALE_HOURS is stale" \
  || bad "quiet draft -> 1" "$(tp --only stale)"
# 48h is the PR's clock. The issue's would say 456h.
case "$(tp --only stale)" in *"draft pull request quiet for 48h"*) ok "and is measured on the PR, not the issue" ;;
  *) bad "measured on the PR" "$(tp --only stale)" ;; esac

# A claim whose PR is gone -- closed, or never opened -- is the shape the claim
# order exists to prevent: the queue hides an issue nothing is working on.
prs '{}'
case "$(tp --only stale)" in *"no open pull request found, quiet for 456h"*)
    ok "a claim with no open PR falls back to the issue, and says why" ;;
  *) bad "no-PR fallback" "$(tp --only stale)" ;; esac

# Released and re-claimed onto a new branch: the LATEST claim is the live one.
claimed "$CLAIM, $(printf '%s' "$CLAIM" | sed 's/claude\/the-work/claude\/second-try/')"
prs '{"claude/second-try":{"draft":true,"updatedAt":"2026-08-19T23:00:00Z"}}'
[ "$(rcp --only stale)" -eq 0 ] && ok "a re-claim is read from the latest claim comment" \
  || bad "latest claim wins" "$(tp --only stale)"

# --- a fixture run never reaches the network ---------------------------------
# With issues from a file and no PR file, the provider is not asked -- a test
# that quietly called a live backend would pass or fail on the weather.
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\necho "[]"\n' "$TMP/gh.log" > "$TMP/fakebin/gh"
chmod +x "$TMP/fakebin/gh"
claimed "$CLAIM"
rm -f "$TMP/gh.log"
PATH="$TMP/fakebin:$PATH" BACKLOG_ISSUES_JSON="$TMP/i.json" sh "$BIN" --only stale >/dev/null 2>&1
if grep -q "pr list" "$TMP/gh.log" 2>/dev/null; then bad "a fixture run reached the provider" "$(cat "$TMP/gh.log")"
else ok "a fixture run never asks the provider about PRs"; fi

# --- a backend that cannot answer is not a quiet claim -----------------------
# Live mode: the issue list comes back, the PR question fails. Treating that as
# "no PR" would report every claim stale; treating it as "fine" would hide one.
cat > "$TMP/fakebin/gh" <<GH
#!/bin/sh
case "\$1 \$2" in
  "issue list") cat "$TMP/i.json" ;;
  "pr list") echo "gh: HTTP 502" >&2; exit 1 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TMP/fakebin/gh"
out=$(PATH="$TMP/fakebin:$PATH" PM_ASSUME_DEPS=1 sh "$BIN" --only stale --repo o/n 2>&1); r=$?
[ "$r" -eq 2 ] && ok "a PR lookup that fails exits 2, never a quiet pass" || bad "failed lookup -> 2" "rc=$r $out"
case "$out" in *"could not ask"*"claude/the-work"*) ok "and names the branch it could not ask about" ;;
  *) bad "names the branch" "$out" ;; esac

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

# --- saturation ----------------------------------------------------------------
# A band holding most of the queue produces an order that looks ranked and is
# not: inside one band priority separates nothing, so what is left is the
# tie-breaks, ending in issue number -- the arrival order the queue replaces.
#
# Six competing issues at BACKLOG_NOW (2026-08-20): two labelled high, two that
# arrived below and aged past the 21-day step, two that stay low.
sat() {
  cat > "$TMP/i.json" <<'JSON'
[{"number":1,"title":"labelled high","state":"OPEN","createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[],
  "labels":[{"name":"task"},{"name":"urgency-low"},{"name":"size-s"},{"name":"priority-high"}]},
 {"number":2,"title":"labelled high too","state":"OPEN","createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[],
  "labels":[{"name":"task"},{"name":"urgency-low"},{"name":"size-s"},{"name":"priority-high"}]},
 {"number":3,"title":"arrived medium","state":"OPEN","createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-01T00:00:00Z","comments":[],"blockedBy":[],
  "labels":[{"name":"task"},{"name":"urgency-low"},{"name":"size-s"},{"name":"priority-med"}]},
 {"number":4,"title":"arrived low","state":"OPEN","createdAt":"2026-05-01T00:00:00Z","updatedAt":"2026-05-01T00:00:00Z","comments":[],"blockedBy":[],
  "labels":[{"name":"task"},{"name":"urgency-low"},{"name":"size-s"},{"name":"priority-low"}]},
 {"number":5,"title":"stays low","state":"OPEN","createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[],
  "labels":[{"name":"task"},{"name":"urgency-low"},{"name":"size-s"},{"name":"priority-low"}]},
 {"number":6,"title":"also low","state":"OPEN","createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[],
  "labels":[{"name":"task"},{"name":"urgency-low"},{"name":"size-s"},{"name":"priority-low"}]}]
JSON
}

sat
[ "$(rc --only saturation)" -eq 1 ] && ok "a crowded top band exits 1" || bad "saturation -> 1" "$(t --only saturation)"
case "$(t --only saturation)" in *"4 of 6 competing issues (66%)"*) ok "and counts the band against the queue" ;;
  *) bad "counts the band" "$(t --only saturation)" ;; esac

# The number the decision actually turns on. Ageing promotes INTO the top band
# and caps there, so a band fills by design -- and a report that does not
# separate the two makes that look like people over-labelling.
case "$(t --only saturation)" in *"2 of them were labelled lower and aged into it"*)
    ok "and says how many got there by ageing rather than by label" ;;
  *) bad "names the aged-in count" "$(t --only saturation)" ;; esac
case "$(t --only saturation)" in *"#3  priority-med + 111d"*) ok "and shows the label it arrived with" ;;
  *) bad "shows arrival label and age" "$(t --only saturation)" ;; esac

# --- the other direction, which is what stops it being a check that always fires
# Same six issues with the two old ones young: a normal spread, nothing to say.
sed 's/2026-05-01/2026-08-19/g' "$TMP/i.json" > "$TMP/spread.json" && mv "$TMP/spread.json" "$TMP/i.json"
[ "$(rc --only saturation)" -eq 0 ] && ok "a spread across bands is silent" || bad "spread -> 0" "$(t --only saturation)"

# A small backlog is 100% of something and means nothing by it.
printf '%s' "$CLEAN" > "$TMP/i.json"
[ "$(rc --only saturation)" -eq 0 ] && ok "one issue at the top is not saturation" || bad "below the floor -> 0" "$(t --only saturation)"
sat
[ "$(BACKLOG_ISSUES_JSON=$TMP/i.json SATURATION_MIN=99 sh "$BIN" --only saturation >/dev/null 2>&1; echo $?)" -eq 0 ] \
  && ok "SATURATION_MIN raises the floor" || bad "SATURATION_MIN honoured"
[ "$(BACKLOG_ISSUES_JSON=$TMP/i.json SATURATION_PCT=90 sh "$BIN" --only saturation >/dev/null 2>&1; echo $?)" -eq 0 ] \
  && ok "SATURATION_PCT raises the bar" || bad "SATURATION_PCT honoured"
# The ageing step is backlog-queue's, read from the same variable so the two
# cannot disagree about the order being described.
[ "$(BACKLOG_ISSUES_JSON=$TMP/i.json ESCALATE_DAYS=999 sh "$BIN" --only saturation >/dev/null 2>&1; echo $?)" -eq 0 ] \
  && ok "a longer ESCALATE_DAYS ages nobody in" || bad "ESCALATE_DAYS honoured" \
     "$(BACKLOG_ISSUES_JSON=$TMP/i.json ESCALATE_DAYS=999 sh "$BIN" --only saturation 2>&1)"

# --- what does not compete for queue position ---------------------------------
# Counting these measures a list nobody is waiting on, and dilutes the share
# with work that is already moving.
for excluded in claimed finding needs-human; do
  sat
  jq --arg l "$excluded" '(.[] | select(.number == 5) | .labels) += [{"name":$l}]' \
     "$TMP/i.json" > "$TMP/x.json" && mv "$TMP/x.json" "$TMP/i.json"
  case "$(t --only saturation)" in *"of 5 competing issues"*) ok "$excluded does not compete" ;;
    *) bad "$excluded excluded" "$(t --only saturation)" ;; esac
done

sat
[ "$(BACKLOG_ISSUES_JSON=$TMP/i.json SATURATION_PCT=0 sh "$BIN" >/dev/null 2>&1; echo $?)" -eq 2 ] \
  && ok "SATURATION_PCT outside 1..100 -> 2" || bad "SATURATION_PCT validated"
[ "$(BACKLOG_ISSUES_JSON=$TMP/i.json ESCALATE_DAYS=0 sh "$BIN" >/dev/null 2>&1; echo $?)" -eq 2 ] \
  && ok "ESCALATE_DAYS below 1 -> 2" || bad "ESCALATE_DAYS validated"

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
