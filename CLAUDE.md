# Working this repository

## Merge authority

**A human reviews everything. An agent does not merge its own pull requests.**

Recorded from https://github.com/ZY-Ang/clawdy/issues/34, where the answer was:

> Human reviews everything by default. Only in extreme situations should a bot auto-merge
> its own PRs.

So the agent's job ends at **READY FOR REVIEW** or **READY TO MERGE**, proved with
`pr-watch`, and the next issue starts. Waiting for a merge is not a reason to idle.

"Extreme situations" is deliberately not enumerated here. If a case seems to qualify, it is
a case for asking, and asking costs one round trip against a merge nobody sanctioned.

This is written down because it is otherwise re-inferred every session — and the signals
mislead. A pre-push hook guards `git push`, not `gh pr merge`; on GitHub Free, rulesets are
not enforced on private repositories, so the absence of a block proves nothing; and a human
merging a PR themselves reads as policy or convenience with equal plausibility.

## Claim before you write code

`backlog-claim <n>` **before** the first commit, not after the work is done. It opens a
draft pull request immediately, and that is the point rather than a formality: with a PR
open from the first commit, a review finding becomes a thread GitHub tracks and resolves.
With no PR it has nowhere to live but a new top-level issue, competing with real work for
queue position.

That is not hypothetical here. Five open issues in this repo — 25, 27, 28, 29 and 30 — are
findings against branches that were in flight at the time. Every one should have been a
review thread.

## Tests assert what happened, not that nothing went wrong

A test that greps for the absence of an error passes when the binary dies with empty output,
and passes when the fix it guards is reverted. Four tests written in this repo failed exactly
that way, and each was found by mutation rather than by reading:

- one matched the hook's own help text, so it passed whatever the code reported
- one asserted an exit code that was identical with and without the fix
- one checked for "could not parse" against a binary that says "could not scan"
- one was silenced by a *later* fix, which stopped the failure being an error at all

**So mutation-test every fix: revert it and confirm the suite fails at exactly the test that
names it.** A fix with no failing mutation is a fix with no test, whatever the assertion says.

## A guard that never runs looks exactly like a guard with nothing to catch

Two hooks shipped non-executable and had never run once since release. Six test suites
refused to execute on any machine with `gh` installed, hiding 203 assertions and a call to a
function that does not exist. In all three cases the code looked present and the plugin
looked healthy.

Prefer checks that fail loudly on absence: `.github/bin/hooks-executable` asserts every hook
named in a `hooks.json` is executable **in the git index**, because a filesystem that reports
everything `0777` — a network share, a mounted volume — hides the committed mode entirely.
