#!/bin/sh
# The second door into the tracker. `gh issue create` attaches no labels and
# enforces nothing, so what it files is open and invisible at once.
#
#   sh plugins/pm/tests/raw-issue.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK=$HERE/../hooks/deny-raw-issue-create

[ -f "$HOOK" ] || { echo "raw-issue.test: no $HOOK" >&2; exit 1; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"
        [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

# The hook reads PreToolUse JSON on stdin. Built with jq when it is here so the
# quoting is right, by hand when it is not -- the hook itself has both paths and
# the test must exercise the shape either way.
say() {  # <command> -> exit code
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' \
      | sh "$HOOK" >/dev/null 2>&1
  else
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
      | sh "$HOOK" >/dev/null 2>&1
  fi
  echo $?
}
blocks() { if [ "$(say "$2")" -eq 2 ]; then ok "$1"; else bad "$1" "not blocked"; fi; }
allows() { if [ "$(say "$2")" -eq 0 ]; then ok "$1"; else bad "$1" "blocked, should not be"; fi; }

# --- the shape that produced this guard --------------------------------------
blocks "gh issue create"            'gh issue create --title "x" --body "y"'
blocks "glab issue create"          'glab issue create --title "x"'
blocks "a flag before the subcommand" 'gh --repo o/r issue create --title x'
blocks "inside a pipeline"          'cat body.md | gh issue create --title x --body-file -'
blocks "after a cd"                 'cd /tmp && gh issue create --title x'

# --- must not block the rest of the CLI --------------------------------------
# Over-blocking is how a guard gets switched off. Every one of these is a normal
# thing to run, and none of them files an unlabelled issue.
allows "gh issue list"              'gh issue list --state open'
allows "gh issue view"              'gh issue view 42 --json labels'
allows "gh issue edit"              'gh issue edit 42 --add-label task'
allows "gh issue close"             'gh issue close 42 --reason "not planned"'
allows "gh pr create"               'gh pr create --title x --body y'
allows "gh label create"            'gh label create -n task'
allows "file-issue itself"          'file-issue task "x" --priority med --urgency low --size s --body b'
# file-issue shells out to the provider, which runs the very command this
# blocks. The hook sees Bash tool calls, not what a script spawns -- but a
# caller pasting the whole invocation must still get through.
allows "a heredoc mentioning it"    'cat <<EOF
run gh issue list to see them
EOF'

# --- the escape hatch, and the shape of the refusal --------------------------
if command -v jq >/dev/null 2>&1; then
  out=$(printf '%s' 'gh issue create --title x' \
        | jq -Rs '{tool_name:"Bash",tool_input:{command:.}}' | sh "$HOOK" 2>&1 >/dev/null)
else
  out=$(printf '{"tool_input":{"command":"gh issue create --title x"}}' | sh "$HOOK" 2>&1 >/dev/null)
fi
case "$out" in *file-issue*) ok "the refusal names file-issue" ;;
               *) bad "the refusal names file-issue" "$out" ;; esac
case "$out" in *--priority*) ok "and shows the axes it wants" ;;
               *) bad "and shows the axes it wants" "$out" ;; esac
case "$out" in *ask-async*) ok "and points questions at ask-async" ;;
               *) bad "and points questions at ask-async" "$out" ;; esac

rc=$(printf '{"tool_input":{"command":"gh issue create --title x"}}' \
     | CLAUDE_ALLOW_RAW_ISSUE=1 sh "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "the escape hatch lets one command through" \
                || bad "the escape hatch lets one command through" "exit $rc"

# --- no input, no opinion ----------------------------------------------------
# A hook that blocks on an empty payload blocks every Bash call the moment the
# harness changes shape.
rc=$(printf '' | sh "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "empty input is allowed, not blocked" \
                || bad "empty input is allowed, not blocked" "exit $rc"
rc=$(printf '{"tool_name":"Bash","tool_input":{}}' | sh "$HOOK" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "a payload with no command is allowed" \
                || bad "a payload with no command is allowed" "exit $rc"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
