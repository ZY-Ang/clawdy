---
name: opinionated-claude
description: Install a set of working conventions into your CLAUDE.md — act autonomously instead of asking permission to push or open a PR, keep changes surgical, never leak private infrastructure detail into a public repository, and never claim something is verified without evidence. Use when an agent keeps asking permission for steps the task already implies, when setting up a new machine, or when the user runs /opinionated-claude.
user-invocable: true
---

# opinionated-claude

Writes a block of working conventions into your user-level `CLAUDE.md`, so every session on
that machine starts with them.

## The Autonomy rule is enforced, not just written

Installing this plugin adds a **`Stop` hook** that refuses to end a turn which asks permission for
work the request already implied.

```
Blocked: this turn ends by asking permission ("want me to").
  - not "Want me to open a PR?"  ->  "Pushed, PR #12"
```

**Why a hook and not a paragraph.** The convention below has said "do the work, do not ask
permission" since it was written. Across one long session the agent that *wrote* it ended turn
after turn with "Want me to…?" — including in the message announcing a fix for agents asking too
much. Prose you authored is not loaded prose.

**Why the interrupt guard cannot do this.** That one blocks the `AskUserQuestion` *tool*. A
question written as ordinary prose is not a tool call, so the hole in it is exactly the width of a
sentence. A `Stop` hook sees the finished message.

It catches two shapes:

- **Questions** — "Want me to…?", "Should I…?", "Shall I…?" — counted when the question mark
  falls *after* the phrase. Not at the end of the line: a message that asks and then closes on a
  statement still ends in a full stop. Writing *about* asking stays possible, because a
  retrospective has no "?" following the phrase.
- **Statements that hand the turn over** — "unless you say otherwise", "say the word and", "let
  me know if you", and the explicit hand-backs: **"your call"**, "your choice", "up to you",
  "whichever you prefer", and the imperative form — **"say go"**, "if you want it", "give me the
  word", "happy to". These read as decisive and are the subtler hang: the turn ends, and nothing
  happens until a human replies. If it genuinely *is* the human's call, that is a filed question —
  `ask-async` — not an inline one.

  The imperative form has a sharper failure: it gets used when a **tracked issue for the work is
  already open**. The work is written down and prioritised, and the turn still stops to request a
  start signal it does not need. An open issue is the go-ahead.

Only the last **ten** non-empty lines are scanned. It was three, which took *"the ask is always
last"* too literally — that holds for the **sentence**, not for the line. A hand-back followed by a
numbered list of next steps sits four or five lines from the end and went straight through, which
is why the guard read as intermittent rather than broken: it caught "say the word" as a closing
line and missed the identical sentence with a list after it.

## The other half: announcing work is not doing it

A second `Stop` hook, `no-announced-work`. The first catches *"shall I?"*; this catches
*"doing it now"*, which fails the same way and is **harder to notice**.

Observed three times in one session, each as the closing line of a message:

```
"Filing both now, then continuing with the merged-PR sweep."   -- nothing filed
"Next, per the approved plan: sweeping the 46 merged PRs..."    -- no sweep
"Now backfilling across all 118 open issues."                   -- no backfill
```

**Nothing resumes a turn on its own.** Only a user message, a scheduled wakeup or a background-task
notification starts one, and none was armed — so in each case the work simply did not happen and a
human had to notice.

**Why it is worse than asking permission.** *"Shall I open a PR?"* is visibly a stall: the human
sees a question and knows they are needed. *"Filing now"* reads as a **report**. A day later in a
scrollback it is indistinguishable from completed work, so nobody checks, and the gap is silent.

Two exemptions, both load-bearing:

- **Telling the human what to do next is not a promise.** "Next action: merge #32" is the house
  closing format, addressed to someone else. Only a **first-person** subject counts. A guard that
  fires on correct output is the first one switched off, so that case is pinned as its own test.
- **A promise with a return path is a plan.** "Monitor armed, I will report the result" is honest
  precisely because something *will* wake the turn. Name the mechanism and the hook stands down —
  which makes saying what you armed the cheap path.

`CLAUDE_ALLOW_ASKING=1` on a single command is the escape, for something genuinely irreversible or
outside what was asked. Per command — exporting it in a profile disables the rule permanently and
silently.

## Install

```bash
"$HOME/.claude/plugins/marketplaces/clawdy/plugins/opinionated-claude/bin/opinionated-claude-install"
```

The full path is deliberate — a plugin's `bin/` is on the *Bash tool's* `PATH` only, so a bare
command name will not resolve. `$HOME` expands per user, so nothing here is machine-specific.

| Flag | Effect |
| --- | --- |
| *(none)* | writes `~/.claude/CLAUDE.md` |
| `--project` | writes `./CLAUDE.md` in the current repo |
| `--print` | prints the block, writes nothing |
| `--remove` | takes the block back out |

## It will not eat your CLAUDE.md

Everything lands between two markers:

```markdown
<!-- BEGIN opinionated-claude -->
...
<!-- END opinionated-claude -->
```

Content outside them is preserved exactly. Re-running **replaces** the block rather than
appending a second copy, so updating is the same command as installing. `--remove` strips it
and leaves the rest untouched.

## What goes in

**Autonomy** — the reason this exists. Agents ask permission for steps the task already
implies: *shall I push this?*, *would you like me to open a PR?* Both stall a turn and answer
themselves — a change sitting on a local branch is worthless. The block says to push, open the
PR, and report what was done rather than proposing it. Hard-to-reverse actions still get asked
about, and the block names them: force pushes over others' commits, merging to protected
branches, deleting data, production config.

**Public repositories** — check what you are about to commit for details that identify
someone's infrastructure: hardware models, VPN and mesh names, ISPs, internal service names,
real domains, paths containing a username. Private context shared to inform a design does not
become public because it informed the design. Write the shape, not the inventory.

**Git** — never commit to `main` unbidden, worktrees for concurrent agents, commit messages
that explain why rather than what.

**Think before coding · Simplicity first · Surgical changes · Goal-driven execution · Code
comments** — the minimum that solves the problem, no speculative abstractions, no improving
adjacent code, every changed line traceable to the request, comments that explain the code
rather than narrating its history.

**Evidence** — never claim "verified" or "confirmed" without having run something and seen the
output. Say "I believe" instead. Include the actual output when asserting technical correctness
in a PR comment.

Run `--print` to read the whole thing before installing it.

## Editing it

The installed block is a copy. Edit it directly in your `CLAUDE.md` if you want local
variations — but re-running the installer overwrites the block. To keep changes, either edit
the plugin's `conventions.md` and re-install, or move your variations outside the markers.

## Related

`devloop` covers the same autonomy principle applied specifically to pull requests: proving a
PR is mergeable before asking for review, and polling for CI success because it is never
delivered as an event.
