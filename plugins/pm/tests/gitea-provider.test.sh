#!/bin/sh
# The gitea provider, against a fake curl.
#
#   sh plugins/pm/tests/gitea-provider.test.sh
#
# The fake serves fixtures by method and URL from a routes file and logs every
# request -- method, URL, body, argv and the auth header -- so the tests assert
# what went on the wire.
#
# The *-gitea-schema.json fixtures are written to Gitea's published API schema
# (swagger, https://docs.gitea.com/api), NOT captured off the wire: no instance
# was available. tests/live.test.sh with PM_PROVIDER=gitea is the check that
# remains, pending a scratch instance.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB=$HERE/../lib
BIN=$HERE/../bin
FIX=$HERE/fixtures
TMP=${TMPDIR:-/tmp}/gitea-provider.$$
mkdir -p "$TMP/bin" "$TMP/run"
trap 'rm -rf "$TMP"' EXIT INT TERM
command -v jq >/dev/null 2>&1 || { echo "gitea-provider.test: jq required" >&2; exit 1; }

fails=0 ran=0
unset TEST_GITEA_URL
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
log=${FAKE_CURL_LOG:-/dev/null}
printf 'ARGV %s\n' "$*" >> "$log"
m=GET url= out= data= cfg=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift 2 ;;
    -K) cfg=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    -w|-H) shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf 'REQ %s %s\n' "$m" "$url" >> "$log"
[ -n "$cfg" ] && printf 'AUTH %s\n' "$(cat "$cfg")" >> "$log"
[ -n "$cfg" ] && printf 'MODE %s\n' "$(ls -l "$cfg" | cut -c1-10)" >> "$log"
case "$data" in @*) printf 'BODY %s\n' "$(jq -c . "${data#@}" 2>/dev/null || cat "${data#@}")" >> "$log" ;; esac
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  echo "curl: (7) Failed to connect to gitea.com port 443 after 3 ms: Connection refused" >&2; exit 7
fi
while read -r rm rpat rcode rfile; do
  [ -n "$rm" ] || continue
  # shellcheck disable=SC2254
  case "$m $url" in
    "$rm "$rpat)
      if [ "$rfile" = - ]; then : > "$out"; else cat "$rfile" > "$out"; fi
      printf '%s' "$rcode"; exit 0 ;;
  esac
done < "$FAKE_ROUTES"
printf '{"message":"fake curl: no route for %s %s"}' "$m" "$url" > "$out"
printf '404'
EOF
chmod +x "$TMP/bin/curl"

echo '[]' > "$TMP/empty.json"
jq '.state = "closed"' "$FIX/issue-gitea-schema.json" > "$TMP/issue-closed.json"

