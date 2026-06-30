# Gnimu Monitor

![Platform: macOS | iOS](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/swift-5.0-orange)
![License: GPL v3](https://img.shields.io/badge/license-GPLv3-green)
![Xcode 26.5+](https://img.shields.io/badge/Xcode-26.5%2B-lightgrey)

A macOS/iOS app for monitoring real-time output from a [Gnimu](https://github.com/c20d-us/Gnimu) open-source RaceBox Mini emulator. Gnimu streams GNSS+IMU telemetry over BLE (Bluetooth Low Energy) using the published RaceBox BLE protocol, and I built this app to validate Gnimu functionality. I've not tested with an actual RaceBox device, but it should work exactly the same when paired with a RaceBox Mini, Mini S, or Micro.

> [!IMPORTANT]
> **Unofficial project.** This is an independent, educational, and non-commercial implementation. It is **not affiliated with, endorsed by, or supported by RaceBox.** "RaceBox" and related marks belong to their respective owner. Use this code for learning and personal purposes only, and at your own risk. Do not use this code for any commercial or fraudulent purpose.

The macOS and iPad version features a single monitor window with a live map showing current location on the left, and a data panel on the right that provides a view of real-time data streaming from the GNSS+IMU device.

The iPhone version has three swipe-able panes - a live map panel, a streaming data panel, and a real-time g-force gauge panel. Each panel has a glancebox at the top that shows ground speed in the middle, with battery level, satellite lock count, GNSS fix status, and [pDOP](https://en.wikipedia.org/wiki/Dilution_of_precision) in the four corners.

The units for ground speed can be toggled between MPH and KPH by tapping or clicking the speed value display.

## Features

- BLE device discovery and connection
- Live data panels displaying position, motion, GNSS status, IMU, and timing
- Real-time map tracking with follow mode

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

## Requirements

- Xcode 26.5+
- macOS 26.5+ or iOS 26.5+
- A Gnimu-compatible BLE device (advertises as "RaceBox")

## Building

Open `GnimuMonitor/GnimuMonitor.xcodeproj` in Xcode and build for your target device. BLE functionality requires a physical device — the simulator does not support Bluetooth.

## iPhone Screenshots

| Device Picker | Live Map | Data Panel | G-Force Meter |
| :---: | :---: | :---: | :---: |
| <img src="screenshots/iphone-device-picker.png" width="185"> | <img src="screenshots/iphone-live-map.png" width="185"> | <img src="screenshots/iphone-data-panel.png" width="185"> | <img src="screenshots/iphone-g-force-meter.png" width="185"> |

## Mac/iPad Screenshots

| Device Picker | Live Map & Data Panel |
| :---: | :---: |
| <img src="screenshots/ipad-device-picker.png" width="391"> | <img src="screenshots/ipad-live-map-and-data.png" width="391"> |
