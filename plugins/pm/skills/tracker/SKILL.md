---
name: tracker
description: File untracked work as GitHub issues, and ask the user questions asynchronously instead of blocking on them. Use whenever you would reach for AskUserQuestion mid-work, and whenever something is deferred, worked around, noticed but not fixed, or needs a decision — plus when the user asks what is outstanding.
user-invocable: true
---

# File the issue now

Work that is not written down does not exist. The moment something is deferred, worked around
or guessed at, **it is already forgotten** — the session that knew about it ends, and nobody
finds it again.

```bash
file-issue task     "Retry logic is missing" --priority high --urgency low --size s
file-issue question "Should deleted orders keep their invoice number?" --body "..."
```

One line. That is the whole point: filing has to cost less than deciding whether to file.


## A task carries its axes, or it is not filed

```bash
file-issue task "Retry logic is missing" --priority high --urgency low --size s
```

`--priority`, `--urgency` and `--size` are **required on a task**. Not tidiness: they are exactly
what `backlog-queue` ranks on.

Filed without them, `backlog-queue` treats an issue as `priority-med`/`size-m`. That default is
right — a backlog where a third of the issues carry no label must not quietly bury them — but it
means **an unlabelled backlog does not rank badly, it ranks flat.** Everything ties on the first
four keys and falls through to issue number, which is the arrival order the queue exists to
replace. The queue looks like it is working.

Measured on the repo this was designed from, before a backfill: **118 open issues, 0 carrying a
priority**, every one of them filed by this command.

The precedent is `ask-async`, which already refuses without `--blocked-on` and `--assume`. Same
reasoning: the field that makes this useful later is mandatory rather than encouraged.

`--severity data-loss-risk|security` and `--area <thing>` stay optional — severity is genuinely
rare, and area is for batching rather than ordering.

**A question needs none of them.** It is not queued; it sits in the `needs-human` inbox until
answered, and gets its axes when it becomes work.

`backlog-queue --why` names any axis it had to guess, so a flat order announces itself:

```
#7     unlabelled work
        key=111999200000007  severity=1 priority=2(base 2) unblocks=0 age=19d
        defaulted: priority,urgency,size -- not supplied, so this row is not really ranked on ...
```

## Two kinds

**`task`** — untracked work, actionable without anyone answering anything. Labelled `task`.
**This is the checklist.** A task is not a promise to do it now; it is a promise not to lose it.

**`question`** — needs a decision only a person can make. Labelled `needs-human`, which agents
skip when picking up work, so nobody starts it on a guess. **This is the async inbox** — the
human answers when they get to it, and the work carries on meanwhile.

A question with no body is refused. Say what you were doing, what needs deciding, and what you
will do with each answer — otherwise it cannot be answered without a conversation, which is the
thing being avoided.

## Filing is cheap, forgetting is not

An issue costs about ten seconds. A wrong one is closed in a click, and nobody minds. Work
nobody wrote down cannot be recovered at any price, because nobody knows to look for it.

The two mistakes are not symmetric, so do not treat them as a balance to strike. **When
unsure, file it.**

## `ask-async` — AskUserQuestion without the blocking

Same shape as the inline tool: a question, and options with reasons. It files an issue and
**returns immediately**.

```bash
ask-async "Should deleted orders keep their invoice number?" \
  --context "Writing the delete path. Both readings are defensible." \
  --option "Keep it|Numbering gets gaps, but invoices stay immutable" \
  --option "Drop it|Clean numbering, but invoices become mutable" \
  --assume "Keeping it — reversible either way, and immutability is the safer default"
```

The human ticks a box from a phone whenever they get to it. The work does not wait.

**`--assume` is required, and is the whole design.** An async question only helps if the work
continues, which means you must have decided what to do meanwhile. If you cannot name a
default, you are not asking a question — you are stopping, and the tool says so and points you
at `file-issue question` instead.

**Give options.** A question answerable by ticking a box gets answered in ten seconds from a
phone. One needing a written paragraph waits until someone is at a desk with the context
reloaded — which is how a question ages into a blocker.

The issue carries the assumption, so the human sees what happens if they say nothing.

## The rule is enforced, not just written

Installing this plugin adds a `PreToolUse` hook that **refuses `AskUserQuestion`** and prints
the `ask-async` invocation instead. Prose did not hold — an agent mid-change, unsure, reaches
for the tool that is right there. A call that fails with instructions is the version that binds.

The one exception is a window you open deliberately:

```bash
interview-window open      # inline questions permitted for 30 minutes
interview-window close     # the moment the interview ends
interview-window status    # this session, and any other session's window
```

