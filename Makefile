.PHONY: build test lifecycle-test app run clean

SWIFT_ENV = CLANG_MODULE_CACHE_PATH="$(CURDIR)/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$(CURDIR)/.build/ModuleCache"

build:
	$(SWIFT_ENV) swift build --disable-sandbox --scratch-path .build

test:
	$(SWIFT_ENV) swift test --disable-sandbox --scratch-path .build

lifecycle-test: build
	./Scripts/test-lifecycle.py

app:
	./Scripts/build-app.sh release

run: app
	open "$(CURDIR)/dist/OpenConnect Sandbox.app"

clean:
	swift package --disable-sandbox --scratch-path .build clean
