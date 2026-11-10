#!/usr/bin/env bash
# Writes scripts/pymobiledevice3.lock: pymobiledevice3 <version> and every dependency it pulls in,
# each pinned to an exact version with the sha256 of its wheels, for CPython 3.12 on macOS arm64.
# fetch-python.sh installs only from this file (--require-hashes, wheels only). Needs uv.
#
# Usage: scripts/lock-python.sh <pymobiledevice3 version>     (or: PMD3_VERSION=<v> make lock)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Usage: $0 <pymobiledevice3 version>}"
LOCK="$ROOT/scripts/pymobiledevice3.lock"
command -v uv >/dev/null || { echo "uv is needed: brew install uv" >&2; exit 1; }

TMP="$(mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT
echo "pymobiledevice3==$VERSION" > "$TMP/requirements.in"
uv pip compile "$TMP/requirements.in" --python-version 3.12 --python-platform aarch64-apple-darwin \
    --generate-hashes --only-binary :all: --no-header --no-annotate -o "$TMP/lock.txt"
{
    echo "# pymobiledevice3 and every dependency, pinned with hashes: CPython 3.12, macOS arm64, wheels only."
    echo "# Installed by scripts/fetch-python.sh with --require-hashes. Regenerate with:"
    echo "#   PMD3_VERSION=<version> make lock"
    cat "$TMP/lock.txt"
} > "$LOCK"
echo "Wrote $LOCK (pymobiledevice3 $VERSION, $(grep -c '==' "$LOCK") packages)."
echo "Review the diff, then: make python && make install"