# The routes most cases use. First match wins.
base_routes() {
  cat <<EOF
GET */api/v1/repos/owner/repo 200 $FIX/repo-gitea-schema.json
GET */repos/owner/repo/labels[?]*page=1 200 $FIX/labels-gitea-schema.json
GET */repos/owner/repo/labels[?]* 200 $TMP/empty.json
GET */repos/owner/repo/issues[?]*page=1 200 $FIX/issues-gitea-schema.json
GET */repos/owner/repo/issues[?]* 200 $TMP/empty.json
GET */issues/3/dependencies[?]*page=1 200 $FIX/deps-gitea-schema.json
GET */issues/*/dependencies[?]* 200 $TMP/empty.json
GET */issues/5/comments 200 $FIX/comments-gitea-schema.json
GET */issues/*/comments 200 $TMP/empty.json
GET */issues/*/labels 200 $FIX/labels-gitea-schema.json
GET */issues/3 200 $FIX/issue-gitea-schema.json
POST */repos/owner/repo/issues 201 $FIX/issue-gitea-schema.json
POST */issues/*/labels 200 $FIX/labels-gitea-schema.json
DELETE */issues/*/labels/* 204 -
POST */issues/*/comments 201 -
PATCH */issues/* 201 $TMP/issue-closed.json
POST */repos/owner/repo/labels 201 -
POST */repos/owner/repo/pulls 201 $FIX/pull-gitea-schema.json
GET */repos/owner/repo/pulls[?]*page=1 200 $FIX/pulls-gitea-schema.json
GET */repos/owner/repo/pulls[?]* 200 $TMP/empty.json
POST */issues/*/dependencies 201 $FIX/issue-gitea-schema.json
DELETE */issues/*/dependencies 201 $FIX/issue-gitea-schema.json
EOF
}
base_routes > "$TMP/routes"

# routes_with <line>... -> a routes file with these lines ahead of the base set.
routes_with() {
  _f=$TMP/routes.$ran.$$
  { for l in "$@"; do printf '%s\n' "$l"; done; base_routes; } > "$_f"
  printf '%s' "$_f"
}

# run <fn> <args...> -- the provider sourced fresh, the fake curl first on PATH.
run() {
  ( PATH="$TMP/bin:$PATH"; GITEA_URL=${TEST_GITEA_URL:-https://gitea.com} GITEA_TOKEN=s3cr3t-token
    FAKE_ROUTES=${FAKE_ROUTES:-$TMP/routes}
    export GITEA_URL GITEA_TOKEN FAKE_ROUTES FAKE_CURL_LOG FAKE_CURL_FAIL PM_ASSUME_DEPS PM_LIMIT
    . "$LIB/provider-gitea.sh"; "$@" )
}
# wire <fn> <args...> -- the request log of one call.
wire() {
  FAKE_CURL_LOG=$TMP/wire.$$; : > "$FAKE_CURL_LOG"
  run "$@" >/dev/null 2>&1 </dev/null
  cat "$FAKE_CURL_LOG"; FAKE_CURL_LOG=/dev/null
}
# rcerr <fn> <args...> -- "rc=<code> <PROVIDER_ERR>" after the call.
rcerr() { run _rcerr "$@"; }
_rcerr() { "$@" >/dev/null 2>&1; echo "rc=$? $PROVIDER_ERR"; }
# lines <prefix> <log> -- the log lines of one kind.
lines() { printf '%s\n' "$2" | grep "^$1" || :; }
# --- the trivial two ---------------------------------------------------------
[ "$(run provider_name)" = "gitea" ] && ok "provider_name is gitea" || bad "provider_name"
[ "$(run provider_pr_ref_mark)" = "#" ] && ok "a PR is #n: issues and PRs share one number space" || bad "pr_ref_mark"

# --- configuration: two variables, and a missing one is never a pass ---------
if run provider_available 2>/dev/null; then ok "available with GITEA_URL and GITEA_TOKEN set"
else bad "available with both set"; fi

for v in GITEA_URL GITEA_TOKEN; do
  e=$( PATH="$TMP/bin:$PATH"; GITEA_URL=https://gitea.com GITEA_TOKEN=t; export GITEA_URL GITEA_TOKEN
       unset "$v"; . "$LIB/provider-gitea.sh"; provider_available 2>&1; echo "rc=$?" )
  case "$e" in *"$v is not set"*"rc=1") ok "unavailable without $v, and says so" ;;
    *) bad "unavailable without $v" "$e" ;; esac
  pe=$( PATH="$TMP/bin:$PATH"; GITEA_URL=https://gitea.com GITEA_TOKEN=t; export GITEA_URL GITEA_TOKEN
        unset "$v"; . "$LIB/provider-gitea.sh"; provider_available 2>/dev/null; printf '%s' "$PROVIDER_ERR" )
  case "$pe" in *"$v"*) ok "PROVIDER_ERR names $v" ;; *) bad "PROVIDER_ERR names $v" "$pe" ;; esac
done

# Through the binaries: exit 2, could not tell -- and the variable is named.
for b in backlog-queue check-replies; do
  o=$( PATH="$TMP/bin:$PATH"; PM_PROVIDER=gitea GITEA_URL=https://gitea.com; export PM_PROVIDER GITEA_URL
       unset GITEA_TOKEN; sh "$BIN/$b" --repo owner/repo 2>&1 </dev/null; echo "rc=$?" )
  case "$o" in *"GITEA_TOKEN is not set"*"rc=2") ok "$b exits 2 naming GITEA_TOKEN" ;;
    *) bad "$b without GITEA_TOKEN" "$o" ;; esac
done

# --- the token stays off argv ------------------------------------------------
w=$(wire provider_issue 3 owner/repo)
case "$(lines ARGV "$w")" in *s3cr3t*) bad "the token is not on curl's command line" "$(lines ARGV "$w")" ;;
  *) ok "the token is not on curl's command line" ;; esac
case "$w" in *'AUTH header = "Authorization: token s3cr3t-token"'*) ok "it goes in the -K config as a token header" ;;
  *) bad "auth header in the config" "$w" ;; esac
case "$w" in *"MODE -rw-------"*) ok "and that config file is mode 600" ;; *) bad "config mode" "$(lines MODE "$w")" ;; esac

# A trailing slash on GITEA_URL must not double up.
w=$(TEST_GITEA_URL=https://gitea.com/ wire provider_issue 3 owner/repo | grep "^REQ")
[ "$w" = "REQ GET https://gitea.com/api/v1/repos/owner/repo/issues/3" ] \
  && ok "a trailing slash on GITEA_URL is tolerated" || bad "trailing slash" "$w"

# --- the backend's own words -------------------------------------------------
R=$(routes_with "POST */repos/owner/repo/issues 422 $FIX/error-422-gitea-schema.json")
e=$(echo body | FAKE_ROUTES=$R rcerr provider_create_issue owner/repo T)
case "$e" in "rc=1 "*"HTTP 422"*"[Title]: Required"*) ok "a 4xx fails with Gitea's own message and the code" ;;
  *) bad "4xx diagnostic" "$e" ;; esac
