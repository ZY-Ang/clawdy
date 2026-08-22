---
name: devloop
description: How to work a GitHub repo unattended without stalling — the definition of ready that must hold before asking a human to review, why CI success is never delivered as an event, replying to review threads only after the fix is pushed, durable scheduling that survives container suspension, and when to merge versus ask. Use when running an autonomous loop, babysitting a PR, waiting on CI, deciding whether a PR is ready, or when work appears stuck.
user-invocable: true
---

# The development feedback loop

An agent working a repo unattended is rarely blocked by the code. It is blocked by the loop it
runs in. These are the failure modes that actually cost hours, and what to do instead.

## Never say "ready for review" until you have proved it

**This is the rule that gets broken most.** An agent finishes a change, sees its own push
succeed, and asks a human to look — while CI is still queued, the branch is behind, or a review
thread from last round is still open. The human opens it, finds it not ready, and the round trip
is wasted. Worse, they learn to distrust the phrase.

**Asking for review is a claim. Make it a checked one.**

```bash
pr-watch                # the PR for the current branch
pr-watch 14             # a specific one
pr-watch 14 --wait      # block until checks settle, then judge
pr-watch --all          # every open PR you own -- the first step of a loop tick
```

It exits `0` when nothing is left on your side, `1` with the reason and the fix, and `2` when
it could not tell — so a loop can branch on it and an unreachable API is never mistaken for a
pass. Exit `0` prints which of two situations you are in:

- **READY TO MERGE** — every gate passed and no review is outstanding.
- **READY FOR REVIEW** — everything you control is green; the only thing left is a human.
  This is the one moment asking for review is correct.

Run it before you type the words, not after. Under the hood it is the check below.

```bash
gh pr view <n> --json number,isDraft,state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup
```

Every one of these must hold before the words "ready for review" appear:

| Field | Required | Why |
| --- | --- | --- |
| `state` | `OPEN` | — |
| `isDraft` | `false` | a draft is not a request |
| `mergeable` | `MERGEABLE` | `CONFLICTING` needs a merge; `UNKNOWN` means GitHub has not finished — re-poll, do not assume |
| `mergeStateStatus` | `CLEAN` | see below |
| `statusCheckRollup` | every check `COMPLETED` **and** `SUCCESS` | a `PENDING` check is not a pass; the array mixes `CheckRun` (`status`/`conclusion`) with `StatusContext` (`state`, no `status`) — read both or a commit status looks pending forever |
| review threads | none unresolved | `gh api repos/{o}/{r}/pulls/{n}/comments` |

`mergeStateStatus` is the one worth learning, because each value has a different fix:

- `CLEAN` — good.
- `BEHIND` — base moved. Update the branch, wait for CI again. **Not ready yet.**
- `UNSTABLE` — a check is failing or still running. **Not ready.**
- `DIRTY` — conflicts. Resolve them.
- `BLOCKED` — a required review or check is missing. **Split this one.** If checks are green,
  there are no conflicts, and the review decision is `REVIEW_REQUIRED`, the only thing left is
  a human — that is genuinely ready for review. If the review is already `APPROVED` and it is
  still `BLOCKED`, a required check or ruleset is unmet: say *which* rather than "please
  review". `pr-watch` makes exactly this split.
- `UNKNOWN` — GitHub is still computing. Re-poll; never report this as ready.

**Without `gh`**, the same facts come from the REST API, but the names and casing differ —
`GET /repos/{o}/{r}/pulls/{n}` gives `draft`, `mergeable` (a boolean, not an enum) and
`mergeable_state` (lowercase: `clean`, `behind`, `dirty`, `blocked`, `unstable`, `unknown`).
Check runs come from `GET /repos/{o}/{r}/commits/{sha}/check-runs`. Same gate, different
spelling — do not assume one shape and silently read `undefined`.

If something fails, say what and what you are doing about it. "CI red on `test`, fixing" is
useful. "Ready for review" when it is not is worse than silence.

## A verdict goes stale the moment the base moves

"READY TO MERGE" is a fact about a moment, not a property of the PR. The base branch moving
after the check flips `mergeStateStatus` to `BEHIND`, GitHub grays out the merge button, and a
human looking at the PR sees it unmergeable — while the last thing the agent said was "ready".
That is exactly what happened to #68: the verdict was printed, another PR merged, and the
human's button went gray.

