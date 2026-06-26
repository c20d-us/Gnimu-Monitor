import SwiftUI

struct DataPanel: View {
    let packet: GnimuPacket?

    var body: some View {
        ScrollView {
            if let p = packet {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    sectionHeader("Position")
                    row("Latitude",    String(format: "%.7f °", p.latitude))
                    row("Longitude",   String(format: "%.7f °", p.longitude))
                    row("Alt MSL",     String(format: "%.1f m", p.heightMSL))
                    row("Alt WGS84",   String(format: "%.1f m", p.heightEllipsoid))
                    row("H Accuracy",  String(format: "%.2f m", p.hAcc))
                    row("V Accuracy",  String(format: "%.2f m", p.vAcc))

                    sectionHeader("Motion")
                    row("Speed",       String(format: "%.1f km/h", p.speedKmh))
                    row("Heading",     String(format: "%@ %.2f °", p.headingCardinal, p.headingOfMotion))
                    row("Spd Acc",     String(format: "%.2f m/s", p.speedAccuracy))
                    row("Hdg Acc",     String(format: "%.2f °", p.headingAccuracy))

                    sectionHeader("GNSS Status")
                    row("Fix",         p.fixTypeString)
                    row("Satellites",  "\(p.numSV)")
                    row("pDOP",        String(format: "%.2f", p.pDOP))
                    row("Battery",     "\(p.battery) %")

                    sectionHeader("IMU")
                    row("Accel X",     String(format: "%.3f g", p.accelX))
                    row("Accel Y",     String(format: "%.3f g", p.accelY))
                    row("Accel Z",     String(format: "%.3f g", p.accelZ))
                    row("Gyro X",      String(format: "%.2f °/s", p.gyroX))
                    row("Gyro Y",      String(format: "%.2f °/s", p.gyroY))
                    row("Gyro Z",      String(format: "%.2f °/s", p.gyroZ))

                    sectionHeader("Time")
                    row("UTC", utcString(p))
                    row("iTOW",        "\(p.iTOW) ms")
                    row("Time Acc",    "\(p.timeAccuracy) ns")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                Text("No data — connect to a device")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }

    private func utcString(_ p: GnimuPacket) -> String {
        let validDate = (p.validityFlags & 0x01) != 0
        let validTime = (p.validityFlags & 0x02) != 0
        let datePart = validDate
            ? String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
            : "date invalid"
        let timePart = validTime
            ? String(format: "%02d:%02d:%02d", p.hour, p.minute, p.second)
            : "time invalid"
        return "\(datePart)  \(timePart)"
    }

    private func sectionHeader(_ title: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .gridCellColumns(2)
                .padding(.top, 8)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.caption)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption)
                .fontDesign(.monospaced)
                .gridColumnAlignment(.leading)
        }
    }
}
