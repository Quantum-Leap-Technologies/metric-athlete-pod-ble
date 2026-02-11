# Metric Athlete Pod BLE - Bluetooth & Telemetry System

**metric_athlete_pod_ble** is a high-performance Flutter plugin designed to interface with custom STM32/embedded GPS/IMU "Pod" devices over Bluetooth Low Energy. It handles high-frequency BLE telemetry, reliable file transfers, advanced trajectory data processing, and comprehensive session analytics.

**Supported Platforms:** Android, iOS, macOS, Windows

## Key Features

* **Robust BLE Connectivity:** Auto-connect logic, optimized connection priority, and MTU negotiation.
* **Reliable File Sync:** Custom "Smart Peek" logic filters files on the native side before downloading, saving bandwidth.
* **Background Reliability:** Android Foreground Service with WakeLocks ensures downloads do not fail when the screen turns off.
* **Real-time Visualization:** Streams live accelerometer, gyroscope, and GPS data at 10Hz+.
* **Advanced Data Cleaning:** Implements a 5-Stage Pipeline (Sanity Check -> Linear Interpolation -> Kalman+RTS -> Butterworth Low-Pass -> Outlier Rejection) to reconstruct timelines from lossy BLE data.
* **Session Management:** Auto-clusters raw data into logical "Sessions" based on time gaps.
* **Session Analytics:** Computes 30+ performance metrics including speed zones, player load, impacts, HMLD, fatigue index, and metabolic power estimates.

---

## Architecture

The project uses a **Hybrid Architecture** to balance performance and UI flexibility.

### 1. The Native Engine (Platform-Specific BLE)
Handles the "heavy lifting" of Bluetooth communication on each platform.

**Android** (`android/.../PodConnectorPlugin.kt` + `PodForegroundService.kt`):
* **Packet Reassembly:** Stitches fragmented BLE packets into clean 64-byte records using a dedicated processing thread (`THREAD_PRIORITY_URGENT_AUDIO`).
* **Strict Header Stripping:** Automatically detects and strips the 9-byte (initial) or 5-byte (subsequent) packet headers to ensure clean payloads.
* **Watchdog:** Automatically kills hanging connections if no data is received for 60s (or if progress stalls at >98%).
* **Smart Peek:** Reads the first 128 bytes of a file to check timestamps. If the file is outside the requested filter range, it aborts the download immediately on the native side.
* **Foreground Service:** Promotes the app process to "User Visible" status to prevent Android OS execution killing.

**iOS/macOS** (`ios/Classes/PodBLECore.swift` + `PodConnectorPlugin.swift`, shared with `macos/Classes/`):
* Shared `PodBLECore` class using CoreBluetooth (`CBCentralManager`/`CBPeripheral`).
* Packet reassembly and Smart Peek run on a dedicated `bleQueue` (DispatchQueue).
* Communicates to Flutter via `PodBLECoreDelegate` protocol.

**Windows** (`windows/pod_ble_core.cpp` + `pod_connector_plugin.cpp`):
* C++ implementation using Windows BLE APIs.

### 2. The Bridge (Method Channels)
* **Commands (Flutter -> Native):** `startScan`, `stopScan`, `connect`, `disconnect`, `writeCommand`, `downloadFile`, `cancelDownload`, `requestBatteryExemption`.
* **Streams (Native -> Flutter):**
    * `statusStream`: Connection state (Connecting, Connected, Disconnected).
    * `scanResultStream`: Discovered BLE devices (name and ID).
    * `payloadStream`: Raw byte arrays (Telemetry or File Data).
* **Channel Names:** `com.example.pod_connector/methods`, `/status`, `/scan`, `/payload`.

### 3. The Logic Core (Dart/Riverpod)
* **`PodNotifier`:** The central brain. Manages state, routes messages, and handles the "Dispatch Pattern" for incoming data.
* **`PodProtocolHandler`:** Decodes raw binary payloads into strongly-typed objects (`LiveTelemetry`, `SensorLog`).
* **`FilterPipeline`:** Unified orchestrator for all data processing stages (runs via `compute()` isolate).
* **`TrajectoryFilter`:** Multi-stage post-processing engine that repairs and smooths sensor data (Sanity Check, Gap Repair, Kalman+RTS).
* **`ButterworthFilter`:** 2nd-order zero-phase low-pass filter for IMU noise reduction.
* **`StatsCalculator`:** Computes 30+ session metrics (distances, speed zones, impacts, player load, metabolic power).

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

## Data Processing Pipeline

The raw data from the Pod is often noisy and may contain packet gaps due to BLE interference. The `FilterPipeline` orchestrates a **5-Stage Pipeline** across `TrajectoryFilter`, `ButterworthFilter`, and outlier rejection logic. All stages run via `compute()` isolate to avoid blocking the UI.

### Stage -1: Physical Validity Check (Sanity)
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
* **Health Score:** Computes a 0-100% data quality score based on the ratio of real vs. synthetic packets.