- **Every report of a PR's state carries its evidence** — the `pr-watch` line, not the bare
  words. A verdict with no check behind it is a rumour, and a stale one is a lie with a
  timestamp.
- **When a human says "not mergeable" or "the button is grayed", diagnose; never re-assert.**
  The button is the ground truth. Read `mergeStateStatus` first, then fix what it names:
  `BEHIND` — merge the base branch in, push, wait for CI, re-report; `DIRTY` — resolve;
  `UNSTABLE` — fix the check; `BLOCKED` — say *which* check or ruleset. The `BEHIND` fix is
  mechanical and needs no permission.
- **The verdict expires at every merge to the base, yours included.** After anything lands on
  `main`, re-check before repeating the word "ready" — including for a PR you reported ready
  moments ago. Between your check and the human's click, `main` is the only thing that moves,
  and it is the thing that grays the button.

## The loop, numbered

The steps are the contract; the tool names are local to this repository.

1. Make changes on a non-main branch.
2. Push the branch to the remote.
3. Create the PR if one does not exist (`gh pr create`), or push to the existing one.
4. After **every** push, run `pr-watch <n> --wait` — **always dispatched as a background Bash
   call (`run_in_background: true`), never as the foreground main process.** The check can
   block until CI settles; foreground use deadlocks the agent and burns context. Background
   pattern:
   - Bash with `run_in_background: true` returns a task ID immediately.
   - The agent keeps working (reply to the operator, fan out subagents, draft fixes) while CI
     runs.
   - When the command exits, the harness delivers a `<task-notification>` — no polling, no
     sleep loops.
   - Read the **full output** when the notification arrives before deciding on step 5+.
   - `pr-watch` exits `0` when nothing is left on your side, `1` naming the reason and its fix,
     `2` when it could not tell. Exit `0` prints which of two situations you are in — READY TO
     MERGE or READY FOR REVIEW — and that line is the only licence to use those words.

   Mergeability is not the same as "may merge". Pick per task, don't default blindly:
   - **merge without asking** — routine, low-risk, reversible changes: image/tag bumps, lint
     fixes, dependency bumps, docs, test-only changes, anything already agreed this session.
   - **stop at ready and ask** — anything the operator should eyeball first: new features or
     behaviour changes, security/auth/policy, config, schema and data migrations, deletions,
     cross-repo or breaking changes, or when the PR resolved a discussion by judgement rather
     than a mechanical fix.
   - When genuinely unsure, stop at ready and say why in the status report — stopping costs one
     review round, merging the wrong thing costs a revert.
5. **CRITICAL: do not reply to any discussion until you have actually made and pushed the
   fix.** Never "will do", "will fix", "will update" — the reply describes what you *already
   did*, not what you intend to do. Sequence: change, commit, push, *then* reply. See "Never
   reply 'will fix'".
6. For each open discussion: **bot threads** — fix it or justify why it is a non-issue, then
   resolve; if the finding contradicts an operator instruction or a documented project
   decision, do not silently comply — reply explaining the conflict, leave it unresolved, flag
   it. **Human threads** — fix it and reply describing the change, but do not resolve; the
   human's disagreement is their call to close.
7. After addressing discussions — whether by pushing code or replying in-thread — go back to
   step 4.
8. Repeat until `pr-watch` exits `0` (mergeable, or merged).

## Fan out; do not serialise work that has no dependency

Independent issues go to **subagents in their own `git worktree` checkouts and their own
branches**, so several PRs progress at once. A loop that takes one issue at a time runs at a
fraction of its throughput for no reason.

Two things make that safe rather than chaotic: a worktree per agent, so nobody is editing another
agent's tree; and a branch per issue, so the PRs stay reviewable separately.

Serialise only where the dependency is real — one change needs another's migration, or two issues
touch the same lines and will conflict. "It feels tidier" is not a dependency.

## Open it ready, not as a draft

**A draft is not a request** — that is the whole point of the readiness gate above. So do not open
every PR as a draft out of habit and then ask someone to review it, which says two contradictory
things at once.

Open a PR **ready** when the work is complete and the checks you can run locally pass. That is the
normal case.

Open a **draft** only when there is a reason a reader would otherwise waste their time:

- it is stacked on an unmerged PR and cannot merge yet
- it is deliberately incomplete and you are publishing it for early direction
- it is a spike you do not intend to merge as-is

