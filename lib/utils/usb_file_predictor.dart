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
  /// 1. Validates file existence and minimum size (must be at least 2 packets aka 128 bytes).
  /// 2. Reads the **first 64 bytes** to extract the Start Time.
  /// 3. Reads the **last 64 bytes** to extract the End Time.
  /// 4. Validates that both timestamps were parsed successfully.
  static Future<UsbFileBounds?> getFileBounds(String path) async {
    final file = File(path);
    
    // Basic Validation
    if (!await file.exists()) return null;
    
    final int size = await file.length();
    
    // Safety Check: File must be at least 2 packets (Start + End) to be valid.
    if (size < 128) return null; 

    try {
      // Read First 64 bytes (Start Time)
      // openRead is used to stream *only* the specific bytes needed, avoiding loading the full file into RAM.
      final startChunk = await file.openRead(0, 64).first;
      final startTime = _parseTimestamp(Uint8List.fromList(startChunk));

      // Read Last 64 bytes (End Time)
      final endChunk = await file.openRead(size - 64, size).first;
      final endTime = _parseTimestamp(Uint8List.fromList(endChunk));
      
      // Confirm that both times were found successfully.
      if (startTime != null && endTime != null) {
        return UsbFileBounds(start: startTime, end: endTime, filePath: path);
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  /// Extracts the timestamp from a 64-byte binary packet.
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