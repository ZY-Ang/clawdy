# mvp-kit

Harden what a vibe-coding tool generated, and put it under CI.

The plan and the reasoning behind that scope are in
[`docs/mvp-kit-plan.md`](../docs/mvp-kit-plan.md). The short version: generating
an app with auth, a database and a deploy is a solved problem — Google AI Studio
and Lovable both do it, and better than a scaffolder would. What none of them do
is set up CI, test the security rules they generated, or warn you before a free
tier hard-stops. That gap is this kit.

## Not a plugin yet

**This cannot be installed.** There is no `.claude-plugin/plugin.json` and no
`marketplace.json`, so Claude Code cannot load any of it. What exists is the payload — a
working template and one skill — sitting in a subdirectory of `helper-scripts` because this
session could not create a new repo.

To become installable it needs to move to its own **public** repo (`ZY-Ang/mvp-kit`) and gain
a manifest. Moving it is a rename: nothing under `mvp-kit/` reaches outside that directory.

## Status

| Step | State |
| --- | --- |
| 1. Template **A** `static-firestore` | **built**, checks and rules suite passing locally |
| 1b. Deploy A once by hand | **not done** — needs a Firebase project and a Google account |
| 1c. Verify A end to end | **done** — 12/12 rules tests pass against the emulator, drift check clean |
| 2. `new/SKILL.md` — the four questions | **built** |
| GitHub hygiene — PR template, issue labels | file written; **nothing applies the labels yet** |
| GitHub hygiene — branch protection | not started |
| Plugin manifest so it can actually be installed | **not started — blocks everything** |
| 3. The research agent | not started |
| 4. Templates C (supabase), D (railway), E (nas), B (cloudflare) | not started |
| 5. `audit/SKILL.md` | not started |

## `templates/static-firestore`

A static page on Firebase Hosting, one Firestore document, Google Sign-In
against an allow-list. Stack **A** in the plan.

```bash
node templates/static-firestore/init.mjs \
  --into ../my-app \
  --name "Shop Stock" \
  --project-id shop-stock-4821 \
  --allow alice@example.com,bob@example.com
```

That writes a repo that builds, passes its own drift check, and runs a
security-rules suite — before anyone has created a Firebase project. The
remaining one-time steps are in the generated `docs/SETUP.md`.

### What it fills in, against the four gaps

| Gap | How |
| --- | --- |
| GitHub hygiene | README, AGENTS.md, `.gitignore`, docs; labels are still a manual step in `docs/SETUP.md` |
| CI | `pr.yml` gates and previews · `merge.yml` deploys site **and rules** · fork PRs get checks without credentials |
| Security-rules verification | `tools/rules-tests/` — 12 assertions against the real rules engine in the Firestore emulator |
| Quota and backup alerting | `backup.yml` commits a nightly JSON snapshot; `docs/QUOTAS.md` names each limit and what it does on overage |

### Two things it does that the plan did not ask for

**The version guard is enforced in the security rules, not in the page.** The
plan rated stale-client blind writes as only *partly* preventable, on the
grounds that a scaffold cannot force correct app logic. It cannot — but it can
move the guard somewhere app logic cannot skip. The rules require an incoming
`version` exactly one past the stored one, so the guard still holds for a
browser running last week's cached JavaScript, which is precisely the browser
holding the stale copy.

**`npm run check` is the drift check, and it runs in CI on every pull request.**
Eight checks, each one a specific way these repos have been seen to rot: docs
claiming rules ship by hand while CI ships them, a pull-request workflow that
deploys rules to the shared production database, `firebase.json` serving a
directory the build does not write, a workflow pointed at the wrong project, an
allow-list copied into the page where it means nothing, a missing backup path,
scaffolding placeholders never filled in, a publish list naming a file that does
not exist.

### Verified locally

- `init.mjs` into an empty directory → 20 files, tokens substituted
- `npm run build` → `dist/` holds exactly the two published files
- `npm run check` → clean
- `npm test` → 12/12 against the Firestore emulator
- **Mutation-tested, because a suite that cannot go red proves nothing.**
  Dropping `email_verified`, weakening the version guard, adding a stranger to
  the allow-list and opening the catch-all match were each caught. So were all
  eight drift cases above, with a clean baseline.

### Not verified

**The template has never been deployed.** Everything above runs offline against
the emulator; nothing has touched a real Firebase project, a preview channel or
a live URL. The plan's step 1 is not finished until `docs/SETUP.md` has been
followed end to end by someone with a Google account — the parts most likely to
be wrong are the service-account roles in step 4 and the exact secret name
`firebase init hosting:github` produces.

### Deliberate omissions

- **No LICENSE.** Licence choice is gated on Q4 ("is it for the business?"), so
  it belongs to `new/SKILL.md` alongside the questions, not to a template that
  cannot know the answer.
- **No minifier.** The source is what gets served, so there is no gap between
  the file you read and the file that runs, and no class of bug where
  minification changed behaviour rather than names. Adding one later means
  adding a test that runs against `dist/` in the same commit.
- **No programmatic quota alerting.** On the Spark plan there is no free
  automatic warning before a hard-stop. `docs/QUOTAS.md` says so plainly rather
  than implying monitoring exists — building it around a free tier is the wrong
  trade, and the honest answer at that point is Blaze with a budget alert.

## Where this eventually lives

The plan proposes extracting this to a **public** `ZY-Ang/mvp-kit` repo, since
marketplace install needs no auth. It sits under `helper-scripts/` for now
because `create_repository` is limited to session-attached repos. Moving it is a
rename, not a rewrite — nothing here reaches outside this directory.