**The window belongs to one session, not to you.** It is keyed on the session id — the hook
reads `session_id` from the JSON on its stdin, `interview-window` reads `CLAUDE_CODE_SESSION_ID`,
and both name the same session. Two agents working towards two different north stars is the
ordinary case, and a shared window would mean one agent's interview granted the other permission
to interrupt, while its `close` revoked a window the other was relying on. `status` lists other
sessions' open windows rather than hiding them: when two agents are running, knowing the other is
mid-interview explains a lot.

**Without a session id the guard denies, and `open` refuses.** "Cannot tell whose window this is"
must not resolve to "allowed" — that is the shared-window bug in a different costume. And a
window nothing will read is worse than no window, because the interview then proceeds believing
it has permission.

**It expires on its own**, because a permission that must be revoked is a permission left on —
and left on, this one silently disables the rule it exists to make room for.
`CLAUDE_INTERVIEW_WINDOW_MINUTES` changes the timeout; `CLAUDE_ALLOW_INTERRUPT=1` on a single
command is the escape hatch for the case nobody predicted.

## Everything posted carries the agent mark

Every issue, comment and reply these tools write starts with a robot emoji on its own line:

```
🤖

the body
```

**On GitHub an agent posts through the human's own token**, so every comment shows the same
author. Unlike GitLab — where agent and human have different usernames and the author alone
tells them apart — the mark is the *only* signal here. Without it a reader cannot tell whose
words they are reading.

It is added when missing rather than demanded. A guard that rejects the call teaches agents to
route around it, and `gh issue comment` is always one keystroke away. Marking twice is a no-op.

Going straight to `gh` — a PR description, a review comment — means adding it yourself. That
rule lives in `opinionated-claude`, because it has to apply when no tool is involved.

## One door for questions, and it has a shape

`file-issue question` is closed. Questions go through `ask-async`, which requires one.

```bash
ask-async "the question, in one line" \
  --blocked-on access|decision \
  --context "what you were doing when it came up" \
  --option "Keep it|invoices stay immutable" \
  --assume "keeping it — reversible either way"
```

Two doors into one `needs-human` inbox, only one of them shaped, produces exactly what you would
expect: a free-text essay with the deciding fact in paragraph four. So there is one door.

**Task bodies are checked for shape too** — the same rule `pr-desc-check` applies to a PR
description: at most 12 prose lines and 4000 characters outside `<details>`. Bullets, headings,
tables and code blocks are free. An issue nobody can read quickly has failed at the one thing it
was for.

## Is it a task, or a fix you are avoiding?

The same test the `--blocked-on` gate applies to questions applies to tasks, and nothing enforces
it — so this one is on you.

**A finding in code you are already changing, whose fix is smaller than its issue, is a fix.** Three
issues filed while reviewing one branch, each describing a one-line change in a file already open,
is three issues that should have been one commit.

File it when it is **someone else's branch** (pushing into work you do not own is not a favour),
when you are **not in that code now**, or when it is **genuinely bigger than it looks**.

`questions` warns when this session has more than a handful of either kind open. Filing is cheap by
design, which is exactly why the count has to be visible — nothing else distinguishes a careful
session from one that deferred everything.

## Is it a question, or a decision you are avoiding?

`--blocked-on` is required, and only two of its three values produce a question:

| Blocked on | Meaning | Result |
| --- | --- | --- |
| `access` | no credential, no permission, no network | **question** |
| `decision` | only the human can choose | **question**, and only with `--irreversible "<why>"` |
| `fact` | knowable, but you cannot reach it | **refused** — assume the safest reading, file a task |

**A `needs-human` issue is a stall wearing the costume of diligence.** It reads as careful, it
produces an artefact that looks like progress, and it turns "I will fix this" into "you must now
read this and choose". Filing was made cheap on purpose — which is precisely why deciding must not
be the more expensive option.

**If you can act and undo it, that is not a decision to escalate.** State the assumption, act on
it, and say which reading you took. That is what `--assume` was always for: it keeps the work
moving, not just the paperwork.

**If you cannot obtain a fact, that is not a question either.** Take the safest reading, say
plainly which, and file a task to confirm it later. Handing it over as a question makes a human go
and look it up — which is the thing you were meant to save them.

`questions` warns at **three or more open questions from one session**. That is a stalling
pattern, not a careful one, and the count is the only thing that tells them apart.

## The question reaches disk before it reaches GitHub

`file-issue` and `ask-async` write a markdown note under `~/.claude/questions/` **first**, then
try GitHub. Not a fallback — a first step.

```bash
questions              # what is still unsent
questions sync         # file them now
questions show <file>
```

`gh` can be absent, the network can be down, the token can be expired, and the session can end
between forming the question and sending it. Each of those loses it silently, which is the one
failure this plugin exists to prevent. The note costs a file write and removes all of them.

