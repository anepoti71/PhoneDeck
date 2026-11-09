#!/usr/bin/env bash
# Assembles build/PMD3Bar.app: release Swift binary + Info.plist + embedded Python, ad-hoc signed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/PMD3Bar.app"
PYDIR="$BUILD/python"

if [[ ! -x "$PYDIR/bin/python3" ]]; then
    echo "Manca build/python: esegui prima 'make python'." >&2
    exit 1
fi

echo "==> swift build (release)"
cd "$ROOT"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/PMD3Bar"

# A running copy of this bundle would lose its Python mid-run (ModuleNotFoundError): quit it first.
if pgrep -f "$APP/Contents/MacOS/PMD3Bar" >/dev/null; then
    echo "==> Chiudo PMD3Bar in esecuzione"
    pkill -INT -f "$APP/Contents/MacOS/PMD3Bar" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$APP/Contents/MacOS/PMD3Bar" >/dev/null || break; sleep 0.5; done
fi
# serve-web started by that copy would keep its port busy: stop its Python processes too.
pkill -INT -f "$APP/Contents/Resources/python/bin/python3" 2>/dev/null || true

echo "==> Assemblo $APP"
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PMD3Bar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/pmd3bar_helper.py" "$APP/Contents/Resources/pmd3bar_helper.py"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# -a keeps symlinks (python3 -> python3.12) and permissions
cp -a "$PYDIR" "$APP/Contents/Resources/python"

echo "==> Firma ad-hoc"
# Sign every Mach-O inside the embedded Python first, then the app itself.
find "$APP/Contents/Resources/python" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q 'Mach-O'; then
            codesign --force --sign - --timestamp=none "$f"
        fi
    done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP" && echo "Firma OK"

# Let Finder, Dock and notifications pick up the current icon instead of a cached one.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

du -sh "$APP"
echo "Pronto: $APP"
