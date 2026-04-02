import 'dart:typed_data';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/utils/pod_logger.dart';

/// Class used to parse downloaded .bin file [rawBytes] into [SensorLog] objects.
/// The [rawBytes] are expected to be in Little Endian format.
///
/// Supports three packet sizes:
/// - **64 bytes** — original HTS firmware (61 bytes data + 3 bytes padding)
/// - **61 bytes** — Proewe firmware (no padding)
/// - **47 bytes** — V3.6 firmware (v01 log format: uint16 speed, no filtered accel)
///
/// The packet size is auto-detected from the first two valid headers.
class BinaryParser {
  /// Padded packet size (original HTS firmware).
  static const int packetSize = 64;

  /// Data-only packet size (Proewe firmware, no padding).
  static const int dataSize = 61;

  /// V3.6 firmware packet size (v01 log format).
  static const int v01DataSize = 47;

  /// Iterates through [rawBytes] and extracts [SensorLog] objects.
  ///
  /// Auto-detects whether packets are 47, 61 or 64 bytes by examining
  /// the first two valid headers. Falls back to 64 if detection fails.
  ///
  /// Includes a "Sync Check" to handle corrupted bytes or packet loss.
  ///
  /// ### Packet Structure — 61-byte format (optionally + 3 padding for 64)
  /// | Offset | Field | Type | Size |
  /// | :--- | :--- | :--- | :--- |
  /// | 0 | Kernel Tick | Uint32 | 4 |
  /// | 4 | Year | Uint16 | 2 |
  /// | 6 | Month | Uint8 | 1 |
  /// | 7 | Day | Uint8 | 1 |
  /// | 8 | Hour | Uint8 | 1 |
  /// | 9 | Minute | Uint8 | 1 |
  /// | 10 | Second | Uint8 | 1 |
  /// | 11 | Millisecond | Uint16 | 2 |
  /// | 13 | Latitude | Float32 | 4 |
  /// | 17 | Longitude | Float32 | 4 |
  /// | 21 | Speed (km/h) | Float32 | 4 |
  /// | 25 | Accel X | Float32 | 4 |
  /// | 29 | Accel Y | Float32 | 4 |
  /// | 33 | Accel Z | Float32 | 4 |
  /// | 37 | Gyro X | Float32 | 4 |
  /// | 41 | Gyro Y | Float32 | 4 |
  /// | 45 | Gyro Z | Float32 | 4 |
  /// | 49 | Filt Accel X | Float32 | 4 |
  /// | 53 | Filt Accel Y | Float32 | 4 |
  /// | 57 | Filt Accel Z | Float32 | 4 |
  /// | **61** | **Padding** | **-** | **3** (only in 64-byte mode) |
  ///
  /// ### Packet Structure — 47-byte v01 format (V3.6 firmware)
  /// | Offset | Field | Type | Size |
  /// | :--- | :--- | :--- | :--- |
  /// | 0 | Kernel Tick | Uint32 | 4 |
  /// | 4 | Year | Uint16 | 2 |
  /// | 6 | Month | Uint8 | 1 |
  /// | 7 | Day | Uint8 | 1 |
  /// | 8 | Hour | Uint8 | 1 |
  /// | 9 | Minute | Uint8 | 1 |
  /// | 10 | Second | Uint8 | 1 |
  /// | 11 | Millisecond | Uint16 | 2 |
  /// | 13 | Latitude | Float32 | 4 |
  /// | 17 | Longitude | Float32 | 4 |
  /// | 21 | Speed (km/h×10) | Uint16 | 2 |
  /// | 23 | Accel X | Float32 | 4 |
  /// | 27 | Accel Y | Float32 | 4 |
  /// | 31 | Accel Z | Float32 | 4 |
  /// | 35 | Gyro X | Float32 | 4 |
  /// | 39 | Gyro Y | Float32 | 4 |
  /// | 43 | Gyro Z | Float32 | 4 |
  static List<SensorLog> parseBytes(Uint8List rawBytes) {
    final detectedSize = _detectPacketSize(rawBytes);
    PodLogger.info(
      'parser',
      'Detected packet size',
      detail:
          '${detectedSize}B, totalPayload=${rawBytes.length}B, estRecords=${rawBytes.length ~/ detectedSize}',
    );
    final logs =
        detectedSize == v01DataSize
            ? _parseV01(rawBytes, detectedSize)
            : _parse(rawBytes, detectedSize);
    if (logs.isNotEmpty) {
      PodLogger.info(
        'parser',
        'Parse result',
        detail:
            '${logs.length} records, first=${logs.first.timestamp.toIso8601String()}, last=${logs.last.timestamp.toIso8601String()}',
      );
    }
    return logs;
  }

