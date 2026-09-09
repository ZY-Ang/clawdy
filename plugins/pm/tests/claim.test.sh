#!/bin/sh
# The claim protocol: bind an issue to a branch, open the pull request NOW, and
# be safe to run twice.
#
#   sh plugins/pm/tests/claim.test.sh
#
# gh is faked and records every call, so the assertions are about what would
# have been sent. git is real, against a throwaway repo with a real "remote" --
# branch creation and push are the half a JSON fixture cannot prove.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
TMP=${TMPDIR:-/tmp}/claim-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

command -v jq  >/dev/null 2>&1 || { echo "claim.test: jq required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "claim.test: git required" >&2; exit 1; }
# These cases fake gh, so they need it absent from the PATH the code under
# test sees -- NOT absent from the operator's machine. This used to refuse and
# exit 1, the same code a real failure uses, so a full-suite run was red on
# any machine that has gh.
. "$HERE/lib/gh-free.sh"
PATH=$(gh_free_path "$TMP/nogh"); export PATH

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

CALLS=$TMP/gh-calls
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "pr list")   [ "${GH_PR_EXISTS:-0}" = 1 ] && echo '[{"number":7}]' || echo '[]' ;;
  "pr create") echo "https://github.com/o/n/pull/9" ;;
  "issue view") cat "$GH_ISSUE" ;;
  *) : ;;
esac
exit "${GH_RC:-0}"
EOF
chmod +x "$TMP/bin/gh"
export GH_CALLS=$CALLS

# A real repo with a real remote, so push and branch creation are exercised.
mkrepo() {
  rm -rf "$TMP/up" "$TMP/wt"; : > "$CALLS"
  git init -q --bare "$TMP/up"
  git init -q "$TMP/wt"
  ( cd "$TMP/wt"
    git config user.email t@t; git config user.name t
    git commit -q --allow-empty -m base
    git branch -M main
    git remote add origin "$TMP/up"
    git push -q -u origin main ) 2>/dev/null
}

issue() { printf '%s' "$1" > "$TMP/issue.json"; export GH_ISSUE=$TMP/issue.json; }
OPEN='{"number":42,"title":"Fix the parser, twice","state":"OPEN","labels":[]}'

claim()   { ( cd "$TMP/wt" && PATH="$TMP/bin:$PATH" BACKLOG_NOW=1787184000 \
            BACKLOG_ISSUE_JSON=$TMP/issue.json sh "$BIN/backlog-claim" "$@" 2>&1 ); }
release() { ( cd "$TMP/wt" && PATH="$TMP/bin:$PATH" \
            BACKLOG_ISSUE_JSON=$TMP/issue.json sh "$BIN/backlog-release" "$@" 2>&1 ); }
# The binary name is consumed here. Passing "$@" straight through would hand the
# script its own name as the issue number, and every exit-code case would then
# be asserting the argument parser rather than the thing named in the case.
rc_of()   { _b=$1; shift
            ( cd "$TMP/wt" && PATH="$TMP/bin:$PATH" BACKLOG_NOW=1787184000 \
              BACKLOG_ISSUE_JSON=$TMP/issue.json sh "$BIN/$_b" "$@" >/dev/null 2>&1 ); echo $?; }

# --- the happy path, and the thing that makes it worth having -----------------
mkrepo; issue "$OPEN"
out=$(claim 42)
case "$out" in *"claimed #42"*) ok "claims an open issue" ;; *) bad "claims an open issue" "$out" ;; esac
case "$out" in *"claude/fix-the-parser-twice"*) ok "branch name comes from the title" ;; *) bad "branch name from title" "$out" ;; esac

if grep -q 'pr create .*--draft' "$CALLS"; then ok "opens the pull request as a DRAFT"
else bad "opens a draft PR" "$(cat "$CALLS")"; fi
if grep -q 'pr create' "$CALLS" && grep -q 'issue edit .*--add-label claimed' "$CALLS"; then
  ok "and labels the issue claimed"
else bad "labels claimed" "$(cat "$CALLS")"; fi

# The PR must exist BEFORE the label. A labelled issue with no PR is hidden from
# the queue while nothing is working it.
pr_line=$(grep -n 'pr create' "$CALLS" | head -1 | cut -d: -f1)
lbl_line=$(grep -n 'add-label claimed' "$CALLS" | head -1 | cut -d: -f1)
if [ -n "$pr_line" ] && [ -n "$lbl_line" ] && [ "$pr_line" -lt "$lbl_line" ]; then
  ok "PR is created before the label, not after"
else bad "PR before label" "pr=$pr_line label=$lbl_line"; fi

# `claimed` is tooling-written, and adding a label the repo does not have
# fails -- the first claim in a fresh repo did, after the branch and PR
# existed (#64). So the label is ensured before the add.
if grep -q 'label create claimed' "$CALLS"; then
  ok "ensures the claimed label exists"
