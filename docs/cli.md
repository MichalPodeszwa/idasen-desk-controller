# CLI (`idasen`)

The automation interface. A small command-line tool that talks to the running menu-bar app. It works from a terminal, Shortcuts ("Run Shell Script"), Raycast, Alfred, Keyboard Maestro, cron/launchd, and so on.

## Why a CLI talking to the app (not to the desk)

The desk accepts **one** BLE connection, and the menu-bar app holds it. So the CLI never touches Bluetooth. It sends requests to the app over a Unix domain socket, and the app executes them through `DeskController`, exactly like a button press in the UI.

Why not AppleScript: we ship self-signed builds (no Apple Developer ID). Every caller of an Apple-Events-based interface gets a macOS Automation (TCC) prompt, and with non-Developer-ID signing that is likely to repeat after updates. A Unix socket needs no TCC grant. An AppleScript dictionary can still be added later on top of the same controller if needed.

## Installation

- The binary ships inside the app: `/Applications/Idasen.app/Contents/Helpers/idasen`. It is not in `Contents/MacOS/`, because `idasen` and `Idasen` collide on case-insensitive APFS.
- Settings → "Install command line tool" creates a symlink at `~/.local/bin/idasen` (no admin needed). It then asks the user's login shell for its `PATH` (`$SHELL -lc`, 3 s timeout, because a Finder-launched app only has launchd's minimal `PATH`) and warns if that directory is not on it. If the shell can't be asked (no `$SHELL`, a failure or the timeout), it says so neutrally and tells the user to add `~/.local/bin` to their `PATH` if `idasen` isn't found. It is refused while the app runs translocated or outside `/Applications`. Manual alternative:
  ```bash
  ln -s /Applications/Idasen.app/Contents/Helpers/idasen /usr/local/bin/idasen
  ```
- Shortcuts' "Run Shell Script" has a minimal `PATH`, so use the absolute path there.

## Commands

All heights are in **centimetres**, as displayed in the app (calibration applied). Input and output always use `.` as the decimal separator, whatever the locale, and output is rounded to one decimal.

| Command | Description |
| --- | --- |
| `idasen status [--json]` | Height, connection state, moving flag |
| `idasen height` | Prints the current height only, e.g. `92.4`. While there is no height yet and the state isn't `bluetoothOff`, `unauthorized`, `pairingRequired` or `failed` (for example right after launch or connecting, before the first height arrives), it polls for up to 10 s, then exits 4 |
| `idasen move <target> [--no-wait]` | `<target>` is a number (cm), a position name or a position slug. Position names and slugs can never be numbers, so this is unambiguous. |
| `idasen up [<cm>] [--no-wait]` | Relative move, default 1 cm. `<cm>` must be positive (usage error otherwise) |
| `idasen down [<cm>] [--no-wait]` | Relative move, default 1 cm. `<cm>` must be positive |
| `idasen stop` | Stop immediately |
| `idasen positions [--json]` | List positions (in display order) with their slugs. Human output is `<name>  <slug>  <height> cm`, with `-` when the position has no usable slug |
| `idasen positions save <name> [--height <cm>]` | Create, or update if the name exists. Default: current settled height |
| `idasen positions remove <name\|slug>` | Delete a position |
| `idasen positions rename <old> <new>` | Rename a position. `<old>` is a name or slug; renaming changes the slug |
| `idasen watch [--json]` | Stream height/state changes until Ctrl-C |
| `idasen connect` | Make sure the desk is connected (waits up to 10 s) |

Global flag: `--no-launch` (don't start the app if it isn't running; exit 3 instead). It is accepted before or after the command name.

A `<target>` that `Double(_:)` accepts is a height, anything else is a position name. A non-finite height (`inf`, `nan`) exits 5 without contacting the app. Write `-inf` after `--`, otherwise it is parsed as an option.

### Behaviour

