# LINAK DPG BLE protocol (IKEA IDÅSEN)

Language-agnostic description of what the app sends and receives.

Sources:
- mehmetmuejde/idasen-desk-controller (Go, `app.go`)
- newAM/idasen (Python, `idasen/__init__.py`)
- DWilliames/idasen-desk-controller-mac (Swift)
- rhyst/linak-controller (Python, `desk.py`, `gatt.py`, `reference/*.md`), which documents desk behaviour the others leave out

Items marked **⚠ verify** disagree between sources, come from one source only, or are our own design. They must be confirmed on real hardware and this document updated with the result.

Target device: IKEA IDÅSEN. Other LINAK DPG desks may work but are not targeted.

## Units

- Internally, all heights are **integer raw units**: 0.1 mm above the desk's lowest position. That is the desk's own unit.
- Convert to and from cm only at the edges (UI, CLI, positions file), **rounding to nearest**. The references truncate, so `(0.73 − 0.62) × 10000` becomes 1099 instead of 1100.
- Valid raw range: **0–6500** (65 cm of travel). Clamp in raw units. The displayed range is derived from the base height.

## Discovery

1. Before scanning, check `retrieveConnectedPeripherals(withServices:)`. A desk already connected at system level does not advertise.
2. Reconnect to a remembered desk by identifier (`retrievePeripherals(withIdentifiers:)` + `connect`). A pending `connect` has no timeout, which is the supported pattern for "reconnect when back in range". Re-issue it after Bluetooth power-cycles.
3. First run, or no remembered desk: scan by the advertised service `99fa0001-338a-1024-8a49-009c0215f78a`.
   - **⚠ verify** that the desk advertises this UUID. Only newAM relies on it. DWilliames scans with `nil` and filters by name.
   - If nothing turns up within ~5 s, fall back to a `nil` scan filtered by the name prefix `Desk`. Users can rename the desk, so the name only matters before first pairing.
4. Several desks in range: list them with name and signal strength and let the user pick. DWilliames' automatic RSSI pick has an inverted comparison (`BluetoothManager.swift:100`).
5. The desk accepts **one** central connection at a time. A desk connected to another device most likely just stops advertising, which looks the same as off or out of range. **⚠ verify**. This cannot be detected, only hinted at.

## Pairing

- The desk requires a BLE bond. On first use, the user holds the Bluetooth button on the desk panel until the LED blinks.
- On macOS there is no explicit pair API. The system pairing prompt appears when we first access an encrypted characteristic. The UI tells the user to enable pairing mode *before* connecting.
- macOS keeps the bond after a desk reset, and an app cannot delete a system bond.
- Reset procedure (DWilliames' README): lower the desk fully, hold down again until it jumps, then hold the Bluetooth button until it blinks.

Error → state mapping (**⚠ verify** all of it on hardware):

| Observation | State / user message |
| --- | --- |
| `CBATTError.insufficientAuthentication` / `.insufficientEncryption` on the first read or notify-enable | `.pairingRequired`: "Hold the Bluetooth button on the desk until it blinks" |
| Disconnect within a few seconds of connecting, before discovery completes | `.pairingRequired` (heuristic) |
| `CBError.peerRemovedPairingInformation` | "Remove the desk in System Settings → Bluetooth, then pair again" |
| Remembered desk not found for ~15 s | "Desk not found: is it on, in range, and not connected to another device?" |
| `CBError.connectionTimeout` / `.connectionFailed` | Retry with backoff |

## Services and characteristics

All UUIDs share the suffix `-338a-1024-8a49-009c0215f78a`.

| Purpose | Service | Characteristic | Properties |
| --- | --- | --- | --- |
| Control (commands) | `99fa0001` | `99fa0002` | write, write-without-response (`0x0c`) |
| Error | `99fa0001` | `99fa0003` | read, notify. **⚠ verify** (linak-controller `gatt.py:124-125`) |
| DPG | `99fa0010` | `99fa0011` | write, notify |
| Reference output (height + speed) | `99fa0020` | `99fa0021` | read, notify |
| Reference input (target height) | `99fa0030` | `99fa0031` | write, write-without-response (`0x0c`) |

Check the expected properties at discovery, and treat a mismatch as an error state rather than dropping writes silently.

Write types:
- **Refresh writes** (target, hold pulses): `.withoutResponse`. If `canSendWriteWithoutResponse` is false, skip that tick instead of queueing.
- **Stop, wake and DPG writes**: `.withResponse`, so they can't be dropped.

## DPG (`99fa0011`)

Command frames (linak-controller `gatt.py`, `desk.py`):

- Read: `7F <cmd> 00`. The answer arrives as a notification on `99fa0011`.
- Write: `7F <cmd> 80 <data…>`.

| Cmd | Meaning |
| --- | --- |
| `0x80` | Capabilities |
| `0x81` | Base offset |
| `0x86` | User ID |

On connect, after notifications on `99fa0011` are enabled:

1. **Base height**: write `7F 81 00`. The response is valid if byte 0 is `01`. Bytes 3–4 are a `uint16` LE in 0.1 mm, so the base in mm is that value / 10. If there is no valid answer, fall back to 620.0 mm. The user calibration offset is a fine-tune on top. **⚠ verify**. This resolves the 62.0 vs 61.5 cm disagreement between references.
2. **User ID (optional)**: read with `7F 86 00`. If the first byte isn't `01`, set it to `01` and write the data back with `7F 86 80 <data>` (linak-controller's form). Some DPG1C controllers ignore commands until this is done. newAM blindly overwrites all 17 bytes, which isn't needed. Do this only if commands are ignored without it. **⚠ verify**.
   - Both DPG parsers share one definition of a response: byte 0 is the status (`01` = valid), bytes 1–2 are a header, and the payload starts at byte 3. The base offset is payload bytes 0–1. The user-ID flag is payload byte 0, and the rest of the payload is written back unchanged. **⚠ verify** this framing on hardware (only the base-offset layout comes from a reference; whether the user-ID flag sits after the same header is unconfirmed).

