# Writing a provider

`pm` talks to one tracker through one file. This describes the contract that file
implements, and the places where GitHub's shape has leaked into it — so you find
those out here rather than after writing the code.

`lib/provider-github.sh` is the reference implementation. `lib/provider-gitlab.sh` is the
second, through the public `glab` CLI: it lists and views issues, and writes issues and
MRs. The authenticated remainder — the issue-link graph and the needs-human notes —
waits on a token (issue #18).

## Where the seam is

Every binary in `bin/` goes through it. `tests/seam.test.sh` fails the build if one
stops doing so, because a prose promise about an interface decays silently — six of
the ten tools called `gh` directly for weeks and nothing said so.

Two knobs, and they answer different questions: **`PM_PROVIDER`** picks *which backend*,
**`PM_REPO`** picks *where its issues go*. Without the second, the backend CLI resolves the
project from the current directory's git remote — so a question filed by an agent lands in
whatever repository its shell happened to be standing in. Both take a per-call `--repo`
override, and leaving `PM_REPO` unset keeps the old cwd behaviour exactly.

Which provider loads is chosen by **`PM_PROVIDER`**, default `github`:

```sh
PM_PROVIDER=jira backlog-queue
```

Every binary goes through `lib/load-provider.sh`, so there is nothing to edit. An unknown name
exits `2` and lists what it did find; a file that loads without defining the contract exits `2`
and points here, rather than failing three calls later as `provider_issues: not found`.

## The contract

`provider_name` and `provider_available` are the only two everything needs. The rest
are needed by the tools that use them; implement what you use.

| Function | Returns | Used by |
| --- | --- | --- |
| `provider_name` | a word, for messages | everything |
| `provider_pr_ref_mark` | the markdown glyph that references a code-review item (`#` vs `!`) | `backlog-claim` |
| `provider_available` | `0` if reachable now | everything |
| `provider_issues <repo>` | open issues, JSON array | `backlog-queue` `backlog-cluster` |
| `provider_issue <n> <repo>` | one issue, JSON | `backlog-claim` `backlog-release` |
| `provider_needs_human <repo>` | blocked issues + comments, **oldest first** | `check-replies` |
| `provider_create_issue <repo> <title> [label…]` | URL; **body on stdin** | `file-issue` `ask-async` |
| `provider_comment <n> <body> <repo>` | — | `reply-issue` `backlog-*` |
| `provider_label <n> <label> add\|remove <repo>` | — | `reply-issue` `backlog-*` |
| `provider_issue_labels <n> <repo>` | names, one per line | `reply-issue` |
| `provider_close_issue <n> <reason> <repo>` | — | `reply-issue` |
| `provider_ensure_label <label> <repo>` | always `0` | `file-issue` `ask-async` |
| `provider_supports_deps` | `0` if a dependency graph exists | `backlog-queue` |
| `provider_is_triaged <issue-json>` | `0` triaged · `1` not · **`2` cannot tell** | ordering |
| `provider_blocked_by <n> <repo>` | blocker numbers | `backlog-link` |
| `provider_issue_id <n> <repo>` | the backend's own id | `backlog-link` |
| `provider_link` / `provider_unlink` | — | `backlog-link` |
| `provider_open_draft_pr` / `provider_find_pr` | URL / number | `backlog-claim` |

### The normalised issue

```json
{ "number": 12, "title": "...", "state": "OPEN", "labels": ["task"],
  "createdAt": "...", "updatedAt": "...",
  "comments": [{ "author": "...", "body": "..." }],
  "blockedBy": [7, 9] }
```

**Labels may be strings OR objects, and consumers must accept both.** `gh` returns
`[{"name":"task"}]`; `glab` returns `["task"]`. The idiom `(.name // .)` looks like it
handles both and does not — `//` catches `null` and `false`, while indexing a *string* with
`.name` is a hard jq error. Use `(if type == "object" then .name else . end)`. Every binary
that read a label carried the broken form, so the whole toolset died on the second backend.

**Timestamps may carry fractional seconds.** GitHub sends `...T10:12:28Z`, GitLab sends
`...T10:12:28.895Z`, and jq's `fromdateiso8601` rejects the fractional part outright. Trim
before parsing rather than making each provider round.

**Anything you cannot supply is an empty array, never absent.** A consumer that has to
test for missing keys grows a branch per backend, which is the coupling the seam exists
to prevent.

**Comment order is part of the shape, and `check-replies` turns on it.** It reads the LAST
comment and asks whether it carries the agent mark; reversed, every question is reported as
the opposite of its real state and still looks like it works. A backend that mixes its own
activity records into the comment stream must strip them — GitLab files "changed title
from" and "marked as related to" as notes alongside human ones, so an untouched stream
reports a question as answered by whatever the tracker last did to it.

`blockedBy` accepts a bare integer **or** an object carrying `number`. Both, because
`gh` returns different shapes from different subcommands — and because this repo's own
queue was broken on its own documented form for two releases (#33, #41).

## Rules that are not style

**An unreachable backend is never a pass.** `0` ready · `1` not ready · `2` could not tell.
Never collapse "I could not ask" into "there is nothing". Read the status **unpiped** —
after a pipe `$?` is the last stage's, and POSIX `sh` has no `PIPESTATUS` (#39).

**Degrade, do not fail.** `provider_supports_deps` is the pattern: probe once, and if the
backend has no dependency graph, produce an order without the dependents term rather than
an error.

**A capability can be licensed, not just absent.** GitLab's blocking issue links are a paid
feature. Measured against a real project on gitlab.com free:

| `link_type` | result |
| --- | --- |
| `is_blocked_by` | `403 Blocked issues not available for current license` |
| `blocks` | `403`, the same |
| `relates_to` | `201`, a symmetric "related" edge |

So the same backend has a dependency graph on one instance and none on another, and a
provider must neither assume nor hardcode either — the Enterprise instances people run at
work have it, gitlab.com free does not.

**Both ends of a directed edge report different types, so read the end you mean.** For
"A is blocked by B", measured on a licensed instance:

| call | `link_type` | the other side |
| --- | --- | --- |
| `GET /issues/A/links` | `is_blocked_by` | B — the blocker |
| `GET /issues/B/links` | `blocks` | A |
| `POST /issues/A/links link_type=is_blocked_by` | returns **`blocks`** | — |

The POST response describes the link from the far end. Believing it instead of re-reading
inverts the graph.

**Never substitute a weaker edge for the one asked for.** `relates_to` is symmetric and
carries no direction: recording a blocker as "related" would let the queue read a
bidirectional edge as an ordering constraint and produce a confidently wrong order. No
dependency graph beats a graph that lies about direction. The 403 is passed to the caller
in `PROVIDER_ERR` instead, in GitLab's own words.

**Never discard the backend's diagnostic.** Put it in `PROVIDER_ERR` and let the caller
print it. `_gh_write` and `_gh_read` do this. Three different failures once printed the
same four words, and one of them — an HTTP 422 naming the property, the value, its type,
the required type and the docs URL — cost a live debugging session to recover (#45).

**Types on the wire are part of the contract.** `gh api -f` sends a string; the endpoint
wanted an integer; every call 422'd while every test passed. A fixture cannot catch that.

## Testing without the backend

| Seam | Stands in for |
| --- | --- |
| `PM_REPO` | the destination repository, when no `--repo` is given |
| `BACKLOG_ISSUES_JSON` | `provider_issues` |
| `BACKLOG_ISSUE_JSON` | `provider_issue` |
| `BACKLOG_DEPS_JSON` | the whole dependency graph — **replaces**, never merges |
| `BACKLOG_LINK_JSON` | `provider_blocked_by` |
| `CHECK_REPLIES_JSON` | `provider_needs_human` |
| `BACKLOG_NOW` | the clock. Not optional: without it, ageing cases drift a day at a time |
| `STALE_HOURS` · `ESCALATE_DAYS` · `PM_LIMIT` · `PM_ASSUME_DEPS` | tunables |

**A fixture for a wire format has to come off the wire.** `tests/fixtures/issues-github-shape.json`
exists because a hand-written one agreed with the bug it was meant to catch.

**And a fixture cannot catch a wrong scalar type in a request body.** For that,
`tests/live.test.sh` — an opt-in round-trip in a throwaway repo, since it needs
credentials, a network and a repo it may write to:

```sh
PM_LIVE_REPO=owner/scratch sh tests/live.test.sh
```

It files two issues, links them, reads the edge back, unlinks, claims, releases,
asks and closes — and asserts each **read-back**, because the exit code is what
passed while #45 was broken. It skips loudly rather than silently when unset.
It also refuses to run against a repo whose name does not say `scratch`
(`PM_LIVE_FORCE=1` overrides), because it closes issues in whatever it is
pointed at.

**Never point it at GitHub.** Automating issue and pull request creation there —
even in a throwaway repo — is synthetic traffic GitHub's terms do not permit, so
the suite has never run against GitHub. That is a known gap, and it is
deliberate: the suite is the acceptance test for a provider whose backend terms
allow it, not a GitHub regression test.

## Three assumptions that are GitHub's, not the contract's

These are real limits. If any blocks you, that is a bug in the contract, not in your file.

**One backend serves both issues and code review.** `backlog-claim` opens a draft PR and
labels an issue in the same run. Where the tracker and the code host are separate products,
the contract cannot currently express the split.

**An issue is identified by an integer.** `backlog-link` validates `[!0-9]`, and
`backlog-queue` sorts on `number` as its final tie-break. The tie-break needs *a total
order*, not an integer — but the validation does not know that yet.

**Ordering axes are labels.** `priority-high`, `size-s`, `needs-human`. A backend with
native priority and estimate fields is currently made to fake them as labels.

That one has a first crack at a fix. **`provider_is_triaged` asks the question rather than
inspecting labels**, because *"has anyone classified this"* and *"does it carry three labels"*
are only the same question on this backend. Where priority is a **mandatory field**, every issue
has one from the moment it exists — usually defaulted by the tracker rather than chosen — and an
issue nobody looked at is indistinguishable from one deliberately set to the middle value.

Returning **`2`** means *this backend cannot distinguish a chosen priority from a defaulted one*.

**It is not a licence to carry on ranking.** Dropping the untriaged key and sorting by priority as
usual asserts that every priority was chosen — and produces a confidently differentiated order
built from values nobody set. A flat order is visibly useless; that one looks authoritative, which
is worse.

This matters more than it looks because **priority is the key the order actually turns on.**
Severity sits above it and fires only for `security` and `data-loss-risk` — two labels a repository
may not even define, in which case priority decides everything.

So a caller receiving `2` must **say so in its output**. `backlog-queue --why` already reports
per-row provenance on this backend (`defaulted: priority,urgency,size`), and it can do that only
because absence is observable here. Where nothing is ever absent, that reporting has nothing to
detect and every row silently claims to be ranked.

## The agent mark

`check-replies` and `backlog-triage` decide *has a human replied* from the last comment
starting with 🤖. That exists because on GitHub an agent posts under the human's own token,
so the author distinguishes nothing.

**If your backend posts as a separate user, say so and use the author.** Emulating the mark
would be reimplementing a workaround for a problem you do not have.
