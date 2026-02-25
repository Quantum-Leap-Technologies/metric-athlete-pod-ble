# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`metric_athlete_pod_ble` is a Flutter plugin that communicates with custom STM32-based GPS/IMU "Pod" hardware devices over Bluetooth Low Energy. It handles scanning, connecting, live telemetry streaming, reliable file downloads, and a multi-stage signal processing pipeline that converts noisy BLE sensor data into clean athletic performance data.

**The plugin does NOT compute analytics.** All session metrics (speed zones, player load, metabolic power, etc.) are computed by the main app's `MetricsCalculator`. The plugin's responsibility ends at delivering clean, filtered `SensorLog` data and clustered sessions.

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
- Android: `PodConnectorPlugin.kt` + `PodForegroundService.kt` — GATT connections, packet reassembly, Smart Peek, watchdog, foreground service
- iOS/macOS: `PodBLECore.swift` + `PodConnectorPlugin.swift` (shared) — CoreBluetooth delegation
- Windows: `pod_ble_core.cpp` + `pod_connector_plugin.cpp`

**2. Method Channel Bridge**
- Commands (Flutter -> Native): `startScan`, `stopScan`, `connect`, `disconnect`, `writeCommand`, `downloadFile`, `cancelDownload`, `requestBatteryExemption`
- Streams (Native -> Flutter): `statusStream`, `scanResultStream`, `payloadStream`
- Channel names: `com.example.pod_connector/methods`, `/status`, `/scan`, `/payload`

**3. Dart Logic Core** (`lib/`)
- `providers/pod_notifier.dart` — Central state manager (`Notifier<PodState>`)
- `utils/pod_protocol_decoder.dart` — Decodes raw binary payloads by message type
- `utils/logs_binary_parser.dart` — Parses 64-byte binary records into `SensorLog` objects
- `services/storage_service.dart` — CSV read/write for session data persistence
- `utils/pod_logger.dart` — Structured diagnostic logging with ring buffer (500 entries)

### Binary Protocol

All pod communication uses: `[Command ID] [Length] [Payload...]`

Key commands (App -> Pod): `0x03` stream on/off, `0x04` log on/off, `0x05` get file list, `0x06` download file, `0x07` delete file, `0x08` cancel download, `0x09` get settings, `0x0A` set player number, `0x0B` set log interval.

**Binary record format** (64 bytes, Little Endian): KernelTick(4) | Year(2) | Month(1) | Day(1) | Hour(1) | Min(1) | Sec(1) | Ms(2) | Lat(4) | Lon(4) | Speed(4) | AccelXYZ(12) | GyroXYZ(12) | FiltAccelXYZ(12) | Pad(3)

**Live telemetry format** (72 bytes): KernelTick(4) | Battery(4) | Accel(12) | Gyro(12) | FiltGravity(12) | GpsFix(1) | Time(9) | Lat(4) | Lon(4) | FixQuality(1) | Satellites(1) | Speed(4) | Course(4)

### Data Processing Pipeline

The `FilterPipeline` (`lib/utils/filter_pipeline.dart`) orchestrates all stages via `compute()` isolate:

1. **Sanity Check** — Deletes physically impossible data (NaN, null island, accel > 200 m/s², speed > 80 km/h)
2. **Gap Repair** — Detects gaps via hardware PacketID, fills < 500 steps via linear interpolation, computes health score
3. **Kalman + RTS** — Variance-tuned Kalman filter with innovation gating, backward RTS smoother
4. **Butterworth** — 2nd-order zero-phase low-pass on IMU channels (5Hz cutoff, 10Hz sampling)
5. **Outlier Rejection** — Speed-based GPS outlier rejection using Haversine distance checks

Additional processing:
- `SessionClusterer` — Splits logs into sessions using 10-minute gap threshold, filters sessions < 5 minutes

### Key Models

- `SensorLog` — 64-byte binary record: packetId, timestamp, lat/lon/speed, accelXYZ, gyroXYZ, filteredAccelXYZ
- `LiveTelemetry` — 72-byte live stream: kernelTick, battery, accelerometer/gyroscope/filteredGravity, GPS data
- `PodState` — Immutable state for UI: scanning, connection, files, telemetry, recording, settings, clusters, RSSI, clockDrift
- `SessionBlock` — Clustered session with start/end times, logs, and metadata

## Key Conventions

- State management uses Riverpod v3 (`flutter_riverpod: ^3.0.3`) with `Notifier<PodState>` pattern (not code generation)
- The main Flutter app uses Riverpod v2 (`flutter_riverpod: ^2.5.1`) — do NOT upgrade the main app to v3
- Heavy computation (`TrajectoryFilter.process`, `FilterPipeline`) must run via `compute()` isolate
- BLE UUIDs are hardcoded to match STM32 firmware: Service `761993fb-...`, Notify `5e0c4072-...`, Write `fb4a9352-...`
- All binary data is Little Endian
- The barrel file `lib/metric_athlete_pod_ble.dart` exports all public APIs
- CSV format: `Timestamp,KernelCount,Lat,Lon,Speed_Kph,AccelX,AccelY,AccelZ,GyroX,GyroY,GyroZ,FiltAccelX,FiltAccelY,FiltAccelZ`
- Filter thresholds are tuned for rugby athletics (max 45 km/h sprint, 16G accelerometer, 5G impact threshold)
- PodLogger categories: `ble`, `sync`, `protocol`, `clock`
