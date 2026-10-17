#!/bin/sh
# pr-watch-gitea, alone and end to end through pr-watch, against a stub curl.
#
#   sh plugins/devloop/tests/pr-watch-gitea.test.sh
#
# No live Gitea instance is used (one is pending a scratch instance). Fixture
# shapes follow Gitea's published API schema (https://docs.gitea.com/api and
# modules/structs in https://github.com/go-gitea/gitea): PullRequest,
# CombinedStatus/CommitStatus (note: `status`, not `state`, per entry) and
# PullReview.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$(CDPATH= cd -- "$HERE/../bin" && pwd)
TMP=${TMPDIR:-/tmp}/pr-watch-gitea-test.$$
mkdir -p "$TMP/sbin" "$TMP/work"
trap 'rm -rf "$TMP"' EXIT INT TERM
cp "$HERE/stub-curl" "$TMP/sbin/curl"; chmod +x "$TMP/sbin/curl"

URL=https://gitea.com
TOKEN=tok-5f3a9c1e
A=$URL/api/v1/repos/o/r
HEAD_SHA=1111111111111111111111111111111111111111
BASE_SHA=2222222222222222222222222222222222222222
OLD_SHA=3333333333333333333333333333333333333333
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2" | head -20
        return 0; }

nb=0
reset() { : > "$TMP/log"; : > "$TMP/routes"; }
route() { # METHOD URL CODE BODY
  nb=$((nb + 1)); printf '%s\n' "$4" > "$TMP/body.$nb"
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$TMP/body.$nb" >> "$TMP/routes"
}

# pr <number> <state> <merged> <draft> <mergeable> <merge_base> <title>
pr() {
  cat <<EOF
{"id":$(($1 + 100)),"number":$1,"title":"$7","state":"$2","draft":$4,
 "user":{"id":7,"login":"me"},"merged":$3,"mergeable":$5,"merge_base":"$6",
 "html_url":"$URL/o/r/pulls/$1",
 "base":{"label":"main","ref":"main","sha":"$BASE_SHA","repo_id":1},
 "head":{"label":"feat","ref":"feat","sha":"$HEAD_SHA","repo_id":1}}
EOF
}
status() { # <state> <context> -> one CommitStatus
  printf '{"id":%s,"status":"%s","context":"%s","description":"","target_url":""}' "$nb" "$1" "$2"
}
combined() { # <statuses json array>
  printf '{"state":"pending","sha":"%s","total_count":0,"statuses":%s,"commit_url":"","url":""}' "$HEAD_SHA" "$1"
}
review() { # <id> <user id> <state> <dismissed>
  printf '{"id":%s,"user":{"id":%s,"login":"u%s"},"state":"%s","dismissed":%s,"stale":false,"official":true,"commit_id":"%s"}' \
    "$1" "$2" "$2" "$3" "$4" "$HEAD_SHA"
}

# setup <pr json> <statuses array> <reviews array>: routes for PR 14, one page each.
setup() {
  reset
  route GET "$A/pulls/14" 200 "$1"
  route GET "$A/commits/$HEAD_SHA/status?page=1&limit=50" 200 "$(combined "$2")"
  route GET "$A/commits/$HEAD_SHA/status?page=2&limit=50" 200 "$(combined null)"
  route GET "$A/pulls/14/reviews?page=1&limit=50" 200 "$3"
  route GET "$A/pulls/14/reviews?page=2&limit=50" 200 '[]'
}

env_run() { # <cmd...>; sets out, rc
  out=$(cd "$TMP/work" && PATH="$TMP/sbin:$BIN:$PATH" STUB_DIR="$TMP" \
        GITEA_URL=${GU-$URL} GITEA_TOKEN=${GT-$TOKEN} PR_WATCH_REPO=${GR-o/r} "$@" 2>&1); rc=$?
}
pw() { env_run env PR_WATCH_PROVIDER=pr-watch-gitea sh "$BIN/pr-watch" "$@"; }
prov() { env_run sh "$BIN/pr-watch-gitea" "$@"; }

expect() { # <name> <want rc> <substring in output>
  case "$rc:$out" in
    "$2:"*"$3"*) ok "$1" ;;
    *) bad "$1" "rc=$rc, wanted $2 and '$3': $out" ;;
  esac
}

OPEN_OK=$(pr 14 open false false true "$BASE_SHA" "Add a thing")
GREEN="[$(status success build),$(status success test)]"
APPROVED="[$(review 1 9 APPROVED false)]"

# --- end to end through pr-watch ------------------------------------------
setup "$OPEN_OK" "$GREEN" "$APPROVED"; pw 14
expect "green, approved, up to date: READY TO MERGE" 0 "READY TO MERGE"

setup "$OPEN_OK" "$GREEN" '[]'; pw 14
expect "green, no review yet: READY FOR REVIEW" 0 "READY FOR REVIEW"

setup "$(pr 14 open false false true "$OLD_SHA" t)" "$GREEN" "$APPROVED"; pw 14
expect "merge_base is not the base tip: BEHIND" 1 "BEHIND"