e=$(FAKE_CURL_FAIL=1 rcerr provider_issues owner/repo)
case "$e" in "rc=1 curl: "*"Connection refused"*) ok "an unreachable host fails with curl's words" ;;
  *) bad "curl failure diagnostic" "$e" ;; esac

# --- the repository, from the argument or the origin remote ------------------
repo_from() {
  rm -rf "$TMP/g"; git init -q "$TMP/g" && git -C "$TMP/g" remote add origin "$1"
  ( cd "$TMP/g" && . "$LIB/provider-gitea.sh" && _gitea_repo && printf '%s' "$PM_GITEA_REPO" )
}
for u in https://gitea.com/owner/repo.git git@gitea.com:owner/repo.git \
         ssh://git@gitea.com:2222/owner/repo.git https://gitea.com/sub/path/owner/repo; do
  [ "$(repo_from "$u")" = owner/repo ] && ok "owner/repo from $u" || bad "repo from $u" "$(repo_from "$u")"
done
if ( cd "$TMP" && . "$LIB/provider-gitea.sh" && _gitea_repo ) >/dev/null 2>&1
then bad "no remote and no repo is refused"; else ok "no remote and no repo is refused"; fi
e=$( . "$LIB/provider-gitea.sh"; _gitea_repo just-a-name; printf '%s' "$PROVIDER_ERR" )
case "$e" in *"owner/name"*) ok "a repo without an owner is refused with a reason" ;; *) bad "bad repo" "$e" ;; esac

# --- provider_issues ---------------------------------------------------------
out=$(run provider_issues owner/repo)
[ $? -eq 0 ] && ok "provider_issues exits 0" || bad "provider_issues exit" "$out"
[ "$(printf '%s' "$out" | jq -r '[.[].number] | join(",")')" = "5,3" ] \
  && ok "the pull request in the listing is dropped" || bad "PR rows dropped" "$(printf '%s' "$out" | jq -c '[.[].number]')"
k=$(printf '%s' "$out" | jq -r '.[0] | keys | sort | join(",")')
[ "$k" = "blockedBy,comments,createdAt,labels,number,state,title,updatedAt" ] \
  && ok "exactly the contract keys" || bad "contract keys" "$k"
[ "$(printf '%s' "$out" | jq -r '.[1].state')" = OPEN ] && ok "open becomes OPEN" || bad "state"
[ "$(printf '%s' "$out" | jq -c '.[1].labels')" = '["task","priority-high"]' ] \
  && ok "labels are their names" || bad "labels" "$(printf '%s' "$out" | jq -c '.[1].labels')"
# +02:00 is what Gitea sends from a server in that zone; the queue parses Z only.
[ "$(printf '%s' "$out" | jq -r '.[1].createdAt')" = "2026-10-14T06:00:00Z" ] \
  && ok "a +02:00 stamp becomes the same instant in Z" || bad "utc" "$(printf '%s' "$out" | jq -r '.[1].createdAt')"
[ "$(printf '%s' "$out" | jq -c '.[1].blockedBy')" = "[2]" ] \
  && ok "blockedBy is read per issue, same-repo blockers only" || bad "blockedBy" "$(printf '%s' "$out" | jq -c '.[1].blockedBy')"
[ "$(printf '%s' "$out" | jq -r '.[0].comments | last | .author.login')" = maintainer ] \
  && ok "a needs-human issue carries its comments, oldest first" || bad "needs-human comments" "$(printf '%s' "$out" | jq -c '.[0].comments')"
[ "$(printf '%s' "$out" | jq -c '.[1].comments')" = "[]" ] && ok "other issues carry an empty comment list" || bad "comments []"

w=$(wire provider_issues owner/repo)
case "$w" in *"issues?state=open&type=issues&limit=50&page=1"*) ok "asks for open issues, not pulls, 50 a page" ;;
  *) bad "issue list query" "$(lines REQ "$w")" ;; esac
