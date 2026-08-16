#!/bin/sh
# The guard is per-session. These assert that, because the bug it replaced was
# invisible: one agent's interview silently permitted every other agent on the
# machine to interrupt, and its `close` revoked a window another was relying on.
#
#   sh plugins/pm/tests/interview-window.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IW=$HERE/../bin/interview-window
HOOK=$HERE/../hooks/deny-interrupt
TMP=${TMPDIR:-/tmp}/interview-window-test.$$
mkdir -p "$TMP/home"
trap 'rm -rf "$TMP"' EXIT INT TERM

export HOME=$TMP/home
export CLAUDE_INTERVIEW_WINDOW_DIR=$TMP/windows

A=aaaaaaaa-1111-2222-3333-444444444444
B=bbbbbbbb-5555-6666-7777-888888888888

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }

# as <session> <cmd...>  -- run interview-window as that session
as() { sid=$1; shift; CLAUDE_CODE_SESSION_ID=$sid sh "$IW" "$@"; }

# ask <session>  -- what the hook decides for that session. 0 allow, 2 block.
ask() {
  printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' "$1" \
    | sh "$HOOK" >/dev/null 2>&1
  echo $?
}
allowed() { [ "$(ask "$2")" -eq 0 ] && ok "$1" || bad "$1" "blocked, expected allowed"; }
blocked() { [ "$(ask "$2")" -eq 2 ] && ok "$1" || bad "$1" "allowed, expected blocked"; }

# --- the default is no ------------------------------------------------------
blocked "closed by default: A" "$A"
blocked "closed by default: B" "$B"

# --- the bug this replaced --------------------------------------------------
as "$A" open >/dev/null 2>&1
allowed "A opens -> A may ask" "$A"
blocked "A opens -> B still may NOT ask" "$B"

# --- and the other half of it -----------------------------------------------
as "$B" open >/dev/null 2>&1
allowed "both open -> A may ask" "$A"
allowed "both open -> B may ask" "$B"
as "$A" close >/dev/null 2>&1
blocked "A closes -> A blocked" "$A"
allowed "A closing does NOT revoke B's window" "$B"

# --- expiry, per session ----------------------------------------------------
as "$B" close >/dev/null 2>&1
as "$A" open >/dev/null 2>&1
# Backdate A's stamp past the window; B never had one.
find "$CLAUDE_INTERVIEW_WINDOW_DIR/$A" -exec touch -t 202001010000 {} \; 2>/dev/null
blocked "an expired window does not allow" "$A"
[ -f "$CLAUDE_INTERVIEW_WINDOW_DIR/$A" ] && bad "expired window is cleaned up" || ok "expired window is cleaned up"

# --- fail closed ------------------------------------------------------------
# No session id means we cannot tell whose window an open one is. Treating that
# as "allowed" is precisely the bug being fixed, so it must deny.
as "$A" open >/dev/null 2>&1
printf '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' | sh "$HOOK" >/dev/null 2>&1
[ $? -eq 2 ] && ok "no session_id in input -> blocked, not allowed" || bad "no session_id -> blocked"
printf '' | sh "$HOOK" >/dev/null 2>&1
[ $? -eq 2 ] && ok "empty input -> blocked" || bad "empty input -> blocked"
echo 'not json at all' | sh "$HOOK" >/dev/null 2>&1
[ $? -eq 2 ] && ok "unparseable input -> blocked" || bad "unparseable input -> blocked"

# --- opening a window nothing will read is refused, loudly ------------------
out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID sh "$IW" open 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "open without a session id -> exit 2" || bad "open without a session id -> exit 2" "rc=$rc"
case "$out" in *"cannot be scoped"*) ok "and explains why" ;; *) bad "and explains why" "$out" ;; esac

# --- the escape hatch still works -------------------------------------------
as "$A" close >/dev/null 2>&1
printf '{"session_id":"%s"}' "$A" | CLAUDE_ALLOW_INTERRUPT=1 sh "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "CLAUDE_ALLOW_INTERRUPT=1 overrides" || bad "CLAUDE_ALLOW_INTERRUPT=1 overrides"

# --- status sees the other agent --------------------------------------------
as "$B" open >/dev/null 2>&1
out=$(as "$A" status 2>&1)
case "$out" in *"$B"*) ok "status lists another session's open window" ;; *) bad "status lists another session's window" "$out" ;; esac
case "$out" in *"closed"*) ok "and reports this session as closed" ;; *) bad "and reports this session closed" "$out" ;; esac

# --- the old shared stamp is removed, not honoured --------------------------
mkdir -p "$HOME/.claude"; date > "$HOME/.claude/.interview-window"
as "$A" status >/dev/null 2>&1
[ -f "$HOME/.claude/.interview-window" ] && bad "legacy global stamp removed" || ok "legacy global stamp removed"
blocked "and it never allowed anything" "$A"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
