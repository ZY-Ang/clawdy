#!/bin/sh
# Two failures these guard against, both observed in the wild:
#   1. one question buried under 400 words of arithmetic
#   2. a reversible fix escalated as a needs-human question instead of made
#
#   sh plugins/pm/tests/shape.test.sh

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
TMP=${TMPDIR:-/tmp}/shape-test.$$
mkdir -p "$TMP/bin"
trap 'rm -rf "$TMP"' EXIT INT TERM

# These cases fake gh, so they need it absent from the PATH the code under
# test sees -- NOT absent from the operator's machine. This used to refuse and
# exit 1, the same code a real failure uses, so a full-suite run was red on
# any machine that has gh.
. "$HERE/lib/gh-free.sh"
PATH=$(gh_free_path "$TMP/nogh"); export PATH
export CLAUDE_QUESTIONS_DIR=$TMP/notes CLAUDE_CODE_SESSION_ID=sess-shape HOME=$TMP

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }
rc_is(){ if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, wanted $3"; fi; }
fi_() { PATH="$TMP/bin:$PATH" sh "$BIN/file-issue" "$@"; }
# A task now requires the three ordering axes (see the section at the bottom).
# Cases about body SHAPE should not restate them, so this supplies a valid set
# and keeps each case about the one thing it is named for.
AX="--priority med --urgency low --size s"
aa()  { PATH="$TMP/bin:$PATH" sh "$BIN/ask-async" "$@"; }

# --- one door for questions ---------------------------------------------------
fi_ question "Which timeout?" --body "..." --dry-run >/dev/null 2>&1
rc_is "file-issue refuses a free-text question" $? 2
out=$(fi_ question "Q" --body b --dry-run 2>&1)
case "$out" in *ask-async*) ok "and names ask-async" ;; *) bad "and names ask-async" "$out" ;; esac
# sync re-sends notes that were shaped when written; that must not be re-judged.
CLAUDE_ISSUE_REFILE=1 fi_ question "Q" --body b --dry-run >/dev/null 2>&1
rc_is "REFILE bypasses the gate for sync" $? 0

# --- the wall of text ---------------------------------------------------------
long=""; i=0
while [ "$i" -lt 20 ]; do long="$long
This is an ordinary sentence of prose explaining background nobody asked for."; i=$((i+1)); done
fi_ task "Long one" $AX --body "$long" --dry-run >/dev/null 2>&1
rc_is "20 prose lines is refused" $? 2
out=$(fi_ task "Long one" $AX --body "$long" --dry-run 2>&1)
case "$out" in *"<details>"*) ok "and shows how to collapse it" ;; *) bad "and shows how to collapse it" ;; esac

# The same length as bullets and headings is fine — only paragraphs count, so a
# dense but skimmable issue is never blocked.
bullets=""; i=0
while [ "$i" -lt 20 ]; do bullets="$bullets
- a bullet point carrying the same amount of text as the prose above"; i=$((i+1)); done
fi_ task "Bullets" $AX --body "$bullets" --dry-run >/dev/null 2>&1
rc_is "20 bullets is fine" $? 0

collapsed="Short lead line.

<details><summary>The arithmetic</summary>
$long
</details>"
fi_ task "Collapsed" $AX --body "$collapsed" --dry-run >/dev/null 2>&1
rc_is "the same prose inside <details> is fine" $? 0

fi_ task "Short" $AX --body "One line." --dry-run >/dev/null 2>&1
rc_is "a short body passes" $? 0

# --- the blocker gate ---------------------------------------------------------
aa "Q?" --context c --assume a --dry-run >/dev/null 2>&1
rc_is "ask-async requires --blocked-on" $? 2

aa "Q?" --blocked-on fact --context c --assume a --dry-run >/dev/null 2>&1
rc_is "a FACT is not a question -> refused" $? 2
out=$(aa "Q?" --blocked-on fact --context c --assume a --dry-run 2>&1)
case "$out" in *"file-issue task"*) ok "and redirects to assumption + task" ;;
  *) bad "and redirects to assumption + task" "$out" ;; esac

aa "Q?" --blocked-on decision --context c --assume a --dry-run >/dev/null 2>&1
rc_is "a decision with no --irreversible -> refused" $? 2
out=$(aa "Q?" --blocked-on decision --context c --assume a --dry-run 2>&1)
case "$out" in *"act and undo"*) ok "and says a reversible choice is yours" ;;
  *) bad "and says a reversible choice is yours" "$out" ;; esac

aa "Q?" --blocked-on decision --irreversible "drops the production table" \
   --context c --assume a --dry-run >/dev/null 2>&1
rc_is "a genuinely irreversible decision is allowed" $? 0

aa "Q?" --blocked-on access --context c --assume a --dry-run >/dev/null 2>&1
rc_is "no credential is allowed" $? 0
out=$(aa "Q?" --blocked-on access --context c --assume a --dry-run 2>&1)
case "$out" in *"Blocked on"*) ok "and the body records the blocker" ;; *) bad "and the body records the blocker" ;; esac

