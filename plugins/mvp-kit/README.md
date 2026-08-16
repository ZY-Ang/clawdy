# mvp-kit

AI generators build the app. This puts it under CI, tests the security rules they wrote, and
sets up backups.

## Install

In Claude Code, run these two lines once:

```
/plugin marketplace add ZY-Ang/clawdy
/plugin install mvp-kit@clawdy
```

Then run `/reload-plugins` if it asks you to. That's it — you now have `/mvp-kit:new`.

To check it worked, run `/help` and look under **Custom commands** for `mvp-kit`.

### Try it without installing

To test a local copy before installing:

```bash
git clone https://github.com/ZY-Ang/clawdy
claude --plugin-dir ./clawdy/plugins/mvp-kit
```

### Update later

```
/plugin marketplace update clawdy
```

## Use it

In the folder where you want the app, run:

```
/mvp-kit:new
```

It asks four short questions — who uses it, does it need a real server, does anything have to
run on your own machine, is it for the business — and then does two things.

**First it tells you the fastest way to build the app itself**, which is usually not this
plugin. For a Firebase app that's Google AI Studio; for a Supabase one it's Lovable. Those
tools write the page, the login and the database better than a scaffolder would, so the
plugin points at them and gets out of the way.

**Then it does the part they skip:**

| | What it sets up |
| --- | --- |
| **CI** | Pull requests build a preview; merging deploys the live site |
| **Security-rules tests** | Checks that your "only these people can get in" rules actually work |
| **Backups** | So the only copy of your data isn't one database you could delete |
| **Repo tidiness** | Issue labels, a PR template, a sensible `.gitignore` |

You do not have to use a generator. An app you wrote yourself, or one that already exists,
skips straight to the second half.

## Why the security-rules tests matter

Google AI Studio writes your database security rules **and deploys them for you** — then
Google's own documentation tells you to double-check them before sharing your app. Nothing
checks them.

If those rules are wrong, anyone with your URL can read or delete everything. This plugin
ships 12 tests that run against a real database engine on your machine and fail the build if
the rules stop doing what they claim.

## Status

Early. One stack works end to end; the rest are planned.

| | State |
| --- | --- |
| **A** Firebase — Hosting + Firestore + Google sign-in | **works**, 12/12 rules tests pass |
| Deployed to a real Firebase project | **not yet** — everything so far runs offline |
| **C** Supabase · **D** Railway · **E** self-hosted · **B** Cloudflare | not built |
| `/mvp-kit:audit` — fix a repo you already have | not built |

**Nothing here has been deployed to a live site yet.** The template builds, passes its own
checks and passes its security-rules suite, all offline against a local emulator. Following
the generated `docs/SETUP.md` end to end — creating the Firebase project, the deploy account
and the sign-in provider — still needs a person with a browser.

## What's in here

```
skills/new/          the /mvp-kit:new command
templates/
  static-firestore/  the Firebase template
    init.mjs         writes the template into a new folder
    template/        the files it writes
```

The reasoning, the costed comparison of hosts and databases, and the list of things
deliberately rejected live in
[`docs/mvp-kit-plan.md`](../../docs/mvp-kit-plan.md).

## If a better tool comes along

This exists because of a gap: no generator sets up CI, tests the rules it wrote, or warns you
before a free tier cuts you off. **If one starts doing that, the plugin is meant to say so and
point you there instead.** It is justified by the gap, and the gap is allowed to close.
