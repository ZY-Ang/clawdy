# mvp-kit — one command to start an app

## The problem — narrowed by research

Original framing: every new app repeats repo, CI, hosting, database and sign-in by hand.
**Deep research (Aug 2026, 112 agents, adversarially verified) partly refuted that.** The
auth / database / deploy leg is already solved by shipped products:

- **Google AI Studio** — one approval provisions Firestore, enables auth, generates the
  Google Sign-In page, drafts *and deploys* Firestore security rules, emits
  `src/lib/firebase.ts` and `firestore.rules`. Since 8 Jul 2026 it also does GitHub import and
  one-click commit-and-push.
- **Lovable 2.0** — the same on Supabase: provisions Postgres, configures auth, sets RLS,
  adds storage and realtime, one-click deploy. Marketed at non-technical users.
- **create-t3-app** — already established the interview mechanic.
- **Firebase ships 12 first-party agent skills.**

**Building an interview that wires up auth, a database and a deploy would duplicate shipped
products.** That work is done, and done by vendors.

### What is actually still missing

None of the above touches any of this:

1. **GitHub hygiene** — repo creation, README/LICENSE/`.gitignore`, labels, branch protection
2. **CI** — no tool above sets up Actions, test gating, or preview-vs-live separation
3. **Security-rules verification** — AI Studio *auto-deploys* AI-drafted rules while Google
   explicitly disclaims them: "you should always double-check these rules before sharing or
   deploying your app." Nobody ships a test for them.
4. **Backup and quota alerting** — nobody warns you before a free tier hard-stops

**That is the kit.** Not "set up my app" — **"harden what the vibe-coding tool just generated,
and put it under CI."** Narrower, unoccupied, and it is where generated apps get bitten: losing
days of data to a stale client is a rules problem, and the generator does not write the test
that would have caught it.

## Two phases: generate, then harden

**The kit does not compete with AI Studio or Lovable. It hands off to them, then picks up
where they stop.**

That a tool already exists is a reason to **signpost** it, not to pretend it does not. The
user should be told, in one line, the fastest current way to get a working app — then the kit
does the part that tool skipped.

```
1. GENERATE  →  "Use Google AI Studio for this one. Come back when it's deployed."
                (the kit does not rebuild this — vendors do it better)

2. HARDEN    →  the kit's actual job:
                GitHub hygiene · CI · rules tests · quota + backup alerts
```

**Phase 1 is optional.** A hand-written repo, a Claude-built one, or an existing app all enter
at phase 2. The kit never requires that a generator was used.

### Signposts, by stack — checked Aug 2026

| Stack | Point them at | Why |
| --- | --- | --- |
| **A** firebase | **Google AI Studio** | Provisions Firestore, auth, sign-in page, rules; GitHub import + push since 8 Jul 2026 |
| **C** supabase | **Lovable** | Provisions Postgres, auth, RLS, storage, realtime; one-click deploy |
| **B** cloudflare | no strong generator found | Scaffold from the kit's own template |
| **D** railway / **E** self-hosted | no generator fits containers | Kit template |

### The signposts rot too

**This table is a fact with a date, not a permanent truth.** AI Studio and Lovable can change
terms, change pricing, get discontinued, or be overtaken — the same way Firebase dropped Cloud
Storage from Spark in Feb 2026 and Neon dropped its Azure regions in April.

So **the research agent owns the signpost list, not just the stack list.** When the entries are
older than ~90 days, or when a recommendation fails in practice, it re-checks what the best
current generator is and updates the answer. The kit must never insist on a tool that has
quietly become the wrong one.

**Corollary worth stating plainly:** if a generator ever *does* cover CI, rules tests and
backup alerting, the honest move is to signpost that and retire this kit. Building it is
justified by a gap, and the gap is allowed to close.

## The principle

**One vendor for the stateful plane.**

Database, auth, storage and any server come from a single vendor. Static frontend hosting may
sit elsewhere — a CDN holds no state, no credentials beyond a public key, and can be swapped
in an afternoon, so it is not the thing that hurts.

Earlier drafts paired Cloud Run with Neon because both have free tiers. That is a dirty stack:
two dashboards, two bills, two sets of credentials, two status pages, an egress hop and two
cold starts stacked on each other. Debugging it means guessing which vendor broke. **Free and
dirty is worse than $5 and clean.**

The rule was originally written as "one project, one platform", which was too strict — it
would have banned Supabase, since Supabase does not host static sites. The failure being
avoided is *split state*, not *two logos*.

### The CDN exception

**Static hosting may come from a different vendor than the stateful plane.** Cloudflare Pages,
GitHub Pages, Netlify and Firebase Hosting are all free at this scale, so this costs nothing
and buys real freedom — a static front is swappable in an afternoon.

