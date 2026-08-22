# Contributing

Small, opinionated tools that do one job. The rules below are all paid for — each
one exists because something broke without it.

**Writing a tracker backend?** See [`plugins/pm/lib/PROVIDERS.md`](plugins/pm/lib/PROVIDERS.md).

## Shell

**POSIX `sh` only.** No bash, no python3, no node. `gh` and `jq` are the only
dependencies, and `jq` is checked for rather than assumed.

`dash -n` runs over every script in CI. bash accepts things dash does not, and a
bashism (`${2//|/\|}`) shipped here once before that check existed.

Two traps that have each cost a session:

- **An apostrophe inside a single-quoted `jq` program ends the program.** A comment
  saying "the gh nodes" is fine; "gh's nodes" hands the rest of your script to the
  shell. Both jq programs in `pm` now say so in place.
- **An `EXIT` trap whose last command fails clobbers the exit status.** Write
  `trap 'rm -f "$F" 2>/dev/null || :' EXIT`. Without the `|| :` a script that had
  decided on `2` exits `127`.

## Exit codes

`0` yes · `1` no · `2` could not tell. **Never collapse "could not ask" into "no".**

Read a status **unpiped**: after a pipe `$?` is the last stage's, and POSIX `sh` has
no `PIPESTATUS`. That mismeasurement has already produced a confident bug report
against a tool behaving correctly.

**Never discard the underlying tool's diagnostic.** Capture it and print it under your
own message. Three different failures once printed the same four words.

## Tests

One file per binary, in `plugins/<plugin>/tests/`. Fixture-driven, no network, no
real `gh` — four suites refuse to run if a real one is on `PATH`, because their
fixtures carry repo names a live binary would take to the network.

One exception, opt-in: `plugins/pm/tests/live.test.sh` runs a full round-trip
against a throwaway repo (`PM_LIVE_REPO=owner/scratch sh .../live.test.sh`) and
skips loudly when unset. It exists because a fixture cannot catch a wrong scalar
type in a request body — #45 passed every test and 422'd against every real
repository.

It has never run against GitHub, deliberately: automating issue and pull request
creation there may violate GitHub's terms. It is the acceptance test for a
provider whose backend terms allow such traffic — a known gap, documented in
the suite header rather than hidden.

**Pin both directions.** A check that only ever fires is indistinguishable from one
that always fires. Most bugs found here were found by the negative case.

**Assert the thing, not something implied by it.** A test asserting `issue_id=9911`
passes whether the flag is `-f` or `-F` — and the difference between those two was a
tool that could not write to any real repository.

**A fixture for a wire format has to come off the wire.** Capture it once and commit
it. A hand-written one is written by the same misunderstanding as the code.

**Bare `PATH` sandboxes lose `dirname`.** Three separate suites have hit this. Link
what the script needs, then *assert* the thing you are removing is really gone —
otherwise the case passes for the wrong reason.

## Layout

```
plugins/<name>/
  .claude-plugin/plugin.json   seven fields, same order
  SKILL.md                     or skills/<name>/SKILL.md for more than one
  bin/  lib/  hooks/  tests/
```

`SKILL.md` at the plugin root; `skills/<name>/SKILL.md` only when a plugin carries
more than one skill. Slash commands come from `user-invocable: true`, not a
`commands/` directory.

Anything invoked from a hook uses `${CLAUDE_PLUGIN_ROOT}`. Only the Bash tool gets
bare names on `PATH`.

**Do not source across plugins.** Vendor the file and say so in a comment. A guard
that silently does nothing when a sibling plugin is absent is worse than no guard.

## Versions

**Every shipped change bumps its plugin's version.** `.github/bin/require-version-bump`
enforces it; `tests/` is excluded, since no installed user runs those.

If two branches bump to the same number and one merges first, the second needs its
own bump — the number that landed is taken. Go *past* it; do not match it. That has
happened, and the loser silently republished a version already out.

## Pull requests

CI must be green — the `suite` check is required and `main` cannot be force-pushed.

Say what is **not** proven. Every PR here carries that section, and it is the part
most likely to be read later: "never run against a live `gh`" was the honest note
that turned out to be hiding a tool broken against every real repository.

## Agent-authored content

Anything posted to GitHub by a tool here is prefixed 🤖. It is not decoration:
`check-replies` and `backlog-triage` decide *has a human replied* from it, because
an agent posts under the human's own token and the author distinguishes nothing.

Add it if missing, never reject. A guard that refuses teaches agents to route around
it; one that quietly does the right thing cannot be forgotten.

**This repository is public.** There is no scrubbing step between a tool and a filed
issue. Employer names, internal hostnames and product names do not belong in one, and
editing after the fact does not remove them — GitHub keeps prior revisions.
