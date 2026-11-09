#!/usr/bin/env bash
# Builds the Python runtime that ships inside PMD3Bar.app:
# a relocatable CPython (astral-sh/python-build-standalone) with pymobiledevice3 installed into it.
#
# Output: build/python   (copied into PMD3Bar.app/Contents/Resources/python by build-app.sh)
#
# Overrides:
#   PMD3_VERSION=11.50.3   pymobiledevice3 version from PyPI
#   PMD3_SPEC="git+https://github.com/doronz88/pymobiledevice3.git@master"   any pip requirement instead
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DOWNLOADS="$BUILD/downloads"
PYDIR="$BUILD/python"

# Pinned runtime: CPython 3.12.15, python-build-standalone release 20261020, Apple Silicon.
PBS_TAG="20261020"
PBS_FILE="cpython-3.12.15+${PBS_TAG}-aarch64-apple-darwin-install_only.tar.gz"
PBS_SHA256="921fc822416bbad146b026d2051dbfe08338ce4144ced64c56afd899a4351752"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE/+/%2B}"

PMD3_VERSION="${PMD3_VERSION:-11.50.3}"
PMD3_SPEC="${PMD3_SPEC:-pymobiledevice3==${PMD3_VERSION}}"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "Questo script scarica il Python per Apple Silicon (arm64); questo Mac è $(uname -m)." >&2
    exit 1
fi

mkdir -p "$DOWNLOADS"
ARCHIVE="$DOWNLOADS/$PBS_FILE"
if [[ ! -f "$ARCHIVE" ]]; then
    echo "==> Scarico $PBS_FILE"
    curl -fL --retry 3 -o "$ARCHIVE.part" "$PBS_URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi

echo "==> Verifico sha256"
echo "$PBS_SHA256  $ARCHIVE" | shasum -a 256 -c -

echo "==> Estraggo in build/python"
/bin/rm -rf "$PYDIR"
EXTRACT="$(mktemp -d "$BUILD/extract.XXXXXX")"
tar -xzf "$ARCHIVE" -C "$EXTRACT"
mv "$EXTRACT/python" "$PYDIR"
/bin/rmdir "$EXTRACT"

PY="$PYDIR/bin/python3"
echo "==> Installo $PMD3_SPEC"
PYTHONNOUSERSITE=1 "$PY" -I -m pip install --disable-pip-version-check --no-warn-script-location \
    --upgrade "$PMD3_SPEC"

echo "==> Pulizia e precompilazione"
# Drop what the app never uses, then precompile so the signed bundle never needs to write .pyc files.
/bin/rm -rf "$PYDIR"/lib/python3.12/test "$PYDIR"/lib/python3.12/idlelib "$PYDIR"/lib/python3.12/tkinter \
    "$PYDIR"/lib/python3.12/turtledemo "$PYDIR"/lib/tcl* "$PYDIR"/lib/tk* "$PYDIR"/lib/itcl* "$PYDIR"/lib/thread* \
    "$PYDIR"/share
find "$PYDIR" -name '__pycache__' -type d -prune -exec /bin/rm -rf {} +
"$PY" -I -m compileall -q -j 0 "$PYDIR/lib/python3.12" >/dev/null || true

echo "==> Verifica"
PYTHONNOUSERSITE=1 "$PY" -I -m pymobiledevice3 version
du -sh "$PYDIR"
