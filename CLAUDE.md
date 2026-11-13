# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

macOS menu-bar app (`Idasen`, bundle ID `io.github.michalpodeszwa.idasen`) that controls an IKEA IDÅSEN standing desk over Bluetooth LE. Features: live height display, live (press-and-hold) control, `n` named positions, and an `idasen` CLI for automation. Distributed only through GitHub Releases, self-signed (no Apple Developer account).

**Status: all code in place, untested on hardware.** Diagnostic logging and a hardware test kit are in place. The popover, settings, first-run flow and lifecycle hooks are wired; `--simulate` runs the app without Bluetooth. Public docs in `docs/`: `cli.md` (commands, exit codes, IPC wire format) and `protocol.md` (BLE UUIDs, raw units, DPG, move algorithm, hold variants; **⚠ verify** marks items unconfirmed on hardware).

The working specs live outside the repository, in `~/Projects/idasen-desk-controller-notes/` (local only, never committed, never quoted in public files). Read the relevant one before implementing and update it when a decision changes:

- `requirements.md`: scope, requirement IDs (F-x, N-x), reference projects
- `architecture.md`: ADRs, module layout, controller semantics, hold safety, persistence format, diagnostics
- `release.md`: release workflow, self-signed signing, Gatekeeper, certificate setup
- `roadmap.md`: decisions log and milestones
- `hardware-test-plan.md`, `release-checklist.md`: checks on the real desk and before v1.0.0
- `distribution.md`, `packaging/`, `scripts/`: distribution decision and the deferred Homebrew tap drafts

## Stack

Swift 6 (strict concurrency), SwiftUI `MenuBarExtra`, CoreBluetooth, Network.framework (Unix socket), swift-argument-parser. Deployment target macOS 27, arm64 only, Xcode 27. XcodeGen generates the Xcode project from `project.yml`. Never hand-edit or commit `*.xcodeproj`.

## Commands

```bash
brew install xcodegen
make generate                       # xcodegen generate; after any change to project.yml or added/removed files
make test                           # swift test --package-path Packages/DeskKit; no hardware needed
swift test --package-path Packages/DeskKit --filter IdasenCLITests.IdasenCLITests/testVersionString$
make test-scripts                   # shell tests for scripts/ci
make build                          # Debug build into build/DerivedData.noindex (hidden from Spotlight), ad-hoc signed
make build MARKETING_VERSION=1.2.3 CURRENT_PROJECT_VERSION=42
make e2e                            # builds, launches the app with --simulate in a temp support dir, drives it through the idasen CLI
make hw-log                         # streams the app's os.Logger output into ~/Desktop/idasen-hw-logs/ (HW_LOG_ARGS="path"); start before a hardware session
make lint                           # swift format lint --recursive --strict App Packages Tools
make format                         # same paths, in place
make app-path                       # prints the built Idasen.app path
make clean
$(make -s app-path)/Contents/Helpers/idasen --version
```

## Architecture rules

- `DeskController` (`@MainActor`, in `Packages/DeskKit`) is the only component that sends commands to the desk, through one generation-guarded serial write path. The UI and `ControlServer` (CLI socket, `DeskServer` module in the same package) are thin adapters over it.
- The CLI never uses Bluetooth. The desk allows one BLE connection and the app holds it, so the CLI only talks to the app via `~/Library/Application Support/Idasen/control.sock`. The CLI code (`IdasenCLI`) depends on `DeskIPC` only. The tool target in `project.yml` is `idasen-cli` (product `idasen`), because a target named `idasen` collides with `Idasen` on case-insensitive APFS. The binary lives in `Contents/Helpers/`, never `Contents/MacOS/`, because `idasen` and `Idasen` collide on case-insensitive APFS.
- CoreBluetooth is confined to `CoreBluetoothTransport` (main queue, `@MainActor`) behind `DeskTransport`. Controller logic is tested with `FakeTransport` and an injected `Clock`. Keep `Protocol/` free of CoreBluetooth imports.
- Heights are integer raw units (0.1 mm above the lowest position) internally. Convert to cm only at the UI, CLI and file edges, rounding to nearest.
- **Safety invariants**:
  - Movement continues only while the app keeps refreshing the command, and every exit path except clean arrival sends the stop sequence.
  - The stop is sent from `stop()`'s context, never from inside the cancelled move task, and always `.withResponse`.
  - Holds are level-triggered: a dead-man check on every tick, a ~20 s cap, and an end on resign-key / deactivate / lock / sleep.
  - A stall after movement aborts with no retry.
- Diagnostics: `os.Logger` through `DeskLog` (categories `ble`, `controller`, `ipc`, `app`; see `architecture.md` in the notes). Mark interpolated strings `privacy: .public`, use `.debug` for per-tick noise and `.notice` for decisions, and never log position names. Logging must not change behaviour.
- No polling while idle. Height comes from notifications on `99fa0021`. Active reads happen only during a move the app is running.
- **Public contracts**: the positions file format, the CLI `--json` output, exit codes and error codes, and the IPC wire format (`"v": 1`). Changing any of them needs a version bump or a migration, and a doc update.
- **Signing**: always the same self-signed certificate. Its SHA-1 is in `.github/signing-cert.sha1`. A new certificate re-triggers the Bluetooth permission prompt for every user.
