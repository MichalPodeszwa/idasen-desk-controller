# idasen-desk-controller

macOS menu-bar app for the IKEA IDÅSEN (LINAK) standing desk: live height, press-and-hold control, named positions, and an `idasen` command-line tool for automation.

> Pre-release: all features are implemented and tested against a simulated desk. Verification on the real desk is in progress, and no release has been published yet.

Requires macOS 27 or later on Apple Silicon, and a desk with Bluetooth (IKEA IDÅSEN).

## Install

Builds are self-signed (there is no Apple Developer account), so macOS asks for a few extra steps once.

1. Download `Idasen-<version>-macOS-arm64.zip` from the [GitHub Releases](../../releases) page and unzip it.
2. **Move `Idasen.app` to `/Applications` first.** An app started from `~/Downloads` runs translocated from a random read-only path, which breaks the command-line tool and launch at login.
3. Remove the download quarantine flag (this also covers the bundled `idasen` tool):
   ```bash
   xattr -dr com.apple.quarantine /Applications/Idasen.app
   ```
4. Open `Idasen`. It lives only in the menu bar, with no Dock icon.

Updating: quit the app, replace `/Applications/Idasen.app` with the new version and run the `xattr` command again. Releases are signed with one fixed certificate, so the Bluetooth permission should survive updates.

## First run and pairing

1. Put the desk in pairing mode **before** continuing: hold the Bluetooth button on the desk panel until its LED blinks.
2. Open the app and click Continue. macOS asks for Bluetooth access: allow it.
3. Pick your desk from the list (with several desks in range, the strongest signal is listed first). macOS may show a pairing dialog.
4. Once connected, the menu bar shows the desk height. From then on the app reconnects on its own, also after sleep, Bluetooth off/on and the desk going out of range. No pairing mode is needed again.

The desk accepts only **one** Bluetooth connection. If it does not show up, check that it is on, in range and not connected to another device (a phone with the LINAK app, for example).

## Troubleshooting

- **"Hold the Bluetooth button on the desk until it blinks"**: the desk is not bonded with this Mac yet. Put it in pairing mode and click Try Again.
- **"Remove the desk in System Settings → Bluetooth, then pair again"** (stale bond): after a desk reset the Mac still holds the old pairing, and an app cannot delete it. Remove the desk in System Settings → Bluetooth if it is listed, then in the popover choose Settings → Forget desk, put the desk in pairing mode and pick it again. Reset procedure for the desk itself: lower it fully, hold the down button until it jumps, then hold the Bluetooth button until the LED blinks. A reset may erase the presets stored on the desk's panel.
- **"Bluetooth access is denied"**: allow Idasen in System Settings → Privacy & Security → Bluetooth. To get the permission prompt again, quit the app and run `tccutil reset BluetoothAlways io.github.michalpodeszwa.idasen`.
- **"Desk not found" after ~15 s**: the desk is off, out of range or connected to another device.
- **`idasen: command not found`**: use Settings → Install command line tool, which links `~/.local/bin/idasen`, and make sure `~/.local/bin` is on your `PATH`. The tool is also at `/Applications/Idasen.app/Contents/Helpers/idasen`.
- **Something else**: capture a diagnostic log while you reproduce the problem and attach it to the issue: `log stream --level debug --predicate 'subsystem == "io.github.michalpodeszwa.idasen"' > idasen.log` (Ctrl-C to stop). Developers can use `make hw-log` (see below).

## Command line

The `idasen` tool talks to the running app, never to the desk directly (the desk allows one connection, and the app holds it). If the app is not running it is started for you. Heights are in centimetres, as shown in the app.

```bash
idasen status                      # connection state and height
idasen height                      # just the number, e.g. 92.4
idasen move 105.5                  # blocks until the desk has stopped; Ctrl-C stops the desk
idasen up 2                        # relative move, 1 cm by default
idasen positions save Stand --height 105
idasen move Stand                  # positions are addressed by name
idasen stop
idasen watch --json | jq .heightCm # live stream
```

Exit codes, `--json` output and all commands are in [docs/cli.md](docs/cli.md).

## Development

```bash
brew install xcodegen
make generate      # after any change to project.yml or added/removed files
make test          # unit tests, no hardware needed
make build         # Debug build into build/DerivedData.noindex (ad-hoc signed, hidden from Spotlight)
make lint          # swift format lint --strict;  make format fixes it
make test-scripts  # shell tests for scripts/
make e2e           # builds, runs the app against a simulated desk and drives it through the CLI
```

### Simulate mode: no desk needed

`IDASEN_SIMULATE=1` (or the `--simulate` launch argument) replaces Bluetooth with a physics-based desk simulator, shows a "SIMULATED" badge and keeps settings in memory. Always set `IDASEN_SUPPORT_DIR`, otherwise the app uses your real `positions.json` and control socket:

```bash
export IDASEN_SUPPORT_DIR="$(mktemp -d /tmp/idasen-sim.XXXXXX)"
IDASEN_SIMULATE=1 "$(make -s app-path)/Contents/MacOS/Idasen" &
"$(make -s app-path)/Contents/Helpers/idasen" --no-launch move 100
```

`make e2e` does exactly this in a temporary directory and checks the results.

### Diagnostic log and hardware testing

The app logs through `os.Logger` (subsystem = bundle ID, categories `ble`, `controller`, `ipc`, `app`). `make hw-log` captures it into `~/Desktop/idasen-hw-logs/idasen-<timestamp>.log` (stop with Ctrl-C; `HW_LOG_ARGS="/some/path.log"` sets the output, `scripts/hw-log.sh --help` has the rest). Start it before the session, because debug-level lines are not kept by macOS.

## Documentation

- [CLI](docs/cli.md): commands, exit codes and `--json` output
- [BLE protocol](docs/protocol.md): how the app talks to the desk

## Releasing

Push a `vMAJOR.MINOR.PATCH` tag (a suffix such as `-beta.1` makes it a pre-release) and `.github/workflows/release.yml` builds, signs and publishes the GitHub Release. The one-time certificate setup is `scripts/create-signing-cert.sh`; the workflow refuses to publish a build that isn't signed with the certificate pinned in `.github/signing-cert.sha1`.

Not affiliated with IKEA or LINAK.
