# Gnimu Monitor

A macOS/iOS app for monitoring real-time output from a Gnimu (RaceBox Mini) GNSS+IMU streaming telemetry monitor over BLE (Bluetooth Low Energy).

## Features

- BLE device discovery and connection
- Live data panel displaying position, motion, GNSS status, IMU, and timing
- Speed, compass, and G-force gauges
- Real-time map tracking with follow mode

## Requirements

- Xcode 26.5+
- macOS 26.5+ or iOS 26.5+
- A Gnimu-compatible BLE device (advertises as "RaceBox")

## Building

Open `GnimuMonitor/GnimuMonitor.xcodeproj` in Xcode and build for your target device. BLE functionality requires a physical device — the simulator does not support Bluetooth.