**And say which**, in the description. A draft with no stated reason reads as an accident, and it
is usually right.

If a PR was drafted for one of those reasons and the reason has since gone — the parent merged,
the spike became real — take it out of draft in the same turn you notice. Leaving it drafted is
the same stall as never opening it.

## Successes are not delivered as events

PR subscriptions wake you on **failures**, review comments and merges — not on a run turning
green. Every `check_run.completed` event that arrives carries `conclusion: failure`.

So a passing PR sits until something polls it. **Poll every open PR at the start of every
tick** rather than waiting for a notification that is never sent.

## Run the backlog on a loop

Tune the interval to your CI duration: roughly one tick per full CI run. Too short and every
tick re-observes pending checks; too long and green PRs sit unmerged. Ten to twenty minutes
suits most repos.

Each tick, in this order:

1. **Poll every open PR's checks.** Merge or report anything that passes the gate above.
2. **Triage red checks.** Read the failing job's log, fix the cause, push. A failure that also
   reproduces on the base branch is pre-existing — say so in the thread rather than absorbing
   it into the PR.
3. **Answer review threads** on PRs you own — with a change, or with a reason.
4. **Pull the next issues** — both kinds: those not labelled `needs-human`, **and** any
   `needs-human` issue a human has since replied to. `check-replies` finds the second kind;
   filtering on the label alone hides them until someone remembers to strip it. Fan out:
   independent work goes to subagents in their own `git worktree` checkouts and branches. Do
   not serialise work that has no dependency between its parts.

   **Order that set, and claim what you take.** `backlog-queue` ranks it; `backlog-claim <n>`
   binds the issue to a branch and opens the draft PR before the work starts. Without a claim,
   two sessions fanned out in step 4 pick the same top item — the ordering makes that *more*
   likely, not less, because they now agree on what is first.
5. **Re-arm the timer before the turn ends.** A tick that forgets this is the last tick.

**Never let a tick end in a hold.** If every PR is in CI, that is not a reason to idle — it is
a reason to start the next issue. "Waiting" and "stuck" look identical from outside, and both
mean nothing shipped that tick.

## Push it and open the PR — do not ask

Committing, pushing and opening the pull request are **part of the task**, not separate
decisions needing sign-off. "Shall I push this?" stalls a round trip and answers itself: a
change on a local branch does nothing for anyone.

Push the branch, open the PR, push follow-up fixes to it, and **report what you did** rather
than proposing it. "Pushed, PR #12, CI running" beats asking.

Ask first only where the action is hard to reverse or wider than the task: force pushing over
someone else's commits, merging to a protected branch, deleting data, rewriting published
history, changing production configuration.

Note the asymmetry with the section above: **opening** a PR needs no permission, but **claiming
it is ready** is a factual assertion that must be checked first.

## Write a PR description someone will actually read

Agents write essays. A reviewer opens the PR, sees six paragraphs, and scrolls past the part
that mattered. **Lead with bullets; put the long version in a collapsible block.**

```bash
pr-desc-check body.md                        # before creating the PR
gh pr view 12 --json body -q .body | pr-desc-check   # what ACTUALLY rendered
```

The rule it enforces:

- At most **12 prose lines** and **4000 characters** outside `<details>`
- Bullets, numbered items, headings, quotes, table rows and fenced code are **not** prose
- Anything inside `<details>…</details>` does not count at all

### Check the posted body, not just the draft

**Some tooling strips `<details>` from a PR body while keeping the text inside it.** The GitHub
MCP tools do: post a body through `create_pull_request` and the tags are gone, the prose is not,
and apostrophes come back HTML-escaped. Issue comments through the same server keep them, and a
body a human types keeps them — so it is that one path, not GitHub.

The consequence is the failure this guard exists to prevent, arriving silently: a description
scoring 2 prose lines locally renders as 20, and nothing says so.

So the second form above is the one that tells the truth. It reads what landed, by which point
any `<details>` is already gone, and counts that. Run it after creating or editing a PR, not only
before.

Where a body must stay short and the evidence is long, **put the evidence in a comment instead** —
`<details>` survives there — or write the body as bullets and tables, which do not count as prose
whether they are collapsed or not.

So there is no limit on how much you explain — only on how much a reviewer must read before
they find the point. Background, rationale, the story of what went wrong: all fine, collapsed.

