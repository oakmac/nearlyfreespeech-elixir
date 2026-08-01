#!/bin/sh
set -e

# setup.sh — One-time setup for Elixir hosting on NearlyFreeSpeech
#
# Run this once via SSH on your NFS server to create the required directories.
#
# Usage:
#   ssh YOUR_NFS_SSH 'sh -s' < setup.sh

echo "Creating directories …"
mkdir -p /home/protected/workspace
mkdir -p /home/protected/releases
mkdir -p /home/protected/diagnostics

# The SSH user builds and deploys; the daemon runs as web. These directories
# live under /home/protected (not web-accessible), so both users need access.
chmod 777 /home/protected/workspace
chmod 777 /home/protected/releases
chmod 777 /home/protected/diagnostics

# Pre-create the diagnostic files so both the SSH user and web daemon can
# inspect or replace them later.
touch /home/protected/diagnostics/beam-stderr.log
touch /home/protected/diagnostics/erl_crash.dump
chmod 666 /home/protected/diagnostics/beam-stderr.log
chmod 666 /home/protected/diagnostics/erl_crash.dump

echo ""
echo "Done. Directory layout:"
echo ""
echo "  /home/protected/"
echo "  ├── workspace/    ← persistent build directory (source, _build, deps)"
echo "  ├── releases/     ← installed releases + current-release symlink"
echo "  ├── diagnostics/  ← BEAM stderr and Erlang crash dump"
echo "  ├── run.sh        ← NFS daemon script (you create this, contains secrets)"
echo "  └── build.sh      ← build script (copy from repo)"
echo ""
echo "Next steps:"
echo "  1. Copy build.sh to /home/protected/"
echo "  2. Create run.sh with your env vars (see run.sh.example)"
echo "  3. Push your first release"
echo "  4. Register the daemon in the NFS control panel"
