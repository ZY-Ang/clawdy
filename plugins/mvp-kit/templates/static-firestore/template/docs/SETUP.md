# Setting this up, once

Everything here is a one-time step that no workflow can do for itself: creating
the Firebase project, granting the deploy account its roles, and the console
settings that decide who can sign in. After this, every change ships from a pull
request and nothing is ever deployed from a laptop again.

Budget about 30 minutes. Steps 1–4 are in a browser; the rest is the repo.

---

## 1. Create the Firebase project

<https://console.firebase.google.com> → **Create a project**.

Name it whatever you like; the **project ID** is the part that matters, because
it becomes the live URL (`https://<project-id>.web.app`) and appears in
`.firebaserc`, `firebase-config.js` and both deploy workflows. It cannot be
changed afterwards.

Google Analytics is not needed. Turning it off is one fewer thing collecting
data about a private app.

## 2. Turn on Google Sign-In — and only Google Sign-In

**Authentication** → **Get started** → **Sign-in method** → enable **Google**.

**Leave every other provider disabled.** The allow-list in `firestore.rules` is
a list of email addresses, and the rules require `email_verified`. Google
accounts always satisfy that. Enabling Email/Password would let anyone
self-register an address that happens to be on the list, and an unverified match
would then be enough to get in.

Under **Settings → Authorized domains**, confirm `<project-id>.web.app` and
`<project-id>.firebaseapp.com` are listed. They are added automatically; if
sign-in later fails with `auth/unauthorized-domain`, this is why.

## 3. Create the Firestore database

**Firestore Database** → **Create database** → **Production mode** (start locked
down; the rules in this repo will replace whatever it starts with on the first
merge).

Pick the region closest to the people using it. **This cannot be changed later** —
moving regions means a new database.

## 4. Create the deploy service account

From a terminal in this repo:

```bash
npx firebase login
npx firebase init hosting:github
```

Point it at this GitHub repository. It creates a service account, grants it the
Hosting roles, and stores the JSON key as a repository secret named
`FIREBASE_SERVICE_ACCOUNT_<PROJECT_ID>`. It will also offer to write its own
workflow files — **decline**, or let it write them and then `git checkout` them
away. The workflows in `.github/workflows/` do more than the generated ones:
they run the checks, deploy the security rules, and take backups.

Confirm the secret name it created matches `__SA_SECRET__`, which is what the
workflows reference. If it differs, rename the secret in **GitHub → Settings →
Secrets and variables → Actions**.

Then grant that same service account two roles it does not get automatically, in
the Google Cloud console (**IAM & Admin → IAM**, find the
`github-action-*@<project-id>.iam.gserviceaccount.com` account, **Edit**):

| Role | Needed by | Symptom if missing |
| --- | --- | --- |
| **Firebase Rules Admin** | the rules deploy in `merge.yml` | that step fails with a 403 |
| **Cloud Datastore User** | the nightly backup reading `app/state` | `backup.yml` fails with a permission error |

## 5. Fill in the repo

```bash
cp firebase-config.js.example firebase-config.js
```

Fill it from **Project settings → General → Your apps → Web app → SDK setup and
configuration**. Add a web app there first if none exists. None of this is
secret — it ships to every visitor's browser regardless — which is why
`firebase-config.js` is committed.

Then put the real addresses in the allow-list in `firestore.rules`. The
security-rules suite fails while the `__ALLOWLIST__` placeholder is still there,
so this is not a step you can forget.

```bash
npm install          # generates package-lock.json, which CI needs
npm run check        # should report no drift
npm test             # should pass — this is the rules suite
git add -A && git commit -m "Configure Firebase project" && git push
```

## 6. The first deploy

Merging to `main` deploys. To do it once by hand first — worth it, because a
failure here is easier to read locally than in a workflow log:

```bash
npm run build
npx firebase deploy --only hosting,firestore:rules
```

Then open `https://<project-id>.web.app` and check both halves of the access
model:

- an address **on** the allow-list signs in and can save
- an address **not** on it signs in to Google and is then refused by the app

The second one is the test that matters. If a stranger can read the document,
the rules did not deploy — check that the deploy above mentioned
`firestore: released rules`.

## 7. Set the traps you cannot see coming

- **Spark plan:** nothing to do, but read `docs/QUOTAS.md`. The free tier does
  not throttle, it stops.
- **If you ever upgrade to Blaze:** set a budget alert the same day. Blaze has
  no default spend cap.
- **GitHub labels:** create `needs-human` at minimum. It is how an agent working
  in this repo flags something it should not decide alone.

## 8. Check the backup actually runs

`.github/workflows/backup.yml` runs nightly, but a backup nobody has watched
succeed is not a backup. Trigger it once by hand — **Actions → Backup → Run
workflow** — and confirm a `backups/<date>.json` commit lands on `main`.

It exits non-zero if it finds nothing to read, so a green run with no commit
means the data was simply unchanged, not that it failed silently.
