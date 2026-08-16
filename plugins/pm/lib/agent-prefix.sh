# Shared by every tool here that writes to GitHub.
#
# Everything an agent posts is marked with a robot emoji on its own line:
#
#   🤖
#
#   the actual body
#
# The blank line is deliberate — without it the emoji joins the first paragraph
# and markdown renders one run-on line.
#
# Two jobs. The obvious one is honesty: a reader can tell at a glance that a
# comment was written by an agent. The load-bearing one is that it makes "has a
# human replied?" mechanically checkable, which is what `check-replies` and the
# loop's pick-up step depend on.
#
# On GitHub this matters more than it does on GitLab. There, agent and human
# post under different usernames, so the author alone distinguishes them. Here
# an agent posts through the human's own token, so **every comment has the same
# author** and the prefix is the only signal there is.
#
# Add if missing, never reject. A guard that refuses the call teaches agents to
# route around it; one that quietly does the right thing cannot be forgotten.
# Mirrors `glab-mr-note`, which does exactly this with its "_ " prefix.

AGENT_MARK='🤖'

# agent_prefix <body> -> the body, marked, on stdout. Idempotent.
agent_prefix() {
  case "$1" in
    "$AGENT_MARK"*) printf '%s' "$1" ;;
    *) printf '%s\n\n%s' "$AGENT_MARK" "$1" ;;
  esac
}

# agent_authored <body> -> 0 if this text was posted by an agent.
# The question every caller actually asks is the negation: did a human write it?
agent_authored() {
  case "$1" in "$AGENT_MARK"*) return 0 ;; *) return 1 ;; esac
}
