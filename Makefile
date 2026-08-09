CONFIG ?= release
APP := clipssh-mac.app
BIN := ClipsshMac
BINDIR = $(shell swift build -c $(CONFIG) --show-bin-path)

.PHONY: build test app install clean release uitest

build:
	swift build -c $(CONFIG)

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
