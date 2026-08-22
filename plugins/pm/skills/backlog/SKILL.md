---
name: backlog
description: Decide what to work on next from a tracker, in an order that is the same every time — severity first, then priority, urgency, and how much other work each item unblocks. Use at the start of a loop tick, when picking up work, or when a backlog has grown faster than it is being cleared.
user-invocable: true
---

# pm

**`issues` files work. `devloop` says how to land it. Nothing ordered it** — and on a loop running
unattended that is the binding constraint, not the code.

```bash
backlog-queue              # what to work on, best first
backlog-queue --why        # the sort key beside each line
backlog-queue --blocked    # what is not ready, and what is holding it
backlog-queue --top 5

backlog-claim 42           # bind it to a branch, open the draft PR now
backlog-release 42 --reason "blocked on the DNS record"
```

Exit `0` when something is ready, `1` when nothing is, `2` when it could not tell. **An
unreachable backend is never a pass** — the same rule `pr-watch` holds.

**Read the status from the command itself.** After a pipe, `$?` is the last stage's — so
`backlog-queue | head` reports `head`'s `0` however the queue exited, and POSIX `sh` has no
`PIPESTATUS` to recover it. That mismeasurement has already produced a confident bug report
against a tool that was behaving correctly.

## Why an order at all

A loop that takes the first open issue it reads works whatever it happened to see first. Measured
over 72 hours of one real unattended loop:

- **160 issues filed, 117 still open** — findings arrived about twice as fast as fixes landed
- **45 of those open issues are findings against an unmerged branch**, competing with real work
- one defect shape was filed **six times against six files**; four instance-fixes shipped and the
  class fix is still open

That last one is the shape this exists to fix. Instances are small and land easily; the class fix
is bigger and never rises. Ordering by *how much other work an item unblocks* inverts that
**between an item and the work it blocks** — dependents is the **fourth** key, so it separates a
class fix from its own instances rather than lifting it past unrelated higher-priority work.

That distinction matters because the stronger reading is the one an agent acts on: it links the
instances, expects the class fix near the top, does not find it there, and re-derives the sort
order to discover nothing is broken.

## The order

Lexicographic over fixed keys. **No weights** — weights are a permanent argument, and changing one
silently reorders everything.

| Key | Meaning |
| --- | --- |
| severity | `data-loss-risk` or `security`, above everything else |
| **untriaged** | **nobody has classified it** — above all ranked work, below severity |
| priority | cost if this is **never** done. Ages upward one whole step per `ESCALATE_DAYS` (21), capped at high |
| urgency | whether **waiting** makes it worse |
| dependents | how much other work closing this unblocks |
| size | `size-s` before `size-l` — finish things rather than start them |
| number | oldest first, so the order is **total** and reproducible |

Priority and urgency are separate on purpose. Unencrypted backups are high priority and low
urgency — catastrophic, no worse next week. An expiring certificate is the reverse. One blended
score destroys exactly the distinction a person cares about.

## Ready, and the four ways not to be

```
ready = open
        AND (not needs-human, OR a human has replied since the last agent comment)
        AND not claimed
        AND not finding
        AND every blocker closed
```

- **`needs-human`** blocks only while *unanswered*. The verdict is the same one `check-replies`
  computes — the last comment being agent-marked means the ball is still with the human. One
  definition, not two that drift.
- **`claimed`** means a branch is on it.
- **`finding`** is a review finding against an unmerged branch. It is a sub-issue of the
  deliverable and never queues on its own.
- **blockers** come from the tracker's own dependency graph, not from prose. A branch named in a
  sentence does not resolve; `blockedBy` does.

## Claiming, and why the pull request opens first

Ordering tells you what to do next. It does **not** stop two sessions doing the same thing — and
it makes that collision *more* likely, not less, because both sessions now agree on what is first.

```bash
backlog-claim 42
```

Three things happen together, and the middle one is the reason this exists:

1. a branch, named from the issue title unless you pass `--branch`
2. **a draft pull request, opened immediately** — not when the work is finished
3. the `claimed` label, so the queue skips it

