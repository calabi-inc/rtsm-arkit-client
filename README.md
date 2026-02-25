# Calabi Lens

This repository (`rtsm-arkit-client`) contains the client app for Calabi Lens.

ARKit sensor streaming app for the RTSM ecosystem. Calabi Lens captures RGB frames, LiDAR depth (optional), camera pose, and intrinsics from an iPhone and streams them in real time over WebSocket to a server on the local network.

**Streams:** RGB image, depth map (optional), 6-DoF camera pose (T\_wc), camera intrinsics, and ARKit tracking state.

**Platform:** iOS 16+, iPhone, Swift / SwiftUI.

## Requirements

| Requirement | Details |
|---|---|
| Xcode | 15+ |
| Device | iPhone with ARKit support, iOS 16+ |
| LiDAR | Optional — depth is auto-detected. Non-LiDAR devices stream RGB + pose only. |
| Server | Running on the same LAN Wi-Fi (5 GHz recommended for stability) |

No third-party Swift dependencies. The project uses only Apple frameworks.

## How to Run

1. Clone the repository and open `Calabi Lens/Calabi Lens.xcodeproj` in Xcode.
2. Select your iPhone as the run destination (ARKit requires a physical device).
3. Build and run (`Cmd+R`).
4. Grant camera permission when prompted on first launch.
5. On the main screen, tap the server URL row in the **Network** section to open the Network Configuration sheet. Enter the server WebSocket URL (e.g. `ws://192.168.1.100:8765/stream`) and tap **Done**.
6. Tap **Connect** — wait for the top-left pill to turn green.
7. Tap the **Record** button (shutter icon) to start streaming.
8. Tap the **Stop** button (square icon) to end the session. The queue flushes before the connection closes.

## Configuration (Settings Sheet)

Tap the gear icon (top-right) to open the Streaming Settings sheet. Settings persist across launches and are locked for the duration of a recording session.

| Setting | Options | Default | Notes |
|---|---|---|---|
| Capture Rate | 5 / 10 / 15 / 20 Hz | **10 Hz** | Slider with discrete ticks |
| RGB Format | JPEG, PNG, Raw BGRA | **JPEG** | JPEG is fastest encode and lowest bandwidth |
| JPEG Quality | 50 – 95 | **75** | Shown only when RGB Format = JPEG |
| Depth Inclusion | Auto, On, Off | **Auto** | Auto includes depth when LiDAR is available |
| Depth Format | uint16 mm, float32 m, PNG-uint16 | **uint16 mm** | `depth_scale` is derived automatically |
| Pose Format | 4x4 column-major matrix, Quaternion + translation | **4x4 matrix** | 4x4 is most compatible with Open3D / RTAB-Map / OpenCV |

**Depth scale:** `0.001` for uint16 mm and PNG-uint16, `1.0` for float32 m. Included in every frame header.

**Depth inclusion behavior:**
- **Auto** — depth is included when the device has LiDAR; omitted otherwise.
- **On** — same as Auto (depth is included when available; stream continues without depth on non-LiDAR devices).
- **Off** — depth is never encoded or sent, even on LiDAR devices.

## Wire Format

Each frame is transmitted as a **single binary WebSocket message** with three length-prefixed sections:

```
Offset          Size            Field
──────          ────            ─────
0               4 bytes         json_len    (little-endian uint32)
4               json_len        JSON header (UTF-8 encoded)
4+json_len      4 bytes         rgb_len     (little-endian uint32)
8+json_len      rgb_len         RGB image data
8+json_len      4 bytes         depth_len   (little-endian uint32; 0 = no depth)
 +rgb_len
12+json_len     depth_len       Depth data
 +rgb_len
```

One message = one complete frame. The receiver reads `json_len`, parses JSON, reads `rgb_len` bytes, then reads `depth_len` bytes (which may be 0).

### JSON Header Fields

Every frame header is a JSON object with the following fields:

| Field | Type | Description |
|---|---|---|
| `session_id` | `string` | UUID identifying the recording session |
| `frame_id` | `uint64` | Monotonic counter, resets at Record start (0-indexed) |
| `timestamp_ns` | `uint64` | `ARFrame.timestamp * 1e9` (device monotonic clock, nanoseconds) |
| `unix_timestamp` | `float64` | `Date().timeIntervalSince1970` (wall clock, seconds) |
| `rgb_format` | `string` | `"jpeg"`, `"png"`, or `"bgra"` |
| `rgb_width` | `int` | Pixel buffer width |
| `rgb_height` | `int` | Pixel buffer height |
| `image_orientation` | `string` | Orientation of the RGB buffer as sent (always `"landscapeRight"` in v0.1). Pixels are **not** rotated; the receiver rotates if desired. |
| `jpeg_quality` | `float64?` | Present only when `rgb_format == "jpeg"` (0–100 scale) |
| `depth_format` | `string?` | `"uint16_mm"`, `"float32_m"`, `"png_uint16"`, or `null` if no depth |
| `depth_width` | `int?` | Depth buffer width (may differ from RGB). `null` if no depth. |
| `depth_height` | `int?` | Depth buffer height. `null` if no depth. |
| `depth_scale` | `float64?` | `0.001` (uint16 mm / PNG-uint16) or `1.0` (float32 m). `null` if no depth. |
| `fx` | `float64` | Camera intrinsic: focal length x (pixels) |
| `fy` | `float64` | Camera intrinsic: focal length y (pixels) |
| `cx` | `float64` | Camera intrinsic: principal point x (pixels) |
| `cy` | `float64` | Camera intrinsic: principal point y (pixels) |
| `intrinsics_width` | `int` | Reference image width for the intrinsics |
| `intrinsics_height` | `int` | Reference image height for the intrinsics |
| `pose_format` | `string` | `"matrix4x4_col_major"` or `"quat_translation"` |
| `T_wc` | `[float64]` | Camera-to-world transform. 16 elements (4x4 column-major) or 7 elements `[qx, qy, qz, qw, tx, ty, tz]`. |
| `tracking_state` | `string` | `"normal"`, `"limited"`, or `"not_available"` |
| `tracking_reason` | `string?` | Reason when Limited: `"initializing"`, `"excessive_motion"`, `"insufficient_features"`, `"relocalizing"`. `null` when Normal or Not Available. |
| `pose_source` | `string` | Always `"arkit_vio"` in v0.1 |

