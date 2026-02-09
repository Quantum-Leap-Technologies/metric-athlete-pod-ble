# Pod Connector - Bluetooth & Telemetry System

**Pod Connector** is a high-performance Flutter plugin and application logic designed to interface with custom STM32/embedded "Pod" devices. It handles high-frequency BLE telemetry, reliable file transfers, and advanced trajectory data processing.

## Key Features

* **Robust BLE Connectivity:** Auto-connect logic, optimized connection priority, and MTU negotiation.
* **Reliable File Sync:** Custom "Smart Peek" logic filters files on the native side before downloading, saving bandwidth.
* **Background Reliability:** Android Foreground Service with WakeLocks ensures downloads do not fail when the screen turns off.
* **Real-time Visualization:** Streams live accelerometer, gyroscope, and GPS data at 10Hz+.
* **Advanced Data Cleaning:** Implements a 3-Stage Pipeline (Sanity Check -> Linear Interpolation -> Kalman Filter) to reconstruct timelines from lossy BLE data.
* **Session Management:** Auto-clusters raw data into logical "Sessions" based on time gaps.

---

## Architecture

The project uses a **Hybrid Architecture** to balance performance and UI flexibility.

### 1. The Native Engine (Kotlin)
Handles the "heavy lifting" of Bluetooth communication.
* **Packet Reassembly:** Stitches fragmented BLE packets into clean 64-byte records.
* **Strict Header Stripping:** Automatically detects and strips the 9-byte (initial) or 5-byte (subsequent) packet headers to ensure clean payloads.
* **Watchdog:** Automatically kills hanging connections if no data is received for 60s (or if progress stalls at >98%).
* **Smart Peek:** Reads the first 128 bytes of a file to check timestamps. If the file is outside the requested filter range, it aborts the download immediately on the native side.
* **Foreground Service:** Promotes the app process to "User Visible" status to prevent Android OS execution killing.

### 2. The Bridge (Method Channels)
* **Commands (Flutter -> Native):** `connect`, `writeCommand`, `downloadFile`, `requestBatteryExemption`.
* **Streams (Native -> Flutter):**
    * `statusStream`: Connection state (Connecting, Connected, Disconnected).
    * `payloadStream`: Raw byte arrays (Telemetry or File Data).

### 3. The Logic Core (Dart/Riverpod)
* **`PodNotifier`:** The central brain. Manages state, routes messages, and handles the "Dispatch Pattern" for incoming data.
* **`PodProtocolHandler`:** Decodes raw binary payloads into strongly-typed objects (`LiveTelemetry`, `SensorLog`).
* **`TrajectoryFilter`:** A multi-stage post-processing engine that repairs and smooths sensor data.

---

## Protocol Specification

The Pod communicates via a custom binary protocol. All commands use the following structure:
`[Command ID] [Length] [Payload...]`

### Write Commands (App -> Pod)

| Command | Hex | Payload | Description |
| :--- | :--- | :--- | :--- |
| **Stream On/Off** | `0x03` | `0x01` / `0x00` | Toggles live telemetry. |
| **Log On/Off** | `0x04` | `0x01` / `0x00` | Toggles internal SD card logging. |
| **Get File List** | `0x05` | None | Requests list of all files on SD card. |
| **Download File** | `0x06` | `0x20` + `[Name]` | Requests binary stream of specific file. |
| **Delete File** | `0x07` | `0x20` + `[Name]` | Deletes file from SD card. |
| **Cancel Download** | `0x08` | None | Aborts current file download. |
| **Get Settings** | `0x09` | None | Requests Player # and Log Interval. |
| **Set Player #** | `0x0A` | `[Uint8]` | Sets device ID (1-99). |
| **Set Interval** | `0x0B` | `[Uint16]` | Sets logging rate (100-1000ms). |

### Read Messages (Pod -> App)

| Type | Content | Handled By |
| :--- | :--- | :--- |
| `0x01` | **Live Telemetry** | Updates Graph & Live Dashboard. |
| `0x02` | **File List** | Updates File Explorer UI. |
| `0x03` | **File Data** | Chunk of a log file (sent to `BinaryParser`). |
| `0x05` | **Settings** | Updates Config UI. |
| `0xDA` | **File Skipped** | Native "Smart Peek" skipped this file. |

## Data Processing Logic

The raw data from the Pod is often noisy and may contain packet gaps due to BLE interference. We apply a strict **3-Stage Filter** in `TrajectoryFilter.dart` before analysis.