**The draft PR is the structural fix, not a formality.** With one open from the first commit, a
review finding becomes a thread GitHub tracks and resolves. With no PR, that same finding has
nowhere to live but a new top-level issue, competing with real work for queue position — which is
how **45 of 117** open issues on one measured backlog came to be findings against unmerged
branches.

The order of operations is deliberate: **PR before label.** If the label lands and the PR does
not, the queue hides an issue that nothing is actually working on.

`backlog-claim` is **idempotent**. Claiming twice reports the existing claim and exits `0` — it
creates no second branch, PR or comment. A loop re-reading its own queue *will* re-claim, and
failing there would train it to ignore the exit code.

It refuses three things before writing anything: a **closed** issue, one labelled **`needs-human`**
(answer it first), and one labelled **`size-l`** without `--force` — a large issue held under one
claim is how a branch goes quiet for a week while the queue reports it as being worked.

### Handing one back

```bash
backlog-release 42 --reason "blocked on the DNS record, filed #58"
```

`--reason` is required. Whatever stopped you is the one thing the next session cannot work out for
itself. The comment posts **before** the label comes off, so the issue can never return to the
queue with no record of why it was dropped.

**The branch and its draft PR are left alone.** Work already pushed is evidence, and deleting it
to tidy up a label loses the only record of what was tried.

## Labels

Five axes. The first three decide order; `size` is a late tie-break; `area-*` is for batching.

```
priority-high | priority-med | priority-low
urgency-high  | urgency-low
data-loss-risk | security          ← already exist in mvp-kit's labels.json; reused, not reinvented
size-s | size-m | size-l
area-<thing>
```

Plus three written by tooling and never by hand: `needs-human`, `claimed`, `finding`.

**An unlabelled issue sorts second, not medium.** Treating a missing axis as medium keeps it from
being *last*, and medium is exactly where things get buried — indistinguishable from work somebody
deliberately ranked as medium. An unlabelled backlog does not rank badly, it ranks **flat**:
everything ties on the first keys and falls through to issue number, which is the arrival order the
queue exists to replace.

So an issue missing any of priority, urgency or size sorts **above all ranked work and below
severity only**. One place down from "this could lose data", which is what *nobody has looked at
this yet* is worth: it cannot be ranked until it is classified, and classifying it costs three
labels.

`--why` says so, because a position that looks like a ranking and is not is the ambiguity that
produced #48:

```
#2  nobody chose anything
    UNTRIAGED: priority,urgency,size not supplied. It is here to be classified, not because
    anyone ranked it -- the priority shown is a default, not a decision.
```

**`needs-human` is exempt.** A question is not queue work, and `file-issue` does not ask it for
axes. Clearing the label with `reply-issue --clears` is what turns it into work — and that is the
moment it becomes untriaged and surfaces here, which is the behaviour wanted and comes for free.

**Safe now, and not before.** `file-issue` has required the three axes on a task since #38, so
nothing new arrives unlabelled. The untriaged set is closed and shrinking — legacy issues, and
anything raised by hand in the web UI — so promoting it is self-correcting: each item leaves the
position the moment somebody classifies it.

## What still works when the tracker does not

The split is a property of individual tools, not a reason to install two plugins. `persist.sh`
writes a question to disk **before** any tracker is touched, so the discipline half never depends
on the network being up.

| Needs a provider | Works with nothing at all |
| --- | --- |
| `file-issue`, `ask-async`, `reply-issue`, `check-replies`, `backlog-*` | `questions`, `interview-window`, the hooks |

A tool in the right-hand column never returns "could not reach the tracker", because it never
tries. That is why an unreachable API is exit `2` and not a silent pass in the left-hand column —
the two halves fail differently on purpose.

## Other trackers

The provider is a seam, not an abstraction added later. `lib/provider-github.sh` implements four
functions; an adapter for another backend is a new file behind the same contract.

The plugin is named `pm` because GitHub is where it starts. If the suite outgrows the prefix,
the rename is cosmetic — nothing above the seam knows which backend it is talking to.

**Degradation is part of the contract.** `gh` exposes `blockedBy` only where the instance supports
issue relationships, so the provider tries and falls back rather than letting one unsupported
field cost the whole queue. A backend with no dependency graph produces an order without the
dependents term, not an error.

