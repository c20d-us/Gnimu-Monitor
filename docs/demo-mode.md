# Demo mode (design note)

Status: proposed, not started.

## Why

App Store review may reject an app whose functions the reviewer can't exercise.
Without a Gnimu device the app opens to a device picker showing "no devices
found" and nothing else. Demo mode gives a reviewer (and a curious user) a
Gnimu GNSS+IMU device and a Gnimu-CAN device to "connect" to, streaming
realistic data, with the Device-panel commands responding as if real.

## Behavior

- The device picker has a **Demo** section listing two clearly labelled demo
  devices: a Gnimu GNSS+IMU (RaceBox-protocol, `Gnimu-RB`) and a Gnimu-CAN.
- **On by default.** A setting turns the section off (`@AppStorage`, e.g.
  `showDemoDevices`, default `true`), for users who don't want it cluttering
  the list. The setting needs a home in the app's existing settings UI.
- Demo rows work with Bluetooth off or unauthorized, since reviewers often
  have it off. The Demo section must show even when the BLE state banner would
  otherwise block the list.
- Selecting one "connects" immediately and streams looping, internally
  consistent data. Disconnect returns to the picker.
- A persistent "Demo" label is visible while connected, so demo data is never
  mistaken for a real device.
- Commands act on the fake device: restart/shutdown show the existing
  "device is restarting" notice and then reconnect; config changes update
  `deviceConfig`.
- Recording works and produces a valid capture, marked as demo in its header,
  so the Capture/analysis tab can be exercised too.

## What already exists

- `BLEManager.startReplay` feeds frames through the real `ingest()` path
  (decoder, state merge, throttle), with looping. Debug-only today.
- `DemoData.swift`: `BLEManager.demo()` / `.demoCAN()` build connected sample
  devices with identity, schema, info JSON and config text. Debug-only today.
- Test-target generators: `SyntheticCapture`, `SyntheticGnimuCapture`,
  `RaceBoxPacketBuilder`, `GnimuFrameBuilder`.

## Work

1. **Picker model.** `DiscoveredDevice` wraps a `CBPeripheral`, which can't be
   constructed. Add a source (real vs demo) or make the peripheral optional;
   add the Demo section; branch `connect(to:)` to a demo session.
2. **Generator.** Rather than a fixed bundled capture, synthesize a lap around
   a circuit at the existing public fake location (`DemoLaunch.defaultLatitude`
   / `defaultLongitude`). GNSS+IMU: position, speed, heading, lateral and
   longitudinal g, satellites, fix, all derived from one path. CAN: rpm,
   throttle, gear, speed, temperatures, boost, tied to the same lap. Emit
   `TelemetryUpdate`s or encoded frames through `ingest()`.
3. **Fake commands.** `send()` currently needs a peripheral and command
   characteristic; in demo mode route to a handler that updates the fake
   device.
4. **Release gating.** Remove `#if DEBUG` from what demo mode needs; keep the
   launch-argument tooling (`-demoMonitor`, `-replay`, ...) debug-only.
5. **Review notes.** Update `docs/app-store/review-notes.md` to point
   reviewers at the Demo section instead of the "no devices found" dead end.

Estimate: 1-2 focused days; picker/model change first (it touches existing
code), then the generators.

## Open points

- The map panel likely needs network for tiles; fine for a reviewer.
- Where the setting lives (settings screen vs. picker footer toggle).
- Whether the Demo label is a banner or a badge in the monitor header.
