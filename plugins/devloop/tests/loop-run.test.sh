#!/bin/sh
# Exercise loop-run's gate logic without spending a single Claude turn.
#
#   sh plugins/devloop/tests/loop-run.test.sh
#
# CLAWDY_LOOP_CLAUDE points at a fake `claude` that records its argv, so the two
# things that actually matter can be asserted: that the first tick bootstraps a
# session and later ticks resume it, and that a missed tick is detected and told
# to the agent rather than written to a log nobody reads.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/loop-run
TMP=${TMPDIR:-/tmp}/loop-run-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

export CLAWDY_LOOP_HOME=$TMP/home
mkdir -p "$CLAWDY_LOOP_HOME"

# Fake claude: records argv, and fails on demand so the failure path is covered.
FAKE=$TMP/fake-claude
cat > "$FAKE" <<'EOF'
#!/bin/sh
: > "$ARGV_FILE"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGV_FILE"; done
[ "${FAKE_CLAUDE_RC:-0}" -eq 0 ] || exit "$FAKE_CLAUDE_RC"
echo "fake claude ok"
EOF
chmod +x "$FAKE"
export CLAWDY_LOOP_CLAUDE=$FAKE
export ARGV_FILE=$TMP/argv

fails=0 ran=0
ok()   { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad()  { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', wanted '$3'"; fi; }
rc_is(){ if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, wanted $3"; fi; }
# -- before the pattern, or grep reads "--resume" as its own option and every
# assertion silently inverts: the search errors out, and `hasnt` then passes for
# the wrong reason.
has()  { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "missing: $3"; fi; }
hasnt(){ if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "unexpectedly present: $3"; else ok "$1"; fi; }

mkconf() { # mkconf <name> <interval>
  cat > "$CLAWDY_LOOP_HOME/$1.conf" <<EOF
SESSION_ID=11111111-2222-3333-4444-555555555555
INTERVAL=$2
PROMPT='work the backlog'
EOF
}

# --- misconfiguration is exit 2, never a silent no-op -----------------------
sh "$BIN" nosuch >/dev/null 2>&1; rc_is "missing config -> 2" $? 2
sh "$BIN" >/dev/null 2>&1;        rc_is "no name -> 2"        $? 2
printf 'INTERVAL=600\n' > "$CLAWDY_LOOP_HOME/noid.conf"
sh "$BIN" noid >/dev/null 2>&1;   rc_is "no SESSION_ID -> 2"  $? 2
printf 'SESSION_ID=x\n' > "$CLAWDY_LOOP_HOME/noprompt.conf"
sh "$BIN" noprompt >/dev/null 2>&1; rc_is "no PROMPT -> 2"    $? 2

# --- first tick bootstraps, second resumes ----------------------------------
mkconf bt 600
sh "$BIN" bt >/dev/null 2>&1; rc_is "first tick -> 0" $? 0
has  "first tick uses --session-id" "$ARGV_FILE" "--session-id"
hasnt "first tick does not resume"  "$ARGV_FILE" "--resume"

sh "$BIN" bt >/dev/null 2>&1; rc_is "second tick -> 0" $? 0
has  "second tick uses --resume"        "$ARGV_FILE" "--resume"
hasnt "second tick does not bootstrap"  "$ARGV_FILE" "--session-id"

is "tick count advances" "$(awk '{print $2}' "$CLAWDY_LOOP_HOME/bt.state")" 2

# --- the point of the whole thing: a missed tick is detected -----------------
# The clock is pinned for these. Sampling date here and again inside loop-run
# leaves a one-second race, which at the exact 2x boundary flips the result.
mkconf gap 600
now=1800000000
export LOOP_RUN_NOW=$now
# Last tick 4h 40m ago, interval 10m -- the incident's shape exactly.
printf '%s 5\n' "$((now - 16800))" > "$CLAWDY_LOOP_HOME/gap.state"
out=$(sh "$BIN" gap --dry-run 2>&1)
printf '%s' "$out" > "$TMP/gapout"
has "4h40m gap is reported"        "$TMP/gapout" "4h 40m"
has "missed ticks are counted"     "$TMP/gapout" "MISSED"
has "the agent is told, in prompt" "$TMP/gapout" "did not fire"
has "and told to distrust memory"  "$TMP/gapout" "re-read state from disk"

# A gap inside one interval is normal and must stay silent, or the warning
# becomes noise and gets ignored the one time it matters.
mkconf ok1 600
printf '%s 5\n' "$((now - 300))" > "$CLAWDY_LOOP_HOME/ok1.state"
sh "$BIN" ok1 --dry-run > "$TMP/okout" 2>&1
hasnt "a normal gap warns about nothing" "$TMP/okout" "MISSED"
hasnt "and does not pad the prompt"      "$TMP/okout" "did not fire"

# Exactly 2x interval is still not a miss; 2x+1s is.
mkconf edge 600
printf '%s 1\n' "$((now - 1200))" > "$CLAWDY_LOOP_HOME/edge.state"
sh "$BIN" edge --dry-run > "$TMP/e1" 2>&1
hasnt "exactly 2 intervals is not a miss" "$TMP/e1" "MISSED"
printf '%s 1\n' "$((now - 1201))" > "$CLAWDY_LOOP_HOME/edge.state"
sh "$BIN" edge --dry-run > "$TMP/e2" 2>&1
has "just over 2 intervals is a miss" "$TMP/e2" "MISSED"

# --- overlap: two ticks must never share one transcript ---------------------
unset LOOP_RUN_NOW
mkconf lk 600
mkdir "$CLAWDY_LOOP_HOME/lk.lock"
sh "$BIN" lk >/dev/null 2>&1; rc_is "held lock -> 3, not 0" $? 3
rmdir "$CLAWDY_LOOP_HOME/lk.lock"
sh "$BIN" lk >/dev/null 2>&1; rc_is "lock released -> 0"    $? 0
[ -d "$CLAWDY_LOOP_HOME/lk.lock" ] && bad "lock is released on exit" || ok "lock is released on exit"

# --- a failing tick is still a tick -----------------------------------------
# The stamp must be written even on failure. Skipping it would make an
# application error indistinguishable from the scheduler never having run.
mkconf fl 600
FAKE_CLAUDE_RC=7 sh "$BIN" fl >/dev/null 2>&1; rc_is "failed tick -> 1" $? 1
[ -f "$CLAWDY_LOOP_HOME/fl.state" ] && ok "failed tick still records a stamp" \
  || bad "failed tick still records a stamp"

# --- dry-run touches nothing ------------------------------------------------
mkconf dr 600
: > "$ARGV_FILE"
sh "$BIN" dr --dry-run >/dev/null 2>&1; rc_is "dry-run -> 0" $? 0
is "dry-run does not invoke claude" "$(wc -c < "$ARGV_FILE" | tr -d ' ')" 0
[ -f "$CLAWDY_LOOP_HOME/dr.state" ] && bad "dry-run writes no state" || ok "dry-run writes no state"

unset LOOP_RUN_NOW

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
