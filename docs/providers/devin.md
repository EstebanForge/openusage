# Devin

Tracks your Devin quota using the login from the Devin CLI or the Devin app.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly quota used |
| Daily | Daily quota used (falls back to the weekly figure when Devin hides the daily one) |
| Extra Balance | Overage/extra-usage balance in dollars |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Checked in this order — whichever works first wins:

1. Devin CLI credentials: `~/.local/share/devin/credentials.toml` (uses `windsurf_api_key`, and `api_server_url` when present)
2. The Devin app's local state database

If the CLI credentials fail but the app is signed in with a different account, the app's auth is used instead.

## Troubleshooting

- **"Not logged in"** — run `devin auth login`, or sign into the Devin app, then refresh.
- **Daily shows the same as Weekly** — Devin sometimes doesn't expose a separate daily quota; the weekly figure is shown so the row stays meaningful.

## Under the hood

Connect RPC `GetUserStatus` on the configured API server (default `server.codeium.com`). Quota percentages arrive as "remaining" and are flipped to "used". No token refresh — a 401/403 switches to the next auth source instead.
