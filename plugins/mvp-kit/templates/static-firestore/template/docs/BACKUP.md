# Backups, and how to restore

Firestore's managed export is a Blaze-tier feature. On the free plan the live
document is the only copy that exists, and a bad write, a bad migration or a
deletion takes it with nothing to go back to.

So `.github/workflows/backup.yml` reads `app/state` once a day and commits it to
`backups/<date>.json`. **The repo history is the backup.** Every clone is a
copy, and every copy is off Google's infrastructure.

## What is covered

One document: `app/state`. That is the whole app.

If this app grows other collections, add them to `DOCUMENTS` in
`tools/backup.mjs`. And notice the moment there are more than a handful — this
script is the least clever thing that works for a single document, and it stops
being the right tool once there is a real dataset. At that point the answer is
Blaze and a scheduled managed export, not a longer script.

## What is not covered

- **Firebase Auth users.** Not backed up. They are Google accounts; the app
  stores nothing about them beyond an address in `firestore.rules`, which is in
  git already.
- **Anything written between the last nightly run and the incident.** Up to 24
  hours. If that is not acceptable, the schedule in `backup.yml` takes a cron
  expression.

## Restoring

1. Find the last good snapshot:

   ```bash
   git log --oneline -- backups/
   cat backups/2026-08-15.json
   ```

2. The `version` field matters. The security rules only accept a write whose
   version is exactly one past the stored one, so you cannot paste an old
   document back as-is — it will be refused. Restore with the **current**
   version plus one, keeping the old contents:

   ```bash
   # what is stored right now
   npx firebase firestore:get app/state --project <project-id>
   ```

3. Write it back through the console (**Firestore Database → app → state**), or
   with the Admin SDK using the same service account the backup uses. Set
   `version` to `<current> + 1` and everything else from the snapshot.

That version dance is deliberate friction. It is the same guard that stops a
stale phone overwriting fresher work, and a restore is exactly the operation
where you want to be sure about which copy is newer.

## Checking it works

A backup nobody has watched succeed is not a backup.

**Actions → Backup → Run workflow.** A green run either commits a new
`backups/<date>.json` or reports no change since the last one. It exits non-zero
if it cannot read the document at all, so a green run always means the data was
reachable.

Worth doing once at setup, and again any time the service account's roles
change.
