#!/usr/bin/env bash
# Builds the Python runtime that ships inside PhoneDeck.app:
# a relocatable CPython (astral-sh/python-build-standalone) with pymobiledevice3 installed into it.
#
# Safe update: everything is installed into build/python.new and verified with scripts/check.py.
# Only if the check passes does it replace build/python; the previous one is kept in
# build/python.prev (`make python-rollback` puts it back). If the check fails, build/python is
# left untouched and build/python.new stays there for inspection.
#
# Output: build/python   (copied into PhoneDeck.app/Contents/Resources/python by build-app.sh)
#
# Overrides:
#   PMD3_VERSION=11.50.3   pymobiledevice3 version from PyPI
#   PMD3_SPEC="git+https://github.com/doronz88/pymobiledevice3.git@master"   any pip requirement instead
#   CHECK_DEVICE=1         also run the device checks (an iPhone must be connected)
#   FORCE=1                install even if the check fails
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DOWNLOADS="$BUILD/downloads"
PYDIR="$BUILD/python"
NEWDIR="$BUILD/python.new"
PREVDIR="$BUILD/python.prev"

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

echo "==> Estraggo in build/python.new"
/bin/rm -rf "$NEWDIR"
EXTRACT="$(mktemp -d "$BUILD/extract.XXXXXX")"
tar -xzf "$ARCHIVE" -C "$EXTRACT"
mv "$EXTRACT/python" "$NEWDIR"
/bin/rmdir "$EXTRACT"

PY="$NEWDIR/bin/python3"
echo "==> Installo $PMD3_SPEC"
PYTHONNOUSERSITE=1 "$PY" -I -m pip install --disable-pip-version-check --no-warn-script-location \
    --upgrade "$PMD3_SPEC"

echo "==> Pulizia e precompilazione"
# Drop what the app never uses, then precompile so the signed bundle never needs to write .pyc files.
/bin/rm -rf "$NEWDIR"/lib/python3.12/test "$NEWDIR"/lib/python3.12/idlelib "$NEWDIR"/lib/python3.12/tkinter \
    "$NEWDIR"/lib/python3.12/turtledemo "$NEWDIR"/lib/tcl* "$NEWDIR"/lib/tk* "$NEWDIR"/lib/itcl* "$NEWDIR"/lib/thread* \
    "$NEWDIR"/share
find "$NEWDIR" -name '__pycache__' -type d -prune -exec /bin/rm -rf {} +
"$PY" -I -m compileall -q -j 0 "$NEWDIR/lib/python3.12" >/dev/null || true

echo "==> Verifica della nuova versione"
CHECK_ARGS=(--no-device)
[[ "${CHECK_DEVICE:-0}" == "1" ]] && CHECK_ARGS=()
if ! "$PY" -I "$ROOT/scripts/check.py" "${CHECK_ARGS[@]}"; then
    if [[ "${FORCE:-0}" != "1" ]]; then
        echo >&2
        echo "Verifica fallita: build/python NON è stato toccato (l'app resta com'era)." >&2
        echo "La nuova versione è in build/python.new per indagare; FORCE=1 per installarla comunque." >&2
        exit 1
    fi
    echo "FORCE=1: installo nonostante la verifica fallita." >&2
fi

echo "==> Sostituisco build/python (la precedente resta in build/python.prev)"
/bin/rm -rf "$PREVDIR"
[[ -d "$PYDIR" ]] && mv "$PYDIR" "$PREVDIR"
mv "$NEWDIR" "$PYDIR"

PYTHONNOUSERSITE=1 "$PYDIR/bin/python3" -I -m pymobiledevice3 version
du -sh "$PYDIR"
echo "Fatto. Ora 'make install' per aggiornare l'app."
