---
name: issues
description: Deprecated. This plugin's commands moved into `pm`, which now carries both halves of the tracker — filing and asking, plus the queue that orders what comes back. Install `pm` and uninstall this.
user-invocable: true
---

# issues — moved into `pm`

**Every command this plugin provided now ships in `pm`.** Nothing was dropped and nothing changed
its name or its flags.

```bash
claude plugin install pm@clawdy
claude plugin uninstall issues
```

`claude plugin update issues` does **not** do this. The commands are gone from this plugin, so an
update alone leaves you with neither copy.

| Was here | Now |
| --- | --- |
| `file-issue`, `ask-async`, `reply-issue`, `check-replies` | `pm` |
| `questions`, `interview-window` | `pm` |
| the `AskUserQuestion` deny hook, the open-questions reminder | `pm` |
| `/issues:issues` | `/pm:tracker` |

## Why they merged

They were one job split across two installs.

`pm`'s ready-filter consumes the exact verdict `check-replies` computes — *is the ball still with
the human* — and a definition living in two plugins is a definition that drifts. Ordering a backlog
also needs `persist.sh`'s `slugify()` to key clusters the same way notes are keyed. Neither is a
dependency you can express between plugins, so the boundary was being paid for in copied files.

## Why this ships no commands

The alternative was a shim: keep `file-issue` here, have it hand off to `pm`'s copy. That puts
**two `file-issue` binaries on `PATH`**, and which one answers is decided by install order rather
than by either plugin. A silent wrong-copy is worse than a missing command, and `lib/shape.sh`
already states the rule this follows — *a guard that silently does nothing when a sibling plugin is
absent is worse than no guard.*

So this version fails loudly instead. If a command is not found, that is this plugin telling you
the install is half-done.
