// Does firestore.rules actually enforce what its comments claim?
//
// This suite exists because nothing else checks. Google AI Studio drafts rules
// and deploys them for you, while Google's own documentation tells you to
// double-check them before shipping; the generators stop there. Every claim the
// rules file makes is asserted below, against the real Firestore rules engine
// running in the emulator.
//
//   npm test                    # boots the emulator, runs this
//
// The project id is `demo-`-prefixed on purpose. The emulator treats a demo
// project as offline: it will not reach Google, will not ask for credentials,
// and cannot touch production even if someone runs this with a service account
// sitting in the environment.
//
// The allow-list is read out of firestore.rules rather than duplicated here.
// A copy in the test would have to be edited every time someone joins, and the
// day it was forgotten the suite would go green while testing the wrong list.
// Parsing the real file means these tests assert the property that matters --
// "the addresses in that file, and no others, get in" -- for whatever the file
// currently says.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';

import {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} from '@firebase/rules-unit-testing';
import { doc, getDoc, setDoc, deleteDoc } from 'firebase/firestore';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '../..');
const rulesPath = resolve(repoRoot, 'firestore.rules');
const rulesSource = readFileSync(rulesPath, 'utf8');

const STATE_DOC = 'app/state';

// An address that must never be on the list. Chosen from RFC 2606's reserved
// example.com, so it cannot become a real account someone actually controls.
const OUTSIDER = 'not-on-the-list@example.com';

/**
 * Pull the allow-list out of the rules file itself.
 *
 * Deliberately narrow: it reads only the array inside allowed(), so an email
 * address written in a comment somewhere else in the file cannot widen what the
 * tests think is permitted.
 */
function allowListFromRules(source) {
  const block = source.match(/request\.auth\.token\.email in \[([^\]]*)\]/);
  assert.ok(
    block,
    'firestore.rules has no `request.auth.token.email in [...]` allow-list. ' +
      'These tests assume the allow-list shape this template ships with -- if ' +
      'you replaced it with a different access model, replace this suite too ' +
      'rather than deleting it.'
  );
  return [...block[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
}

const allowList = allowListFromRules(rulesSource);

let testEnv;
let INSIDER;

before(async () => {
  // A template that was never filled in is the most likely way to ship broken
  // rules, and it would otherwise sail through: an empty list denies everyone,
  // so every "must be refused" test below would pass for the wrong reason.
  //
  // Note that an unsubstituted scaffolding placeholder lands here too -- it
  // parses as no addresses. `npm run check` names that case specifically; this
  // is the backstop for it and for a list someone emptied by hand.
  assert.ok(
    allowList.length > 0,
    'The allow-list in firestore.rules is empty, so nobody can sign in. Either ' +
      'this repo was scaffolded and never configured, or the list was emptied. ' +
      'An app nobody can use is not a safe default.'
  );
  assert.ok(
    !allowList.includes(OUTSIDER),
    `${OUTSIDER} is on the allow-list in firestore.rules. It is this suite's ` +
      'stand-in for a stranger and must not be a real member.'
  );
  INSIDER = allowList[0];

  const host = process.env.FIRESTORE_EMULATOR_HOST ?? '127.0.0.1:8080';
  const [emulatorHost, emulatorPort] = host.split(':');

  testEnv = await initializeTestEnvironment({
    projectId: 'demo-__APP_SLUG__-rules',
    firestore: {
      rules: rulesSource,
      host: emulatorHost,
      port: Number(emulatorPort),
    },
  });
});

after(async () => {
  await testEnv?.cleanup();
});

/** A signed-in context with a verified Google-shaped identity. */
function asVerified(email) {
  return testEnv.authenticatedContext('uid-' + email, {
    email,
    email_verified: true,
  }).firestore();
}

/** Signed in, but with an address nothing has proved they own. */
function asUnverified(email) {
  return testEnv.authenticatedContext('uid-' + email, {
    email,
    email_verified: false,
  }).firestore();
}

/** Put the document into a known state, ignoring the rules to get there. */
async function seedState(data) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), STATE_DOC), data);
  });
}

