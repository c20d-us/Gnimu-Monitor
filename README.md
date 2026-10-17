<p>
  <img src="https://raw.githubusercontent.com/c20d-us/Gnimu-branding/main/svg/gnimu-icon-default-rounded.svg" alt="Gnimu icon" height="72">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/c20d-us/Gnimu-branding/main/wordmark/gnimu-wordmark-transparent-white.svg">
    <img src="https://raw.githubusercontent.com/c20d-us/Gnimu-branding/main/wordmark/gnimu-wordmark-transparent-navy.svg" alt="gnimu" height="72">
  </picture>
</p>

# Gnimu Monitor

![Platform: macOS | iOS](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/swift-5.0-orange)
![License: GPL v3+](https://img.shields.io/badge/license-GPLv3%2B-blue)
![Xcode 26.5+](https://img.shields.io/badge/Xcode-26.5%2B-lightgrey)

A macOS/iOS app for monitoring real-time output from a [Gnimu](https://github.com/c20d-us/Gnimu) (nigh-mew) open-source GNSS+IMU telemetry device. Gnimu streams telemetry over BLE (Bluetooth Low Energy) using the publicly documented RaceBox data protocol, and I built this app to validate Gnimu functionality. It reads that protocol, so other devices that stream it may work too, but I've only tested it with Gnimu.

> [!IMPORTANT]
> **Unofficial project.** This is an independent, educational, and non-commercial implementation. It is **not affiliated with, endorsed by, or supported by RaceBox.** "RaceBox" and related marks belong to their respective owner, and are used here only to describe the protocol this app is compatible with. Use this code for learning and personal purposes only, and at your own risk. Do not use this code for any commercial or fraudulent purpose.

## What it does

Gnimu Monitor opens on a device picker. It lists nearby devices that stream the RaceBox data protocol, each labelled with its protocol and a signal-strength indicator. Pick one and connect. A **Devices / Captures** switch at the top of the picker also gives access to the saved captures and their analysis reports (see [Capture and analysis](#capture-and-analysis)).

Once connected, the screen is laid out for the space it has, and re-arranges as a window is resized or an iPad is rotated. Which panel you're on, and the map's zoom and style, carry across the change.

- **Wide (Mac, iPad landscape):** a live map on the left. On the right, a glance box above a switchable panel, with buttons below to choose between **Data**, **Fix Rate**, **Level** and **Capture**, plus **Device** when the connected device supports it.
- **Stacked (iPad portrait, or a window too narrow for two columns):** the map across the top, then the glance box, the switchable panel and the same buttons below.
- **Deck (iPhone, and small iPad windows):** the glance box stays at the top, above a row of swipeable pages: **Map**, **Data**, **Fix Rate**, **G-Force**, **Level** and **Capture**, plus **Device** when the connected device supports it. The G-Force meter exists only in this layout.

Disconnecting returns to the picker. On iPhone and iPad the screen stays awake while connected, and the connection is dropped when the app goes to the background.

### Glance box

Ground speed in the middle, with battery level (and charging state), satellite count, GNSS fix status and [pDOP](https://en.wikipedia.org/wiki/Dilution_of_precision) around it, and the live fix rate along the bottom edge. Tap or click the speed to switch between MPH and KPH.

### Panels

- **Map:** the device's position and heading on a standard or satellite map. Follow mode keeps it centred, and you can zoom in and out or pan away from the device.
- **Data:** every field the device reports, grouped as Position (latitude, longitude, altitude, horizontal and vertical accuracy), Motion (ground speed, speed accuracy, heading, heading accuracy), IMU (lateral, longitudinal and vertical acceleration, roll, pitch and yaw rates) and Time (UTC date and time, GNSS time of week, time accuracy).
- **Fix Rate:** the rate the device is actually producing fixes, worked out from the GNSS time-of-week stamp on each packet so Bluetooth delivery jitter doesn't hide a device problem. It shows the current rate against the device's nominal rate and whether it is holding it, missed and late fixes, running totals for the session, and two one-minute charts: fix rate (with dropouts marked) and satellite count.
- **Level:** a bubble level for mounting the device, driven by the IMU, with pitch and roll readouts. The bubble turns green when the device is within half a degree of level.
- **G-Force (iPhone):** a lateral and longitudinal g meter with the current magnitude.
- **Capture:** record the stream, and see the result. See below.
- **Device:** what the device was built with, and three commands to send it. See below.

## Device configuration and commands

Newer Gnimu firmware lets a connected client read the device's configuration and send it commands (see the Gnimu [device commands documentation](https://github.com/c20d-us/Gnimu/blob/main/docs/device-commands.md)). When the connected device offers both, a **Device** panel appears. A device without them shows no Device panel.

- **Firmware:** the device ID, firmware version and revision, build time and target board.
- **Configuration:** the settings the firmware was built with: GNSS constellations, dynamic mode, fix rate and minimum satellite elevation; IMU axis orientation and accelerometer and gyro smoothing; BLE protocol and transmit power; and, on battery boards, the cutoff, critical, warning and full voltages. These are fixed when the firmware is built, and the Monitor only reads them.
- **Commands:** **Re-trim** (re-zero the IMU) runs as soon as you tap it. **Restart** and **Shut Down** each ask for confirmation first, because the connection drops while the device restarts and a shut down device has to be power-cycled or woken to come back. The device sends no reply, so Re-trim shows a brief "Sent" and the other two simply end the connection.

All three commands are disabled while a capture is recording, since each would disturb it. The Device panel says so while they are disabled. The device requires no pairing, so any client in range can send these commands.


## Capture and analysis

The **Capture** panel records the packet stream from the connected device. Start and stop with the red button; while recording it shows the elapsed time, the packet count and the file size. The recording keeps each frame exactly as it arrived, with the time it arrived, plus a header describing the session, so a capture can be analyzed later or on another machine.

Captures are saved to iCloud Drive in a *Gnimu Monitor* folder when iCloud is available, and on the device (visible in the Files app on iPhone and iPad) when it isn't. The panel says where a capture went and why, if iCloud was unavailable. **Share Capture** sends the file anywhere else.

When a capture is saved, the app analyzes it automatically and writes an HTML report next to it. The **Captures** list in the picker shows every capture with its size and whether it has a report. From there you can view, share or delete a capture, run or re-run its analysis, or stop one in progress.

A report opens in the app and can be printed or saved as a PDF. It opens with a verdict (clean, mostly healthy, or problems found) and covers:

- **Summary:** packets received against expected, error rate and missed fixes, the longest run with no missed or late fixes, nominal and mean rate, duration and interruptions.
- **Fix cadence:** how steady the device's own fix timing was.
- **Transport vs. device:** every packet carries the device's clock and the time it arrived, so each gap is attributed to the device not producing the fix or to a fix that was produced but delivered late. Arrival spacing and clock drift are charted.
- **GNSS quality:** satellite count, pDOP and accuracy over the capture.
- **Consistency checks:** pass, warn or fail results for the time-of-week sequence, frame integrity, agreement between the clock fields, reported speed against movement between positions, IMU readings at rest, field ranges, battery reporting and whether the capture is complete.
- **Gaps:** each gap, listed.
- **Track:** the shape of the recorded path, coloured by speed.
- **Session:** the device, app and host the capture was recorded on, power and thermal state, and the capture file's details.

## License

This project is licensed under the GNU General Public License, version 3 or (at your option) any later version. See [LICENSE](LICENSE) for details.

The Gnimu name and logo are not covered by this license. See the [Gnimu branding usage policy](https://github.com/c20d-us/Gnimu-branding/blob/main/LICENSE.md).

## Requirements

- Xcode 26.5+
- macOS 26.5+ or iOS 26.5+
- A compatible BLE device (advertises the RaceBox data service)

## Building

Open `GnimuMonitor/GnimuMonitor.xcodeproj` in Xcode and build for your target device. BLE functionality requires a physical device — the simulator does not support Bluetooth.

The build number shown in the About box is the build date and time (for example `20261015.1930`), stamped into the app at build time.

### Installing from the command line

Two scripts in `scripts/` build a Release version and install it:

- `scripts/install-mac.sh` builds for macOS and copies the app to `/Applications`, quitting the running copy first. Set `DEST` to install somewhere else.
- `scripts/install-ios.sh` builds for iOS and installs on every paired iPhone and iPad. Pass part of a device name, or a device identifier, to pick one: `scripts/install-ios.sh iPad`. Devices must be unlocked and reachable by USB or Wi-Fi.

Builds go to `build/`, which is not tracked.

## iPhone Screenshots

| Device Picker | Capture List | Live Map |
| :---: | :---: | :---: |
| <img src="screenshots/iPhone-device-picker.png" width="185"> | <img src="screenshots/iPhone-capture-list.png" width="185"> | <img src="screenshots/iPhone-map-panel.png" width="185"> |

| Data Panel | Fix Rate Tracker | G-Force Meter |
| :---: | :---: | :---: |
| <img src="screenshots/iPhone-data-panel.png" width="185"> | <img src="screenshots/iPhone-fix-rate-tracker-panel.png" width="185"> | <img src="screenshots/iPhone-gmeter-panel.png" width="185"> |

| Level | Capture | Device |
| :---: | :---: | :---: |
| <img src="screenshots/iPhone-level-panel.png" width="185"> | <img src="screenshots/iPhone-capture-panel.png" width="185"> | <img src="screenshots/iPhone-device-panel.png" width="185"> |

## iPad Screenshots

| Device Picker | Capture List |
| :---: | :---: |
| <img src="screenshots/iPad-device-picker.png" width="391"> | <img src="screenshots/iPad-capture-list.png" width="391"> |

| Live Map & Data Panel | Fix Rate Tracker |
| :---: | :---: |
| <img src="screenshots/iPad-data-panel.png" width="391"> | <img src="screenshots/iPad-fix-rate-tracker-panel.png" width="391"> |

| Level | Capture |
| :---: | :---: |
| <img src="screenshots/iPad-level-panel.png" width="391"> | <img src="screenshots/iPad-capture-panel.png" width="391"> |

| Capture in Progress | Capture Complete |
| :---: | :---: |
| <img src="screenshots/iPad-capture-progress-panel.png" width="391"> | <img src="screenshots/iPad-capture-complete-panel.png" width="391"> |

| Device |
| :---: |
| <img src="screenshots/iPad-device-panel.png" width="391"> |

## Mac Screenshots

| Device Picker | Capture List |
| :---: | :---: |
| <img src="screenshots/macOS-device-picker.png" width="250"> | <img src="screenshots/macOS-capture-list.png" width="250"> |

| Live Map & Data Panel | Fix Rate Tracker |
| :---: | :---: |
| <img src="screenshots/macOS-data-panel.png" width="391"> | <img src="screenshots/macOS-fix-rate-tracker-panel.png" width="391"> |

| Level | Capture |
| :---: | :---: |
| <img src="screenshots/macOS-level-panel.png" width="391"> | <img src="screenshots/macOS-capture-panel.png" width="391"> |

| Capture in Progress | Capture Complete |
| :---: | :---: |
| <img src="screenshots/macOS-capture-progress-panel.png" width="391"> | <img src="screenshots/macOS-capture-complete-panel.png" width="391"> |

| Device |
| :---: |
| <img src="screenshots/macOS-device-panel.png" width="391"> |
