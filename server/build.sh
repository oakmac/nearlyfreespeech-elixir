#!/bin/sh
set -e
umask 000

# build.sh — Build an Elixir release from source on NearlyFreeSpeech
#
# Called automatically by run.sh when the build environment has changed.
# Can also be run manually via SSH for debugging.
#
# Usage:
#   ./build.sh                       # rebuild from existing source in workspace/
#   ./build.sh /path/to/foo.tar.gz   # extract tarball first, then build

export MIX_ENV=prod

# ── Configuration ─────────────────────────────────────────────────────────────
# Change these to match your project.

APP_NAME="myapp"
WORKSPACE="/home/protected/workspace"
RELEASES_DIR="/home/protected/releases"
RELEASES_TO_KEEP=4

# ── Build lock ────────────────────────────────────────────────────────────────
# Prevent concurrent builds (eg NFS restarts daemon during a deploy).

LOCKFILE="/home/protected/.build.lock"

if [ -f "$LOCKFILE" ]; then
  OLD_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ERROR: Another build is already running (PID $OLD_PID). Exiting."
    exit 1
  fi
  echo "Stale lock file found (PID $OLD_PID no longer running). Removing."
  rm -f "$LOCKFILE"
fi

echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# ── Optional: extract a tarball ───────────────────────────────────────────────

TARBALL="$1"

mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

if [ -n "$TARBALL" ]; then
  # Verify checksum if a .sha256 file exists alongside the tarball
  if [ -f "${TARBALL}.sha256" ]; then
    echo "Verifying checksum ..."
    EXPECTED=$(cat "${TARBALL}.sha256" | awk '{print $1}')
    ACTUAL=$(sha256sum "$TARBALL" 2>/dev/null || shasum -a 256 "$TARBALL")
    ACTUAL=$(echo "$ACTUAL" | awk '{print $1}')
    if [ "$EXPECTED" != "$ACTUAL" ]; then
      echo "ERROR: Checksum mismatch for $(basename "$TARBALL")"
      echo "  expected: $EXPECTED"
      echo "  actual:   $ACTUAL"
      rm -f "$TARBALL" "${TARBALL}.sha256"
      exit 1
    fi
    echo "Checksum OK."
    rm -f "${TARBALL}.sha256"
  fi

  echo "Extracting $(basename "$TARBALL") ..."
  tar -xzf "$TARBALL"
  rm -f "$TARBALL"
fi

if [ ! -f "mix.exs" ]; then
  echo "ERROR: No mix.exs found in $WORKSPACE. Nothing to build."
  exit 1
fi

# ── Build ─────────────────────────────────────────────────────────────────────

echo "Installing Hex and Rebar ..."
mix local.hex --force --quiet
mix local.rebar --force --quiet

echo "Fetching dependencies ..."
mix deps.get --only prod

echo "Compiling (--force) ..."
mix compile --force

echo "Building release ..."
rm -rf _build/prod/rel
mix release --overwrite

# ── Validate release ─────────────────────────────────────────────────────────

RELEASE_BIN="_build/prod/rel/${APP_NAME}/bin/${APP_NAME}"
if [ ! -x "$RELEASE_BIN" ]; then
  echo "ERROR: Release binary not found at $RELEASE_BIN. Build may have failed."
  exit 1
fi

# ── Install ───────────────────────────────────────────────────────────────────

RELEASE_ID=$(cat priv/release-id 2>/dev/null || echo "${APP_NAME}-$(date +%Y%m%d%H%M%S)")
RELEASE_PATH="${RELEASES_DIR}/${RELEASE_ID}"

echo "Installing release: ${RELEASE_ID}"
rm -rf "$RELEASE_PATH"
mkdir -p "$RELEASE_PATH"
cp -r "_build/prod/rel/${APP_NAME}/." "$RELEASE_PATH/"

# ── Record the build environment ─────────────────────────────────────────────
# run.sh compares this file against the current environment to detect changes.

ENV_FINGERPRINT=$(printf '%s | %s' \
  "$(elixir --version | grep Elixir | head -1)" \
  "$(erl -noshell -eval 'io:format(erlang:system_info(version))' -s init stop)")

echo "$ENV_FINGERPRINT" > "$RELEASE_PATH/BUILD_ENV"
echo "Build environment: $ENV_FINGERPRINT"

echo "Updating current-release symlink ..."
ln -sfn "$RELEASE_PATH" "${RELEASES_DIR}/current-release"

# ── Prune old releases ───────────────────────────────────────────────────────
# Remove releases built against a different environment (they won't work).
# Then keep the most recent $RELEASES_TO_KEEP compatible releases for rollback.

CURRENT_ENV=$(cat "${RELEASES_DIR}/current-release/BUILD_ENV" 2>/dev/null || echo "")

for dir in "${RELEASES_DIR}/${APP_NAME}-"*; do
  [ -d "$dir" ] || continue
  [ "$dir" = "$RELEASE_PATH" ] && continue
  OLD_ENV=$(cat "$dir/BUILD_ENV" 2>/dev/null || echo "unknown")
  if [ "$OLD_ENV" != "$CURRENT_ENV" ]; then
    echo "Removing incompatible release: $(basename "$dir")"
    rm -rf "$dir"
  fi
done

ls -1dt "${RELEASES_DIR}/${APP_NAME}-"* 2>/dev/null \
  | tail -n +$((RELEASES_TO_KEEP + 1)) \
  | xargs rm -rf || true

echo "Done. Release ${RELEASE_ID} is ready."