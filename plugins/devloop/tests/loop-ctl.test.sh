#!/bin/sh
# Exercise loop-ctl without a Mac: launchctl is faked, and the plist it writes is
# parsed as a real plist rather than eyeballed.
#
#   sh plugins/devloop/tests/loop-ctl.test.sh
#
# The plist is the part that fails silently. launchd does not run a job whose
# plist is malformed and does not say so, so "it parses" is the assertion that
# matters most here.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/loop-ctl
TMP=${TMPDIR:-/tmp}/loop-ctl-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

printf '#!/bin/sh\necho "$*" >> "%s/launchctl.log"\nexit 0\n' "$TMP" > "$TMP/bin/launchctl"
chmod +x "$TMP/bin/launchctl"
FAKE_CLAUDE=$TMP/bin/claude
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CLAUDE"; chmod +x "$FAKE_CLAUDE"

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }
rc_is(){ if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, wanted $3"; fi; }

# run <home-suffix> <args...>  -- each install gets a clean HOME
run() {
  h=$TMP/$1; shift
  mkdir -p "$h/Library/LaunchAgents" "$h/loops"
  PATH="$TMP/bin:$PATH" HOME="$h" CLAWDY_LOOP_HOME="$h/loops" \
    CLAWDY_LOOP_CLAUDE="$FAKE_CLAUDE" sh "$BIN" "$@"
}

parses() { # parses <label> <plist>
  if python3 - "$2" <<'PY' >/dev/null 2>&1
import plistlib,sys
d = plistlib.load(open(sys.argv[1],'rb'))
assert d['Label'] and d['ProgramArguments'] and d['StartInterval']
PY
  then ok "$1"; else bad "$1" "plist does not parse: $2"; fi
}

# --- the happy path ---------------------------------------------------------
run h1 install nightly --interval 10m --prompt "work the backlog" --dir "$TMP" >/dev/null 2>&1
rc_is "install -> 0" $? 0
P=$TMP/h1/Library/LaunchAgents/com.clawdy.loop.nightly.plist
[ -f "$P" ] && ok "plist written" || bad "plist written"
parses "plist parses" "$P"
grep -q 'launchctl' /dev/null 2>&1  # noop, keeps shellcheck quiet
if grep -q 'load' "$TMP/launchctl.log" 2>/dev/null; then ok "job is loaded"; else bad "job is loaded"; fi

# The single most common launchd failure: the job cannot find the binary,
# because launchd never reads a shell profile.
if python3 - "$P" <<'PY' >/dev/null 2>&1
import plistlib,sys
d=plistlib.load(open(sys.argv[1],'rb'))
assert d['EnvironmentVariables']['PATH']
assert d['ProgramArguments'][0].startswith('/')
PY
then ok "plist pins PATH and an absolute program"; else bad "plist pins PATH and an absolute program"; fi

# --- paths we do not control must not break the XML -------------------------
# A home directory called "R&D" is legal, and unescaped it yields a plist that
# launchd silently refuses to load.
mkdir -p "$TMP/R&D<x>"
run "R&D<x>" install amp --interval 10m --prompt "p" --dir "$TMP" >/dev/null 2>&1
rc_is "install under an & path -> 0" $? 0
parses "plist with & and < in HOME still parses" \
  "$TMP/R&D<x>/Library/LaunchAgents/com.clawdy.loop.amp.plist"

# --- names are validated, not escaped ---------------------------------------
run h2 install 'a&b' --interval 10m --prompt p >/dev/null 2>&1
rc_is "name with & rejected"   $? 2
run h2 install 'a b' --interval 10m --prompt p >/dev/null 2>&1
rc_is "name with space rejected" $? 2
run h2 install '../esc' --interval 10m --prompt p >/dev/null 2>&1
rc_is "name with path traversal rejected" $? 2
run h2 status 'a&b' >/dev/null 2>&1
rc_is "status validates the name too" $? 2

# --- argument handling ------------------------------------------------------
run h3 install ok1 --interval 30s --prompt p >/dev/null 2>&1
rc_is "sub-minute interval rejected" $? 2
run h3 install ok1 --interval 10m >/dev/null 2>&1
rc_is "missing prompt rejected" $? 2
run h3 install ok1 --interval 10m --prompt p --dir /no/such/dir >/dev/null 2>&1
rc_is "missing --dir rejected" $? 2
run h3 frobnicate >/dev/null 2>&1
rc_is "unknown command -> 2" $? 2

# --- the session id is the conversation; reinstall must not orphan it -------
run h4 install keep --interval 10m --prompt "v1" --dir "$TMP" >/dev/null 2>&1
S1=$(. "$TMP/h4/loops/keep.conf"; echo "$SESSION_ID")
run h4 install keep --interval 20m --prompt "v2" --dir "$TMP" >/dev/null 2>&1
S2=$(. "$TMP/h4/loops/keep.conf"; echo "$SESSION_ID")
if [ "$S1" = "$S2" ] && [ -n "$S1" ]; then ok "reinstall keeps the session id"
else bad "reinstall keeps the session id" "$S1 -> $S2"; fi
V=$(. "$TMP/h4/loops/keep.conf"; echo "$PROMPT")
if [ "$V" = "v2" ]; then ok "reinstall updates the prompt"; else bad "reinstall updates the prompt" "$V"; fi

# --- intervals --------------------------------------------------------------
for pair in "10m 600" "2h 7200" "900s 900" "1200 1200"; do
  iv=${pair%% *}; want=${pair##* }
  run "iv$want" install i --interval "$iv" --prompt p --dir "$TMP" >/dev/null 2>&1
  got=$(. "$TMP/iv$want/loops/i.conf"; echo "$INTERVAL")
  if [ "$got" = "$want" ]; then ok "interval $iv -> ${want}s"; else bad "interval $iv -> ${want}s" "got $got"; fi
done

# --- status reports a stall ------------------------------------------------
now=$(date +%s)
printf '%s 5\n' "$((now - 16800))" > "$TMP/h1/loops/nightly.state"
out=$(run h1 status nightly 2>&1); rc=$?
rc_is "status exits 1 when stalled" "$rc" 1
if printf '%s' "$out" | grep -q 'STALLED'; then ok "status says STALLED"; else bad "status says STALLED" "$out"; fi
printf '%s 5\n' "$((now - 60))" > "$TMP/h1/loops/nightly.state"
run h1 status nightly >/dev/null 2>&1
rc_is "status exits 0 when healthy" $? 0

# --- the cron path, for hosts with no launchd -------------------------------
# A fake crontab backed by a file, so the managed-block edit can be asserted
# without touching the real one.
CRONFILE=$TMP/crontab.txt; : > "$CRONFILE"
cat > "$TMP/bin/crontab" <<EOF
#!/bin/sh
if [ "\${1:-}" = "-l" ]; then cat "$CRONFILE"; else cat > "$CRONFILE"; fi
EOF
chmod +x "$TMP/bin/crontab"
mv "$TMP/bin/launchctl" "$TMP/bin/launchctl.off"

# A line the user owns, which must survive every edit we make.
echo "0 3 * * * /usr/local/bin/backup.sh" > "$CRONFILE"

runcron() { h=$TMP/$1; shift; mkdir -p "$h/loops"
  PATH="$TMP/bin:$PATH" HOME="$h" CLAWDY_LOOP_HOME="$h/loops" \
    CLAWDY_LOOP_CLAUDE="$FAKE_CLAUDE" sh "$BIN" "$@"; }

runcron c1 install cronny --interval 10m --prompt "p" --dir "$TMP" >/dev/null 2>&1
rc_is "cron install -> 0" $? 0
if grep -q '^\*/10 \* \* \* \*' "$CRONFILE"; then ok "cron expression is */10"; else bad "cron expression is */10" "$(cat "$CRONFILE")"; fi
if grep -q 'CLAWDY_LOOP_CLAUDE=' "$CRONFILE"; then ok "cron line pins CLAWDY_LOOP_CLAUDE"; else bad "cron line pins CLAWDY_LOOP_CLAUDE"; fi
if grep -q 'backup.sh' "$CRONFILE"; then ok "the user's own cron line survives"; else bad "the user's own cron line survives"; fi
if [ "$(grep -c 'BEGIN clawdy-loop cronny' "$CRONFILE")" -eq 1 ]; then ok "one managed block"; else bad "one managed block"; fi

# Reinstall must replace the block, not stack a second copy.
runcron c1 install cronny --interval 20m --prompt "p" --dir "$TMP" >/dev/null 2>&1
if [ "$(grep -c 'BEGIN clawdy-loop cronny' "$CRONFILE")" -eq 1 ]; then ok "reinstall replaces, not appends"; else bad "reinstall replaces, not appends" "$(cat "$CRONFILE")"; fi
if grep -q '^\*/20 ' "$CRONFILE"; then ok "reinstall updates the interval"; else bad "reinstall updates the interval"; fi

# Intervals cron cannot express must be rounded, not silently drifted.
runcron c1 install seven --interval 7m --prompt p --dir "$TMP" 2>"$TMP/warn" >/dev/null
if grep -q 'rounded' "$TMP/warn"; then ok "7m is rounded, and says so"; else bad "7m is rounded, and says so" "$(cat "$TMP/warn")"; fi
if grep -q '60 %' /dev/null 2>&1; then :; fi
if grep -qE '^\*/(5|6) ' "$CRONFILE"; then ok "7m lands on a clean divisor"; else bad "7m lands on a clean divisor" "$(grep -A1 'BEGIN clawdy-loop seven' "$CRONFILE")"; fi

runcron c1 uninstall cronny >/dev/null 2>&1
if grep -q 'BEGIN clawdy-loop cronny' "$CRONFILE"; then bad "uninstall removes the block"; else ok "uninstall removes the block"; fi
if grep -q 'backup.sh' "$CRONFILE"; then ok "uninstall keeps the user's line"; else bad "uninstall keeps the user's line"; fi

# A host with neither scheduler must fail loudly and point at send_later.
#
# Hiding the stubs is not enough. runcron PATHs the sandbox in FRONT of the
# host's, so a real /usr/bin/crontab -- present on most Linux, including the CI
# runner -- answers `have crontab` and this case passes for the wrong reason. It
# did exactly that: green here, red the first time it ran anywhere with cron.
# So this one case gets a PATH with nothing on it but what loop-ctl needs, and
# asserts the absence rather than assuming it.
BARE="sh sed grep awk cat tail tr rm mkdir date id dirname basename chmod sleep"
mkdir -p "$TMP/bare"
for b in $BARE; do
  src=$(command -v "$b") || { echo "loop-ctl.test: $b not found on this host" >&2; exit 1; }
  ln -sf "$src" "$TMP/bare/$b"
done
# uuidgen is optional -- loop-ctl falls back to /proc/sys/kernel/random/uuid.
src=$(command -v uuidgen) && ln -sf "$src" "$TMP/bare/uuidgen"
for leak in crontab launchctl; do
  if PATH="$TMP/bare" command -v "$leak" >/dev/null 2>&1; then
    echo "loop-ctl.test: $leak leaked into the bare sandbox; the case below would be meaningless" >&2
    exit 1
  fi
done
runbare() { h=$TMP/$1; shift; mkdir -p "$h/loops"
  PATH="$TMP/bare" HOME="$h" CLAWDY_LOOP_HOME="$h/loops" \
    CLAWDY_LOOP_CLAUDE="$FAKE_CLAUDE" sh "$BIN" "$@"; }
out=$(runbare c2 install nope --interval 10m --prompt p --dir "$TMP" 2>&1); rc=$?
rc_is "no scheduler at all -> 2" "$rc" 2
if printf '%s' "$out" | grep -q 'send_later'; then ok "and points at send_later"; else bad "and points at send_later" "$out"; fi
mv "$TMP/bin/launchctl.off" "$TMP/bin/launchctl"

# --- --dir must reach the runtime, not just the scheduler --------------------
# WORKDIR was written into the launchd plist and the crontab line and NOWHERE
# ELSE. loop-run never chdir'd, so its working directory was whatever the caller
# had -- and `doctor` calls it straight from the operator's shell.
#
# That tick is the FIRST one, so it consumes the bootstrap --session-id and
# writes the state file. Every scheduled tick afterwards runs --resume against a
# session created under a different project directory. The loop is dead, and the
# check whose own comment says "only this is sufficient" certified it.
mkloop_dir() {
  rm -rf "$TMP/lh" "$TMP/proj" "$TMP/elsewhere"
  mkdir -p "$TMP/lh" "$TMP/proj" "$TMP/elsewhere" "$TMP/bin"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/launchctl"; chmod +x "$TMP/bin/launchctl"
  ( cd "$TMP/proj" && git init -q . && git commit -q --allow-empty -m base ) 2>/dev/null
}

mkloop_dir
( cd "$TMP/elsewhere" && CLAWDY_LOOP_HOME="$TMP/lh" PATH="$TMP/bin:$PATH" \
  sh "$BIN" install dirtest --dir "$TMP/proj" --interval 10m --prompt tick ) >/dev/null 2>&1
case "$(cat "$TMP/lh/dirtest.conf" 2>/dev/null)" in
  *WORKDIR=*) ok "--dir is recorded in the conf, not only the scheduler entry" ;;
  *) bad "WORKDIR in conf" "$(cat "$TMP/lh/dirtest.conf" 2>/dev/null | tr '\n' ' ')" ;;
