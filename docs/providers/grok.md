# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Monthly | Credits used vs. your monthly limit |
| Extra Usage | Pay-as-you-go cap as a status (e.g. `2500 cap` or `Disabled`) |
| Plan | Your subscription tier (optional widget) |

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); OpenUsage reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing` for usage and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.
