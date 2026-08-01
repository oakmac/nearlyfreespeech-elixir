#!/bin/bash
set -e

# push.sh — Deploy a release to NearlyFreeSpeech
#
# This runs on your local machine. It:
#   1. Uploads the source tarball and checksum to the server
#   2. SSHs in and calls build.sh (which verifies, compiles, installs, and symlinks)
#   3. Signals the running app to shut down (NFS restarts it automatically)
#   4. Optionally checks that the app returns a successful HTTP response
#
# Usage:
#   ./scripts/push.sh                              # push LATEST release
#   ./scripts/push.sh myapp-20260403163237-abc1234 # push a specific release

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

# Optional post-deploy availability check. Leave empty to skip. If set, push.sh
# makes up to HEALTH_ATTEMPTS requests, two seconds apart, and succeeds when the
# URL returns a 2xx response. This confirms availability, not the release ID.
HEALTH_URL=""             # eg "https://yourdomain.com/health"
HEALTH_ATTEMPTS=30

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
CHECKSUM="_releases/${RELEASE_NAME}.tar.gz.sha256"

if [ ! -f "$TARBALL" ]; then
  echo "Error: $TARBALL not found."
  exit 1
fi

echo "==> Pushing $RELEASE_NAME to $NFS_SSH …"

# ── Upload ────────────────────────────────────────────────────────────────────

echo "==> Uploading source tarball …"
scp "$TARBALL" "${NFS_SSH}:${WORKSPACE}/${RELEASE_NAME}.tar.gz"
if [ -f "$CHECKSUM" ]; then
  scp "$CHECKSUM" "${NFS_SSH}:${WORKSPACE}/${RELEASE_NAME}.tar.gz.sha256"
fi

# ── Build + deploy on server ──────────────────────────────────────────────────

echo "==> Building on server …"
ssh "$NFS_SSH" \
  SHUTDOWN_FILE="$SHUTDOWN_FILE" \
  SHUTDOWN_WAIT="$SHUTDOWN_WAIT" \
  sh <<REMOTE
  set -e
  /home/protected/build.sh "${WORKSPACE}/${RELEASE_NAME}.tar.gz"
  echo "==> Creating shutdown file …"
  touch "\$SHUTDOWN_FILE"
  sleep "\$SHUTDOWN_WAIT"
  echo "==> Release ${RELEASE_NAME} built; restart requested."
REMOTE

# ── Availability check (optional) ────────────────────────────────────────────

if [ -n "$HEALTH_URL" ]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: HEALTH_URL is set, but curl is not installed."
    exit 1
  fi

  echo "==> Checking app availability at $HEALTH_URL …"
  ATTEMPT=1
  AVAILABLE=false

  while [ "$ATTEMPT" -le "$HEALTH_ATTEMPTS" ]; do
    HTTP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL" || true)

    case "$HTTP_STATUS" in
      2??)
        AVAILABLE=true
        break
        ;;
    esac

    if [ "$ATTEMPT" -lt "$HEALTH_ATTEMPTS" ]; then
      sleep 2
    fi

    ATTEMPT=$((ATTEMPT + 1))
  done

  if [ "$AVAILABLE" != true ]; then
    echo ""
    echo "!!! WARNING: App did not return a 2xx response after $HEALTH_ATTEMPTS attempts."
    echo "    The deploy may have failed. Check the logs:"
    echo "    ssh $NFS_SSH 'tail -50 /home/logs/daemon_*.log /home/protected/diagnostics/beam-stderr.log'"
    exit 1
  fi

  echo "==> App returned HTTP $HTTP_STATUS on attempt $ATTEMPT."
fi

echo ""
echo "==> Deployed. NFS will restart the app automatically."
echo "    Watch logs: ssh $NFS_SSH 'tail -f /home/logs/daemon_*.log'"
