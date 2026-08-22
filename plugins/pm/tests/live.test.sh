#!/bin/sh
# A live round-trip against a real backend, for the one bug class a fixture
# cannot catch.
#
#   PM_LIVE_REPO=owner/scratch sh plugins/pm/tests/live.test.sh
#
# #45 was a wrong scalar type in a request body -- `gh api -f` sends a string,
# the endpoint wanted an integer, every call 422'd -- and every test passed,
# because every test fakes gh. The tool could not create an edge against any
# real repository. A fixture for a wire format has to come off the wire; a
# fixture cannot catch a wrong scalar type AT ALL.
#
# Opt-in on purpose: it needs credentials, a network and a throwaway repo, so
# it is not part of the normal suite, and it skips loudly rather than silently
# when PM_LIVE_REPO is unset. In CI it exits 0 on the skip line.
#
# NOT RUN AGAINST GITHUB, DELIBERATELY. Automating issue and pull request
# creation on github.com -- even in a throwaway repo -- is synthetic traffic
# GitHub's terms do not permit, so this suite has never run live against
# GitHub. That is a known testing gap: the #45 class of bug is exactly what it
# exists to catch, and exactly what no fixture can. It remains the acceptance
# test for any provider whose terms allow it -- PM_PROVIDER selects one, and
# the contract rather than GitHub is what gets exercised.
#
# It drives the binaries and reads everything back through the provider seam,
# asserting the ROUND TRIP, not the exit code. backlog-link once exited 2
# correctly while being completely broken; what distinguished working from
# broken was reading the edge back.
#
# What it leaves behind, on PM_LIVE_REPO only: the two issues and the question
# it files are closed at the end, and the claim's draft PR is closed with its
# branch deleted. If the run dies mid-way the leftovers stay -- titles carry
# the PID, so the next run does not collide with them.
#
# The file names no repository. PM_LIVE_REPO is also required to contain
# "scratch" (PM_LIVE_FORCE=1 overrides), because this test CLOSES issues in
# whatever repo it is pointed at.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
PM_LIB=$HERE/../lib

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

# --- opt in ------------------------------------------------------------------
if [ -z "${PM_LIVE_REPO:-}" ]; then
  printf 'live.test: PM_LIVE_REPO is not set -- skipping.\n'
  printf '  set it to run the round trip against a throwaway repo:\n'
  printf '  PM_LIVE_REPO=owner/scratch sh plugins/pm/tests/live.test.sh\n'
  exit 0
fi

# The repo is disposable or the test does not run. It closes every issue it
# files, but a crash mid-run leaves them open, and a typo'd PM_LIVE_REPO that
# points at a real tracker would close real issues.
case "$PM_LIVE_REPO" in
  *scratch*) ;;
  *) if [ "${PM_LIVE_FORCE:-0}" != 1 ]; then
       printf 'live.test: %s does not look like a throwaway repo.\n' "$PM_LIVE_REPO" >&2
       printf '  this test creates, links, claims and CLOSES issues in it.\n' >&2
       printf '  name a repo containing "scratch", or set PM_LIVE_FORCE=1 to proceed.\n' >&2
       exit 1
     fi ;;
esac

# A fixture seam set in the environment would silently fake the run -- the one
# failure mode this suite exists to make impossible.
if [ -n "${BACKLOG_ISSUES_JSON:-}${BACKLOG_ISSUE_JSON:-}${BACKLOG_DEPS_JSON:-}${BACKLOG_LINK_JSON:-}${CHECK_REPLIES_JSON:-}" ]; then
  printf 'live.test: a fixture seam is set in the environment; a live run must not read fixtures\n' >&2
  exit 1
fi

