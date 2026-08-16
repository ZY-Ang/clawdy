// Take a copy of the app's Firestore state out of Firestore.
//
//   npm run backup           # writes backups/<utc-date>.json
//
// Firestore on the Spark (free) plan has no managed backup and no export: the
// managed export API is a Blaze feature. So the only copy of the data is the
// live document, and a bad write, a bad migration or a deletion takes it with
// no way back. That is not hypothetical -- it is the incident this whole
// template is a response to.
//
// This is deliberately the least clever thing that works. One document, read
// with the deploy service account, written as JSON, committed to the repo by
// .github/workflows/backup.yml. Restoring is `git show` and a paste. It costs
// one Firestore read a day against a 50,000/day free quota.
//
// What it is NOT: a backup of anything except app/state. If this app grows
// collections, add them to DOCUMENTS below -- and notice that the moment there
// are many, this script has stopped being the right tool and a Blaze-tier
// scheduled export is.

import { mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';

import { initializeApp, cert, applicationDefault } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

const DOCUMENTS = ['app/state'];

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const backupDir = join(repoRoot, 'backups');

// In CI the service account arrives as JSON in an environment variable, because
// writing it to a file that a later step could publish is a good way to leak it.
// Locally, `firebase login` and GOOGLE_APPLICATION_CREDENTIALS both work.
const inlineCredentials = process.env.FIREBASE_SERVICE_ACCOUNT;
initializeApp(
  inlineCredentials
    ? { credential: cert(JSON.parse(inlineCredentials)) }
    : { credential: applicationDefault() }
);

const db = getFirestore();

const snapshot = {
  takenAt: new Date().toISOString(),
  documents: {},
};

let missing = 0;
for (const path of DOCUMENTS) {
  const snap = await db.doc(path).get();
  if (!snap.exists) {
    missing += 1;
    console.error(`backup: ${path} does not exist.`);
    continue;
  }
  snapshot.documents[path] = snap.data();
}

if (missing === DOCUMENTS.length) {
  // Exit non-zero so the scheduled workflow goes red. A backup job that
  // succeeds while copying nothing is worse than no backup job, because it
  // tells you every morning that you are covered.
  console.error(
    'backup: nothing was found to back up. Either the app has never been used, ' +
      'or the service account is pointed at the wrong project.'
  );
  process.exit(1);
}

await mkdir(backupDir, { recursive: true });
const day = snapshot.takenAt.slice(0, 10);
const file = join(backupDir, `${day}.json`);
await writeFile(file, JSON.stringify(snapshot, null, 2) + '\n');

console.log(`backup: wrote backups/${day}.json`);
