#!/bin/sh
# The seam is only real if nothing goes around it.
#
#   sh plugins/pm/tests/seam.test.sh
#
# This is a structural test, not a behavioural one. It exists because the
# contract in lib/provider-github.sh says a second backend is "a new file
# implementing the same functions", and that was untrue for six of the ten
# tools -- file-issue, reply-issue, ask-async, check-replies, questions and
# pr-watch all called gh directly. Nothing said so, and nothing would have.
#
# A prose promise about an interface decays silently. This is the check.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
LIB=$HERE/../lib
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

# --- no binary calls the backend directly ------------------------------------
# Comment lines are excluded: describing gh is fine, invoking it is not.
for f in "$BIN"/*; do
  b=$(basename "$f")
  hits=$(grep -n "^[^#]*\bgh " "$f" 2>/dev/null | grep -v "provider_" || true)
  if [ -z "$hits" ]; then ok "$b goes through the provider"
  else bad "$b calls gh directly" "$hits"; fi
done

# --- every binary that talks to a backend actually sources one ---------------
for f in "$BIN"/*; do
  b=$(basename "$f")
  # interview-window is local-only by design: it reads and writes stamp files
  # and never touches a tracker, so it must NOT grow a provider dependency.
  case "$b" in interview-window) continue ;; esac
  if grep -q 'provider_[a-z]' "$f" 2>/dev/null; then
    if grep -q 'pm_load_provider' "$f"; then ok "$b loads a provider through the loader"
    else bad "$b calls provider_* without loading one" ""; fi
  fi
  # And nothing names a specific provider. Hardcoding one is what #53 removed:
  # eleven copies of the same two lines, so PM_PROVIDER could not select at all.
  if grep -q 'provider-github\.sh\|provider-[a-z]*\.sh' "$f" 2>/dev/null; then
    bad "$b hardcodes a provider file instead of using PM_PROVIDER" \
        "$(grep -n 'provider-[a-z]*\.sh' "$f" | head -1)"
  fi
done

# --- the mark has one definition ---------------------------------------------
# check-replies used to hardcode its own copy. Whether a human has replied is
# decided by this character, and two definitions is two answers the day one of
# them changes.
n=$(grep -l "AGENT_MARK\|MARK='" "$BIN"/* "$LIB"/* 2>/dev/null | wc -l | tr -d ' ')
lit=$(grep -c "MARK='🤖'" "$LIB/agent-prefix.sh" 2>/dev/null || echo 0)
[ "$lit" -eq 1 ] && ok "the agent mark is defined once, in agent-prefix.sh" \
  || bad "mark defined once" "found $lit literals in the lib"
others=$(grep -ln "MARK='🤖'" "$BIN"/* 2>/dev/null || true)
[ -z "$others" ] && ok "and no binary carries its own copy" \
  || bad "a binary redefines the mark" "$others"

# --- the contract is documented where it is implemented ----------------------
for fn in provider_name provider_pr_ref_mark provider_available \
          provider_issues provider_issue \
          provider_comment provider_label provider_create_issue \
          provider_close_issue provider_issue_labels provider_needs_human \
          provider_ensure_label provider_link provider_unlink \
          provider_issue_id provider_blocked_by provider_open_draft_pr \
          provider_find_pr provider_supports_deps ; do
  if grep -q "^$fn()" "$LIB/provider-github.sh"; then :
  else bad "$fn is named in the contract but not implemented"; fi
done
ok "every function the contract names is implemented"



# --- the provider is selectable, which is the whole point of a seam ----------
# Before #53 every binary named provider-github.sh directly, so a correctly
# written second provider could be installed and never loaded.
TMPL=${TMPDIR:-/tmp}/seam-provider.$$
mkdir -p "$TMPL"
trap 'rm -rf "$TMPL"' EXIT INT TERM
cat > "$TMPL/provider-fake.sh" <<'EOF'
provider_name() { printf 'fake'; }
provider_available() { return 0; }
EOF
cat > "$TMPL/load-provider.sh" < "$LIB/load-provider.sh"

loadp() { ( PM_LIB="$TMPL" PM_PROVIDER="$1" sh -c '. "$PM_LIB/load-provider.sh"
            pm_load_provider || exit $?
            provider_name' ) 2>&1; }
loadrc() { ( PM_LIB="$TMPL" PM_PROVIDER="$1" sh -c '. "$PM_LIB/load-provider.sh"
             pm_load_provider' >/dev/null 2>&1 ); echo $?; }

[ "$(loadp fake)" = "fake" ] && ok "PM_PROVIDER selects a different provider" \
  || bad "selects a provider" "$(loadp fake)"

[ "$(loadrc nope)" -eq 2 ] && ok "an unknown provider exits 2" || bad "unknown provider -> 2"
case "$(loadp nope)" in *"no provider 'nope'"*) ok "and names what it looked for" ;;
  *) bad "names the missing file" "$(loadp nope)" ;; esac
case "$(loadp nope)" in *"available:"*fake*) ok "and lists what it did find" ;;
  *) bad "lists available" "$(loadp nope)" ;; esac

# A file that loads but implements nothing fails LATER and somewhere else,
# reading like a bug in the tool rather than in the provider.
: > "$TMPL/provider-empty.sh"
[ "$(loadrc empty)" -eq 2 ] && ok "a provider missing the contract exits 2, not later" \
  || bad "empty provider -> 2"
case "$(loadp empty)" in *PROVIDERS.md*) ok "and points at the contract" ;;
  *) bad "points at PROVIDERS.md" "$(loadp empty)" ;; esac

# A name is a filename, so it must not reach out of the lib directory.
[ "$(loadrc ../../etc/passwd)" -eq 2 ] && ok "a name with a path in it is refused" \
  || bad "path traversal refused"


# --- provider_is_triaged, and what a 2 obliges the caller to do --------------
. "$LIB/provider-github.sh"
tri() { provider_is_triaged "$1"; echo $?; }

# --- the reference glyph -----------------------------------------------------
# One namespace on GitHub, two on GitLab: the mark is a backend fact, so it
# lives on the provider rather than in a consumer's case statement.
[ "$(provider_pr_ref_mark)" = "#" ] && ok "github references a PR with #" || bad "github mark"
( . "$LIB/provider-gitlab.sh"; [ "$(provider_pr_ref_mark)" = "!" ] ) \
  && ok "gitlab references an MR with !" || bad "gitlab mark"

[ "$(tri '{"labels":[{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-s"}]}')" -eq 0 ] \
  && ok "all three axes present -> triaged" || bad "triaged -> 0"
[ "$(tri '{"labels":[{"name":"priority-low"}]}')" -eq 1 ] \
  && ok "one axis missing -> not triaged" || bad "partial -> 1"
[ "$(tri '{"labels":[]}')" -eq 1 ] && ok "no axes at all -> not triaged" || bad "none -> 1"
# The seventh label site, and the last one with no coverage: is_triaged was only
# ever fed the object shape, so its share of the (.name // .) bug was invisible.
[ "$(tri '{"labels":["priority-low","urgency-low","size-s"]}')" -eq 0 ] \
  && ok "string labels -> triaged, same as objects" || bad "string labels -> 0"
[ "$(tri '{"labels":["priority-low"]}')" -eq 1 ] \
  && ok "string labels, one axis missing -> not triaged" || bad "partial strings -> 1"
[ "$(tri 'not json')" -eq 2 ] && ok "unusable input -> cannot tell, never triaged" || bad "bad input -> 2"

# The contract says a caller that gets 2 must SAY SO rather than rank quietly.
# On this backend absence is observable, so backlog-queue can report provenance
# per row -- and that reporting is the behaviour a 2 stands in for elsewhere.
# Pinned here because it is the part that was documented wrongly first: a 2 was
# described as licence to drop the key and carry on, which asserts every
# priority was chosen and yields a confident order built from nothing.
cat > "$TMPL/i.json" <<'EOF'
[{"number":1,"title":"chosen","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":2,"title":"nobody chose","state":"OPEN","labels":[],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
EOF
why=$(BACKLOG_ISSUES_JSON="$TMPL/i.json" BACKLOG_NOW=1787184000 sh "$HERE/../bin/backlog-queue" --why 2>&1)
case "$why" in *"UNTRIAGED: priority"*) ok "an unranked row says its priority was not supplied" ;;
  *) bad "reports defaulted provenance" "$why" ;; esac
case "$why" in *"not a decision"*) ok "and says the priority shown is a default, not a ranking" ;;
  *) bad "says the priority is a default" "$why" ;; esac
# The ranked row must NOT carry the note, or the signal means nothing.
n=$(printf '%s\n' "$why" | grep -c 'UNTRIAGED:')
[ "$n" -eq 1 ] && ok "and the row someone did rank carries no such note" \
  || bad "provenance note is not selective" "got $n notes"

# --- nothing here claims to be stable ----------------------------------------
# Every plugin in this marketplace is pre-1.0 on purpose. A 1.x number is a
# promise about compatibility that none of these has earned yet, and it is the
# kind of claim that gets made by accident one bump at a time.
for m in "$HERE"/../../*/.claude-plugin/plugin.json; do
  [ -f "$m" ] || continue
  v=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | head -1)
  n=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | head -1)
  case "$v" in
    0.*) ok "$n is pre-1.0 ($v)" ;;
    *)   bad "$n claims $v -- nothing here is stable yet" ;;
  esac
