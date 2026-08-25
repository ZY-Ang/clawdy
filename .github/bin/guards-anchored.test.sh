#!/bin/sh
# Every guard must examine the repository it belongs to, not the cwd it was
# called from — and must refuse rather than pass when it finds nothing.
#
# All three globbed `plugins/*/…` relative to cwd, so running one from anywhere
# else printed its success line having looked at zero files. That is the exact
# failure these guards exist to catch, in the guards themselves.
#
#   sh .github/bin/guards-anchored.test.sh
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TMP=${TMPDIR:-/tmp}/guards-anchored.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

GUARDS='hooks-executable test-counts posix-sed stale-branches'

# Each guard must SAY how much it examined, so a run that looked at nothing is
# distinguishable from a clean one. "It printed a success line" is exactly what
# the broken version did.
for g in hooks-executable posix-sed; do
  [ -f "$HERE/$g" ] || continue
  out=$( cd "$ROOT" && sh "$HERE/$g" 2>&1 | tail -1 )
  n=$(printf '%s' "$out" | grep -oE '[0-9]+' | head -1)
  if [ -n "$n" ] && [ "$n" -gt 0 ]
  then ok "$g reports how many things it examined ($n)"
  else bad "$g reports a non-zero count" "$out"; fi
done

# The real case: called from an unrelated directory it must examine the SAME
# things, because it ships inside the repository it checks.
for g in hooks-executable posix-sed; do
  [ -f "$HERE/$g" ] || continue
  from_root=$( cd "$ROOT" && sh "$HERE/$g" 2>&1 | tail -1 )
  from_away=$( cd "$TMP" && sh "$HERE/$g" 2>&1 | tail -1 )
  [ "$from_root" = "$from_away" ] \
    && ok "$g gives the same answer from an unrelated directory" \
    || bad "$g answer differs by cwd" "root: $from_root / away: $from_away"
done

# ...including from inside a DIFFERENT git repository, which is what rules out
# `git rev-parse --show-toplevel` as the anchor.
( cd "$TMP" && git init -q otherrepo ) >/dev/null 2>&1
for g in hooks-executable posix-sed; do
  [ -f "$HERE/$g" ] || continue
  from_root=$( cd "$ROOT" && sh "$HERE/$g" 2>&1 | tail -1 )
  from_other=$( cd "$TMP/otherrepo" && sh "$HERE/$g" 2>&1 | tail -1 )
  [ "$from_root" = "$from_other" ] \
    && ok "$g is not fooled by another repository's root" \
    || bad "$g resolved the wrong repo" "root: $from_root / other: $from_other"
done

# Defence in depth: if the anchor is ever lost, a guard that finds nothing must
# REFUSE rather than print its success line. Tested by placing a copy where the
# anchor resolves to an empty tree, which is the only way to reach that branch
# while the anchor is working.
# One tree PER guard: posix-sed scans .github/bin itself, so copying all three
# into one directory gives it two scripts to find and the case proves nothing.
for g in hooks-executable posix-sed test-counts; do
  [ -f "$HERE/$g" ] || continue
  rm -rf "$TMP/empty-$g"; mkdir -p "$TMP/empty-$g/.github/bin"
  cp "$HERE/$g" "$TMP/empty-$g/.github/bin/"
  out=$( cd "$TMP" && sh "$TMP/empty-$g/.github/bin/$g" 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'broken run'
  then ok "$g refuses when it finds nothing to examine"
  else bad "$g refuses on an empty tree" "exit $rc: $(printf '%s' "$out" | tail -1)"; fi
done

# A remote that reports no HEAD branch -- bare, or freshly initialised -- must
# fall back rather than build the non-ref `origin/(unknown)`. That regression
# broke stale-branches' own suite and was invisible from this one.
( cd "$TMP" && git init -q --bare nohead.git
  git clone -q nohead.git noheadwt && cd noheadwt
  git config user.email t@t && git config user.name t
  echo x > f.txt && git add . && git commit -qm base
  git branch -M main && git push -q -u origin main ) >/dev/null 2>&1
if [ -f "$HERE/stale-branches" ]; then
  out=$( cd "$TMP/noheadwt" && sh "$HERE/stale-branches" 2>&1 ); rc=$?
  case "$out" in
    *'(unknown)'*) bad "a remote with no HEAD falls back cleanly" "$out" ;;
    *) [ "$rc" -eq 0 ] && ok "a remote with no HEAD falls back cleanly" \
         || bad "a remote with no HEAD falls back cleanly" "exit $rc: $out" ;;
  esac
fi

# stale-branches must read the default branch rather than guessing `main`. A
# repo whose default is master got every diff failing and `|| continue`
# swallowing it — a genuinely stale branch reported as none, exit 0.
( cd "$TMP" && git init -q --bare up.git
  git clone -q up.git wt && cd wt
  git config user.email t@t && git config user.name t
  echo one > a.txt && git add . && git commit -qm base
  git branch -M master && git push -q -u origin master
  git checkout -qb landed && echo two > a.txt && git commit -qam "work" && git push -q origin landed
  git checkout -q master && echo two > a.txt && git commit -qam "same content, landed separately"
  git push -q origin master ) >/dev/null 2>&1

if [ -f "$HERE/stale-branches" ]; then
  out=$( cd "$TMP/wt" && sh "$HERE/stale-branches" 2>&1 )
  case "$out" in
    *"stale: landed"*) ok "stale-branches finds a dead branch on a master-default repo" ;;
    *) bad "stale-branches on a master default" "$out" ;;
  esac
  # And it must not offer to delete anything on a repo where it found nothing
  # to compare against — the destructive direction of the same bug.
  cmds=$( cd "$TMP/wt" && sh "$HERE/stale-branches" --commands 2>&1 )
  case "$cmds" in
    *"--delete master"*) bad "stale-branches must never offer to delete the default branch" "$cmds" ;;
    *) ok "and never offers to delete the default branch" ;;
  esac
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