### Example JSON Header

```json
{
  "session_id": "A3F2C8D1-4B5E-4A2F-9C1D-7E8F6A3B2C1D",
  "frame_id": 42,
  "timestamp_ns": 1234567890123,
  "unix_timestamp": 1700000000.123,
  "rgb_format": "jpeg",
  "rgb_width": 1920,
  "rgb_height": 1440,
  "image_orientation": "landscapeRight",
  "jpeg_quality": 75.0,
  "depth_format": "uint16_mm",
  "depth_width": 256,
  "depth_height": 192,
  "depth_scale": 0.001,
  "fx": 1597.72,
  "fy": 1597.72,
  "cx": 960.0,
  "cy": 720.0,
  "intrinsics_width": 1920,
  "intrinsics_height": 1440,
  "pose_format": "matrix4x4_col_major",
  "T_wc": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0.1,0.2,0.3,1],
  "tracking_state": "normal",
  "tracking_reason": null,
  "pose_source": "arkit_vio"
}
```

### Depth Encoding Rules

| Format | Encoding | Byte order | Invalid values | Valid range |
|---|---|---|---|---|
| `uint16_mm` | Raw uint16 buffer, row-major | Little-endian | `0` (NaN / Inf / ≤0 m) | 1–65535 mm (`min(65535, round(meters * 1000))`) |
| `float32_m` | Raw float32 buffer, row-major | Little-endian | `0.0` (NaN / Inf / ≤0 m) | Positive meters |
| `png_uint16` | PNG-encoded 16-bit grayscale image | Little-endian uint16 values in mm | `0` | 1–65535 mm |

### RGB Orientation Note

The `image_orientation` field (always `"landscapeRight"` in v0.1) describes the orientation of the pixel buffer as captured by ARKit. Pixels are sent **as-is** — no rotation is applied. The receiver should use this field to rotate or transpose the image if a specific display orientation is desired.

## Health Metrics

The Health & Telemetry panel on the main screen shows live metrics during streaming:

| Metric | Description |
|---|---|
| **RTT** | Round-trip time in milliseconds, measured via WebSocket ping/pong every 2 seconds |
| **Throughput** | Bytes sent per second, computed over a rolling 1-second window |
| **Dropped** | Frames dropped due to send-queue backpressure. The send queue holds up to 10 frames; when full, the oldest frame is dropped. Counter is cumulative for the session; turns amber while drops are actively occurring. |
| **Queue** | Current number of frames waiting in the send queue (0–10) |
| **Last Send** | Timestamp of the last successfully sent frame |
| **Tracking** | ARKit tracking state: Normal (green), Limited (amber with reason), Not Available (red) |

Metrics freeze at their last values when recording stops, so you can review session stats.

## Receiver Stubs

Two minimal Python receiver utilities are included for testing and development:

- `receiver_server_stub.py` runs a WebSocket **server** that accepts connections from Calabi Lens.
- `receiver_stub.py` runs a WebSocket **client** that connects to an existing stream endpoint.

```bash
pip install websockets

# Server mode (accepts app connection)
python receiver_server_stub.py
python receiver_server_stub.py --host 0.0.0.0 --port 8765 --path /stream

# Client mode (connects to an existing server endpoint)
python receiver_stub.py                                # default: ws://192.168.1.100:8765/stream
python receiver_stub.py ws://192.168.1.100:9000/stream
```

Both scripts parse the same binary frame format and print frame metadata (frame ID, timestamp, tracking state, RGB size, depth size), with periodic throughput summaries.

## Future Extensions

The `pose_source` field is always `"arkit_vio"` in v0.1, indicating raw ARKit visual-inertial odometry. The `tracking_state` field is included in every frame to support future corrected-pose swap-in workflows:

- A server-side SLAM system (e.g. RTAB-Map, loop closure pipeline) could consume the raw VIO poses and return corrected poses.
- A future version of the app could accept corrected poses and set `pose_source` to a different value (e.g. `"rtabmap_corrected"`), allowing downstream consumers to distinguish raw VIO from loop-closed poses.
- The `tracking_state` and `tracking_reason` fields let the receiver detect and handle degraded tracking conditions (e.g. skip frames where tracking is limited or not available).
