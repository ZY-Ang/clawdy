#!/bin/sh
# The question reaches disk before it reaches GitHub, so nothing can lose it.
#
#   sh plugins/pm/tests/persist.test.sh
#
# The cases that matter are the ones where GitHub is unavailable: no gh, gh
# failing, gh returning nothing. In every one of those the note must exist and
# the exit code must say "kept locally", never "filed".

set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=$HERE/../bin
TMP=${TMPDIR:-/tmp}/persist-test.$$
mkdir -p "$TMP/bin" "$TMP/notes"
trap 'rm -rf "$TMP"' EXIT INT TERM

export CLAUDE_QUESTIONS_DIR=$TMP/notes
export CLAUDE_CODE_SESSION_ID=sess-test
export HOME=$TMP

# Notes are grouped under a per-session directory, so match by find rather
# than a fixed glob — the layout is free to change without editing every case.
notefiles() { find "$CLAUDE_QUESTIONS_DIR" -name '*.md' -type f 2>/dev/null; }
ingrep() { find "$CLAUDE_QUESTIONS_DIR" -name '*.md' -type f -exec grep -q "$1" {} + 2>/dev/null; }

fails=0 ran=0
ok()  { ran=$((ran+1)); printf 'ok   %s\n' "$1"; }
bad() { ran=$((ran+1)); fails=$((fails+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"
        # Always succeed: `cond && bad "x" || ok "x"` runs BOTH branches when
        # bad's last command fails, which it does whenever $2 is absent.
        return 0; }
rc_is(){ if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "exit $2, wanted $3"; fi; }
notes() { notefiles | wc -l | tr -d ' '; }
reset() { rm -rf "$CLAUDE_QUESTIONS_DIR"; mkdir -p "$CLAUDE_QUESTIONS_DIR"; }

# gh that succeeds, gh that fails, gh that returns nothing — and no gh at all.
gh_ok()      { printf '#!/bin/sh\n[ "$1" = "label" ] && exit 0\necho "https://github.com/o/r/issues/42"\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
# Same as gh_ok, but records its arguments. Asserting that sync REPLAYS the axes
# needs the call, not just the exit code.
GH_ARGS=$TMP/gh-args
gh_rec()     { printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$GH_ARGS"\n[ "$1" = "label" ] && exit 0\necho "https://github.com/o/r/issues/42"\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
export GH_ARGS
gh_fail()    { printf '#!/bin/sh\n[ "$1" = "label" ] && exit 0\nexit 1\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
gh_silent()  { printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"; }
gh_absent()  { rm -f "$TMP/bin/gh"; }

# The sandbox PREPENDS rather than replaces: the scripts need a normal set of
# utilities, and enumerating them by hand is how a test breaks on the next
# machine. Only `gh` is controlled, so this is only sound if the host has none —
# assert that rather than assume it.
# These cases fake gh, so they need it absent from the PATH the code under
# test sees -- NOT absent from the operator's machine. This used to refuse and
# exit 1, the same code a real failure uses, so a full-suite run was red on
# any machine that has gh.
. "$HERE/lib/gh-free.sh"
PATH=$(gh_free_path "$TMP/nogh"); export PATH
call() { cmd=$1; shift; PATH="$TMP/bin:$PATH" sh "$BIN/$cmd" "$@"; }
# A task now requires the three ordering axes. These cases are about DURABILITY
# -- what happens when gh is missing, failing or silent -- so the axes are
# supplied once here rather than restated in every call.
AX="--priority med --urgency low --size s"

# --- no gh: the note is the whole point --------------------------------------
reset; gh_absent
call file-issue task "Retry logic is missing" $AX --body "found while fixing #12" >/dev/null 2>&1
rc_is "no gh -> exit 3, not a silent success" $? 3
[ "$(notes)" = "1" ] && ok "and the note exists" || bad "and the note exists" "$(notes) notes"
if ingrep '^- filed: no$'; then ok "marked unsent"; else bad "marked unsent"; fi
if ingrep 'found while fixing #12'; then ok "body preserved"; else bad "body preserved"; fi
out=$(call file-issue task "T2" $AX --body b 2>&1 >/dev/null)
case "$out" in *"kept on disk"*) ok "message names the file" ;; *) bad "message names the file" "$out" ;; esac

# --- gh present but failing --------------------------------------------------
reset; gh_fail
call file-issue task "Server rejects it" $AX --body b >/dev/null 2>&1
rc_is "gh failing -> exit 3" $? 3
[ "$(notes)" = "1" ] && ok "note still written" || bad "note still written"

# --- gh succeeding but printing nothing --------------------------------------
# A silent success is not a success: without a URL there is nothing to point the
# note at, and treating it as filed would lose the only reference.
reset; gh_silent
call file-issue task "Quiet gh" $AX --body b >/dev/null 2>&1
rc_is "gh returning no URL -> exit 3" $? 3
if ingrep '^- filed: no$'; then ok "and stays unsent"; else bad "and stays unsent"; fi

# --- the happy path ----------------------------------------------------------
reset; gh_ok
url=$(call file-issue task "It works" $AX --body b 2>/dev/null); rc=$?
rc_is "gh ok -> exit 0" "$rc" 0
[ "$url" = "https://github.com/o/r/issues/42" ] && ok "prints the URL" || bad "prints the URL" "$url"
if ingrep '^- filed: https://github.com/o/r/issues/42$'
then ok "note records where it went"; else bad "note records where it went"; fi

# --- ask-async takes the same path -------------------------------------------
reset; gh_absent
call ask-async "Keep invoice numbers?" --blocked-on access --context "delete path" --assume "keep them" >/dev/null 2>&1
rc_is "ask-async, no gh -> exit 3" $? 3
[ "$(notes)" = "1" ] && ok "ask-async persists too" || bad "ask-async persists too"
out=$(call ask-async "Q2" --blocked-on access --context c --assume a 2>&1 >/dev/null)
case "$out" in *"proceeding on the stated assumption"*) ok "and says work continues" ;;
  *) bad "and says work continues" "$out" ;; esac

# --- dry-run must not litter --------------------------------------------------
reset; gh_ok
call file-issue task "Dry" $AX --body b --dry-run >/dev/null 2>&1
[ "$(notes)" = "0" ] && ok "dry-run writes no note" || bad "dry-run writes no note"

# --- questions list -----------------------------------------------------------
reset; gh_absent
call file-issue task "Unsent one" $AX --body b >/dev/null 2>&1
call questions list >/dev/null 2>&1
rc_is "list exits 1 while anything is unsent" $? 1
out=$(call questions list 2>&1)
case "$out" in *"[unsent]"*) ok "and marks it [unsent]" ;; *) bad "and marks it [unsent]" "$out" ;; esac
case "$out" in *"questions sync"*) ok "and names the fix" ;; *) bad "and names the fix" ;; esac

