#!/bin/sh
# The gitlab provider, against a fake glab.
#
#   sh plugins/pm/tests/glab-provider.test.sh
#
# The fake is a shell script on PATH that dispatches on the subcommand and
# cats the captured wire fixtures. Those fixtures came off a real glab run
# against gitlab.com's public gitlab-org/cli project (`glab issue list` and
# `glab issue view`, both `--output json`) -- a hand-written one would agree
# with the bug it was meant to catch.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB=$HERE/../lib
FIX=$HERE/fixtures
TMP=${TMPDIR:-/tmp}/glab-provider.$$
mkdir -p "$TMP/bin" "$TMP/log"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "glab-provider.test: jq required" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

# Page-mode fixtures: a full page of 100 rows, and a one-row last page, built
# from the captured wire rows so the paging loop is tested against real shape.
jq -s '.[0][0] as $r | [range(0;100) | $r]' "$FIX/issues-gitlab-shape.json" > "$TMP/full-page.json"
jq -s '.[0][0:1]' "$FIX/issues-gitlab-shape.json" > "$TMP/one-row.json"

cat > "$TMP/bin/glab" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\${FAKE_GLAB_LOG:-/dev/null}"
if [ "\${FAKE_GLAB_FAIL:-0}" = "1" ]; then
  echo "glab fake: the backend exploded (HTTP 502)" >&2
  exit 1
