.PHONY: dev python app run install clean check check-static icon

# Run from source, using $PMD3_PYTHON or ~/miniforge3/envs/pymobiledevice as the Python.
dev:
	swift run PMD3Bar

# Download the pinned CPython and install pymobiledevice3 into build/python.
python:
	./scripts/fetch-python.sh

# Build build/PMD3Bar.app (needs `make python` once).
app:
	./scripts/build-app.sh

run: app
	open build/PMD3Bar.app

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
	@echo "Installata in ~/Applications/PMD3Bar.app"

clean:
	/bin/rm -rf build/PMD3Bar.app .build
