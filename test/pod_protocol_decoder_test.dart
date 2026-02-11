import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/utils/pod_protocol_decoder.dart';
import 'package:metric_athlete_pod_ble/models/live_data_model.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';

void main() {
  group('PodProtocolHandler', () {
    late List<PodMessage> messages;
    late PodProtocolHandler handler;

    setUp(() {
      messages = [];
      handler = PodProtocolHandler(
        onMessageDecoded: (msg) => messages.add(msg),
      );
    });

    // --- Type 0x01: Live Telemetry ---

    test('type 0x01 parses valid 72-byte telemetry', () {
      final bytes = ByteData(72);
      bytes.setUint32(0, 5000, Endian.little); // kernelTick
      bytes.setFloat32(4, 3.7, Endian.little); // battery
      bytes.setFloat32(8, 0.5, Endian.little); // accelX
      bytes.setFloat32(12, -0.3, Endian.little);
      bytes.setFloat32(16, 9.8, Endian.little);
      bytes.setFloat32(20, 0.01, Endian.little); // gyroX
      bytes.setFloat32(24, -0.02, Endian.little);
      bytes.setFloat32(28, 0.03, Endian.little);
      bytes.setFloat32(32, 0.0, Endian.little); // filtGravity
      bytes.setFloat32(36, 0.0, Endian.little);
      bytes.setFloat32(40, 9.8, Endian.little);
      bytes.setUint8(44, 1); // gpsFix
      bytes.setUint16(45, 2025, Endian.little); // year
      bytes.setUint8(47, 7); // month
      bytes.setUint8(48, 25); // day
      bytes.setUint8(49, 10); // hour
      bytes.setUint8(50, 30); // minute
      bytes.setUint8(51, 0); // second
      bytes.setUint16(52, 0, Endian.little); // ms
      bytes.setFloat32(54, -33.8688, Endian.little);
      bytes.setFloat32(58, 151.2093, Endian.little);
      bytes.setUint8(62, 1); // fixQuality
      bytes.setUint8(63, 8); // satellites
      bytes.setFloat32(64, 10.5, Endian.little); // speed
      bytes.setFloat32(68, 180.0, Endian.little); // course

      handler.handleMessage(0x01, bytes.buffer.asUint8List());

      expect(messages.length, 1);
      expect(messages.first.type, 0x01);
      expect(messages.first.description, 'Live Update');
      expect(messages.first.payload, isA<LiveTelemetry>());
      final t = messages.first.payload as LiveTelemetry;
      expect(t.kernelTickCount, 5000);
      expect(t.batteryVoltage, closeTo(3.7, 0.01));
    });

    test('type 0x01 silently drops truncated telemetry (< 72 bytes)', () {
      handler.handleMessage(0x01, Uint8List(50));
      expect(messages, isEmpty);
    });

    // --- Type 0x02: File List ---

    test('type 0x02 decodes file list with 2 files', () {
      // Header: 2 files
      // Each file: 32 bytes name + 4 bytes size = 36 bytes
      final data = Uint8List(1 + 2 * 36);
      data[0] = 2; // fileCount

      // File 1: "20250725.bin"
      final name1 = ascii.encode('20250725.bin');
      for (int i = 0; i < name1.length; i++) {
        data[1 + i] = name1[i];
      }
      // File 1 size: 64000 bytes (Little Endian)
      final size1 = ByteData(4)..setUint32(0, 64000, Endian.little);
      for (int i = 0; i < 4; i++) {
        data[33 + i] = size1.getUint8(i);
      }

      // File 2: "20250726.bin"
      final name2 = ascii.encode('20250726.bin');
      for (int i = 0; i < name2.length; i++) {
        data[37 + i] = name2[i];
      }
      // File 2 size: 128000 bytes
      final size2 = ByteData(4)..setUint32(0, 128000, Endian.little);
      for (int i = 0; i < 4; i++) {
        data[69 + i] = size2.getUint8(i);
      }

      handler.handleMessage(0x02, data);

      expect(messages.length, 1);
      expect(messages.first.type, 0x02);
      expect(messages.first.description, 'Found 2 Files');
      final files = messages.first.payload as List<String>;
      expect(files.length, 2);
      expect(files[0], contains('20250725.bin'));
      expect(files[1], contains('20250726.bin'));
    });

    test('type 0x02 handles empty file list', () {
      handler.handleMessage(0x02, Uint8List.fromList([0]));
      expect(messages.length, 1);
      expect(messages.first.description, 'Found 0 Files');
      expect((messages.first.payload as List).isEmpty, true);
    });

    test('type 0x02 handles empty payload gracefully', () {
      handler.handleMessage(0x02, Uint8List(0));
      // Should not crash, should not emit a message
      expect(messages, isEmpty);
    });

    test('type 0x02 truncated file entry is skipped', () {
      // Header says 2 files but only 1 file's worth of data
      final data = Uint8List(1 + 36); // only enough for 1 file
      data[0] = 2; // claims 2 files
      final name = ascii.encode('file1.bin');
      for (int i = 0; i < name.length; i++) {
        data[1 + i] = name[i];
      }

      handler.handleMessage(0x02, data);

      expect(messages.length, 1);
      final files = messages.first.payload as List<String>;
      expect(files.length, 1); // Only the valid one
    });

    // --- Type 0x03: File Download ---

    test('type 0x03 sends parsed SensorLogs on valid binary data', () {
      // Create a valid 64-byte binary record
      final record = ByteData(64);
      record.setUint32(0, 1000, Endian.little); // kernelTick
      record.setUint16(4, 2025, Endian.little); // year
      record.setUint8(6, 7); // month
      record.setUint8(7, 25); // day
      record.setUint8(8, 10); // hour
      record.setUint8(9, 30); // min
      record.setUint8(10, 0); // sec
      record.setUint16(11, 0, Endian.little); // ms
      record.setFloat32(13, -33.8688, Endian.little); // lat
      record.setFloat32(17, 151.2093, Endian.little); // lon
      record.setFloat32(21, 10.0, Endian.little); // speed

      handler.handleMessage(0x03, record.buffer.asUint8List());

      expect(messages.length, 1);
      expect(messages.first.type, 0x03);
      expect(messages.first.description, 'Download Complete');
      final logs = messages.first.payload as List<SensorLog>;
      expect(logs.length, 1);
      expect(logs.first.packetId, 1000);
    });

    test('type 0x03 sends empty list for corrupt data', () {
      // Too short to contain even 1 record, but BinaryParser returns empty
      handler.handleMessage(0x03, Uint8List(10));
      expect(messages.length, 1);
      expect(messages.first.type, 0x03);
      final logs = messages.first.payload as List<SensorLog>;
      expect(logs, isEmpty);
    });

    // --- Type 0x05: Settings ---

    test('type 0x05 parses settings correctly', () {
      // Player number: 42, Log interval: 200ms (Little Endian: 0xC8, 0x00)
      final data = Uint8List.fromList([42, 0xC8, 0x00]);

      handler.handleMessage(0x05, data);

      expect(messages.length, 1);
      expect(messages.first.type, 0x05);
      expect(messages.first.description, 'Settings Retrieved');
      final settings = messages.first.payload as Map;
      expect(settings['playerNumber'], 42);
      expect(settings['logInterval'], 200);
    });

    test('type 0x05 parses 1000ms log interval', () {
      // Player 1, interval 1000 = 0xE8 + (0x03 << 8)
      final data = Uint8List.fromList([1, 0xE8, 0x03]);
      handler.handleMessage(0x05, data);

      final settings = messages.first.payload as Map;
      expect(settings['playerNumber'], 1);
      expect(settings['logInterval'], 1000);
    });

    test('type 0x05 ignores payload shorter than 3 bytes', () {
      handler.handleMessage(0x05, Uint8List.fromList([42, 0x64])); // only 2 bytes
      expect(messages, isEmpty);
    });

    // --- Type 0xDA: File Skipped ---

    test('type 0xDA emits file skipped message', () {
      handler.handleMessage(0xDA, Uint8List(0));
      expect(messages.length, 1);
      expect(messages.first.type, 0xDA);
      expect(messages.first.description, 'File Skipped');
    });

    // --- Unknown Type ---

    test('unknown type emits unknown message', () {
      handler.handleMessage(0xFF, Uint8List(0));
      expect(messages.length, 1);
      expect(messages.first.type, 0xFF);
      expect(messages.first.description, 'Unknown Message');
    });
  });
}
