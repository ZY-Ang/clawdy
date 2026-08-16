---
name: statusline
description: Set up or adjust the Claude Code statusline — model, context percentage, token counts, and cost shown on Bedrock and DeepSeek, where you are actually billed per token. Use when the user wants a statusline, asks why cost is or isn't showing, wants a different currency, or runs /statusline.
user-invocable: true
---

# Statusline

Prints one line under the prompt:

```
[Opus 4.5] 42% context | in:120.4k out:8.1k
[bedrock-claude-opus-4-5] 42% context | in:120.4k out:8.1k | total: $1.23 | turn: +$0.0456
[deepseek-v4-pro[1m]] 42% context | in:1.0M out:1.0M | total: $2.64 | turn: +$0.66
```

**Cost appears only where you are billed per token.** On a claude.ai subscription the dollar
figure is an estimate of what those tokens *would* have cost on the API — nobody is billed it.
Showing it every turn trains you to react to a number that isn't real. On Bedrock and on
DeepSeek you are billed per token, so it means something.

## Install

After installing the plugin, run once:

```bash
"$HOME/.claude/plugins/marketplaces/clawdy/plugins/statusline/bin/claude-statusline-install"
```

The full path is deliberate. A plugin's `bin/` is on the *Bash tool's* `PATH` only, so a bare
`claude-statusline-install` will not resolve either — the same trap the installer exists to
fix. Nothing here is machine-specific: `$HOME` expands per user.

That copies the script to `~/.claude/statusline.sh` and points `statusLine` at it in
`~/.claude/settings.json`. Add `--project` to write the repo's `.claude/settings.json`
instead. Start a new session to see it.

It will not overwrite a `statusLine` you already set to something else — it prints what is
there and stops.

### Why it copies rather than pointing at the plugin

**Installing the plugin alone is not enough, and `"command": "claude-statusline"` will not
work.** A plugin's `bin/` is added to the *Bash tool's* `PATH`; the statusline runs as a
separate process that Claude Code spawns, and it does not inherit that `PATH`. The command
would silently fail to resolve, and a statusline that fails just renders nothing — no error,
no clue.

So the installer writes an absolute path. It copies to `~/.claude/` rather than pointing into
the plugin directory, so the statusline survives the marketplace being removed or the cache
layout changing, and the copy is yours to edit.

### Doing it by hand

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/statusline.sh"
  }
}
```

Requires `jq`; arithmetic uses `awk`, so no `bc`.

## Configuration

All optional, all environment variables.

| Variable | Default | What it does |
| --- | --- | --- |
| `CLAUDE_STATUSLINE_COST` | `auto` | `auto` shows cost on Bedrock and DeepSeek only · `always` · `never` |
| `CLAUDE_STATUSLINE_CURRENCY` | `$` | Symbol to print |
| `CLAUDE_STATUSLINE_FX_RATE` | `1` | Multiplier applied to the USD figure (comma or dot decimal) |
| `CLAUDE_STATUSLINE_DEEPSEEK_RATE` | `auto` | `auto` (Beijing peak 09–12, 14–18) · `peak` · `offpeak` |

Billing yourself in another currency:

```bash
export CLAUDE_STATUSLINE_CURRENCY='SGD '
export CLAUDE_STATUSLINE_FX_RATE=1.27
```

The rate is a static number you set — nothing fetches an exchange rate, so it drifts. Treat
the converted figure as indicative, and update the rate when it matters.

## How DeepSeek cost is calculated

DeepSeek ids are priced from the public rate card ([api-docs.deepseek.com](https://api-docs.deepseek.com/quick_start/pricing), effective 2026-08-16), USD per 1M tokens, off-peak:

| Model | Input (cache miss) | Output |
| --- | --- | --- |
| `deepseek-v4-flash` | $0.22 | $0.66 |
| `deepseek-v4-flash-vision-exp` (same as flash) | $0.22 | $0.66 |
| `deepseek-v4-pro` | $0.66 | $1.98 |

Peak is exactly 2× off-peak, and peak hours are Beijing time 09:00–12:00 and 14:00–18:00. The
tier is picked from the current clock — set `CLAUDE_STATUSLINE_DEEPSEEK_RATE=peak` (or
`offpeak`) to pin it.

Every input token is priced at the cache-miss rate. The session totals don't break cache hits
out, so a session with DeepSeek's automatic context caching costs less than shown — the figure
is an **upper bound**, not a bill. A deepseek id with no published price (the legacy
`deepseek-chat`/`deepseek-reasoner`) gets no cost line rather than an invented one.

## How Bedrock and DeepSeek are detected

Cost shows when **any** of these hold:

1. `.model.id` or `.model.display_name` starts with `bedrock`
2. `.model.id` starts with `deepseek-v4-pro` or `deepseek-v4-flash` — this also covers `deepseek-v4-flash-vision-exp`, priced like flash
3. `CLAUDE_CODE_USE_BEDROCK` is `1` or `true`

Deliberately narrow. Anything unrecognised gets no cost line, because showing a fake number is
worse than showing none — and `CLAUDE_STATUSLINE_COST=always` is there for anyone who
disagrees.

## Why "turn" is not just the last delta

The statusline re-renders many times inside a single turn. If the delta were computed per
render it would reset constantly and always read near zero.

So the script counts human messages in the transcript and only advances the baseline when that
count increases — a real turn boundary. Between boundaries the figure holds steady. State
lives in `$TMPDIR/claude_statusline_<session-id>`, one file per session.

## Troubleshooting

**Nothing appears.** Almost always the command does not resolve, and a statusline that fails
renders nothing rather than an error. Check the configured path actually runs:

```bash
jq -r '.statusLine.command' ~/.claude/settings.json    # what is configured
echo '{}' | "$(jq -r '.statusLine.command' ~/.claude/settings.json)"   # does it run
```

If the command is a bare name like `claude-statusline`, that is the bug — it needs an absolute
path. Re-run the installer by full path, as in Install above.

**An update did not take effect.** Installed plugins live in a *versioned* directory
(`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`), so a fix only reaches you when
the plugin's `version` is bumped. `/plugin marketplace update` refreshes the catalog under
`~/.claude/plugins/marketplaces/`, which is why running the installer from there gets the
newest copy even when the installed one is stale.

**Cost missing on Bedrock or DeepSeek.** Check what the model reports — detection is
prefix-based, so an id that doesn't start with `bedrock`, `deepseek-v4-pro` or
`deepseek-v4-flash` won't match, and unpriced ids (the legacy `deepseek-chat`/
`deepseek-reasoner`) show nothing by design. Set `CLAUDE_CODE_USE_BEDROCK=1`, or
`CLAUDE_STATUSLINE_COST=always`.

**Cost showing where you don't want it.** `CLAUDE_STATUSLINE_COST=never`.

**`turn:` stuck at 0.0000.** Expected until the next turn — the baseline advances only at real
turn boundaries, and if a transcript is already open the first render takes the whole session
cost as the delta.

**`turn:` shows a jump or a negative.** The baseline is stored in USD at the tier of the render
that advanced it, so a delta spanning a DeepSeek peak/off-peak boundary includes the rate
difference, and a state reset (like `/clear`) can print a negative delta until the next turn.
Both are display artifacts, not billing errors.
