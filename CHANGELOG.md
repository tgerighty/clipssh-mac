# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- The app now shrinks an oversized clipboard image before it sends it. It caps
  the long edge at 1568 pixels and flattens 16-bit colour to 8-bit, then halves
  the image again if the result still exceeds 3.5 MB, down to a 196-pixel
  floor. While the redraws succeed the budget is always reached first, so the
  floor only guards the loop; if every redraw fails down to the floor, the app
  sends nothing rather than fall back to the oversized original. PNG data taken
  straight from the pasteboard passes through byte for byte when it is already
  8-bit, within the cap and within the budget, which an ordinary screenshot is.
  TIFF-only pasteboard data is converted to PNG first, so it is always
  re-encoded.

  Both numbers are the app's own limits, not a protocol requirement: it uploads
  to any SSH host and cannot know what reads the file there. They come from the
  case that prompted the feature. Before this, the app sent the pasteboard image
  as-is, so a 24-megapixel 16-bit photo arrived as a 69 MB PNG that the reader
  on the far end could not use — Claude Code caps an image at 5 MB of base64,
  about 3.75 MB of actual bytes, and models commonly downscale to a 1568-pixel
  long edge, so pixels above that cost upload time and usually add no detail.
  Other readers allow more. The same 69 MB file now sends as 2.3 MB.

## [0.1.5] - 2026-08-10

### Added

- Real end-to-end UI tests. The suite previously held only an assertion-free
  discovery probe. It now verifies that the status item appears, that no window
  opens at launch, that a right-click opens the menu, that a left-click with no
  target configured opens the Targets window, and that adding a target persists
  it as the default. Local-only via `make uitest`: GitHub runners have no
  window server.

### Fixed

- `make uitest` now terminates a running instance and waits for it to exit.
  XCUITest launches the app itself, so an already-running copy made every test
  fail on its launch timeout.
- Removed `.accessibilityIdentifier` and `.accessibilityLabel` from the
  add/remove buttons. Neither propagates through `Button { Image }` on macOS —
  verified at runtime — so declaring them only misled readers. macOS derives
  the labels from the SF Symbol.

### Documentation

- Documented that a menu bar manager (Bartender, Ice, Hidden Bar) can park the
  status item off-screen, where it cannot be clicked, and that the global
  hotkey works regardless.

## [0.1.4] - 2026-08-10

### Fixed

- `brew install` failed with `sandbox-exec: sandbox_apply: Operation not
  permitted` and an invalid manifest. Homebrew runs the install inside
  `sandbox-exec`, and Swift Package Manager then tried to sandbox its own
  manifest evaluation inside that; macOS refuses the nested sandbox. The
  Makefile now accepts a `SWIFTFLAGS` passthrough so the formula can pass
  `--disable-sandbox`. Local builds keep the sandbox.

## [0.1.3] - 2026-08-10

### Changed

- Resolved SwiftLint findings surfaced by the code-quality gate: split
  `ProcessRunner.run` into focused helpers (no behaviour change; the stdin,
  SIGPIPE, bounded-drain and process-group-kill invariants are preserved and
  were independently reviewed), split three oversized files by responsibility,
  and replaced `MenuModel.build`'s parameter list with an input struct. No
  functional change.

### Fixed

- IPv6 destinations now actually connect. The bracketed form
  (`[::1]`, `user@[2001:db8::1]`) is still required in the stored/validated
  destination to keep the grammar unambiguous, but the brackets are now
  stripped before the value is handed to `ssh`, which rejects the bracketed
  form as an unresolvable hostname.
- The upload watchdog now also bounds draining `ssh`'s stderr pipe after the
  child exits. Previously, a descendant process that inherited the pipe's
  write end (e.g. a backgrounded remote process) could keep the read open
  indefinitely, hanging the app in the "sending" state.
