import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/utils/logs_binary_parser.dart';

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
}