done

# --- string labels: the shape the second backend actually sends ---------------
# `(.name // .)` was written to accept an object label or a bare string, and
# does NOT: `//` catches null and false, while indexing a STRING with .name is a
# hard jq error. gh sends objects, glab sends strings, so every binary that read
# a label died on the second backend.
#
# ASSERT POSITIVE OUTPUT, NOT THE ABSENCE OF AN ERROR. The first version of
# these greps looked for "could not parse" -- but backlog-cluster says "could
# not scan", and backlog-triage died with stdout AND stderr empty, so both
# passed while completely broken. An empty output satisfies any "no error here"
# test.
LBLTMP=${TMPDIR:-/tmp}/seam-labels.$$
mklbl() { printf '[{"number":1,"title":"needle-title","state":"OPEN","labels":%s,"createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","comments":[],"blockedBy":[]}]\n' "$1" > "$LBLTMP"; }
lblrun() { BACKLOG_ISSUES_JSON="$LBLTMP" BACKLOG_NOW=1787184000 sh "$BIN/$1" 2>&1; }

for shape in '["task","priority-high","size-s","urgency-low"]' '[{"name":"task"},{"name":"priority-high"},{"name":"size-s"},{"name":"urgency-low"}]'; do
  case "$shape" in '["task"'*) kind=string ;; *) kind=object ;; esac
  mklbl "$shape"
  for b in backlog-queue backlog-cluster backlog-triage; do
    out=$(lblrun "$b"); rc=$?
    # The title must appear: the binary has to have READ the issue, not merely
    # exited without complaining.
    # cluster and triage legitimately print no title, so the discriminator is
    # a sane exit AND some output: a broken idiom gives cluster exit 2, and
    # triage exit 5 with stdout and stderr both empty.
    if [ "$rc" -le 1 ] && [ -n "$out" ]
    then ok "$b reads $kind labels"
    else bad "$b reads $kind labels" "exit $rc: $(printf '%s' "$out" | head -2)"; fi
  done
