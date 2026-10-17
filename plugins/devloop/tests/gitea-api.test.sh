#!/bin/sh
# gitea-api against a stub curl: what goes over the wire, and the exit codes.
#
#   sh plugins/devloop/tests/gitea-api.test.sh
#
# No live Gitea instance is used (one is pending a scratch instance). Response
# shapes follow Gitea's published API schema (https://docs.gitea.com/api and
# modules/structs in https://github.com/go-gitea/gitea).

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
API=$HERE/../bin/gitea-api
TMP=${TMPDIR:-/tmp}/gitea-api-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM
cp "$HERE/stub-curl" "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"

URL=https://gitea.com
TOKEN=tok-5f3a9c1e
A=$URL/api/v1
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

reset() { : > "$TMP/log"; : > "$TMP/routes"; }
route() { # METHOD URL CODE BODY
  printf '%s\n' "$4" > "$TMP/body.$ran.$(wc -l < "$TMP/routes" | tr -d ' ')"
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$TMP/body.$ran.$(wc -l < "$TMP/routes" | tr -d ' ')" >> "$TMP/routes"
}
call() { # args to gitea-api; sets out, err, rc
  out=$(PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" GITEA_URL=${U-$URL} GITEA_TOKEN=${T-$TOKEN} \
        sh "$API" "$@" 2>"$TMP/err"); rc=$?
  err=$(cat "$TMP/err")
}

PR='{"id":101,"number":14,"title":"Add a thing","state":"open","draft":false,"mergeable":true}'

# --- reads -------------------------------------------------------------------
reset; route GET "$A/repos/o/r/pulls/14" 200 "$PR"
call repos/o/r/pulls/14
if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$out" | jq -r .number)" = 14 ]
then ok "GET prints the body and exits 0"; else bad "GET prints the body and exits 0" "rc=$rc out=$out err=$err"; fi

reset; route GET "$A/repos/o/r/pulls/14" 200 "$PR"
U=$URL/; call /repos/o/r/pulls/14; unset U
if [ "$rc" -eq 0 ] && grep -qx "REQ GET $A/repos/o/r/pulls/14" "$TMP/log"
then ok "trailing slash on GITEA_URL and leading slash on the path"
else bad "trailing slash on GITEA_URL and leading slash on the path" "$(cat "$TMP/log")"; fi

# --- the token --------------------------------------------------------------
reset; route GET "$A/user" 200 '{"id":1,"login":"me"}'
call user
if grep '^ARGV' "$TMP/log" | grep -q "$TOKEN"
then bad "token never appears in curl's argv" "$(grep '^ARGV' "$TMP/log")"
else ok "token never appears in curl's argv"; fi
if grep -qx "CFG header = \"Authorization: token $TOKEN\"" "$TMP/log"
then ok "token is sent as an Authorization header from the config file"
else bad "token is sent as an Authorization header from the config file" "$(cat "$TMP/log")"; fi
if grep -qx 'CFGMODE -rw-------' "$TMP/log"
then ok "the config file holding the token is mode 600"
else bad "the config file holding the token is mode 600" "$(grep CFGMODE "$TMP/log")"; fi
cfg=$(sed -n 's/^ARGV.* -K \([^ ]*\) .*/\1/p' "$TMP/log" | head -1)
if [ -n "$cfg" ] && [ ! -e "$cfg" ]
then ok "the config file is removed afterwards"; else bad "the config file is removed afterwards" "cfg=$cfg"; fi

# --- writes -----------------------------------------------------------------
reset; route POST "$A/repos/o/r/pulls" 201 '{"number":15}'
printf '%s' '{"base":"main","head":"feat","title":"WIP: thing","milestone":3}' > "$TMP/in.json"
call -X POST repos/o/r/pulls --input "$TMP/in.json"
if [ "$rc" -eq 0 ] && grep -qx "REQ POST $A/repos/o/r/pulls" "$TMP/log" \
   && grep -qx 'BODY {"base":"main","head":"feat","title":"WIP: thing","milestone":3}' "$TMP/log" \
   && grep -qx 'HEADER Content-Type: application/json' "$TMP/log"