command -v gh  >/dev/null 2>&1 || { echo "live.test: PM_LIVE_REPO is set but gh is not installed" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "live.test: jq is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "live.test: git is required" >&2; exit 1; }

# file-issue and ask-async persist a note per filing. A live run must not
# pollute the local questions dir with scratch issues.
export CLAUDE_QUESTIONS_NO_PERSIST=1
# A push that cannot authenticate must fail, not hang on a credential prompt.
export GIT_TERMINAL_PROMPT=0

# --- load the configured provider, whatever it is -----------------------------
# The suite is written against the contract, not against gh: every assertion
# goes through provider_*, so a second backend fails here in its own way
# rather than silently passing a github-only test.
. "$PM_LIB/load-provider.sh"
pm_load_provider || exit 1
provider_available || {
  echo "live.test: $(provider_name) is not reachable" >&2
  [ -n "${PROVIDER_ERR:-}" ] && printf '%s\n' "$PROVIDER_ERR" | sed 's/^/  /' >&2
  exit 1
}

# The one gh call that is not contract: no provider function clones a repo,
# and the suite needs a real checkout for the claim's branch and push.
TMP=${TMPDIR:-/tmp}/live-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM
gh repo clone "$PM_LIVE_REPO" "$TMP/wt" 2>"$TMP/clone.err" \
  && ok "cloned $PM_LIVE_REPO" \
  || { bad "clone failed" "$(cat "$TMP/clone.err" 2>/dev/null || true)"; exit 1; }

# gh clones an empty repo to an unborn HEAD, which git cannot branch from.
# Give it one base commit so the claim has something to push against.
if ! git -C "$TMP/wt" rev-parse --verify HEAD >/dev/null 2>&1; then
  ( cd "$TMP/wt"
    git config user.email live@test; git config user.name "live test"
    git commit -q --allow-empty -m "base: created by pm's live test"
    git branch -M main
    git push -q -u origin main ) \
    && ok "seeded the empty repo with a base commit" \
    || { bad "could not seed $PM_LIVE_REPO"; exit 1; }
fi

RUN=$$   # titles and the branch carry the PID, so reruns never collide
REPO=$PM_LIVE_REPO

# Every binary runs inside the scratch worktree -- backlog-claim pushes from
# it, and gh would otherwise infer the surrounding repo.
inwt() { ( cd "$TMP/wt" && "$@" ); }

# The URL a filing prints is backend-shaped; the number comes from a read-back
# through the provider, which works for any backend and is itself an assertion.
issue_num() {
  provider_issues "$REPO" 2>/dev/null \
    | jq -r --arg t "$1" '.[] | select(.title == $t) | .number' | head -1
}

# --- file two issues ----------------------------------------------------------
TITLE_A="live test task A $RUN"
TITLE_B="live test task B $RUN"

URL=$(inwt "$BIN/file-issue" task "$TITLE_A" \
        --priority low --urgency low --size s --repo "$REPO") \
  && ok "task A filed ($URL)" \
  || bad "file-issue task A"
A_NUM=$(issue_num "$TITLE_A")
[ -n "$A_NUM" ] && ok "task A reads back as #$A_NUM" || bad "task A did not read back"

URL=$(inwt "$BIN/file-issue" task "$TITLE_B" \
        --priority med --urgency low --size m --repo "$REPO") \
  && ok "task B filed ($URL)" \
  || bad "file-issue task B"
B_NUM=$(issue_num "$TITLE_B")
[ -n "$B_NUM" ] && ok "task B reads back as #$B_NUM" || bad "task B did not read back"

# Labels are part of the wire shape too: provider_create_issue once dropped
# every label and still printed a URL. Read them back.
lab=$(provider_issue_labels "$A_NUM" "$REPO" | sort | tr '\n' ' ')
case " $lab " in
  *" priority-low "*" size-s "*" task "*" urgency-low "*) ok "task A carries its axes and kind" ;;
  *) bad "task A's labels did not read back" "got: $lab" ;;
esac
lab=$(provider_issue_labels "$B_NUM" "$REPO" | sort | tr '\n' ' ')
case " $lab " in
  *" priority-med "*" size-m "*" task "*" urgency-low "*) ok "task B carries its axes and kind" ;;
  *) bad "task B's labels did not read back" "got: $lab" ;;
esac

# --- link, read the edge back, unlink -----------------------------------------
inwt "$BIN/backlog-link" "$A_NUM" --blocked-by "$B_NUM" --repo "$REPO" >/dev/null \
  && ok "linked: #$A_NUM blocked by #$B_NUM" \
  || bad "backlog-link refused to link"

# THE assertion #45 could not make: the edge exists where the backend keeps it.
blk=$(provider_blocked_by "$A_NUM" "$REPO")
[ "$blk" = "$B_NUM" ] && ok "the edge reads back: #$A_NUM is blocked by #$B_NUM" \
  || bad "the backend does not record the edge" "got: ${blk:-<nothing>}"

inwt "$BIN/backlog-link" "$A_NUM" --unblock "$B_NUM" --repo "$REPO" >/dev/null \
  && ok "unlinked: #$A_NUM no longer blocked by #$B_NUM" \
  || bad "backlog-link refused to unlink"
blk=$(provider_blocked_by "$A_NUM" "$REPO")
[ -z "$blk" ] && ok "and the edge is gone after unlink" \
  || bad "the unlink did not read back" "still blocked by: $blk"

# --- claim, read the claim back, release --------------------------------------
BRANCH="live/$RUN"

inwt "$BIN/backlog-claim" "$A_NUM" --branch "$BRANCH" --repo "$REPO" >/dev/null \
  && ok "claimed #$A_NUM on $BRANCH" \
  || bad "backlog-claim failed"

