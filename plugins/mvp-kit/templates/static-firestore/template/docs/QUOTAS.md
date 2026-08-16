# Free-tier limits, and what happens when you reach them

**Checked August 2026.** Every number here has moved before and will move again —
Firebase dropped Cloud Storage from the Spark plan in February 2026. Verify
against <https://firebase.google.com/pricing> before relying on any of it.

The reason this file exists: the free tier does not slow down when you reach a
limit. It stops.

## Hosting (Spark)

| | Limit | On overage |
| --- | --- | --- |
| Storage | 10 GB | — |
| Data transfer | **10 GB/month** | **The site is disabled until the next calendar month** |

This is the one that ends an app. A static page is a few hundred KB, so 10 GB is
tens of thousands of loads — comfortable for a private tool, not for anything
that gets shared publicly or embeds images.

**If this app is ever going to be public or image-heavy, it is on the wrong
plan.** That is a stack decision, not a quota decision: either Blaze with a
budget alert, or a host without a metered cliff.

## Firestore (Spark)

| | Daily limit |
| --- | --- |
| Document reads | 50,000 |
| Document writes | 20,000 |
| Deletes | 20,000 |
| Stored data | 1 GiB |

Reads and writes reset daily, so hitting one is a bad day rather than a bad
month. This app makes roughly one read per sign-in and one write per save, which
does not approach it.

**What does approach it:** a polling loop, a `onSnapshot` listener left attached
to a page nobody closed, or a list view that reads every document to render.
Each of those turns a handful of daily operations into thousands.

## Authentication

Google Sign-In is unlimited on Spark. It is not a constraint here.

## Blaze, if you upgrade

**Blaze has no default spend cap.** A budget alert emails you; it does not stop
anything. There is no setting that hard-stops billing.

Set one the same day you upgrade:

Google Cloud console → **Billing → Budgets & alerts → Create budget**, scoped to
this project, with thresholds at 50% / 90% / 100% of a number you would be
annoyed to pay.

## Watching it

Firebase console → **Usage and billing** shows the current month against each
limit. There is no free automatic alert before a Spark hard-stop, which is worth
saying plainly: **on the free plan, checking this page is the alerting.**

Look at it if the app suddenly stops loading, and once a month otherwise. If
that is not good enough for what this app has become, that is the signal to move
to Blaze with a budget alert rather than to build monitoring around a free tier.
