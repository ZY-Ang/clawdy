#!/bin/sh
# A PR opened without a watcher is the failure this hook exists for.
#
#   sh plugins/devloop/tests/pr-open-reminder.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK=$HERE/../hooks/pr-open-reminder
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

feed() { printf '%s' "$1" | sh "$HOOK"; }

out=$(feed '{"tool_name":"Bash","tool_input":{"command":"gh pr create --head b --base main --title t --body b"}}')
case "$out" in *watcher*) ok "gh pr create triggers the reminder" ;;
  *) bad "gh pr create triggers the reminder" "$out" ;; esac

out=$(feed '{"tool_name":"Bash","tool_input":{"command":"gh pr view 1"}}')
case "$out" in *watcher*) bad "other gh commands do not fire it" ;;
  *) ok "other gh commands do not fire it" ;; esac

# Prose mentioning the command inside a heredoc must not fire.
out=$(feed '{"tool_name":"Bash","tool_input":{"command":"gh pr edit 1 --body-file - <<EOF\nrun gh pr create yourself\nEOF"}}')
case "$out" in *watcher*) bad "prose mentioning the command does not fire it" ;;
  *) ok "prose mentioning the command does not fire it" ;; esac

out=$(feed '{"tool_name":"Read","tool_input":{"file_path":"/x"}}')
case "$out" in *watcher*) bad "non-Bash tools never fire it" ;;
  *) ok "non-Bash tools never fire it" ;; esac

out=$(feed 'not json at all')
case "$out" in *watcher*) bad "unparseable input stays silent" ;;
  *) ok "unparseable input stays silent" ;; esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