case "$w" in *"/issues/3/comments"*) bad "comments read only for needs-human issues" ;; *) ok "comments read only for needs-human issues" ;; esac

R=$(routes_with "GET */api/v1/repos/owner/repo 200 $FIX/repo-nodeps-gitea-schema.json")
out=$(FAKE_ROUTES=$R run provider_issues owner/repo)
[ "$(printf '%s' "$out" | jq -c '[.[].blockedBy[]]')" = "[]" ] \
  && ok "dependencies off for the repo: blockedBy is empty" || bad "deps off" "$out"
w=$(FAKE_ROUTES=$R wire provider_issues owner/repo)
case "$w" in *dependencies*) bad "and no dependency read is made" ;; *) ok "and no dependency read is made" ;; esac

# A failed blocker read is "could not tell", never an empty graph.
R=$(routes_with "GET */issues/3/dependencies[?]* 500 $FIX/error-422-gitea-schema.json")
if FAKE_ROUTES=$R run provider_issues owner/repo >/dev/null 2>&1
then bad "a failed dependency read fails the listing"; else ok "a failed dependency read fails the listing"; fi

# Paging. The server's page cap may be below 50, so a short page is not the end.
jq '[range(0;20) as $i | .[2] | .number = (100 + $i)]' "$FIX/issues-gitea-schema.json" > "$TMP/p20.json"
jq '[range(0;5) as $i | .[2] | .number = (200 + $i)]' "$FIX/issues-gitea-schema.json" > "$TMP/p5.json"
R=$(routes_with "GET */repos/owner/repo/issues[?]*page=1 200 $TMP/p20.json" \
                "GET */repos/owner/repo/issues[?]*page=2 200 $TMP/p5.json")
n=$(PM_ASSUME_DEPS=1 FAKE_ROUTES=$R run provider_issues owner/repo | jq length)
[ "$n" = 25 ] && ok "pages until an empty page, not a short one" || bad "paging" "got $n"
n=$(PM_ASSUME_DEPS=1 PM_LIMIT=7 FAKE_ROUTES=$R run provider_issues owner/repo | jq length)
[ "$n" = 7 ] && ok "PM_LIMIT caps the rows" || bad "PM_LIMIT cap" "got $n"
w=$(PM_ASSUME_DEPS=1 PM_LIMIT=7 FAKE_ROUTES=$R wire provider_issues owner/repo)
case "$w" in *page=2*) bad "and stops paging at the cap" ;; *) ok "and stops paging at the cap" ;; esac
if PM_LIMIT=abc run provider_issues owner/repo >/dev/null 2>&1
then bad "a non-numeric PM_LIMIT is refused"; else ok "a non-numeric PM_LIMIT is refused"; fi

# --- provider_issue ----------------------------------------------------------
one=$(run provider_issue 3 owner/repo)
[ "$(printf '%s' "$one" | jq -r '.number, .state, .labels[0]' | tr '\n' ' ')" = "3 OPEN task " ] \
  && ok "one issue, normalised" || bad "provider_issue" "$one"
case "$(printf '%s' "$one" | jq -r .body)" in "## Problem"*) ok "body comes through" ;; *) bad "body" ;; esac
e=$(rcerr provider_issue 404 owner/repo)
case "$e" in "rc=1 HTTP 404"*) ok "a missing issue fails with the 404" ;; *) bad "missing issue" "$e" ;; esac

# --- provider_needs_human ----------------------------------------------------
nh=$(run provider_needs_human owner/repo)
[ $? -eq 0 ] && ok "needs-human exits 0" || bad "needs-human exit" "$nh"
[ "$(printf '%s' "$nh" | jq -r '[.[].number] | join(",")')" = 5 ] \
  && ok "only issues that carry needs-human, even if the server ignored the filter" \
  || bad "client-side needs-human filter" "$(printf '%s' "$nh" | jq -c '[.[].number]')"
[ "$(printf '%s' "$nh" | jq -r '.[0] | keys | sort | join(",")')" = "comments,number,title" ] \
  && ok "the contract keys" || bad "needs-human keys"
[ "$(printf '%s' "$nh" | jq -r '.[0].comments[0] | keys | sort | join(",")')" = "author,body,createdAt,id" ] \
  && ok "the comment keys" || bad "comment keys"
