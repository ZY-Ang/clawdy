# Which agent an item belongs to, when several share one tracker.
#
# Ordering answers "what is most important". It does not answer "whose lane is
# this" -- so with one global ready-set, any agent can claim work another filed
# for a different stream, and the `claimed` label then makes the grab look
# legitimate to everyone else.
#
#   export PM_AGENT=backlog-worker      # label form: agent-backlog-worker
#   export PM_AGENT=auto                # take the harness session name
#
# Precedence matches every other knob here: --agent beats PM_AGENT beats unset.
#
# **Unset is today's behaviour exactly.** Nothing filters, nothing refuses. That
# is what makes this safe to land while other agents are mid-flight.
#
# `auto` exists because a name you must set per session is a name you forget to
# set. It is derived, not guessed: the harness writes the session's own record
# to ~/.claude/sessions/$CLAUDE_PID.json, and $CLAUDE_PID is exported into every
# subprocess. So `export PM_AGENT=auto` once, anywhere, and every session lands
# in its own lane with nothing to remember.

# _agent_slug <text> -> a label-safe form, or nothing.
# Session names are free text -- a cloud session is called "Homelab k3s hardware
# options" -- so `auto` slugifies rather than refusing what it was handed.
_agent_slug() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9._-]\{1,\}/-/g' -e 's/^-*//' -e 's/-*$//'
}

# _agent_session_record -> path to this session's harness record, if it exists.
_agent_session_record() {
  [ -n "${CLAUDE_PID:-}" ] || return 1
  _r="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}/$CLAUDE_PID.json"
  [ -f "$_r" ] || return 1
  printf '%s' "$_r"
}

# _agent_derived -> the session's current name, slugified, or nothing.
_agent_derived() {
  _r=$(_agent_session_record) || return 1
  command -v jq >/dev/null 2>&1 || return 1
  _agent_slug "$(jq -r '.name // empty' "$_r" 2>/dev/null)"
}

# _agent_former -> names this session used to have, slugified, one per line.
# A rename would otherwise orphan everything the session already filed: the old
# label names an agent that no longer exists, so its own work reads as somebody
# else's and claiming it is refused.
_agent_former() {
  _r=$(_agent_session_record) || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '.formerNames[]?.name // empty' "$_r" 2>/dev/null | while IFS= read -r _n; do
    _s=$(_agent_slug "$_n"); [ -n "$_s" ] && printf '%s\n' "$_s"
  done
}

# agent_name -> the configured name, or nothing.
# AGENT_OVERRIDE is what a caller sets from its own --agent flag.
agent_name() {
  _v=${AGENT_OVERRIDE:-${PM_AGENT:-}}
  [ "$_v" = auto ] || { printf '%s' "$_v"; return 0; }
  _agent_derived || true
}

# agent_auto_unresolved -> 0 when `auto` was asked for and produced nothing.
# Callers warn on this rather than letting it pass as "no scoping configured" --
# silently behaving like unset is how a lane goes missing without a trace.
agent_auto_unresolved() {
  [ "${AGENT_OVERRIDE:-${PM_AGENT:-}}" = auto ] || return 1
  [ -z "$(agent_name)" ]
}

# agent_label -> agent-<name>, or nothing when unset.
agent_label() {
  _n=$(agent_name)
  [ -n "$_n" ] || return 0
  printf 'agent-%s' "$_n"
}

# agent_name_ok <name> -> 0 if it can be half of a label.
# A name with a space produces a label the backend either rejects or, worse,
# creates split in two -- and the second half is a word like "worker" that then
# scopes nothing and looks like a typo nobody made.
agent_name_ok() {
  case "${1:-}" in
    '') return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# agent_owner <label>... -> the name in the first agent-* label, or nothing.
agent_owner() {
  for _l in "$@"; do
    case "$_l" in agent-*) printf '%s' "${_l#agent-}"; return 0 ;; esac
  done
  return 0
}

# agent_may_claim <label>... -> 0 if the current agent may take this item.
#
# Lenient on purpose. Refusing anything not explicitly ours would strand every
# legacy issue and everything a human filed by hand -- which is most of a real
# backlog. Only a label naming a DIFFERENT agent refuses.
agent_may_claim() {
  _owner=$(agent_owner "$@")
  [ -n "$_owner" ] || return 0
  _me=$(agent_name)
  [ -n "$_me" ] || return 0
  [ "$_owner" = "$_me" ] && return 0
  # A former name is still this session. Without this a rename strands every
  # item the session filed under the old one.
  _agent_former | grep -qx -- "$_owner"
}