  /// Detect packet size by finding the first two valid headers and
  /// measuring the distance between them.
  ///
  /// Checks for 47 (v01), 61 (Proewe), and 64 (HTS) byte records.
  static int _detectPacketSize(Uint8List rawBytes) {
    final data = ByteData.sublistView(rawBytes);
    int? firstOffset;

    // Minimum data size needed for header validation is v01DataSize (47)
    final minSize = v01DataSize;

    for (var i = 0; i + minSize <= rawBytes.length; i++) {
      if (!_isValidHeader(data, i)) continue;

      if (firstOffset == null) {
        firstOffset = i;
        continue;
      }

      // Distance between two consecutive valid headers
      final gap = i - firstOffset;
      if (gap == v01DataSize) return v01DataSize;
      if (gap == dataSize) return dataSize;
      if (gap == packetSize) return packetSize;

      // If gap is a multiple, derive the unit
      if (gap % v01DataSize == 0) return v01DataSize;
      if (gap % dataSize == 0) return dataSize;
      if (gap % packetSize == 0) return packetSize;

      // Unexpected gap — advance anchor to current header and keep scanning
      firstOffset = i;
    }

    // Fallback: check if file divides evenly
    if (rawBytes.length % v01DataSize == 0 &&
        rawBytes.length % dataSize != 0 &&
        rawBytes.length % packetSize != 0) {
      return v01DataSize;
    }
    if (rawBytes.length % dataSize == 0 && rawBytes.length % packetSize != 0) {
      return dataSize;
    }

    return packetSize; // default
  }

  /// Check whether bytes at [offset] form a plausible packet header.
  static bool _isValidHeader(ByteData data, int offset) {
    if (offset + 8 > data.lengthInBytes) return false;

    final year = data.getUint16(offset + 4, Endian.little);
    if (year < 2022 || year > 2030) return false;

    final month = data.getUint8(offset + 6);
    final day = data.getUint8(offset + 7);
    return month >= 1 && month <= 12 && day >= 1 && day <= 31;
  }

  /// Core parse loop using the given [stepSize] per packet.
  static List<SensorLog> _parse(Uint8List rawBytes, int stepSize) {
    final List<SensorLog> logs = [];
    final ByteData data = ByteData.sublistView(rawBytes);
    int offset = 0;
    int syncSkips = 0;
    int parseErrors = 0;

    while (offset + dataSize <= rawBytes.length) {
      // --- 1. SYNC CHECK ---
      if (!_isValidHeader(data, offset)) {
        offset++;
        syncSkips++;
        continue;
      }

      // --- 2. EXTRACTION ---
      try {
        final int kernelTick = data.getUint32(offset + 0, Endian.little);
        final int year = data.getUint16(offset + 4, Endian.little);
        final int month = data.getUint8(offset + 6);
        final int day = data.getUint8(offset + 7);
        final int hour = data.getUint8(offset + 8);
        final int min = data.getUint8(offset + 9);
        final int sec = data.getUint8(offset + 10);
        final int ms = data.getUint16(offset + 11, Endian.little);

        final DateTime dt = DateTime(year, month, day, hour, min, sec, ms);

        final double lat = data.getFloat32(offset + 13, Endian.little);
        final double lon = data.getFloat32(offset + 17, Endian.little);
        final double speed = data.getFloat32(offset + 21, Endian.little);

        final double ax = data.getFloat32(offset + 25, Endian.little);
        final double ay = data.getFloat32(offset + 29, Endian.little);
        final double az = data.getFloat32(offset + 33, Endian.little);

        final double gx = data.getFloat32(offset + 37, Endian.little);
        final double gy = data.getFloat32(offset + 41, Endian.little);
        final double gz = data.getFloat32(offset + 45, Endian.little);

        final double filtAx = data.getFloat32(offset + 49, Endian.little);
        final double filtAy = data.getFloat32(offset + 53, Endian.little);
        final double filtAz = data.getFloat32(offset + 57, Endian.little);

        logs.add(
          SensorLog(
            packetId: kernelTick,
            timestamp: dt,
            latitude: lat,
            longitude: lon,
            speed: speed,
            accelX: ax,
            accelY: ay,
            accelZ: az,
            gyroX: gx,
            gyroY: gy,
            gyroZ: gz,
            filteredAccelX: filtAx,
            filteredAccelY: filtAy,
            filteredAccelZ: filtAz,
          ),
        );

        offset += stepSize;
      } catch (e) {
        offset++;
        parseErrors++;
      }
    }

    if (syncSkips > 0 || parseErrors > 0) {
      PodLogger.warn(
        'parser',
        'Parse anomalies',
        detail:
            'syncSkips=$syncSkips, parseErrors=$parseErrors, goodRecords=${logs.length}',
      );
    }

    return logs;
  }