aa "Q?" --blocked-on nonsense --context c --assume a --dry-run >/dev/null 2>&1
rc_is "an unknown blocker kind -> refused" $? 2

# --- the rate signal ----------------------------------------------------------
rm -rf "$CLAUDE_QUESTIONS_DIR"
i=0
while [ "$i" -lt 2 ]; do
  aa "Q$i?" --blocked-on access --context c --assume a >/dev/null 2>&1; i=$((i+1))
done
out=$(PATH="$TMP/bin:$PATH" sh "$BIN/questions" 2>&1)
case "$out" in *WARNING*) bad "two open questions is not warned about" ;; *) ok "two open questions is not warned about" ;; esac
aa "Q3?" --blocked-on access --context c --assume a >/dev/null 2>&1
out=$(PATH="$TMP/bin:$PATH" sh "$BIN/questions" 2>&1)
case "$out" in *WARNING*) ok "three IS warned about" ;; *) bad "three IS warned about" "$out" ;; esac
case "$out" in *"act and undo"*|*"could act"*) ok "and says what to do about it" ;;
  *) bad "and says what to do about it" "$out" ;; esac

# --- the task rate signal -----------------------------------------------------
# Questions warn at 3; tasks are legitimately more numerous so the bar is 6.
# Unbounded is how a tracker reaches three figures one reasonable issue at a time.
rm -rf "$CLAUDE_QUESTIONS_DIR"
i=0
while [ "$i" -lt 5 ]; do fi_ task "T$i" $AX --body b >/dev/null 2>&1; i=$((i+1)); done
out=$(PATH="$TMP/bin:$PATH" sh "$BIN/questions" --all 2>&1)
case "$out" in *"open tasks from this session"*) bad "five tasks is not flagged" "$out" ;;
  *) ok "five tasks is not flagged" ;; esac
fi_ task "T6" $AX --body b >/dev/null 2>&1
out=$(PATH="$TMP/bin:$PATH" sh "$BIN/questions" --all 2>&1)
case "$out" in *"open tasks from this session"*) ok "six IS flagged" ;; *) bad "six IS flagged" "$out" ;; esac
case "$out" in *"already in that code"*) ok "and names the fix-vs-file test" ;;
  *) bad "and names the fix-vs-file test" ;; esac
# A task that has been closed is not deferred work and must not count.
f=$(find "$CLAUDE_QUESTIONS_DIR" -name '*.md' | head -1)
PATH="$TMP/bin:$PATH" sh "$BIN/questions" close "$(sed -n 's/^- id: //p' "$f" | head -1)" >/dev/null 2>&1
out=$(PATH="$TMP/bin:$PATH" sh "$BIN/questions" --all 2>&1)
case "$out" in *"open tasks from this session"*) bad "closing one drops it below the bar" "$out" ;;
  *) ok "closing one drops it below the bar" ;; esac

# --- a task must carry the three ordering axes ---------------------------------
# #35: file-issue applied exactly one label, so a backlog it filled ranked FLAT --
# every issue tying through to issue number, which is arrival order. Measured on
# the repo this was designed from: 118 open issues, 0 with a priority.
rc_fi() { ( PATH="$TMP/bin:$PATH" sh "$BIN/file-issue" "$@" >/dev/null 2>&1 ); echo $?; }
out_fi() { ( PATH="$TMP/bin:$PATH" sh "$BIN/file-issue" "$@" 2>&1 ); }

# A gh that records what it was asked to do. The labels are the deliverable
# here, so asserting on the arguments is asserting on the thing itself.
GH_ARGS=$TMP/gh-args
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_ARGS"
case "$1 $2" in "issue create") echo "https://github.com/o/n/issues/1" ;; esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export GH_ARGS

[ "$(rc_fi task "x")" -eq 2 ] && ok "a task with no axes is refused" || bad "task with no axes refused"
case "$(out_fi task "x")" in *"--priority"*) ok "and names the three flags" ;; *) bad "names the flags" ;; esac
case "$(out_fi task "x")" in *FLAT*) ok "and says why: an unaxed backlog ranks flat" ;; *) bad "explains flat" ;; esac

[ "$(rc_fi task "x" --priority high --urgency low)" -eq 2 ] && ok "two of three is still refused" || bad "partial axes refused"
[ "$(rc_fi task "x" --priority nope --urgency low --size s)" -eq 2 ] && ok "an invalid priority is refused" || bad "invalid priority"
[ "$(rc_fi task "x" --priority high --urgency nope --size s)" -eq 2 ] && ok "an invalid urgency is refused" || bad "invalid urgency"
[ "$(rc_fi task "x" --priority high --urgency low --size xl)" -eq 2 ] && ok "an invalid size is refused" || bad "invalid size"
[ "$(rc_fi task "x" --priority high --urgency low --size s --severity nope)" -eq 2 ] && ok "an invalid severity is refused" || bad "invalid severity"
case "$(out_fi task "x" --priority nope --urgency low --size s)" in *"high med low"*) ok "and lists the allowed values" ;; *) bad "lists allowed values" ;; esac

