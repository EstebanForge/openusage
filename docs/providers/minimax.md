# MiniMax

Tracks MiniMax Coding Plan session usage using your API key, with automatic GLOBAL/CN endpoint
selection.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Prompts or percentage used in the current coding-plan window |
| Plan | Your tier (Starter / Plus / Max / Ultra), inferred from the limit and suffixed with region |

## Where credentials come from

Set one of these environment variables:

```bash
# GLOBAL (minimax.io) — default
export MINIMAX_API_KEY="your-api-key"

# CN (minimaxi.com) — takes precedence if set
export MINIMAX_CN_API_KEY="your-cn-api-key"
```

When `MINIMAX_CN_API_KEY` is set, the CN endpoint is tried first; otherwise the GLOBAL endpoint is
tried first. The endpoint that has a key wins.

**GUI-launch note:** apps launched from Finder/Spotlight (children of `launchd`) don't inherit
`.zshrc` exports. OpenUsage works around this by spawning a login shell once at first lookup to
capture your exports. If your `.zshrc` touches the terminal (powerlevel10k instant-prompt, a prompt
that reads stdin), gate that block behind `[[ -z "$OPENUSAGE_ENV_READER" ]]` so it doesn't hang the
capture. Alternatively, `launchctl setenv MINIMAX_API_KEY "..."` puts the var straight into launchd's
environment with no shell involved.

## Two response shapes

MiniMax's token-plan API returns either:
- **Count mode** — `current_interval_total_count` > 0, showing prompts used vs. your plan ceiling.
  CN endpoints report model-call counts (15 per prompt); GLOBAL reports prompts directly.
- **Percent mode** — `remaining_percent` when the total is 0 or absent (the newer Token Plan API).

## Troubleshooting

- **"MiniMax API key missing"** — export `MINIMAX_API_KEY` (or `MINIMAX_CN_API_KEY` for China).
- **"Session expired"** — the API key is invalid or expired; regenerate it at [minimax.io](https://minimax.io).

## Under the hood

`GET https://www.minimax.io/v1/token_plan/remains` (GLOBAL) or
`GET https://api.minimaxi.com/v1/token_plan/remains` (CN). Plan tiers are inferred from the limit
count (GLOBAL: 100/300/1000/2000 = Starter/Plus/Max/Ultra; CN: 600/1500/4500 = Starter/Plus/Max).
The coding-plan window resets every 5 hours.