```markdown
Fixes X by doing Y.

## What changed
- one bullet per change

## Verified
- what you ran, and what it said

<details><summary>Why the original approach failed</summary>

...the long version, as long as it needs to be...

</details>
```

**The top of a description answers three questions:** what changed, how you know it works, and
what you did not check. Everything else is background and belongs in the fold.

## Never block on a human

The issue tracker is the specification. If something genuinely needs a human decision, **file
it as an issue labelled `needs-human`** and keep working on something else. Stopping to ask in
chat stalls everything until a person happens to look. **An inline question tool is not an
option at all here** — no interruptions once work has started, however stuck. It blocks the
turn with no timeout, needs someone present at that moment, and loses the question if the
session ends.

```bash
file-issue question "..." --body "what you were doing, what needs deciding, what each answer changes"
```

Then take the most reasonable reading, say which you took, and carry on.

**Skip `needs-human` issues only while they are unanswered.** Blocked on an answer means
starting one produces a guess or another stall — but that ends the moment a human replies.

**A reply makes it workable again, label or no label.** The label records *who is waited on*,
not what may be worked; once someone has answered, nobody is waited on. Leaving an answered
question until the label is tidied wastes the whole round trip the question cost, and that is
the common way these go stale. Check for replies before filtering the list, not after:

```bash
check-replies        # exit 0 if anything is answered and workable
```

It reads the **agent mark** to decide who spoke last, which is why everything posted from here
carries one — see `opinionated-claude`. A comment you post without the mark reads as a human
reply, and the loop will pick the question up as answered by you.

## Never reply "will fix"

**Do not reply to a review thread until the fix is pushed.** Never "will do", "will fix", "will
update" — the reply describes what you **already did**, not what you intend to do. The sequence
is always: change, commit, push, *then* reply.

A reply promising future work is indistinguishable from one reporting completed work when the
reviewer reads it a day later, and they will assume the latter.

**Bot threads** — fix it, or justify why it is a non-issue, then resolve. If the finding
contradicts an instruction given earlier or a documented project decision, do **not** silently
comply: reply explaining the conflict, leave it unresolved, flag it.

Mark every reply and every PR description with the agent emoji — `reply-issue` does it for you;
`gh pr create` and `gh api` do not, so do it yourself there.

**Human threads** — fix it and reply describing the change, but do **not** resolve. Resolving
someone else's thread takes away their chance to disagree.

## A thread is done only when your reply is the last word

Review feedback is not discharged by replying — it is discharged by being the last person to
speak. Three rules, and the third is the one that fails silently:

- **"Addressed" means your marked reply is the latest comment in the thread.** A reviewer who
  answers after you reopens the thread, even if the fix landed — so each tick re-reads the
  threads you already posted in, not just new ones. The agent mark is what tells your last
  word from anyone else's; this is the same last-word test `check-replies` applies to
  `needs-human` issues.
- **Unaddressed threads pre-empt everything, CI included.** Read the threads *before* waiting
  on a pipeline: `gh api repos/{o}/{r}/pulls/{n}/comments` for inline threads, plus the
  general comments. If any thread's last word is not yours, a green pipeline proves nothing —
  fix, push, then re-check. Waiting for CI while review feedback stands is the waste the
  readiness gate exists to prevent.
- **Resolved means resolved on the platform, not in prose.** Where the host has a resolve
  action on threads, bot threads get resolved by you after the fix and human threads never
  do. A comment that says "done" without the resolution state discharges nothing.

## Arm a watcher on every open PR you own

The platform notifies you of failures, review comments and merges — but only while a session
is listening, and nothing is listening by default. **After opening a PR, arm a persistent
monitor on it** so review activity re-enters the loop without a human poke.

The watcher is a **webhook you poll for**. A webhook delivers one message per event — every
comment, every review, every check run completing, every merge. The watcher does the same,
aggressively:

- poll the PR's timeline events (`gh api repos/{o}/{r}/issues/{n}/events`) every minute or
  two, and the check runs for the branch head (`repos/{o}/{r}/commits/{sha}/check-runs`);
- keep the ids already seen in a state file, and **emit one line per unseen id** — one
  notification per event, exactly like a webhook delivery. A comment, a review, a label
  change, a run finishing, a run failing, a merge: each wakes the turn on its own;