test.beforeEach(async () => {
  await testEnv.clearFirestore();
});

// --- Who gets in ------------------------------------------------------------

test('a stranger who never signed in is refused', async () => {
  const db = testEnv.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(db, STATE_DOC)));
  await assertFails(setDoc(doc(db, STATE_DOC), { version: 1 }));
});

test('a signed-in Google account that is not on the list is refused', async () => {
  const db = asVerified(OUTSIDER);
  await assertFails(getDoc(doc(db, STATE_DOC)));
  await assertFails(setDoc(doc(db, STATE_DOC), { version: 1 }));
});

test('an address on the list is refused until it is verified', async () => {
  // The guard against enabling email/password sign-in, where anyone could
  // self-register an address that happens to be on the list.
  const db = asUnverified(INSIDER);
  await assertFails(getDoc(doc(db, STATE_DOC)));
  await assertFails(setDoc(doc(db, STATE_DOC), { version: 1 }));
});

test('an allow-listed, verified account can read and create the state document', async () => {
  const db = asVerified(INSIDER);
  await assertSucceeds(setDoc(doc(db, STATE_DOC), { version: 1 }));
  await assertSucceeds(getDoc(doc(db, STATE_DOC)));
});

test('every address on the list gets in, not just the first', async () => {
  // Catches a list that was edited into a shape the rules engine does not
  // actually read -- a stray comma, a smart quote pasted from a chat message.
  for (const email of allowList) {
    const db = asVerified(email);
    await testEnv.clearFirestore();
    await assertSucceeds(setDoc(doc(db, STATE_DOC), { version: 1 }));
  }
});

// --- What they can reach ----------------------------------------------------

test('being on the list does not open the rest of the database', async () => {
  const db = asVerified(INSIDER);
  await assertFails(setDoc(doc(db, 'app/other'), { version: 1 }));
  await assertFails(setDoc(doc(db, 'somewhere/else'), { version: 1 }));
  await assertFails(getDoc(doc(db, 'somewhere/else')));
});

test('nobody can delete the state document', async () => {
  await seedState({ version: 1 });
  const db = asVerified(INSIDER);
  await assertFails(deleteDoc(doc(db, STATE_DOC)));
});

// --- The version guard ------------------------------------------------------
//
// This is the failure that cost a real app four days of data: a device holding
// a stale copy saved over everything that had happened since. Enforcing it in the
// rules rather than in the page means it still holds for a client running
// cached JavaScript from before the guard shipped.

test('a fresh document must start at version 1', async () => {
  const db = asVerified(INSIDER);
  await assertFails(setDoc(doc(db, STATE_DOC), { version: 7 }));
  await assertSucceeds(setDoc(doc(db, STATE_DOC), { version: 1 }));
});

test('a save that advances the version by exactly one is accepted', async () => {
  await seedState({ version: 4 });
  const db = asVerified(INSIDER);
  await assertSucceeds(setDoc(doc(db, STATE_DOC), { version: 5 }));
});

test('a stale client rewriting the same version is rejected', async () => {
  await seedState({ version: 4 });
  const db = asVerified(INSIDER);
  await assertFails(setDoc(doc(db, STATE_DOC), { version: 4 }));
});

test('a save that skips versions is rejected', async () => {
  await seedState({ version: 4 });
  const db = asVerified(INSIDER);
  await assertFails(setDoc(doc(db, STATE_DOC), { version: 6 }));
});

test('a write with no version at all is rejected', async () => {
  // The shape a hand-written console edit or a half-migrated client produces.
  await seedState({ version: 4 });
  const db = asVerified(INSIDER);
  await assertFails(setDoc(doc(db, STATE_DOC), { note: 'no version field' }));
});
