#!/bin/bash
set -e

# create-release.sh — Build a source tarball for deployment to NearlyFreeSpeech
#
# This runs on your local machine. It:
#   1. Builds frontend assets (if applicable)
#   2. Creates a source tarball with everything needed to compile on the server
#   3. Writes the release name to _releases/LATEST for use by push.sh
#
# The tarball does NOT include _build/ or deps/ — those persist on the server
# for faster incremental builds.
#
# Usage:
#   ./scripts/create-release.sh

# ── Configuration ─────────────────────────────────────────────────────────────
# Change APP_NAME to match your Mix project name.

APP_NAME="myapp"

TIMESTAMP=$(date +%Y%m%d%H%M%S)
GIT_SHA=$(git rev-parse --short HEAD)
RELEASE_NAME="${APP_NAME}-${TIMESTAMP}-${GIT_SHA}"

mkdir -p _releases

# ── Build frontend assets (optional) ─────────────────────────────────────────
# Uncomment and adjust these lines if your project has frontend assets.
# The goal is to have compiled assets in priv/static/ before creating the tarball.

# echo "==> Installing JS dependencies ..."
# npm install --silent
# echo "==> Building frontend assets ..."
# MIX_ENV=prod mix assets.deploy

# ── Create source tarball ─────────────────────────────────────────────────────

echo "==> Creating source tarball ..."
echo "$RELEASE_NAME" > priv/release-id

tar -czf "_releases/${RELEASE_NAME}.tar.gz" \
  config \
  lib \
  priv \
  mix.exs \
  mix.lock

echo "$RELEASE_NAME" > _releases/LATEST

# ── Clean up old tarballs (keep 5) ───────────────────────────────────────────

ls -1t _releases/*.tar.gz 2>/dev/null | tail -n +6 | xargs rm -f || true

echo ""
echo "==> Done: _releases/${RELEASE_NAME}.tar.gz"