done

# backlog-claim and backlog-release read ONE issue through a different seam, so
# the loop above never reached them -- both label fixes were untested.
ONETMP=${TMPDIR:-/tmp}/seam-one.$$
for shape in '["task","claimed"]' '[{"name":"task"},{"name":"claimed"}]'; do
  case "$shape" in '["task"'*) kind=string ;; *) kind=object ;; esac
  printf '{"number":1,"title":"needle-title","state":"OPEN","labels":%s,"createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","comments":[],"blockedBy":[]}\n' "$shape" > "$ONETMP"
  # --dry-run for claim; release has no such flag, so it is driven with --reason
  # and asserted on the label read rather than the write. Getting the flags
  # wrong is how the first version of this test never reached the label code at
  # all -- "unknown option --dry-run" satisfied every assertion.
  out=$(BACKLOG_ISSUE_JSON="$ONETMP" BACKLOG_NOW=1787184000 sh "$BIN/backlog-claim" 1 --dry-run 2>&1)
  case "$out" in
    *"Cannot index string"*|*"unknown option"*) bad "backlog-claim reads $kind labels" "$out" ;;
    *) ok "backlog-claim reads $kind labels" ;;
  esac
  out=$(BACKLOG_ISSUE_JSON="$ONETMP" BACKLOG_NOW=1787184000 sh "$BIN/backlog-release" 1 --reason "seam test" 2>&1)
  case "$out" in
    *"Cannot index string"*|*"unknown option"*) bad "backlog-release reads $kind labels" "$out" ;;
    *) ok "backlog-release reads $kind labels" ;;
  esac