| Exit | Meaning |
| --- | --- |
| `0` | filed to GitHub; the note records the issue URL |
| `3` | **kept on disk only** — carry on, and `questions sync` later |
| `1` | could not reach GitHub *and* could not write a note. Now it is a real problem |

**Exit 3 is not a failure.** The question is recorded and durable; it is simply not visible to
anyone yet. Proceed on the stated assumption exactly as you would after exit 0 — the point of
asking asynchronously is that work continues either way.

A note carries the title, kind, timestamp, working directory, session id and repo, so it can be
answered cold weeks later. `- filed:` is `no` until it lands, which is how `questions` tells sent
from unsent.

## A question has a life after it is asked

```bash
questions answer q-7f3a "Keep them — invoices stay immutable"
questions close  q-7f3a --reason superseded
questions prune  --older-than 30d      # closed and answered only
questions --stale 7d                   # open, and older than a week
questions name   "homelab bring-up"    # label this session in listings
```

**The answer is appended to the note, not stored beside it.** The question and what came back are
one artefact, so they cannot drift apart or be read separately.

**`prune` never removes an open question, however old.** Age is what makes an unanswered question
worth looking at, not what makes it disposable. `--stale` surfaces exactly those.

Notes are grouped by session, because several agents run at once and a flat folder stops being
readable fast. A session shows under the name you gave it with `questions name`, or the topic of
its first question if you gave it none — a shell script cannot read what `/rename` set, since
that lives in session metadata rather than the environment.

## Recording the answer is enforced, not requested

The failure is not disagreement. An agent asks, the human answers in chat, the agent says
"noted" — and writes nothing down. Nothing checked, so nothing happened.

Installing this plugin adds a **`UserPromptSubmit` hook** that fires when the human sends a
message — the exact moment an answer arrives — and injects the open questions into the agent's
context before it composes a reply:

> `[open questions]` You asked 1 question that is still open: `q-7f3a` …
> If the message you are about to answer resolves one of them, record it BEFORE replying.

- **It reminds, it never blocks.** An agent cannot reliably tell whether a message answered the
  question or changed the subject, so a hook that refused to end the turn would stop the wrong
  turns and get switched off.
- **Silent when nothing is open**, so it costs nothing in the common case.
- **Only this session's questions.** Another agent's open question is not what this human is
  answering right now.
- **Plain stdout, not JSON.** `additionalContext` in a JSON payload is reported broken in the
  VSCode extension while working in the CLI; stdout injection works in both.

**`gh issue create` succeeding but printing no URL counts as not filed.** Without a URL there is
nothing to point the note at, and calling it filed would drop the only reference.

## Check what a human answered, every tick

```bash
check-replies                # answered questions, newest first
check-replies --quiet        # just the numbers
check-replies --all          # including the ones still waiting
```

Exit `0` means something is answered and workable, `1` means nothing is, `2` means it could not
tell — so a tick can branch on it.

**A `needs-human` issue is blocked only while it is unanswered.** The moment a person replies it
is ordinary work again, and it stays invisible if the loop filters on the label alone, because
nobody remembers to strip the label. That wastes the entire round trip the question cost.

Answered means **the last comment is unmarked**, not "some comment is unmarked". If the human
answered and the agent then asked a follow-up, the ball is back with the person and the issue is
still blocked. That distinction is why this is a tool and not a `grep`.

## Replying to a `needs-human` issue must say what happens to the label

```bash
reply-issue 33 "Done, on branch X" --clears
reply-issue 33 "Superseded by the rewrite" --closes
reply-issue 33 "Acted on the first half" --keeps "still need the DNS record"
```

**Remove the label if the issue is still needed for task tracking, or close it if it is no longer
needed.** On a `needs-human` issue, `reply-issue` refuses until you say which:

| Flag | Meaning |
| --- | --- |
| `--clears` | answered and acted on, still worth tracking as work — label off, issue open |
| `--closes` | answered and no longer needed at all — label off, issue closed |
| `--keeps "<why>"` | a person is still needed, and this is what for — label stays |

**The failure it prevents:** the human answers, the agent acts and replies, and the label outlives
both. The issue then sits in the queue looking blocked on someone who already answered — and
because the agent's reply is the last comment, and agent comments carry the 🤖 mark,
`check-replies` reads it as *still waiting on a human*. The agent blocks its own issue.

**Deliberately not automatic.** Whether the answer was enough is a judgement only the replying
agent can make: an acknowledgement, a partial answer and a follow-up question look identical from
outside. What is enforced is that the judgement is *made*, not which way it goes.

