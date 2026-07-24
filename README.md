# Elixir/Phoenix Hosting on NearlyFreeSpeech

Shell scripts and Elixir modules for hosting an Elixir/Phoenix app on
[NearlyFreeSpeech.NET](https://www.nearlyfreespeech.net/) (NFS) — affordable
shared hosting that runs on FreeBSD.

## How It Works

Your app is built **on the server** from source. This is necessary because NFS runs
FreeBSD and you likely develop on macOS or Linux — cross-compiling Erlang releases
for FreeBSD isn't practical.

The deploy flow:

1. **Locally:** `create-release.sh` packages your source into a tarball (with a SHA-256 checksum)
2. **Locally:** `push.sh` uploads the tarball to the server and kicks off a build
3. **On server:** `build.sh` extracts, compiles, creates an Elixir release, and symlinks it
4. **On server:** Your running app detects a shutdown file and exits gracefully
5. **NFS daemon manager** restarts the process → `run.sh` starts the new release

Downtime during a normal deploy: a few seconds.

```
your laptop                          NFS server
──────────                           ──────────
create-release.sh                    
  └─ tar source + checksum           
push.sh ─── scp ──────────────────►  build.sh
                                       ├─ verify checksum
                                       ├─ mix deps.get + compile + release
                                       ├─ symlink current-release
                                       └─ record BUILD_ENV fingerprint
         ── touch shutdown file ───►  ShutdownWatcher detects file
                                       └─ System.stop(0)
                                     NFS restarts daemon
                                       └─ run.sh → exec release
push.sh ── polls HEALTH_URL ──────►  app returns 2xx → availability check passed
```

### Resilience: surviving NFS realm updates

NFS performs **realm updates** roughly once a quarter, which can bump the
Erlang/OTP version. This breaks existing compiled BEAM files.

Two mechanisms handle this automatically:

- **Bundled ERTS** (`include_erts: true`, the default). Each release includes its own
  copy of the Erlang runtime, so a realm update doesn't affect a running app.

- **Auto-rebuild on startup.** `run.sh` records a build environment fingerprint
  (Elixir + ERTS versions) and compares it before starting. If anything changed,
  it calls `build.sh` to recompile from source (~2-3 min), then starts the new release.
  If the incremental build fails (eg stale artifacts or precompiled NIFs broken by
  the realm update), `build.sh` wipes `deps/` and `_build/` and retries once from a
  clean slate, allowing common stale-artifact failures to recover unattended.

Your app keeps running through realm updates. If it does need to restart, it rebuilds
itself. No SSH required.

> **Note on the fingerprint:** the same fingerprint is computed in two places —
> `build.sh` (writes `BUILD_ENV`) and `run.sh` (compares against it). The two
> format strings must stay byte-identical, or every daemon start will trigger a
> spurious rebuild. Both scripts carry a `KEEP IN SYNC` comment pointing at each
> other. The fingerprint deliberately uses `elixir --short-version` (answered by
> the shell wrapper, no VM boot) and `erlang:system_info(version)` (pure ERTS
> version) rather than the `erl` banner line, which embeds machine details like
> CPU count and would false-positive a rebuild after a server move.

### Crash diagnostics: preserving VM evidence

When the BEAM exits abnormally, useful evidence may be written to stderr or an
Erlang crash dump. `run.sh` preserves both under `/home/protected/diagnostics/`:

- `beam-stderr.log` captures the release process's stderr.
- `erl_crash.dump` is written when ERTS can produce a crash dump.

Some forced terminations — especially an external `SIGKILL` — may leave neither.
The `VmStatsLogger` heartbeat provides a lightweight last-known snapshot of the
VM even when no crash dump is produced.

## Repository Structure

```
server/
  setup.sh              ← one-time directory setup (run via SSH)
  build.sh              ← compile + release + symlink (runs on server)
  run.sh.example        ← daemon entry point template (copy + fill in secrets)

scripts/
  create-release.sh     ← build a source tarball (runs locally)
  push.sh               ← upload + build + deploy + availability check (runs locally)

elixir/
  shutdown_watcher.ex   ← detects shutdown file, stops the app gracefully
  vm_stats_logger.ex    ← logs a VM health snapshot every 5 minutes
  background_tasks.ex   ← periodic task scheduler (runs the two modules above)
```

### Directory layout on the server

```
/home/protected/
├── run.sh                  ← daemon script (env vars, environment check, exec)
├── build.sh                ← build script
├── workspace/              ← persistent build directory
│   ├── config/ lib/ priv/ mix.exs mix.lock
│   ├── _build/             ← persists between builds
│   └── deps/               ← persists so deps aren't re-fetched
├── diagnostics/
│   ├── beam-stderr.log     ← stderr from the release process
│   └── erl_crash.dump      ← Erlang crash dump, when one is produced
└── releases/
    ├── myapp-20260403-abc1234/
    │   └── BUILD_ENV       ← eg "Elixir 1.17.3 | erts-14.2.5"
    ├── myapp-20260404-def5678/
    └── current-release -> myapp-20260404-def5678/
```

## Setup

### 1. Run the setup script on your server

```sh
ssh YOUR_NFS_SSH 'sh -s' < server/setup.sh
```

When upgrading an existing installation, run `setup.sh` again before replacing
`run.sh`; it creates the diagnostics directory and files used by the new script.

### 2. Copy the server scripts

```sh
scp server/build.sh YOUR_NFS_SSH:/home/protected/
ssh YOUR_NFS_SSH 'chmod +x /home/protected/build.sh'
```

### 3. Create the daemon run script

Copy `server/run.sh.example` to the server as `run.sh` and fill in your secrets:

```sh
scp server/run.sh.example YOUR_NFS_SSH:/home/protected/run.sh
ssh YOUR_NFS_SSH 'chmod +x /home/protected/run.sh'
```

This file contains secrets — do **not** commit it to version control.

### 4. Edit the scripts for your project

Set `APP_NAME` in `server/build.sh` and `scripts/push.sh`. Set `NFS_SSH` in
`scripts/push.sh`. Optionally set `HEALTH_URL` in `scripts/push.sh` to check
that the app returns a successful HTTP response after a deploy.

### 5. Add the Elixir modules to your project

Copy `elixir/shutdown_watcher.ex`, `elixir/vm_stats_logger.ex`, and
`elixir/background_tasks.ex` into your `lib/` directory. Rename the `MyApp`
module prefix to match your app.

Add to your supervision tree in `application.ex`:

```elixir
children = [
  # ... your other children
  {Task.Supervisor, name: MyApp.TaskSupervisor},
  MyApp.BackgroundTasks
]
```

Update `@shutdown_file` in `shutdown_watcher.ex` to match `SHUTDOWN_FILE` in `push.sh`.

### 6. Configure `mix.exs`

Make sure the `project` function in your `mix.exs` defines a release that looks
like this (with `myapp` renamed to your app):

```elixir
def project do
  [
    app: :myapp,
    # ... your other project settings ...
    releases: [
      myapp: [
        include_erts: true
      ]
    ]
  ]
end
```

`include_erts: true` is technically the default, but we set it explicitly because
it is what makes this whole setup survive NFS realm updates: each release bundles
its own copy of the Erlang runtime, so a realm update can't break a running app.
If it were `false`, every realm update would take your app down until a rebuild.

### 7. Register the daemon in the NFS control panel

- **Daemons → Add:** Command `/home/protected/run.sh`, run as `web`
- **Proxies → Add:** Protocol `HTTP`, base path `/`, port matching `PORT` in `run.sh`

### 8. Deploy

```sh
./scripts/create-release.sh
./scripts/push.sh
```

## Day-to-Day Usage

### Deploy

```sh
./scripts/create-release.sh
./scripts/push.sh
```

### Deploy a specific release (rollback)

```sh
./scripts/push.sh myapp-20260403163237-abc1234
```

### Manual rollback via SSH

```sh
ls -lt /home/protected/releases/
ln -sfn /home/protected/releases/myapp-PREVIOUS /home/protected/releases/current-release
touch /tmp/MY_APP_SHUTDOWN
```

Rollback only works within the same build environment. After a realm update, old
incompatible releases are automatically removed.

### View logs

```sh
ssh YOUR_NFS_SSH 'tail -f /home/logs/daemon_YOURTAG.log'

# BEAM stderr and Erlang crash dump
ssh YOUR_NFS_SSH 'tail /home/protected/diagnostics/beam-stderr.log'
ssh YOUR_NFS_SSH 'head -20 /home/protected/diagnostics/erl_crash.dump'
```

### Frontend assets

If your project has frontend assets, build them locally before `create-release.sh`.
The commented-out lines in the script show one approach. If you have no frontend, ignore
this.

## Safety Features

**Build lock.** `build.sh` uses a PID-based lockfile to prevent concurrent builds
(eg if NFS restarts the daemon while a deploy build is running).

**Checksum verification.** `create-release.sh` generates a SHA-256 checksum alongside
the tarball. `build.sh` verifies it before extracting, catching truncated or corrupt
uploads.

**Release validation.** After compiling, `build.sh` checks that the release binary
exists and is executable before updating the `current-release` symlink.

**Build failure handling.** If the incremental build fails, `build.sh` wipes `deps/`
and `_build/` and retries once from clean. If that also fails during an auto-rebuild,
`run.sh` exits with a clear error. NFS retries the daemon, which retries the build.

**Crash diagnostics.** `run.sh` sets `ERL_CRASH_DUMP` and captures BEAM stderr
under `/home/protected/diagnostics/`. These files preserve useful evidence when
ERTS has an opportunity to write it; a forced kill may leave no final output.

**VM heartbeat.** `VmStatsLogger` writes a one-line health snapshot (memory
breakdown, process count, uptime) every 5 minutes, so if the daemon dies you have
a last-known-state — and `uptime_min` resetting reveals restarts you didn't know
about.

**Post-deploy availability check.** If `HEALTH_URL` is set, `push.sh` makes up
to `HEALTH_ATTEMPTS` requests and exits non-zero unless the URL returns a 2xx
response. This confirms availability, not the identity of the running release.

**Automatic pruning.** Old releases built against a different Erlang environment are
removed (they can't run). Recent compatible releases are kept for rollback (default: 4).

## Permissions

NFS runs daemons as `web`. When you SSH in, you're a different user. `setup.sh`
creates the workspace, release, and diagnostics directories with access for both
users; `build.sh` uses `umask 000` for shared build artifacts. Everything lives inside
`/home/protected/`, which is not web-accessible.

If you hit permission errors on existing files, delete and rebuild:

```sh
rm -rf /home/protected/workspace/_build
rm -rf /home/protected/workspace/deps
rm -rf /home/protected/releases/*
```

## Configuration Reference

| Setting | Where | Description |
|---------|-------|-------------|
| `APP_NAME` | `build.sh`, `push.sh` | Your Mix project name |
| `NFS_SSH` | `push.sh` | Your NFS SSH login |
| `SHUTDOWN_FILE` | `push.sh`, `shutdown_watcher.ex` | Path to shutdown sentinel file |
| `SHUTDOWN_WAIT` | `push.sh` | Seconds to wait for graceful shutdown (default: 10) |
| `HEALTH_URL` | `push.sh` | Post-deploy availability URL (empty = skip) |
| `HEALTH_ATTEMPTS` | `push.sh` | Maximum availability requests, with a 2s pause between failures (default: 30) |
| `RELEASES_TO_KEEP` | `build.sh` | Old releases kept for rollback (default: 4) |
| Env vars | `run.sh` (on server) | `SECRET_KEY_BASE`, `DATABASE_URL`, `PORT`, etc. |

## FAQ

**Why build on the server?** NFS runs FreeBSD. Cross-compiling Erlang releases for
FreeBSD from macOS is fragile at best. Building on the server also means realm updates
can be fixed with a recompile.

**How long does a build take?** ~2-3 minutes. `deps/` persists in the workspace so
dependencies aren't re-fetched each time.

**What if the build fails?** `build.sh` retries once from a clean slate (wiping
`deps/` and `_build/`) automatically. If it still fails, SSH in and run it manually
to see full output: `cd /home/protected/workspace && MIX_ENV=prod /home/protected/build.sh`

**My daemon keeps dying with nothing in the app log. Now what?** Check
`/home/protected/diagnostics/beam-stderr.log`,
`/home/protected/diagnostics/erl_crash.dump`, and the last `[VmStats]` entries in
the daemon log. These may show the VM's last known state or an ERTS error. Some
forced terminations can occur without producing a crash dump or final stderr.

**Can I get advance notice of realm updates?** NFS doesn't offer this. You can elect
"late" realm updates in the control panel to trigger them on your schedule (must update
at least once a quarter).

**What about NIFs?** The clean-slate retry in `build.sh` handles the common case
(precompiled NIF binaries broken by a realm update) automatically. If a NIF fails
even from a clean build, investigate via SSH.

**Why the shutdown file instead of the release `stop` command?** The `stop` command
relies on Erlang's distribution system (epmd, node names, cookies). The sentinel file
has zero dependencies.

## License
 
This project is released under [CC0] — no rights reserved.

You are free to use, copy, modify, and distribute everything here for any purpose,
including copying the scripts and Elixir modules directly into your own projects.
No attribution required. Also there is no warranty 😉

[CC0]:https://creativecommons.org/publicdomain/zero/1.0/
