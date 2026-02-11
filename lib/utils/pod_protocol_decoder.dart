import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:metric_athlete_pod_ble/metric_athlete_pod_ble.dart';

///Helper class used to transfer messages between the [PodProtocolHandler] and the [podNotifier].
///The [type] contains the message type received from the pod.
///The [description] describes the current state or content of the message.
///The [payload] contains the data received in the message from the pod.
///The [podNotifier] uses the [type],[description] and [payload] data type to determine what models and states to update.
class PodMessage {
  final int type;
  final String description;
  final dynamic payload; 
  PodMessage(this.type, this.description, {this.payload});
}


///This class is used to decode and process the different message types that is received from the pod through bluetooth.
///The class contains requires an instance of the [podMessage] class for communication with the [podNotifier].
///
/// The logic:
/// 1. The pod receives the encoded message from the [podNotifier].
/// 2. Determine what message type it is.
/// 3. Process the payload according to the message type.
/// 4. Use the [onMessageDecoded] function to update the message details and notify the [podNotifier].
class PodProtocolHandler {
  ///This function creates a [PodMessage] used to update the [podNotifier] with the correct message [type], [description] and [payload].
  final Function(PodMessage message) onMessageDecoded;

  PodProtocolHandler({required this.onMessageDecoded});

  ///This is the start point of the protocol decoder.
  ///This function receives the message [type] and [payload].
  ///It uses a case statement to determine how the [payload] should be processed based on the message [type].
  ///Returns the [onMessageDecoded] function to update the [podNotifier].
  ///If the processing requires a helper function the [payload] is passed to helper functions.
  ///In this scenario the helper function returns the [onMessageDecoded] function to update the [podNotifier].
  void handleMessage(int type, Uint8List payload) {
    switch (type) {
      case 0x01: //Live data steaming
      try {
        //transforms the payload to a LiveTelemetry object, updates the description and returns the object to the notifier.
           final telemetry = LiveTelemetry.fromBytes(payload);
           if (telemetry != null) {
             onMessageDecoded(PodMessage(
               0x01,
               "Live Update",
               payload: telemetry //live telemetry object
             ));
           } else {
             PodLogger.warn('protocol', 'Truncated telemetry packet', detail: '${payload.length} bytes, need 72');
           }
        } catch (e) {
           PodLogger.error('protocol', 'Telemetry parse error', detail: '$e');
        }
        break;

      case 0x02: //file list retrieval.
        _handleLogFilesInfo(payload);
        break;

      case 0x03: //Log file download.
        _handleFileDownload(payload);
        break;

      case 0x05://settings retrieved 
        _handleSettings(payload);
        break;

      case 0xda://file skipped.
      //This is a custom message type used to let the notifier know a file was skipped while trying to download multiple files based on a time range.
      //Is crucial to pass the await call if a file is skipped.
        onMessageDecoded(PodMessage(0xda, "File Skipped"));
      break;
      

      default: //sends the unknown type and description to the pod notifier
        onMessageDecoded(PodMessage(type, "Unknown Message"));
    }
  }

  
  ///Helper function to parse the downloaded bytes into raw [SensorLog] objects.
  ///The payload is in the format described by the [BinaryParser].
  ///Filtering is NOT done here — it is handled by the notifier to avoid double-filtering.
  void _handleFileDownload(Uint8List rawBytes) {
    try {
      // Parse binary data into raw SensorLog objects
      final rawLogs = BinaryParser.parseBytes(rawBytes);

      // Return raw List<SensorLog> to Notifier (filtering happens there)
      onMessageDecoded(PodMessage(
        0x03,
        "Download Complete",
        payload: rawLogs
      ));
    } catch (e) {
      PodLogger.error('protocol', 'Binary parse error', detail: '$e');
      // Send empty list to signal failure
      onMessageDecoded(PodMessage(0x03, "Parse Failed", payload: <SensorLog>[]));
    }
  }

  /// Decodes the "Settings" response packet (Type 0x05).
  ///
  /// The payload consists of 3 bytes containing the device configuration.
  ///
  /// ### Packet Structure
  /// | Offset | Field | Type | Size | Description |
  /// | :--- | :--- | :--- | :--- | :--- |
  /// | 0 | Player Number | Uint8 | 1 | Range 1-99. Identifier appended to the POD name. |
  /// | 1 | Log Interval | Uint16 | 2 | Range 100-1000 (ms). Sampling rate for SD card logging. |
  ///
  /// **Logic:**
  /// 1. Verifies the payload has at least 3 bytes.
  /// 2. Extracts the [Player Number] from the first byte.
  /// 3. Extracts the [Log Interval] by combining the 2nd and 3rd bytes (Little Endian).
  /// 4. Updates the notifier with a Map containing these settings.
  void _handleSettings(Uint8List data) {
    // Safety check: Ensure we have enough bytes
    if (data.length >= 3) {
      
      final settings = {
        'playerNumber': data[0],
        
        // Combine 2 bytes for interval (Little Endian: LSB + MSB << 8)
        // e.g., if data[1]=100 (0x64) and data[2]=0, result is 100ms.
        'logInterval': data[1] + (data[2] << 8) 
      };

      onMessageDecoded(PodMessage(
        0x05, 
        "Settings Retrieved", 
        payload: settings
      ));
    }
  }

  /// Decodes the "File List" response packet (Type 0x02).
  ///
  /// The payload consists of a 1-byte header indicating the number of files,
  /// followed by a repeating 36-byte block for each file.
  ///
  /// ### Packet Structure
  /// | Offset | Field | Type | Size | Description |
  /// | :--- | :--- | :--- | :--- | :--- |
  /// | **0** | **File Count** | **Uint8** | **1** | Total number of files on the device |
  /// | | | | |
  /// | *Repeat for N files:* | | | | |
  /// | 1 + (i×36) | File Name | Uint8[32] | 32 | ASCII string (e.g. "20250725.bin") |
  /// | 33 + (i×36) | File Size | Uint32 | 4 | Size in bytes (Little Endian) |
  ///
  /// **Logic:**
  /// 1. Reads the first byte to get the [fileCount].
  /// 2. Loops [fileCount] times, advancing by a stride of 36 bytes.
  /// 3. Extracts the filename (trimming null terminators) and file size.
  /// 4. Updates the notifier with a list of formatted file summaries.
  void _handleLogFilesInfo(Uint8List data) {
    try {
      if (data.isEmpty) return;
      
      int fileCount = data[0]; 
      List<String> fileSummaries = [];
      int headerSize = 1; 
      int stride = 36; 
      
      for (int i = 0; i < fileCount; i++) {
        int startOffset = headerSize + (i * stride);
        if (startOffset + stride > data.length) break;

        List<int> rawName = data.sublist(startOffset, startOffset + 32);
        int nullIndex = rawName.indexOf(0x00);
        List<int> cleanName = (nullIndex != -1) ? rawName.sublist(0, nullIndex) : rawName;
        String name = ascii.decode(cleanName, allowInvalid: true);

        int sizeOffset = startOffset + 32;
        int size = ByteData.sublistView(data, sizeOffset, sizeOffset + 4).getUint32(0, Endian.little);

        fileSummaries.add("$name (${(size / 1024).toStringAsFixed(1)} KB)");
      }
      
      onMessageDecoded(PodMessage(0x02, "Found $fileCount Files", payload: fileSummaries));
    } catch (e) {
      PodLogger.error('protocol', 'Error decoding file list', detail: '$e');
    }
  }
}