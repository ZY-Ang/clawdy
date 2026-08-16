#!/bin/sh
# loop-env's job is to distinguish "the command exists" from "a daemon would run
# the job". Every case here is that distinction, because getting it wrong means
# recommending a scheduler that silently never fires.
#
#   sh plugins/devloop/tests/loop-env.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin/loop-env
TMP=${TMPDIR:-/tmp}/loop-env-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }

# A PATH containing only what each case declares, so the host's real tools
# cannot leak in and make a case pass for the wrong reason -- this host has
# systemctl and pgrep, either of which would otherwise decide a case for us.
# Only the utilities loop-env genuinely uses are linked in.
BASE="sh uname cat grep sed"
link_base() {
  for b in $BASE; do
    src=$(command -v "$b") || { echo "loop-env.test: $b not found on this host" >&2; exit 1; }
    ln -sf "$src" "$TMP/bin/$b"
  done
}
mk() { printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$1"; chmod +x "$TMP/bin/$1"; }
clear_bin() { rm -f "$TMP/bin"/*; link_base; }

# Assert the sandbox really is bare, rather than trusting that it is.
link_base
for leak in crontab launchctl systemctl pgrep; do
  if PATH="$TMP/bin" command -v "$leak" >/dev/null 2>&1; then
    echo "loop-env.test: $leak leaked into the sandbox; the cases below would be meaningless" >&2
    exit 1
  fi
done
# pgrep is what separates "installed" from "running"; each case supplies its own.
mk_pgrep() { printf '#!/bin/sh\n[ "${2:-}" = "%s" ] && exit 0\nexit 1\n' "$1" > "$TMP/bin/pgrep"; chmod +x "$TMP/bin/pgrep"; }
mk_pgrep_none() { printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/pgrep"; chmod +x "$TMP/bin/pgrep"; }

# pid 1 is not on PATH, so the sandbox cannot fake it: loop-env takes it from
# LOOP_ENV_INIT when set. Empty is the default here -- "pid 1 is not systemd" --
# and the one case that wants the opposite sets it and puts it back.
INIT_FAKE=""
run()  { PATH="$TMP/bin" LOOP_ENV_INIT="$INIT_FAKE" sh "$BIN" "$@" 2>&1; }
runq() { PATH="$TMP/bin" LOOP_ENV_INIT="$INIT_FAKE" sh "$BIN" --quiet 2>&1; }
rcof() { PATH="$TMP/bin" LOOP_ENV_INIT="$INIT_FAKE" sh "$BIN" >/dev/null 2>&1; echo $?; }

# --- nothing installed ------------------------------------------------------
clear_bin
[ "$(runq)" = "no-local-scheduler" ] && ok "bare environment -> no-local-scheduler" \
  || bad "bare environment -> no-local-scheduler" "$(runq)"
[ "$(rcof)" -eq 1 ] && ok "and exits 1" || bad "and exits 1"
case "$(run)" in *send_later*) ok "and points at send_later" ;; *) bad "and points at send_later" ;; esac
case "$(run)" in *environment_kind*) ok "and names the check the agent must run" ;; *) bad "and names the check" ;; esac
# The backgrounded task needs no scheduler and no MCP, so it must be offered
# precisely here -- this is the environment with nothing else left.
case "$(run)" in *"--wait &"*) ok "offers backgrounded real work" ;; *) bad "offers backgrounded real work" ;; esac
case "$(run)" in *"sleep 600"*) ok "and the sleep fallback" ;; *) bad "and the sleep fallback" ;; esac
case "$(run)" in *"NOT the session exiting"*) ok "and says what backgrounding does not survive" ;;
  *) bad "and says what backgrounding does not survive" ;; esac
# send_later must be verified, not assumed, so the check has to be named.
case "$(run)" in *list_triggers*) ok "names list_triggers as the send_later proof" ;;
  *) bad "names list_triggers as the send_later proof" ;; esac

# --- the case this script exists for ---------------------------------------
# crontab installed, no daemon. Recommending cron here would produce a schedule
# that accepts the job and never runs it.
clear_bin; mk crontab; mk_pgrep_none
[ "$(runq)" = "no-local-scheduler" ] && ok "crontab without a daemon is NOT durable" \
  || bad "crontab without a daemon is NOT durable" "$(runq)"
case "$(run)" in *"never fire"*) ok "and says why" ;; *) bad "and says why" "$(run | grep cron)" ;; esac

# --- crontab with a daemon --------------------------------------------------
clear_bin; mk crontab; mk_pgrep cron
[ "$(runq)" = "local-scheduler" ] && ok "crontab + running cron is durable" \
  || bad "crontab + running cron is durable" "$(runq)"
[ "$(rcof)" -eq 0 ] && ok "and exits 0" || bad "and exits 0"
clear_bin; mk crontab; mk_pgrep crond
[ "$(runq)" = "local-scheduler" ] && ok "crond spelling also detected" || bad "crond spelling also detected"

# --- macOS: launchd runs cron, so no daemon is expected ---------------------
clear_bin; mk launchctl; mk crontab; mk_pgrep_none
[ "$(runq)" = "local-scheduler" ] && ok "launchd counts even with no cron daemon" \
  || bad "launchd counts even with no cron daemon" "$(runq)"
case "$(run)" in *caffeinate*) ok "and warns about sleep via --caffeinate" ;; *) bad "and warns about sleep" ;; esac

# --- systemd needs to actually be pid 1 -------------------------------------
# systemctl exists in plenty of containers where pid 1 is something else, and
# there it schedules nothing.
clear_bin; mk systemctl; mk_pgrep_none
[ "$(runq)" = "no-local-scheduler" ] && ok "systemctl without systemd as pid 1 is not durable" \
  || bad "systemctl without systemd as pid 1 is not durable" "$(runq)"

# The other direction, which had no case at all until the seam existed. Without
# it the negative above proves only that this host is not systemd.
INIT_FAKE=systemd
[ "$(runq)" = "local-scheduler" ] && ok "systemctl WITH systemd as pid 1 is durable" \
  || bad "systemctl WITH systemd as pid 1 is durable" "$(runq)"
case "$(run)" in *systemd*) ok "and names systemd as the option" ;; *) bad "and names systemd" "$(run)" ;; esac
INIT_FAKE=""

# --- a local scheduler still does not end the question ----------------------
clear_bin; mk launchctl; mk_pgrep_none
case "$(run)" in *environment_kind*) ok "even with a scheduler, still says to check environment_kind" ;;
  *) bad "even with a scheduler, still says to check environment_kind" ;; esac

# --- arguments --------------------------------------------------------------
clear_bin
PATH="$TMP/bin" sh "$BIN" --nonsense >/dev/null 2>&1
[ $? -eq 2 ] && ok "unknown option -> 2" || bad "unknown option -> 2"
PATH="$TMP/bin" sh "$BIN" --help >/dev/null 2>&1
[ $? -eq 0 ] && ok "--help -> 0" || bad "--help -> 0"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