# --- sync ---------------------------------------------------------------------
gh_ok
call questions sync >/dev/null 2>&1
rc_is "sync exits 0 when everything went" $? 0
[ "$(notes)" = "1" ] && ok "sync does not breed duplicate notes" \
  || bad "sync does not breed duplicate notes" "$(notes) notes — NO_PERSIST not honoured"
if ingrep '^- filed: https://'; then ok "and marks the original filed"
else bad "and marks the original filed"; fi
# The note is filed but still OPEN, so list correctly reports work outstanding.
out=$(call questions list 2>&1)
case "$out" in *"[unsent]"*) bad "nothing is unsent after sync" "$out" ;; *) ok "nothing is unsent after sync" ;; esac

reset; gh_absent
call questions sync >/dev/null 2>&1
rc_is "sync without gh -> exit 1" $? 1

# --- the axes must survive the durability path --------------------------------
# The requirement is only worth having if a note that never reached the tracker
# comes back ranked. Replaying it without the axes would reintroduce the exact
# decay through the one path nobody looks at.
rm -rf "$TMP/notes"; gh_absent
call file-issue task "Axed note" --priority high --urgency low --size s --severity security --body b >/dev/null 2>&1
note=$(find "$TMP/notes" -name '*.md' 2>/dev/null | head -1)
if [ -n "$note" ]; then
  for pair in "priority: high" "urgency: low" "size: s" "severity: security"; do
    if grep -q -- "- $pair" "$note"; then ok "note records $pair"
    else bad "note records $pair" "$(cat "$note")"; fi
  done
  : > "$GH_ARGS"; gh_rec
  out=$(call questions sync 2>&1)
  case "$out" in *sent*) ok "sync re-files the note" ;; *) bad "sync re-files the note" "$out" ;; esac
  # file-issue turns --priority high into --label priority-high, so the assertion
  # is on what gh was actually asked for, not on the flag that produced it.
  create=$(grep '^issue create' "$TMP/gh-args" 2>/dev/null | head -1)
  case "$create" in *"--label priority-high"*) ok "and replays priority-high" ;;
    *) bad "replays the axes on sync" "$create" ;; esac
  case "$create" in *"--label security"*) ok "and replays the severity" ;;
    *) bad "replays the severity" "$create" ;; esac
  # The metadata must not have leaked into the re-sent body.
  case "$create" in *"- priority: high"*) bad "note metadata leaked into the body" "$create" ;;
    *) ok "and the metadata stayed out of the body" ;; esac
