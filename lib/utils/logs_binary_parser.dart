import 'dart:typed_data';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';

/// Class used to parse downloaded .bin file [rawBytes] into [SensorLog] objects.
/// The [rawBytes] are expected to be in Little Endian format and consist of logs that are 64 bytes fixed size.
class BinaryParser {
  static const int packetSize = 64; 

  /// Iterates through [rawBytes] in packets of 64 Bytes and extracts them into [SensorLog] objects.
  ///
  /// The function returns a list of [SensorLog] objects. 
  /// It includes a "Sync Check" to handle corrupted bytes or packet loss by verifying the Date header.
  ///
  /// ### Packet Structure (64 Bytes)
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
  /// | **61** | **Padding** | **-** | **3** |
  static List<SensorLog> parseBytes(Uint8List rawBytes) {
    List<SensorLog> logs = [];
    final ByteData data = ByteData.sublistView(rawBytes); 
    int offset = 0; 

    // Loop through the rawBytes in 64 byte packets. 
    // We use (offset + packetSize) to ensure we don't read past the end of the file.
    while (offset + packetSize <= rawBytes.length) { 
      
      // --- 1. SYNC CHECK (The Fix) ---
      // Before parsing, check if the Year is valid (e.g., 2022-2030).
      // Bounds can be made dynamic at a future date.
      // The Year is at Offset 4 (2 bytes, Little Endian).
      // This detects incorrect offsets caused by data corruption or dropped bytes.
      int potentialYear = data.getUint16(offset + 4, Endian.little);
      
      bool isHeaderValid = (potentialYear >= 2022 && potentialYear <= 2030);

      if (!isHeaderValid) {
        offset++; // Move 1 byte forward to "hunt" for the next valid header.
        continue; 
      }

      // --- 2. EXTRACTION ---
      try {
        int kernelTick = data.getUint32(offset + 0, Endian.little); 
        int year = data.getUint16(offset + 4, Endian.little); 
        int month = data.getUint8(offset + 6); 
        int day = data.getUint8(offset + 7); 
        int hour = data.getUint8(offset + 8); 
        int min = data.getUint8(offset + 9); 
        int sec = data.getUint8(offset + 10); 
        int ms = data.getUint16(offset + 11, Endian.little); 

        // Sanity Check for Date 
        if (month == 0 || month > 12 || day == 0 || day > 31) {
           offset++; 
           continue;
        }

        DateTime dt = DateTime(year, month, day, hour, min, sec, ms);

        double lat = data.getFloat32(offset + 13, Endian.little);
        double lon = data.getFloat32(offset + 17, Endian.little);
        double speed = data.getFloat32(offset + 21, Endian.little);

        double ax = data.getFloat32(offset + 25, Endian.little);
        double ay = data.getFloat32(offset + 29, Endian.little);
        double az = data.getFloat32(offset + 33, Endian.little);

        double gx = data.getFloat32(offset + 37, Endian.little);
        double gy = data.getFloat32(offset + 41, Endian.little);
        double gz = data.getFloat32(offset + 45, Endian.little);

        double filtAx = data.getFloat32(offset + 49, Endian.little);
        double filtAy = data.getFloat32(offset + 53, Endian.little);
        double filtAz = data.getFloat32(offset + 57, Endian.little);

        logs.add(SensorLog(
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
        ));

        // Jump by full packet size only if successful
        offset += packetSize;

      } catch (e) {
        // If parsing crashes (e.g., out of bounds), move 1 byte and try again
        offset++;
      }
    }
    return logs;
  }
}