- the ids are the events; nothing else is. Do not snapshot state and diff it — a
  state-diff watcher sleeps through the events themselves and wakes only when a bucket
  changes, which under-fires in exactly the way a webhook never does. Noise suppression
  belongs to the turn that receives the event, not to the watcher;
- **seed every stream on arming** — timeline ids *and* the existing check-run ids go into
  the state file silently, or the first poll replays the past as events;
- **one thing has no event: the base moving under the PR.** A merge to main makes every
  open PR stale without emitting a single event on any of them — no comment, no review, no
  check run, and webhooks see it no better. So the watcher polls the PR's own
  `mergeStateStatus` as a third signal and emits when it enters the actionable set —
  `BEHIND`, `UNSTABLE`, `DIRTY`, `BLOCKED` — with `CLEAN`/`UNKNOWN`/absent treated as one
  silent "steady" bucket so recomputes stay quiet. A watcher without this third signal
  watches everything except the one thing that grays the merge button.

That is the mechanism that makes "answer review threads" a loop step that actually fires
rather than a step that waits for someone to type. `pr-watch --wait` covers the CI wait; the
persistent watcher delivers everything that happens *between* waits, one event at a time.

## Long checks run in the background

Anything that can block for minutes — waiting on CI, a long test run — goes out as a background
call that returns immediately, so the agent can keep working while it runs. Wait for the
completion notification. **No `sleep` loops, no polling with `pgrep`.**

Read the *full* output when it arrives, including the summary, before deciding what to do.

## Schedule with something that outlives the container

A cloud container is suspended between messages, and anything holding in-process state dies
with it:

| Mechanism | Survives suspension? |
| --- | --- |
| In-process timers, `setTimeout`-style wakeups | ❌ gone when the process exits |
| Anything storing state only in the session | ❌ same |
| **`/loop` at any interval** (it schedules via `CronCreate`) | ❌ see below |
| Server-side scheduled messages (`send_later` / Routines) | ✅ delivered on resume |
| A scheduler *outside* the session (`loop-ctl`, launchd, cron) | ✅ the timer is not the thing being suspended |

Symptom of getting this wrong: the loop only advances when a human sends a message, and every
message shows a "resumed session" banner. The timer never fires because nothing is running to
fire it.

### `/loop` is not durable, at any interval

Worth stating plainly because the interval looks like it should matter and does not.
`CronCreate`, which every `/loop` schedules through, documents three things:

- *"Jobs live only in this Claude session — nothing is written to disk, and the job is gone
  when Claude exits."*
- Its `durable` parameter *"has no effect — durable persistence is not available."*
- *"Jobs only fire while the REPL is idle"* — so the session must still be alive **and** between
  turns.

Recurring jobs also **auto-expire after 7 days**. A `/loop 10m` and a `/loop 2h` are equally
in-memory; there is no threshold above which one becomes durable, and nothing offers you a
durable alternative when you ask for a short interval.

`/loop` is still the right tool for a loop you are watching — instant, no setup, and stopping
when you stop is what a watched loop should do. It is the wrong tool the moment you walk away.

### For unattended work, work out where you are, then choose

There is no single right mechanism. Environments differ more than they look, and the same
command can be present and useless: a container and a laptop both "have cron" right up until you
check whether any daemon is running to fire it. **So detect first, then decide.**

```bash
loop-env            # what this machine can actually schedule, and why not
```

It reports the OS, whether you are in a container, and — for each of launchd, cron and systemd —
not merely whether the command exists but whether anything would run the job. A `crontab` with no
daemon behind it accepts your entry and silently never fires it, which is the same failure as a
dead `/loop` with more setup.

That covers the machine. The other half is whether anything can reach the session **from
outside**, which only the agent can check:

```
get_session()      # claude-code-remote MCP, session_id omitted → describes this session
```

Read `environment_kind`. It puts you in one of three worlds, and they have genuinely different
answers:

| `environment_kind` | What it means | What survives |
| --- | --- | --- |
| `anthropic_cloud` | the session runs on Anthropic's infrastructure | **`send_later` chain.** The platform suspends and resumes you; a scheduled message is delivered on resume. Nothing of yours has to stay up |
| `bridge` | a local CLI, bridged out so a phone can reach it | `send_later` **while connected**. The message is delivered to your process — if that process is gone, so is the tick |
| no MCP at all | a plain local CLI, nothing outside can reach it | only a local scheduler, or `Monitor` |