  /// Parse loop for V3.6 firmware v01 format (47-byte records).
  ///
  /// Key differences from 61/64-byte format:
  /// - Speed is uint16 (km/h × 10) at offset 21 instead of float32
  /// - No filtered accelerometer data (fields set to raw accel as fallback)
  static List<SensorLog> _parseV01(Uint8List rawBytes, int stepSize) {
    final List<SensorLog> logs = [];
    final ByteData data = ByteData.sublistView(rawBytes);
    int offset = 0;
    int syncSkips = 0;
    int parseErrors = 0;

    while (offset + v01DataSize <= rawBytes.length) {
      // --- 1. SYNC CHECK ---
      if (!_isValidHeader(data, offset)) {
        offset++;
        syncSkips++;
        continue;
      }

      // --- 2. EXTRACTION ---
      try {
        final int kernelTick = data.getUint32(offset + 0, Endian.little);
        final int year = data.getUint16(offset + 4, Endian.little);
        final int month = data.getUint8(offset + 6);
        final int day = data.getUint8(offset + 7);
        final int hour = data.getUint8(offset + 8);
        final int min = data.getUint8(offset + 9);
        final int sec = data.getUint8(offset + 10);
        final int ms = data.getUint16(offset + 11, Endian.little);

        final DateTime dt = DateTime(year, month, day, hour, min, sec, ms);

        final double lat = data.getFloat32(offset + 13, Endian.little);
        final double lon = data.getFloat32(offset + 17, Endian.little);

        // V3.6: Speed is uint16 (km/h × 10). Divide by 10 to get km/h.
        // SensorLog.speed convention is km/h — converted to m/s downstream
        // in sensor_log_to_gps_points.dart.
        final double speed = data.getUint16(offset + 21, Endian.little) / 10.0;

        // IMU data starts 2 bytes earlier (offset 23 vs 25) due to smaller speed field
        final double ax = data.getFloat32(offset + 23, Endian.little);
        final double ay = data.getFloat32(offset + 27, Endian.little);
        final double az = data.getFloat32(offset + 31, Endian.little);

        final double gx = data.getFloat32(offset + 35, Endian.little);
        final double gy = data.getFloat32(offset + 39, Endian.little);
        final double gz = data.getFloat32(offset + 43, Endian.little);

        logs.add(
          SensorLog(
            packetId: kernelTick,
            timestamp: dt,
            latitude: lat,
            longitude: lon,
            speed: speed,
            accelX: ax,
            accelY: ay,
            accelZ: az,
            gyroX: gx,
            gyroY: gy,
            gyroZ: gz,
            // V3.6 has no filtered accel — use raw accel as fallback so the
            // trajectory filter's variance calculator can still detect motion.
            filteredAccelX: ax,
            filteredAccelY: ay,
            filteredAccelZ: az,
          ),
        );

        offset += stepSize;
      } catch (e) {
        offset++;
        parseErrors++;
      }
    }

    if (syncSkips > 0 || parseErrors > 0) {
      PodLogger.warn(
        'parser',
        'Parse anomalies (v01)',
        detail:
            'syncSkips=$syncSkips, parseErrors=$parseErrors, goodRecords=${logs.length}',
      );
    }

    return logs;
  }
}
