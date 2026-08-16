---
name: new
description: Set up a new small web app repo — asks four questions, points at the best current generator for the chosen stack, then scaffolds the part generators skip (CI, security-rules tests, quota and backup alerting, GitHub hygiene). Use when starting a new app, adding hosting or a database to an empty repo, or when asked which stack to build something on.
---

# Start a new app

Two phases. **Signpost, then harden.**

Generating an app with auth, a database and a deploy is solved — Google AI Studio and Lovable
do it better than a scaffolder would. What none of them do is set up CI, test the rules they
generated, or warn before a free tier hard-stops. **Only phase 2 is this kit's work.**

Never rebuild what a generator already does. Point at it and pick up after.

## Phase 0 — four questions

Ask with `AskUserQuestion`, one at a time, each with a recommended default so "just do it"
works. Stop early: as soon as the answers determine a stack, stop asking.

1. **Who uses it?** just me / family / staff / anyone with the link
2. **Does it need a real server?** a backend, a job queue, Postgres, a local model
3. **Does anything have to run at home?** a local LLM, files on a box you own, a USB device
4. **Is it for the business?** — only asked if Q1 said staff or public

Infer instead of asking wherever the answer is already obvious from what they told you.

## Picking the stack

First match wins:

| If | Stack | What it is |
| --- | --- | --- |
| Q3 yes | **E** self-hosted | your own platform: git, CI, secrets, shared Postgres. **Internal only** |
| Q2 yes | **D** railway | container + Postgres, one vendor |
| Postgres wanted, no long-running server | **C** supabase | Postgres + Auth + Storage + Functions |
| Q4 business **and** public | **B** cloudflare | Pages/Workers + D1 + Access |
| otherwise | **A** firebase | Hosting + Firestore + Google sign-in |

**Only template A exists today.** For B–E, say so plainly and offer: build the repo hygiene and
CI parts now, or wait. Do not fake a template that is not there.

### The rule that binds every answer

**One vendor for the stateful plane** — database, auth, storage and any server from the same
place. Never an app on one vendor reaching a database on another.

Static hosting is the one exception, because a CDN holds no state and no secret the browser
does not already see. **The exception ends where credentials begin:** anything holding a
`DATABASE_URL` or a service-role key is not a CDN, it is a second stateful vendor.

Never propose glue, even when glue is cheapest.

## Phase 1 — signpost

State the fastest current way to get a working app, then stop. One line, not a tutorial.

| Stack | Point them at |
| --- | --- |
| **A** firebase | **Google AI Studio** — provisions Firestore, auth, sign-in page and rules; GitHub import and push |
| **C** supabase | **Lovable** — provisions Postgres, auth, RLS, storage, realtime; one-click deploy |
| **B** / **D** / **E** | no generator fits — use the kit's template |

*Checked Aug 2026.* **Re-verify with the research agent when these are more than ~90 days old**,
or when one fails in practice. Generators get discontinued and overtaken like anything else.

Phase 1 is **optional**. A hand-written repo, a Claude-built one, or an app that already exists
all enter at phase 2. Never require that a generator was used.

## Phase 2 — harden

The actual work. Four things, none of which any generator does:

1. **GitHub hygiene** — labels including `needs-human`, PR template, `.gitignore` covering
   `.env` and build output, branch protection where the plan allows it
2. **CI** — PR builds a preview, merge deploys live. Access rules deploy **from the repo on
   merge only**, never from a PR build and never by hand from a laptop
3. **Security-rules tests** — the reason this kit exists. Generators draft and deploy rules,
   then tell you to check them yourself. Assert every claim the rules file makes, against the
   emulator, in CI
4. **Quota and backup alerting** — a free tier that hard-stops silently, and a database whose
   only copy is one machine, are both routine ways small apps die

For stack A: `node templates/static-firestore/init.mjs --into <dir> --name <name>
--project-id <id> --allow <emails>`, then `npm install && npm run check && npm test`.

Then hand over `docs/SETUP.md` — creating the Firebase project, the deploy service account and
the sign-in provider needs a browser and a human.

## Rules that do not bend

- **Stack E is never publicly exposed.** Asked for a public URL on the self-hosted stack, refuse and explain
  — do not comply. Public means A–D.
- **One database and one role per app** on a shared Postgres. Never a shared schema or
  superuser: one instance saves memory, not blast radius.
- **Stack E CI is a self-hosted runner**, shell steps over marketplace actions.
- **Secrets resolve from the platform's secret manager** on stack E — as a file, never repo
  secrets, never a committed `.env`.
- **Never let the alerting tool run only on the box it watches** — it exists to report other
  things are broken and cannot report its own host's failure. Developing one there is fine;
  running the instance that pages you is not.
- **Auth is not optional for anything network-reachable.** "Internal" is not a security
  control; everyone who can reach the private network reaches every route.
- **Stack E stops at the platform boundary.** Issuing identities, rendering secret files,
  creating the database role, the hostname and the memory ceiling belong to a skill in your
  own platform's repository, not here.
- **If a generator ever ships CI, rules tests and backup alerting, say so and recommend it over
  this kit.** It is justified by a gap, and the gap is allowed to close.

## Related

`audit` does the same checks against a repo that already exists.
`docs/mvp-kit-plan.md` holds the reasoning, the costed options and what was rejected.
