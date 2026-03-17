import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/utils/logs_binary_parser.dart';

/// Helper to build a valid 47-byte v01 binary record (V3.6 firmware).
Uint8List _buildV01Record({
  int kernelTick = 100,
  int year = 2026,
  int month = 3,
  int day = 16,
  int hour = 14,
  int minute = 49,
  int second = 37,
  int ms = 300,
  double lat = -25.8356,
  double lon = 28.2056,
  int speedX10 = 15, // km/h × 10 (1.5 km/h)
  double accelX = 0.5,
  double accelY = -0.3,
  double accelZ = 9.8,
  double gyroX = 0.01,
  double gyroY = -0.02,
  double gyroZ = 0.03,
}) {
  final bytes = ByteData(47);
  bytes.setUint32(0, kernelTick, Endian.little);
  bytes.setUint16(4, year, Endian.little);
  bytes.setUint8(6, month);
  bytes.setUint8(7, day);
  bytes.setUint8(8, hour);
  bytes.setUint8(9, minute);
  bytes.setUint8(10, second);
  bytes.setUint16(11, ms, Endian.little);
  bytes.setFloat32(13, lat, Endian.little);
  bytes.setFloat32(17, lon, Endian.little);
  bytes.setUint16(21, speedX10, Endian.little);
  bytes.setFloat32(23, accelX, Endian.little);
  bytes.setFloat32(27, accelY, Endian.little);
  bytes.setFloat32(31, accelZ, Endian.little);
  bytes.setFloat32(35, gyroX, Endian.little);
  bytes.setFloat32(39, gyroY, Endian.little);
  bytes.setFloat32(43, gyroZ, Endian.little);
  return bytes.buffer.asUint8List();
}

/// Helper to build a valid 64-byte binary record.
Uint8List _buildRecord({
  int kernelTick = 100,
  int year = 2025,
  int month = 7,
  int day = 25,
  int hour = 10,
  int minute = 30,
  int second = 0,
  int ms = 0,
  double lat = -33.8688,
  double lon = 151.2093,
  double speed = 10.0,
  double accelX = 0.5,
  double accelY = -0.3,
  double accelZ = 9.8,
  double gyroX = 0.01,
  double gyroY = -0.02,
  double gyroZ = 0.03,
  double filtAx = 0.4,
  double filtAy = -0.2,
  double filtAz = 9.7,
}) {
  final bytes = ByteData(64);
  bytes.setUint32(0, kernelTick, Endian.little);
  bytes.setUint16(4, year, Endian.little);
  bytes.setUint8(6, month);
  bytes.setUint8(7, day);
  bytes.setUint8(8, hour);
  bytes.setUint8(9, minute);
  bytes.setUint8(10, second);
  bytes.setUint16(11, ms, Endian.little);
  bytes.setFloat32(13, lat, Endian.little);
  bytes.setFloat32(17, lon, Endian.little);
  bytes.setFloat32(21, speed, Endian.little);
  bytes.setFloat32(25, accelX, Endian.little);
  bytes.setFloat32(29, accelY, Endian.little);
  bytes.setFloat32(33, accelZ, Endian.little);
  bytes.setFloat32(37, gyroX, Endian.little);
  bytes.setFloat32(41, gyroY, Endian.little);
  bytes.setFloat32(45, gyroZ, Endian.little);
  bytes.setFloat32(49, filtAx, Endian.little);
  bytes.setFloat32(53, filtAy, Endian.little);
  bytes.setFloat32(57, filtAz, Endian.little);
  return bytes.buffer.asUint8List();
}

