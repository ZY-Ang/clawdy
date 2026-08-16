---
name: north-star
description: Agree a goal with the user, write it down, wait for approval, then work towards it unattended on a heartbeat until it is provably reached. Only the user starts this.
user-invocable: true
disable-model-invocation: true
---

# North Star

Adapted from the [Ralph loop](https://ghuntley.com/ralph/) — run the work repeatedly until it
is done, keeping progress in files and the tracker rather than in a context window, so a fresh
session picks up where the last one stopped.

**What is added here is the gate.** Ralph's failure mode is looping forever on a goal nobody
pinned down. So: agree the goal, write it, get it approved, *then* loop — and stop when the
written criteria are met.

**Only the user starts this.** Never invoke it on your own initiative. It runs unattended for a
long time and spends real money.

## Phase 1 — interview

**`AskUserQuestion` is correct here, and only here.** The user typed the command, they are
waiting, and blocking is the point. One question at a time, and stop as soon as the answers are
enough.

If the `pm` plugin is installed, inline questions are **blocked by a hook** unless a window
is open. Open it before the interview and close it the moment phase 1 ends:

```bash
interview-window open      # first thing in phase 1
interview-window close     # last thing, before writing the document
```

The window expires by itself after 30 minutes, so forgetting to close it fails safe rather
than leaving the rule disabled.

**This permission expires when phase 4 begins.** It covers the interview and nothing after it.
Once the loop is running there are no interruptions — not for an ambiguous requirement, not for
a risky change, not for confirmation. Questions that arise during the work get filed and the
loop carries on, or the loop stops and reports. It never hangs waiting for someone.

Get all four. A goal missing any of them cannot be checked, which means the loop cannot end:

1. **What does done look like?** Something observable, not "improve X". *"A person can sign up,
   pay, and get a receipt, on a phone."*
2. **How will we know?** The test, the command, the URL to open. If it cannot be checked
   without you, it will not be checked.
3. **What is out of scope?** The boundary matters more than the goal — it is what stops the
   loop wandering.
4. **What must never break?** Existing behaviour, data, anyone's live site. This is the thing
   worth stopping over.

Also ask: **how long, and how much?** Unattended work has a bill.

## Phase 2 — write it down

Write `NORTH-STAR.md` in the repo root:

```markdown
# North Star

## Done means
One paragraph. Observable from outside.

## Checked by
- [ ] A concrete check, runnable without a human
- [ ] Another

## Out of scope
- Things deliberately not being done

## Must not break
- Existing behaviour that has to keep working

## Stop and ask if
- Conditions that end the loop and need a person

## Budget
Roughly how long, roughly how much.
```

**Every line in "Checked by" must be a command or an observation someone can run.** That list is
the termination condition — if a box cannot be ticked mechanically, the loop has no way to know
it is finished.

## Phase 3 — stop

**Show the document and wait.** Do not start. Do not "begin the easy parts". A goal the human
has not read is a goal you invented.

They may edit it. The edited version is the goal.

## Phase 4 — the loop

Once approved, pick the heartbeat to match whether anyone is watching.

**If you are staying at the machine**, `/loop` is fine and needs no setup:

```
/loop 10m work towards NORTH-STAR.md — check the job queue, pick up anything not
labelled needs-human, and stop when every box in "Checked by" is ticked
```

**If you are walking away — overnight, or for hours — `/loop` will not survive it.** It
schedules through `CronCreate`, whose own documentation says jobs are *"gone when Claude
exits"*, that its `durable` flag *"has no effect"*, and that they *"only fire while the REPL is
idle"*. This is true at every interval; there is no length above which it becomes durable. A
north-star run is unattended by definition, so this is the normal case, not the exception.

Put the timer outside the session instead:

```bash
loop-ctl install north-star --interval 10m --dir "$PWD" --caffeinate \
  --prompt 'work towards NORTH-STAR.md — check the job queue, pick up anything not
labelled needs-human, and stop when every box in "Checked by" is ticked'
loop-ctl doctor north-star     # do not skip this; install proves nothing
```

Each tick resumes the conversation from its transcript, so context carries across ticks without
needing a resident process. `doctor` checks the failures that are otherwise silent — chiefly a
sleeping machine, which stops launchd firing and produces a multi-hour gap that looks exactly
like a crashed loop. See `devloop` for the full reasoning.

**Pick the interval from how long CI takes, not by feel.** One tick per full CI run picks up
almost every result on its first look; shorter intervals mostly re-observe checks still queued,
and longer ones leave green PRs sitting unmerged. Where a full workflow takes ten to fifteen
minutes, twenty is the number. Measure yours rather than copying that one.

The heartbeat is not the work. It is a check on the job queue, so nothing sits idle after CI
goes green or a human answers a question.

**A tick that reports a gap is not a normal tick.** `loop-run` prepends a warning when more than
two intervals have passed. Treat it as a signal that the world moved without you: re-read the
tracker and the PR list from the API rather than trusting what you remember from the last tick.

**Each tick, in order:**

1. **Re-arm the heartbeat. First, before anything else.** Not at the end of the tick — at the
   start of it. A tick that crashes, is interrupted, hits a rate limit or simply runs out of
   context halfway has already scheduled its successor, so the chain survives its own failures.
   Re-arming last means every one of those ends the loop silently, which is the failure mode
   hardest to notice and most expensive to discover.
2. **Poll open PRs.** Merge or report anything that passes the readiness gate. Successes are
   never delivered as events, so this only happens if you look.
3. **Triage red CI.** Read the log, fix, push.
4. **Read answered questions.** `check-replies` lists them — it reads the agent mark to work
   out who spoke last, so a question you replied to yourself is not mistaken for answered. Any
   `needs-human` issue with a human reply is now workable:
   - the answer is a decision → **remove `needs-human`** and start
   - the answer opens up more work → **file the tasks**, close or relabel the question
   - the answer is unclear → reply asking precisely, leave the label on
5. **Pick up work.** Two sources, and both count:
   - Any open issue *not* labelled `needs-human`. Independent items go to subagents in their
     own worktrees; **and**
   - `needs-human` issues that have received a reply from a human.

   The second is the one that gets missed. An answered question is unblocked work, and leaving
   it for the next tick because the label is still attached wastes the very round trip the
   question cost. The label records *who is waited on*, not what may be worked — once a human
   has replied, nobody is waited on any more.
6. **File what you found.** Anything deferred, worked around or newly noticed becomes an issue
   this tick, not at the end.
7. **Check the North Star.** Tick any box now satisfied. **If all are ticked, stop the loop and
   say so** — and cancel the heartbeat you armed in step 1, or it will wake a finished loop.

   Anything unclear at this point goes to `ask-async` and the loop moves on. **Never interrupt
   to ask** — the human started this so they would not have to sit and watch it. They tick a
   box when they see it; the loop already carried on with the stated assumption.

**An empty queue is not idle.** If every PR is in CI and no issue is open, re-read the North
Star and file the next piece of work. Ending a tick with nothing done and nothing filed means
the loop is stalled, not finished.

## Stopping

**Stop and say so when:**

- Every box under "Checked by" is ticked — the goal is reached, which is the point
- Anything under "Must not break" broke
- A "Stop and ask if" condition fires
- **Three consecutive ticks produce no merged PR and no new issue.** That is stuck, not slow.
  `loop-ctl status` gives the tick count, so this is countable rather than remembered
- The budget agreed in phase 1 is spent

**Do not confuse stuck with never-ran.** Three ticks with nothing to show is stuck. *No ticks at
all* is a dead scheduler, and it looks identical from inside the session — which is why
`loop-run` reports the gap rather than leaving you to infer it from what did or did not land.

**Whatever the reason, file before you stop.** A `needs-human` issue naming what is blocking,
what you tried, and what would unblock it. Then stop, citing the number. Stopping without
filing loses the reason along with the session, and the next run starts from nothing.

**Never stop quietly.** A loop that ends without a message looks identical to one still running.

## Related

`devloop` — the readiness gate, review threads, why CI success needs polling.
`pm` — `file-issue` for the queue this loop feeds on, and `backlog-queue` to order it.
`handoff` — if the loop ends mid-work, leave a document a fresh session can resume from.
