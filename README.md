# clawdy

Claude Code plugins worth open-sourcing. Small, opinionated tools that do one job.

## Use it

Once, in Claude Code:

```
/plugin marketplace add ZY-Ang/clawdy
```

Then install what you want:

```
/plugin install mvp-kit@clawdy
```

`/plugin` opens the manager to browse what's here.

## Updating

**In a Claude Code session** — the normal way:

```
/plugin marketplace update clawdy
/reload-plugins
```

**From a terminal**, or anywhere without an interactive session — CI, a cloud agent, a script:

```
claude plugin marketplace update clawdy      # refresh the catalog
claude plugin update <name>@clawdy           # move the install to it
```

then restart Claude Code. `claude plugin update --help` says so itself: *"restart required to
apply"*.

Two things about the terminal form specifically, both measured:

- **The `@clawdy` suffix is required.** `claude plugin update statusline` fails with
  `Plugin "statusline" not found`; `claude plugin update statusline@clawdy` works. The error
  suggests the plugin is missing rather than mis-addressed, which is what makes it hard to spot.
- **Refreshing the catalog is not updating the install.** With the catalog offering `0.1.0` and
  the install pinned at `1.1.0`, the pin did not move until `claude plugin update` ran. The two
  live in different places — `~/.claude/plugins/marketplaces/` and
  `~/.claude/plugins/cache/clawdy/<plugin>/<version>/` — and nothing reports the gap between them.

To see what you actually have:

```
claude plugin list
```

## What's here

| Plugin | What it does |
| --- | --- |
| [**mvp-kit**](plugins/mvp-kit) | AI generators build the app. This puts it under CI, tests the security rules they wrote, and sets up backups. |
| [**adhd**](plugins/adhd) | Shape every reply for a reader with ADHD and explain it like they are new to the topic: next action first, numbered steps, zero jargon, and never cutting the context needed to understand it. |
| [**handoff**](plugins/handoff) | Write a handoff document a fresh session can resume from — including what was already tried and failed. |
| [**devloop**](plugins/devloop) | Work a GitHub backlog unattended: prove a PR is really mergeable before asking for review, poll for CI success, reply only after pushing the fix. |
| [**opinionated-claude**](plugins/opinionated-claude) | Install working conventions into your CLAUDE.md — act autonomously rather than asking permission to push, keep private infrastructure detail out of public repos, and never claim "verified" without evidence. |
| [**north-star**](plugins/north-star) | Agree a goal, write it down, get it approved, then work towards it unattended until it is provably reached. You start it; it never starts itself. |
| [**pm**](plugins/pm) | The tracker, both halves. File work and ask questions without blocking — `ask-async` has the shape of AskUserQuestion and returns immediately — then order what comes back: severity wins, a class fix outranks its own instances, and the same input always gives the same queue. |
| [**statusline**](plugins/statusline) | Model, context use and token counts under the prompt — with cost shown on Bedrock and DeepSeek, where you are actually billed for it. |

Install one, or all of them:

```
/plugin install adhd@clawdy
/plugin install handoff@clawdy
/plugin install statusline@clawdy
/plugin install devloop@clawdy
/plugin install opinionated-claude@clawdy
/plugin install north-star@clawdy
/plugin install pm@clawdy
```

## Layout

A monorepo. The catalog and the plugins live together:

```
.claude-plugin/marketplace.json   the catalog
plugins/<name>/                   one directory per plugin
docs/                             design notes
```

Each plugin directory is a complete plugin — its own `.claude-plugin/plugin.json`, its own
skills, agents and templates — and is listed in the catalog by relative path:

```json
{ "name": "mvp-kit", "source": "./plugins/mvp-kit" }
```

One repo means one clone, one PR when a change spans a plugin and the catalog, and one place
to look. Plugins that outgrow that can move to their own repo later and be listed by
`{"source": "github", "repo": "..."}` instead — the catalog supports both, so nothing here
forecloses that.

## Adding a plugin

1. `plugins/<name>/.claude-plugin/plugin.json` with a name, description and version
2. Skills in `plugins/<name>/skills/<skill>/SKILL.md`
3. One entry in `.claude-plugin/marketplace.json` pointing at `./plugins/<name>`
4. `claude plugin validate .` — must pass
5. Test it before pushing: `claude --plugin-dir ./plugins/<name>`
6. Open a PR

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md) for the house rules — POSIX `sh`, exit-code
discipline, what a test has to pin. [`plugins/pm/lib/PROVIDERS.md`](plugins/pm/lib/PROVIDERS.md)
for writing a backend against a tracker other than GitHub.

## Status

Nine plugins, one of them a deprecation stub. `adhd`, `handoff`, `devloop`, `opinionated-claude`, `north-star` and `statusline` are stable — they are prose, with no dependencies and
nothing to break. `pm` absorbed `issues`, so it now carries both filing and ordering; the filing half is settled and the ordering is newer. `mvp-kit` is early; see
[its README](plugins/mvp-kit) for what does and does not work yet.

`issues` is **deprecated** and ships no commands — it remains only to point installs at `pm`.