esac

# The runtime must actually go there. A fake claude records its cwd.
printf '#!/bin/sh\nprintf "%%s\\n" "$PWD" >> "%s/cwd.log"\nexit 0\n' "$TMP" > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
: > "$TMP/cwd.log"
( cd "$TMP/elsewhere" && CLAWDY_LOOP_HOME="$TMP/lh" CLAWDY_LOOP_CLAUDE="$TMP/bin/claude" \
  PATH="$TMP/bin:$PATH" sh "$HERE/../bin/loop-run" dirtest ) >/dev/null 2>&1
tickcwd=$(head -1 "$TMP/cwd.log" 2>/dev/null)
case "$tickcwd" in
  "$TMP/proj") ok "loop-run runs the tick in the recorded workdir" ;;
  *) bad "loop-run chdirs to WORKDIR" "ran in: ${tickcwd:-<nothing>}" ;;
esac

# ...including when invoked from somewhere else entirely, which is exactly what
# doctor does.
mkloop_dir
( cd "$TMP/elsewhere" && CLAWDY_LOOP_HOME="$TMP/lh" PATH="$TMP/bin:$PATH" \
  sh "$BIN" install dirtest2 --dir "$TMP/proj" --interval 10m --prompt tick ) >/dev/null 2>&1
: > "$TMP/cwd.log"
( cd / && CLAWDY_LOOP_HOME="$TMP/lh" CLAWDY_LOOP_CLAUDE="$TMP/bin/claude" \
  PATH="$TMP/bin:$PATH" sh "$HERE/../bin/loop-run" dirtest2 ) >/dev/null 2>&1
