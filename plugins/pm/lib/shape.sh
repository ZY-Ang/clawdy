# Is this issue body readable, and is this question actually a question?
#
# Two guards, both structural. Prose in a skill did not stop agents writing
# essays or stalling; nothing checked, so nothing changed.
#
# The prose rule is deliberately identical to devloop's `pr-desc-check`: at most
# 12 prose lines and 4000 characters outside <details> and fenced code, where
# bullets, numbers, headings, quotes and table rows are not prose. It is
# reimplemented here rather than shelled out to, because a guard that silently
# does nothing when a sibling plugin is absent is worse than no guard. If you
# change one, change both.

PROSE_MAX=${CLAUDE_ISSUE_PROSE_MAX:-12}
CHAR_MAX=${CLAUDE_ISSUE_CHAR_MAX:-4000}

# prose_lines <file> -> "<lines> <chars>"
prose_lines() {
  awk '
    BEGIN { in_details = 0; in_code = 0; lines = 0; chars = 0 }
    {
      line = $0
      lower = tolower(line)
      if (index(lower, "<details")) { in_details = 1 }
      if (in_details) { if (index(lower, "</details>")) in_details = 0; next }
      if (line ~ /^[[:space:]]*```/) { in_code = !in_code; next }
      if (in_code) next
      if (line ~ /^[[:space:]]*$/) next
      if (line ~ /^[[:space:]]*[-*+][[:space:]]/) next      # bullets
      if (line ~ /^[[:space:]]*[0-9]+[.)][[:space:]]/) next # numbered
      if (line ~ /^[[:space:]]*#/) next                     # headings
      if (line ~ /^[[:space:]]*>/) next                     # quotes
      if (line ~ /^[[:space:]]*\|/) next                    # tables
      if (line ~ /^[[:space:]]*</) next                     # raw html
      lines++; chars += length(line)
    }
    END { print lines, chars }
  ' "$1"
}

# check_shape <body-file> <label-for-errors> -> 0 ok, 1 too long (message on stderr)
check_shape() {
  set -- $(prose_lines "$1") "$2"
  _l=$1 _c=$2 _what=$3
  if [ "$_l" -le "$PROSE_MAX" ] && [ "$_c" -le "$CHAR_MAX" ]; then return 0; fi
  {
    printf '%s is a wall of text: %s prose lines, %s chars (max %s / %s).\n\n' \
      "$_what" "$_l" "$_c" "$PROSE_MAX" "$CHAR_MAX"
    printf 'Nobody reads these quickly, which is the point of filing one. Lead with what\n'
    printf 'you need, then collapse the reasoning:\n\n'
    printf '  <details><summary>How I got here</summary>\n\n  ...the arithmetic...\n\n  </details>\n\n'
    printf 'Bullets, headings, tables and code blocks are free. Only paragraphs count.\n'
  } >&2
  return 1
}

# --- is this a question, or a decision being avoided? ------------------------
#
# A `needs-human` issue is a stall wearing the costume of diligence: it reads as
# careful, and it converts "I will fix this" into "you must now read this and
# choose". Filing was made cheap on purpose; deciding was not. The local optimum
# is to file everything and decide nothing, and that is what happens.
#
# So a question has to name what it is blocked ON, and only two answers survive.
check_blocker() {
  case "$1" in
    access)
      return 0 ;;   # no credential, no permission, no network. Genuinely stuck.
    decision)
      [ -n "${2:-}" ] && return 0
      {
        printf 'A "decision" question needs --irreversible "<why acting first cannot be undone>".\n\n'
        printf 'If you can act and undo it, that is not a decision to escalate -- it is a\n'
        printf 'choice you are allowed to make. State your assumption, act on it, and say\n'
        printf 'which reading you took.\n'
      } >&2
      return 1 ;;
    fact)
      {
        printf 'A fact you cannot obtain is not a question for a human.\n\n'
        printf 'Act on the safest reading, say plainly which one you took, and file a TASK\n'
        printf 'to confirm it later:\n\n'
        printf '  file-issue task "Confirm <the fact>" --body "Assumed <X> in <where>. If <Y>, revisit."\n\n'
        printf 'Filing it as a question stops the work and hands a decision to someone who\n'
        printf 'has to go and look it up themselves.\n'
      } >&2
      return 1 ;;
    *)
      printf 'questions: --blocked-on must be one of: access, decision, fact\n' >&2
      return 1 ;;
  esac
}
