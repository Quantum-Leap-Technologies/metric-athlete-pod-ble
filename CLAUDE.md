# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`metric_athlete_pod_ble` is a Flutter plugin that communicates with custom STM32-based GPS/IMU "Pod" hardware devices over Bluetooth Low Energy. It handles scanning, connecting, live telemetry streaming, reliable file downloads, and a multi-stage signal processing pipeline that converts noisy BLE sensor data into clean athletic performance metrics.

This plugin is consumed by the main Metric Athlete Flutter app as a path dependency at `../metric-athlete-pod-ble`.

## Commands

```bash
flutter analyze                          # Lint / static analysis
flutter test                             # Run all tests
flutter test test/pod_connector_test.dart # Run a single test
cd example && flutter run                # Run example/test harness app
```

## Architecture

### Three-Layer Design

**1. Native Engine** (platform-specific BLE)
- Android: `android/.../PodConnectorPlugin.kt` + `PodForegroundService.kt` - Handles GATT connections, packet reassembly, Smart Peek filtering, watchdog timer, and foreground service for background downloads
- iOS/macOS: `ios/Classes/PodBLECore.swift` + `PodConnectorPlugin.swift` (shared between iOS and macOS via identical `macos/Classes/` files) - CoreBluetooth CBCentralManager/CBPeripheral delegation
- Windows: `windows/pod_ble_core.cpp` + `pod_connector_plugin.cpp`

**2. Method Channel Bridge** (`lib/pod_connector_platform_interface.dart` + `lib/pod_connector_method_channel.dart`)
- Commands (Flutter -> Native): `startScan`, `stopScan`, `connect`, `disconnect`, `writeCommand`, `downloadFile`, `cancelDownload`, `requestBatteryExemption`
- Streams (Native -> Flutter): `statusStream` (connection state), `scanResultStream` (discovered devices), `payloadStream` (raw bytes for telemetry and file data)
- Channel names: `com.example.pod_connector/methods`, `/status`, `/scan`, `/payload`

**3. Dart Logic Core** (`lib/`)
- `providers/pod_notifier.dart` - Central state manager (`Notifier<PodState>`). Routes decoded messages, orchestrates scanning/connection/sync/recording, exposes state to UI via `podNotifierProvider`
- `utils/pod_protocol_decoder.dart` - Decodes raw binary payloads by message type (0x01=live telemetry, 0x02=file list, 0x03=file data, 0x05=settings, 0xDA=file skipped)
- `utils/logs_binary_parser.dart` - Parses 64-byte binary records from `.bin` files into `SensorLog` objects with byte-level sync recovery
- `services/storage_service.dart` - CSV read/write for session data persistence
- `utils/pod_logger.dart` - Structured diagnostic logging with ring buffer (500 entries), severity levels (debug/info/warn/error), category filtering, and optional external listener hook

### Binary Protocol

All pod communication uses a custom binary protocol: `[Command ID] [Length] [Payload...]`

Key commands (App -> Pod): `0x03` stream on/off, `0x04` log on/off, `0x05` get file list, `0x06` download file, `0x07` delete file, `0x08` cancel download, `0x09` get settings, `0x0A` set player number, `0x0B` set log interval.

**Binary record format** (64 bytes, Little Endian): KernelTick(4) | Year(2) | Month(1) | Day(1) | Hour(1) | Min(1) | Sec(1) | Ms(2) | Lat(4) | Lon(4) | Speed(4) | AccelXYZ(12) | GyroXYZ(12) | FiltAccelXYZ(12) | Pad(3)

**Live telemetry format** (72 bytes): KernelTick(4) | Battery(4) | Accel(12) | Gyro(12) | FiltGravity(12) | GpsFix(1) | Time(9) | Lat(4) | Lon(4) | FixQuality(1) | Satellites(1) | Speed(4) | Course(4)

### Data Processing Pipeline

The `FilterPipeline` (`lib/utils/filter_pipeline.dart`) orchestrates all stages and is designed to run via `compute()` isolate:

1. **Stage -1 (Sanity Check)** in `TrajectoryFilter` - Deletes physically impossible data: NaN/Infinity, null island (0,0), accel > 200 m/s^2, gyro > 40 rad/s, speed > 80 km/h, all-zero sensor readings
2. **Stage 0 (Gap Repair)** in `TrajectoryFilter` - Detects gaps via hardware PacketID sequence, determines kernel step size from median of first 20 diffs, fills gaps < 500 steps via linear interpolation to restore monotonic 100ms timeline. Computes health score (0-100%)
3. **Stage 1-2 (Kalman + RTS)** in `TrajectoryFilter._HybridTrajectoryPipeline` - Variance-tuned Kalman filter (moving vs stationary modes), innovation gating to reject GPS teleports, backward RTS smoother to eliminate phase lag. Motion latch requires ~2s sustained movement before starting
4. **Stage 3 (Butterworth)** in `FilterPipeline` - 2nd-order Butterworth low-pass on IMU channels (5Hz cutoff, 10Hz sampling) with zero-phase forward-backward filtering
5. **Stage 4 (Outlier Rejection)** in `FilterPipeline` - Speed-based GPS outlier rejection using Haversine distance checks per 100ms interval

Additional processing:
- `SessionClusterer` - Splits logs into sessions using 10-minute gap threshold, filters sessions < 5 minutes
- `StatsCalculator` - Computes `SessionStats` with speed zones (Resting/Walking/Jogging/Running/Sprinting), player load, impacts, HMLD, fatigue index, and 30+ metrics. Resamples to 1Hz for GPS calculations

### Key Models

- `SensorLog` - 64-byte binary record: packetId, timestamp, lat/lon/speed, accelXYZ, gyroXYZ, filteredAccelXYZ
- `LiveTelemetry` - 72-byte live stream: kernelTick, battery, accelerometer/gyroscope/filteredGravity (Vector3), GPS data, fix quality
- `PodState` - Immutable state for UI: scanning, connection, files, telemetry history, recording, settings, raw clusters, lastRssi (BLE signal strength), clockDriftMs (pod vs device clock)
- `SessionStats` - 30+ computed metrics matching the `session_data` database table, with `toMap()`/`fromMap()` for GraphQL
- `SessionBlock` - Clustered session with start/end times, logs, and estimated stats

### Native-Specific Behavior

**Android**: Uses Foreground Service + WakeLock to prevent OS from killing BLE during downloads. Dedicated processing thread (THREAD_PRIORITY_URGENT_AUDIO) drains packet queue separately from GATT callback thread. Watchdog kills connections after 60s inactivity or 5s stall above 98% progress.

**iOS/macOS**: `PodBLECore` is a shared Swift class used by both platforms. Packet reassembly and Smart Peek run on a dedicated `bleQueue` (DispatchQueue). No foreground service equivalent; relies on `Info.plist` background BLE mode.

**Smart Peek** (native-side optimization): Reads first 128 bytes of a download to check timestamps. If the file falls outside the requested date range, sends an abort (0x08) command immediately, saving bandwidth.

## Key Conventions

- State management uses Riverpod v3 (`flutter_riverpod: ^3.0.3`) with `Notifier<PodState>` pattern (not code generation)
- The main Flutter app (`metric_athlete_app`) uses Riverpod v2 with `flutter_riverpod: ^2.5.1` - the example app pins v2 for compatibility. Do NOT upgrade the main app to v3
- Heavy computation (`TrajectoryFilter.process`, `StatsCalculator.analyze`) must run via `compute()` isolate to avoid blocking the UI thread
- BLE UUIDs are hardcoded to match STM32 firmware: Service `761993fb-...`, Notify `5e0c4072-...`, Write `fb4a9352-...`
- All binary data is Little Endian
- The barrel file `lib/metric_athlete_pod_ble.dart` exports all public APIs - import via `package:metric_athlete_pod_ble/metric_athlete_pod_ble.dart`
- CSV format: `Timestamp,KernelCount,Lat,Lon,Speed_Kph,AccelX,AccelY,AccelZ,GyroX,GyroY,GyroZ,FiltAccelX,FiltAccelY,FiltAccelZ`
- Filter thresholds are tuned for rugby athletics (max 45 km/h sprint, 16G accelerometer, 5G impact threshold)
- PodLogger categories: `ble` (connections/scanning), `sync` (file downloads/processing), `protocol` (binary decoding), `clock` (drift detection)
