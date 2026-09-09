#!/bin/sh
# The conventions block is installed as instruction. Naming one host as THE host
# makes a missing CLI read as a missing tracker.
#
#   sh plugins/opinionated-claude/tests/neutral.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DOC=$HERE/../conventions.md

[ -f "$DOC" ] || { echo "neutral.test: no $DOC" >&2; exit 1; }

fails=0 checked=0
ok()  { checked=$((checked+1)); printf 'ok   %s\n' "$1"; }
bad() { checked=$((checked+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"
        [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

absent() {
  hit=$(grep -n -- "$2" "$DOC" | head -1)
  if [ -z "$hit" ]; then ok "$1"; else bad "$1" "$hit"; fi
}
present() {
  if grep -q -- "$2" "$DOC"; then ok "$1"; else bad "$1" "no line matches: $2"; fi
}

# --- no host stated as the environment ---------------------------------------
absent "no heading names a host"            '^## .*post to GitHub'
absent "no claim that posting is via GitHub" 'On GitHub you post'
absent "no CLI named as the only fallback"   'go straight to .gh. —'

# --- the seam is named, and named as the authority ---------------------------
present "PM_PROVIDER named"                  'PM_PROVIDER'
present "PM_REPO named"                      'PM_REPO'
present "provider stated as authoritative"   'configured provider is authoritative'

# The whole point: a denied CLI must not be read as an unreachable tracker.
present "denied CLI is not evidence"         'does \*\*not\*\* mean the tracker is unreachable'
present "names what does answer it"          'questions list'

# A CLI may still be named illustratively -- but never alone, or it reads as the
# one true tool. Both backends appear together or neither does.
if grep -q '`gh`' "$DOC"; then
  if grep -q '`glab`' "$DOC"; then ok "gh named beside glab"
  else bad "gh named beside glab" "gh appears without glab"; fi
else
  ok "gh named beside glab"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$checked passed"; else echo "$fails of $checked failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