else
  bad "a note was written for the axed task"
fi

# --- a title with spaces ------------------------------------------------------
# One filing produced FIVE entries in `questions list`, all with an empty id, so
# the reminder hook printed an id that could never be cleared. Two causes, both
# invisible until a title contains a space.
#
# 1. slugify used `\+`, a GNU extension. POSIX and BSD sed read it as a literal
#    "+", so on macOS the spaces survived into the filename.
# 2. `for f in $(all_notes)` word-splits on IFS, so one path with five spaces
#    became six "notes".
reset; gh_absent
call ask-async "a title with spaces here" --blocked-on access \
  --context ctx --option "A|why" --assume "A meanwhile" >/dev/null 2>&1

n=$(find "$CLAUDE_QUESTIONS_DIR" -name '*.md' 2>/dev/null | wc -l)
[ "$n" -eq 1 ] && ok "one filing writes exactly one note" || bad "note count" "wrote $n"

spaced=$(find "$CLAUDE_QUESTIONS_DIR" -name '* *' 2>/dev/null | wc -l)
[ "$spaced" -eq 0 ] && ok "the filename carries no spaces" \
  || bad "spaces in filename" "$(find "$CLAUDE_QUESTIONS_DIR" -name '* *' | head -1)"

# The user-visible half: the listing must agree with the disk.
out=$(PATH="$TMP/bin:$PATH" sh "$BIN/questions" 2>&1)
listed=$(printf '%s' "$out" | grep -cE '^\s+q-[0-9]+' || true)
[ "$listed" -eq 1 ] && ok "questions lists exactly one entry" || bad "listing count" "listed $listed"

# An empty id is what made the reminder unclearable, so the id must be there.
id=$(printf '%s' "$out" | grep -oE 'q-[0-9]+' | head -1)
[ -n "$id" ] && ok "the entry carries an id" || bad "empty id" "$out"

# And the id must actually work, which is the whole point of printing it.
if [ -n "$id" ]; then
  PATH="$TMP/bin:$PATH" sh "$BIN/questions" close "$id" --reason superseded >/dev/null 2>&1 \
    && ok "closing by that id succeeds" || bad "close by id failed" "$id"
fi

# THE PLATFORM-INDEPENDENT HALF. The cases above cannot see the word-splitting
# on a GNU sed, because `\+` works there and no space ever reaches the filename.
# A title is not the only way one gets there: a questions directory under a path
# containing a space does it on every platform, which is what makes this
# reproducible rather than a macOS-only report.
SPACED="$TMP/dir with spaces/notes"
rm -rf "$SPACED"; mkdir -p "$SPACED"
( CLAUDE_QUESTIONS_DIR="$SPACED"; export CLAUDE_QUESTIONS_DIR
  PATH="$TMP/bin:$PATH" sh "$BIN/ask-async" "plain title" --blocked-on access \
    --context ctx --option "A|why" --assume "A meanwhile" >/dev/null 2>&1 )
files=$(find "$SPACED" -name '*.md' 2>/dev/null | wc -l)
[ "$files" -eq 1 ] && ok "one note written under a spaced directory" || bad "spaced dir note count" "$files"