`--keeps` puts its reason in the reply, not just in a flag. A thread that says why it is still
blocked can be answered; a bare label cannot.

An issue **without** the label needs no disposition — ordinary replies are unaffected.

The label comes off only after the comment posts. A failed reply must not leave the issue looking
unblocked with nothing said.

## When the answer is a correction, file a task as well

A human reply is often not just an answer — it corrects a premise you argued from. `--clears`
closes the loop on the question and **loses the correction with it**.

```bash
reply-issue 33 "Right — posting the status without requiring it" --clears
file-issue task "Premise 'a required check can block here' was wrong" \
  --body "Asserted in #33; CLAUDE.md section 3 says otherwise. Check what else assumed it."
```

The thread closes and takes the correction with it. Worse, the same wrong premise is probably
sitting in another issue, a plan, or a comment written in the same session — and a reply saying
"you're right" revisits none of it.

**Disposition flags handle the label. They do not handle what the answer taught you.**

## Reply on a thread

```bash
reply-issue 42 "Fixed in abc1234 — the retry now backs off."
reply-issue 42 --body -            # body on stdin
```

Marked automatically. It posts a **top-level** comment — `gh issue comment` works on pull
requests too, since GitHub models a PR as an issue. Replying *inside* a specific review thread
still needs `gh api`, and there you add the mark yourself.

## Do not block on a question — file it

**Prefer a question issue over any tool that asks the user inline.** An inline question:

- stops the turn until someone answers
- has no timeout, so it can wait indefinitely
- needs a person present at that exact moment
- vanishes with the session if unanswered — the question is lost, not deferred

It turns a small uncertainty into a full stop. The issue does the opposite.

```bash
file-issue question "Should deleted orders keep their invoice number?" \
  --body "Writing the delete path. Keeping it leaves gaps in numbering; dropping it makes
invoices mutable. Went with keeping it, which is reversible. Tell me if that is wrong."
```

Then say in your reply: *"Assumed invoices keep their number on delete — filed #48, easy to
change."* Three things happen at once: the work continues, the assumption is visible, and the
question survives this session.

**Never ask inline once work has started** — not when the requirement is unclear, not when the
change is risky, not when you would rather be sure. The only permitted use is an interview the
user explicitly started, before any work begins.

**If you are genuinely stuck, that is the strongest case for filing, not an exception to it.**
File the question first, then stop and cite the number. A session that stops without filing
loses the reason along with itself — and unlike an unanswered inline prompt, there is nothing
left sitting there to notice.

> Filed #52 — blocked on whether deleted orders keep their invoice number. Stopped there.

That sentence still means something tomorrow, to someone who was not present.

## When to file — the moments, not a judgement call

**If you write or think any of these, you already owe an issue:**

| You said | File |
| --- | --- |
| "for now", "later", "TODO", "leaving that" | `task` |
| "out of scope for this change" | `task` |
| "worth doing", "should probably", "ideally" | `task` |
| "I worked around it by…" | `task` |
| "this is also broken, but unrelated" | `task` |
| "I'll assume", "going with X for now" | `question` |
| "unclear whether", "depends what you want" | `question` |
| skipping or disabling a test | `task` |
| noticing a second bug while fixing the first | `task` |

**File it in the same turn you notice it.** Not at the end, not in the summary, not "when I
wrap up" — those are the turns that get interrupted, and the note dies with the session.

## Why agents miss this

Filing feels like a detour. You are mid-change, the thing you noticed is not the thing you are
doing, and stopping to write it up costs attention you are spending elsewhere. So it becomes a
line in the final message instead — where it is read once and lost.

**A sentence in a chat reply is not a record.** The tracker is the only thing that survives the
session. If it is worth mentioning to the user, it is worth one line in the tracker first.

## Reporting

When you have filed, say so in one line with the number: "Filed #47 for the retry gap." That
is the evidence it landed, and it is shorter than describing the problem again in prose.

When asked what is outstanding, read the tracker rather than the conversation:

```bash
gh issue list --label task           # the checklist
gh issue list --label needs-human    # waiting on a person
```

## Install

The command lives in the plugin's `bin/`, which is on the Bash tool's `PATH`. If a bare
`file-issue` does not resolve, call it by full path:

```bash
"$HOME/.claude/plugins/marketplaces/clawdy/plugins/pm/bin/file-issue" task "..."
```

`--dry-run` prints the `gh` command without creating anything. `--repo owner/name` files
elsewhere. Requires `gh`, authenticated; the label is created on first use.

## Related

`devloop` covers what to do with `needs-human` issues once they exist: skip them while they are
unanswered, and pick them up again as soon as a human has replied — the label says who is waited
on, not what may be worked.
