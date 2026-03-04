import 'dart:typed_data';

/// Validation result for a reassembled payload.
class PayloadValidation {
  final bool isValid;
  final String? error;
  final int messageType;
  final int payloadSize;

  const PayloadValidation({
    required this.isValid,
    this.error,
    required this.messageType,
    required this.payloadSize,
  });
}

/// Dart-side payload validation layer.
///
/// This is NOT a replacement for native reassembly — it validates incoming
/// payloads after native reassembly to catch corrupt data before it reaches
/// the protocol decoder.
class PacketReassembler {
  /// Known valid message types from Pod firmware protocol.
  static const validMessageTypes = {0x01, 0x02, 0x03, 0x05, 0xDA};

  /// Maximum reasonable payload sizes by message type.
  static const _maxPayloadSize = {
    0x01: 256, // Live telemetry — single packet (~72 bytes typical)
    0x02: 8192, // File list — up to ~100 files
    0x03: 10 * 1024 * 1024, // File data — up to 10 MB
    0x05: 256, // Device settings — small response
    0xDA: 1, // Skip signal — just the type byte
  };

  /// Validate a reassembled payload from native code.
  static PayloadValidation validate(Uint8List payload) {
    if (payload.isEmpty) {
      return const PayloadValidation(
        isValid: false,
        error: 'Empty payload',
        messageType: 0,
        payloadSize: 0,
      );
    }

    final messageType = payload[0];

    if (!validMessageTypes.contains(messageType)) {
      return PayloadValidation(
        isValid: false,
        error: 'Unknown message type: 0x${messageType.toRadixString(16)}',
        messageType: messageType,
        payloadSize: payload.length,
      );
    }

    final maxSize = _maxPayloadSize[messageType] ?? 0;
    if (payload.length > maxSize) {
      return PayloadValidation(
        isValid: false,
        error: 'Payload too large for type 0x${messageType.toRadixString(16)}: '
            '${payload.length} > $maxSize',
        messageType: messageType,
        payloadSize: payload.length,
      );
    }

    // Type-specific validation
    switch (messageType) {
      case 0x03:
        return _validateFileData(payload);
      case 0x01:
        return _validateLiveTelemetry(payload);
      default:
        return PayloadValidation(
          isValid: true,
          messageType: messageType,
          payloadSize: payload.length,
        );
    }
  }

  /// Validate file data payload (0x03).
  /// Checks header timestamps are within reasonable range.
  static PayloadValidation _validateFileData(Uint8List payload) {
    // Need at least type byte + 4 timestamp bytes + 4 date bytes = 13
    if (payload.length < 13) {
      return PayloadValidation(
        isValid: false,
        error: 'File data payload too short: ${payload.length} < 13',
        messageType: 0x03,
        payloadSize: payload.length,
      );
    }

    // Check header date at offset 5-10 (year at 5-6, month at 7, day at 8)
    if (payload.length >= 9) {
      final year = payload[5] | (payload[6] << 8);
      final month = payload[7];
      final day = payload[8];

      if (year < 2022 || year > 2035 || month < 1 || month > 12 || day < 1 || day > 31) {
        return PayloadValidation(
          isValid: false,
          error: 'Invalid header date: $year-$month-$day',
          messageType: 0x03,
          payloadSize: payload.length,
        );
      }
    }

    return PayloadValidation(
      isValid: true,
      messageType: 0x03,
      payloadSize: payload.length,
    );
  }

  /// Validate live telemetry payload (0x01).
  static PayloadValidation _validateLiveTelemetry(Uint8List payload) {
    // Live telemetry should be at least ~20 bytes (type + basic sensor data)
    if (payload.length < 5) {
      return PayloadValidation(
        isValid: false,
        error: 'Telemetry payload too short: ${payload.length}',
        messageType: 0x01,
        payloadSize: payload.length,
      );
    }

    return PayloadValidation(
      isValid: true,
      messageType: 0x01,
      payloadSize: payload.length,
    );
  }

  /// Validate a first-packet header for packet count sanity.
  /// Returns null if valid, or an error string if invalid.
  static String? validatePacketHeader(Uint8List headerPacket) {
    if (headerPacket.length < 9) return 'Header too short: ${headerPacket.length}';

    final totalPackets = headerPacket[5] |
        (headerPacket[6] << 8) |
        (headerPacket[7] << 16) |
        (headerPacket[8] << 24);

    if (totalPackets <= 0) return 'Invalid packet count: $totalPackets';
    if (totalPackets > 500000) return 'Packet count too large: $totalPackets';

    return null;
  }

  /// Detect firmware record size from payload buffer (61 or 64 bytes).
  /// Returns 61 for Proewe firmware, 64 for HTS firmware.
  static int detectRecordSize(Uint8List buffer) {
    // Need at least 1 (type) + 61 (first record) + 8 (header of second) = 70 bytes
    if (buffer.length >= 70) {
      // Second record at offset 62; year is 4 bytes into the record header
      final year = buffer[66] | (buffer[67] << 8);
      final month = buffer[68];
      final day = buffer[69];
      if (year >= 2022 && year <= 2030 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return 61;
      }
    }
    return 64;
  }
}
