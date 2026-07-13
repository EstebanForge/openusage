# Command-Line Interface

OpenUsage ships a one-shot `openusage` command for agents and scripts. It prints the documented usage
JSON and exits; it never launches or leaves the menu-bar app running.

```sh
openusage                 # every enabled provider, refreshing stale cache entries
openusage codex           # one provider, refreshing when its cache is stale
openusage codex --force   # refresh through the shared provider engine, cache, print, exit
```

The command and app import the same providers, authentication stores, pricing, refresh coordinator, and
snapshot cache. A normal read reuses snapshots less than five minutes old and refreshes missing or stale
ones. `--force` is the CLI equivalent of the app's manual refresh: it bypasses that freshness gate and
writes successful results to the same cache. Credentials are used locally and never appear in the output.

## Install on `PATH`

The signed executable lives at `OpenUsage.app/Contents/Helpers/openusage`. The Homebrew cask exposes
that helper as the global `openusage` command and owns the symlink across upgrades and uninstalls.

For a direct-download app in `/Applications`, create a user-owned link instead:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/OpenUsage.app/Contents/Helpers/openusage ~/.local/bin/openusage
```

Make sure `~/.local/bin` is on your shell's `PATH`. The link stays current when Sparkle replaces the app
in place.

Exit codes are `0` for success, `2` for invalid arguments, `3` when a requested provider has no snapshot,
and `4` when a refresh or local read fails.
