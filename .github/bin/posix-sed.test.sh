#!/bin/sh
# The guard must catch the exact expression that shipped, ignore comments about
# it, and not fire on the portable form.
#
#   sh .github/bin/posix-sed.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP=${TMPDIR:-/tmp}/posix-sed-test.$$
mkdir -p "$TMP/plugins/demo/bin" "$TMP/.github/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM
cp "$HERE/posix-sed" "$TMP/.github/bin/"

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

mk()  { printf '#!/bin/sh\n%s\n' "$1" > "$TMP/plugins/demo/bin/demo"; }
run() { ( cd "$TMP" && sh .github/bin/posix-sed 2>&1 ); }
rc()  { ( cd "$TMP" && sh .github/bin/posix-sed >/dev/null 2>&1 ); echo $?; }

# The literal expression from issue 50.
mk "printf x | sed -e 's/[^a-z0-9]\\+/-/g'"
[ "$(rc)" -ne 0 ] && ok "the shipped \\+ expression is caught" || bad "\\+ not caught" "$(run)"
case "$(run)" in *'BSD sed reads it literally'*) ok "and says why it matters" ;; *) bad "explains the cause" "$(run)" ;; esac

mk "printf x | sed -e 's/ab\\?/-/g'"
[ "$(rc)" -ne 0 ] && ok "\\? is caught" || bad "\\? not caught"
mk "printf x | sed -e 's/a\\|b/-/g'"
[ "$(rc)" -ne 0 ] && ok "\\| is caught" || bad "\\| not caught"

# The portable rewrite must pass, or the guard is unusable.
mk "printf x | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g'"
[ "$(rc)" -eq 0 ] && ok "the portable form passes" || bad "portable form flagged" "$(run)"
mk "printf x | sed -e 's/ab\\{0,1\\}/-/g'"
[ "$(rc)" -eq 0 ] && ok "a POSIX interval passes" || bad "interval flagged" "$(run)"

# A comment ABOUT the trap is not the trap. The first version of this guard
# flagged its own explanation.
mk "# beware: sed with \\+ is a GNU extension
printf x | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g'"
[ "$(rc)" -eq 0 ] && ok "a comment mentioning \\+ is ignored" || bad "comment flagged" "$(run)"

# \+ in another language on a line with no sed is not a sed problem.
mk "printf x | awk '/[0-9]\\+/ { print }'"
[ "$(rc)" -eq 0 ] && ok "\\+ outside a sed call is left alone" || bad "awk flagged" "$(run)"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
