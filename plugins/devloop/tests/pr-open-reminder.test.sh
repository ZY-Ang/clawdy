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

# --- Gitea: gitea-api POST to repos/<o>/<r>/pulls ---------------------------
fires() { # <name> <command JSON string>
  out=$(feed "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$2\"}}")
  case "$out" in *watcher*) ok "$1" ;; *) bad "$1" "$out" ;; esac
}
silent() {
  out=$(feed "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$2\"}}")
  case "$out" in *watcher*) bad "$1" "$out" ;; *) ok "$1" ;; esac
}
fires  "gitea-api POST repos/o/r/pulls fires" \
  'gitea-api -X POST repos/o/r/pulls --input /tmp/b.json'
fires  "gitea-api POST with a leading slash fires" \
  'gitea-api -X POST /repos/o/r/pulls --input -'
fires  "gitea-api by absolute path, after &&, fires" \
  'cd /x && /p/devloop/bin/gitea-api --input b.json -X post \"repos/o/r/pulls\"'
silent "gitea-api GET repos/o/r/pulls does not fire" \
  'gitea-api repos/o/r/pulls'
silent "gitea-api POST to a PR sub-path does not fire" \
  'gitea-api -X POST repos/o/r/pulls/3/reviews --input b.json'
silent "gitea-api POST to issues does not fire" \
  'gitea-api -X POST repos/o/r/issues --input b.json'
silent "prose naming a gitea-api POST does not fire" \
  'echo run gitea-api -X POST repos/o/r/pulls yourself'

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
