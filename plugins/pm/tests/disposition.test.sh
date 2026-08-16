#!/bin/sh
# Replying to a needs-human issue must say what happens to the label.
#
#   sh plugins/pm/tests/disposition.test.sh
#
# The failure this guards: the human answers, the agent acts and replies, and
# the label outlives both — so the issue sits in the queue forever looking
# blocked on a person who already answered.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
TMP=${TMPDIR:-/tmp}/disposition-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

if command -v gh >/dev/null 2>&1; then
  echo "disposition.test: a real gh is on PATH; these cases fake it" >&2; exit 1
fi
export HOME=$TMP CLAUDE_QUESTIONS_DIR=$TMP/notes

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }
rc_is(){ if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, wanted $3"; fi; }

# A gh that reports the label and records what was done to it.
mkgh() { # mkgh <labelled?>
  cat > "$TMP/bin/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$TMP/calls"
case "\$1 \$2" in
  "issue view") [ "$1" = yes ] && echo needs-human; exit 0 ;;
  "issue comment") echo "https://github.com/o/r/issues/33#c1"; exit 0 ;;
  "issue edit") exit 0 ;;
  "issue close") exit 0 ;;
  "label create") exit 0 ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/gh"; : > "$TMP/calls"
}
r() { PATH="$TMP/bin:$PATH" sh "$BIN/reply-issue" "$@"; }
called() { grep -q -- "$1" "$TMP/calls" 2>/dev/null; }

# --- labelled: a disposition is required -------------------------------------
mkgh yes
r 33 "Done, on branch X" >/dev/null 2>&1
rc_is "labelled + no disposition -> refused" $? 2
out=$(mkgh yes; r 33 "Done" 2>&1)
case "$out" in *"still needed for task tracking"*) ok "and gives the instruction verbatim" ;;
  *) bad "and gives the instruction verbatim" "$out" ;; esac
if called "issue comment"; then bad "and posts nothing"; else ok "and posts nothing"; fi

# --- --clears: label off, issue stays open -----------------------------------
mkgh yes
r 33 "Done, on branch X" --clears >/dev/null 2>&1
rc_is "--clears -> 0" $? 0
if called "remove-label needs-human"; then ok "removes the label"; else bad "removes the label" "$(cat "$TMP/calls")"; fi
if called "issue close"; then bad "but does NOT close the issue"; else ok "but does NOT close the issue"; fi

# --- --closes: label off AND closed ------------------------------------------
mkgh yes
r 33 "Superseded by the rewrite" --closes >/dev/null 2>&1
rc_is "--closes -> 0" $? 0
if called "remove-label needs-human"; then ok "closes: removes the label too"; else bad "closes: removes the label too"; fi
if called "issue close"; then ok "and closes the issue"; else bad "and closes the issue"; fi

# --- --keeps: label stays, and the thread says why ---------------------------
mkgh yes
r 33 "Acted on the first half" --keeps "still need the DNS record" >/dev/null 2>&1
rc_is "--keeps -> 0" $? 0
if called "remove-label"; then bad "keeps does not touch the label"; else ok "keeps does not touch the label"; fi
out=$(mkgh yes; r 33 "Acted" --keeps "still need the DNS record" --dry-run 2>&1)
case "$out" in *"Still needs you:"*"DNS record"*) ok "and the reason lands in the reply" ;;
  *) bad "and the reason lands in the reply" "$out" ;; esac

# --- mutually exclusive -------------------------------------------------------
mkgh yes
r 33 "x" --clears --keeps "y" >/dev/null 2>&1
rc_is "--clears with --keeps -> refused" $? 2

# --- an issue WITHOUT the label needs no disposition -------------------------
# Demanding one everywhere would make ordinary PR replies impossible.
mkgh no
r 44 "Fixed in abc1234" >/dev/null 2>&1
rc_is "unlabelled issue replies freely" $? 0
if called "issue comment"; then ok "and the comment is posted"; else bad "and the comment is posted"; fi