It qualifies only when **all** of these hold:

1. It serves **files** — HTML, CSS, JS, images. No server-side code.
2. It holds **no secret**. A public anon key or Firebase web config is fine, since both ship
   to the browser anyway. A service-role key, a database URL or a private API key is not.
3. Losing it loses **nothing**. Redeploy elsewhere and the app is whole, because all state
   lives in the one backend.

**The exception ends where credentials begin.** The moment the hosting layer runs code holding
a database credential — a Vercel function with a connection string, a Worker bound to a
database in another account, a Cloud Run service with `DATABASE_URL` — it is not a CDN any
more. It is a second stateful vendor, and the rule applies again.

That boundary is what stops this exception from quietly re-admitting Cloud Run + Neon: Cloud
Run holds the credential, so it was never a CDN.

**Test to encode:** does the hosting layer hold a secret the browser never sees? Yes → same
vendor as the database. No → host it anywhere free.

## The questions

Four. Each has a default, so "just do it" works.

1. **Who uses it?** → just me / family / staff / anyone with the link
2. **Does it need a real server?** → a backend, a job queue, Postgres, a local model
3. **Does anything have to run at home?** → local LLM, files on a box you own, a USB device
4. **Is it for the business?** → gates licence and bandwidth traps

## The five default stacks

Each keeps its stateful plane on one vendor. These are the **fast paths** — a template exists
and is tested. Anything else goes through the research agent below.

| # | Stack | Everything from | Cost | Picked when |
|---|---|---|---|---|
| **A** | **firebase** *(default)* | Hosting + Firestore + Firebase Auth | $0 | static or SPA, known users, low traffic |
| **B** | **cloudflare** | Pages/Workers + D1 + R2 + Access | $0 | business, public, bandwidth or images |
| **C** | **supabase** | Postgres + Auth + Storage + Functions; static front on any CDN | $0 | Postgres wanted, no long-running server |
| **D** | **railway** *(or Render / Fly)* | container + Postgres + TLS, one dashboard | ~$5–7/mo | needs a long-running server or a container |
| **E** | **self-hosted** | your own box: git, CI, secrets and data under one owner | $0 | Q3 pins it home. **Internal only.** |

**Mapping:** Q3 yes → **E**. Else Q2 yes (needs a container or long-running process) → **D**.
Else Postgres wanted → **C**. Else Q4 business and public → **B**. Else → **A**.

### Why each exists

- **A** — proven on a shop floor. Free, Firestore never sleeps, and Google sign-in with an
  allow-list in security rules is one file.
- **B** — Firebase Spark caps transfer at **10 GB/month** and **disables the site until the
  next calendar month** on overage. Cloudflare permits commercial use where Vercel Hobby does
  not. **Corrected by research:** Cloudflare's free tier hard-stops too — D1 blocks queries at
  its daily row limits and blocks writes/DDL at the storage cap, and Pages Functions share a
  single *account-wide* 100 k req/day Workers quota, so one app can starve another. Cloudflare
  escapes metered bandwidth, not free-tier cliffs. **The honest recommendation is Workers Paid
  at ~$5/mo**, not "B is free".
- **C** — Postgres, auth, storage and functions from one vendor, free. The 7-day idle pause
  is the catch: fatal for a sporadic
  app, irrelevant for one used daily. Pair the static front with any CDN — that part is
  swappable and holds no state.
- **D** — the clean answer when something must actually keep running: a container, a queue, a
  websocket server. App and database one vendor, one bill, no egress hop. **This is where the
  $5–7/mo goes, and it is worth it.**
- **E** — the answer when something needs local hardware: a GPU for a local model, data that
  may not leave the building, or simply a box you already run. Git, CI, secrets and data on one
  machine with one owner is the cleanest stack here by the stateful-plane rule, and it dodges
  GitHub's 2,000-minute private-repo cap. What that platform must give a tenant is its own
  problem, not the kit's — see "Where the other half lives" under stack E.

## The escape hatch: research a stack

**The five above are known-good defaults, not the only allowed answers.** They exist because a
template is already built and tested for each, so they are the fast path. They are not a claim
that nothing else is suitable.

`/mvp-kit:new` therefore ships a **research agent**, used when:

- none of the five fits the app
- the user names a vendor — "can we use Vercel?", "what about Supabase?"
- the app has an unusual requirement (websockets, cron, big file storage, a GPU)
- **the cached facts are older than ~90 days**

### Why this is not optional

Every price and limit in this document is dated **Aug 2026**. Free tiers change, ToS change,
products get discontinued — Firebase dropped Cloud Storage from Spark in Feb 2026, Neon
deprecated its Azure regions in April. **A hardcoded table is wrong the day it ships and gets
worse.** An agent that re-verifies at the moment of use is the only version that stays true.