tickcwd=$(head -1 "$TMP/cwd.log" 2>/dev/null)
case "$tickcwd" in
  "$TMP/proj") ok "and from an unrelated cwd, so doctor proves the real thing" ;;
  *) bad "loop-run from / uses WORKDIR" "ran in: ${tickcwd:-<nothing>}" ;;
esac

# A loop installed with no --dir keeps today's behaviour: the install cwd.
mkloop_dir
( cd "$TMP/proj" && CLAWDY_LOOP_HOME="$TMP/lh" PATH="$TMP/bin:$PATH" \
  sh "$BIN" install nodir --interval 10m --prompt tick ) >/dev/null 2>&1
: > "$TMP/cwd.log"
( cd / && CLAWDY_LOOP_HOME="$TMP/lh" CLAWDY_LOOP_CLAUDE="$TMP/bin/claude" \
  PATH="$TMP/bin:$PATH" sh "$HERE/../bin/loop-run" nodir ) >/dev/null 2>&1
tickcwd=$(head -1 "$TMP/cwd.log" 2>/dev/null)
case "$tickcwd" in
  "$TMP/proj") ok "with no --dir the install directory is recorded and used" ;;
  *) bad "no --dir defaults to install cwd" "ran in: ${tickcwd:-<nothing>}" ;;
