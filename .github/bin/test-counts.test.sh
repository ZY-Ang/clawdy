#!/bin/sh
# The guard must fail on the shape that shipped in three suites, or it is
# decoration — and it must not fire on a suite that legitimately skips.
#
#   sh .github/bin/test-counts.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP=${TMPDIR:-/tmp}/test-counts-test.$$
mkdir -p "$TMP/plugins/demo/tests" "$TMP/.github/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM
cp "$HERE/test-counts" "$TMP/.github/bin/"

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

mksuite() { printf '#!/bin/sh\n%s\n' "$2" > "$TMP/plugins/demo/tests/$1.test.sh"; }
run() { ( cd "$TMP" && sh .github/bin/test-counts 2>&1 ); }
rc()  { ( cd "$TMP" && sh .github/bin/test-counts >/dev/null 2>&1 ); echo $?; }

# Honest: two assertions printed, two claimed.
mksuite honest 'printf "ok   one\nok   two\n---\n2 passed\n"'
[ "$(rc)" -eq 0 ] && ok "an honest count passes" || bad "honest count" "$(run)"

# The shape that shipped: ok() incremented, then the case incremented again.
mksuite honest 'printf "ok   one\nok   two\n---\n4 passed\n"'
[ "$(rc)" -ne 0 ] && ok "a total larger than what was printed fails" || bad "over-count not caught"
case "$(run)" in
  *"claims 4 assertions but printed 2"*) ok "and says both numbers" ;;
  *) bad "names both numbers" "$(run)" ;;
esac

# The other direction: counted without printing.
mksuite honest 'printf "ok   one\nok   two\n---\n1 passed\n"'
[ "$(rc)" -ne 0 ] && ok "a total smaller than what was printed fails" || bad "under-count not caught"

# The failure summary uses a different shape, and it is the one that shifted.
mksuite honest 'printf "ok   one\nFAIL two\n---\n1 of 5 failed\n"'
[ "$(rc)" -ne 0 ] && ok "the \"N of M failed\" form is checked too" || bad "failed-form not checked"
mksuite honest 'printf "ok   one\nFAIL two\n---\n1 of 2 failed\n"'
[ "$(rc)" -eq 0 ] && ok "and passes when M matches" || bad "failed-form false positive" "$(run)"

# statusline's shape.
mksuite honest 'printf "ok   one\nok   two\n---\n2 ran, 0 failed\n"'
[ "$(rc)" -eq 0 ] && ok "the \"N ran\" form is understood" || bad "ran-form" "$(run)"

# A suite that skips has nothing to count and must not fail the guard.
mksuite honest 'echo "demo.test: skipping, no credentials" >&2; exit 1'
[ "$(rc)" -eq 0 ] && ok "a suite that prints no assertion is skipped, not failed" || bad "skip treated as failure" "$(run)"

# ...but a suite that printed assertions and no summary is a real problem.
mksuite honest 'printf "ok   one\nok   two\n"'
[ "$(rc)" -ne 0 ] && ok "assertions with no summary fail" || bad "missing summary not caught"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
