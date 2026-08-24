# Write the question to disk before trying to file it anywhere.
#
# Not a fallback — a first step. `gh` can be missing, the network can be down,
# the token can be expired, and a session can die between forming the question
# and sending it. Every one of those loses the question silently, which is the
# single failure this plugin exists to prevent.
#
# Notes live under one directory per session, so a folder of them stays legible
# when several agents are running. Each carries an id, a status and the time it
# was asked, because an unanswered question that has gone stale is a different
# thing from one still worth answering, and only the timestamp can tell them
# apart.
#
# Adapted from the reference setup's rule, which persists a question to a
# markdown file before doing anything else "so the question survives session
# compaction / restart and the operator can revisit it later".

QUESTIONS_DIR=${CLAUDE_QUESTIONS_DIR:-$HOME/.claude/questions}

# The session id is the only stable handle a shell script has. What `/rename`
# set lives in session metadata the environment does not expose, so a display
# name has to be recorded deliberately — see `questions name`.
q_session() { printf '%s' "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unsessioned}}"; }
q_dir()     { printf '%s/%s' "$QUESTIONS_DIR" "$(q_session)"; }

# `\+` is a GNU extension: POSIX and BSD sed read it as a LITERAL plus, so on
# macOS the spaces survived and landed in the filename. `[^x][^x]*` is the
# portable "one or more" and needs no -E.
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^-//' -e 's/-$//' \
    | cut -c1-48
}

# A short id that is typeable. Not cryptographic — it only has to be unique
# among a handful of open questions, and short enough to retype without copying.
q_newid() {
  _s=$( (date +%s; echo $$; head -c16 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null) | cksum | tr -dc '0-9' )
  printf 'q-%s' "$(printf '%s' "$_s" | tail -c 5)"
}

# persist_question <kind> <title> <body> -> prints the path it wrote
persist_question() {
  _kind=$1 _title=$2 _body=$3
  # `questions sync` re-files notes that already exist on disk. Without this it
  # would persist a fresh copy of each and one question would breed.
  [ "${CLAUDE_QUESTIONS_NO_PERSIST:-}" = "1" ] && return 1

  _d=$(q_dir)
  mkdir -p "$_d" 2>/dev/null || { echo "persist: cannot create $_d" >&2; return 1; }

  _id=$(q_newid)
  _f="$_d/$(date -u +%Y-%m-%d)-$(slugify "$_title")-$_id.md"
  {
    printf '# %s\n\n' "$_title"
    printf -- '- id: %s\n' "$_id"
    printf -- '- kind: %s\n' "$_kind"
    printf -- '- status: open\n'
    printf -- '- asked: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- topic: %s\n' "$(slugify "$_title")"
    printf -- '- cwd: %s\n' "$PWD"
    printf -- '- session: %s\n' "$(q_session)"
    _remote=$(git remote get-url origin 2>/dev/null || true)
    [ -n "$_remote" ] && printf -- '- repo: %s\n' "$_remote"
    printf -- '- filed: no\n'
    printf '\n---\n\n%s\n' "$_body"
  } > "$_f" 2>/dev/null || { echo "persist: cannot write $_f" >&2; return 1; }

  printf '%s' "$_f"
}

# set_field <path> <key> <value> — rewrite one metadata line in place.
# awk plus mv, not sed -i: sed's in-place flag differs between GNU and BSD, and
# an interrupted rewrite must not leave a half-written note that reads as
# something it is not.
set_field() {
  [ -f "$1" ] || return 1
  _t="$1.tmp.$$"
  # `|| _rc=$?` matters: awk exits 3 to report "key absent", and under `set -e`
  # a bare failing command would end the caller before the append below runs.
  _rc=0
  awk -v k="- $2: " -v v="$3" '
    index($0, k) == 1 { print k v; found = 1; next }
    { print }
    END { if (!found) exit 3 }
  ' "$1" > "$_t" 2>/dev/null || _rc=$?
  case $_rc in
    0) mv "$_t" "$1" 2>/dev/null ;;
    # The key was absent — an older note, or a field this version added. Insert
    # it INTO THE METADATA BLOCK, before the `---` that starts the body.
    #
    # Appending to the end of the file put it after that separator, so the line
    # became part of the question text: `questions sync` re-sent the body with
    # "- priority: high" inside it, and get_field -- which anchors on `^- key: `
    # and does not know where the metadata stops -- would read a body line as
    # metadata. Cosmetic until something appended a key, which nothing did until
    # the ordering axes.
    3) awk -v line="- $2: $3" '
         !done && /^---$/ { print line; print ""; done = 1 }
         { print }
         END { if (!done) print line }
       ' "$_t" > "$_t.2" 2>/dev/null && mv "$_t.2" "$1" 2>/dev/null && rm -f "$_t" ;;
    *) rm -f "$_t" 2>/dev/null; return 1 ;;
  esac
}

get_field() { sed -n "s/^- $2: //p" "$1" 2>/dev/null | head -1; }

mark_filed() { set_field "$1" filed "$2"; }
