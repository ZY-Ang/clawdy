#!/bin/sh
# The seam is only real if nothing goes around it.
#
#   sh plugins/pm/tests/seam.test.sh
#
# This is a structural test, not a behavioural one. It exists because the
# contract in lib/provider-github.sh says a second backend is "a new file
# implementing the same functions", and that was untrue for six of the ten
# tools -- file-issue, reply-issue, ask-async, check-replies, questions and
# pr-watch all called gh directly. Nothing said so, and nothing would have.
#
# A prose promise about an interface decays silently. This is the check.

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
LIB=$HERE/../lib
fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        return 0; }

# --- no binary calls the backend directly ------------------------------------
# Comment lines are excluded: describing gh is fine, invoking it is not.
for f in "$BIN"/*; do
  b=$(basename "$f")
  hits=$(grep -n "^[^#]*\bgh " "$f" 2>/dev/null | grep -v "provider_" || true)
  if [ -z "$hits" ]; then ok "$b goes through the provider"
  else bad "$b calls gh directly" "$hits"; fi
done

# --- every binary that talks to a backend actually sources one ---------------
for f in "$BIN"/*; do
  b=$(basename "$f")
  # interview-window is local-only by design: it reads and writes stamp files
  # and never touches a tracker, so it must NOT grow a provider dependency.
  case "$b" in interview-window) continue ;; esac
  if grep -q 'provider_[a-z]' "$f" 2>/dev/null; then
    if grep -q 'pm_load_provider' "$f"; then ok "$b loads a provider through the loader"
    else bad "$b calls provider_* without loading one" ""; fi
  fi
  # And nothing names a specific provider. Hardcoding one is what #53 removed:
  # eleven copies of the same two lines, so PM_PROVIDER could not select at all.
  if grep -q 'provider-github\.sh\|provider-[a-z]*\.sh' "$f" 2>/dev/null; then
    bad "$b hardcodes a provider file instead of using PM_PROVIDER" \
        "$(grep -n 'provider-[a-z]*\.sh' "$f" | head -1)"
  fi
done

# --- the mark has one definition ---------------------------------------------
# check-replies used to hardcode its own copy. Whether a human has replied is
# decided by this character, and two definitions is two answers the day one of
# them changes.
n=$(grep -l "AGENT_MARK\|MARK='" "$BIN"/* "$LIB"/* 2>/dev/null | wc -l | tr -d ' ')
lit=$(grep -c "MARK='🤖'" "$LIB/agent-prefix.sh" 2>/dev/null || echo 0)
[ "$lit" -eq 1 ] && ok "the agent mark is defined once, in agent-prefix.sh" \
  || bad "mark defined once" "found $lit literals in the lib"
others=$(grep -ln "MARK='🤖'" "$BIN"/* 2>/dev/null || true)
[ -z "$others" ] && ok "and no binary carries its own copy" \
  || bad "a binary redefines the mark" "$others"

# --- the contract is documented where it is implemented ----------------------
for fn in provider_name provider_available provider_issues provider_issue \
          provider_comment provider_label provider_create_issue \
          provider_close_issue provider_issue_labels provider_needs_human \
          provider_ensure_label provider_link provider_unlink \
          provider_issue_id provider_blocked_by provider_open_draft_pr \
          provider_find_pr provider_supports_deps ; do
  if grep -q "^$fn()" "$LIB/provider-github.sh"; then :
  else bad "$fn is named in the contract but not implemented"; fi
done
ok "every function the contract names is implemented"



# --- the provider is selectable, which is the whole point of a seam ----------
# Before #53 every binary named provider-github.sh directly, so a correctly
# written second provider could be installed and never loaded.
TMPL=${TMPDIR:-/tmp}/seam-provider.$$
mkdir -p "$TMPL"
trap 'rm -rf "$TMPL"' EXIT INT TERM
cat > "$TMPL/provider-fake.sh" <<'EOF'
provider_name() { printf 'fake'; }
provider_available() { return 0; }
EOF
cat > "$TMPL/load-provider.sh" < "$LIB/load-provider.sh"

loadp() { ( PM_LIB="$TMPL" PM_PROVIDER="$1" sh -c '. "$PM_LIB/load-provider.sh"
            pm_load_provider || exit $?
            provider_name' ) 2>&1; }
loadrc() { ( PM_LIB="$TMPL" PM_PROVIDER="$1" sh -c '. "$PM_LIB/load-provider.sh"
             pm_load_provider' >/dev/null 2>&1 ); echo $?; }

[ "$(loadp fake)" = "fake" ] && ok "PM_PROVIDER selects a different provider" \
  || bad "selects a provider" "$(loadp fake)"

[ "$(loadrc nope)" -eq 2 ] && ok "an unknown provider exits 2" || bad "unknown provider -> 2"
case "$(loadp nope)" in *"no provider 'nope'"*) ok "and names what it looked for" ;;
  *) bad "names the missing file" "$(loadp nope)" ;; esac
case "$(loadp nope)" in *"available:"*fake*) ok "and lists what it did find" ;;
  *) bad "lists available" "$(loadp nope)" ;; esac

# A file that loads but implements nothing fails LATER and somewhere else,
# reading like a bug in the tool rather than in the provider.
: > "$TMPL/provider-empty.sh"
[ "$(loadrc empty)" -eq 2 ] && ok "a provider missing the contract exits 2, not later" \
  || bad "empty provider -> 2"
case "$(loadp empty)" in *PROVIDERS.md*) ok "and points at the contract" ;;
  *) bad "points at PROVIDERS.md" "$(loadp empty)" ;; esac

# A name is a filename, so it must not reach out of the lib directory.
[ "$(loadrc ../../etc/passwd)" -eq 2 ] && ok "a name with a path in it is refused" \
  || bad "path traversal refused"


# --- provider_is_triaged, and what a 2 obliges the caller to do --------------
. "$LIB/provider-github.sh"
tri() { provider_is_triaged "$1"; echo $?; }

[ "$(tri '{"labels":[{"name":"priority-low"},{"name":"urgency-low"},{"name":"size-s"}]}')" -eq 0 ] \
  && ok "all three axes present -> triaged" || bad "triaged -> 0"
[ "$(tri '{"labels":[{"name":"priority-low"}]}')" -eq 1 ] \
  && ok "one axis missing -> not triaged" || bad "partial -> 1"
[ "$(tri '{"labels":[]}')" -eq 1 ] && ok "no axes at all -> not triaged" || bad "none -> 1"
[ "$(tri 'not json')" -eq 2 ] && ok "unusable input -> cannot tell, never triaged" || bad "bad input -> 2"

# The contract says a caller that gets 2 must SAY SO rather than rank quietly.
# On this backend absence is observable, so backlog-queue can report provenance
# per row -- and that reporting is the behaviour a 2 stands in for elsewhere.
# Pinned here because it is the part that was documented wrongly first: a 2 was
# described as licence to drop the key and carry on, which asserts every
# priority was chosen and yields a confident order built from nothing.
cat > "$TMPL/i.json" <<'EOF'
[{"number":1,"title":"chosen","state":"OPEN","labels":[{"name":"priority-high"},{"name":"urgency-low"},{"name":"size-s"}],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]},
 {"number":2,"title":"nobody chose","state":"OPEN","labels":[],
  "createdAt":"2026-08-19T00:00:00Z","comments":[],"blockedBy":[]}]
EOF
why=$(BACKLOG_ISSUES_JSON="$TMPL/i.json" BACKLOG_NOW=1787184000 sh "$HERE/../bin/backlog-queue" --why 2>&1)
case "$why" in *"UNTRIAGED: priority"*) ok "an unranked row says its priority was not supplied" ;;
  *) bad "reports defaulted provenance" "$why" ;; esac
case "$why" in *"not a decision"*) ok "and says the priority shown is a default, not a ranking" ;;
  *) bad "says the priority is a default" "$why" ;; esac
# The ranked row must NOT carry the note, or the signal means nothing.
n=$(printf '%s\n' "$why" | grep -c 'UNTRIAGED:')
[ "$n" -eq 1 ] && ok "and the row someone did rank carries no such note" \
  || bad "provenance note is not selective" "got $n notes"

# --- nothing here claims to be stable ----------------------------------------
# Every plugin in this marketplace is pre-1.0 on purpose. A 1.x number is a
# promise about compatibility that none of these has earned yet, and it is the
# kind of claim that gets made by accident one bump at a time.
for m in "$HERE"/../../*/.claude-plugin/plugin.json; do
  [ -f "$m" ] || continue
  v=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | head -1)
  n=$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | head -1)
  case "$v" in
    0.*) ok "$n is pre-1.0 ($v)" ;;
    *)   bad "$n claims $v -- nothing here is stable yet" ;;
  esac
done

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
