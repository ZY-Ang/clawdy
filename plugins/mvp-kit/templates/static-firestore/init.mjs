#!/usr/bin/env node
// Materialise the static-firestore template into a repo.
//
//   node init.mjs --into ../my-app \
//                 --name "My App" \
//                 --project-id my-app-1234 \
//                 --allow alice@example.com,bob@example.com
//
// This is the mechanical half of `/mvp-kit:new`: copy files, substitute tokens,
// leave a repo that passes its own checks. Everything requiring judgement -- which
// stack, which questions to ask, what the app is -- belongs in the skill, not here.
//
// It refuses to write into a directory that already has an index.html or a
// firestore.rules. Overwriting a repo someone has already worked in is the one
// mistake here that cannot be undone with git, because the files it would clobber
// may never have been committed.

import { readdir, readFile, writeFile, mkdir, stat, cp } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve, join, relative } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const templateDir = join(here, 'template');

// Files copied byte-for-byte. Substituting tokens in a lockfile or an image
// would corrupt it, and a lockfile is the realistic case once someone runs
// `npm install` before scaffolding a sibling repo.
const VERBATIM = [/package-lock\.json$/, /\.(png|jpe?g|gif|ico|webp|woff2?)$/i];

// Written under a different name than they are stored under. `.gitignore` is
// stored as `gitignore` because a real one sitting in this template directory
// would silently apply to the repository the kit itself lives in.
const RENAME = new Map([['gitignore', '.gitignore']]);

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith('--')) {
      args[key] = true;
    } else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}

function die(message) {
  console.error(`init: ${message}`);
  process.exit(1);
}

const args = parseArgs(process.argv.slice(2));

const into = args.into;
const name = args.name;
const projectId = args['project-id'];
const allow = args.allow;

if (!into || !name || !projectId || !allow) {
  die(
    'missing arguments.\n\n' +
      '  --into        directory to write into (created if absent)\n' +
      '  --name        human name, e.g. "My App"\n' +
      '  --project-id  Firebase project id, e.g. my-app-1234\n' +
      '  --allow       comma-separated email addresses allowed to sign in\n'
  );
}

// Firebase project ids are lowercase letters, digits and hyphens, 6-30 chars.
// Checking here rather than at deploy time, because the id is baked into the
// live URL, .firebaserc, the web config and both workflows -- finding out it was
// wrong means editing five files, not one.
if (!/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(projectId)) {
  die(
    `"${projectId}" is not a valid Firebase project id. Lowercase letters, ` +
      'digits and hyphens; 6-30 characters; must start with a letter.'
  );
}

const emails = String(allow)
  .split(',')
  .map((e) => e.trim())
  .filter(Boolean);

if (emails.length === 0) die('--allow listed no addresses, so nobody could sign in.');
for (const email of emails) {
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) die(`"${email}" is not an email address.`);
}

const slug =
  String(name)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '') || 'app';

const tokens = {
  __APP_NAME__: name,
  __APP_SLUG__: slug,
  __PROJECT_ID__: projectId,
  // The name `firebase init hosting:github` gives the secret it creates.
  __SA_SECRET__: 'FIREBASE_SERVICE_ACCOUNT_' + projectId.toUpperCase().replace(/-/g, '_'),
  __ALLOWLIST__: emails.map((e) => `        '${e}'`).join(',\n'),
};

function substitute(text) {
  return text.replace(/__[A-Z0-9_]+__/g, (token) =>
    Object.hasOwn(tokens, token) ? tokens[token] : token
  );
}

const target = resolve(process.cwd(), into);

async function exists(path) {
  try {
    await stat(path);
    return true;
  } catch {
    return false;
  }
}

for (const guard of ['index.html', 'firestore.rules', 'package.json']) {
  if (await exists(join(target, guard))) {
    die(
      `${relative(process.cwd(), join(target, guard))} already exists. This ` +
        'would overwrite work that may never have been committed. Scaffold into ' +
        'an empty directory, or use /mvp-kit:audit on the existing repo.'
    );
  }
}

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      yield* walk(full);
    } else {
      yield full;
    }
  }
}

let written = 0;
for await (const source of walk(templateDir)) {
  const rel = relative(templateDir, source);
  const parts = rel.split('/');
  parts[parts.length - 1] = RENAME.get(parts[parts.length - 1]) ?? parts[parts.length - 1];
  const dest = join(target, parts.join('/'));

  await mkdir(dirname(dest), { recursive: true });

  if (VERBATIM.some((re) => re.test(source))) {
    await cp(source, dest);
  } else {
    await writeFile(dest, substitute(await readFile(source, 'utf8')));
  }
  written += 1;
}

// firebase-config.js is the one file the template cannot fill in -- the values
// come from the Firebase console after the project exists. Seeding it from the
// example keeps `npm run build` and `npm run check` working immediately, and
// leaves REPLACE_ME sitting where anyone would see it.
const configPath = join(target, 'firebase-config.js');
if (!(await exists(configPath))) {
  await cp(join(target, 'firebase-config.js.example'), configPath);
  written += 1;
}

console.log(`init: wrote ${written} files into ${relative(process.cwd(), target) || '.'}`);
console.log(`
Next:
  cd ${relative(process.cwd(), target) || '.'}
  npm install            # generates package-lock.json, which CI needs
  npm run check          # should report no drift
  npm test               # runs the security-rules suite (needs a JDK)

Then follow docs/SETUP.md. Nothing above touches Firebase or GitHub -- the
project, the deploy service account and the sign-in provider are all still to be
created, and REPLACE_ME is still sitting in firebase-config.js.`);