### Stage -1: Physical validity check.
Before processing, every row is scanned for physical validity. Rows are strictly deleted if:
* **Binary Corruption:** Values contain `NaN` or `Infinity`.
* **Null Island:** Latitude/Longitude are both `0.0`.
* **Physics Violations:**
    * Acceleration > 200 m/s^2 (approx 20G).
    * Rotation > 40 rad/s (approx 2300 deg/s).
    * Speed > 80 km/h (Hardware/GPS Glitch cap).
* **Zero-Fill Glitch:** All sensors read exactly `0.0`.

### Stage 0: Strict Data Repair (Linear Interpolation)
This stage restores the "Heartbeat" of the data. It detects gaps in the hardware `PacketID` sequence.
* **Gap Detection:** Calculates the integer number of steps missed between two packets based on the hardware median step size (typically 100).
* **Synthetic Filling:** If packets are missing (e.g., ID 100 -> ID 103), the system generates synthetic rows (ID 101, 102) using linear interpolation for all 12 sensor fields.
* **Monotonic Timeline:** This ensures the Kalman Filter receives a mathematically perfect timeline, preventing velocity spikes caused by time jumps.

### Stage 1 & 2: Hybrid Filtering (Kalman + RTS)
* **Variance-Tuned Kalman Filter:**
    * **Moving:** Low Variance -> Trust GPS more.
    * **Stopped:** High Variance -> Trust GPS less (locks position).
* **RTS Smoother:** Runs a backward pass to eliminate phase lag introduced by the forward filter.

## Setup & Installation

### Android Permissions
This plugin requires the following permissions in `AndroidManifest.xml` to support Android 13+ BLE scanning and background services.

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />
```
### Dependencies

**State & Logic**
* `flutter_riverpod`: Internal state management for the plugin logic.
* `plugin_platform_interface`: Core infrastructure for federated plugins.
* `intl`: Date and time formatting for log timestamps.

**System & Hardware**
* `permission_handler`: Manages runtime permissions (Bluetooth, Location, Storage, Battery optimization).
* `path_provider`: Accesses file system paths for saving logs.
* `shared_preferences`: Persists user settings (Player ID, Log Interval) across restarts.

**UI & Interaction**
* `file_picker`: Allows browsing and selecting local files (for USB/Import features).

---

## Project Structure

```text
lib/
├── models/
│   ├── live_data_model.dart       # Decodes 72-byte live packet
│   ├── pod_state_model.dart       # Riverpod State (Scanning, Connected, etc.)
│   ├── sensor_log_model.dart      # Decodes 64-byte file record
│   ├── session_block_model.dart   # Logical "Session" groupings
│   └── usb_bounds_model.dart      # USB-specific logic
├── providers/
│   └── pod_notifier.dart          # Main Logic Controller (The Brain)
├── services/
│   ├── storage_service.dart       # CSV Saving & Parsing
│   └── usb_file_processor.dart    # USB File Handling Logic
├── utils/
│   ├── logs_binary_parser.dart    # Byte-level extraction logic
│   ├── pod_protocol_decoder.dart  # Binary Packet Router
│   ├── session_cluster.dart       # Logic to split runs by time gaps
│   ├── trajectory_filter.dart     # 3-Stage Data Repair & Filter
│   └── usb_file_predictor.dart    # USB Prediction Logic
├── pod_connector_method_channel.dart  # Native Bridge Implementation
├── pod_connector_platform_interface.dart # Native Bridge Contract
└── pod_connector.dart             # Main Plugin Entry

android/src/main/kotlin/com/example/pod_connector/
├── PodConnectorPlugin.kt          # Native Engine (Buffers, Watchdog)
└── PodForegroundService.kt        # Background Life Support
```
---

## Known Issues

1.  **Download Hangs:**
    * *Issue:* Packet loss can cause the download loop to wait forever if the Pod stops transmitting.
    * *Fix:* A Watchdog timer in Kotlin forces the stream to close if no bytes are received for 60s, or if progress exceeds 98% but stalls for >2.5s.
2.  **Filter Output Shifts:**
    * *Observation:* Filtered data graphs may appear shifted to the left compared to Raw data.
    * *Cause:* The filter drops stationary data at the start of a session.
    * *Verification:* Align data by `PacketID` rather than array index to compare inputs vs outputs accurately.