So the five defaults carry their facts *with a checked-on date*, and the agent re-verifies
anything stale rather than repeating it confidently.

### What the agent must return

1. **A stack with an undivided stateful plane.** The cleanliness rule binds it too — it may
   not split database, auth and server across vendors. A separate static CDN is fine.
2. **Current price, free-tier limits, and commercial-use terms**, each with a source and a date
3. **The catch**, named plainly — every option has one
4. **A recommendation, not a menu.** Same standard as the rest of the kit: pick one, defend it
   in a sentence.

### Candidates it should know to evaluate

Not rejected — evaluated on the facts at the time, and several are clean by construction:

| Candidate | Case for | Catch to check |
|---|---|---|
| **Vercel** | Best-in-class DX for Next.js; Postgres and Blob via one bill | **Hobby is non-commercial** — a business app needs Pro. Verify current pricing |
| **Cloud Run + Cloud SQL** | Clean, same-cloud, GCP-native | ~$8/mo floor; more than Railway for less convenience |
| **Fly / Render** | Container + Postgres, one vendor, like Railway | Pricing and free-tier terms move; re-check |
| **Netlify, Deno Deploy, Convex, PocketBase, Appwrite, Hetzner** | Each wins some case | Unverified — the agent's job |

**Rejected on structure, not price** — and this one does not need re-checking, because it is a
design rule rather than a fact: **Cloud Run + Neon**, or any app-on-one-vendor /
database-on-another pairing. Cheap and dirty still loses.

### Stack E detail — a self-hosted platform

Stack E is not a spare box running one container. It assumes a platform: something that hosts
git and CI, holds secrets outside the repository, runs a database other apps share, and bounds
what any one workload can consume. The specifics belong to whoever runs it — **this document
deliberately does not describe any particular installation**, and the kit's job stops at the
boundary between the app and the platform.

**Consequences the kit must handle:**

1. **CI is a self-hosted runner, not GitHub Actions.** Workflow syntax is largely compatible,
   but the kit must emit a workflow targeted at the platform's own forge and assume a
   self-hosted runner rather than a hosted `ubuntu-latest`. Marketplace actions are *not*
   guaranteed — prefer plain shell steps.
2. **Secrets come from the platform's secret manager**, injected at deploy or CI time. The kit
   must not write credentials into repo secrets or into a `.env` committed anywhere. A platform
   of this shape hands a workload a *file* on a RAM-backed volume, not an environment variable
   — an environment variable is readable by anything holding the container runtime's socket.
3. **One database and one role per app on a shared instance.** Never a shared schema and never
   a shared superuser. The point of one instance is saving memory, not sharing blast radius —
   a migration in one app must not be able to touch another's tables.
4. **Memory limits still go in the compose file.** Ample RAM removes scarcity, not blast
   radius; an unbounded container can still take the box down.
5. **Backup is still required, and RAID is not it.** A mirrored pair survives a dead disk, not
   a deletion or a bad migration. `pg_dump` on a schedule plus an off-box copy.
6. **Never publicly exposed.** Internal only. Public means A–D.
7. **Never let an alerting tool run only on the box it watches.** Something that exists to
   report that other things are broken cannot report the failure of the machine it lives on.
   Developing one on stack E is fine; running the instance that pages you is not. The same
   argument applies to a telemetry backend: keep a second destination off the box, and alert
   on the *absence* of data, which is the only signal that survives its own subject.

**Where the other half lives.** Everything above is what the *app* must do. The platform side —
issuing a workload its identity, rendering that secret file, creating the database and role,
giving the service a hostname, capping its memory — is specific to one installation and cannot
live in a public marketplace. It belongs in a skill in your own platform's repository, which
this kit hands off to. Stack E is the boundary, not the whole job.

> **Verification status.** The Actions minute cap above is sourced. Two
> earlier claims were **mine and unsourced** and are withdrawn pending evidence: that SQLite
> corrupts over SMB/NFS mounts, and the specific Btrfs-snapshot guidance. Keep data on a local
> volume regardless — it is cheap insurance either way — but the kit should not assert a
> mechanism it cannot cite.

**In scope vs not:** a repo you *develop* is in scope even when it is open source — if it
needs Postgres, a container and CI, that is stack D or E. Something you merely *run*, packaged
by someone else, is out: no repo, no CI, no deploy.

## What gets generated

Same shape for every stack:

- App skeleton — single `index.html`, or a real build if it will grow
- Host config and CI: **PR builds a preview, merge deploys live**
- Access control deployed **from the repo on merge**, never by hand
- `AGENTS.md`, `.gitignore`, labels incl. `needs-human`

Deploys on first push. Sign-in works before any feature is written.

