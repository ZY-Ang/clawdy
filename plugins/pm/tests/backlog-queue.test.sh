#!/bin/sh
# The order must be the same every run, and provable without a network.
#
#   sh plugins/pm/tests/backlog-queue.test.sh
#
# BACKLOG_NOW is not optional in these: without a fixed clock every ordering
# case drifts a day at a time and eventually starts failing on a Tuesday.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/backlog-queue
TMP=${TMPDIR:-/tmp}/backlog-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null || { echo "backlog-queue.test: jq required" >&2; exit 1; }

export BACKLOG_NOW=1787184000          # 2026-08-20T00:00:00Z
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

q() { BACKLOG_ISSUES_JSON="$TMP/i.json" sh "$BIN" "$@" 2>&1; }
rcof() { BACKLOG_ISSUES_JSON="$TMP/i.json" sh "$BIN" "$@" >/dev/null 2>&1; echo $?; }
first() { q "$@" | head -1 | awk '{print $1}'; }
order() { q "$@" | grep '^#' | awk '{print $1}' | tr '\n' ' '; }

iss() { cat > "$TMP/i.json"; }

# --- severity beats everything, including a higher priority -----------------
iss <<'JSON'
[{"number":1,"title":"routine","state":"OPEN","labels":[{"name":"priority-high"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":2,"title":"backups unencrypted","state":"OPEN","labels":[{"name":"data-loss-risk"},{"name":"priority-low"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
[ "$(first)" = "#2" ] && ok "data-loss-risk outranks priority-high" || bad "data-loss-risk outranks priority-high" "$(order)"

iss <<'JSON'
[{"number":1,"title":"routine","state":"OPEN","labels":[{"name":"priority-high"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":2,"title":"auth bypass","state":"OPEN","labels":[{"name":"security"},{"name":"priority-low"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
[ "$(first)" = "#2" ] && ok "security does too" || bad "security does too" "$(order)"

# --- the class-versus-instance case this exists for -------------------------
# Instances declare the class as their blocker, so they leave the ready set and
# the class rises. Without the dependency they would each outrank it on size.
iss <<'JSON'
[{"number":10,"title":"class fix","state":"OPEN","labels":[{"name":"priority-med"},{"name":"size-m"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":11,"title":"instance a","state":"OPEN","labels":[{"name":"priority-med"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[{"number":10}]},
 {"number":12,"title":"instance b","state":"OPEN","labels":[{"name":"priority-med"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[{"number":10}]}]
JSON
[ "$(order)" = "#10 " ] && ok "instances blocked by the class leave the queue" || bad "instances leave the queue" "$(order)"
case "$(q --why)" in *unblocks=2*) ok "and the class shows what it unblocks" ;; *) bad "class shows unblocks=2" "$(q --why)" ;; esac
case "$(q --blocked)" in *"blocked by #10"*) ok "--blocked names the blocker" ;; *) bad "--blocked names the blocker" ;; esac

# --- needs-human is skipped only while unanswered ---------------------------
iss <<'JSON'
[{"number":1,"title":"answered","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z",
  "comments":[{"body":"🤖\n\nwhich?"},{"body":"the second one"}]},
 {"number":2,"title":"unanswered","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[{"body":"🤖\n\nwhich?"}]}]
JSON
[ "$(order)" = "#1 " ] && ok "an answered needs-human is ready" || bad "answered needs-human is ready" "$(order)"
case "$(q --blocked)" in *"#2"*"unanswered"*) ok "an unanswered one is not" ;; *) bad "unanswered one is not" ;; esac
# The agent replying after the human puts the ball back with the human.
iss <<'JSON'
[{"number":1,"title":"agent asked again","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z",
  "comments":[{"body":"🤖\n\nwhich?"},{"body":"the second"},{"body":"🤖\n\nwhich second?"}]}]
JSON
[ "$(rcof)" -eq 1 ] && ok "agent speaking last re-blocks it" || bad "agent speaking last re-blocks it" "$(q)"

# --- claimed and finding never queue ----------------------------------------
iss <<'JSON'
[{"number":1,"title":"claimed","state":"OPEN","labels":[{"name":"claimed"},{"name":"priority-high"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":2,"title":"finding","state":"OPEN","labels":[{"name":"finding"},{"name":"priority-high"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":3,"title":"ordinary","state":"OPEN","labels":[{"name":"priority-low"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
[ "$(order)" = "#3 " ] && ok "claimed and finding never queue" || bad "claimed and finding never queue" "$(order)"

# --- ageing promotes one whole step, and is capped --------------------------
iss <<'JSON'
[{"number":1,"title":"old low","state":"OPEN","labels":[{"name":"priority-low"}],
  "createdAt":"2026-07-16T00:00:00Z","comments":[]},
 {"number":2,"title":"fresh low","state":"OPEN","labels":[{"name":"priority-low"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
[ "$(first)" = "#1" ] && ok "35 days promotes low above fresh low" || bad "ageing promotes" "$(q --why)"
case "$(q --why)" in *"priority=2(base 1)"*) ok "and shows base beside effective" ;; *) bad "shows base beside effective" ;; esac
# Capped at high: a very old low must not outrank a fresh high on age alone.
iss <<'JSON'
[{"number":1,"title":"ancient low","state":"OPEN","labels":[{"name":"priority-low"}],
  "createdAt":"2024-01-01T00:00:00Z","comments":[]},
 {"number":2,"title":"fresh high","state":"OPEN","labels":[{"name":"priority-high"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
[ "$(first)" = "#1" ] && ok "ageing caps at high, oldest wins the tie" || bad "ageing caps at high" "$(q --why)"
case "$(q --why)" in *"priority=3(base 1)"*) ok "and does not exceed 3" ;; *) bad "does not exceed 3" ;; esac

# --- the order is TOTAL: same input, same output ----------------------------
iss <<'JSON'
[{"number":5,"title":"e","state":"OPEN","labels":[],"createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":3,"title":"c","state":"OPEN","labels":[],"createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":9,"title":"i","state":"OPEN","labels":[],"createdAt":"2026-08-19T00:00:00Z","comments":[]},
 {"number":1,"title":"a","state":"OPEN","labels":[],"createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
[ "$(order)" = "#1 #3 #5 #9 " ] && ok "identical issues break ties by number, oldest first" || bad "tie-break by number" "$(order)"
a=$(order); b=$(order); c=$(order)
{ [ "$a" = "$b" ] && [ "$b" = "$c" ]; } && ok "three runs give an identical order" || bad "order is deterministic"

# --- an unreachable backend is never a pass ---------------------------------
echo 'not json' > "$TMP/i.json"
[ "$(rcof)" -eq 2 ] && ok "unparseable input -> 2, never mistaken for ready" || bad "unparseable -> 2"
: > "$TMP/i.json"
[ "$(rcof)" -eq 2 ] && ok "empty input -> 2" || bad "empty input -> 2"
iss <<'JSON'
[]
JSON
[ "$(rcof)" -eq 1 ] && ok "an empty backlog -> 1, which is not an error" || bad "empty backlog -> 1"

BACKLOG_ISSUES_JSON=/nope/missing.json sh "$BIN" >/dev/null 2>&1
[ $? -eq 2 ] && ok "a missing seam file -> 2" || bad "missing seam file -> 2"
sh "$BIN" --nonsense >/dev/null 2>&1
[ $? -eq 2 ] && ok "unknown option -> 2" || bad "unknown option -> 2"

# --- fields that must survive the shell -------------------------------------
# Tab is an IFS whitespace character, so an empty field collapses the row and
# shifts every field after it. pr-watch hit exactly this; nothing may be empty.
iss <<'JSON'
[{"number":7,"title":"a title with several spaces in it","state":"OPEN","labels":[],
  "createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
case "$(q)" in *"a title with several spaces in it"*) ok "titles with spaces survive" ;; *) bad "titles with spaces" "$(q)" ;; esac
iss <<'JSON'
[{"number":8,"title":"","state":"OPEN","labels":[],"createdAt":"2026-08-19T00:00:00Z","comments":[]}]
JSON
[ "$(first)" = "#8" ] && ok "an empty title does not shift the row" || bad "empty title shifts the row" "$(q)"

# --- ageing only ever promotes ------------------------------------------------
# A negative age -- clock skew, or a BACKLOG_NOW pinned before the issue existed
# -- used to SUBTRACT from priority. A priority-high issue ranked as medium and
# the only sign was "priority=2(base 3)" in --why. Nothing called it an error.
neg=${TMPDIR:-/tmp}/bq-negage.$$
printf '[{"number":1,"title":"future","state":"OPEN","labels":[{"name":"priority-high"}],"createdAt":"2030-01-01T00:00:00Z","updatedAt":"2030-01-01T00:00:00Z","comments":[],"blockedBy":{"nodes":[],"totalCount":0}}]' > "$neg"
out=$(BACKLOG_ISSUES_JSON=$neg BACKLOG_NOW=1787184000 sh "$BIN" --why 2>&1)
case "$out" in *"priority=3(base 3)"*) ok "an issue newer than the clock keeps its priority" ;;
  *) bad "an issue newer than the clock keeps its priority" "$out" ;; esac
case "$out" in *"age=-"*) bad "age is floored at 0, never negative" "$out" ;;
  *) ok "age is floored at 0, never negative" ;; esac
rm -f "$neg"

# --- a flat order must announce itself ----------------------------------------
# #35: the default that stops an unlabelled issue being buried also makes a
# backlog with no axes rank FLAT -- everything ties and falls through to number,
# which is arrival order. Without this line that is indistinguishable from a
# ranking.
flat=${TMPDIR:-/tmp}/bq-flat.$$
printf '[{"number":7,"title":"unlabelled","state":"OPEN","labels":[{"name":"task"}],"createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","comments":[],"blockedBy":{"nodes":[],"totalCount":0}},{"number":8,"title":"labelled","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],"createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z","comments":[],"blockedBy":{"nodes":[],"totalCount":0}}]' > "$flat"
out=$(BACKLOG_ISSUES_JSON=$flat BACKLOG_NOW=1787184000 sh "$BIN" --why 2>&1)
case "$out" in *"UNTRIAGED: priority,urgency,size"*) ok "--why names the axes it guessed" ;;
  *) bad "--why names the axes it guessed" "$out" ;; esac
# The fully-labelled row must NOT carry the line, or it means nothing.
lab=$(printf '%s\n' "$out" | grep -A2 '^#8 ' | grep -c 'UNTRIAGED:' || true)
[ "$lab" -eq 0 ] && ok "and says nothing on a fully-labelled row" || bad "the note leaks onto labelled rows" "$out"
# Empty field, tab-split: the bug that has cost this repo two sessions.
# The key gained a digit when untriaged became the second component: #8 is
# triaged, so 1 -- and #7 is not, which is why it now sorts first.
case "$out" in *"key=1101999100000008"*) ok "the empty marker does not shift the other fields" ;;
  *) bad "fields shifted by the empty defaulted marker" "$out" ;; esac
rm -f "$flat"

# --- the wire shape, from a real gh call --------------------------------------
#
# Every case above drives a hand-written fixture, and the fixture was written by
# the same reading of blockedBy that the code made -- so the test agreed with the
# bug and the queue exited 2 against every real repository. A fixture for a wire
# format has to come off the wire.
#
# This one carries blockedBy as gh actually emits it: {"nodes":[],"totalCount":0}.
WIRE=$HERE/fixtures/issues-github-shape.json
if [ -f "$WIRE" ]; then
  out=$(BACKLOG_ISSUES_JSON=$WIRE BACKLOG_NOW=1787184000 sh "$BIN" 2>&1); rc=$?
  [ "$rc" -eq 0 ] && ok "gh's object-shaped blockedBy parses" \
    || bad "gh's object-shaped blockedBy parses" "exit $rc: $out"
  case "$out" in
    *"could not parse"*) bad "and does not fall back to the parse error" "$out" ;;
    *) ok "and does not fall back to the parse error" ;;
  esac
  # 223 and 90 tie on severity, priority and urgency, and differ only on size:
  # s before m. If the fixture only proved it parses, this line would not care
  # which came out first.
  first=$(printf '%s\n' "$out" | head -1)
  case "$first" in \#223*) ok "and still ranks severity first on real data" ;;
    *) bad "ranks severity first on real data" "$first" ;; esac

  # The failure this replaces: jq's diagnostic was thrown away, so the message
  # named neither the field nor the shape.
  bad_json=${TMPDIR:-/tmp}/bq-badshape.$$
  printf '[{"number":1,"title":"x","state":"OPEN","labels":[],"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","comments":[],"blockedBy":{"nodes":[{"number":2}],"totalCount":1}}]' > "$bad_json"
  out2=$(BACKLOG_ISSUES_JSON=$bad_json BACKLOG_NOW=1787184000 sh "$BIN" --blocked 2>&1)
  case "$out2" in *"#1"*) ok "a real blocker in nodes[] blocks the issue" ;;
    *) bad "a real blocker in nodes[] blocks the issue" "$out2" ;; esac
  rm -f "$bad_json"
else
  bad "the wire fixture is missing" "$WIRE"
fi

# --- the inversion this whole plugin exists for ------------------------------
#
# #22 failure mode 1: one defect shape filed six times against six files, four
# instance-fixes shipped, the class fix still open. Instances are small and
# land easily; the class fix is bigger and never rises.
#
# This could not be tested before BACKLOG_DEPS_JSON existed, because every
# blockedBy on the measured backlog was EMPTY -- 160 of 160. A fixture drawn
# from real data proves the field parses and nothing about what it does.
cat > "$TMP/d.json" <<'JSON'
[{"number":10,"blockedBy":[]},{"number":11,"blockedBy":[10]},{"number":12,"blockedBy":[10]}]
JSON
iss <<'JSON'
[{"number":10,"title":"class fix","state":"OPEN","labels":[{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-m"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":11,"title":"instance a","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":12,"title":"instance b","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
# Without the graph the instances win on priority. That is the bug, stated as a
# case, so the fix below cannot be mistaken for the default behaviour.
[ "$(first)" = "#11" ] && ok "without a graph, priority-high instances outrank the class fix" \
  || bad "instances outrank without deps" "$(order)"

qd() { BACKLOG_ISSUES_JSON="$TMP/i.json" BACKLOG_DEPS_JSON="$TMP/d.json" sh "$BIN" "$@" 2>&1; }
# "First" is true of THIS fixture, which holds nothing but the class and its
# instances. It is not a general claim, and naming it one is how the skill came
# to overstate the same thing -- see #48. The case below pins the boundary.
[ "$(qd | head -1 | awk '{print $1}')" = "#10" ] \
  && ok "with the graph, the class fix outranks its own instances despite priority-low" \
  || bad "class fix above its instances" "$(qd)"
case "$(qd --why)" in *unblocks=2*) ok "and its dependents count is 2" ;; *) bad "unblocks=2" "$(qd --why)" ;; esac
n=$(qd | grep -c '^#')
[ "$n" -eq 1 ] && ok "and both instances leave the ready set while it is open" \
  || bad "instances blocked" "got $n ready"

# --- untriaged sorts second, below severity and above everything else --------
#
# #51. Treating a missing axis as medium keeps an unlabelled issue from being
# buried, and medium is exactly where things get buried: indistinguishable from
# work somebody deliberately ranked medium. An unlabelled backlog does not rank
# badly, it ranks FLAT, and falls through to arrival order -- the thing the
# queue exists to replace.
iss <<'JSON'
[{"number":1,"title":"nobody chose","state":"OPEN","labels":[],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":2,"title":"a credential exposure","state":"OPEN","labels":[{"name":"security"},{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":4,"title":"ranked high","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(order)" = "#2 #1 #4 " ] && ok "untriaged outranks priority-high but not severity" \
  || bad "untriaged sorts second" "$(order)"

# Severity staying above it is the whole reason this is the SECOND key and not
# the first: an unclassified typo must not outrank a credential exposure.
[ "$(first)" = "#2" ] && ok "and a credential exposure still comes first" || bad "severity first" "$(order)"

# Partly labelled is still untriaged -- two of three axes is not a decision.
iss <<'JSON'
[{"number":1,"title":"half labelled","state":"OPEN","labels":[{"name":"priority-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":4,"title":"ranked high","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(first)" = "#1" ] && ok "a partly-labelled issue is untriaged too" || bad "partial is untriaged" "$(order)"

# needs-human is exempt: a question is not queue work and file-issue does not
# ask it for axes. Clearing the label is what turns it into work -- and THAT is
# when it becomes untriaged and surfaces, which is the behaviour wanted.
iss <<'JSON'
[{"number":3,"title":"answered question","state":"OPEN","labels":[{"name":"needs-human"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[{"author":"a","body":"🤖 asked"},{"author":"h","body":"yes"}],"blockedBy":[]},
 {"number":4,"title":"ranked high","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(first)" = "#4" ] && ok "an answered needs-human is exempt, not promoted" || bad "needs-human exempt" "$(order)"

# Fully labelled work is never treated as untriaged, or the key means nothing.
iss <<'JSON'
[{"number":1,"title":"low but ranked","state":"OPEN","labels":[{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":4,"title":"ranked high","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
[ "$(first)" = "#4" ] && ok "fully labelled work sorts on priority as before" || bad "triaged unaffected" "$(order)"

# --why must say the position is a consequence of being unclassified, not of a
# ranking somebody made. Without that the queue reproduces #48's ambiguity.
iss <<'JSON'
[{"number":1,"title":"nobody chose","state":"OPEN","labels":[],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
case "$(q --why)" in *UNTRIAGED*) ok "--why names the row as untriaged" ;; *) bad "why says untriaged" "$(q --why)" ;; esac
case "$(q --why)" in *"not a decision"*) ok "and that the priority shown is a default" ;; *) bad "why explains the default" ;; esac

# --- and what the dependents key does NOT do ---------------------------------
#
# #48: the skill read as "a class fix reaches the top". It does not. Dependents
# is the fourth key, below severity, priority and urgency, so an unrelated
# priority-high item still outranks a class fix with dependents.
#
# Nothing tested this boundary, which is why the wording could drift without
# anything catching it. An ambiguity that no case pins is a claim.
cat > "$TMP/d.json" <<'JSON'
[{"number":10,"blockedBy":[]},{"number":11,"blockedBy":[10]},{"number":12,"blockedBy":[10]},
 {"number":20,"blockedBy":[]},{"number":21,"blockedBy":[]}]
JSON
iss <<'JSON'
[{"number":10,"title":"class fix","state":"OPEN","labels":[{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-m"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":11,"title":"instance a","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":12,"title":"instance b","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":20,"title":"unrelated high","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":21,"title":"a credential exposure","state":"OPEN","labels":[{"name":"security"},{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
JSON
qd() { BACKLOG_ISSUES_JSON="$TMP/i.json" BACKLOG_DEPS_JSON="$TMP/d.json" sh "$BIN" "$@" 2>&1; }
qdo() { qd | grep '^#' | awk '{print $1}' | tr '\n' ' '; }

[ "$(qd | head -1 | awk '{print $1}')" = "#21" ] \
  && ok "severity still comes first, dependents or not" || bad "severity first" "$(qdo)"
case "$(qdo)" in "#21 #20 #10 "*) ok "an unrelated priority-high still outranks a class fix with dependents" ;;
  *) bad "priority beats dependents" "$(qdo)" ;; esac
case "$(qd --why)" in *unblocks=2*) ok "even though the class fix carries unblocks=2" ;;
  *) bad "class fix has dependents" "$(qd --why)" ;; esac

# --- the failure contract, which nothing tested ------------------------------
#
# From #39. The skill states "an unreachable backend is never a pass" more
# emphatically than any other rule here, and it was the one rule with no case.
# The claim that it was BROKEN came from `... | head` and reading $?, which is
# the last stage's status -- so a correct tool looked defective, and a defective
# one would have looked correct.
#
# Run unpiped, deliberately. POSIX sh has no PIPESTATUS, so inside a pipeline
# there is no way back to the real status.
NOBIN=$TMP/nobin; mkdir -p "$NOBIN"
# dirname is required -- backlog-queue resolves its lib directory with it. Its
# absence made the first attempt at this case pass for the WRONG REASON: exit 2
# from a failed `.` of provider-github.sh, not from an unreachable backend. The
# stderr assertion is what caught that, which is why this case checks the
# message and not only the code.
#
# rm is left OUT on purpose. Without it the EXIT trap's cleanup fails, and a
# failing trap clobbers the script's exit status -- this returned 127 having
# already decided on 2. The trap is now `|| :` guarded, so an absent rm proves
# the guard rather than breaking the case. Do not "fix" this by adding rm.
for b in sh jq sed awk cat sort tr date grep head printf dirname basename; do
  src=$(command -v "$b") || continue
  ln -sf "$src" "$NOBIN/$b"
done
if PATH="$NOBIN" command -v gh >/dev/null 2>&1; then
  echo "backlog-queue.test: gh leaked into the bare PATH; the case below is meaningless" >&2
  exit 1
fi
PATH="$NOBIN" sh "$BIN" --top 3 >"$TMP/o" 2>"$TMP/e"; rc=$?
[ "$rc" -eq 2 ] && ok "unreachable backend -> exit 2, never a pass" \
  || bad "unreachable backend -> 2" "got $rc"
if grep -qi 'not available\|could not' "$TMP/e"; then ok "and says so on stderr"
else bad "explains the failure" "$(cat "$TMP/e")"; fi
if [ -s "$TMP/o" ]; then bad "a failed run printed a queue" "$(cat "$TMP/o")"
else ok "and prints no queue at all"; fi

# The measurement that produced the false claim, kept as a case so the trap is
# recorded rather than remembered.
piped=$(PATH="$NOBIN" sh "$BIN" --top 3 2>&1 | head -5 >/dev/null; echo $?)
[ "$piped" -eq 0 ] && ok "piped, \$? is head's 0 -- which is why #39 read it wrong" \
  || bad "pipeline masks the status" "got $piped"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
