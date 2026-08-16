#!/bin/sh
# The version guard, against real repositories built for each case.
#
#   sh .github/bin/version-guard.test.sh
#
# The escape added for a deliberate re-versioning is only safe if the case it
# was added for passes and the accident it resembles still fails. Both are here.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUARD=$HERE/require-version-bump
TMP=${TMPDIR:-/tmp}/vg-test.$$
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

# repo <from> <to> <message> -- two commits, a version move, a changed file
repo() {
  rm -rf "$TMP/r"; mkdir -p "$TMP/r/plugins/x/.claude-plugin"
  ( cd "$TMP/r" && git init -q .
    printf '{"name":"x","version":"%s"}\n' "$1" > plugins/x/.claude-plugin/plugin.json
    echo a > plugins/x/f
    git add -A && git -c user.email=t@t -c user.name=t commit -qm base
    printf '{"name":"x","version":"%s"}\n' "$2" > plugins/x/.claude-plugin/plugin.json
    echo b > plugins/x/f
    git add -A && git -c user.email=t@t -c user.name=t commit -qm "$3" ) >/dev/null 2>&1
}
rc() { ( cd "$TMP/r" && sh "$GUARD" HEAD~1 >/dev/null 2>&1 ); echo $?; }
out() { ( cd "$TMP/r" && sh "$GUARD" HEAD~1 2>&1 ); }

repo 1.0.0 1.1.0 "a normal bump"
[ "$(rc)" -eq 0 ] && ok "a forward bump passes" || bad "forward bump" "$(out)"

repo 1.0.0 1.0.0 "no bump at all"
[ "$(rc)" -eq 1 ] && ok "an unchanged version fails" || bad "unchanged fails"

repo 1.8.0 1.7.0 "the losing side of a version race"
[ "$(rc)" -eq 1 ] && ok "an undeclared downgrade fails" || bad "undeclared downgrade fails"

repo 1.8.0 0.8.0 "back under 1.0

Version-Reset: x"
[ "$(rc)" -eq 0 ] && ok "a DECLARED downgrade passes" || bad "declared downgrade" "$(out)"
case "$(out)" in *"reset, declared"*) ok "and says it was declared, not silently allowed" ;;
  *) bad "reports the reset" "$(out)" ;; esac

# The escape must be scoped to the plugin named, or it is a blanket bypass.
repo 1.8.0 0.8.0 "back under 1.0

Version-Reset: something-else"
[ "$(rc)" -eq 1 ] && ok "a reset declared for ANOTHER plugin does not apply" || bad "reset is scoped" "$(out)"

# 0.9.0 -> 0.10.0 is the pair a lexicographic compare gets backwards.
repo 0.9.0 0.10.0 "double-digit minor"
[ "$(rc)" -eq 0 ] && ok "0.10.0 reads as higher than 0.9.0, not lower" || bad "sort -V ordering" "$(out)"

repo 0.10.0 0.9.0 "going back a minor"
[ "$(rc)" -eq 1 ] && ok "and 0.9.0 after 0.10.0 is still a downgrade" || bad "reverse ordering"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