done
# THE SHAPES THAT ARE NEITHER. `| strings` exists so a label that is neither a
# string nor {name} degrades to "no labels" rather than aborting the run one
# shape further out. Nothing exercised it -- the suite only ever fed the two
# well-formed shapes. {"nodes":[...]} is not hypothetical: backlog-queue's own
# comment records gh returning blockedBy in exactly that wrapper.
for shape in '[null]' '[123]' '[{"id":7}]' '[["nested"]]' '{"nodes":[{"name":"task"}]}'; do
  mklbl "$shape"
  for b in backlog-queue backlog-cluster backlog-triage; do
    out=$(lblrun "$b"); rc=$?
    if [ "$rc" -le 1 ] && [ -n "$out" ]
    then ok "$b degrades on $shape"
    else bad "$b degrades on $shape" "exit $rc: $(printf '%s' "$out" | head -1)"; fi
  done
done
rm -f "$LBLTMP" "$ONETMP" 2>/dev/null

# --- fractional-second timestamps --------------------------------------------
# jq's fromdateiso8601 rejects "...T10:12:28.895Z". GitHub never sends a
# fractional part; GitLab always does.
#
# CHECKING THAT SOMETHING WAS PRINTED CANNOT SEE THIS. The unparsed-stamp
# fallback (to $now, so an unknown age is not "infinitely old") means a failed
# parse no longer errors -- the queue still prints and triage still reports
# not-stale. Both of those satisfied the first version of this test, so the fix
# it guarded was silently revertible. Only comparing ANSWERS distinguishes them:
# ageing for the queue, staleness for triage.
AGETMP=${TMPDIR:-/tmp}/seam-age.$$
# An old low-priority issue escalates above a fresh medium one -- unless its
# stamp was not read, in which case it dates to now and does not.
agefirst() {
  printf '[{"number":1,"title":"aged-low","state":"OPEN","labels":["task","priority-low","size-s","urgency-low"],"createdAt":"%s","updatedAt":"%s","comments":[],"blockedBy":[]},{"number":2,"title":"fresh-med","state":"OPEN","labels":["task","priority-med","size-s","urgency-low"],"createdAt":"2026-08-19T00:00:00Z","updatedAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]\n' "$1" "$1" > "$AGETMP"
  BACKLOG_ISSUES_JSON="$AGETMP" BACKLOG_NOW=1787184000 ESCALATE_DAYS=30 sh "$BIN/backlog-queue" 2>&1 | head -1
}
# A claim untouched since 2020 is stale -- unless its stamp was not read.
stalefirst() {
  printf '[{"number":1,"title":"aged-claim","state":"OPEN","labels":["task","claimed"],"createdAt":"%s","updatedAt":"%s","comments":[],"blockedBy":[]}]\n' "$1" "$1" > "$AGETMP"
  BACKLOG_ISSUES_JSON="$AGETMP" BACKLOG_NOW=1787184000 STALE_HOURS=24 sh "$BIN/backlog-triage" 2>&1
}

zq=$(agefirst "2020-01-01T00:00:00Z")
nowq=$(agefirst "2026-08-19T00:00:00Z")
case "$zq" in *aged-low*) ok "an old Z stamp escalates above a fresher higher priority" ;;
  *) bad "Z ageing" "$zq" ;; esac
case "$nowq" in *fresh-med*) ok "and a fresh one does not" ;; *) bad "fresh control" "$nowq" ;; esac

# Every stamp form GitLab or GitHub can send must date the SAME as plain Z.
for stamp in "2020-01-01T00:00:00.895Z" "2020-01-01T00:00:00+00:00" "2020-01-01T00:00:00.895+00:00"; do
  got=$(agefirst "$stamp")
  if [ "$got" = "$zq" ] && [ "$got" != "$nowq" ]
  then ok "backlog-queue dates $stamp as it dates Z"
  else bad "backlog-queue dates $stamp as it dates Z" "got=[$got] z=[$zq] now=[$nowq]"; fi

  got=$(stalefirst "$stamp")
  case "$got" in
    *"stale claims"*) ok "backlog-triage dates $stamp as it dates Z" ;;
    *) bad "backlog-triage dates $stamp as it dates Z" "an aged claim was not reported stale" ;;
  esac