fi
case "\$1" in
  mr)
    case "\$2" in
      create) echo "https://gitlab.com/owner/repo/-/merge_requests/77" ;;
      list)   cat "$FIX/mrs-gitlab-shape.json" ;;
    esac ;;
  issue)
    case "\$2" in
      list)
        if [ "\${FAKE_GLAB_PAGE:-0}" = "1" ]; then
          case "\$*" in *"--page 2"*) cat "$TMP/one-row.json" ;; *) cat "$TMP/full-page.json" ;; esac
        else
          cat "$FIX/issues-gitlab-shape.json"
        fi ;;
      view) cat "$FIX/issue-gitlab-shape.json" ;;
      create) echo "https://gitlab.com/owner/repo/-/issues/99" ;;
      note|update|close) exit 0 ;;
    esac ;;
  label) exit 0 ;;
  repo) cat "$FIX/repo-gitlab-shape.json" ;;
  api)
    # The REST half. Dispatch on the method and the path, the way the real
    # endpoint does -- the provider builds these URLs itself, so a typo in one
    # has to show up here as "no fixture" rather than as a silent empty answer.
    _m=view
    case "\$*" in *"--method POST"*) _m=post ;; *"--method DELETE"*) _m=delete ;; esac
    for a in "\$@"; do case "\$a" in projects/*) _p=\$a ;; esac; done
    case "\$_m:\$_p" in
      post:*/links*)   cat "$FIX/links-403-gitlab-shape.json"; echo "glab: Blocked issues not available for current license (HTTP 403)" >&2; exit 1 ;;
      delete:*/links/*) exit 0 ;;
      view:*"/issues/1/notes"*) cat "$FIX/notes-answered-gitlab-shape.json" ;;
      view:*"/issues/2/notes"*) cat "$FIX/notes-blocked-gitlab-shape.json" ;;
      view:*/issues/*/links*) cat "$FIX/links-gitlab-shape.json" ;;
      view:*labels=needs-human*) cat "$FIX/issues-needs-human-gitlab-shape.json" ;;
      view:*"/issues?"*)  cat "$FIX/issues-gitlab-shape.json" ;;
      view:*/issues/*)  jq '.[0]' "$FIX/issues-needs-human-gitlab-shape.json" ;;
      *) echo "glab fake: no api fixture for \$_m \$_p" >&2; exit 1 ;;
    esac ;;
  *) echo "glab fake: no fixture for \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/glab"

# run <fn> <args...> -> stdout of the provider function, with the fake glab
# first on PATH and the provider sourced fresh in a subshell.
run() {
  ( PATH="$TMP/bin:$PATH"; . "$LIB/provider-gitlab.sh"; "$@" )
}

# --- the trivial two ---------------------------------------------------------
[ "$(run provider_name)" = "gitlab" ] && ok "provider_name is gitlab" || bad "provider_name"
[ "$(run provider_pr_ref_mark)" = "!" ] && ok "the MR mark is !, not # -- # would read as an issue" || bad "pr_ref_mark"

if ( PATH="$TMP/bin:$PATH"; . "$LIB/provider-gitlab.sh"; provider_available )
then ok "available when glab is on PATH"
else bad "available when glab is on PATH"; fi
if ( PATH="$TMP/empty"; . "$LIB/provider-gitlab.sh"; provider_available )
then bad "unavailable when glab is missing"; else ok "unavailable when glab is missing"; fi

# --- provider_issues: the wire shape becomes the contract shape --------------
out=$(run provider_issues owner/repo)
[ $? -eq 0 ] || bad "provider_issues exit 0" "$out"
jq -e 'length == 2' >/dev/null 2>&1 <<EOF && ok "two issues come back" || bad "two issues come back"
$out
EOF

n=$(printf '%s' "$out" | jq -r '.[0] | keys | sort | join(",")')
want=$(printf 'blockedBy,comments,createdAt,labels,number,state,title,updatedAt')
[ "$n" = "$want" ] && ok "exactly the contract keys" || bad "exactly the contract keys" "got: $n"

[ "$(printf '%s' "$out" | jq -r '.[0].number')" = "8511" ] && ok "iid becomes number" || bad "iid becomes number"
[ "$(printf '%s' "$out" | jq -r '.[0].state')" = "OPEN" ] && ok "opened becomes OPEN" || bad "opened becomes OPEN"
[ "$(printf '%s' "$out" | jq -r '.[0].createdAt')" != "null" ] && ok "created_at becomes createdAt" || bad "createdAt present"
[ "$(printf '%s' "$out" | jq -r '.[0].labels | join(" ")')" != "" ] && ok "labels are the strings" || bad "labels present"
[ "$(printf '%s' "$out" | jq -r '.[0].comments | type')" = "array" ] && ok "comments is an empty array, never absent" || bad "comments array"
[ "$(printf '%s' "$out" | jq -r '.[0].blockedBy | type')" = "array" ] && ok "blockedBy is an empty array, never absent" || bad "blockedBy array"
# No repo -> no -R, and the queue must still work from inside a project dir.
run provider_issues >/dev/null 2>&1 && ok "works without a repo argument" || bad "no-repo call"

# --- provider_issue ----------------------------------------------------------
one=$(run provider_issue 8511 owner/repo)
[ $? -eq 0 ] || bad "provider_issue exit 0" "$one"
[ "$(printf '%s' "$one" | jq -r '.number')" = "8511" ] && ok "issue number from iid" || bad "issue number"
[ "$(printf '%s' "$one" | jq -r '.state')" = "OPEN" ] && ok "issue state normalised" || bad "issue state"
case "$(printf '%s' "$one" | jq -r '.body')" in
  "## Problem"*) ok "description becomes body" ;;
  *) bad "description becomes body" ;;
esac

# --- provider_needs_human: an honest cannot-tell until the write half --------
# --- needs-human: the whole answered-question loop turns on this -------------
nh=$(run provider_needs_human owner/repo)
[ $? -eq 0 ] && ok "needs-human exits 0 with a token" || bad "needs-human exit 0" "$nh"
[ "$(printf '%s' "$nh" | jq -r 'length')" = "2" ] && ok "both labelled issues come back" \
  || bad "two needs-human issues" "$(printf '%s' "$nh" | jq -r 'length')"

k=$(printf '%s' "$nh" | jq -r '.[0] | keys | sort | join(",")')
[ "$k" = "comments,number,title" ] && ok "the contract keys, nothing else" || bad "contract keys" "got: $k"
ck=$(printf '%s' "$nh" | jq -r '.[0].comments[0] | keys | sort | join(",")')
case "$ck" in *author*body*) ok "comments carry author and body" ;; *) bad "comment keys" "got: $ck" ;; esac
# check-replies reads .author.login; GitLab's key is username. A provider that
# passed the wire shape through would give every comment a null author.
[ "$(printf '%s' "$nh" | jq -r '.[0].comments[0].author.login')" = "ZY-Ang" ] \
  && ok "username is mapped to author.login" || bad "author.login mapping"

# SYSTEM NOTES. GitLab puts "changed title from", "marked as related to" in the
# same stream as human comments. check-replies asks whether the LAST comment
# carries the agent mark -- so a system note after an agent reply reads as a
# human answering, and a question still blocked gets reported ANSWERED. The
# fixture has two of them, recorded after the agent's reply, deliberately.
sys=$(printf '%s' "$nh" | jq -r '[ .[].comments[] | select(.body | test("changed title|marked as related")) ] | length')
[ "$sys" = "0" ] && ok "system notes are excluded" || bad "system notes leaked" "$sys of them"
blocked=$(printf '%s' "$nh" | jq -r '.[] | select(.number == 2) | .comments | length')
[ "$blocked" = "2" ] && ok "only the two human-written notes survive" || bad "note count" "got $blocked"

# ORDER IS THE ANSWER. Last comment marked -> still on the human; unmarked ->
# answered. Both directions are pinned, because a reversed sort reports every
# question as the opposite of what it is and still looks like it works.
last2=$(printf '%s' "$nh" | jq -r '.[] | select(.number == 2) | .comments | last | .body')
case "$last2" in "🤖"*) ok "issue 2: agent spoke last, still blocked" ;; *) bad "issue 2 last comment" "$last2" ;; esac
last1=$(printf '%s' "$nh" | jq -r '.[] | select(.number == 1) | .comments | last | .body')
case "$last1" in "🤖"*) bad "issue 1 last comment" "$last1" ;; *) ok "issue 1: human spoke last, answered" ;; esac

# --- the dependency graph ----------------------------------------------------
[ "$(run provider_issue_id 2 owner/repo)" = "2" ] && ok "issue_id is the iid, which links take" || bad "issue_id"

# The fixture holds a relates_to edge -- the only kind gitlab.com free can
# create. relates_to is symmetric and carries no direction, so counting it as a
# blocker would invent an ordering constraint nobody recorded.
bb=$(run provider_blocked_by 2 owner/repo)
[ -z "$bb" ] && ok "relates_to is not a blocker" || bad "relates_to counted as a blocker" "$bb"

# A licence without blocking links fails LOUDLY, carrying GitLab's own words.
# Silently degrading to relates_to would record the wrong claim.
lk=$( PATH="$TMP/bin:$PATH"; . "$LIB/provider-gitlab.sh"; provider_link 2 3 owner/repo >/dev/null 2>&1; printf '%s' "$PROVIDER_ERR" )
case "$lk" in *"not available for current license"*) ok "link failure carries the licence message" ;; *) bad "link error" "$lk" ;; esac
if ( PATH="$TMP/bin:$PATH"; . "$LIB/provider-gitlab.sh"; provider_link 2 3 owner/repo >/dev/null 2>&1 )
then bad "link reports success on a 403"; else ok "link reports failure on a 403"; fi

# unlink needs the LINK's id, not either issue's. Passing an issue number there
# deletes nothing; the lookup is the function's job, not the caller's.
if ( PATH="$TMP/bin:$PATH"; . "$LIB/provider-gitlab.sh"; provider_unlink 2 99 owner/repo >/dev/null 2>&1 )
then bad "unlink claims success for an edge that is not there"
else ok "unlink fails when no is_blocked_by edge exists"; fi

# Degrade, do not fail: an unreachable backend means "no dependency graph", so
# the queue drops the dependents term instead of erroring.
if ( PATH="$TMP/bin:$PATH"; FAKE_GLAB_FAIL=1; export FAKE_GLAB_FAIL; . "$LIB/provider-gitlab.sh"; provider_supports_deps owner/repo )
then bad "supports_deps says yes with a dead backend"; else ok "supports_deps degrades when the backend is dead"; fi
if ( PATH="$TMP/bin:$PATH"; PM_ASSUME_DEPS=1; export PM_ASSUME_DEPS; . "$LIB/provider-gitlab.sh"; provider_supports_deps owner/repo )
then bad "PM_ASSUME_DEPS ignored"; else ok "PM_ASSUME_DEPS overrides the probe"; fi

# --- paging: glab returns page one, thirty rows, silently ---------------------
out=$(FAKE_GLAB_PAGE=1 run provider_issues owner/repo)
[ $? -eq 0 ] || bad "paged provider_issues exit 0" "$out"
[ "$(printf '%s' "$out" | jq 'length')" = "101" ] && ok "pages past a full page" \
  || bad "pages past a full page" "got $(printf '%s' "$out" | jq 'length')"
out=$(FAKE_GLAB_PAGE=1 PM_LIMIT=50 run provider_issues owner/repo)
[ "$(printf '%s' "$out" | jq 'length')" = "50" ] && ok "PM_LIMIT caps the queue" \
  || bad "PM_LIMIT caps the queue" "got $(printf '%s' "$out" | jq 'length')"

# --- the write half: each call is the command line, verbatim ------------------
log() { FAKE_GLAB_LOG="$TMP/log/calls" run "$@" >/dev/null 2>&1; cat "$TMP/log/calls"; rm -f "$TMP/log/calls"; }

l=$(log provider_comment 5 "done, pushed" owner/repo)
case "$l" in *"issue note 5 -m done, pushed -R owner/repo"*) ok "comment posts as a note" ;; *) bad "comment posts as a note" "$l" ;; esac

l=$(log provider_label 5 bug add owner/repo)
case "$l" in *"issue update 5 -l bug -R owner/repo"*) ok "label add updates -l" ;; *) bad "label add" "$l" ;; esac
l=$(log provider_label 5 bug remove owner/repo)
case "$l" in *"issue update 5 -u bug -R owner/repo"*) ok "label remove updates -u" ;; *) bad "label remove" "$l" ;; esac
( run provider_label 5 bug reorder owner/repo ) >/dev/null 2>&1
[ $? -eq 2 ] && ok "a bad label op is refused" || bad "bad label op refused"

l=$(log provider_close_issue 5 completed owner/repo)
case "$l" in *"issue close 5 -R owner/repo"*) ok "close carries no reason -- GitLab has none" ;; *) bad "close" "$l" ;; esac

run provider_ensure_label task owner/repo >/dev/null 2>&1
[ $? -eq 0 ] && ok "ensure-label always succeeds" || bad "ensure-label always succeeds"
l=$(log provider_ensure_label task owner/repo)
case "$l" in *"label create -n task -R owner/repo"*) ok "ensure-label creates by name" ;; *) bad "ensure-label" "$l" ;; esac

url=$(printf 'the body\n' | run provider_create_issue owner/repo "A title" task)
[ $? -eq 0 ] && [ "$url" = "https://gitlab.com/owner/repo/-/issues/99" ] && ok "create passes the URL through" || bad "create URL" "$url"
l=$(printf 'the body\n' | log provider_create_issue owner/repo "A title" task)
case "$l" in *"issue create -t A title -d the body -y --label task -R owner/repo"*) ok "create sends title, stdin body, yes, labels" ;; *) bad "create args" "$l" ;; esac

labs=$(run provider_issue_labels 8511 owner/repo)
case "$labs" in *"automation:ml"*) ok "issue labels come back one per line" ;; *) bad "issue labels" "$labs" ;; esac

url=$(run provider_open_draft_pr feat/x "Draft MR" "the body" main owner/repo)
[ $? -eq 0 ] && [ "$url" = "https://gitlab.com/owner/repo/-/merge_requests/77" ] && ok "draft MR passes the URL through" || bad "draft MR URL" "$url"
l=$(log provider_open_draft_pr feat/x "Draft MR" "the body" main owner/repo)
case "$l" in *"mr create -s feat/x -b main -t Draft MR -d the body --draft -y -R owner/repo"*) ok "draft MR carries branch, base, draft and yes" ;; *) bad "draft MR args" "$l" ;; esac

n=$(run provider_find_pr feat/x owner/repo)
[ "$n" = "3771" ] && ok "find-pr reads iid from the real mr-list wire shape" || bad "find-pr" "$n"
run provider_find_pr feat/x >/dev/null 2>&1 && ok "find-pr works without a repo argument" || bad "find-pr no repo"

# --- the backend's own words are never discarded -----------------------------
out=$(FAKE_GLAB_FAIL=1 run provider_issues owner/repo 2>&1)
[ $? -ne 0 ] && ok "a failing glab is a failing provider" || bad "failure exit"
err=$(FAKE_GLAB_FAIL=1 bash -c 'PATH="$0/bin:$PATH"; . "$1/provider-gitlab.sh"; provider_issues owner/repo >/dev/null 2>&1; printf "%s" "$PROVIDER_ERR"' "$TMP" "$LIB")
case "$err" in *"HTTP 502"*) ok "PROVIDER_ERR carries the backend diagnostic" ;; *) bad "PROVIDER_ERR" "$err" ;; esac

# --- the repo argument reaches glab as -R ------------------------------------
FAKE_GLAB_LOG="$TMP/log/calls" run provider_issues owner/repo >/dev/null 2>&1
grep -q -- '-R owner/repo' "$TMP/log/calls" && ok "-R carries the repo" || bad "-R carries the repo" "$(cat "$TMP/log/calls")"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