# The fixture lists the human reply first; oldest-first puts the agent first.
case "$(printf '%s' "$nh" | jq -r '.[0].comments[0].body')" in "🤖"*) ok "comments oldest first" ;; *) bad "comment order" ;; esac
[ "$(printf '%s' "$nh" | jq -r '.[0].comments | last | .author.login')" = maintainer ] \
  && ok "user.login becomes author.login" || bad "author.login"
w=$(wire provider_needs_human owner/repo)
case "$w" in *"state=open&type=issues&labels=needs-human"*) ok "asks for open needs-human issues" ;; *) bad "needs-human query" ;; esac

# Two zones: order by the instant, not the string.
jq '[(.[1] | .created_at = "2026-10-17T10:00:00+02:00"), (.[0] | .created_at = "2026-10-17T09:00:00Z")]' \
  "$FIX/comments-gitea-schema.json" > "$TMP/zones.json"
R=$(routes_with "GET */issues/5/comments 200 $TMP/zones.json")
last=$(FAKE_ROUTES=$R run provider_needs_human owner/repo | jq -r '.[0].comments | last | .author.login')
[ "$last" = maintainer ] && ok "comments sort by instant across zones" || bad "zone sort" "last: $last"

R=$(routes_with "GET */issues/5/comments 500 $FIX/error-422-gitea-schema.json")
o=$(FAKE_ROUTES=$R run provider_needs_human owner/repo 2>/dev/null; echo "rc=$?")
[ "$o" = "rc=2" ] && ok "a failed comment read is 2, with nothing printed" || bad "needs-human comment failure" "$o"
o=$(FAKE_CURL_FAIL=1 run provider_needs_human owner/repo 2>/dev/null; echo "rc=$?")
[ "$o" = "rc=2" ] && ok "an unreachable backend is 2 for needs-human" || bad "needs-human unreachable" "$o"
urc=$( PATH="$TMP/bin:$PATH" GITEA_URL=https://gitea.com GITEA_TOKEN=t FAKE_ROUTES=$TMP/routes \
       sh -c 'set -u; . "$1"; provider_needs_human owner/repo >/dev/null 2>&1; echo "rc=$?"' _ "$LIB/provider-gitea.sh" 2>/dev/null )
[ "$urc" = "rc=0" ] && ok "needs-human runs under set -u" || bad "set -u" "$urc"

# --- writes: what goes on the wire ------------------------------------------
w=$(printf 'the body\n' | ( FAKE_CURL_LOG=$TMP/c.log; : > "$FAKE_CURL_LOG"; export FAKE_CURL_LOG
      run provider_create_issue owner/repo "A title" task priority-high >/dev/null 2>&1; cat "$FAKE_CURL_LOG" ))
b=$(printf '%s\n' "$w" | grep -A99 'REQ POST .*/repos/owner/repo/issues$' | grep '^BODY' | head -1 | sed 's/^BODY //')
[ "$(printf '%s' "$b" | jq -c '.labels')" = "[11,14]" ] && ok "create sends label ids" || bad "create label ids" "$b"
[ "$(printf '%s' "$b" | jq -c '[.labels[] | type] | unique')" = '["number"]' ] \
  && ok "as JSON numbers, not strings" || bad "label id types" "$b"
printf '%s' "$b" | jq -e '.title == "A title" and .body == "the body\n"' >/dev/null \
  && ok "title, and the body from stdin" || bad "create title/body" "$b"
url=$(printf 'x' | run provider_create_issue owner/repo "A title" task)
[ "$url" = "https://gitea.com/owner/repo/issues/3" ] && ok "create prints the html_url" || bad "create url" "$url"

w=$(printf 'x' | ( FAKE_CURL_LOG=$TMP/c2.log; : > "$FAKE_CURL_LOG"; export FAKE_CURL_LOG
      run provider_create_issue owner/repo "T" nope >/dev/null 2>&1; cat "$FAKE_CURL_LOG" ))
case "$w" in *"REQ POST"*) bad "an unknown label stops the create before it is sent" ;;
  *) ok "an unknown label stops the create before it is sent" ;; esac
e=$(echo x | rcerr provider_create_issue owner/repo T nope)
case "$e" in *"no such label"*nope*) ok "and names it" ;; *) bad "unknown label message" "$e" ;; esac

w=$(wire provider_label 5 claimed add owner/repo)
case "$w" in *"REQ POST https://gitea.com/api/v1/repos/owner/repo/issues/5/labels"*'BODY {"labels":[13]}'*)
  ok "label add posts the id as a number" ;; *) bad "label add wire" "$w" ;; esac
