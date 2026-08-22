#!/bin/sh
# statusline: cost appears on Bedrock and on DeepSeek, priced from the public
# rate card; the tier and currency are env-tunable. date is faked so the
# auto tier is deterministic.
#
#   sh plugins/statusline/tests/statusline.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/claude-statusline
TMP=${TMPDIR:-/tmp}/statusline-test.$$
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/tx"
trap 'rm -rf "$TMP"' EXIT INT TERM

# A PATH containing only what the script uses, so the host's real tools
# cannot leak in. date is faked to answer `date -u '+%H %w'`.
for b in cat jq awk tr sh; do
  src=$(command -v "$b") || { echo "statusline.test: $b not found on this host" >&2; exit 1; }
  ln -sf "$src" "$TMP/bin/$b"
done
cat > "$TMP/bin/date" <<'EOF'
#!/bin/sh
# The script's one date call. Anything else is a contract break; run()
# captures stderr, so a break fails the assertions with the diagnostic.
case "$*" in
  '-u +%H %w') printf '%s %s\n' "$FAKE_UTC_HOUR" "$FAKE_UTC_DOW" ;;
  *) echo "date called with: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/date"

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }

# Case knobs, reset before every case; run() exports them. The default clock
# is Wed 02:00 UTC = Beijing 10:00 -- a weekday peak hour, the tier a case
# that forgets to set the clock should trip over.
reset_knobs() {
  DSR=auto CUR='$' FX=1 MODE=auto USE_BEDROCK=0 FAKE_UTC_HOUR=2 FAKE_UTC_DOW=3
}

run() {
  printf '%s' "$1" |
    PATH="$TMP/bin" TMPDIR="$TMP/state" FAKE_UTC_HOUR="${FAKE_UTC_HOUR:-2}" FAKE_UTC_DOW="${FAKE_UTC_DOW:-3}" \
    CLAUDE_STATUSLINE_DEEPSEEK_RATE="${DSR:-auto}" \
    CLAUDE_STATUSLINE_CURRENCY="${CUR:-\$}" CLAUDE_STATUSLINE_FX_RATE="${FX:-1}" \
    CLAUDE_STATUSLINE_COST="${MODE:-auto}" CLAUDE_CODE_USE_BEDROCK="${USE_BEDROCK:-0}" \
    sh "$BIN" 2>&1
}

# F <id> <in-tokens> <out-tokens> <session-id> <transcript-path> [display-name]
F() {
  printf '{"model":{"id":"%s","display_name":"%s"},"context_window":{"used_percentage":42,"total_input_tokens":%s,"total_output_tokens":%s},"cost":{"total_cost_usd":1.23},"session_id":"%s","transcript_path":"%s"}' \
    "$1" "${6:-$1}" "$2" "$3" "$4" "$5"
}

assert() { # assert <name> <expected> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2
got:      $3"; fi
}

# Transcript fixtures: t1 = one user line, t2 = two user lines.
printf '%s\n' '{"type":"user","message":{"role":"user"}}' > "$TMP/tx/t1.jsonl"
printf '%s\n' '{"type":"user","message":{"role":"user"}}' '{"type":"user","message":{"role":"user"}}' > "$TMP/tx/t2.jsonl"

# --- nobody is billed per token: no cost line --------------------------------
reset_knobs
got=$(run "$(F claude-opus-4-5 1000000 100000 c1 '')")
assert "anthropic model, auto: no cost line" \
  '[claude-opus-4-5] 42% context | in:1.0M out:100.0k' "$got"

# --- bedrock path unchanged --------------------------------------------------
reset_knobs
got=$(run "$(F bedrock-claude-opus-4-5 1000000 100000 c2 '')")
assert "bedrock model: cost from total_cost_usd" \
  '[bedrock-claude-opus-4-5] 42% context | in:1.0M out:100.0k | total: $1.23 | turn: +$0.0000' "$got"

reset_knobs; USE_BEDROCK=1
got=$(run "$(F claude-opus-4-5 1000000 100000 c3 '')")
assert "bedrock env flag: cost shown" \
  '[claude-opus-4-5] 42% context | in:1.0M out:100.0k | total: $1.23 | turn: +$0.0000' "$got"

# --- deepseek-v4-pro, fixed tiers ---------------------------------------------
reset_knobs; DSR=offpeak
got=$(run "$(F 'deepseek-v4-pro[1m]' 1000000 1000000 c4 '')")
assert "v4-pro off-peak: 0.66+1.98=2.64" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M | total: $2.64 | turn: +$0.0000' "$got"