# --- the label is only removed if the comment succeeded ----------------------
# Otherwise a failed reply leaves the issue looking unblocked with nothing said.
cat > "$TMP/bin/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$TMP/calls"
case "\$1 \$2" in
  "issue view") echo needs-human; exit 0 ;;
  "issue comment") exit 1 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"; : > "$TMP/calls"
r 33 "Done" --clears >/dev/null 2>&1
# 2, not 1. The old value was whatever gh happened to return; now the write goes
# through the provider and reports the house code for "could not complete it",
# the same one backlog-claim and backlog-release use for a failed write. The
# assertion this case actually makes -- non-zero, and the label untouched -- is
# unchanged. Recorded because a refactor that quietly moves an exit code is the
# kind of thing a caller finds out about later.
rc_is "a failed comment -> non-zero" $? 2
if called "remove-label"; then bad "and the label is NOT removed"; else ok "and the label is NOT removed"; fi

# --- close reasons ------------------------------------------------------------
# "done", "superseded" and "won't do" read completely differently in a backlog
# six weeks later, and GitHub records the difference.
mkgh yes
r 33 "Superseded" --closes --as duplicate >/dev/null 2>&1
rc_is "--closes --as duplicate -> 0" $? 0
if called "reason duplicate"; then ok "passes the reason to gh"; else bad "passes the reason to gh" "$(cat "$TMP/calls")"; fi
mkgh yes
r 33 "Done" --closes >/dev/null 2>&1
if called "reason completed"; then ok "defaults to completed"; else bad "defaults to completed"; fi
mkgh yes
r 33 "x" --closes --as nonsense >/dev/null 2>&1
rc_is "an unknown reason -> refused" $? 2
mkgh yes
r 33 "x" --as duplicate >/dev/null 2>&1
rc_is "--as without --closes -> refused" $? 2

# --- #59: --closes must not depend on the label being there -----------------
#
# The close was nested two levels inside the HAS_LABEL branch. --closes sets both
# CLOSES and CLEARS, so on an issue WITHOUT needs-human the outer condition was
# false and both statements were skipped: comment posted, issue open, nothing
# printed, exit 0. A flag accepted and silently ignored.
#
# Worth naming as a class: three earlier defects here were swallowed
# diagnostics. This one had no error to swallow, because the code did not run.
mkgh no; : > "$TMP/calls"
r 58 "Closing, wrong repo." --closes --as not-planned >/dev/null 2>&1
rc_is "--closes on an UNLABELLED issue -> 0" $? 0
called "issue close 58" && ok "and the close actually happens" \
  || bad "close attempted without needs-human" "$(cat "$TMP/calls")"
called "remove-label" && bad "removed a label the issue never had" "$(cat "$TMP/calls")" \
  || ok "and no label is removed, since there was none"

mkgh no; : > "$TMP/calls"
case "$(r 58 "Closing." --closes 2>&1)" in
  *"Closed #58"*) ok "and it says so, rather than printing nothing" ;;
  *) bad "reports the close" "$(r 58 "Closing." --closes 2>&1)" ;; esac

# The ordering the original comment protects must survive the flattening:
# comment first, then label, then close.
mkgh yes; : > "$TMP/calls"
r 33 "Done." --closes >/dev/null 2>&1
c=$(grep -n 'issue comment' "$TMP/calls" | head -1 | cut -d: -f1)
l=$(grep -n 'remove-label' "$TMP/calls" | head -1 | cut -d: -f1)
x=$(grep -n 'issue close' "$TMP/calls" | head -1 | cut -d: -f1)
if [ -n "$c" ] && [ -n "$l" ] && [ -n "$x" ] && [ "$c" -lt "$l" ] && [ "$l" -lt "$x" ]; then
  ok "comment, then label, then close -- the order still holds"
else bad "ordering preserved" "comment=$c label=$l close=$x"; fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