esac

# The pinned binary, for the same reason. doctor inherited whatever
# CLAWDY_LOOP_CLAUDE the operator's shell had -- usually unset -- and so
# certified `claude` from PATH, which may not be what launchd runs.
mkloop_dir
printf '#!/bin/sh\nprintf "PINNED\\n" >> "%s/which.log"\nexit 0\n' "$TMP" > "$TMP/bin/pinned-claude"
chmod +x "$TMP/bin/pinned-claude"
printf '#!/bin/sh\nprintf "PATHCLAUDE\\n" >> "%s/which.log"\nexit 0\n' "$TMP" > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
( cd "$TMP/elsewhere" && CLAWDY_LOOP_HOME="$TMP/lh" CLAWDY_LOOP_CLAUDE="$TMP/bin/pinned-claude" \
  PATH="$TMP/bin:$PATH" sh "$BIN" install pinned --dir "$TMP/proj" --interval 10m --prompt tick ) >/dev/null 2>&1
: > "$TMP/which.log"
# Deliberately NOT setting CLAWDY_LOOP_CLAUDE -- this is doctor's situation.
( cd / && CLAWDY_LOOP_HOME="$TMP/lh" PATH="$TMP/bin:$PATH" \
  sh "$HERE/../bin/loop-run" pinned ) >/dev/null 2>&1
