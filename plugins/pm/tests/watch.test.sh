#!/bin/sh
# The heartbeat. A loop whose last step is "remember to re-arm" stops the first
# time it is forgotten, and the failure is silent -- no prompt, no error.
#
#   sh plugins/pm/tests/watch.test.sh
#
# gh is faked, so every case is about what backlog-watch does with what it is
# told, not about any repository.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
TMP=${TMPDIR:-/tmp}/watch-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

. "$HERE/lib/gh-free.sh"
PATH=$(gh_free_path "$TMP/nogh"); export PATH

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"
        [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

# The provider calls `gh issue list --json ...`, so the fake answers in that
# shape: a JSON array the case controls. provider_issues lists OPEN issues only,
# which is why a close arrives here as a disappearance rather than a state flip.
ISSUES=$TMP/issues.json
cat > "$TMP/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "issue list") cat "$ISSUES" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
printf '[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","title":"A thing"}]\n' > "$ISSUES"

watch() { PATH="$TMP/bin:$PATH" PM_ASSUME_DEPS=1 sh "$BIN/backlog-watch" \
            --repo o/n --state "$1" --interval 1 --max-wait 2 2>&1; }

# --- the first run must say nothing ------------------------------------------
# Without this, every re-arm after a quiet exit replays the whole backlog as
# news, and the agent acts on an "event" that is just the repository existing.
S=$TMP/s1
out=$(watch "$S")
case "$out" in *EVENT*) bad "a first run emits nothing" "$out" ;;
               *) ok "a first run emits nothing" ;; esac
case "$out" in *"quiet, re-arm"*) ok "and says to re-arm" ;;
               *) bad "and says to re-arm" "$out" ;; esac
[ -s "$S/seen" ] && ok "but it does record what it saw" \
                || bad "but it does record what it saw" "state is empty"

# --- a quiet second run ------------------------------------------------------
out=$(watch "$S")
case "$out" in *EVENT*) bad "nothing changed, nothing emitted" "$out" ;;
               *) ok "nothing changed, nothing emitted" ;; esac

# --- a new issue -------------------------------------------------------------
printf '[{"number":42,"updatedAt":"2026-01-01T00:00:00Z","title":"A thing"},{"number":43,"updatedAt":"2026-01-02T00:00:00Z","title":"Brand new"}]\n' > "$ISSUES"
out=$(watch "$S")
case "$out" in *"issue#43 NEW"*) ok "a new issue is reported as NEW" ;;
               *) bad "a new issue is reported as NEW" "$out" ;; esac
case "$out" in *"Brand new"*) ok "and names it, so the turn need not go and look" ;;
               *) bad "and names it" "$out" ;; esac

# --- activity on a known issue is NOT new ------------------------------------
# The distinction matters: "new" means triage it, "updated" usually means
# somebody answered something.
printf '[{"number":42,"updatedAt":"2026-06-06T00:00:00Z","title":"A thing"},{"number":43,"updatedAt":"2026-01-02T00:00:00Z","title":"Brand new"}]\n' > "$ISSUES"
out=$(watch "$S")
case "$out" in
  *"issue#42 NEW"*) bad "a known issue that moved is not NEW" "$out" ;;
  *"issue#42 updated"*) ok "a known issue that moved is reported as updated" ;;
  *) bad "a known issue that moved is reported as updated" "$out" ;;
esac

# --- a close is activity, not a disappearance --------------------------------
printf '[{"number":43,"updatedAt":"2026-01-02T00:00:00Z","title":"Brand new"}]\n' > "$ISSUES"
out=$(watch "$S")
case "$out" in *"issue#42 closed or no longer listed"*) ok "a close wakes the loop" ;;
               *) bad "a close wakes the loop" "$out" ;; esac

# --- an unreachable backend is not a quiet backlog ---------------------------
# Treating "could not reach it" as "nothing happened" is how a loop sleeps
# through an outage and reports itself healthy.
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
rc=$(watch "$TMP/dead" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "an unreachable backend exits 2, not 0" \
                || bad "an unreachable backend exits 2, not 0" "exit $rc"
cat > "$TMP/bin/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "issue list") cat "$ISSUES" ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"

# --- two watchers do not share one memory ------------------------------------
# A second agent on the same repo has its own idea of what it has seen; sharing
# the file means the second one is told nothing happened.
S2=$TMP/s2
out=$(watch "$S2")
case "$out" in *EVENT*) bad "a fresh state seeds rather than replaying" "$out" ;;
               *) ok "a fresh state seeds rather than replaying" ;; esac

# --- usage -------------------------------------------------------------------
rc=$(PATH="$TMP/bin:$PATH" sh "$BIN/backlog-watch" --nonsense >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "an unknown option exits 2" || bad "an unknown option exits 2" "exit $rc"

# Both outcomes exit 0, because both mean the same thing to the caller: re-arm.
rc=$(watch "$S" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "a quiet expiry still exits 0" || bad "a quiet expiry still exits 0" "exit $rc"
printf '[{"number":99,"updatedAt":"2026-09-09T00:00:00Z","title":"Another"}]\n' > "$ISSUES"
rc=$(watch "$S" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "and so does an event" || bad "and so does an event" "exit $rc"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