R=$(routes_with "POST */issues/*/labels 200 $TMP/empty.json")
if FAKE_ROUTES=$R run provider_label 5 claimed add owner/repo >/dev/null 2>&1
then bad "a label missing from the response fails the add"; else ok "a label missing from the response fails the add"; fi
w=$(wire provider_label 5 claimed remove owner/repo)
case "$w" in *"REQ DELETE https://gitea.com/api/v1/repos/owner/repo/issues/5/labels/13"*) ok "label remove deletes by id" ;;
  *) bad "label remove wire" "$w" ;; esac
run provider_label 5 claimed reorder owner/repo >/dev/null 2>&1
[ $? -eq 2 ] && ok "a bad label op is 2" || bad "bad label op"

w=$(wire provider_ensure_label claimed owner/repo)
case "$w" in *"REQ POST"*) bad "ensure-label leaves an existing label alone" "$w" ;; *) ok "ensure-label leaves an existing label alone" ;; esac
w=$(wire provider_ensure_label size-s owner/repo)
case "$w" in *"REQ POST https://gitea.com/api/v1/repos/owner/repo/labels"*'BODY {"name":"size-s","color":"#ededed"}'*)
  ok "and creates a missing one" ;; *) bad "ensure-label create" "$w" ;; esac
( FAKE_CURL_FAIL=1; export FAKE_CURL_FAIL; run provider_ensure_label x owner/repo ) >/dev/null 2>&1
[ $? -eq 0 ] && ok "ensure-label is 0 even when the backend is down" || bad "ensure-label rc"

# Org-level labels: the base routes have no org route, so the fake answers 404 as for a user-owned repo.
printf '[{"id":21,"name":"size-s","color":"ededed"}]' > "$TMP/org-labels.json"
ORG=$(routes_with "GET */orgs/owner/labels[?]*page=1 200 $TMP/org-labels.json" "GET */orgs/owner/labels[?]* 200 $TMP/empty.json")
w=$(FAKE_ROUTES=$ORG wire provider_ensure_label size-s owner/repo)
case "$w" in *"REQ POST"*) bad "ensure-label finds an org-level label instead of duplicating it" "$w" ;;
  *"REQ GET https://gitea.com/api/v1/orgs/owner/labels"*) ok "ensure-label finds an org-level label instead of duplicating it" ;;
  *) bad "ensure-label finds an org-level label instead of duplicating it" "$w" ;; esac
w=$(FAKE_ROUTES=$ORG wire provider_label 5 size-s add owner/repo)
case "$w" in *'BODY {"labels":[21]}'*) ok "an org label id is sent as a number" ;; *) bad "org label add wire" "$w" ;; esac
e=$(echo x | rcerr provider_create_issue owner/repo T task nope)
case "$e" in "rc=1 no such label in owner/repo: nope") ok "a 404 for org labels is not an error" ;; *) bad "org labels 404" "$e" ;; esac
R=$(routes_with "GET */orgs/owner/labels[?]* 500 $FIX/error-422-gitea-schema.json")
e=$(echo x | FAKE_ROUTES=$R rcerr provider_create_issue owner/repo T nope)
case "$e" in "rc=1 HTTP 500 "*) ok "an org-labels failure other than 404 is an error" ;; *) bad "org labels 500" "$e" ;; esac

w=$(wire provider_comment 5 "done, pushed" owner/repo)
case "$w" in *"REQ POST https://gitea.com/api/v1/repos/owner/repo/issues/5/comments"*'BODY {"body":"done, pushed"}'*)
  ok "comment posts the body" ;; *) bad "comment wire" "$w" ;; esac

w=$(wire provider_close_issue 5 not_planned owner/repo)
case "$w" in *"REQ PATCH https://gitea.com/api/v1/repos/owner/repo/issues/5"*'BODY {"state":"closed"}'*) ok "close patches state" ;;
  *) bad "close wire" "$w" ;; esac
ap=$( PATH="$TMP/bin:$PATH"; GITEA_URL=https://gitea.com GITEA_TOKEN=t FAKE_ROUTES=$TMP/routes; export GITEA_URL GITEA_TOKEN FAKE_ROUTES
      . "$LIB/provider-gitea.sh"; provider_close_issue 5 not_planned owner/repo >/dev/null 2>&1; echo "$?:$PROVIDER_CLOSE_REASON_APPLIED" )
[ "$ap" = "0:0" ] && ok "closed, and the reason reported as not applied" || bad "close reason" "$ap"
R=$(routes_with "PATCH */issues/* 201 $FIX/issue-gitea-schema.json")
if FAKE_ROUTES=$R run provider_close_issue 5 "" owner/repo >/dev/null 2>&1
then bad "an issue still open after the close fails"; else ok "an issue still open after the close fails"; fi

