CONFIG ?= release
APP := clipssh-mac.app
BIN := ClipsshMac
# Extra flags for swift build. Homebrew runs the install inside sandbox-exec,
# and SwiftPM then tries to sandbox its own manifest evaluation inside that.
# macOS refuses the nested sandbox ("sandbox_apply: Operation not permitted"),
# so the manifest never compiles. The formula passes --disable-sandbox here.
# Local builds keep the sandbox by leaving this empty.
SWIFTFLAGS ?=
BINDIR = $(shell swift build -c $(CONFIG) $(SWIFTFLAGS) --show-bin-path)

.PHONY: build test app install clean release uitest

build:
	swift build -c $(CONFIG) $(SWIFTFLAGS)

test:
	swift test

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp $(BINDIR)/$(BIN) $(APP)/Contents/MacOS/$(BIN)
	# The binary SPM produces is already linker-signed on its own, but the
	# bundle around it is not: codesign --verify --deep --strict then fails
	# with "code has no resources but signature indicates they must be
	# present". Ad-hoc sign the assembled bundle as a whole so it verifies.
	# No Apple Developer account is needed for "-".
	codesign --force --sign - $(APP)

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "Installed to /Applications/$(APP)"

clean:
	rm -rf .build $(APP)

# UI tests are local only: GitHub Actions macOS runners have no GUI session.
# Requires: xcodegen installed, and Accessibility permission on first run.
# Depends on `app` (not `install`) so this never touches /Applications.
uitest: app
	# XCUITest launches the app itself. A copy already running (from `open`,
	# or left running after a previous session) makes launch() fail with
	# "does not have a process ID", and every test then burns its timeout.
	-@pkill -f 'clipssh-mac.app/Contents/MacOS/ClipsshMac' 2>/dev/null || true
	@# pkill returns once SIGTERM is sent, not once the process is gone. Wait for
	@# it to actually exit, or xcodebuild races a still-running instance and every
	@# test burns its launch timeout.
	@n=0; while pgrep -f 'clipssh-mac.app/Contents/MacOS/ClipsshMac' >/dev/null 2>&1; do \
		n=$$((n+1)); \
		if [ $$n -gt 50 ]; then \
			echo "ERROR: ClipsshMac is still running after 5s; kill it and retry" >&2; \
			exit 1; \
		fi; \
		sleep 0.1; \
	done
	cd UITests && xcodegen generate
	xcodebuild test \
		-project UITests/ClipsshMacUITests.xcodeproj \
		-scheme ClipsshMacUITests \
		-destination 'platform=macOS'

# Prints the Homebrew formula fields for a tagged release.
release:
	@test -n "$(VERSION)" || (echo "Usage: make release VERSION=x.y.z" && exit 1)
	@echo "url \"https://github.com/tgerighty/clipssh-mac/archive/refs/tags/v$(VERSION).tar.gz\""
	@archive=$$(mktemp) && trap 'rm -f "$$archive"' EXIT && \
		curl --fail --silent --show-error --location \
			--output "$$archive" \
			"https://github.com/tgerighty/clipssh-mac/archive/refs/tags/v$(VERSION).tar.gz" && \
		shasum -a 256 "$$archive" | awk '{print "sha256 \"" $$1 "\""}'
