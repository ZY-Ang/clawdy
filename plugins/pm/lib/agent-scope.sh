# Which agent an item belongs to, when several share one tracker.
#
# Ordering answers "what is most important". It does not answer "whose lane is
# this" -- so with one global ready-set, any agent can claim work another filed
# for a different stream, and the `claimed` label then makes the grab look
# legitimate to everyone else.
#
# Identity is an explicit variable, not something derived. The harness session
# name is not in the process environment -- only a mutable UUID is -- so there
# is nothing stable to read.
#
#   export PM_AGENT=backlog-worker      # label form: agent-backlog-worker
#
# Precedence matches every other knob here: --agent beats PM_AGENT beats unset.
#
# **Unset is today's behaviour exactly.** Nothing filters, nothing refuses. That
# is what makes this safe to land while other agents are mid-flight.

# agent_name -> the configured name, or nothing.
# AGENT_OVERRIDE is what a caller sets from its own --agent flag.
agent_name() { printf '%s' "${AGENT_OVERRIDE:-${PM_AGENT:-}}"; }

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
  [ "$_owner" = "$_me" ]
}