[ "$(run provider_issue_labels 5 owner/repo | tr '\n' ' ')" = "task needs-human claimed priority-high question " ] \
  && ok "issue labels, one per line" || bad "issue labels"

w=$(wire provider_open_draft_pr claude/retry "Retry backs off" "the body" main owner/repo)
b=$(printf '%s\n' "$w" | grep '^BODY' | sed 's/^BODY //')
[ "$(printf '%s' "$b" | jq -r '.title')" = "WIP: Retry backs off" ] && ok "a draft PR is titled WIP:" || bad "WIP title" "$b"
[ "$(printf '%s' "$b" | jq -r '.head + " " + .base + " " + .body')" = "claude/retry main the body" ] \
  && ok "with head, base and body" || bad "draft PR body" "$b"
w=$(wire provider_open_draft_pr claude/retry "WIP: Already" "b" main owner/repo)
[ "$(printf '%s\n' "$w" | grep '^BODY' | sed 's/^BODY //' | jq -r .title)" = "WIP: Already" ] \
  && ok "an existing WIP: prefix is not doubled" || bad "WIP doubled"
url=$(run provider_open_draft_pr claude/retry "T" "b" main owner/repo)
[ "$url" = "https://gitea.com/owner/repo/pulls/9" ] && ok "draft PR prints the html_url" || bad "draft PR url" "$url"

[ "$(run provider_find_pr claude/retry owner/repo)" = 9 ] && ok "find-pr takes this repo's branch, not a fork's" \
  || bad "find-pr" "$(run provider_find_pr claude/retry owner/repo)"
o=$(run provider_find_pr no/such owner/repo; echo "rc=$?")
[ "$o" = "rc=0" ] && ok "no PR is empty output and 0" || bad "find-pr none" "$o"
if ( FAKE_CURL_FAIL=1; export FAKE_CURL_FAIL; run provider_find_pr claude/retry owner/repo ) >/dev/null 2>&1
then bad "find-pr fails when it could not ask"; else ok "find-pr fails when it could not ask"; fi

# --- what a claim's PR is doing ----------------------------------------------
act=$(run provider_pr_activity claude/retry owner/repo)
[ "$act" = "$(printf 'true\t2026-10-17T16:44:16Z')" ] \
  && ok "pr-activity: this repo's PR, not a fork's, draft and updatedAt in UTC" || bad "pr-activity" "[$act]"
jq 'map(.draft = false)' "$FIX/pulls-gitea-schema.json" > "$TMP/pulls-ready.json"
R=$(routes_with "GET */repos/owner/repo/pulls[?]*page=1 200 $TMP/pulls-ready.json")
act=$(FAKE_ROUTES=$R run provider_pr_activity claude/retry owner/repo)
case "$act" in false*) ok "pr-activity: a ready PR is not a draft" ;; *) bad "pr-activity ready" "[$act]" ;; esac
o=$(run provider_pr_activity no/such owner/repo; echo "rc=$?")
[ "$o" = "rc=0" ] && ok "pr-activity: no PR is empty output and 0" || bad "pr-activity none" "$o"
e=$(FAKE_CURL_FAIL=1 rcerr provider_pr_activity claude/retry owner/repo)
case "$e" in "rc=1 curl: "*"Connection refused"*) ok "pr-activity: a dead backend is a failure, with curl's words" ;;
  *) bad "pr-activity dead backend" "$e" ;; esac
R=$(routes_with "GET */repos/owner/repo/pulls[?]* 500 $FIX/error-422-gitea-schema.json")
e=$(FAKE_ROUTES=$R rcerr provider_pr_activity claude/retry owner/repo)
case "$e" in "rc=1 HTTP 500 "*) ok "pr-activity: an HTTP error is a failure, not 'no PR'" ;;
  *) bad "pr-activity HTTP error" "$e" ;; esac

# --- the dependency graph ----------------------------------------------------
[ "$(run provider_issue_id 3 owner/repo)" = 3 ] && ok "issue_id is the number the body takes" || bad "issue_id"
if run provider_issue_id 404 owner/repo >/dev/null 2>&1; then bad "issue_id fails for a missing issue"
else ok "issue_id fails for a missing issue"; fi
[ "$(run provider_blocked_by 3 owner/repo)" = 2 ] && ok "blocked_by lists the blockers, same repo only" \
  || bad "blocked_by" "$(run provider_blocked_by 3 owner/repo | tr '\n' ' ')"
