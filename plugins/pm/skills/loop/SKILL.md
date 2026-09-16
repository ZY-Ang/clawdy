---
name: loop
description: Run a whole backlog unattended — triage what arrived, order it, claim the top item, drive each pull request to ready with devloop, close what landed, and arm a heartbeat so the loop comes back. Use when asked to clear a backlog, work a repo continuously, or keep going without being prompted each time.
user-invocable: true
---

# pm:loop

**`devloop` is per pull request.** Its whole vocabulary — is this one mergeable, are its
checks green, are its threads answered — is scoped to one PR, and that is right for what it is.

The layer above it has had no owner: the backlog as a whole, over time. That is this.

```
/pm:loop            one repo, continuously
  ├─ triage         label what arrived unlabelled, before it is invisible
  ├─ order          backlog-queue
  ├─ claim          backlog-claim, which opens the draft PR
  ├─ devloop        ← per PR, unchanged, invoked once per claimed item
  ├─ close          what the merge settled, and the questions it answered
  └─ heartbeat      backlog-watch, which brings the turn back to all of it
```

`devloop` is not replaced or wrapped in prose. It is **called**, once per PR in flight, and
stays exactly what it is.

## The tick

Six steps. The first and last are the ones that did not exist before.

### 1. Triage — because nothing else is looking

```bash
backlog-triage            # every check
backlog-triage --quiet    # counts only
```

**An unlabelled issue is open and invisible at the same time.** `backlog-queue` skips anything
without priority, urgency and size, so an issue filed bare never reaches the order at all.

`file-issue` refuses to file a task without those axes. But `gh issue create` does not, and it
is the obvious command — an agent reaching for it is not being careless, it is using the tool
that is there and works. Three issues sat unlabelled in one repo for up to nine days that way,
while the loop reported itself healthy.

Enforcing it at the point of filing was considered and rejected (clawdy#86): a guard that
refuses a command correct in every other use gets switched off, and then protects nothing.
**So this step is load-bearing, not an improvement.** It is the only thing standing between a
bare filing and an issue nobody ever ranks.

Label what has no axes. Where the right values are genuinely unclear, `priority-med /
urgency-low / size-m` and an `area-*` is better than leaving it bare — an issue ranked
roughly is in the order; an issue unranked is not in it at all.

`backlog-triage` also finds dependency **cycles** (an order that cannot be built in the
sequence it gives), **stale claims** (a branch nothing has touched), and `needs-human`
**answered but still labelled**. A cycle always exits 1 and is never ranked around.

### 2. Order

```bash
backlog-queue --why
```

Severity, then untriaged, then priority, urgency, dependents, size, number. Read the exit
status from the command itself — after a pipe `$?` belongs to the last stage, and that
mismeasurement has already produced a confident bug report against a tool behaving correctly.

### 3. Claim

```bash
backlog-claim 42
```

Branch, **draft PR opened immediately**, then the `claimed` label. The PR before the label is
deliberate: if the label lands and the PR does not, the queue hides an issue nothing is
working on.

Independent items fan out to subagents in their own worktrees. Serialise only where the
dependency is real.

### 4. devloop, per PR

For each PR in flight, the `devloop` contract applies unchanged: prove it with `pr-watch`
before the words "ready for review", answer review threads only after the fix is pushed, and
never let a verdict outlive a merge to the base.

**The base moving is the event that invalidates every open PR at once.** After anything lands,
re-check before repeating the word "ready" — including for a PR reported ready moments ago.

### 5. Close what landed

A merge settles things that are not the issue it closed:

- questions the work answered — `questions answer <id> "<what was decided>"`
- issues describing behaviour that no longer reproduces — reproduce first, put the output in
  the comment, and record **which** of completed / not-planned / duplicate it was
- branches and worktrees whose PRs are merged — `stale-branches` finds them

### 6. Heartbeat — the step that cannot be left to discipline

```bash
backlog-watch                    # blocks until something happens, then exits
backlog-watch --interval 120
```

Run it **as a background command the harness owns**, not in the foreground. It exits on the
first unseen event and prints it along with the queue and the gate, so the resumed turn has the
ranked work in front of it rather than having to go and ask.

It watches six things because no smaller set is sufficient:

| | |
| --- | --- |
| issue `updatedAt` | new issues, comments, labels, closes — and the only way a *new* issue with no comments announces itself |
| PR timeline | registers only some reviews, no inline comments |
| PR reviews | a review without inline comments lives only here |
| PR comments | an inline review comment lives only here |
| check runs | CI, which is evented on **failure only** — a run turning green is delivered to nobody |
| base tip | a merge grays every open PR's button and emits nothing anywhere |

**Why a watcher rather than remembering to re-arm.** The tick's last step used to be "re-arm
the timer", and re-arming was the agent remembering. Miss once and the session goes quiet: no
prompt, no error, just work that stopped. From outside, "waiting" and "stuck" are the same
picture — which is why the failure survives so long.

The point of the heartbeat is not the polling. It is that it **comes back and puts the list in
front of the agent again**.

A quiet expiry and an event both exit 0, and both mean the same thing: re-arm.

## Never end a tick in a hold

If every PR is in CI, that is not a reason to idle — it is a reason to start the next issue.
A tick that ends with nothing started and nothing watching has ended the loop.

Two things make a hold legitimate, and only two: the queue is genuinely empty, or everything
left is `needs-human` and unanswered. In both cases the heartbeat still arms.

## Merge authority

**The loop drives to ready. It does not merge.** `pr-watch` exiting 0 with READY TO MERGE is
where an agent's job ends unless the repository says otherwise; waiting for a human to merge is
not a reason to idle, because step 3 has more work in it.

## What this is not

- **Not a replacement for `devloop`.** That is called per PR and is the right shape for one.
- **Not `pm:backlog`.** Ordering answers *what next*; this answers *keep going*.
- **Not a scheduler.** `backlog-watch` waits for the repository to change. For running on a
  wall-clock cadence regardless, that is `/loop`.
