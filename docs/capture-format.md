# Capture file format (schema 2)

Gnimu Monitor records what a device sends to a capture file, so it can be
analyzed later or on another machine. This describes the file as the app writes
and reads it. The format is versioned by the `schema` number in the header; this
is **schema 2**.

A capture is a **JSON Lines** file (`.jsonl`): one JSON object per line, UTF-8,
each ending in a newline. It is append-only, so a capture cut short by a crash
or a force-quit loses at most its last line and is still readable. There are
three kinds of line, told apart by the `type` key:

| Line | `type` | When |
|---|---|---|
| Header | `"header"` | Always the first line |
| Frame | none (no `type` key) | One per frame received |
| Summary | `"summary"` | The last line, written only on a clean stop |

A capture with no summary line was interrupted. That is a finding in the
analysis, not an error.

## Header

One object on one line. Shown here spread over several lines, with the same
content as the sample capture below.

```json
{
  "type": "header",
  "schema": 2,
  "format": "gnimu-capture-jsonl",
  "sessionId": "11111111-2222-3333-4444-555555555555",
  "startedAt": "2026-11-15T18:00:00.000Z",
  "timeZone": "UTC",
  "device": {
    "name": "Gnimu-CAN 1958745094",
    "peripheralId": "0A1B2C3D",
    "identity": {
      "manufacturer": "Gnimu", "model": "Gnimu-CAN", "serial": "1958745094",
      "firmware": "0.1.0", "hardware": "XIAO ESP32C6"
    },
    "schema": { "v": 1, "d": "Gnimu-CAN", "r": 20, "fill": { "vehicle": 3, "power": 1 } },
    "info": { "v": 1, "build": { "rev": "9c1e4a7", "target": "esp32c6", "utc": "2026-11-10T18:22:05Z" },
              "cfg": { "can_bitrate": 500000 } }
  },
  "app":  { "name": "Gnimu Monitor", "version": "1.2", "build": "1" },
  "host": { "platform": "macOS", "systemVersion": "26", "model": "Mac14,2",
            "lowPowerMode": false, "thermalState": "nominal" },
  "capture": {
    "protocol": "gnimu",
    "unit": "frame",
    "streams": [
      { "name": "frame", "characteristic": "0752D3C3-CEAF-462F-A944-BCC06C57284B", "frameBytes": 140 }
    ],
    "encoding": "base64",
    "timeBase": "seconds since startedAt, monotonic",
    "nominalHz": 20
  }
}
```

- **`capture.protocol`**: `"racebox"` or `"gnimu"`. It decides how the frame bytes
  are decoded.
- **`capture.unit`**: what a frame line holds. `"frame"` means one validated
  frame, after the protocol's own reassembly, so a line is always a whole frame.
  A reader must refuse a unit it doesn't know.
- **`capture.streams`**: the streams the file holds, each with a short `name`, the
  Bluetooth characteristic it came from and the size of one frame. Both protocols
  have one stream today, named `"frame"`. A protocol that splits its data across
  several characteristics would list one stream for each.
- **`device`**: what the device reported about itself when recording began. Every
  part is optional, because the device may not have reported it yet.
  - `identity` is the standard Device Information Service.
  - `schema` and `info` are the Gnimu protocol's Schema and Device info
    characteristics, exactly as the device sent them. With them a capture can be
    replayed with its channel names and settings, without the device.
- **`device.peripheralId`** identifies the device within one install of the app on
  one phone or Mac. It is not a serial number.
- **`capture.nominalHz`**: the frame rate the device said it uses, when it says.

## Frame lines

```json
{"t":0.0500,"c":"frame","d":"<base64 of the frame's bytes>"}
```

- **`t`**: seconds since `startedAt`, from the host's monotonic clock, to the
  frame arriving at the app. It carries Bluetooth timing, so it is not the
  device's own time. Each frame has its own time stamps inside it.
- **`c`**: the stream the frame belongs to, one of the names in `capture.streams`.
  A line naming a stream the header doesn't list is not a valid line.
- **`d`**: the frame's bytes, base64.

## Summary line

```json
{"type":"summary","sessionId":"…","endedAt":"…","durationSeconds":0.15,
 "packets":3,"rawBytes":420,"meanHz":20,"rejected":0,
 "streams":{"frame":{"packets":3,"rawBytes":420}}}
```

`rejected` is the number of notifications the app dropped as not valid frames
while the capture ran. They are not in the file. `streams` has the same counts
per stream.

## Reading a capture

- **Versioning.** A reader requires the same schema number. A file with a lower
  number was written by an older version, and one with a higher number by a newer
  one; both are refused with a message that says so.
- **Unknown content is ignored, not an error.** Keys a reader doesn't know are
  skipped, and so are typed lines (`type` other than `header` and `summary`), so a
  later version can add them without breaking this one. A change that a reader
  couldn't safely skip raises the schema number.
- **Order.** The header comes first, so a reader knows the protocol before it sees
  a frame.

## What a capture contains about you

A capture holds the telemetry from the device, including GNSS positions if the
device has a receiver, so it can show where you were. The header names the
device, including its **serial number**, and the model of the phone or Mac that
recorded it. Check before sharing a capture publicly.

## Sample

A three-frame capture for a Gnimu-CAN device. The header and summary lines are
exactly what the unit tests read, so they stay correct. The frame bytes are
shortened here; a real line holds the whole 140-byte frame in base64.

```
{"app":{"build":"1","name":"Gnimu Monitor","version":"1.2"},"capture":{"encoding":"base64","nominalHz":20,"protocol":"gnimu","streams":[{"characteristic":"0752D3C3-CEAF-462F-A944-BCC06C57284B","frameBytes":140,"name":"frame"}],"timeBase":"seconds since startedAt, monotonic","unit":"frame"},"device":{"identity":{"firmware":"0.1.0","manufacturer":"Gnimu","model":"Gnimu-CAN","serial":"1958745094"},"info":{"build":{"rev":"9c1e4a7","target":"esp32c6","utc":"2026-11-10T18:22:05Z"},"cfg":{"can_bitrate":500000},"v":1},"name":"Gnimu-CAN 1958745094","peripheralId":"0A1B2C3D","schema":{"d":"Gnimu-CAN","fill":{"power":1,"vehicle":3},"r":20,"v":1}},"format":"gnimu-capture-jsonl","host":{"lowPowerMode":false,"model":"Mac14,2","platform":"macOS","systemVersion":"26","thermalState":"nominal"},"schema":2,"sessionId":"11111111-2222-3333-4444-555555555555","startedAt":"2026-11-15T18:00:00.000Z","timeZone":"UTC","type":"header"}
{"t":0.0000,"c":"frame","d":"6AMAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA…"}
{"t":0.0500,"c":"frame","d":"…"}
{"t":0.1000,"c":"frame","d":"…"}
{"durationSeconds":0.15,"endedAt":"2026-11-15T18:00:00.150Z","meanHz":20,"packets":3,"rawBytes":420,"rejected":0,"sessionId":"11111111-2222-3333-4444-555555555555","streams":{"frame":{"packets":3,"rawBytes":420}},"type":"summary"}
```
