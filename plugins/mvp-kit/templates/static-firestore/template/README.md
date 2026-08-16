# __APP_NAME__

A small private app: one static page on Firebase Hosting, one Firestore
document, Google Sign-In restricted to an allow-list.

**Live:** https://__PROJECT_ID__.web.app

## Who can use it

Sign in with Google. Only the addresses listed in `firestore.rules` are let in;
everyone else is refused by Firestore itself, not just by the page.

To add someone, edit the list in `firestore.rules` and merge to `main` — the
deploy workflow ships the change. See `AGENTS.md`.

## Working on it

```bash
npm ci
npm run build     # regenerate dist/, which is what Hosting serves
npm run check     # has the repo drifted from its own documentation?
npm test          # run the security-rules suite against the Firestore emulator
```

`npm test` needs a JDK installed — the Firestore emulator is a Java program.

Open a pull request and CI will run all three, then put the change on a preview
URL. Merging to `main` deploys the site and the security rules together.

## Where things are

| | |
| --- | --- |
| `index.html` | the entire app |
| `firestore.rules` | who may read and write, and the version guard |
| `tools/rules-tests/` | proof that the rules do what their comments claim |
| `tools/check-drift.mjs` | catches this README describing something the repo no longer does |
| `backups/` | a nightly JSON copy of the data, committed by CI |
| `docs/QUOTAS.md` | the free-tier limits and what happens when you hit them |
| `docs/BACKUP.md` | how to restore |

## Setting it up from scratch

See `docs/SETUP.md` — the Firebase project, the deploy service account, and the
one-time console settings that no workflow can do for you.
