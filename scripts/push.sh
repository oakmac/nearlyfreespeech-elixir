#!/bin/bash
set -e

# push.sh — Deploy a release to NearlyFreeSpeech
#
# This runs on your local machine. It:
#   1. Uploads the source tarball to the server
#   2. SSHs in and calls build.sh (which compiles, installs, and symlinks)
#   3. Signals the running app to shut down (NFS restarts it automatically)
#
# Usage:
#   ./scripts/push.sh                              # push LATEST release
#   ./scripts/push.sh myapp-20260403163237-abc1234  # push a specific release

# ── Configuration ─────────────────────────────────────────────────────────────
# Change these to match your project and NFS site.

APP_NAME="myapp"
NFS_SSH="yourusername@ssh.nyc1.nearlyfreespeech.net"
WORKSPACE="/home/protected/workspace"

# Path to the shutdown sentinel file. Must match @shutdown_file in your
# Elixir ShutdownWatcher module.
SHUTDOWN_FILE="/tmp/MY_APP_SHUTDOWN"

# Seconds to wait after creating the shutdown file, giving the app time to
# notice it and stop gracefully before NFS restarts the daemon.
SHUTDOWN_WAIT=10

# ── Determine which release to push ──────────────────────────────────────────

RELEASE_ARG="$1"

if [ -n "$RELEASE_ARG" ]; then
  RELEASE_NAME="$RELEASE_ARG"
else
  if [ ! -f _releases/LATEST ]; then
    echo "Error: _releases/LATEST not found. Run ./scripts/create-release.sh first."
    exit 1
  fi
  RELEASE_NAME=$(cat _releases/LATEST)
fi

TARBALL="_releases/${RELEASE_NAME}.tar.gz"

if [ ! -f "$TARBALL" ]; then
  echo "Error: $TARBALL not found."
  exit 1
fi

echo "==> Pushing $RELEASE_NAME to $NFS_SSH ..."

# ── Upload ────────────────────────────────────────────────────────────────────

echo "==> Uploading source tarball ..."
scp "$TARBALL" "${NFS_SSH}:${WORKSPACE}/${RELEASE_NAME}.tar.gz"

# ── Build + deploy on server ──────────────────────────────────────────────────

echo "==> Building on server ..."
ssh "$NFS_SSH" \
  SHUTDOWN_FILE="$SHUTDOWN_FILE" \
  SHUTDOWN_WAIT="$SHUTDOWN_WAIT" \
  sh <<REMOTE
  set -e

  /home/protected/build.sh "${WORKSPACE}/${RELEASE_NAME}.tar.gz"

  echo "==> Creating shutdown file ..."
  touch "\$SHUTDOWN_FILE"
  sleep "\$SHUTDOWN_WAIT"

  echo "==> Done. Release ${RELEASE_NAME} is deployed."
REMOTE

echo ""
echo "==> Deployed. NFS will restart the app automatically."
echo "    Watch logs: ssh $NFS_SSH 'tail -f /home/logs/daemon_*.log'"