reset_knobs; DSR=peak
got=$(run "$(F 'deepseek-v4-pro[1m]' 1000000 1000000 c5 '')")
assert "v4-pro peak: 2x off-peak" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M | total: $5.28 | turn: +$0.0000' "$got"

# --- auto tier, table-driven over the faked clock ---------------------------
# The script reads date -u '+%H %w' (UTC hour, UTC weekday; 0=Sun..6=Sat).
# Beijing is UTC+8, and the +8 never crosses a date inside the peak windows,
# so the UTC weekday is safe. 1M input at peak = $1.32, off-peak = $0.66.
tier_case() { # <utc-hour> <utc-dow> <expected-total>
  reset_knobs; FAKE_UTC_HOUR=$1; FAKE_UTC_DOW=$2
  got=$(run "$(F 'deepseek-v4-pro[1m]' 1000000 0 "t$1$2" '')")
  assert "UTC $1 dow $2: $3" \
    "[deepseek-v4-pro[1m]] 42% context | in:1.0M out:0 | total: \$$3 | turn: +\$0.0000" "$got"
}

tier_case 01 3 1.32   # Wed, Beijing 09: morning window opens
tier_case 02 3 1.32   # Wed, Beijing 10
tier_case 06 3 1.32   # Wed, Beijing 14: afternoon window opens
tier_case 09 3 1.32   # Wed, Beijing 17: inner edge
tier_case 10 3 0.66   # Wed, Beijing 18: peak ends
tier_case 04 3 0.66   # Wed, Beijing 12: between windows
tier_case 11 3 0.66   # Wed, Beijing 19
tier_case 00 3 0.66   # Wed, Beijing 08: before peak
tier_case 02 1 1.32   # Mon peak -- every weekday peaks
tier_case 02 2 1.32   # Tue peak
tier_case 02 4 1.32   # Thu peak
tier_case 02 5 1.32   # Fri peak
tier_case 01 6 0.66   # Sat, Beijing 09: weekend, morning window
tier_case 06 6 0.66   # Sat, Beijing 14: weekend, afternoon window
tier_case 02 0 0.66   # Sun, Beijing 10
tier_case 06 0 0.66   # Sun, Beijing 14
tier_case 09 0 0.66   # Sun, Beijing 17
tier_case 01 1 1.32   # Mon, Beijing 09: peak again after the weekend
tier_case 16 5 0.66   # Fri UTC 16 = Beijing Sat 00: +8 crosses the day
tier_case 20 5 0.66   # Fri UTC 20 = Beijing Sat 04
tier_case 23 0 0.66   # Sun UTC 23 = Beijing Mon 07

# --- deepseek-v4-flash ---------------------------------------------------------
reset_knobs; DSR=offpeak
got=$(run "$(F deepseek-v4-flash 1000000 1000000 f1 '')")
assert "v4-flash off-peak: 0.22+0.66=0.88" \
  '[deepseek-v4-flash] 42% context | in:1.0M out:1.0M | total: $0.88 | turn: +$0.0000' "$got"

reset_knobs; DSR=peak
got=$(run "$(F deepseek-v4-flash 1000000 1000000 f2 '')")
assert "v4-flash peak: 2x off-peak" \
  '[deepseek-v4-flash] 42% context | in:1.0M out:1.0M | total: $1.76 | turn: +$0.0000' "$got"

# --- unpriced deepseek ids: no fake number -------------------------------------
reset_knobs; DSR=offpeak
got=$(run "$(F deepseek-v4-flash-vision-exp 1000000 1000000 u1 '')")
assert "vision-exp priced like v4-flash: 0.22+0.66=0.88" \
  '[deepseek-v4-flash-vision-exp] 42% context | in:1.0M out:1.0M | total: $0.88 | turn: +$0.0000' "$got"

reset_knobs
got=$(run "$(F deepseek-chat 1000000 1000000 u2 '')")
assert "legacy deepseek-chat: no cost line" \
  '[deepseek-chat] 42% context | in:1.0M out:1.0M' "$got"

reset_knobs
got=$(run "$(F deepseek-chat 1000000 1000000 u3 '' 'deepseek-v4-pro[1m]')")
assert "unpriced id with priced display: no cost line" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M' "$got"

# --- currency ----------------------------------------------------------------
reset_knobs; DSR=offpeak; CUR='SGD '; FX=1.27
got=$(run "$(F 'deepseek-v4-pro[1m]' 1000000 1000000 s1 '')")
assert "SGD: 2.64 x 1.27 = 3.35" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M | total: SGD 3.35 | turn: +SGD 0.0000' "$got"

