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

Your app keeps running through realm updates. If it does need to restart, it rebuilds
itself. No SSH required.

## Repository Structure

```
server/
  setup.sh              ← one-time directory setup (run via SSH)
  build.sh              ← compile + release + symlink (runs on server)
  run.sh.example        ← daemon entry point template (copy + fill in secrets)

scripts/
  create-release.sh     ← build a source tarball (runs locally)
  push.sh               ← upload + build + deploy (runs locally)

elixir/
  shutdown_watcher.ex   ← detects shutdown file, stops the app gracefully
  background_tasks.ex   ← periodic task scheduler (runs the shutdown watcher)
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
└── releases/
    ├── myapp-20260403-abc1234/
    │   └── BUILD_ENV       ← eg "Elixir 1.17.3 (...) | 14.2.5.15"
    ├── myapp-20260404-def5678/
    └── current-release -> myapp-20260404-def5678/
```

## Setup

### 1. Run the setup script on your server

```sh
ssh YOUR_NFS_SSH 'sh -s' < server/setup.sh
```

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
`scripts/push.sh`.

### 5. Add the Elixir modules to your project

Copy `elixir/shutdown_watcher.ex` and `elixir/background_tasks.ex` into your `lib/`
directory. Rename the `MyApp` module prefix to match your app.

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

Leave `include_erts: true` (the default) so each release bundles its own Erlang runtime:

```elixir
releases: [
  myapp: []
]
```

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

**Build failure handling.** If `build.sh` fails during an auto-rebuild, `run.sh` exits
with a clear error. NFS retries the daemon, which retries the build.

**Automatic pruning.** Old releases built against a different Erlang environment are
removed (they can't run). Recent compatible releases are kept for rollback (default: 4).

## Permissions

NFS runs daemons as `web`. When you SSH in, you're a different user. The scripts use
`umask 000` so both users can read/write the build and release directories.
Everything lives inside `/home/protected/` which is not web-accessible, so this is safe.

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
| `RELEASES_TO_KEEP` | `build.sh` | Old releases kept for rollback (default: 4) |
| Env vars | `run.sh` (on server) | `SECRET_KEY_BASE`, `DATABASE_URL`, `PORT`, etc. |

## FAQ

**Why build on the server?** NFS runs FreeBSD. Cross-compiling Erlang releases for
FreeBSD from macOS is fragile at best. Building on the server also means realm updates
can be fixed with a recompile.

**How long does a build take?** ~2-3 minutes. `deps/` persists in the workspace so
dependencies aren't re-fetched each time.

**What if the build fails?** `build.sh` exits on the first error (`set -e`). SSH in and
run it manually to see full output: `cd /home/protected/workspace && MIX_ENV=prod /home/protected/build.sh`

**Can I get advance notice of realm updates?** NFS doesn't offer this. You can elect
"late" realm updates in the control panel to trigger them on your schedule (must update
at least once a quarter).

**What about NIFs?** `mix compile --force` recompiles everything, including NIFs. If a
NIF uses precompiled binaries and fails, delete `deps/` and rebuild.

**Why the shutdown file instead of the release `stop` command?** The `stop` command
relies on Erlang's distribution system (epmd, node names, cookies). The sentinel file
has zero dependencies.

## License
 
This project is released under [CC0] — no rights reserved.

You are free to use, copy, modify, and distribute everything here for any purpose,
including copying the scripts and Elixir modules directly into your own projects.
No attribution required. Also there is no warranty 😉

[CC0]:https://creativecommons.org/publicdomain/zero/1.0/
