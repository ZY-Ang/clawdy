# How much of a block's rationale to print, and how often.
#
# The long explanations exist to teach the model why a rule is there, and that
# part works. But a Stop hook's stderr is the blocking message, and the human
# reading the transcript gets every word of it on every block -- thirty-five
# lines of the same prose, several times a session, burying the one thing that
# changed: which rule fired and what to do about it.
#
# The two readers cannot be separated. `additionalContext`, the field that
# carries model-only text, is documented for UserPromptSubmit, PostToolUse and
# SessionStart -- not for Stop. So the split is over TIME rather than audience:
# the full rationale the first time a hook blocks in a session, one line after
# that, by which point both readers have read it.
#
#   CLAUDE_HOOK_VERBOSE=1    always print the long form
#   CLAUDE_HOOK_STATE_DIR    where "already explained" is remembered
#
# Callers set TRANSCRIPT first; it is the session's identity and every hook
# parses it anyway.

# explain <hook> <what happened> <the fix> <escapes>   -- long form on stdin
#
# The escapes are named in the SHORT form and not the long one, because the long
# one already lists them -- and a second block is exactly when a turn writing
# about a guard needs the way out.
explain() {
  _hook=$1 _what=$2 _fix=$3 _esc=$4
  printf 'Blocked by %s: %s\n%s\n' "$_hook" "$_what" "$_fix" >&2
  if _explain_first "$_hook"; then
    printf '\n' >&2
    cat >&2
  else
    cat >/dev/null
    printf 'Escapes: %s. Full rationale: CLAUDE_HOOK_VERBOSE=1.\n' "$_esc" >&2
  fi
}

# 0 the first time this hook blocks in this session, 1 after that.
#
# Anything that goes wrong answers 0. Repeating an explanation costs a screen;
# losing it costs the model the reason it was blocked, so the failure has a
# direction.
_explain_first() {
  case "${CLAUDE_HOOK_VERBOSE:-}" in 1|true) return 0 ;; esac
  _dir=${CLAUDE_HOOK_STATE_DIR:-${TMPDIR:-/tmp}/opinionated-claude}
  mkdir -p "$_dir" 2>/dev/null || return 0
  # Hashed, because the transcript path is not a filename and its basename is
  # not unique across projects.
  _key=$(printf '%s' "${TRANSCRIPT:-}" | cksum | cut -d' ' -f1)
  _f=$_dir/$1.$_key
  [ -e "$_f" ] && return 1
  : > "$_f" 2>/dev/null || return 0
  return 0
}