## Height / speed (`99fa0021`)

4 bytes, little-endian: `uint16 height_raw`, `int16 speed_raw`.

```
height_mm = height_raw / 10 + base_mm
speed_mm_s = speed_raw / 10   # ⚠ verify the unit (newAM and mehmetmuejde use raw/10000 m/s, which is the same scale)
```

- Speed sign: positive while moving up, negative while moving down. **⚠ verify**. Takeover detection and the `.external` direction depend on it.

- The desk **notifies only while it moves**.
- The last notified value is often not the value measured at rest (linak-controller `desk-internals.md`).
- Consequences:
  - Notifications are enough for idle display.
  - A move must actively read this characteristic on every tick.
  - After a move ends, do one settle read about 0.5 s after speed reaches 0.

## Commands (`99fa0002`, 2 bytes)

| Command | Bytes | Notes |
| --- | --- | --- |
| Up | `47 00` | Motor runs about 1 s per write, so it must be re-sent to keep moving |
| Down | `46 00` | Same as up |
| Stop | `FF 00` | Sometimes not obeyed immediately (linak-controller) |
| Wake up | `FE 00` | Required before the first reference-input write |

## Reference input (`99fa0031`)

- Signed `int16` LE (per linak-controller notes). For 0–6500 the bytes equal the unsigned encoding.
- Target = raw height.
- Stop sentinel: `01 80` (`0x8001`, newAM). **⚠ verify**.

## Move to height

1. The caller has validated the target. Absolute targets out of range are rejected, relative ones clamped. If `|current − target| < 20` raw (2 mm), return success without moving.
2. **Prelude, once per move**: `FE 00` then `FF 00` to control (`.withResponse`). Never re-send the prelude within the same move. After a collision, the stop in the prelude re-enables the desk, so a retry would drive into the obstacle again.
3. **Tick every 100 ms** (continuous clock):
   1. Write the target to the reference input (`.withoutResponse`).
   2. Read `99fa0021`.
4. **Arrival**: speed is 0 on 2 consecutive reads and `|height − target| ≤ 50` raw (5 mm) → settle read → done. The settle value is the move's result.
5. **Did not start**: height has not changed by ≥ 10 raw within 1.5 s of the first target write (the clock starts once the prelude is acknowledged) → fail (`moveFailed`).
6. **Stall after movement**: speed is 0 on 2 consecutive reads outside tolerance → fail (`moveFailed`). This most likely means an obstacle, the collision sensor or the panel. **No retry.**
7. **External takeover**: speed sign opposite to the commanded direction → `interrupted` (someone is using the panel).
8. **Timeout**: 30 s (full travel ≈ 65 cm at ~3.5–4 cm/s ≈ 18 s) → fail (`moveFailed`).
9. **Stop sequence on every exit except clean arrival**: `FF 00` to control, then `01 80` to the reference input, both `.withResponse`. If speed is still non-zero ~300 ms later, send it once more.
10. A move never survives a disconnect or a sleep/wake cycle.

**⚠ verify: residual travel.** The desk keeps moving after the last write. linak-controller says the motor runs ~1 s per command, which is up to ~4 cm. newAM suggests the reference input stalls sooner. Measure the coast distance after the last reference-input write, after the last `47 00`, and after an explicit stop.

## Hold-to-move (live control)

Candidates, to be decided on hardware:

- **A**: run the move loop with target = 0 (down) or 6500 (up) while the button is held. Release → stop sequence. Same code path as move-to-height, but every press pays the prelude latency. Our own design. **⚠ verify**.
- **B**: re-send `47 00` / `46 00` every ~300 ms while held, then `FF 00` on release. The interval is our choice, chosen against the ~1 s motor run per command. DWilliames sends pulses from notifications, at least 0.5 s and 0.5 cm apart (`DeskController.swift:36-40, 151-155`). **⚠ verify** smoothness.
- **C**: write the reference-input direction sentinels `00 80` (up) / `FF 7F` (down) while held. They appear in linak-controller's history (removed as unused in commit `3d0efec`, 2022). Avoids "target = limit". **⚠ verify**.

Whichever variant is used, the **client** must confirm on every refresh tick that the input is still held (dead-man check) and cap a single hold at ~20 s. The desk's own "stops when refreshes stop" behaviour only protects against a dead client, not a live client that missed the release.
