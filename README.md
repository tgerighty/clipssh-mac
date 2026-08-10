# clipssh-mac

A macOS menu bar app. It sends the screenshot on your clipboard to an SSH host.
It then copies the remote file path back to your clipboard.

Take a screenshot. Click the menu bar icon. Paste the path into your SSH
session.

This project derives from a command-line script of the same name. See
[Relation to clipssh](#relation-to-clipssh) below.

## Install

```bash
brew install tgerighty/tap/clipssh-mac
```

The formula builds from source. Homebrew therefore downloads no prebuilt app
bundle, so macOS applies no quarantine attribute and Gatekeeper does not
intervene. `make app` ad-hoc code-signs the built bundle (no Apple Developer
account needed) so `codesign --verify` accepts it, but the signature carries
no Apple Developer identity and the app is not notarized.

Homebrew installs the app into its own prefix. Link it into `/Applications`,
which `Launch at login` requires:

```bash
ln -sfn "$(brew --prefix clipssh-mac)/clipssh-mac.app" /Applications/clipssh-mac.app
open /Applications/clipssh-mac.app
```

Without Homebrew, build from source:

```bash
git clone https://github.com/tgerighty/clipssh-mac.git
cd clipssh-mac
make install
```

This builds the app with Swift Package Manager and copies it to
`/Applications/clipssh-mac.app`.

Three different floors apply here, each stricter than the last:

| | Needs |
|---|---|
| **Run** the app | macOS 13 or later |
| **Build** the app | Xcode 15 (or the matching Command Line Tools), on macOS 13.5 or later |
| **Run its test suite** (`swift test`) | Xcode 16 (Swift 6) — the test suites use `import Testing`, which no earlier Xcode bundles |

So a contributor on macOS 13.5 can build and run the app, but needs macOS 14
(for Xcode 16) to run the tests locally. A contributor on plain macOS 13
(below 13.5) can run the app but cannot build it. CI always runs the tests,
on a current macOS runner.

`make app` ad-hoc code-signs the built bundle (see [Install](#install)); it
is not notarized, and carries no Apple Developer identity.

## Use

| Action | Result |
|---|---|
| Left-click the icon | Send the clipboard image to the default target |
| Right-click the icon | Open the menu |
| Global hotkey (optional) | Send the clipboard image to the default target |

The menu shows the last result at the top. Selecting a target in the `Target`
submenu **sets the default**. It does not send.

The `Add from ~/.ssh/config` submenu lists hosts found in your SSH config that
are not already targets. Add a target from there, or add one directly in
`Targets…`.

On first run, with no targets configured, a left-click opens `Targets…`
instead of showing an error.

## Targets window

Open it from the menu (`Targets…`). For each target you set:

- **Label** — a name shown in the menu.
- **Destination** — `host` or `user@host`. A bare host name gets its
  `HostName`, `User`, and `IdentityFile` from `~/.ssh/config`.
- **Port** (optional) — an integer from 1 to 65535. An invalid entry is not
  saved; the previously stored port is kept.

The window also has:

- **Set as default** — makes the selected target the one a left-click or the
  hotkey sends to.
- **Test connection** — runs the same SSH command as a real upload, but with
  `true` instead of the file write, so you find a connection problem when you
  add the target, not when you need it.
- A **hotkey recorder** — sets the one optional global hotkey. It always
  sends to the default target. The app uses Carbon's `RegisterEventHotKey`,
  which does not require Accessibility permission.

## Configuration

Targets live in `~/.clipssh/clipssh-mac.json`, with file permissions `0600`.
Nothing is stored inside the app bundle.

Set `CLIPSSH_MAC_CONFIG_DIR` to use a different directory instead.

On first run, the app imports `~/.clipssh/aliases` if that file exists (see
[Relation to clipssh](#relation-to-clipssh)). It reads the file once and never
writes to it.

## How it works

The app reads PNG data from the system pasteboard (`NSPasteboard`) and pipes
it to `/usr/bin/ssh`:

```sh
/bin/sh -c 'umask 077; set -C; cat > "$1"' sh '/tmp/clipboard-<epoch-seconds>-<4 hex chars>.png'
```

Every connection uses `-o BatchMode=yes -o ConnectTimeout=8`, plus `-p <port>`
if you set one. `BatchMode=yes` turns a password prompt into an immediate
error, because a menu bar app has no terminal to type a password into. A
30-second watchdog stops the command if the connection hangs.

Using the system `ssh` command means `~/.ssh/config`, agent authentication,
and `ControlMaster` connection reuse all work without extra configuration.

`umask 077` gives the remote file mode `0600`, so the screenshot is not
readable by other users on a shared host. `set -C` (noclobber) makes the
write fail if a file or symlink already exists at that path, instead of
following it — `/tmp` is world-writable, so a plain `>` redirect could be
tricked into overwriting an attacker-readable location.

## Menu bar managers

A menu bar manager such as Bartender, Ice or Hidden Bar can park a hidden item
off-screen. The app still runs, but you cannot click the icon, so you cannot
send or see the error state. Either keep clipssh-mac visible in the menu bar,
or set a global hotkey in `Targets…` — the hotkey works whether or not the icon
is reachable.

## Notes and limits

- **The app writes to `/tmp` only.** The remote directory is not
  configurable.
- **The app never deletes a remote file.** On Linux, `systemd-tmpfiles`
  clears `/tmp` on its own schedule (10 days by default on many
  distributions).
- **`Include` in `~/.ssh/config` is not supported.** If the app finds an
  `Include` line, the discovery submenu shows a disabled note: "Some hosts
  hidden (Include not supported)".
- **The app cannot be sandboxed, and can never be on the Mac App Store.** It
  reads `~/.ssh/config` and runs `/usr/bin/ssh` directly; the App Sandbox
  forbids both.
- **The app never trusts an unknown host for you.** It always passes
  `StrictHostKeyChecking=yes`, overriding any looser setting in your own
  `~/.ssh/config`. If you have not connected to a host before, connect once
  in Terminal to accept its key first.
- Images only. Text and files on the clipboard are not sent.

## Testing

The core logic (`ClipsshCore`) has 129 unit tests, and the app layer
(`ClipsshMac`) has 24 more — 153 in total, all run with `swift test`. They
cover the SSH config parser, the target store, the uploader's error mapping
and destination validation, the remote command format, target-mutation
concurrency, and the Targets window's model. No test touches a real network
connection or a real pasteboard. CI runs `swift build`, `swift test`, and
`make app` on pushes to `main` and on pull requests.

`UITests/` holds the start of an XCUITest end-to-end suite, but there is
nothing to run yet: it contains a single discovery probe that prints the
accessibility tree and asserts nothing. It has never run successfully — it
needs Accessibility permission granted to the test runner and a logged-in GUI
session, neither of which CI provides.

CI does not cover everything, either: 10 of the 153 tests construct a real
`NSStatusItem` or `NSWindow`, which need the same window server the XCUITest
suite needs and GitHub's macOS runners do not have. They are gated with
`.enabled(if: hasWindowServer)`, which checks for the `CI` environment
variable GitHub Actions always sets, and show up as **skipped**, not failed,
in the CI log. Plain `swift test` on a developer machine has a real window
server and runs all 153.

## Relation to clipssh

This app derives from [clipssh](https://github.com/samuellawrentz/clipssh), a
bash command-line script by Samuel Lawrentz. That script is not part of this
project and is not shipped here. If you want the original CLI, get it from
its own repository: https://github.com/samuellawrentz/clipssh.

## Licence

MIT. See `LICENSE`. The licence keeps the original copyright notice from
Samuel Lawrentz, with a second notice added for this work.