setup "$(pr 14 open false false false "$BASE_SHA" t)" "$GREEN" "$APPROVED"; pw 14
expect "not mergeable: conflicts" 1 "conflicts"

setup "$OPEN_OK" "[$(status success build),$(status pending test)]" "$APPROVED"; pw 14
expect "a pending status: still running" 1 "still running"

setup "$OPEN_OK" "[$(status success build),$(status failure test)]" "$APPROVED"; pw 14
expect "a failing status: failing" 1 "check(s) failing"

setup "$OPEN_OK" "[$(status error build)]" "$APPROVED"; pw 14
expect "an error status: failing" 1 "check(s) failing"

setup "$OPEN_OK" "[$(status warning lint)]" "$APPROVED"; pw 14
expect "a warning status fails, as Gitea's own merge gate does" 1 "check(s) failing"

setup "$OPEN_OK" "[$(status success build),$(status skipped deploy)]" "$APPROVED"; pw 14
expect "a skipped status passes, as Gitea's own merge gate does" 0 "READY TO MERGE"

setup "$OPEN_OK" "[$(status success build),$(status queued-someday deploy)]" "$APPROVED"; pw 14
expect "an unknown status state fails closed" 1 "check(s) failing"

setup "$OPEN_OK" '[]' "$APPROVED"; pw 14
expect "no statuses at all is no checks" 0 "READY TO MERGE"

setup "$(pr 14 open false true false "$BASE_SHA" "WIP: thing")" "$GREEN" '[]'; pw 14
expect "WIP draft: still a draft" 1 "still a draft"

setup "$OPEN_OK" "$GREEN" "[$(review 1 9 APPROVED false),$(review 2 8 REQUEST_CHANGES false)]"; pw 14
expect "one reviewer requests changes: changes requested" 1 "changes requested"

setup "$OPEN_OK" "$GREEN" "[$(review 1 8 REQUEST_CHANGES false),$(review 3 8 APPROVED false)]"; pw 14
expect "a reviewer's later approval supersedes their request" 0 "READY TO MERGE"

setup "$OPEN_OK" "$GREEN" "[$(review 1 9 APPROVED false),$(review 2 9 COMMENT false)]"; pw 14
expect "a comment after an approval keeps the approval" 0 "READY TO MERGE"

setup "$OPEN_OK" "$GREEN" "[$(review 1 8 REQUEST_CHANGES true)]"; pw 14
expect "a dismissed request is ignored" 0 "READY FOR REVIEW"

setup "$(pr 14 closed true false false "$BASE_SHA" t)" '[]' '[]'; pw 14
expect "merged: state MERGED" 1 "state is MERGED"
if grep -q '/status?\|/reviews?' "$TMP/log"; then bad "a merged PR fetches no statuses or reviews"
else ok "a merged PR fetches no statuses or reviews"; fi

setup "$(pr 14 closed false false false "$BASE_SHA" t)" '[]' '[]'; pw 14
expect "closed: state CLOSED" 1 "state is CLOSED"

reset; route GET "$A/pulls/14" 404 '{"message":"The target couldn'"'"'t be found."}'; pw 14
expect "API error: could not tell" 2 "couldn't be found"

reset; GT=; pw 14; unset GT
expect "missing GITEA_TOKEN: could not tell, naming it" 2 "GITEA_TOKEN"
reset; GU=; pw 14; unset GU
expect "missing GITEA_URL: could not tell, naming it" 2 "GITEA_URL"

# --- pagination -------------------------------------------------------------
setup "$OPEN_OK" "$GREEN" "$APPROVED"
route GET "$A/commits/$HEAD_SHA/status?page=2&limit=50" 200 "$(combined "[$(status failure late)]")"
route GET "$A/commits/$HEAD_SHA/status?page=3&limit=50" 200 "$(combined null)"
route GET "$A/pulls/14/reviews?page=2&limit=50" 200 '[]'
pw 14
expect "a failing status on page 2 is read" 1 "check(s) failing"

setup "$OPEN_OK" "$GREEN" "$APPROVED"
route GET "$A/pulls/14/reviews?page=2&limit=50" 200 "[$(review 5 8 REQUEST_CHANGES false)]"
route GET "$A/pulls/14/reviews?page=3&limit=50" 200 '[]'
pw 14
expect "a change request on page 2 is read" 1 "changes requested"

# --- the provider's own output ---------------------------------------------
setup "$OPEN_OK" "[$(status success build),$(status warning lint)]" '[]'; prov view 14
if [ "$rc" -eq 0 ] && printf '%s' "$out" | jq -e '
     (keys | sort) == (["isDraft","mergeStateStatus","mergeable","number","reviewDecision","state","statusCheckRollup","title"])' >/dev/null
then ok "view emits every pr-watch field, none absent"
else bad "view emits every pr-watch field, none absent" "rc=$rc $out"; fi
if printf '%s' "$out" | jq -e '(.number | type) == "number" and (.isDraft | type) == "boolean"' >/dev/null
then ok "number is an integer and isDraft a boolean"; else bad "number is an integer and isDraft a boolean" "$out"; fi
if printf '%s' "$out" | jq -e '.statusCheckRollup == [
     {"__typename":"StatusContext","context":"build","state":"SUCCESS"},
     {"__typename":"StatusContext","context":"lint","state":"FAILURE"}]' >/dev/null
