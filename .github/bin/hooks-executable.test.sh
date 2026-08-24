#!/bin/sh
# The guard must FAIL on the shape that shipped, or it is decoration.
#
#   sh .github/bin/hooks-executable.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GUARD=$HERE/hooks-executable
TMP=${TMPDIR:-/tmp}/hooks-exec-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

# A throwaway repo, because the guard reads the git index rather than the disk.
( cd "$TMP" && git init -q . && git config user.email t@t && git config user.name t
  mkdir -p plugins/demo/hooks .github/bin
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/guarded"}]}]}}\n' \
    > plugins/demo/hooks/hooks.json
  printf '#!/bin/sh\nexit 0\n' > plugins/demo/hooks/guarded
  git add -A && git commit -qm base ) >/dev/null 2>&1
cp "$GUARD" "$TMP/.github/bin/hooks-executable"

run() { ( cd "$TMP" && sh .github/bin/hooks-executable 2>&1 ); }

# git add records 100644 for a file with no exec bit -- exactly what shipped.
if ( cd "$TMP" && sh .github/bin/hooks-executable >/dev/null 2>&1 )
then bad "a 100644 hook is rejected" "$(run)"
else ok "a 100644 hook is rejected"; fi

case "$(run)" in
  *"can never run"*) ok "and says why, not just that it failed" ;;
  *) bad "names the consequence" "$(run)" ;;
esac
case "$(run)" in
  *"git update-index --chmod=+x"*) ok "and gives the exact fix" ;;
  *) bad "gives the fix" "$(run)" ;;
esac

( cd "$TMP" && git update-index --chmod=+x plugins/demo/hooks/guarded ) >/dev/null 2>&1
if ( cd "$TMP" && sh .github/bin/hooks-executable >/dev/null 2>&1 )
then ok "a 100755 hook passes"; else bad "a 100755 hook passes" "$(run)"; fi

# A hooks.json naming a file nobody committed is the other way to ship a guard
# that never fires.
( cd "$TMP" && printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/hooks/absent"}]}]}}\n' \
    > plugins/demo/hooks/hooks.json ) >/dev/null 2>&1
if ( cd "$TMP" && sh .github/bin/hooks-executable >/dev/null 2>&1 )
then bad "a hook named but not present is rejected"; else ok "a hook named but not present is rejected"; fi

# AND the real repo, here rather than in the workflow: CI already runs every
# .github/bin/*.test.sh, so the guard is enforced without a workflow change --
# which this token cannot make anyway.
if ( cd "$HERE/../.." && sh .github/bin/hooks-executable >/dev/null 2>&1 )
then ok "this repo's own hooks are all executable"
else bad "this repo's own hooks are all executable" \
       "$( cd "$HERE/../.." && sh .github/bin/hooks-executable 2>&1 | head -3 )"; fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
