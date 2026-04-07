# Reliable Elixir Hosting on NearlyFreeSpeech

## The Problem

[NearlyFreeSpeech.NET](https://www.nearlyfreespeech.net/) (NFS) is affordable shared
hosting that runs on FreeBSD. They support Elixir and Erlang, which makes it a viable
option for small Elixir/Phoenix projects.

However, NFS periodically performs **realm updates** — roughly once a quarter — which
can bump the Erlang/OTP version. When this happens, your existing compiled BEAM files
become incompatible with the new runtime and your application crashes on startup with
`load_failed` errors. NFS's daemon manager tries to restart your app, burns through its
retry limit against the broken release, gives up, and emails you. Your site is down
until you manually SSH in and recompile.

This repo solves that problem with two complementary approaches:

1. **Bundle ERTS with your release** (`include_erts: true`, the default). Since you
   build on the server, the release includes a copy of the Erlang runtime from the
   moment it was compiled. A realm update changes the *system* Erlang, but your release
   uses its own bundled copy — so it keeps running.

2. **Auto-rebuild when the environment changes.** The daemon run script records a build
   environment fingerprint (OS + Elixir + ERTS versions) and compares it on startup. If
   anything has changed, it rebuilds from source before starting. This handles the case
   where your app needs to restart after a realm update — the old bundled ERTS is gone
   and you need a fresh build against the new system.

Together, these mean: your app survives realm updates without restarting, and if it does
need to restart, it rebuilds automatically. No human intervention required.

## How It Works

Your application is built **on the server** from source tarballs. This is necessary
because NFS runs FreeBSD and you likely develop on macOS or Linux — cross-compiling
Erlang releases for FreeBSD is not practical. Building on the server also means that
realm updates can be fixed with a simple recompile.

Each release records a **build environment fingerprint** — Elixir version, and
ERTS (Erlang Runtime System) version it was compiled against. Before
starting, the daemon script compares this fingerprint against the current
system. If anything has changed, it triggers a full rebuild.

```
NFS daemon management
  └── run.sh
        ├── compares BUILD_ENV fingerprint
        ├── rebuilds if environment changed (calls build.sh)
        └── exec's into your Elixir release
```

### Normal startup (no realm update)

1. NFS starts `run.sh`
2. Script compares the build environment fingerprint — it matches
3. Script immediately `exec`s into your release
4. App is up in seconds

### After a realm update

Because the release bundles its own ERTS, your app usually **keeps running** through a
realm update without any intervention. The auto-rebuild only matters if the app needs to
restart (eg NFS reboots the server, you deploy, or the process crashes for another
reason):

1. NFS starts `run.sh`
2. Script compares fingerprints — they differ (eg ERTS 14.2.5.12 → 14.2.5.15)
3. Script calls `build.sh` which recompiles from source (~2-3 minutes)
4. New release is installed, fingerprint is recorded
5. Old incompatible releases are automatically removed
6. Script `exec`s into the new release
7. App is up automatically, no human intervention

### Normal deploy (from your laptop)

1. Run `create-release.sh` to build a source tarball (frontend assets + Elixir source)
2. Run `push.sh` to upload and build on the server
3. The running app shuts down, NFS restarts the daemon
4. `run.sh` checks the fingerprint — it matches — instant start

## Repository Structure

```
├── README.md
│
├── server/                     ← files that live on the NFS server
│   ├── setup.sh                ← one-time directory + permission setup
│   ├── build.sh                ← build script (compile + release + symlink)
│   └── run.sh.example          ← daemon entry point template (copy + fill in secrets)
│
├── scripts/                    ← files that run on your local machine
│   ├── create-release.sh       ← build a source tarball
│   └── push.sh                 ← upload + build + deploy to the server
│
└── elixir/                     ← Elixir modules to add to your project
    ├── shutdown_watcher.ex     ← detects shutdown file, stops the app gracefully
    └── background_tasks.ex     ← periodic task scheduler (runs the shutdown watcher)
```

## Directory Layout on NFS

```
/home/protected/
├── run.sh                ← NFS daemon script (env vars + environment check + exec)
├── build.sh              ← build script (compile + release + symlink)
│
├── workspace/            ← persistent build directory
│   ├── config/
│   ├── lib/
│   ├── priv/
│   ├── mix.exs
│   ├── mix.lock
│   ├── _build/           ← persists between builds
│   └── deps/             ← persists between builds so deps aren't re-fetched
│
└── releases/
    ├── myapp-20260403-abc1234/
    │   ├── bin/
    │   ├── lib/
    │   ├── releases/
    │   └── BUILD_ENV     ← eg "Elixir 1.17.3 (...) | 14.2.5.15"
    ├── myapp-20260404-def5678/
    └── current-release -> myapp-20260404-def5678/
```

The `workspace/` directory persists `deps/` between builds so dependencies aren't
re-fetched on every deploy. `build.sh` always compiles with `--force` for simplicity.

## Quick Start

### 1. Run the setup script on your server

```sh
ssh YOUR_NFS_SSH 'sh -s' < server/setup.sh
```

This creates the `workspace/` and `releases/` directories with the correct permissions.

### 2. Copy the server scripts

```sh
scp server/build.sh YOUR_NFS_SSH:/home/protected/
ssh YOUR_NFS_SSH 'chmod +x /home/protected/build.sh'
```

### 3. Create the daemon run script

Copy `server/run.sh.example` to your server as `run.sh` and fill in your app's
environment variables:

```sh
scp server/run.sh.example YOUR_NFS_SSH:/home/protected/run.sh
ssh YOUR_NFS_SSH 'chmod +x /home/protected/run.sh'
# Then SSH in and edit run.sh with real values
```

This file contains secrets and should **not** be committed to version control.

### 4. Edit the scripts for your project

In `server/build.sh`, change `APP_NAME` to match your Mix project name. In
`scripts/push.sh`, set `APP_NAME` and `NFS_SSH` to match your project and NFS login.

### 5. Add the Elixir modules to your project

Copy the files from `elixir/` into your project's `lib/` directory and rename the
module prefixes from `MyApp` to your application module name.

Add the background task scheduler and a `Task.Supervisor` to your application's
supervision tree in `application.ex`:

```elixir
children = [
  # ... your other children (Repo, Endpoint, etc.)
  {Task.Supervisor, name: MyApp.TaskSupervisor},
  MyApp.BackgroundTasks
]
```

Update the `@shutdown_file` path in `shutdown_watcher.ex` to match the `SHUTDOWN_FILE`
setting in `scripts/push.sh`.

### 6. Configure `mix.exs`

Make sure your release is configured in `mix.exs`. The default settings are fine — in
particular, leave `include_erts: true` (the default) so that each release bundles its
own copy of the Erlang runtime. This is what allows your app to survive realm updates
without restarting.

```elixir
releases: [
  myapp: [
    # include_erts: true is the default — don't set it to false
  ]
]
```

### 7. Register the daemon in the NFS control panel

- **Site Information → Daemons → Add Daemon**
- Command: `/home/protected/run.sh`
- Run as: `web`
- Tag: choose a name (eg `myapp`)

### 8. Set up the NFS proxy

- **Site Information → Proxies → Add Proxy**
- Protocol: `HTTP`
- Base Path: `/`
- Port: whatever you set `PORT` to in `run.sh`

### 9. Deploy

```sh
./scripts/create-release.sh
./scripts/push.sh
```

## Deploy Workflow

Day-to-day deployment is two commands:

```sh
# Build a source tarball locally (compiles frontend assets, packages source)
./scripts/create-release.sh

# Upload to server, build, deploy, restart
./scripts/push.sh
```

To deploy a specific release (eg for rollback):

```sh
./scripts/push.sh myapp-20260403163237-abc1234
```

### What `push.sh` does

1. SCPs the source tarball to the server's `workspace/`
2. SSHs in and calls `build.sh` (extract, compile, install, symlink, record environment fingerprint)
3. Creates the shutdown sentinel file
4. Your app's `ShutdownWatcher` detects the file and calls `System.stop(0)`
5. NFS restarts the daemon → `run.sh` checks fingerprint → matches → instant start

Downtime during a normal deploy: a few seconds.

## Frontend Assets

If your project has frontend assets, build them locally before running
`create-release.sh` so that the compiled output is in `priv/static/` when the tarball
is created. The commented-out lines in `create-release.sh` show one approach; adapt to
your own build tooling.

If your project has no frontend (eg a pure API), you can ignore this entirely.

## Graceful Shutdown

During deploys, the running app needs to shut down so NFS can restart it with the new
release. This repo uses a **shutdown sentinel file** approach.

The `push.sh` script creates a file at a known path (default: `/tmp/MY_APP_SHUTDOWN`).
The `ShutdownWatcher` module in your Elixir app checks for this file every 5 seconds.
When it finds it, it deletes the file and calls `System.stop(0)` for a graceful
shutdown. NFS detects the process exited and restarts the daemon.

This approach is simple and doesn't depend on Erlang's distribution system being
configured.

The relevant files:

- `elixir/shutdown_watcher.ex` — the module that checks for the file
- `elixir/background_tasks.ex` — a GenServer that calls the watcher every 5 seconds

## Rollback

SSH in, update the symlink, and trigger a restart:

```sh
# List available releases
ls -lt /home/protected/releases/

# Point at the previous release
ln -sfn /home/protected/releases/myapp-PREVIOUS \
        /home/protected/releases/current-release

# Trigger a restart
touch /tmp/MY_APP_SHUTDOWN
```

NFS restarts the daemon, the environment check passes, and the old release is live.

**Note:** Rollback only works within the same build environment. After a realm update,
old incompatible releases are automatically removed by `build.sh`.

## Permissions

NFS runs daemons as the `web` user. When you SSH in, you are a different user. Both
users need to read and write the build and release directories.

The scripts use `umask 000`, which makes every new file world-readable and
world-writable. Since everything lives inside `/home/protected/` (which is not
web-accessible on NFS), this is safe.

We tried more restrictive approaches (shared groups, setgid, `g+rwX`) but they break
in practice. Elixir's `mix release` and `mix compile` perform operations like
`File.chmod!` and `File.touch!` that require file ownership, not just group write
permission. `umask 000` is simple, reliable, and appropriate for this context.

**If you encounter permission errors on existing files**, delete and rebuild:

```sh
rm -rf /home/protected/workspace/_build
rm -rf /home/protected/workspace/deps
rm -rf /home/protected/releases/*
```

The next build recreates everything with correct permissions.

## Logs

NFS captures your daemon's stdout at `/home/logs/daemon_YOURTAG.log`, where `YOURTAG`
is the tag you chose when registering the daemon. This includes build output from
`build.sh` and your Elixir app's Logger output.

```sh
ssh YOUR_NFS_SSH 'tail -f /home/logs/daemon_YOURTAG.log'
```

## Configuration Reference

Settings you need to customize, and where:

| Setting | Where | Description |
|---------|-------|-------------|
| `APP_NAME` | `server/build.sh`, `scripts/push.sh` | Your Mix project name |
| `NFS_SSH` | `scripts/push.sh` | Your NFS SSH login |
| `SHUTDOWN_FILE` | `scripts/push.sh`, `elixir/shutdown_watcher.ex` | Path to shutdown sentinel file |
| `SHUTDOWN_WAIT` | `scripts/push.sh` | Seconds to wait after creating shutdown file (default: 10) |
| `RELEASES_TO_KEEP` | `server/build.sh` | Number of old releases to keep for rollback (default: 4) |
| Env vars | `server/run.sh` (on server) | `SECRET_KEY_BASE`, `DATABASE_URL`, `PORT`, etc. |

## FAQ

### Why build on the server instead of locally?

NFS runs FreeBSD. Cross-compiling Erlang releases (including ERTS) for FreeBSD from
macOS is fragile if possible at all. Building on the server guarantees the release —
and its bundled ERTS — matches the runtime environment. It also means realm updates can
be fixed automatically with a recompile.

### How long does a rebuild take?

Builds take ~2-3 minutes depending on project size. `build.sh` always runs
`mix compile --force` for simplicity and reliability. `deps/` persists in the workspace
so dependencies aren't re-fetched each time.

### Can I get notified before a realm update?

As of 2026, NFS does not offer advance notification. You can elect "late" realm updates
in the Site Information panel, which lets you trigger updates manually on your schedule.
If you do this, you must update at least once a quarter — NFS will force-update sites
that fall 18-24 months behind.

### What if the rebuild fails?

`build.sh` uses `set -e`, so it exits on the first error. NFS will try to restart the
daemon, which will attempt the build again. If builds keep failing, SSH in and run
`build.sh` manually to see the full error output:

```sh
cd /home/protected/workspace
MIX_ENV=prod /home/protected/build.sh
```

### Why bundle ERTS (`include_erts: true`)?

When `include_erts: true` (the default), each release includes its own copy of the
Erlang runtime. This means a realm update that changes the system Erlang doesn't affect
your running app — it's using its bundled copy. Your app only needs a rebuild when you
deploy or when it restarts after a realm update. This is much more resilient than
`include_erts: false`, which makes your release depend on the system Erlang and crash
immediately when it changes.

Since you're building on the server (not cross-compiling), the bundled ERTS always
matches the build environment. There's no downside.

### What does the build environment fingerprint look like?

It's a single line in a file called `BUILD_ENV` inside each release directory:

```
Elixir 1.17.3 (compiled with Erlang/OTP 26) | 14.2.5.15
```

If any part of this string changes between builds, `run.sh` triggers a full rebuild
and removes old releases that were built against the previous environment.

### What about NIFs (native extensions)?

If your project depends on packages with NIFs, they also need recompilation after a
realm update. The `mix compile --force` in `build.sh` handles this. Some NIFs use
precompiled binaries downloaded at compile time — if a NIF download fails with
permission errors, delete `deps/` and rebuild.

### Why the shutdown sentinel file instead of the release `stop` command?

The release `stop` command relies on Erlang's distribution system (`epmd`, node names,
cookies) being configured correctly. The sentinel file approach has zero dependencies —
it's just a file on disk. It works regardless of how your release is configured.

## License

This project is released under [CC0] — no rights reserved.

You are free to use, copy, modify, and distribute everything here for any purpose,
including copying the scripts and Elixir modules directly into your own projects.
No attribution required. Also there is no warranty 😉

[CC0]: https://creativecommons.org/publicdomain/zero/1.0/