### The options, and what each actually buys

Two different things can end a loop, and most mechanisms only handle one:

| Mechanism | Survives the session **exiting**? | Survives the session going **idle**? |
| --- | --- | --- |
| `/loop` (`CronCreate`) | ❌ *"gone when Claude exits"* | ❌ needs the REPL alive **and** between turns |
| A **backgrounded task** | ❌ dies with the process | ✅ the session is never idle while it runs |
| `send_later` chain | ✅ server-side Routine | ✅ delivered on resume |
| `loop-ctl` (external scheduler) | ✅ the timer is not in the session | ✅ |

Idle is the one that catches people, because it needs nothing to go wrong. A session with nothing
running is suspended as designed; the in-process timer suspended with it; and the next tick
arrives only when some *other* event wakes the session — typically a human typing, hours later.

**Confirm `send_later` really is server-side before relying on it**, rather than trusting the
name. Two checks, both cheap:

```
list_triggers()     # your send_later appears here, with a trigger_id and run_once_at
```

Appearing in an **account-level** trigger listing is the proof: in-session state cannot. Its docs
say *"delivery survives container restarts"*, where `CronCreate` says the opposite in as many
words. If `list_triggers` is unavailable in this session, the MCP server is not attached and
`send_later` is not an option here at all — do not assume it, check.

**A backgrounded task, when nothing durable is available.** This is the mechanism that addresses
*idle* specifically, and it needs no scheduler at all:

```
Bash(run_in_background: true)   # returns a task id immediately
```

The harness delivers a `<task-notification>` when the process exits, which wakes the agent. So
the session is never idle, and the wake is guaranteed by the process ending rather than by a
timer firing.

**Prefer backgrounding real work over backgrounding a sleep.** The waiting is usually the point:

```bash
pr-watch <n> --wait &     # blocks until checks settle, then reports the verdict
```

That is the whole tick for the common case — you were going to wait for CI anyway, so wait for it
in a way that also wakes you. A bare timer waits *and learns nothing*.

If there is genuinely nothing to wait on, a sleep is the degenerate form and is legitimate:

```bash
sleep 600 && echo "wake up"     # backgrounded; the notification is the heartbeat
```

Its limits are worth stating plainly: it dies with the session, so it recovers from **idle** but
not from **exit**, and it holds a process for the whole interval. Use it when nothing better is
available, and say that is what you did.

**`send_later`, re-armed every tick.** Server-side, so machine sleep, container suspension and
laptop lids stop being your problem. There is no "start" call — each tick schedules the next:

```
send_later(delay_minutes: 10, message: "<the tick prompt>")
```

**Re-arm as the tick's first action, never its last.** A tick that crashes, is interrupted, hits
a rate limit or runs out of context halfway has already scheduled its successor. Re-arming last
means every one of those ends the loop silently.

**An hourly `create_trigger` watchdog.** Hourly is the floor for a cron Routine, which is why it
is a watchdog rather than the heartbeat. Its job is to notice a broken chain and restart it. Two
independent schedules fail independently; one schedule is a single point of failure with extra
steps.

**`loop-ctl` — a local scheduler outside the session.** launchd, cron or systemd, running
`claude -p --resume` so the conversation is rebuilt from its transcript and no resident process
is needed. Right when nothing can reach the session from outside. Its caveats are physical:

- **a Mac that sleeps does not fire `StartInterval`** — it fires once on wake, so a laptop
  sleeping at 4am gives a multi-hour gap indistinguishable from a crash. `--caffeinate`, or
  `pmset -a sleep 0`. An always-on box does not have this problem and is the better host.
- **a container usually has no scheduler at all** — no launchd, often no cron daemon, no systemd.
  `loop-env` will tell you; do not assume.

**`Monitor` with `persistent: true`.** Not a timer — it wakes the session when something
*happens*. For a backlog loop that is arguably the better shape, because the real triggers are
events: CI turned green, a review landed, an issue was filed. Its limit is that it only wakes on
what it was told to watch, so an idle queue or a goal quietly reached still needs a heartbeat
underneath.

**`/loop`.** Correct for a loop you are sitting and watching, where stopping when you stop is the
desired behaviour. Never for unattended work.

### Layer them; they are not alternatives

The three jobs are distinct, and picking one mechanism usually leaves one of them uncovered:

