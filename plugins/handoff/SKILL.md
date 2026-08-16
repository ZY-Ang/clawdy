---
name: handoff
description: Generate a structured handoff document that lets a fresh Claude Code session resume work without re-discovering context. Use whenever the user runs /handoff, asks to "wrap up", "hand off", "save context", "pass to a new session", says the context window is getting full, mentions auto-compact is about to fire, or otherwise signals they want to stop and continue later with a clean slate. Also use proactively at the end of a long debugging or implementation session before the user has to ask.
---

# Handoff

Produce a `handoff-<session>-<description>-<time>.md` file that a brand-new Claude Code session can read and immediately continue the work — no archaeology required.

## When this runs

The user invokes `/handoff` (optionally with a session name: `/handoff payment-bug`). They may also just say "let's wrap this up for a new session" or "I'm running out of context, save state."

## Filename format

Write to `$CLAUDE_HANDOFF_DIR/handoff-<session>-<description>-<time>.md`, defaulting to
`~/.claude/handoffs/` when that variable is unset. Create the directory if it doesn't exist.

Set `CLAUDE_HANDOFF_DIR` to keep handoffs somewhere else. If you point it inside a repo, add
that path to `.gitignore` — handoffs are scratch state and should not be committed.

- `<session>`: the optional argument the user passed. If they didn't pass one, omit this segment entirely — the filename becomes `handoff-<description>-<time>.md`.
- `<description>`: a 2-4 word kebab-case slug you infer from the session's goal. Pick something a future Claude will recognize at a glance: `fix-resolve-bug`, `scrub-git-history`, `add-retry-logic`. Don't use vague words like `updates` or `changes`.
- `<time>`: current local time as `YYYY-MM-DD-HHMM`. Get it from `date +%Y-%m-%d-%H%M` — never invent it.

Because the timestamp makes the filename unique, you should not collide with an existing handoff. If somehow the file does exist, append a `-2`, `-3`, etc. suffix rather than prompting.

## What goes in the file

Six sections, in this order, each H2 except Goal which is H1. The whole document should be skim-readable in under 30 seconds — a future Claude needs the *signal*, not a transcript.

```markdown
# Goal
One or two sentences. What are we ultimately trying to build or fix? Not "the user asked me to..." — the underlying objective, stated as if explaining to a teammate joining mid-project.

## Current state
Where the work stands right now. What's done, what's working, what's half-built. Concrete: "X endpoint returns 200 with the right shape, but Y still throws on null inputs." Not "we've made progress on the API."

## Files in flight
The files actively being modified this session, with one line each on what's changing in them. Use repo-relative paths.
- `path/to/file.ts` — added retry logic to `fetchUser`, not yet handling 429s
- `path/to/other.py` — refactored, tests not updated yet

## Changed
What's been touched and saved this session. Distinct from "Files in flight" — these are completed edits the next session inherits. A bulleted list of files with a short description of what changed in each, oldest to newest.

## Failed attempts
What was tried that didn't work, and *why*. This is the most valuable section — it prevents the next session from re-walking dead ends. Be specific about the failure mode.
- Tried using `Promise.all` for the batch — hit rate limit, switched to sequential with 200ms gap.
- Considered moving the parser to a worker — overhead exceeded the parse cost for typical inputs.

## Next step
The single next thing to try. One concrete action, not a roadmap. If there's a roadmap, put it in Current state and pick one item for this section.
```

## Filling in each section — how to gather the content

Don't ask the user "what's the goal?" — they just said `/handoff`, that's the opposite of what they want. Reconstruct from the session itself:

- **Goal**: Look back at the first substantive message in the session, plus any pivots. State the durable objective, not the literal opening request.
- **Current state**: Survey what's been built or fixed in this session. If there's a TODO list in context, use it. If tests have been run, note the last result. Be honest about half-done work.
- **Files in flight**: Run `git status` and `git diff --stat` to see what's modified but uncommitted. Cross-reference against files the assistant has edited this session.
- **Changed**: Files where edits *have* been committed or saved this session. `git log --since=<session start> --name-only` or just the assistant's own record of writes.
- **Failed attempts**: Scan the session for "that didn't work", error messages followed by a pivot, reverted edits, abandoned approaches. This requires actually reading the conversation, not just the diff.
- **Next step**: Whatever was about to happen when the handoff was called. If unclear, infer from the last "I'll now..." or "next we should..." statement. One item.

## Style rules

- Past tense for what happened, present for current state, imperative for the next step.
- No filler. No "we successfully implemented..." — just "implemented X."
- File paths in backticks, repo-relative.
- No section may be empty. If there are genuinely no failed attempts, write "None this session." rather than leaving it blank — a blank section reads as "I forgot to fill this in."
- Don't include things a fresh session will discover for itself (the project's general structure, the language, framework versions). Include only what's session-specific.

## After writing the file

Print to the user:
1. The path written.
2. A two-line summary: the Goal line, and the Next step line.
3. A suggested kickoff prompt for the next session, e.g. *"Read `~/.claude/handoffs/handoff-payment-bug.md` and continue from Next step."* Use the real path you wrote, so it can be pasted as-is.

Do not commit the handoff file or stage it for git unless explicitly asked. Handoffs are scratch state, not project artifacts. Do not run `git stash` either — if the working tree is dirty, that's the next session's starting context, and worktrees are the right tool for isolating parallel work.

## Example output

For a session that was debugging a flaky integration test:

```markdown
# Goal
Stabilize the `checkout.integration.test.ts` suite — it's been flaking on CI roughly 1 in 5 runs and blocking merges.

## Current state
Isolated the flake to the `applies discount code` test. The flake is timing-related: the test asserts on the cart total before the discount mutation finishes. Two of three identified race conditions are fixed; one remains in the `removeDiscount` path.

## Files in flight
- `src/checkout/cart.ts` — added `await` on the discount mutation in `applyDiscount`, mirror fix not yet applied to `removeDiscount`
- `test/checkout.integration.test.ts` — added `waitFor` around the assertion, may also need it on the removal test

## Changed
- `src/checkout/cart.ts` — fixed missing await in `applyDiscount`
- `test/utils/wait.ts` — extracted shared `waitForCartUpdate` helper

## Failed attempts
- Tried bumping the test timeout to 10s — flake persisted, confirming it's a logic race not a slow test.
- Tried mocking the discount API to resolve synchronously — masked the bug rather than fixing it, reverted.

## Next step
Apply the same `await` fix to `removeDiscount` in `src/checkout/cart.ts`, then run the suite 20x locally with `vitest --repeat 20` to confirm stability.
```
