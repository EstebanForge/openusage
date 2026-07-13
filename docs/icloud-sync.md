# iCloud Sync

**Sync Across Macs** is off by default. When it is on, each Mac writes one versioned OpenUsage history
file to the app's private iCloud container and reads the files written by other Macs signed into the same
iCloud account. There is no folder picker, pairing code, or separate account.

The file contains normalized daily tokens and spend, model totals, and unknown-model names for sources
that are local to one Mac: Claude, Codex, Grok, and OpenCode. It does not contain credentials, account
limits, raw logs, or provider responses. Cursor's history is already account-wide, so it stays local and
is never added across Macs.

OpenUsage combines the valid files in memory and rebuilds Today, Yesterday, Last 30 Days, Usage Trend,
unknown-model warnings, and model breakdowns. The same combined spend rows feed the dashboard, Total
Spend, menu-bar pins, share cards, and the local HTTP API. Both `/v1/usage` and `/v1/limits` read the
same rendered snapshots; the former is the deprecated UI-oriented format and the latter is the
normalized format. Quotas, plans, balances, and provider errors remain this Mac's own values inside
those snapshots.

This Mac updates its file after a five-minute refresh batch, a manual refresh, or a provider enablement
change. iCloud delivery is eventually consistent, so another Mac can take longer than five minutes to
receive it, especially while offline. Downloaded changes reload immediately when macOS reports them.

Settings lists each valid device file with the time that Mac generated it. **Remove** deletes another
Mac's file, although that Mac can create it again on its next update while sync remains enabled there.
Turning sync off deletes this Mac's file, stops reading peers, and immediately returns every surface to
local-only spend. Malformed files are ignored and reported in Settings and the app log.
