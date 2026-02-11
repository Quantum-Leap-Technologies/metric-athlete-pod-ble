import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/models/live_data_model.dart';

/// Build a valid 72-byte live telemetry packet.
Uint8List _buildTelemetryPacket({
  int kernelTick = 1000,
  double battery = 3.7,
  double ax = 0.5,
  double ay = -0.3,
  double az = 9.8,
  double gx = 0.01,
  double gy = -0.02,
  double gz = 0.03,
  double fgx = 0.0,
  double fgy = 0.0,
  double fgz = 9.8,
  int gpsFix = 1,
  int year = 2025,
  int month = 7,
  int day = 25,
  int hour = 10,
  int minute = 30,
  int second = 0,
  int ms = 0,
  double lat = -33.8688,
  double lon = 151.2093,
  int fixQuality = 1,
  int satellites = 8,
  double speed = 10.5,
  double course = 180.0,
}) {
  final bytes = ByteData(72);
  bytes.setUint32(0, kernelTick, Endian.little);
  bytes.setFloat32(4, battery, Endian.little);
  bytes.setFloat32(8, ax, Endian.little);
  bytes.setFloat32(12, ay, Endian.little);
  bytes.setFloat32(16, az, Endian.little);
  bytes.setFloat32(20, gx, Endian.little);
  bytes.setFloat32(24, gy, Endian.little);
  bytes.setFloat32(28, gz, Endian.little);
  bytes.setFloat32(32, fgx, Endian.little);
  bytes.setFloat32(36, fgy, Endian.little);
  bytes.setFloat32(40, fgz, Endian.little);
  bytes.setUint8(44, gpsFix);
  bytes.setUint16(45, year, Endian.little);
  bytes.setUint8(47, month);
  bytes.setUint8(48, day);
  bytes.setUint8(49, hour);
  bytes.setUint8(50, minute);
  bytes.setUint8(51, second);
  bytes.setUint16(52, ms, Endian.little);
  bytes.setFloat32(54, lat, Endian.little);
  bytes.setFloat32(58, lon, Endian.little);
  bytes.setUint8(62, fixQuality);
  bytes.setUint8(63, satellites);
  bytes.setFloat32(64, speed, Endian.little);
  bytes.setFloat32(68, course, Endian.little);
  return bytes.buffer.asUint8List();
}

void main() {
  group('LiveTelemetry', () {
    test('parses a valid 72-byte packet', () {
      final packet = _buildTelemetryPacket();
      final telemetry = LiveTelemetry.fromBytes(packet);

      expect(telemetry, isNotNull);
      expect(telemetry!.kernelTickCount, 1000);
      expect(telemetry.batteryVoltage, closeTo(3.7, 0.01));
      expect(telemetry.isGpsFixValid, true);
      expect(telemetry.year, 2025);
      expect(telemetry.month, 7);
      expect(telemetry.latitude, closeTo(-33.8688, 0.001));
      expect(telemetry.gpsSatellites, 8);
      expect(telemetry.gpsSpeed, closeTo(10.5, 0.1));
    });

    test('returns null for truncated packet (less than 72 bytes)', () {
      final short = Uint8List(50);
      final telemetry = LiveTelemetry.fromBytes(short);
      expect(telemetry, isNull);
    });

    test('returns null for empty packet', () {
      final empty = Uint8List(0);
      final telemetry = LiveTelemetry.fromBytes(empty);
      expect(telemetry, isNull);
    });

    test('returns null for 71-byte packet (off by one)', () {
      final almostFull = Uint8List(71);
      final telemetry = LiveTelemetry.fromBytes(almostFull);
      expect(telemetry, isNull);
    });

    test('parses exactly 72-byte packet', () {
      final packet = _buildTelemetryPacket();
      expect(packet.length, 72);
      final telemetry = LiveTelemetry.fromBytes(packet);
      expect(telemetry, isNotNull);
    });

    test('parses packet with no GPS fix', () {
      final packet = _buildTelemetryPacket(gpsFix: 0);
      final telemetry = LiveTelemetry.fromBytes(packet);
      expect(telemetry, isNotNull);
      expect(telemetry!.isGpsFixValid, false);
    });

    test('getTimestamp returns null for year 0', () {
      final packet = _buildTelemetryPacket(year: 0);
      final telemetry = LiveTelemetry.fromBytes(packet);
      expect(telemetry, isNotNull);
      expect(telemetry!.getTimestamp(), isNull);
    });

    test('getTimestamp returns valid DateTime for valid time', () {
      final packet = _buildTelemetryPacket(
        year: 2025, month: 7, day: 25, hour: 10, minute: 30, second: 45,
      );
      final telemetry = LiveTelemetry.fromBytes(packet);
      final ts = telemetry!.getTimestamp();
      expect(ts, isNotNull);
      expect(ts!.year, 2025);
      expect(ts.month, 7);
      expect(ts.second, 45);
    });

    test('accepts packets longer than 72 bytes (future-proofing)', () {
      final packet = Uint8List(100);
      // Write valid data in the first 72 bytes
      final valid = _buildTelemetryPacket();
      for (int i = 0; i < 72; i++) {
        packet[i] = valid[i];
      }
      final telemetry = LiveTelemetry.fromBytes(packet);
      expect(telemetry, isNotNull);
      expect(telemetry!.kernelTickCount, 1000);
    });
  });
}