provider_issue_labels "$A_NUM" "$REPO" | grep -qx claimed \
  && ok "the claim stuck the label" \
  || bad "the claimed label did not stick"

PR_NUM=$(provider_find_pr "$BRANCH" "$REPO")
[ -n "$PR_NUM" ] && ok "the draft PR exists (#$PR_NUM)" \
  || bad "no draft PR reads back for $BRANCH"

git -C "$TMP/wt" ls-remote --heads origin "refs/heads/$BRANCH" 2>/dev/null | grep -q . \
  && ok "the branch was really pushed" \
  || bad "the branch is not on the remote"

inwt "$BIN/backlog-release" "$A_NUM" \
      --reason "live test $RUN -- returning to the queue" --repo "$REPO" >/dev/null \
  && ok "released #$A_NUM" \
  || bad "backlog-release failed"
if provider_issue_labels "$A_NUM" "$REPO" | grep -qx claimed; then
  bad "the claimed label did not come off"
else
  ok "and the claim label is gone"
fi

# --- the question half: ask-async, check-replies, reply-issue ------------------
QTITLE="live test question $RUN"
inwt "$BIN/ask-async" "$QTITLE" \
      --blocked-on access \
      --context "live test $RUN -- exercising the wire shape" \
      --option "yes|it works" --option "no|it does not" \
      --assume "yes -- this is a live test" \
      --repo "$REPO" >/dev/null \
  && ok "the question filed through ask-async" \
  || bad "ask-async failed"
Q_NUM=$(issue_num "$QTITLE")
[ -n "$Q_NUM" ] && ok "the question reads back as #$Q_NUM" || bad "the question did not read back"

provider_issue_labels "$Q_NUM" "$REPO" | grep -qx needs-human \
  && ok "it carries needs-human" \
  || bad "needs-human did not stick"

# provider_needs_human is check-replies' data path; the body the filing wrote
# must carry the agent mark -- that is the fact the whole reply protocol reads.
nh=$(provider_needs_human "$REPO")
printf '%s' "$nh" | jq -e --argjson n "$Q_NUM" 'any(.[]; .number == $n)' >/dev/null 2>&1 \
  && ok "it appears in the needs-human feed" \
  || bad "provider_needs_human does not list it" "${nh:-<empty>}"
mk=$(provider_issue "$Q_NUM" "$REPO" | jq -r '.body // ""' 2>/dev/null)
case "$mk" in
  🤖*) ok "the filed body carries the agent mark" ;;
  *)   bad "the filed body is not agent-marked" "${mk:-<no body>}" ;;
esac

inwt "$BIN/check-replies" --repo "$REPO" --quiet >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && ok "check-replies: nothing answered yet (exit 1)" \
  || bad "check-replies should report the question unanswered" "exit $rc"

inwt "$BIN/reply-issue" "$Q_NUM" "live test $RUN -- closing the question" \
      --closes --as not-planned --repo "$REPO" >/dev/null \
  && ok "the question closed through reply-issue" \
  || bad "reply-issue --closes failed on the question"
st=$(provider_issue "$Q_NUM" "$REPO" | jq -r '.state // empty')
[ "$st" = "CLOSED" ] && ok "it reads back CLOSED" || bad "the question did not close" "state: ${st:-<none>}"
if provider_issue_labels "$Q_NUM" "$REPO" | grep -qx needs-human; then
  bad "needs-human outlived the close"
else
  ok "and needs-human is gone"
fi

# --- close both tasks ----------------------------------------------------------
for n in "$A_NUM" "$B_NUM"; do
  inwt "$BIN/reply-issue" "$n" "live test $RUN -- closing" --closes --repo "$REPO" >/dev/null \
    && ok "closed #$n" \
    || bad "reply-issue --closes failed on #$n"
  st=$(provider_issue "$n" "$REPO" | jq -r '.state // empty')
  [ "$st" = "CLOSED" ] && ok "#$n reads back CLOSED" || bad "#$n did not close" "state: ${st:-<none>}"
done

# --- tidy the claim's PR -------------------------------------------------------
# The claim protocol leaves branch and PR behind on purpose; a scratch repo
# would accumulate one per run. Closing one is plumbing -- the contract has no
# provider_close_pr, which is exactly the gap #56 records.
case "$(provider_name)" in
  github)
    gh pr close "$PR_NUM" --repo "$REPO" --delete-branch >/dev/null 2>&1 \
      && ok "the claim's draft PR is closed and its branch deleted" \
      || bad "could not close the claim's draft PR -- close #$PR_NUM by hand" ;;
  *) printf 'note: the claim protocol left the draft PR open -- the contract has no way to close one (see #56)\n' ;;
esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