out=$( CLAUDE_QUESTIONS_DIR="$SPACED"; export CLAUDE_QUESTIONS_DIR
       PATH="$TMP/bin:$PATH" sh "$BIN/questions" 2>&1 )
listed=$(printf '%s' "$out" | grep -cE '^\s+q-[0-9]+' || true)
[ "$listed" -eq 1 ] && ok "a spaced directory lists one entry, not several" \
  || bad "spaced dir listing" "listed $listed from 1 file"

id=$(printf '%s' "$out" | grep -oE 'q-[0-9]+' | head -1)
[ -n "$id" ] && ok "and its id is not empty" || bad "spaced dir empty id" "$out"

# --- sync must use the repo the note recorded ---------------------------------
# persist_question already writes `- repo: <origin url>` from the cwd at ASK
# time, and nothing read it back. `sync` with no --repo left REPO empty, so the
# issue was created wherever the shell was standing at SYNC time -- and the note
# was then stamped `filed:` with that wrong URL, so it could never be re-sent to
# the right place. This is the exact scenario sync exists for: an agent that
# filed offline, or moved on.
reset; gh_absent
SYNCA="$TMP/repoA"; rm -rf "$SYNCA"; mkdir -p "$SYNCA"
( cd "$SYNCA" && git init -q . && git remote add origin https://github.com/acme/repo-A.git ) 2>/dev/null
( cd "$SYNCA" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/file-issue" task "Fix the widget" $AX --body b ) >/dev/null 2>&1
if ingrep '^- repo: https://github.com/acme/repo-A.git$'; then ok "the note records the repo it was filed from"
else bad "note records repo" "$(grep -h '^- repo' "$CLAUDE_QUESTIONS_DIR"/*/*.md 2>/dev/null | head -1)"; fi

# Sync from a DIFFERENT checkout. The recorded repo must win over the cwd.
SYNCB="$TMP/repoB"; rm -rf "$SYNCB"; mkdir -p "$SYNCB"
( cd "$SYNCB" && git init -q . && git remote add origin https://github.com/acme/repo-B.git ) 2>/dev/null
gh_rec; : > "$GH_ARGS"
( cd "$SYNCB" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/questions" sync ) >/dev/null 2>&1
case "$(cat "$GH_ARGS" 2>/dev/null)" in
  *"--repo acme/repo-A"*) ok "sync sends it to the recorded repo, not the cwd" ;;
  *) bad "sync uses the recorded repo" "argv: $(head -1 "$GH_ARGS" 2>/dev/null)" ;;
esac

# An explicit --repo must still win: the operator may be deliberately re-homing.
reset; gh_absent
( cd "$SYNCA" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/file-issue" task "Fix the widget" $AX --body b ) >/dev/null 2>&1
gh_rec; : > "$GH_ARGS"
( cd "$SYNCB" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/questions" sync --repo owner/explicit ) >/dev/null 2>&1
case "$(cat "$GH_ARGS" 2>/dev/null)" in
  *"--repo owner/explicit"*) ok "an explicit --repo still overrides the note" ;;
  *) bad "--repo overrides the note" "argv: $(head -1 "$GH_ARGS" 2>/dev/null)" ;;
esac

# A local-path remote is recorded as a path, and a path is not a repository
# name. Passing it as --repo would make the backend fail on something that
# looks like a directory; cwd inference is the honest fallback there.
reset; gh_absent
SYNCL="$TMP/repoLocal"; rm -rf "$SYNCL"; mkdir -p "$SYNCL"
( cd "$SYNCL" && git init -q . && git remote add origin "$TMP/some-bare-repo" ) 2>/dev/null
( cd "$SYNCL" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/file-issue" task "Local remote" $AX --body b ) >/dev/null 2>&1
gh_rec; : > "$GH_ARGS"
( cd "$SYNCB" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/questions" sync ) >/dev/null 2>&1
case "$(cat "$GH_ARGS" 2>/dev/null)" in
  *--repo\ /*) bad "a filesystem path must not be passed as --repo" "argv: $(head -1 "$GH_ARGS" 2>/dev/null)" ;;
  *) ok "a local-path remote is not passed as a repository name" ;;
esac

# A note with no recorded repo keeps today's behaviour: no --repo, cwd decides.
reset; gh_absent
( cd "$TMP" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/file-issue" task "No remote here" $AX --body b ) >/dev/null 2>&1
gh_rec; : > "$GH_ARGS"
( cd "$SYNCB" && CLAUDE_QUESTIONS_DIR="$CLAUDE_QUESTIONS_DIR" PATH="$TMP/bin:$PATH" \
  sh "$BIN/questions" sync ) >/dev/null 2>&1
case "$(cat "$GH_ARGS" 2>/dev/null)" in
  *--repo*) bad "a note with no repo must not gain one" "argv: $(head -1 "$GH_ARGS" 2>/dev/null)" ;;
  *) ok "a note with no recorded repo is unchanged" ;;
esac

# --- an unscoped note must say so ---------------------------------------------
# With no session id, q_session falls back to the literal `unsessioned`, so
# every agent on the machine in that state shares one directory. The reminder
# hook then shows each of them the others' open questions as its own, and sync
# re-files all of them.
#
# interview-window hit the same fork and REFUSED, on the grounds that a window
# nothing will read is worse than no window. That is right for a window and
# wrong here: refusing would destroy the content persistence exists to protect.
# So it writes, and says the note is unscoped.
reset; gh_absent
out=$( CLAUDE_CODE_SESSION_ID= CLAUDE_SESSION_ID= PATH="$TMP/bin:$PATH" \
       sh "$BIN/file-issue" task "Unscoped one" $AX --body b 2>&1 )
[ "$(notes)" = "1" ] && ok "an unsessioned filing still writes the note" || bad "unsessioned note written"
if printf '%s' "$out" | grep -q 'unscoped and shared'
then ok "and warns that it is unscoped"
else bad "warns when unscoped" "[$out]"; fi
if ingrep '^- session: unsessioned$'; then ok "the note records that it has no session" \
  else bad "note records unsessioned"; fi

# A normal filing must stay quiet -- a warning on every note is a warning nobody
# reads.
reset; gh_absent
out=$( CLAUDE_CODE_SESSION_ID=sess-real PATH="$TMP/bin:$PATH" \
       sh "$BIN/file-issue" task "Scoped one" $AX --body b 2>&1 )
case "$out" in
  *unscoped*) bad "a scoped filing must not warn" "$out" ;;
  *) ok "a filing with a session id says nothing extra" ;;
esac

# The reminder must not present another agent's questions as this session's.
reset
mkdir -p "$CLAUDE_QUESTIONS_DIR/unsessioned"
printf '# Someone else\n\n- id: q-99999\n- kind: question\n- status: open\n- asked: 2026-01-01T00:00:00Z\n- session: unsessioned\n- filed: no\n\n---\n\nbody\n' \
  > "$CLAUDE_QUESTIONS_DIR/unsessioned/2026-01-01-someone-else-q-99999.md"
out=$( CLAUDE_CODE_SESSION_ID= CLAUDE_SESSION_ID= PATH="$TMP/bin:$PATH" \
       sh "$HERE/../hooks/remind-open-questions" 2>&1 </dev/null )
case "$out" in
  *q-99999*)
    if printf '%s' "$out" | grep -q 'no session id'
    then ok "the reminder marks unscoped questions as shared"
    else bad "reminder marks unscoped questions" "$out"; fi ;;
  *) bad "the reminder did not list the shared question at all" "$out" ;;
esac

# --- short ids must not collide, and a collision must not resolve silently ----
# Minting used `cksum | tr -dc 0-9 | tail -c 5`. cksum prints "<crc> <bytes>",
# the byte count is near-constant within a session, and tail took the END -- so
# two of the five digits were literally fixed. Measured on the real store: 11
# ids duplicated across 215 notes, one of them across two different sessions.
# Sourced here rather than assumed: this suite drives the binaries, so q_newid
# is not otherwise in scope and the loop below would append 400 empty lines and
# call it a pass.
( . "$HERE/../lib/persist.sh" && command -v q_newid >/dev/null ) \
  || bad "persist.sh defines q_newid" "cannot source it"
. "$HERE/../lib/persist.sh"

ids=$TMP/ids
: > "$ids"
i=0
while [ $i -lt 400 ]; do q_newid >> "$ids"; echo >> "$ids"; i=$((i + 1)); done
minted=$(wc -l < "$ids" | tr -d ' ')
distinct=$(sort -u "$ids" | wc -l | tr -d ' ')
# 400 draws from 100000 collide ~0.8 times on average; from the old ~1000 space
# they collide ~60 times. Anything under 10 distinguishes the two decisively.
dupes=$((minted - distinct))
[ "$dupes" -lt 10 ] && ok "400 ids collide rarely ($dupes)" \
                    || bad "400 ids collide rarely" "$dupes collisions in $minted"

# The trailing digits were the tell: constant across a session. Every one of
# 100 possible endings should be reachable.
endings=$(sed 's/.*\(..\)$/\1/' "$ids" | sort -u | wc -l | tr -d ' ')
[ "$endings" -gt 50 ] && ok "the trailing digits vary ($endings of 100 seen)" \
                      || bad "the trailing digits vary" "only $endings distinct endings"

# Shape has to hold too: q- plus exactly 5 digits, zero-padded.
badshape=$(grep -cv '^q-[0-9][0-9][0-9][0-9][0-9]$' "$ids" || true)
[ "$badshape" -eq 0 ] && ok "every id is q- plus exactly five digits" \
                      || bad "id shape" "$badshape malformed"

# --- lookup: several matches is an error, not a first-match guess -------------
reset
D1=$CLAUDE_QUESTIONS_DIR/sess-aaa; D2=$CLAUDE_QUESTIONS_DIR/sess-zzz
mkdir -p "$D1" "$D2"
mknote() { printf '# %s\n\n- id: %s\n- kind: task\n- status: open\n- filed: no\n\n---\n\nbody\n' "$2" "$3" > "$1"; }
mknote "$D1/2026-01-01-one-q-11111.md" "note one" q-11111
mknote "$D2/2026-01-02-two-q-11111.md" "note two" q-11111
mknote "$D1/2026-01-03-solo-q-22222.md" "solo"    q-22222

q() { PATH="$TMP/bin:$PATH" sh "$BIN/questions" "$@" 2>&1; }

out=$(q show q-11111); rc=$?
case "$out" in *"ambiguous"*) ok "a duplicated id is reported, not guessed" ;;
               *) bad "a duplicated id is reported, not guessed" "[$out]" ;; esac
[ "$rc" -eq 2 ] && ok "and exits 2" || bad "and exits 2" "exit $rc"
# Both paths named: one of them is the note the caller meant, and they cannot
# tell which without seeing both.
case "$out" in *sess-aaa*) case "$out" in *sess-zzz*) ok "both notes are named" ;;
                  *) bad "both notes are named" "[$out]" ;; esac ;;
               *) bad "both notes are named" "[$out]" ;; esac
case "$out" in *"2 notes carry it"*) ok "the count matches what is listed" ;;
               *) bad "the count matches what is listed" "[$out]" ;; esac

out=$(q show q-22222); rc=$?
case "$out" in *solo*) ok "a unique id still resolves" ;;
               *) bad "a unique id still resolves" "[$out]" ;; esac
[ "$rc" -eq 0 ] && ok "and exits 0" || bad "and exits 0" "exit $rc"

out=$(q show q-99999); rc=$?
case "$out" in *"no note with id"*) ok "a missing id says missing, not ambiguous" ;;
               *) bad "a missing id says missing, not ambiguous" "[$out]" ;; esac

# answer and close resolve through the same helper, so they must refuse too --
# closing the wrong session's question is the damage this prevents.
out=$(q close q-11111 --reason superseded); rc=$?
case "$out" in *"ambiguous"*) ok "close refuses an ambiguous id" ;;
               *) bad "close refuses an ambiguous id" "[$out]" ;; esac
[ "$(sed -n 's/^- status: //p' "$D1/2026-01-01-one-q-11111.md")" = open ] \
  && ok "and neither note was touched" \
  || bad "and neither note was touched" "note one was modified"

echo "---"
if [ "$fails" -eq 0 ]; then echo "$ran passed"; else echo "$fails of $ran failed"; fi
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
