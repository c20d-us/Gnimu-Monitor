# Gnimu Monitor

![Platform: macOS | iOS](https://img.shields.io/badge/platform-macOS%20%7C%20iOS-blue)
![Swift](https://img.shields.io/badge/swift-5.0-orange)
![License: GPL v3](https://img.shields.io/badge/license-GPLv3-green)
![Xcode 26.5+](https://img.shields.io/badge/Xcode-26.5%2B-lightgrey)

A macOS/iOS app for monitoring real-time output from a Gnimu (RaceBox Mini) GNSS+IMU streaming telemetry monitor over BLE (Bluetooth Low Energy).

## Features

- BLE device discovery and connection
- Live data panel displaying position, motion, GNSS status, IMU, and timing
- Speed, compass, and G-force gauges
- Real-time map tracking with follow mode

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.

## Requirements

- Xcode 26.5+
- macOS 26.5+ or iOS 26.5+
- A Gnimu-compatible BLE device (advertises as "RaceBox")

## Building

Open `GnimuMonitor/GnimuMonitor.xcodeproj` in Xcode and build for your target device. BLE functionality requires a physical device — the simulator does not support Bluetooth.