done
# The Z control for triage, so the assertion above cannot pass by never firing.
case "$(stalefirst "2020-01-01T00:00:00Z")" in
  *"stale claims"*) ok "the triage Z control reports stale" ;;
  *) bad "triage Z control" "$(stalefirst "2020-01-01T00:00:00Z")" ;;
esac
case "$(stalefirst "2026-08-19T23:00:00Z")" in
  *"stale claims"*) bad "a fresh claim is not stale" ;;
  *) ok "and a fresh claim is not reported stale" ;;
esac

# THE DIRECTION OF THE FALLBACK, for BOTH binaries. An unparseable stamp must
# mean "age unknown", not epoch 0 -- which is "infinitely old" and reports a
# fresh issue as ancient. The queue half was unguarded.
for stamp in "2020-01-01T00:00:00+05:30" "not-a-date" ""; do
  got=$(agefirst "$stamp")
  if [ "$got" = "$nowq" ]
  then ok "backlog-queue treats an unparsed stamp as now, not epoch 0 [$stamp]"
  else bad "backlog-queue unparsed-stamp direction [$stamp]" "got=[$got] wanted=[$nowq]"; fi
  case "$(stalefirst "$stamp")" in
    *"stale claims"*) bad "backlog-triage unparsed-stamp direction [$stamp]" "reported stale" ;;
    *) ok "backlog-triage treats an unparsed stamp as now [$stamp]" ;;
  esac
done
rm -f "$AGETMP" 2>/dev/null

# --- a scan that cannot run must say so --------------------------------------
# backlog-triage's scan() swallowed jq's stderr and dropped its status, so a
# failure died with stdout AND stderr empty -- read as "triage found nothing".
# The first fix was unreachable: `set -e` terminates the subshell at a bare
# failing pipeline, so the diagnostic never executed.
JQSHIM=${TMPDIR:-/tmp}/seam-jqshim.$$
mkdir -p "$JQSHIM"
REALJQ=$(command -v jq)
printf '#!/bin/sh\ncase "$*" in *"--arg check"*) echo "jq: forced failure" >&2; exit 5 ;; esac\nexec %s "$@"\n' "$REALJQ" > "$JQSHIM/jq"
chmod +x "$JQSHIM/jq"
printf '[{"number":1,"title":"t","state":"OPEN","labels":["task","claimed"],"createdAt":"2026-08-20T00:00:00Z","updatedAt":"2026-08-20T00:00:00Z","comments":[],"blockedBy":[]}]\n' > "$JQSHIM/i.json"
out=$(PATH="$JQSHIM:$PATH" BACKLOG_ISSUES_JSON="$JQSHIM/i.json" BACKLOG_NOW=1787184000 sh "$BIN/backlog-triage" 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "a failing scan exits 2, not jq's own code" || bad "scan failure exit" "got $rc"
case "$out" in
  *"could not scan the issue list"*) ok "and names the failure instead of dying silently" ;;
  *) bad "scan failure diagnostic" "out=[$out]" ;;
esac
rm -rf "$JQSHIM" 2>/dev/null

# --- every binary must parse as sh --------------------------------------------
# These scripts embed long jq programs inside SINGLE-quoted strings, so one
# apostrophe in a comment ends the string and the rest of the file becomes
# shell. The file still reads correctly; only `sh -n` sees it. That is exactly
# how it happened, in a comment reading "and jq's builtin".
for f in "$BIN"/*; do
  [ -f "$f" ] || continue
  if sh -n "$f" 2>/dev/null; then ok "$(basename "$f") parses as sh"
  else bad "$(basename "$f") parses as sh" "$(sh -n "$f" 2>&1 | head -1)"; fi
done
for f in "$HERE"/../lib/*.sh; do
  [ -f "$f" ] || continue
  if sh -n "$f" 2>/dev/null; then ok "$(basename "$f") parses as sh"
  else bad "$(basename "$f") parses as sh" "$(sh -n "$f" 2>&1 | head -1)"; fi
done

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