## When the backlog itself is the problem

`backlog-queue` answers *what next* and is deliberately silent about the state of the list it ranks.
A backlog can produce a confident order and still be unusable.

```bash
backlog-triage                 # every check
backlog-triage --only cycles
backlog-triage --quiet         # counts only, for a loop tick
```

Exit `0` nothing wrong · `1` something to fix · `2` could not tell. Five checks, each a shape
measured on a real backlog rather than imagined:

| Check | What it found when it was measured |
| --- | --- |
| `cycles` | **7**, three of them real and blocking |
| `stale` | a claim with no movement for `STALE_HOURS` (default 24) |
| `axes` | **0 of 118** issues carried a priority |
| `human` | 2 answered issues still labelled, 9 needing it unlabelled |
| `orphans` | findings with no parent, competing for queue position |

**A cycle always exits 1.** An order that silently picks one side of a cycle is an order that cannot
be built in the sequence it gives, so it is reported and not ranked around.

`human` reads the same verdict `check-replies` computes — the last comment being agent-marked means
the ball is still with the person. An agent replying to its own question does **not** count as an
answer, which is the `needs-human`-outlives-the-answer bug seen from the other side.

`axes` skips `needs-human` issues. A question is not queued; it gets its axes when it becomes work.

## Recording that one thing blocks another

```bash
backlog-link 12 --blocked-by 7      # 12 cannot start until 7 closes
backlog-link 10 --blocked-by 11,12  # a class fix absorbing its instances
backlog-link 12                     # what is blocking 12 right now
backlog-link 12 --unblock 7
```

This is what makes the dependents term mean anything. An instance that declares the class as its
blocker leaves the ready set, and the class accumulates the count that lifts it.

On the backlog this was designed from the graph was **entirely unused** — every `blockedBy`,
`blocking`, `parent` and `subIssues` empty across all 160 issues — while five findings named their
blocker **in a sentence**. A branch named in prose does not resolve.

**The id is not the number.** GitHub takes the issue *number* in the URL and the numeric *id* in the
body; passing the number in both fails with a message naming neither. `backlog-link` does the
lookup, so no caller has to rediscover it.

Idempotent: re-linking an existing edge reports it and sends nothing.

## Issues that want to be one branch

```bash
backlog-cluster            # groups, biggest first
backlog-cluster --min 3
backlog-cluster --unkeyed  # the ones naming no file at all
```

Eleven separate branches against one script is eleven rebases and eleven reviews of the same file.

**Keyed on structure, not text.** On the measured backlog, **zero** open-issue title pairs exceeded
0.34 token overlap — titles are written distinctively enough that any lexical similarity tool finds
nothing and gets trusted anyway. What actually clusters is the file being touched.

A path is a token with a slash, **or** a dotted filename. Requiring an extension was the first
attempt and it missed this repository's dominant shape entirely: every binary here is an
extensionless shell script, so `plugins/pm/bin/backlog-queue` — the exact case #22 measured as *"one
shell script, 11 open issues"* — matched nothing.

`--unkeyed` is the inverse signal and is not a leftover: **33 issues named no file at all**, and
those were every large design issue — precisely the ones that starve.

Advisory. It prints groups; it does not link, label or close anything.

## Proving the order without a network

```bash
BACKLOG_ISSUES_JSON=fixture.json BACKLOG_NOW=1787184000 backlog-queue --why
```

`BACKLOG_DEPS_JSON` states the whole dependency graph, **replacing** whatever the issues carry —
never merging, so a case states its graph in one place instead of depending on two files at once.

```bash
BACKLOG_ISSUES_JSON=issues.json BACKLOG_DEPS_JSON=graph.json backlog-queue --why
```

It exists because the edges are the hardest input to obtain and the easiest to get wrong. On the
backlog this was designed from, `blockedBy` was empty on **all 160 issues** — so a fixture drawn
from real data proves the field parses and nothing whatever about what it does. The dependents term
is the one thing lifting a class fix above its instances, and until this seam existed there was no
way to show it working.

`BACKLOG_NOW` is **not optional** in a test. Without a fixed clock every ordering case drifts a day
at a time and starts failing on some later Tuesday for no reason anyone can reproduce.
