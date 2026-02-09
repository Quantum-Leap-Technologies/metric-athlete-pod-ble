import 'dart:typed_data';
///Used to store the sensor data where the sensors have 3 axis data.
class Vector3 {
  final double x, y, z;
  Vector3({required this.x, required this.y, required this.z});
  @override
  String toString() => 'X:${x.toStringAsFixed(2)} Y:${y.toStringAsFixed(2)} Z:${z.toStringAsFixed(2)}';
}
///Class used to save the live data streamed by the pod.
///The class contians a function to save the data into the fields directly from the raw bytes.
///The function however requires a full packet to save all the data.
///A full packet consits of 72 bytes.
class LiveTelemetry {
  // --- HEADER ---
  ///Byte Offset 0
  final int kernelTickCount;        

  // --- SENSORS ---
  ///Byte Offset 4
  final double batteryVoltage;
  ///Byte Offset 8
  final Vector3 accelerometer;
  ///Byte Offset 20
  final Vector3 gyroscope;
  ///Byte Offset 32           
  final Vector3 filteredGravity;    

  // --- GPS STATUS ---
  ///Byte Offset 44
  final bool isGpsFixValid;         

  // --- TIME (Packed - No Padding) ---
  ///Byte Offset 45
  final int year;
  ///Byte Offset 47                   
  final int month;
  ///Byte Offset 48                  
  final int day;
  ///Byte Offset 49                    
  final int hour;
  ///Byte Offset 50                   
  final int minute;
  ///Byte Offset 51                 
  final int second;
  ///Byte Offset 52                 
  final int millisecond;            

  // --- GPS DATA (Packed) ---
  ///Byte Offset 54
  final double latitude;
  ///Byte Offset 58            
  final double longitude;
  ///Byte Offset 62           
  final int gpsFixQuality;
  ///Byte Offset 63          
  final int gpsSatellites;
  ///Byte Offset 64          
  final double gpsSpeed;
  ///Byte Offset 68            
  final double gpsCourse;           

  LiveTelemetry({
    required this.kernelTickCount,
    required this.batteryVoltage,
    required this.accelerometer,
    required this.gyroscope,
    required this.filteredGravity,
    required this.isGpsFixValid,
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    required this.millisecond,
    required this.latitude,
    required this.longitude,
    required this.gpsFixQuality,
    required this.gpsSatellites,
    required this.gpsSpeed,
    required this.gpsCourse,
  });
  ///Supply a full packet of live data streamed from the pod and transforms it into a LiveTelemetry object.
  ///The function uses little Endian decoding as specified in pod documents.
  factory LiveTelemetry.fromBytes(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    
    double getFloat(int offset) => view.getFloat32(offset, Endian.little);
    int getUint8(int offset) => view.getUint8(offset);
    int getUint16(int offset) => view.getUint16(offset, Endian.little);
    int getUint32(int offset) => view.getUint32(offset, Endian.little);

    return LiveTelemetry(
      //Kernel Tick
      kernelTickCount: getUint32(0),

      //Battery voltage
      batteryVoltage: getFloat(4),
      
      //Sensors
      accelerometer: Vector3(x: getFloat(8), y: getFloat(12), z: getFloat(16)),
      gyroscope: Vector3(x: getFloat(20), y: getFloat(24), z: getFloat(28)),
      filteredGravity: Vector3(x: getFloat(32), y: getFloat(36), z: getFloat(40)),

      //GPS Fix (0x00 = Invalid, 0x01 = Valid)
      isGpsFixValid: getUint8(44) == 0x01,

      //Time (Packed)
      year: getUint16(45), 
      month: getUint8(47),
      day: getUint8(48),
      hour: getUint8(49),
      minute: getUint8(50),
      second: getUint8(51),
      millisecond: getUint16(52),

      //GPS Data (Packed)
      latitude: getFloat(54),
      longitude: getFloat(58),
      gpsFixQuality: getUint8(62),
      gpsSatellites: getUint8(63),
      gpsSpeed: getFloat(64),
      gpsCourse: getFloat(68),
    );
  }

  /// Returns NULL if the time is invalid (Year 0)
  DateTime? getTimestamp() {
    if (year == 0) return null; //Edge case for when the gps has no fix and return 0/0/0 0:0:0 as the date and time.
    return DateTime(year, month, day, hour, minute, second, millisecond);
  }
}