- **Blocking by default.** `move`/`up`/`down` return when the desk has stopped at the target and print the settled height. `--no-wait` returns once the movement has started.
- **Ctrl-C during a blocking move stops the desk.** The CLI closes its connection (the app then cancels that move and sends the stop sequence) and exits 130. Ctrl-C during `watch` just ends the stream.
- **Interruption**: any newer command (CLI, UI) or the physical panel (detected as an opposite-direction movement, [protocol.md](protocol.md#move-to-height)) interrupts a running move. The blocked caller exits with code 8.
- **Range**:
  - an absolute height outside the desk's range → exit 5, no movement;
  - `up`/`down` are clamped to the range;
  - a request closer than 0.2 cm to the current height succeeds without moving.
- **Relative moves**: relative to the in-flight target if a move is running, otherwise to the current height. Three quick `idasen up --no-wait` calls give +3 cm.
- **Auto-launch**: if the socket isn't there, the CLI resolves its own real path and opens the enclosing `.app` through LaunchServices (`NSWorkspace.openApplication`), falling back to the bundle ID (the CLI's own identifier without `.cli`, so debug builds find the debug app). It never spawns the app binary directly, so Bluetooth is attributed to the app. It then waits up to 10 s for the socket.
- **Waiting for the desk**: commands that need the desk wait up to 10 s for a connection before failing with exit 4. This covers a CLI call right after auto-launch or login.
- **Names and slugs**: every position has a slug derived from its name: `Żółte biurko` → `zolte-biurko`. `move`, `positions remove`, `positions rename` (the old name) and the IPC `position` targets resolve a target on the server in this order: (1) a number is a height (client-side, `move` only); (2) exact name, case-insensitive (Unicode case folding + NFC); (3) slug, after trimming and lower-casing the target (`Standing` and `ZOLTE-BIURKO` both work). A slug that is ambiguous (two positions share it, possible only in a hand-edited file) or numeric matches nothing, so that position is addressable by name only. There is no prefix or fuzzy matching. `positions save <name>` matches by name only, so saving a name whose slug clashes with another position fails with exit 9. A position with an empty slug (a name with no ASCII letters or digits, like `🙂`) is addressable by name only.
- **Output contract**: `--json` output and exit codes are stable (public contract). Human-readable output is not.

## Exit codes

| Code | Error `code` (wire) | Meaning |
| --- | --- | --- |
| 0 | n/a | OK |
| 1 | `internal` | Unexpected error, including a request the app couldn't parse |
| 2 | n/a (client-side) | Usage error. swift-argument-parser's default `64` is remapped to 2 in `IdasenCLI` (`runIdasen`). |
| 3 | n/a (client-side) | App not running and could not be started (or `--no-launch`) |
| 4 | `notConnected` | Desk not connected / unreachable |
| 5 | `outOfRange` | Height out of range |
| 6 | `unknownPosition` | No position with that name or slug |
| 7 | `moveFailed` | Move failed: didn't start, stalled (obstacle), timed out, hold time limit, or a Bluetooth read/write error |
| 8 | `interrupted` | Move interrupted by another command or the physical panel |
| 9 | `invalidName` | Invalid, numeric (name or slug) or duplicate position name (including a slug that clashes with another position; the message names it) |
| 10 | `unsupportedVersion`, `unsupported` | App and CLI versions differ (typically the old app is still running after an update). Message: "restart Idasen" |
| 11 | n/a (client-side) | Lost the connection to the app mid-request (app quit or crashed) |
| 12 | `deskMoving` | Desk is moving; try again when it stops (`positions save` without `--height`) |
| 13 | `positionsReadOnly` | Positions file is read-only; see the warning in the app |
| 130 | n/a (client-side) | Interrupted by Ctrl-C (SIGINT) during a blocking move |

Exit 3 means the connection never got established (no socket, nobody listening, launch failed or timed out, or the socket path is too long, which is reported as such and never triggers a launch). Exit 11 means it was established and then lost. Errors go to stderr as `idasen: <message>`, in both human and `--json` mode.

## Examples

```bash
idasen move standing
idasen move zolte-biurko
idasen move 105.5
idasen positions save Focus --height 100
idasen watch --json | jq .heightCm
```

Toggle sit/stand. Use `if`/`else`, not `a && b || c`: with `&&`/`||`, a failed or interrupted `move standing` would run `move sit`.

```bash
if [ "$(idasen height | cut -d. -f1)" -lt 90 ]; then
  idasen move standing
else
  idasen move sit
fi
```

## IPC (app ↔ CLI)

### Socket

- Path: `~/Library/Application Support/Idasen/control.sock`. Debug builds (`#if DEBUG` in `DeskIPC`, so app and CLI always agree) use `Idasen-Debug/`.
- The environment variable `IDASEN_SUPPORT_DIR` replaces the whole `Idasen[-Debug]` directory (the socket is `$IDASEN_SUPPORT_DIR/control.sock`). It exists for tests and simulate mode, and is honoured by both the app and the CLI. Auto-launch passes it on to the app it starts.
- The directory is created with mode `0700` before listening; that's the real access guard. The socket is created with the umask (`0755`), so `chmod 0600` it after the listener is ready.
- Path length must be < 104 bytes (`sun_path`), i.e. at most 103 UTF-8 bytes. Check it before listening, because `NWListener` reports `.ready` without creating the socket if the path is too long. Too long → error state in the UI.
- **Startup** (two instances starting within the same instant can both see a stale socket and both unlink and bind, leaving the first unreachable; LaunchServices keeps a single app instance, so this is not guarded further): try to connect to an existing socket (a plain POSIX `connect`, so the answer is synchronous; the probe connects and closes without sending a request, which the server ignores).
  - It answers → another instance is running → this instance exits.
  - Connection refused → it's stale: unlink it, then listen.
  - A new listener on an existing file fails with `EADDRINUSE` even with `allowLocalEndpointReuse`.
- **Quit**: cancel the listener and unlink the file.
- App side: Network.framework `NWListener` on `NWEndpoint.unix(path:)` (verified working on macOS 27.2.1). CLI side: `NWConnection` to the same endpoint.

### Framing and versioning

- Newline-delimited JSON. Max line length 64 KiB.
- **One request per connection**: the client sends one line and the server answers with one line, except `watch`, which streams events until the client disconnects.
- Every request carries `"v": 1`. Unknown fields are ignored. Unknown `cmd` → error `unsupported`. Unknown major `v` (or a missing `v`) → error `unsupportedVersion`; the version is checked before `cmd`. A line that isn't JSON, is longer than 64 KiB, or lacks a required field of a known `cmd` → error `internal`. `wait` defaults to `true`.
- Message types, error codes, the socket path, line framing and the client (`IPCClient`, on `NWConnection`) live in the shared `DeskIPC` module.
- Clients must keep the connection fully open until the response arrives. A half-close (shutting down the write side, e.g. `printf … | nc -U`) looks like a disconnect and cancels a waiting move. Any read error, including a second line over 64 KiB, counts as a disconnect too.
- A disconnect while the app is still waiting for the desk to connect (before the move has started) drops a `"wait": true` move without ever starting it. A `"wait": false` move still starts once the desk is connected.

```jsonc
// requests
{"v":1,"cmd":"status"}
{"v":1,"cmd":"move","target":{"heightCm":110},"wait":true}
{"v":1,"cmd":"move","target":{"position":"zolte-biurko"},"wait":false}
{"v":1,"cmd":"moveBy","deltaCm":-2,"wait":true}
{"v":1,"cmd":"stop"}
{"v":1,"cmd":"positions.list"}
{"v":1,"cmd":"positions.save","name":"Focus","heightCm":100}
{"v":1,"cmd":"positions.remove","name":"Focus"}
{"v":1,"cmd":"positions.rename","from":"Focus","to":"Deep work"}
{"v":1,"cmd":"connect"}
{"v":1,"cmd":"watch"}

// responses
{"ok":true,"heightCm":110.1}
{"ok":false,"error":{"code":"unknownPosition","message":"No position named 'Stand'"}}
{"ok":true,"status":{"state":"connected","moving":false,"heightCm":92.4,"minCm":62,"maxCm":127,"notFoundHint":false}}
{"ok":true,"positions":[{"id":"6F1C…","name":"Sit","slug":"sit","heightCm":72.5}]}
{"ok":true,"position":{"id":"6F1C…","name":"Focus","slug":"focus","heightCm":100}}   // positions.save
{"ok":true}   // stop, connect, no-wait moves, positions.remove / rename

// watch events
{"event":"height","heightCm":97.3,"speedCmS":3.6,"state":"moving"}
{"event":"state","state":"disconnected","notFoundHint":false}
```

`state` values: `bluetoothOff`, `unauthorized`, `disconnected`, `scanning`, `connecting`, `pairingRequired`, `connected`, `moving` (`moving` covers moves from any source), `failed`. `status.heightCm` is absent while the height is unknown.

`failed` is unrecoverable without user action (for example the desk lacks an expected characteristic). It carries a `message` string, in `status` and in `state` events (absent in other states). `notFoundHint` is a boolean in `status` and in `state` events: `true` after ~15 s of searching without finding the desk (it may be off, out of range or connected to another device), `false` otherwise. Clients that predate the field treat a missing `notFoundHint` as `false`. `height` events carry neither. A `state` event is sent whenever the controller's state changes or `notFoundHint` flips, and carries the current `state`, `message` and `notFoundHint`; there is no separate `notFoundHint` event. Likewise `slug` in a position object is additive: it is always present from this version on, and clients that predate it (or talk to an older app) treat a missing `slug` as `""`.

All heights in responses and events are cm rounded to one decimal (integral values are emitted without `.0`, e.g. `62`); `speedCmS` is signed (negative = moving down). `watch` starts with a snapshot of the current state: a `height` event if a height is known, otherwise a `state` event. A `watch` request that fails (e.g. `unsupportedVersion`) gets one error response instead.

Waiting for the desk: `move`, `moveBy` and `positions.save` without `heightCm` wait up to 10 s for the desk to be connected before failing with `notConnected`. `connect` asks the app to connect and waits the same way. `stop` and the other positions commands never wait. An unknown position name fails with `unknownPosition` before any waiting.

### Cancellation

- Cancel on disconnect applies **only** to a move issued with `"wait": true` on that connection. It is keyed to that move's `id`.
- If that move was already interrupted by a newer command, the disconnect does nothing. It never cancels the newer move.
- A `--no-wait` move is owned by the app and continues after the CLI exits.
- A `watch` client disconnecting never cancels anything.

### CLI `--json` output

Part of the public contract, together with the exit codes. Each line is compact JSON with sorted keys.

| Command | Output |
| --- | --- |
| `status --json` | the `status` object: `{"heightCm":92.4,"maxCm":127,"minCm":62,"moving":false,"notFoundHint":false,"state":"connected"}` |
| `positions --json` | an array of `{"id","name","slug","heightCm"}` in display order. `slug` is derived from `name`; it is `""` when the position has no usable slug (empty, numeric or shared with another position) |
| `watch --json` | one `watch` event per line, exactly as on the wire |

### Security model

Any process running as the same user can control the desk. This is slightly weaker than AppleScript, which asks for consent per caller app. It is accepted for a desk controller. No network listener, ever.