reset_knobs; DSR=offpeak; CUR='SGD '; FX='1,27'
got=$(run "$(F 'deepseek-v4-pro[1m]' 1000000 1000000 s2 '')")
assert "comma-decimal FX accepted: 2.64 x 1.27 = 3.35" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M | total: SGD 3.35 | turn: +SGD 0.0000' "$got"

# --- degenerate input -----------------------------------------------------------
reset_knobs
got=$(run '')
assert "empty stdin: base line" '[Claude] 0% context | in:0 out:0' "$got"

reset_knobs
got=$(run '{}')
assert "empty object: base line" '[Claude] 0% context | in:0 out:0' "$got"

# --- per-turn delta, pinned to real turn boundaries -------------------------------
reset_knobs; DSR=offpeak
rm -f "$TMP/state"/claude_statusline_d
got=$(run "$(F 'deepseek-v4-pro[1m]' 1000000 0 d "$TMP/tx/t1.jsonl")")
assert "delta render 1: full cost as first delta" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:0 | total: $0.66 | turn: +$0.6600' "$got"

got=$(run "$(F 'deepseek-v4-pro[1m]' 2000000 0 d "$TMP/tx/t2.jsonl")")
assert "delta render 2: 1.32 - 0.66" \
  '[deepseek-v4-pro[1m]] 42% context | in:2.0M out:0 | total: $1.32 | turn: +$0.6600' "$got"

got=$(run "$(F 'deepseek-v4-pro[1m]' 2500000 0 d "$TMP/tx/t2.jsonl")")
assert "delta render 3: pinned until the next turn" \
  '[deepseek-v4-pro[1m]] 42% context | in:2.5M out:0 | total: $1.65 | turn: +$0.6600' "$got"

reset_knobs; DSR=offpeak; CUR='SGD '; FX=1.27
rm -f "$TMP/state"/claude_statusline_x
run "$(F 'deepseek-v4-pro[1m]' 1000000 0 x "$TMP/tx/t1.jsonl")" >/dev/null
got=$(run "$(F 'deepseek-v4-pro[1m]' 2000000 0 x "$TMP/tx/t2.jsonl")")
assert "FX applies to delta: +SGD 0.8382" \
  '[deepseek-v4-pro[1m]] 42% context | in:2.0M out:0 | total: SGD 1.68 | turn: +SGD 0.8382' "$got"

reset_knobs; DSR=offpeak
rm -f "$TMP/state"/claude_statusline_r
run "$(F 'deepseek-v4-pro[1m]' 1000000 0 r "$TMP/tx/t1.jsonl")" >/dev/null
got=$(run "$(F 'deepseek-v4-pro[1m]' 0 0 r "$TMP/tx/t2.jsonl")")
assert "cost reset: negative delta (pre-existing behaviour)" \
  '[deepseek-v4-pro[1m]] 42% context | in:0 out:0 | total: $0.00 | turn: +$-0.6600' "$got"

# --- locale: LC_ALL=C keeps decimal points, not commas ---------------------------
reset_knobs; DSR=offpeak
got=$(printf '%s' "$(F 'deepseek-v4-pro[1m]' 1000000 1000000 l1 '')" |
  PATH="$TMP/bin" TMPDIR="$TMP/state" LC_NUMERIC=de_DE.UTF-8 \
  CLAUDE_STATUSLINE_DEEPSEEK_RATE=offpeak \
  CLAUDE_STATUSLINE_CURRENCY='$' CLAUDE_STATUSLINE_FX_RATE=1 CLAUDE_STATUSLINE_COST=auto \
  sh "$BIN" 2>&1)
assert "LC_NUMERIC cannot turn dots into commas" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M | total: $2.64 | turn: +$0.0000' "$got"

# --- cost mode interplay -----------------------------------------------------------
reset_knobs; MODE=never; DSR=offpeak
got=$(run "$(F 'deepseek-v4-pro[1m]' 1000000 1000000 n1 '')")
assert "COST_MODE=never suppresses deepseek cost" \
  '[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M' "$got"

reset_knobs; MODE=always
got=$(run "$(F deepseek-chat 1000000 1000000 n2 '')")
assert "COST_MODE=always, unpriced id: 0.00, not a fake estimate" \
  '[deepseek-chat] 42% context | in:1.0M out:1.0M | total: $0.00 | turn: +$0.0000' "$got"

printf '%d ran, %d failed\n' "$ran" "$fails"
[ "$fails" -eq 0 ]