case "$(head -1 "$TMP/which.log" 2>/dev/null)" in
  PINNED) ok "an unset env var falls back to the pinned binary, not PATH" ;;
  *) bad "pinned binary used" "ran: $(head -1 "$TMP/which.log" 2>/dev/null || echo nothing)" ;;
esac
# An explicit env var must still win, or nothing can be tested or overridden.
: > "$TMP/which.log"
( cd / && CLAWDY_LOOP_HOME="$TMP/lh" CLAWDY_LOOP_CLAUDE="$TMP/bin/claude" PATH="$TMP/bin:$PATH" \
  sh "$HERE/../bin/loop-run" pinned ) >/dev/null 2>&1
case "$(head -1 "$TMP/which.log" 2>/dev/null)" in
  PATHCLAUDE) ok "and an explicit env var still overrides it" ;;
  *) bad "env override" "ran: $(head -1 "$TMP/which.log" 2>/dev/null || echo nothing)" ;;
esac

# A workdir that has since been deleted must fail loudly, not run somewhere else.
mkloop_dir
( cd "$TMP/elsewhere" && CLAWDY_LOOP_HOME="$TMP/lh" PATH="$TMP/bin:$PATH" \
  sh "$BIN" install gone --dir "$TMP/proj" --interval 10m --prompt tick ) >/dev/null 2>&1
rm -rf "$TMP/proj"
out=$( cd / && CLAWDY_LOOP_HOME="$TMP/lh" CLAWDY_LOOP_CLAUDE="$TMP/bin/claude" \
       PATH="$TMP/bin:$PATH" sh "$HERE/../bin/loop-run" gone 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && ok "a vanished workdir fails rather than running elsewhere" \
  || bad "vanished workdir" "exit $rc: $out"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
