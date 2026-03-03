import 'dart:io';
import 'dart:typed_data';
import '../models/usb_bounds_model.dart';
///Class contains functions to assist in predicting if a file contains the logs within the time interval.
class UsbFilePredictor {

  /// Efficiently determines the start and end timestamps of a binary log file.
  ///
  /// Returns a [UsbFileBounds] object containing the time window and file path.
  /// Returns `null` if the file is invalid, too small, or cannot be parsed.
  ///
  /// Logic:
  /// 1. Validates file existence and minimum size (must be at least 2 records).
  /// 2. Reads the first 128 bytes to extract start time and detect record size (61 or 64).
  /// 3. Aligns to the last complete record and reads its timestamp.
  /// 4. Validates that both timestamps were parsed successfully.
  static Future<UsbFileBounds?> getFileBounds(String path) async {
    final file = File(path);

    // Basic Validation
    if (!await file.exists()) return null;

    final int size = await file.length();

    // Safety Check: File must be at least 2 records to be valid.
    if (size < 122) return null; // 61 * 2 = 122 (minimum for smallest record size)

    try {
      final raf = await file.open();
      try {
        // Read first 128 bytes for start time + record size detection
        final headerBytes = await raf.read(128);
        final startTime = _parseTimestamp(headerBytes);
        final recordSize = _detectRecordSize(headerBytes);

        // Align to the last complete record
        final recordCount = size ~/ recordSize;
        if (recordCount < 2) return null;
        final lastRecordOffset = (recordCount - 1) * recordSize;
        await raf.setPosition(lastRecordOffset);
        final endBytes = await raf.read(recordSize);
        final endTime = _parseTimestamp(endBytes);

        // Confirm that both times were found successfully.
        if (startTime != null && endTime != null) {
          return UsbFileBounds(start: startTime, end: endTime, filePath: path);
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /// Detect record size by checking if byte 61 starts a valid header.
  /// Returns 61 for Proewe firmware, 64 for original HTS firmware.
  static int _detectRecordSize(Uint8List data) {
    if (data.length >= 69) {
      final bd = ByteData.sublistView(data);
      final year = bd.getUint16(65, Endian.little);
      final month = data[67];
      final day = data[68];
      if (year >= 2022 && year <= 2030 && month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        return 61;
      }
    }
    return 64;
  }

  /// Extracts the timestamp from a binary record.
  /// Logic mirrors the full [BinaryParser] but strictly for time extraction.
  static DateTime? _parseTimestamp(Uint8List bytes) {
    try {
      final data = ByteData.sublistView(bytes);

      // Extract the year (Offset 4)
      int year = data.getUint16(4, Endian.little);

      // Validation: Ensure year is within a realistic range.
      if (year < 2022 || year > 2030) return null;

      // Extract date and time components
      int month = data.getUint8(6);
      int day   = data.getUint8(7);
      int hour  = data.getUint8(8);
      int min   = data.getUint8(9);
      int sec   = data.getUint8(10);
      int ms    = data.getUint16(11, Endian.little);

      // Confirm a valid month and day were extracted
      if (month == 0 || month > 12 || day == 0 || day > 31) return null;

      return DateTime(year, month, day, hour, min, sec, ms);
    } catch (e) {
      return null;
    }
  }
}