- A connection failure with empty `ssh` stderr (e.g. `LogLevel QUIET` in the
  user's `~/.ssh/config`) now shows "SSH connection failed" instead of a
  blank error.
- A failed config save (e.g. an immutable config file) no longer leaves a
  `clipssh-mac.json.tmp-<UUID>` staging file behind in the config directory.

## [0.1.2] - 2026-08-09

### Security

- Destination validation is now a strict allowlist (`[user@]host`, where
  `host` is `[A-Za-z0-9._-]+` or a bracketed IPv6 literal) instead of a
  blocklist. The previous blocklist rejected only empty, leading-`-`, and
  whitespace destinations, so a value containing `%h`/`%r` could still reach
  `ssh` and expand into `ProxyCommand`/`LocalCommand`/`Match exec` in the
  user's own `~/.ssh/config`, running an arbitrary local command. `--` is
  kept before the destination as defence in depth.
- Every SSH invocation now also forces `-T`, `-o StdinNull=no`,
  `-o ForkAfterAuthentication=no`, `-o RemoteCommand=none`, and
  `-o SessionType=default`, so settings in the user's own `~/.ssh/config`
  (`StdinNull yes`, `RequestTTY force`, a configured `RemoteCommand`, or
  `SessionType none`) can no longer produce an empty or corrupted upload
  while the app still reports success.
- A failed attempt to tighten a loose config file's permissions to `0600` is
  now shown in the menu instead of only being recorded internally.
- A config file with a schema version newer than this build understands is
  now rejected and left on disk untouched, instead of being silently
  re-saved without the fields this build does not know about.

### Fixed

- The app bundle produced by `make app` is now ad-hoc signed, so
  `codesign --verify --deep --strict` passes. CI checks this on every build.

### Changed

- `swift-tools-version` is 5.9 rather than 5.10. 5.10 first ships in Xcode
  15.3, which requires macOS 14, contradicting the stated macOS 13 support.
  See the README for the resulting build vs. test toolchain requirements.

### Removed

- `assets/*.png`, unused generated images (about 3 MB) carrying AI-generation
  metadata, and `docs/superpowers/`, stale internal planning documents that
  contradicted shipped behaviour.

## [0.1.1] - 2026-08-09

### Security

- Removed the inherited `clipssh` bash CLI and `install.sh`. The script
  interpolated `CLIPSSH_REMOTE_DIR` into a remote shell command without
  quoting, which allowed remote command injection. The installer also
  downloaded from a different repository. Users who want the command-line
  tool should get it from https://github.com/samuellawrentz/clipssh.
- An SSH destination that begins with `-` is now rejected. Such a value was
  passed to `ssh` as an option, and one like `-oProxyCommand=...` caused
  arbitrary local command execution. `--` is also passed before the
  destination.
- `StrictHostKeyChecking=yes` is now forced on every connection. The app
  previously inherited this from `~/.ssh/config`, so a user setting of `no`
  or `accept-new` silently defeated the documented guarantee that an unknown
  host is never trusted automatically.
- A config file found with permissions looser than `0600` is tightened when
  it is read, not only when it is written.
- Remote `stderr` is capped at 64 KB while the pipe is still drained, so a
  hostile or broken server cannot exhaust memory.

### Fixed

- Target-list changes are now a single atomic read-modify-write, so
  concurrent changes cannot lose an update.
- The error icon renders red. It was a template image, so the menu bar
  discarded the tint and drew it in the normal colour, making failures
  invisible.
- A saved hotkey that cannot be registered at launch is reported in the
  Targets window instead of only being logged.
- Reopening the Targets window commits pending text edits before refreshing,
  so uncommitted changes are no longer discarded.

### Changed

- The Swift tools version is 5.10 rather than 6.0. The 6.0 requirement
  implied Xcode 16, which needs macOS 14.5, contradicting the stated macOS 13
  support.

### Removed

- `clipssh` and `install.sh`, the inherited command-line script and its
  installer. `clipssh` let a crafted destination run arbitrary commands on
  the SSH host, and `install.sh` downloaded from the upstream repository
  rather than this one. The original CLI is not part of this project; see
  the README for a link to it.

### Security

- Reject an SSH destination that is empty, begins with `-`, or contains
  whitespace or a NUL, in both the uploader and the Targets window. Without
  this, a destination such as `-oProxyCommand=touch /tmp/pwned` was parsed
  by `ssh` as an option and could run an arbitrary local command.
- Make each target-list mutation (`addTarget`, `setDefault`, `removeTarget`,
  `updateTarget`, `setHotkey`) a single atomic read-modify-write, so
  concurrent mutations can no longer silently lose one another.

## [0.1.0] - 2026-08-09

### Added

- `clipssh-mac`, a macOS menu bar app. A left-click sends the clipboard
  screenshot to the default target. A right-click opens the menu.
- Target management window (`Targets…`), with add, remove, edit, set
  default, and test connection.
- Target discovery from `~/.ssh/config`, with a note when an unsupported
  `Include` line hides some hosts.
- One optional global hotkey, sent to the default target.
- Launch at login, off by default.
- One-time import of the CLI's `~/.clipssh/aliases` file on first run.
- `CLIPSSH_MAC_CONFIG_DIR` environment variable, to override the config
  directory.
- README, changelog, and a second copyright line in `LICENSE` for this work.