then ok "POST --input FILE sends the body verbatim as JSON"
else bad "POST --input FILE sends the body verbatim as JSON" "rc=$rc $(cat "$TMP/log")"; fi
if grep '^BODY' "$TMP/log" | grep -q '"milestone":3[,}]'
then ok "integers stay integers on the wire"; else bad "integers stay integers on the wire"; fi

reset; route PATCH "$A/repos/o/r/issues/14" 200 '{"number":14}'
out=$(printf '%s' '{"body":"x"}' | PATH="$TMP/bin:$PATH" STUB_DIR="$TMP" GITEA_URL=$URL GITEA_TOKEN=$TOKEN \
      sh "$API" -X patch repos/o/r/issues/14 --input - 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -qx "REQ PATCH $A/repos/o/r/issues/14" "$TMP/log" && grep -qx 'BODY {"body":"x"}' "$TMP/log"
then ok "--input - reads stdin; the method is upper-cased"
else bad "--input - reads stdin; the method is upper-cased" "rc=$rc $(cat "$TMP/log")"; fi

reset
call -X POST repos/o/r/pulls --input "$TMP/missing.json"
if [ "$rc" -eq 2 ] && ! grep -q '^REQ' "$TMP/log"
then ok "a missing --input file is exit 2, nothing sent"; else bad "a missing --input file is exit 2, nothing sent" "rc=$rc"; fi

# --- errors -----------------------------------------------------------------
reset; route GET "$A/repos/o/r/pulls/99" 404 '{"message":"The target couldn'"'"'t be found.","url":"https://gitea.com/api/swagger"}'
call repos/o/r/pulls/99
case "$rc:$err:$out" in
  "1:"*"The target couldn't be found."*":") ok "HTTP error: exit 1, Gitea's message on stderr, nothing on stdout" ;;
  *) bad "HTTP error: exit 1, Gitea's message on stderr, nothing on stdout" "rc=$rc err=$err out=$out" ;;
esac
case "$err" in
  *'"url"'*) bad "a JSON error is reduced to its message" "$err" ;;
  *) ok "a JSON error is reduced to its message" ;;
esac

reset; route GET "$A/repos/o/r/pulls/98" 502 'Bad Gateway'
call repos/o/r/pulls/98
case "$rc:$err" in
  "1:"*"HTTP 502"*"Bad Gateway"*) ok "a non-JSON error body is shown as is" ;;
  *) bad "a non-JSON error body is shown as is" "rc=$rc err=$err" ;;
esac

reset; route GET "$A/repos/o/r/pulls/14" 000 x
call repos/o/r/pulls/14
if [ "$rc" -eq 2 ]; then ok "network failure is exit 2, not an HTTP error"
else bad "network failure is exit 2, not an HTTP error" "rc=$rc err=$err"; fi

reset; route DELETE "$A/repos/o/r/issues/comments/7" 204 ''
call -X DELETE repos/o/r/issues/comments/7
if [ "$rc" -eq 0 ]; then ok "204 No Content is success"; else bad "204 No Content is success" "rc=$rc err=$err"; fi

# --- configuration and usage -----------------------------------------------
reset
U=; call user; unset U
case "$rc:$err" in "2:"*GITEA_URL*) ok "missing GITEA_URL: exit 2 naming it" ;;
  *) bad "missing GITEA_URL: exit 2 naming it" "rc=$rc err=$err" ;; esac
T=; call user; unset T
case "$rc:$err" in "2:"*GITEA_TOKEN*) ok "missing GITEA_TOKEN: exit 2 naming it" ;;
  *) bad "missing GITEA_TOKEN: exit 2 naming it" "rc=$rc err=$err" ;; esac
if grep -q '^REQ' "$TMP/log"; then bad "missing configuration sends nothing"; else ok "missing configuration sends nothing"; fi

call
[ "$rc" -eq 2 ] && ok "no path is a usage error" || bad "no path is a usage error" "rc=$rc"
call --paginate user
[ "$rc" -eq 2 ] && ok "an unknown option is a usage error" || bad "an unknown option is a usage error" "rc=$rc"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