else bad "ensures the claimed label" "$(cat "$CALLS")"; fi
lc_line=$(grep -n 'label create claimed' "$CALLS" | head -1 | cut -d: -f1)
if [ -n "$lc_line" ] && [ "$lc_line" -lt "$lbl_line" ]; then
  ok "and creates it before adding it"
else bad "creates the label before the add" "create=$lc_line add=$lbl_line"; fi

if ( cd "$TMP/wt" && git rev-parse --verify --quiet claude/fix-the-parser-twice >/dev/null ); then
  ok "the branch really exists"
else bad "branch exists"; fi
if ( cd "$TMP/up" && git rev-parse --verify --quiet claude/fix-the-parser-twice >/dev/null ); then
  ok "and was pushed to the remote"
else bad "branch pushed"; fi
if ( cd "$TMP/wt" && git log -1 --format=%s claude/fix-the-parser-twice | grep -q 'claim #42' ); then
  ok "the claim is recorded in git history too"
else bad "claim commit"; fi
if grep -q 'issue comment 42' "$CALLS"; then ok "and commented on the issue"
else bad "comment posted" "$(cat "$CALLS")"; fi

# --- idempotence: the whole point ---------------------------------------------
mkrepo; issue '{"number":42,"title":"Fix the parser, twice","state":"OPEN","labels":[{"name":"claimed"}]}'
out=$(claim 42)
case "$out" in *"already claimed"*) ok "a second claim reports, does not repeat" ;; *) bad "second claim reports" "$out" ;; esac
[ "$(rc_of backlog-claim 42)" -eq 0 ] && ok "and exits 0, so a loop is not trained to ignore it" \
  || bad "second claim exits 0"
if grep -q 'pr create' "$CALLS"; then bad "second claim opened another PR" "$(cat "$CALLS")"
else ok "no second pull request"; fi
if grep -q 'issue comment' "$CALLS"; then bad "second claim commented again" "$(cat "$CALLS")"
else ok "no second comment"; fi

# --- refusals, all before anything is written ---------------------------------
mkrepo; issue '{"number":42,"title":"Big one","state":"OPEN","labels":[{"name":"size-l"}]}'
[ "$(rc_of backlog-claim 42)" -eq 1 ] && ok "size-l is refused" || bad "size-l refused"
case "$(claim 42)" in *--force*) ok "and names --force" ;; *) bad "names --force" ;; esac
if [ -s "$CALLS" ] && grep -q 'pr create\|add-label' "$CALLS"; then
  bad "size-l refusal still wrote something" "$(cat "$CALLS")"
else ok "and wrote nothing"; fi
mkrepo; issue '{"number":42,"title":"Big one","state":"OPEN","labels":[{"name":"size-l"}]}'
[ "$(rc_of backlog-claim 42 --force)" -eq 0 ] && ok "--force claims it anyway" || bad "--force works"

mkrepo; issue '{"number":42,"title":"Waiting","state":"OPEN","labels":[{"name":"needs-human"}]}'
[ "$(rc_of backlog-claim 42)" -eq 1 ] && ok "needs-human is refused" || bad "needs-human refused"

mkrepo; issue '{"number":42,"title":"Done","state":"CLOSED","labels":[]}'
[ "$(rc_of backlog-claim 42)" -eq 1 ] && ok "a closed issue is refused" || bad "closed refused"

# --- could not tell is never a claim ------------------------------------------
mkrepo; issue 'not json at all'
[ "$(rc_of backlog-claim 42)" -eq 2 ] && ok "unparseable issue -> 2, never a silent claim" || bad "unparseable -> 2"
mkrepo; issue '{}'
[ "$(rc_of backlog-claim 42)" -eq 2 ] && ok "an issue with no title -> 2" || bad "no title -> 2"

mkrepo; issue "$OPEN"
[ "$(rc_of backlog-claim)" -eq 2 ]         && ok "no issue number -> 2"     || bad "no number -> 2"
[ "$(rc_of backlog-claim abc)" -eq 2 ]     && ok "a non-number -> 2"        || bad "non-number -> 2"
[ "$(rc_of backlog-claim 42 --nope)" -eq 2 ] && ok "unknown option -> 2"    || bad "unknown option -> 2"

# --- dry run ------------------------------------------------------------------
mkrepo; issue "$OPEN"
out=$(claim 42 --dry-run)
case "$out" in *"would claim"*) ok "--dry-run says what would happen" ;; *) bad "--dry-run" "$out" ;; esac
if [ -s "$CALLS" ]; then bad "--dry-run called gh" "$(cat "$CALLS")"; else ok "and calls nothing"; fi
if ( cd "$TMP/wt" && git rev-parse --verify --quiet claude/fix-the-parser-twice >/dev/null ); then
  bad "--dry-run created a branch"
else ok "and creates no branch"; fi