w=$(wire provider_blocked_by 3 owner/repo)
case "$w" in *"REQ GET https://gitea.com/api/v1/repos/owner/repo/issues/3/dependencies?"*) ok "from /dependencies, the issues that block it" ;;
  *) bad "blocked_by endpoint" "$w" ;; esac

w=$(wire provider_link 3 2 owner/repo)
case "$w" in *"REQ POST https://gitea.com/api/v1/repos/owner/repo/issues/3/dependencies"*'BODY {"index":2,"owner":"owner","repo":"repo"}'*)
  ok "link posts the blocker as an integer index with its owner and repo" ;; *) bad "link wire" "$w" ;; esac
run provider_link 3 2 owner/repo >/dev/null 2>&1 && ok "link succeeds when the edge reads back" || bad "link read-back"
e=$(rcerr provider_link 3 4 owner/repo)
case "$e" in "rc=1 "*"not blocked by #4"*) ok "link fails when the edge does not read back" ;; *) bad "link no read-back" "$e" ;; esac

w=$(wire provider_unlink 3 2 owner/repo)
case "$w" in *"REQ DELETE https://gitea.com/api/v1/repos/owner/repo/issues/3/dependencies"*'BODY {"index":2,"owner":"owner","repo":"repo"}'*)
  ok "unlink deletes with the same body" ;; *) bad "unlink wire" "$w" ;; esac
if run provider_unlink 3 2 owner/repo >/dev/null 2>&1; then bad "unlink fails while the edge still reads back"
else ok "unlink fails while the edge still reads back"; fi
R=$(routes_with "GET */issues/3/dependencies[?]* 200 $TMP/empty.json")
FAKE_ROUTES=$R run provider_unlink 3 2 owner/repo >/dev/null 2>&1 && ok "unlink succeeds once the edge is gone" || bad "unlink"
w=$(wire provider_unlink 3 x owner/repo)
case "$w" in *REQ*) bad "a non-numeric blocker is refused before any request" "$w" ;;
  *) ok "a non-numeric blocker is refused before any request" ;; esac

run provider_supports_deps owner/repo && ok "supports_deps reads the repo setting: on" || bad "supports_deps on"
R=$(routes_with "GET */api/v1/repos/owner/repo 200 $FIX/repo-nodeps-gitea-schema.json")
if FAKE_ROUTES=$R run provider_supports_deps owner/repo; then bad "supports_deps off"; else ok "supports_deps reads the repo setting: off"; fi
if ( FAKE_CURL_FAIL=1; export FAKE_CURL_FAIL; run provider_supports_deps owner/repo ); then bad "supports_deps with a dead backend"
else ok "supports_deps degrades when the backend is dead"; fi
w=$(PM_ASSUME_DEPS=1 wire provider_supports_deps owner/repo)
[ -z "$w" ] && ok "PM_ASSUME_DEPS answers without a request" || bad "PM_ASSUME_DEPS" "$w"

# --- triage, same rule as github --------------------------------------------
t=$(run provider_is_triaged '{"labels":[{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-s"}]}'; echo $?)
[ "$t" = 0 ] && ok "is_triaged: all three axes" || bad "is_triaged 0"
t=$(run provider_is_triaged '{"labels":["priority-low"]}'; echo $?)
[ "$t" = 1 ] && ok "is_triaged: one axis" || bad "is_triaged 1"

# --- nothing left behind -----------------------------------------------------
LEAKD=$(mktemp -d)
( PATH="$TMP/bin:$PATH"; TMPDIR=$LEAKD GITEA_URL=https://gitea.com GITEA_TOKEN=t FAKE_ROUTES=$TMP/routes
  export TMPDIR GITEA_URL GITEA_TOKEN FAKE_ROUTES
  . "$LIB/provider-gitea.sh"
  provider_issues owner/repo; provider_needs_human owner/repo; provider_issue 404 owner/repo
  echo x | provider_create_issue owner/repo T task; echo x | provider_create_issue owner/repo T nope
  provider_label 5 claimed add owner/repo; provider_link 3 4 owner/repo; provider_unlink 3 x owner/repo
  provider_find_pr claude/retry owner/repo; provider_pr_activity claude/retry owner/repo
  provider_close_issue 5 "" owner/repo
  FAKE_CURL_FAIL=1 provider_issues owner/repo ) >/dev/null 2>&1
left=$(find "$LEAKD" -type f | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok "no temp file survives, token config included" || bad "temp files leaked" "$(ls "$LEAKD")"
rm -rf "$LEAKD"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
