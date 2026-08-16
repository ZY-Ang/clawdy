#!/bin/sh
# "Has a human replied?" decided by the agent mark, not by the author -- on
# GitHub the agent posts through the human's token, so every comment shares an
# author and the mark is the only signal.
#
#   sh plugins/pm/tests/check-replies.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/check-replies
TMP=${TMPDIR:-/tmp}/check-replies-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

M='🤖'
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }

run() { CHECK_REPLIES_JSON="$TMP/$1.json" sh "$BIN" ${2:-}; }
rcof() { CHECK_REPLIES_JSON="$TMP/$1.json" sh "$BIN" ${2:-} >/dev/null 2>&1; echo $?; }

# Every comment carries the SAME author, deliberately: that is the real shape,
# and a test that varied it could pass while the tool read the wrong field.
mk() { cat > "$TMP/$1.json"; }

mk answered <<EOF
[{"number":7,"title":"Keep invoice numbers?","updatedAt":"2026-08-19T00:00:00Z","comments":[
  {"author":{"login":"ZY-Ang"},"body":"$M\n\n### Question\nKeep them?"},
  {"author":{"login":"ZY-Ang"},"body":"Yes, keep them. Gaps are fine."}]}]
EOF
[ "$(rcof answered)" -eq 0 ] && ok "human spoke last -> answered, exit 0" || bad "human spoke last -> exit 0"
case "$(run answered)" in *ANSWERED*\#7*) ok "and names the issue" ;; *) bad "and names the issue" "$(run answered)" ;; esac

mk waiting <<EOF
[{"number":8,"title":"Which timeout?","updatedAt":"2026-08-19T00:00:00Z","comments":[
  {"author":{"login":"ZY-Ang"},"body":"$M\n\n### Question\nWhich?"}]}]
EOF
[ "$(rcof waiting)" -eq 1 ] && ok "only an agent comment -> still waiting, exit 1" || bad "only agent -> exit 1"
case "$(run waiting)" in *"Nothing answered"*) ok "and says nothing is answered" ;; *) bad "and says nothing is answered" ;; esac

mk nocomments <<'EOF'
[{"number":9,"title":"Never commented on","updatedAt":"2026-08-19T00:00:00Z","comments":[]}]
EOF
[ "$(rcof nocomments)" -eq 1 ] && ok "no comments at all -> waiting" || bad "no comments -> waiting"

# The case a naive "any unmarked comment" check gets wrong: the human answered,
# the agent asked a follow-up, so the ball is back with the person.
mk agentlast <<EOF
[{"number":10,"title":"Ambiguous answer","updatedAt":"2026-08-19T00:00:00Z","comments":[
  {"author":{"login":"ZY-Ang"},"body":"$M\n\nQuestion?"},
  {"author":{"login":"ZY-Ang"},"body":"Maybe, depends."},
  {"author":{"login":"ZY-Ang"},"body":"$M\n\nDepends on what exactly?"}]}]
EOF
[ "$(rcof agentlast)" -eq 1 ] && ok "agent replied after the human -> still waiting" \
  || bad "agent replied after the human -> still waiting" "an 'any unmarked comment' check fails here"

# Mixed: one answered, one not. Exit 0 because there IS work to pick up.
mk mixed <<EOF
[{"number":11,"title":"Answered one","updatedAt":"2026-08-19T00:00:00Z","comments":[
  {"author":{"login":"ZY-Ang"},"body":"$M\n\nQ?"},{"author":{"login":"ZY-Ang"},"body":"Do it."}]},
 {"number":12,"title":"Unanswered one","updatedAt":"2026-08-19T00:00:00Z","comments":[
  {"author":{"login":"ZY-Ang"},"body":"$M\n\nQ?"}]}]
EOF
[ "$(rcof mixed)" -eq 0 ] && ok "mixed -> exit 0, there is work" || bad "mixed -> exit 0"
out=$(run mixed)
case "$out" in *\#11*) ok "lists the answered one" ;; *) bad "lists the answered one" "$out" ;; esac
case "$out" in *\#12*) bad "does not list the unanswered one" "$out" ;; *) ok "does not list the unanswered one" ;; esac
case "$(run mixed --all)" in *\#12*) ok "--all does list it" ;; *) bad "--all does list it" ;; esac
[ "$(run mixed --quiet)" = "11" ] && ok "--quiet prints just the number" || bad "--quiet prints just the number" "$(run mixed --quiet)"

# A title with spaces must survive the split.
mk spaces <<EOF
[{"number":13,"title":"a title with several spaces in it","updatedAt":"2026-08-19T00:00:00Z","comments":[
  {"author":{"login":"ZY-Ang"},"body":"$M\n\nQ?"},{"author":{"login":"ZY-Ang"},"body":"go"}]}]
EOF
case "$(run spaces)" in *"a title with several spaces in it"*) ok "titles with spaces survive" ;;
  *) bad "titles with spaces survive" "$(run spaces)" ;; esac

# Nothing at all is not an error, it is just nothing to do.
mk empty <<'EOF'
[]
EOF
[ "$(rcof empty)" -eq 1 ] && ok "empty list -> exit 1, not an error" || bad "empty list -> exit 1"

# Unparseable input must never look like "nothing to do".
echo 'not json' > "$TMP/broken.json"
[ "$(rcof broken)" -eq 2 ] && ok "unparseable -> exit 2, never mistaken for answered" || bad "unparseable -> exit 2"

sh "$BIN" --nonsense >/dev/null 2>&1
[ $? -eq 2 ] && ok "unknown option -> 2" || bad "unknown option -> 2"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