then ok "statuses become StatusContext entries with no .status key"
else bad "statuses become StatusContext entries with no .status key" "$out"; fi
if printf '%s' "$out" | jq -e '.mergeStateStatus == "UNSTABLE" and .reviewDecision == "REVIEW_REQUIRED"' >/dev/null
then ok "a non-passing status is UNSTABLE; no review is REVIEW_REQUIRED"
else bad "a non-passing status is UNSTABLE; no review is REVIEW_REQUIRED" "$out"; fi
if grep '^ARGV' "$TMP/log" | grep -q "$TOKEN"
then bad "the token is never on a command line"; else ok "the token is never on a command line"; fi

setup "$(pr 14 open false true false "$BASE_SHA" "WIP: x")" '[]' '[]'; prov view 14
if printf '%s' "$out" | jq -e '.isDraft == true and .mergeable == "UNKNOWN" and .mergeStateStatus == "DRAFT"' >/dev/null
then ok "a WIP draft is not reported as conflicting"
else bad "a WIP draft is not reported as conflicting" "$out"; fi

setup "$(pr 14 open false false false "$OLD_SHA" t)" "$GREEN" '[]'; prov view 14
if printf '%s' "$out" | jq -e '.mergeable == "CONFLICTING" and .mergeStateStatus == "DIRTY"' >/dev/null
then ok "not mergeable is CONFLICTING and DIRTY, ahead of BEHIND"
else bad "not mergeable is CONFLICTING and DIRTY, ahead of BEHIND" "$out"; fi

prov view abc
expect "a non-numeric id is exit 2" 2 "digits"
GR=just-a-name; prov view 14; unset GR
expect "PR_WATCH_REPO without an owner is exit 2" 2 "owner/name"

# --- no id: the open PR for the current branch ----------------------------
git -C "$TMP/work" init -q 2>/dev/null
git -C "$TMP/work" checkout -q -b feat 2>/dev/null
for remote in "https://gitea.com/o/r.git" "git@gitea.com:o/r.git" "ssh://git@gitea.com:2222/o/r.git" "https://gitea.com/sub/o/r/"; do
  git -C "$TMP/work" remote remove origin 2>/dev/null
  git -C "$TMP/work" remote add origin "$remote"
  setup "$OPEN_OK" "$GREEN" '[]'
  route GET "$A/pulls?state=open&page=1&limit=50" 200 \
    "[{\"number\":12,\"head\":{\"ref\":\"other\"},\"user\":{\"login\":\"me\"}},{\"number\":14,\"head\":{\"ref\":\"feat\"},\"user\":{\"login\":\"me\"}}]"
  route GET "$A/pulls?state=open&page=2&limit=50" 200 '[]'
  GR=; prov view; unset GR
  if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r .number)" = 14 ]
  then ok "no id: branch feat resolves to PR 14 via remote $remote"
  else bad "no id: branch feat resolves to PR 14 via remote $remote" "rc=$rc $out"; fi
done

setup "$OPEN_OK" "$GREEN" '[]'
route GET "$A/pulls?state=open&page=1&limit=50" 200 '[{"number":12,"head":{"ref":"other"},"user":{"login":"me"}}]'
route GET "$A/pulls?state=open&page=2&limit=50" 200 '[]'
prov view
expect "no id and no PR for the branch is exit 2" 2 "no open pull request for branch feat"

# --- list, mark, unknown verbs ---------------------------------------------
reset
route GET "$URL/api/v1/user" 200 '{"id":7,"login":"me"}'
route GET "$A/pulls?state=open&page=1&limit=50" 200 \
  '[{"number":14,"user":{"login":"me"}},{"number":15,"user":{"login":"someone"}}]'
route GET "$A/pulls?state=open&page=2&limit=50" 200 '[{"number":16,"user":{"login":"me"}}]'
route GET "$A/pulls?state=open&page=3&limit=50" 200 '[]'
prov list
if [ "$rc" -eq 0 ] && [ "$out" = "$(printf '14\n16')" ]
then ok "list: the token user's open PRs, every page"; else bad "list: the token user's open PRs, every page" "rc=$rc [$out]"; fi

reset; route GET "$URL/api/v1/user" 401 '{"message":"token is required"}'
prov list
expect "list with a rejected token is exit 2" 2 "token is required"

prov mark
[ "$rc:$out" = "0:#" ] && ok "mark is #" || bad "mark is #" "rc=$rc [$out]"
prov wait 14
[ "$rc" -ne 0 ] && ok "wait is not implemented, so it exits non-zero" || bad "wait is not implemented, so it exits non-zero"
prov __pr_watch_probe__
[ "$rc" -ne 0 ] && ok "an unknown verb exits non-zero" || bad "an unknown verb exits non-zero"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
