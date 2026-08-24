#!/bin/sh
# The helper must actually hide gh, and must not hide anything else.
#
#   sh plugins/pm/tests/gh-free.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/lib/gh-free.sh"
TMP=${TMPDIR:-/tmp}/gh-free-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

FARM=$(gh_free_path "$TMP/farm")
[ -d "$FARM" ] && ok "the farm is created" || bad "farm not created"

# The whole point. Not "the first gh is hidden" -- every one.
if PATH="$FARM" command -v gh >/dev/null 2>&1
then bad "gh is hidden" "still resolvable at $(PATH="$FARM" command -v gh)"
else ok "gh is hidden, wherever it was installed"; fi

# ...without taking the rest of the toolchain with it, which is what dropping
# a whole PATH directory would do.
for tool in sh jq sed awk grep git printf date mktemp; do
  if PATH="$FARM" command -v "$tool" >/dev/null 2>&1
  then ok "$tool survives"; else bad "$tool survives" "lost from the farm"; fi
done

# A fake gh prepended by a suite must win, which is the arrangement every
# caller uses.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho FAKE\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
[ "$(PATH="$TMP/bin:$FARM" gh 2>&1)" = FAKE ] \
  && ok "a suite's fake gh is reachable in front of the farm" || bad "fake gh not reachable"

# Idempotent: a loop that re-arms must not fail on existing links.
FARM2=$(gh_free_path "$TMP/farm")
[ "$FARM2" = "$FARM" ] && ok "re-running returns the same farm" || bad "farm path changed"
if PATH="$FARM2" command -v gh >/dev/null 2>&1; then bad "gh reappeared on a re-run"; else ok "and gh is still hidden"; fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
