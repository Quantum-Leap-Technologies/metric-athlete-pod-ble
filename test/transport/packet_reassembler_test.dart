import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/transport/packet_reassembler.dart';

void main() {
  group('PacketReassembler.validate', () {
    test('rejects empty payload', () {
      final result = PacketReassembler.validate(Uint8List(0));
      expect(result.isValid, false);
      expect(result.error, contains('Empty'));
    });

    test('rejects unknown message type', () {
      final payload = Uint8List.fromList([0xFF, 0x00, 0x01]);
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, false);
      expect(result.error, contains('Unknown message type'));
    });

    test('accepts valid live telemetry (0x01)', () {
      // Type 0x01 + 71 bytes of sensor data = 72 bytes total
      final payload = Uint8List(72);
      payload[0] = 0x01;
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, true);
      expect(result.messageType, 0x01);
    });

    test('rejects too-short telemetry', () {
      final payload = Uint8List.fromList([0x01, 0x00, 0x01]);
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, false);
      expect(result.error, contains('too short'));
    });

    test('accepts valid file list response (0x02)', () {
      final payload = Uint8List(100);
      payload[0] = 0x02;
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, true);
      expect(result.messageType, 0x02);
    });

    test('accepts valid file data (0x03) with valid header', () {
      // Type + 4 timestamp bytes + year(2024) + month(3) + day(15)
      final payload = Uint8List(200);
      payload[0] = 0x03;
      // Year 2024 at bytes 5-6 (little endian)
      payload[5] = 0xE8; // 2024 & 0xFF
      payload[6] = 0x07; // 2024 >> 8
      payload[7] = 3; // March
      payload[8] = 15; // 15th
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, true);
      expect(result.messageType, 0x03);
    });

    test('rejects file data with invalid header date', () {
      final payload = Uint8List(200);
      payload[0] = 0x03;
      // Year 1990 — too old
      payload[5] = 0xC6; // 1990 & 0xFF
      payload[6] = 0x07; // 1990 >> 8
      payload[7] = 13; // Invalid month
      payload[8] = 32; // Invalid day
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, false);
      expect(result.error, contains('Invalid header date'));
    });

    test('accepts device settings (0x05)', () {
      final payload = Uint8List(20);
      payload[0] = 0x05;
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, true);
      expect(result.messageType, 0x05);
    });

    test('accepts skip signal (0xDA)', () {
      final payload = Uint8List.fromList([0xDA]);
      final result = PacketReassembler.validate(payload);
      expect(result.isValid, true);
      expect(result.messageType, 0xDA);
    });
  });

  group('PacketReassembler.validatePacketHeader', () {
    test('rejects header with totalExpectedPackets = 0', () {
      final header = Uint8List(9);
      header[0] = 0x03;
      // bytes 5-8 all zero = 0 packets
      final error = PacketReassembler.validatePacketHeader(header);
      expect(error, isNotNull);
      expect(error, contains('Invalid packet count'));
    });

    test('rejects header with totalExpectedPackets > 500k', () {
      final header = Uint8List(9);
      header[0] = 0x03;
      // 600000 = 0x927C0 in little endian: C0 27 09 00
      header[5] = 0xC0;
      header[6] = 0x27;
      header[7] = 0x09;
      header[8] = 0x00;
      final error = PacketReassembler.validatePacketHeader(header);
      expect(error, isNotNull);
      expect(error, contains('too large'));
    });

    test('accepts valid header with reasonable packet count', () {
      final header = Uint8List(9);
      header[0] = 0x03;
      // 72000 packets = 0x11940 in little endian: 40 19 01 00
      header[5] = 0x40;
      header[6] = 0x19;
      header[7] = 0x01;
      header[8] = 0x00;
      final error = PacketReassembler.validatePacketHeader(header);
      expect(error, isNull);
    });

    test('rejects too-short header', () {
      final header = Uint8List(5);
      final error = PacketReassembler.validatePacketHeader(header);
      expect(error, isNotNull);
      expect(error, contains('too short'));
    });
  });

  group('PacketReassembler.detectRecordSize', () {
    test('detects 61-byte Proewe firmware records', () {
      // Buffer layout: [type_byte][61_byte_record][next_record_header...]
      // At offset 62 is the start of second record (4 bytes timestamp)
      // At offset 66-67 is the year of second record
      final buffer = Uint8List(80);
      buffer[0] = 0x03; // type

      // Second record at offset 62; year at offset 66-67
      // Year 2024 = 0x07E8
      buffer[66] = 0xE8;
      buffer[67] = 0x07;
      buffer[68] = 6; // June
      buffer[69] = 10; // 10th

      expect(PacketReassembler.detectRecordSize(buffer), 61);
    });

    test('detects 64-byte HTS firmware records', () {
      // No valid date at offset 66 → falls back to 64
      final buffer = Uint8List(80);
      buffer[0] = 0x03;
      buffer[66] = 0x00; // Invalid year
      buffer[67] = 0x00;
      buffer[68] = 0;
      buffer[69] = 0;

      expect(PacketReassembler.detectRecordSize(buffer), 64);
    });

    test('returns 64 for buffer too short for Proewe detection', () {
      final buffer = Uint8List(60);
      expect(PacketReassembler.detectRecordSize(buffer), 64);
    });
  });
}
