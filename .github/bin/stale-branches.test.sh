#!/bin/sh
# The tool must find a branch whose files all match the default branch, must not
# flag one with real work, and must be honest about the case it cannot see.
#
#   sh .github/bin/stale-branches.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP=${TMPDIR:-/tmp}/stale-br-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

# A throwaway origin plus a clone, because the tool reads refs/remotes.
( cd "$TMP" && git init -q --bare origin.git
  git clone -q origin.git work && cd work
  git config user.email t@t && git config user.name t
  echo one > a.txt && git add . && git commit -qm base && git branch -M main && git push -q origin main

  # dead: changes a file, then main gets the identical content by another route
  git checkout -qb dead && echo two > a.txt && git commit -qam "dead branch work" && git push -q origin dead
  git checkout -q main && echo two > a.txt && git commit -qam "same content, landed separately" && git push -q origin main

  # live: real work not on main
  git checkout -qb live main && echo three > b.txt && git add . && git commit -qm "live work" && git push -q origin live
) >/dev/null 2>&1
mkdir -p "$TMP/bin"; cp "$HERE/stale-branches" "$TMP/bin/"

out=$( cd "$TMP/work" && sh "$TMP/bin/stale-branches" 2>&1 )
case "$out" in *"stale: dead"*) ok "a branch whose files all match main is flagged" ;;
  *) bad "dead branch flagged" "$out" ;; esac
case "$out" in *"stale: live"*) bad "a branch with real work is NOT flagged" "$out" ;;
  *) ok "a branch with real work is left alone" ;; esac
case "$out" in *"stale: main"*) bad "main itself must never be flagged" "$out" ;;
  *) ok "the default branch is never flagged" ;; esac

cmds=$( cd "$TMP/work" && sh "$TMP/bin/stale-branches" --commands 2>&1 )
case "$cmds" in *"git push origin --delete dead"*) ok "--commands emits a runnable delete" ;;
  *) bad "--commands output" "$cmds" ;; esac
case "$cmds" in *live*) bad "--commands must not offer to delete live work" "$cmds" ;;
  *) ok "and offers nothing for the live branch" ;; esac

# The documented blind spot must stay documented: a reader who trusts a clean
# run needs to know which case it cannot see.
case "$(cat "$HERE/stale-branches")" in
  *"WHAT IT CANNOT SEE"*) ok "the blind spot is stated in the tool itself" ;;
  *) bad "blind spot undocumented" ;;
esac

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
