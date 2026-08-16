// Assemble the tree Firebase Hosting serves.
//
//   npm run build      # regenerates dist/ from scratch
//
// dist/ is an ALLOW-LIST of what the app needs, not "the repo minus an ignore
// list". That distinction matters more than it sounds: with an ignore list,
// every new file in the repo is published by default and you find out which
// ones shouldn't have been later. Notes, exports, a second project's index.html
// that happens to share the folder -- all of them ship unless someone
// remembered. Here, a file reaches the internet only by being named below.
//
// There is deliberately no minifier. The source is already what gets served, so
// there is no gap between the file you read and the file staff run, and no
// class of bug where minification broke behaviour rather than just names. If
// you add one later, add a test that runs against dist/ in the same commit --
// a source-only suite cannot see a minifier that changed what the page does.

import { cp, mkdir, rm, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join } from 'node:path';

export const DIST = 'dist';

// Everything the browser is allowed to receive. Paths are relative to the repo
// root; a directory is copied whole.
export const PUBLISHED = [
  'index.html',
  // Not a secret. The Firebase web config is handed to every visitor by design
  // -- it identifies the project, it does not authorise anything. Access is
  // decided by firestore.rules, which is why hiding this file would buy nothing
  // and cost CI its ability to build.
  'firebase-config.js',
];

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

async function exists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

async function build() {
  const dist = join(repoRoot, DIST);
  await rm(dist, { recursive: true, force: true });
  await mkdir(dist, { recursive: true });

  const missing = [];
  for (const entry of PUBLISHED) {
    const from = join(repoRoot, entry);
    if (!(await exists(from))) {
      missing.push(entry);
      continue;
    }
    await cp(from, join(dist, entry), { recursive: true });
  }

  if (missing.length) {
    // Failing here rather than deploying a partial site. A missing
    // firebase-config.js is the common one: it is created from
    // firebase-config.js.example during setup, and a fresh clone that skipped
    // that step would otherwise publish a page that cannot sign anyone in.
    console.error(
      'build: these files are named in PUBLISHED but do not exist:\n' +
        missing.map((m) => '  - ' + m).join('\n') +
        '\n\nIf one of them is firebase-config.js, copy firebase-config.js.example\n' +
        'over it and fill in the values from the Firebase console.'
    );
    process.exit(1);
  }

  console.log(`build: ${DIST}/ contains ${PUBLISHED.join(', ')}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await build();
}
