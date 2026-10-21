# App Review Notes (draft)

Paste into App Store Connect > App Review Information > Notes.

---

Gnimu Monitor is a companion app for the open-source Gnimu GNSS+IMU telemetry device (https://github.com/c20d-us/Gnimu). It connects to the device over Bluetooth Low Energy and shows its live position, speed, IMU and fix-quality data, and can record the stream to a file for analysis.

**Hardware requirement.** The app's features depend on a Gnimu device, which is a small hobbyist GNSS+IMU board streaming over BLE. Without one, the app opens to a device picker that shows "no devices found" and does nothing else. I understand this makes the app hard to review in the usual way, so I have provided: [CHOOSE ONE OR MORE]

- A screen recording of the app connected to a device, showing each panel (Map, Data, Fix Rate, G-Force, Level, Capture, Device): [VIDEO LINK]
- [If you can ship a device to Apple: shipping details.]

**No account or login.** The app has no accounts, purchases, ads, tracking or network features of its own.

**Permissions.**
- Bluetooth: used only to find and connect to the Gnimu device. The app does not request location access; the position shown is the device's.
- iCloud Documents: used only to save the user's own capture files to their iCloud Drive. If iCloud is unavailable, captures are saved locally.

**File sharing.** Captures and reports are visible in the Files app (file sharing is enabled deliberately) so users can export them for analysis elsewhere.

**Third-party names.** Gnimu transmits using the publicly documented RaceBox data protocol, so the app can also read other devices that stream it. The app is independent and not affiliated with or endorsed by RaceBox. The name appears in the app only to describe protocol compatibility.

**Open source.** The app's source is available under GPL-3.0-or-later at [REPO URL].

Contact: [NAME / EMAIL / PHONE]
