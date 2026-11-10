.PHONY: dev python python-rollback app release run install clean check check-static icon test

# Run from source, using $PMD3_PYTHON or ~/miniforge3/envs/pymobiledevice as the Python.
dev:
	swift run PMD3Bar

# Download the pinned CPython and install pymobiledevice3 into build/python.
python:
	./scripts/fetch-python.sh

# Put back the runtime that the last `make python` replaced (build/python.prev), and vice versa.
python-rollback:
	@test -d build/python.prev || { echo "No previous version in build/python.prev"; exit 1; }
	mv build/python build/python.swap && mv build/python.prev build/python && mv build/python.swap build/python.prev
	@build/python/bin/python3 -I -m pymobiledevice3 version
	@echo "Restored. Now 'make install' to update the app."

# Build build/PMD3Bar.app (needs `make python` once).
app:
	./scripts/build-app.sh

# Developer ID signature + notarization, packed as build/PMD3Bar-<version>.zip (see RUNBOOK).
# NOTARIZE=0 signs only; SIGN_IDENTITY / NOTARY_PROFILE pick the identity and the notarytool credentials.
release:
	./scripts/release.sh

run: app
	open build/PMD3Bar.app

# Unit tests of the pure logic in Sources/PMD3BarCore (no iPhone needed).
test:
	swift run -c release --arch arm64 PMD3BarCoreTests

# Verify the embedded pymobiledevice3 still provides what PMD3Bar uses (see RUNBOOK).
# With an iPhone connected it also tests it; CHECK_ARGS="--location" tests the simulated location too.
check:
	build/python/bin/python3 -I scripts/check.py $(CHECK_ARGS)

check-static:
	build/python/bin/python3 -I scripts/check.py --no-device

# Rebuild Resources/AppIcon.icns from Resources/AppIcon-source.png (see scripts/make-icon.py).
icon:
	build/python/bin/python3 -I scripts/make-icon.py

# Copy the app to ~/Applications.
install: app
	-pkill -INT -f "$(HOME)/Applications/PMD3Bar.app/Contents/MacOS/PMD3Bar"
	-pkill -INT -f "$(HOME)/Applications/PMD3Bar.app/Contents/Resources/python/bin/python3"
	mkdir -p "$(HOME)/Applications"
	/bin/rm -rf "$(HOME)/Applications/PMD3Bar.app"
	cp -a build/PMD3Bar.app "$(HOME)/Applications/PMD3Bar.app"
	-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(HOME)/Applications/PMD3Bar.app"
	@echo "Installed in ~/Applications/PMD3Bar.app"

clean:
	/bin/rm -rf build/PMD3Bar.app .build
