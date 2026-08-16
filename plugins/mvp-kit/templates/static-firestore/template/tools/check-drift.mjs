// Does this repo still do what its own files say it does?
//
//   npm run check
//
// Not a linter. Every check below is a specific way a small app has been seen
// to rot: two files that must agree, drifting apart quietly because nothing
// reads both. The motivating case is a repo whose handoff notes said security
// rules were deployed by hand, while its merge workflow had been deploying them
// from CI for months -- so the next person to touch it went to deploy rules
// manually, from a laptop, over whatever CI had already shipped.
//
// A failure here is never cosmetic. Read the message; it names both sides.

import { readFile, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';

import { DIST, PUBLISHED } from './build.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const problems = [];

function fail(check, detail) {
  problems.push({ check, detail });
}

async function readIfPresent(rel) {
  try {
    return await readFile(join(repoRoot, rel), 'utf8');
  } catch {
    return null;
  }
}

async function exists(rel) {
  try {
    await stat(join(repoRoot, rel));
    return true;
  } catch {
    return false;
  }
}

const MERGE_WORKFLOW = '.github/workflows/merge.yml';
const PR_WORKFLOW = '.github/workflows/pr.yml';
const PROSE = ['README.md', 'AGENTS.md', 'docs/BACKUP.md', 'docs/QUOTAS.md'];

const merge = await readIfPresent(MERGE_WORKFLOW);
const pr = await readIfPresent(PR_WORKFLOW);
const firebaseJson = await readIfPresent('firebase.json');
const firebaserc = await readIfPresent('.firebaserc');
const indexHtml = await readIfPresent('index.html');
const rules = await readIfPresent('firestore.rules');

// --- 1. Rules deployment: docs vs. the workflow that actually ships them -----

/**
 * Does this prose claim, as a statement of fact, that rules are shipped by hand?
 *
 * Sentence at a time, because the documents that need this check are also the
 * ones most likely to say "rules are never deployed by hand" -- and a check
 * that fires on the sentence telling you the right thing is a check people
 * learn to switch off.
 */
function claimsManualRuleDeploys(text) {
  return text
    .split(/(?<=[.!?])\s+|\n/)
    .filter((s) => /\brules\b/i.test(s))
    .filter((s) => /\b(by hand|manually|from (?:a|your) laptop)\b/i.test(s))
    .some((s) => !/\b(never|not|no longer|don't|do not|instead of|rather than)\b/i.test(s));
}

if (merge && rules) {
  const ciDeploysRules = /--only\s+firestore:rules/.test(merge);
  for (const rel of PROSE) {
    const text = await readIfPresent(rel);
    if (!text) continue;
    if (ciDeploysRules && claimsManualRuleDeploys(text)) {
      fail(
        'rules deployment',
        `${rel} says security rules are deployed by hand, but ${MERGE_WORKFLOW} ` +
          'deploys them on every merge. Whoever believes the doc will deploy ' +
          'a second time, from a laptop, over whatever CI already shipped.'
      );
    }
  }
  if (!ciDeploysRules) {
    fail(
      'rules deployment',
      `${MERGE_WORKFLOW} does not deploy firestore.rules. The rules file in this ` +
        'repo and the rules actually enforced can then drift apart silently, ' +
        'which is the failure this template exists to prevent.'
    );
  }
}

// --- 2. Pull request builds must never deploy rules --------------------------

if (pr && /--only\s+firestore:rules/.test(pr)) {
  fail(
    'preview safety',
    `${PR_WORKFLOW} deploys Firestore rules. Hosting preview channels share the ` +
      'one production database, so a branch\'s rules would be applied to live ' +
      'data before anyone reviewed them. Rules ship from the merge workflow only.'
  );
}

// --- 3. What the build writes vs. what Hosting serves ------------------------

if (firebaseJson) {
  let parsed;
  try {
    parsed = JSON.parse(firebaseJson);
  } catch (err) {
    fail('firebase.json', `is not valid JSON: ${err.message}`);
  }
  const served = parsed?.hosting?.public;
  if (served && served !== DIST) {
    fail(
      'hosting root',
      `firebase.json serves "${served}" but tools/build.mjs writes "${DIST}". ` +
        'Hosting would publish a stale directory, or nothing at all.'
    );
  }
  if (parsed && !parsed.firestore?.rules) {
    fail(
      'firebase.json',
      'has no firestore.rules entry, so `firebase deploy --only firestore:rules` ' +
        'has nothing to deploy and CI will ship the app without its access control.'
    );
  }
}

// --- 4. Access control that only exists in the page --------------------------

if (indexHtml) {
  // Two or more addresses sitting in a list in the page is the shape of a
  // client-side allow-list. It is worth failing on because it looks like
  // security and is not: the browser was handed that array and can be made to
  // ignore it. A single address -- a support mailto, an author line -- is fine.
  const emails = [...indexHtml.matchAll(/[\w.+-]+@[\w-]+\.[\w.]+/g)].map((m) => m[0]);
  const unique = [...new Set(emails)];
  if (unique.length > 1) {
    fail(
      'client-side allow-list',
      `index.html contains ${unique.length} email addresses (${unique
        .slice(0, 3)
        .join(', ')}${unique.length > 3 ? ', …' : ''}). If that is an access ` +
        'list, it is advisory only -- users can edit the JavaScript they were ' +
        'served. The enforced list lives in firestore.rules.'
    );
  }
}

// --- 5. One project id, agreed on everywhere ---------------------------------

if (firebaserc) {
  let projectId;
  try {
    projectId = JSON.parse(firebaserc)?.projects?.default;
  } catch (err) {
    fail('.firebaserc', `is not valid JSON: ${err.message}`);
  }
  if (!projectId) {
    fail('.firebaserc', 'has no projects.default, so CLI deploys have no target.');
  } else {
    for (const [rel, text] of [
      [MERGE_WORKFLOW, merge],
      [PR_WORKFLOW, pr],
    ]) {
      if (!text) continue;
      const mentioned = [...text.matchAll(/projectId:\s*([\w-]+)/g)].map((m) => m[1]);
      const wrong = mentioned.filter((p) => p !== projectId);
      if (wrong.length) {
        fail(
          'project id',
          `${rel} deploys to ${[...new Set(wrong)].join(', ')} but .firebaserc ` +
            `names ${projectId}. One of them is pointing at the wrong Firebase ` +
            'project.'
        );
      }
    }
  }
}

// --- 6. Scaffolding that was never filled in ---------------------------------

const SCAFFOLD_FILES = [
  'firestore.rules',
  'firebase.json',
  '.firebaserc',
  'README.md',
  'AGENTS.md',
  MERGE_WORKFLOW,
  PR_WORKFLOW,
];
for (const rel of SCAFFOLD_FILES) {
  const text = await readIfPresent(rel);
  if (!text) continue;
  const tokens = [...new Set([...text.matchAll(/__[A-Z0-9_]+__/g)].map((m) => m[0]))];
  if (tokens.length) {
    fail(
      'unfilled placeholder',
      `${rel} still contains ${tokens.join(', ')} -- this repo was scaffolded ` +
        'but never configured.'
    );
  }
}

// --- 7. The backup path the template refuses to ship without -----------------

if (!(await exists('.github/workflows/backup.yml'))) {
  fail(
    'backup',
    'There is no .github/workflows/backup.yml. Firestore on the Spark plan has ' +
      'no managed backup, so without this the only copy of the data is the live ' +
      'database, and a bad write or a deletion is unrecoverable.'
  );
}

// --- 8. Files the build publishes must exist ---------------------------------

for (const entry of PUBLISHED) {
  if (!(await exists(entry))) {
    fail(
      'publish list',
      `tools/build.mjs publishes "${entry}", which does not exist. The build ` +
        'will fail before it deploys -- create it, or take it out of PUBLISHED.'
    );
  }
}

// --- Report ------------------------------------------------------------------

if (problems.length === 0) {
  console.log('check: no drift found.');
  process.exit(0);
}

console.error(`check: ${problems.length} problem(s).\n`);
for (const { check, detail } of problems) {
  console.error(`  [${check}] ${detail}\n`);
}
process.exit(1);