# A question is not queued, so it must not be refused FOR MISSING AXES. It is
# still refused -- by the one-door shape gate, which points at ask-async -- so
# the assertion is about which refusal, not about success.
qout=$(out_fi question "Should we?" --body "context here")
case "$qout" in *--priority*) bad "a question is not asked for axes" "$qout" ;;
  *) ok "a question is not asked for axes" ;; esac
case "$qout" in *ask-async*) ok "it is refused by the shape gate instead" ;;
  *) bad "refused by the shape gate" "$qout" ;; esac

# The labels have to reach gh, and gh fails on a label the repo lacks -- so each
# one must also be created.
: > "$GH_ARGS"
out=$(out_fi task "x" --priority high --urgency low --size s --severity security --area edge)
for l in priority-high urgency-low size-s security area-edge; do
  if grep -q -- "--label $l" "$TMP/gh-args" 2>/dev/null; then ok "label $l applied"
  else bad "label $l applied" "$(cat "$TMP/gh-args" 2>/dev/null)"; fi
done
if grep -q "label create priority-high" "$TMP/gh-args" 2>/dev/null; then ok "and priority-high is created first"
else bad "creates the axis label" "$(cat "$TMP/gh-args" 2>/dev/null)"; fi

# --- plan mode is the design phase, not an interruption ----------------------
# The hook's message says "once work has started", but it does not detect work
# at all: it is deny-by-default, allowing only an explicit env var or a
# per-session interview window. Nothing opens a window automatically, so the
# FIRST AskUserQuestion of any fresh session was blocked -- including in plan
# mode, where no edit can land and the plan harness itself asks questions to
# settle requirements before any work exists.
deny() { printf '%s' "$1" | sh "$HERE/../hooks/deny-interrupt" >/dev/null 2>&1; echo $?; }

[ "$(deny '{"session_id":"s1","tool_name":"AskUserQuestion"}')" -eq 2 ] \
  && ok "a fresh session with no window is still blocked" || bad "default still blocked"

# Both spellings, because the hook-development docs say permission_mode and
# live session state says permissionMode -- and a fix reading the wrong key
# would silently do nothing, which is the failure mode being fixed.
[ "$(deny '{"session_id":"s1","tool_name":"AskUserQuestion","permission_mode":"plan"}')" -eq 0 ] \
  && ok "plan mode is allowed (snake_case key)" || bad "plan allowed, snake_case"
[ "$(deny '{"session_id":"s1","tool_name":"AskUserQuestion","permissionMode":"plan"}')" -eq 0 ] \
  && ok "plan mode is allowed (camelCase key)" || bad "plan allowed, camelCase"

# Every mode where a change CAN land must still be blocked -- that is the bug
# the guard exists for: agent mid-change, unsure, reaches for the tool.
for m in default acceptEdits auto ask allow bypassPermissions; do
  [ "$(deny "{\"session_id\":\"s1\",\"tool_name\":\"AskUserQuestion\",\"permission_mode\":\"$m\"}")" -eq 2 ] \
    && ok "$m is still blocked" || bad "$m still blocked"
done

# Both code paths, separately. jq is the primary and sed the fallback, and with
# both present no single mutation to either can fail -- so each is exercised on
# its own, or the redundancy hides a broken half.
. "$HERE/lib/gh-free.sh" 2>/dev/null || true
NOJQ="$TMP/nojq"; mkdir -p "$NOJQ"
for b in sh sed head printf cat find rm date grep; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOJQ/$b" 2>/dev/null
done
denynojq() { printf '%s' "$1" | PATH="$NOJQ" sh "$HERE/../hooks/deny-interrupt" >/dev/null 2>&1; echo $?; }
[ "$(denynojq '{"session_id":"s1","tool_name":"AskUserQuestion","permission_mode":"plan"}')" -eq 0 ] \
  && ok "the sed fallback reads snake_case with no jq" || bad "sed path, snake_case"
[ "$(denynojq '{"session_id":"s1","tool_name":"AskUserQuestion","permissionMode":"plan"}')" -eq 0 ] \
  && ok "the sed fallback reads camelCase with no jq" || bad "sed path, camelCase"
[ "$(denynojq '{"session_id":"s1","tool_name":"AskUserQuestion","permission_mode":"auto"}')" -eq 2 ] \
  && ok "and the sed fallback still blocks other modes" || bad "sed path, auto blocked"

# A value that merely CONTAINS plan must not slip through.
[ "$(deny '{"session_id":"s1","tool_name":"AskUserQuestion","permission_mode":"planning-ish"}')" -eq 2 ] \
  && ok "a mode that merely contains 'plan' is blocked" || bad "substring match leaked"

# No session id and plan mode: the fail-closed rule is about WHOSE window, and
# plan mode needs no window, so it is allowed.
[ "$(deny '{"tool_name":"AskUserQuestion","permission_mode":"plan"}')" -eq 0 ] \
  && ok "plan mode needs no session id" || bad "plan without a session id"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
