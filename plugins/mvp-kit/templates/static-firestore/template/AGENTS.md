# Working on __APP_NAME__

A single static page on Firebase Hosting, storing its state in one Firestore
document, behind Google Sign-In with an allow-list. No build step beyond copying
files, no server, no framework.

```
index.html            the whole app
firebase-config.js    Firebase web config — committed, not secret
firestore.rules       the only real access control
tools/                build, drift check, security-rules tests, backup
.github/workflows/    pr.yml (gate) · merge.yml (deploy) · backup.yml (nightly)
```

```bash
npm ci
npm run build     # regenerate dist/
npm run check     # has the repo drifted from its own docs?
npm test          # boot the Firestore emulator, run the rules suite
```

`npm test` needs a JDK — the Firestore emulator is a Java program.

## Rules, and the incident behind each one

Every rule here is the residue of something that actually went wrong in a small
app like this one. None of them are style.

**Access control lives in `firestore.rules`, never in the page.** A list of
addresses inside `index.html` is advisory: the browser was handed that
JavaScript and can be made to skip it. `npm run check` fails if `index.html`
grows an email list, because the version of this mistake that hurts is the one
where someone edits the page's list to add a colleague and believes they are
done.

**Rules are deployed from the repo on merge, and from nowhere else.** They used
to go out from a laptop in apps like this, which meant the file in git and the
rules the project actually enforced drifted apart with nothing to notice.
`merge.yml` ships them on every push to `main`.

**Never deploy rules from a pull request build.** Hosting preview channels share
the one production database, so a branch's rules would be applied to live data
before anyone reviewed them. `npm run check` fails if `pr.yml` ever grows a
rules deploy.

**The version guard is enforced in the rules, not in `index.html`.** A phone
that has been asleep holds a stale copy of the document; a blind save discards
everything that happened while it slept — in one case, four days of work. The
rules require an incoming `version` exactly one past the stored one. Putting the
guard in the page would not protect a client still running last week's cached
JavaScript, which is precisely the client that has the stale copy.

**Google stays the only enabled sign-in provider, and `email_verified` stays
required.** The allow-list is a list of email addresses, so it is worth exactly
as much as the proof behind the address. Enabling email/password in the console
would let anyone self-register an address on the list.

**Everything the browser receives is named in `PUBLISHED` in
`tools/build.mjs`.** `dist/` is an allow-list, not "the repo minus an ignore
list" — with an ignore list, every new file in the folder is published by
default and you learn which ones mattered afterwards.

**`no-cache` on HTML and JS, including the bare `/`.** Hosting matches headers
against the request path, so a rule for `**/*.html` never covers the `/` people
actually open. An hour of stale cache is an hour of phones running the build you
just fixed.

**The nightly backup is the only copy of the data outside Firestore.** Managed
export is a Blaze feature; on the free plan there is no undo. `backup.yml`
commits `backups/<date>.json` to `main`, so the repo history is the backup.

## Adding someone to the allow-list

One line in `firestore.rules`, then merge. It ships automatically. Two things to
check first:

- The address must have a Google account behind it. A company address on a
  domain with no Google Workspace sits on the list matching nothing.
- Add it to `firestore.rules` only. If you find yourself editing `index.html`,
  stop — that list is not what grants access.

## Things that will bite

- **Firebase Spark caps transfer at 10 GB/month and disables the site until the
  next calendar month on overage.** See `docs/QUOTAS.md`.
- **Blaze has no default spend cap.** If you upgrade, set a budget alert the same
  day.
- **Firestore free tier is 50k reads / 20k writes per day.** A polling loop added
  without thinking will find that ceiling.