## `/mvp-kit:audit`

Same checklist against a repo that already exists. Detects the stack, reports PASS / MISSING,
asks, then opens a PR. Never overwrites a file that differs — reports it and leaves it.

**It also flags a mixed stack** — an app on one vendor reaching a database on another — since
that is the failure this plan exists to prevent.

## Build order

1. Build **A** and deploy it once by hand — proves the pipeline
2. Wrap it in `new/SKILL.md` with the four questions
3. **Add the research agent** — it matters more than the remaining templates, because it is
   what keeps the kit correct after the facts move
4. Add **C** (Supabase), then **D**, **E**, **B**
5. `audit/SKILL.md` against the same checklist

## Verification

- `/mvp-kit:new` in an empty repo → CI green, preview URL on the PR, live URL after merge
- Allow-listed Google account signs in; any other account is refused
- **Cleanliness test** — no generated stack may name two vendors, including anything the
  research agent proposes. Grep the output: one platform per project, or it is broken
- **Research agent — staleness** — mark the cached facts as 6 months old; it must re-verify
  rather than repeat them, and must return a source and a date per claim
- **Research agent — named vendor** — ask "can we use Supabase?" It must evaluate on current
  facts and give a recommendation, not a menu. For a daily-use app the idle-pause must not be
  treated as disqualifying; for a sporadic one it must be
- **Research agent — cleanliness** — ask it for the cheapest possible container + Postgres. It
  must not propose a cross-vendor pairing even though that is cheapest
- **Signpost test** — ask for a new Firebase-shaped app. The kit must point at the current best
  generator and *decline to rebuild* what that tool does, then run phase 2 on the result
- **Signpost staleness** — mark the signpost table 6 months old; the agent must re-verify the
  generator recommendation, not repeat it
- **Retirement test** — tell it a generator now ships CI and rules tests. It must say so and
  recommend against using the kit's own templates, rather than defending its existence
- **Q3 test** — "a local LLM runs at home" → **E**. Answer no → **A**, **C** or **D**
- **Postgres test** — "needs Postgres, no long-running server" → **C**. "needs a container" →
  **D**. Never a cross-vendor database pairing in either case
- **Split-state test** — the rule bans a split *stateful* plane, not two logos. A static front
  on a CDN with Supabase behind it must PASS; Cloud Run with Neon must FAIL
- **CDN exception boundary** — the discriminator is whether the hosting layer holds a secret
  the browser never sees. Pages serving files with an anon key → PASS. A serverless function
  holding `DATABASE_URL` for a database at another vendor → FAIL, however CDN-shaped it looks
- **Business test** — business and public → **B**, and Vercel is never offered
- **E never public** — ask for a public URL on the self-hosted stack; must refuse, not comply
- **Alerting tools** — ask to run the on-call tool that pages you on the box it watches; must
  refuse and explain, while allowing that developing it there is fine
- `/mvp-kit:audit` twice on a generated repo → all PASS both times, no PR

---

## Rules worth keeping — each one learned the hard way

- Test the **built** artifact — a minifier breaks behaviour, not just names
- Deploy access rules **from the repo on merge**, never from a laptop
- Never deploy rules from a PR build — preview channels share the production database
- Access control lives server-side; a list in the page is advisory, users can edit their JS
- Require `email_verified`, keep one provider, or people self-register
- `AGENTS.md` rules each name the incident that caused them

## Anti-patterns to avoid

Failure modes worth designing against, not a description of any particular repository.

- No auth on a network-reachable route, including destructive ones
- Framework dev server used as the production server
- Only copy of the database on one laptop, gitignored, never backed up
- Absolute machine-specific path in the README

## What actually kills small apps — and what a kit can prevent

The point of the narrowed scope. A scaffold cannot prevent a bad schema or a logic bug. It can
prevent these:

| Failure | Preventable by the kit? |
| --- | --- |
| Stale client blind-writes over fresher data | **Partly** — ship a version-guard test, cannot force correct app logic |
| Security rules that do not enforce what they claim | **Yes** — a rules test suite in CI |
| No auth on a reachable route | **Yes** — assert it in CI |
| No backup; only copy on one machine | **Yes** — refuse to generate without a backup path |
| Free tier hard-stops with no warning | **Yes** — quota alerting at setup |
| Stale cache serving an old build | **Yes** — correct cache headers by default |
| Docs claiming a manual step CI already does | **Yes** — drift check |

## Traps to warn about, once

Firebase Blaze has **no default spend cap** — set a budget alert the day you upgrade.
Firebase dropped Cloud Storage from Spark in Feb 2026, so photo upload needs Blaze or **B**.
RAID is not backup: a mirrored pair survives a dead disk, not a deletion.