| Job | Who does it |
| --- | --- |
| **Wake the session on a cadence** | `send_later` chain, `loop-ctl`, or a backgrounded task |
| **Keep the session from going idle at all** | a backgrounded task — the only one that does this |
| **Notice the cadence stopped** | the watchdog trigger, and `loop-run`'s gap warning |
| **Bring the session back if the process died** | *not the scheduler.* A restart policy, a supervisor, or a person |

That third row is the one most often missed, and it is exactly where a `bridge` session is
weakest. A server-side chain delivers to a process that must exist to receive it. If the
container has no `restart` policy, one OOM kill ends the loop permanently and every scheduled
message after it lands nowhere. **Check the restart policy before trusting a bridge session
overnight** — it is not part of the loop, and it is load-bearing for it.

### Say which you chose, and what it does not cover

State the mechanism and its gap in one line, so the next reader is not left inferring it:

> Heartbeat: `send_later` every 10m, re-armed first. Watchdog: hourly trigger. **Not covered:
> the container has no restart policy, so a crash ends the loop until someone restarts it.**

An unqualified "the loop is durable" is the claim that let a four-hour outage go unnoticed.

### A loop that stops must say so

From the inside, a stopped loop and a loop between ticks are identical. `loop-run` stamps every
tick and compares against the last one, and when the gap exceeds two intervals it tells **the
agent**, in the prompt:

> The previous tick was 4h 40m ago; the interval is 10m, so roughly 27 ticks did not fire.
> Treat the world as having moved on: re-read state from disk and the API rather than from
> memory of the last tick.

Note what is being measured: **ticks, not merges.** Downstream artefacts are the tempting
signal and the wrong one — in a repo where a human presses merge, merge timestamps record when
that human was awake, so an overnight gap in them proves nothing about whether the loop ran.
Only a stamp written by the tick itself distinguishes the two.

## Establish whether you may merge at all — once, before you merge anything

**Merge authority is a repository policy, not a property of the change.** Everything below is
about *which* changes are routine enough to merge without asking. None of it applies until you
know you are allowed to merge in the first place, and plenty of repos say no.

Signals that you are not:

- **A local pre-push hook** rejecting pushes to the default branch
- **Branch protection or a ruleset** requiring a review
- **`CODEOWNERS`** on the paths you touched
- **The human has said so.** This is the reliable one — see below

**A pre-push hook guards `git push`, not `gh pr merge`.** It stops you writing to `main`
directly and does nothing about merging a PR through the API, so an agent can respect the hook
and bypass the intent behind it completely. Detecting the hook and concluding "merging is fine
because the hook did not fire" is exactly the wrong reading.

**Ruleset detection is unreliable anyway.** On GitHub Free, rulesets are not enforced on private
repositories — so the absence of a block proves nothing about whether one was intended.

So: **ask once, early, and write the answer down** where the next session will find it — the
repo's `AGENTS.md` or `CLAUDE.md`, not a chat reply. "May I merge my own PRs here, or do you
review everything?" is one question that removes the whole class.

**Until you know, do not merge.** Open the PR, say it is ready, and move to the next issue. That
is not a stall — the work is finished and visible, and the next thing is already started.

## Merge, or ask — pick per change

*Applies only where you have merge authority. If you do not, none of this does.*

**Merge without asking** when it is routine, low-risk and reversible: dependency bumps, lint and
formatting, docs, test-only changes, anything already agreed this session. Waiting for
permission you already have is a stall in a different costume.

**Ask first** for anything the human should eyeball: new features or behaviour changes,
security, auth or access-control rules, schema and data migrations, deletions, config that
affects production, cross-repo or breaking changes — or when you resolved a review comment by
judgement rather than a mechanical fix.

When genuinely unsure, ask, and say why. Stopping costs one review round; merging the wrong
thing costs a revert.

## Fix classes, not instances

Before declaring a compatibility or resource bug fixed, grep for every other call site with the
same property, and ask what resource the change consumes. A fix that addresses the exact failing
line and leaves its siblings is a fix that will be reported again next week.

## Keep the local environment honest

Sandboxes reap background daemons between tool calls. A database that stopped between two
commands produces a "connection refused" that reads exactly like a code regression.

**Make test invocations self-healing** — ensure dependencies are up as part of running tests,
rather than restarting them reactively after misreading a failure.