# --- release ------------------------------------------------------------------
mkrepo; issue '{"number":42,"title":"x","state":"OPEN","labels":[{"name":"claimed"}]}'
[ "$(rc_of backlog-release 42 --reason "blocked on DNS")" -eq 0 ] && ok "releases a claimed issue" || bad "release works"
if grep -q 'issue edit .*--remove-label claimed' "$CALLS"; then ok "removes the claimed label"
else bad "removes label" "$(cat "$CALLS")"; fi
c_line=$(grep -n 'issue comment' "$CALLS" | head -1 | cut -d: -f1)
r_line=$(grep -n 'remove-label' "$CALLS" | head -1 | cut -d: -f1)
if [ -n "$c_line" ] && [ -n "$r_line" ] && [ "$c_line" -lt "$r_line" ]; then
  ok "comments BEFORE unlabelling, so the reason cannot be lost"
else bad "comment before unlabel" "comment=$c_line remove=$r_line"; fi

mkrepo; issue '{"number":42,"title":"x","state":"OPEN","labels":[{"name":"claimed"}]}'
[ "$(rc_of backlog-release 42)" -eq 2 ] && ok "release without --reason -> 2" || bad "reason required"
case "$(release 42)" in *reason*) ok "and says why it matters" ;; *) bad "explains --reason" ;; esac

mkrepo; issue '{"number":42,"title":"x","state":"OPEN","labels":[]}'
[ "$(rc_of backlog-release 42 --reason y)" -eq 1 ] && ok "releasing an unclaimed issue -> 1" || bad "unclaimed -> 1"

# --- both answer --help -------------------------------------------------------
for b in backlog-claim backlog-release; do
  [ "$(rc_of $b --help)" -eq 0 ] && ok "$b --help -> 0" || bad "$b --help"
done

# --- --repo must match the checkout it pushes from ---------------------------
# `--repo` routed every tracker call and nothing routed the CODE. The push was
# `git push -q -u origin`, so the branch went to the cwd's origin while the
# draft PR was filed against --repo -- two different repositories in one
# command, and the PR then names a --head that does not exist there.
#
# backlog-claim inherently needs a local checkout to push from, so naming a
# different repo is a contradiction rather than a routing problem. It refuses.
mkrepo; issue "$OPEN"
out=$(claim 42 --repo someone/else)
# Assert it names BOTH repositories: an operator seeing only one cannot tell
# which end is wrong.
case "$out" in
  *"--repo is 'someone/else'"*"this checkout pushes to"*)
    ok "a --repo that is not this checkout is refused, naming both" ;;
  *) bad "mismatched --repo refused" "$out" ;;
esac
[ "$(rc_of backlog-claim 42 --repo someone/else)" -eq 2 ] \
  && ok "and exits 2, not a half-done claim" || bad "mismatch exit code"

# Nothing may be written on the way to refusing: no branch, no commit, no push.
mkrepo; issue "$OPEN"
claim 42 --repo someone/else >/dev/null 2>&1
pushed=$( cd "$TMP/up" && git for-each-ref --format='%(refname:short)' refs/heads | grep -c claude/ || true )
[ "$pushed" -eq 0 ] && ok "and pushes nothing to the ambient origin" \
  || bad "branch reached the wrong origin" "$pushed branch(es)"
: > "$CALLS"; claim 42 --repo someone/else >/dev/null 2>&1
[ ! -s "$CALLS" ] && ok "and makes no tracker call either" || bad "tracker called before refusing" "$(head -1 "$CALLS")"

# The matching case must still work, however the remote URL is spelled.
mkrepo; issue "$OPEN"
( cd "$TMP/wt" && git remote set-url origin "https://github.com/owner/name.git" ) 2>/dev/null
out=$(claim 42 --repo owner/name)
case "$out" in *"this checkout pushes to"*) bad "a matching --repo was refused" "$out" ;;
  *) ok "an https remote matching --repo is accepted" ;; esac

mkrepo; issue "$OPEN"
( cd "$TMP/wt" && git remote set-url origin "git@github.com:owner/name.git" ) 2>/dev/null
out=$(claim 42 --repo owner/name)
case "$out" in *"this checkout pushes to"*) bad "an ssh remote matching --repo was refused" "$out" ;;
  *) ok "an ssh remote matching --repo is accepted" ;; esac

# A subgroup path is the shape that breaks a naive basename comparison.
mkrepo; issue "$OPEN"
( cd "$TMP/wt" && git remote set-url origin "https://gitlab.com/group/sub/proj.git" ) 2>/dev/null
out=$(claim 42 --repo group/sub/proj)
case "$out" in *"this checkout pushes to"*) bad "a subgroup path matching --repo was refused" "$out" ;;
  *) ok "a nested group path matching --repo is accepted" ;; esac

# And with no --repo at all, nothing changes for anyone relying on today's behaviour.
mkrepo; issue "$OPEN"
out=$(claim 42)
case "$out" in *"this checkout pushes to"*) bad "no --repo must not be refused" "$out" ;;
  *) ok "with no --repo the cwd remains the destination" ;; esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
