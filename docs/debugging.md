# Debugging and Capturing Logs

How to run a local build and watch what the app is doing — useful when a provider misbehaves or you're
chasing a startup or refresh problem.

## Run a local build

The project script owns the build/run loop. From the repo root:

```sh
./script/build_and_run.sh          # build, install "OpenUsage Preview", launch it
./script/build_and_run.sh build    # build and stage only, don't launch
./script/build_and_run.sh verify   # launch and confirm the process is running
```

The preview installs as **OpenUsage Preview** in `/Applications` with its own bundle id, so it runs
side-by-side with a released OpenUsage without clobbering its settings.

## Stream logs

To watch the app's logs live while you reproduce an issue:

```sh
./script/build_and_run.sh logs
```

This launches the preview and then streams its unified logs. Under the hood it filters the system log to
the app's process, equivalent to:

```sh
log stream --info --style compact --predicate 'process == "OpenUsage"'
```

To read logs *after the fact* instead of live, use `log show` with a time window:

```sh
log show --last 10m --info --predicate 'process == "OpenUsage"'
```

## Tips

- **A provider shows an error.** Reproduce with `logs` running, then check that provider's page in
  `docs/providers/` for what its error states mean and where it reads credentials from.
- **Nothing updates.** Refresh runs on a timer and respects the cache; see
  [Refreshing & caching](refreshing.md) for when a network call actually happens. Use the per-provider
  "Refresh" in the row's context menu to force one.
- **Permissions / keychain prompts on every rebuild.** The script signs with a stable Apple Development
  identity so the permission ACLs stick. If you see repeated prompts, make sure such an identity exists in
  your keychain (the script warns when it falls back to ad-hoc signing).
- **Inspect the local API.** With the app running, `curl 127.0.0.1:6736/v1/usage` shows the same usage
  snapshots the UI uses — handy to confirm whether a problem is in fetching/mapping or in the UI.