### Stage 1 & 2: Hybrid Filtering (Kalman + RTS)
* **Variance-Tuned Kalman Filter:**
    * **Moving:** Low Variance -> Trust GPS more.
    * **Stopped:** High Variance -> Trust GPS less (locks position).
* **Innovation Gating:** Rejects GPS "teleport" updates exceeding 3 standard deviations.
* **Motion Latch:** Requires ~2 seconds of sustained movement before activating the filter, preventing drift while stationary.
* **RTS Smoother:** Runs a backward pass to eliminate phase lag introduced by the forward filter.

### Stage 3: Butterworth Low-Pass (IMU Smoothing)
* **2nd-Order Zero-Phase Filter:** Applied to all 6 IMU channels (accelXYZ, gyroXYZ) using forward-backward filtering (`filtfilt`) to eliminate phase lag.
* **Cutoff:** 5Hz at 10Hz sampling rate. Signal padding with reflection reduces edge artifacts.

### Stage 4: Speed-Based Outlier Rejection
* **Haversine Distance Check:** If GPS distance between consecutive 100ms samples exceeds the configurable threshold (default 1.0m), the position is replaced with a speed-inferred interpolation.

### Session Analytics (`StatsCalculator`)
After filtering, the `StatsCalculator` computes 30+ metrics from the clean data:
* **Speed Zones:** Resting (<1.8), Walking (<7), Jogging (<18), Running (<25), Sprinting (>25 km/h).
* **Distance Metrics:** Total, active, sprint, HSR (high-speed running), explosive.
* **Load Metrics:** Player load, load score, session intensity, fatigue index.
* **Impact Analysis:** Total impacts, max G-force, high-intensity events, impacts per speed zone.
* **Metabolic Metrics** (weight-dependent): HMLD (High Metabolic Load Distance), energy expenditure, momentum peak, power play count.
* **Data Quality:** GPS quality percentage, data gap count, health score.

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
│   ├── live_data_model.dart       # Decodes 72-byte live packet (LiveTelemetry, Vector3)
│   ├── pod_state_model.dart       # Riverpod State (Scanning, Connected, etc.)
│   ├── sensor_log_model.dart      # Decodes 64-byte file record (SensorLog)
│   ├── session_block_model.dart   # Logical "Session" groupings
│   ├── session_stats_model.dart   # 30+ computed metrics (SessionStats)
│   ├── stats_input_model.dart     # Input config for StatsCalculator
│   └── usb_bounds_model.dart      # USB-specific logic
├── providers/
│   └── pod_notifier.dart          # Main Logic Controller (The Brain)
├── services/
│   ├── storage_service.dart       # CSV Saving & Parsing
│   └── usb_file_processor.dart    # USB File Handling Logic
├── utils/
│   ├── butterworth_filter.dart    # 2nd-order zero-phase low-pass filter
│   ├── filter_pipeline.dart       # Unified pipeline orchestrator (all 5 stages)
│   ├── kalman_gps_filter.dart     # Simple 2D Kalman for quick GPS smoothing
│   ├── logs_binary_parser.dart    # Byte-level extraction logic
│   ├── pod_protocol_decoder.dart  # Binary Packet Router
│   ├── session_cluster.dart       # Logic to split runs by time gaps
│   ├── stats_calculator.dart      # Session analytics engine (30+ metrics)
│   ├── trajectory_filter.dart     # Sanity + Gap Repair + Kalman+RTS Filter
│   └── usb_file_predictor.dart    # USB Prediction Logic
├── metric_athlete_pod_ble.dart    # Barrel file (all public exports)
├── pod_connector_method_channel.dart  # Native Bridge Implementation
└── pod_connector_platform_interface.dart # Native Bridge Contract

android/src/main/kotlin/com/example/pod_connector/
├── PodConnectorPlugin.kt          # Native Engine (Buffers, Watchdog, Smart Peek)
└── PodForegroundService.kt        # Background Life Support (WakeLock)

ios/Classes/                        # Also mirrored in macos/Classes/
├── PodBLECore.swift               # CoreBluetooth BLE logic (shared iOS/macOS)
└── PodConnectorPlugin.swift       # Flutter bridge (MethodChannel + EventChannels)

windows/
├── pod_ble_core.cpp               # Windows BLE implementation
└── pod_connector_plugin.cpp       # Flutter bridge
```
---

## Known Issues

1.  **Download Hangs:**
    * *Issue:* Packet loss can cause the download loop to wait forever if the Pod stops transmitting.
    * *Fix:* A Watchdog timer on each native platform forces the stream to close if no bytes are received for 60s, or if progress exceeds 98% but stalls for >2.5s.
2.  **Filter Output Shifts:**
    * *Observation:* Filtered data graphs may appear shifted to the left compared to Raw data.
    * *Cause:* The filter drops stationary data at the start of a session.
    * *Verification:* Align data by `PacketID` rather than array index to compare inputs vs outputs accurately.