void main() {
  group('BinaryParser', () {
    test('parses a single valid 64-byte record', () {
      final raw = _buildRecord();
      final logs = BinaryParser.parseBytes(raw);

      expect(logs.length, 1);
      expect(logs[0].packetId, 100);
      expect(logs[0].timestamp.year, 2025);
      expect(logs[0].timestamp.month, 7);
      expect(logs[0].timestamp.day, 25);
      expect(logs[0].latitude, closeTo(-33.8688, 0.001));
      expect(logs[0].longitude, closeTo(151.2093, 0.001));
      expect(logs[0].speed, closeTo(10.0, 0.01));
    });

    test('parses multiple consecutive records', () {
      final r1 = _buildRecord(kernelTick: 100);
      final r2 = _buildRecord(kernelTick: 200);
      final r3 = _buildRecord(kernelTick: 300);
      final combined = Uint8List.fromList([...r1, ...r2, ...r3]);

      final logs = BinaryParser.parseBytes(combined);
      expect(logs.length, 3);
      expect(logs[0].packetId, 100);
      expect(logs[1].packetId, 200);
      expect(logs[2].packetId, 300);
    });

    test('returns empty list for empty input', () {
      final logs = BinaryParser.parseBytes(Uint8List(0));
      expect(logs, isEmpty);
    });

    test('returns empty list for input shorter than 64 bytes', () {
      final logs = BinaryParser.parseBytes(Uint8List(32));
      expect(logs, isEmpty);
    });

    test('skips records with invalid year (sync recovery)', () {
      // Corrupt first byte to make year invalid, then add a valid record
      final corrupt = Uint8List(64); // All zeros — year 0 is invalid
      final valid = _buildRecord(kernelTick: 500);
      final combined = Uint8List.fromList([...corrupt, ...valid]);

      final logs = BinaryParser.parseBytes(combined);
      // Should skip corrupt bytes and find the valid record
      expect(logs.isNotEmpty, true);
      expect(logs.any((l) => l.packetId == 500), true);
    });

    test('skips records with invalid month', () {
      final bad = _buildRecord(month: 13); // Invalid month
      final good = _buildRecord(kernelTick: 200, month: 6);
      final combined = Uint8List.fromList([...bad, ...good]);

      final logs = BinaryParser.parseBytes(combined);
      // Should recover and find the valid record
      expect(logs.any((l) => l.packetId == 200), true);
    });

    test('skips records with invalid day', () {
      final bad = _buildRecord(day: 0); // Invalid day
      final good = _buildRecord(kernelTick: 300, day: 15);
      final combined = Uint8List.fromList([...bad, ...good]);

      final logs = BinaryParser.parseBytes(combined);
      expect(logs.any((l) => l.packetId == 300), true);
    });

    test('handles trailing bytes (not a full record)', () {
      final valid = _buildRecord();
      // Add 32 extra bytes at the end
      final combined = Uint8List.fromList([...valid, ...Uint8List(32)]);

      final logs = BinaryParser.parseBytes(combined);
      expect(logs.length, 1);
    });

    test('handles corrupt byte in the middle with sync recovery', () {
      final r1 = _buildRecord(kernelTick: 100);
      final r2 = _buildRecord(kernelTick: 200);

      // Insert 1 corrupt byte between records to misalign
      final combined = Uint8List.fromList([...r1, 0xFF, ...r2]);

      final logs = BinaryParser.parseBytes(combined);
      // First record should parse normally
      expect(logs.any((l) => l.packetId == 100), true);
      // Second record should be found via sync recovery
      expect(logs.any((l) => l.packetId == 200), true);
    });
  });

  group('BinaryParser v01 (47-byte, V3.6 firmware)', () {
    test('parses a single valid 47-byte v01 record', () {
      final raw = _buildV01Record();
      final logs = BinaryParser.parseBytes(raw);

      expect(logs.length, 1);
      expect(logs[0].packetId, 100);
      expect(logs[0].timestamp.year, 2026);
      expect(logs[0].timestamp.month, 3);
      expect(logs[0].timestamp.day, 16);
      expect(logs[0].latitude, closeTo(-25.8356, 0.001));
      expect(logs[0].longitude, closeTo(28.2056, 0.001));
      // Speed: uint16=15 → 15/10 = 1.5 km/h
      expect(logs[0].speed, closeTo(1.5, 0.01));
      expect(logs[0].accelX, closeTo(0.5, 0.01));
      expect(logs[0].gyroZ, closeTo(0.03, 0.001));
    });

    test('filteredAccel fields are set to raw accel for v01', () {
      final raw = _buildV01Record(accelX: 1.5, accelY: -2.0, accelZ: 9.81);
      final logs = BinaryParser.parseBytes(raw);

      expect(logs.length, 1);
      expect(logs[0].filteredAccelX, closeTo(1.5, 0.01));
      expect(logs[0].filteredAccelY, closeTo(-2.0, 0.01));
      expect(logs[0].filteredAccelZ, closeTo(9.81, 0.01));
    });

    test('parses multiple consecutive v01 records', () {
      final r1 = _buildV01Record(kernelTick: 100);
      final r2 = _buildV01Record(kernelTick: 200);
      final r3 = _buildV01Record(kernelTick: 300);
      final combined = Uint8List.fromList([...r1, ...r2, ...r3]);

      final logs = BinaryParser.parseBytes(combined);
      expect(logs.length, 3);
      expect(logs[0].packetId, 100);
      expect(logs[1].packetId, 200);
      expect(logs[2].packetId, 300);
    });

    test('auto-detects 47-byte vs 64-byte records', () {
      // Build 3 v01 records — parser should detect 47-byte format
      final v01 = Uint8List.fromList([
        ..._buildV01Record(kernelTick: 100),
        ..._buildV01Record(kernelTick: 200),
        ..._buildV01Record(kernelTick: 300),
      ]);
      final logsV01 = BinaryParser.parseBytes(v01);
      expect(logsV01.length, 3);
      expect(logsV01[0].speed, closeTo(1.5, 0.01)); // uint16 decoding

      // Build 3 legacy records — parser should detect 64-byte format
      final legacy = Uint8List.fromList([
        ..._buildRecord(kernelTick: 100),
        ..._buildRecord(kernelTick: 200),
        ..._buildRecord(kernelTick: 300),
      ]);
      final logsLegacy = BinaryParser.parseBytes(legacy);
      expect(logsLegacy.length, 3);
      expect(logsLegacy[0].speed, closeTo(10.0, 0.01)); // float32 decoding
    });

    test('v01 handles sync recovery with corrupt byte', () {
      // Use 3 records so parser can detect 47-byte size from records 2-3
      // even though a corrupt byte shifts record 2 by 1 byte
      final r1 = _buildV01Record(kernelTick: 100);
      final r2 = _buildV01Record(kernelTick: 200);
      final r3 = _buildV01Record(kernelTick: 300);
      final combined = Uint8List.fromList([...r1, 0xFF, ...r2, ...r3]);

      final logs = BinaryParser.parseBytes(combined);
      expect(logs.any((l) => l.packetId == 100), true);
      expect(logs.any((l) => l.packetId == 200), true);
      expect(logs.any((l) => l.packetId == 300), true);
    });

    test('v01 speed decoding: uint16 divided by 10', () {
      // 350 → 35.0 km/h
      final raw = _buildV01Record(speedX10: 350);
      final logs = BinaryParser.parseBytes(raw);
      expect(logs[0].speed, closeTo(35.0, 0.01));
    });
  });
}
