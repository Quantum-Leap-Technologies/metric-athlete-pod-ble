///Class used to store a row of data extracted from .bin and .csv files.
///The class stores the full 64 bytes of a row of data.
///The row of data is extracted to usable information using the [BinaryParser] for .bin files and the [StorageService] for .csv files.
class SensorLog {
  ///Kernel count.
  
  final int packetId;
  ///Time stamp containig the date and time in the format yyyy/MM/dd hh:mm:ss.SSS
  final DateTime timestamp;
  
  ///GPS latitude coordinate
  final double latitude;
  ///GPS longtitude coordinate
  final double longitude;
  ///GPS speed in km/h
  final double speed; 
  
  // Raw IMU data
  ///Accelerometer X-axis measurement in m/s^2
  final double accelX;
  ///Accelerometer Y-axis measurement in m/s^2
  final double accelY;
  ///Accelerometer Z-axis measurement in m/s^2
  final double accelZ;
  ///Gyroscope X-axis measurement in rads/s
  final double gyroX;
  ///Gyroscope Y-axis measurement in rads/s
  final double gyroY;
  ///Gyroscope Z-axis measurement in rads/s
  final double gyroZ;

  // Filtered IMU data from sensor to compensate for gravity
  ///Accelerometer X-axis measurement in m/s^2. Filtered to compensate for gravity using the gyroscope sensor. Measurement supplied by pod.
  final double filteredAccelX;
  ///Accelerometer Y-axis measurement in m/s^2. Filtered to compensate for gravity using the gyroscope sensor. Measurement supplied by pod.
  final double filteredAccelY;
  ///Accelerometer Z-axis measurement in m/s^2. Filtered to compensate for gravity using the gyroscope sensor. Measurement supplied by pod.
  final double filteredAccelZ;

  SensorLog({
    required this.packetId, 
    required this.timestamp, 
    required this.latitude, 
    required this.longitude, 
    required this.speed, 
    required this.accelX, 
    required this.accelY, 
    required this.accelZ,
    required this.gyroX, 
    required this.gyroY, 
    required this.gyroZ,
    required this.filteredAccelX,
    required this.filteredAccelY,
    required this.filteredAccelZ,
  });

  /// Creates a copy of this SensorLog but with the given fields replaced with the new values.
  /// Essential for immutable state updates in Riverpod/Bloc.
  SensorLog copyWith({
    int? packetId,
    DateTime? timestamp,
    double? latitude,
    double? longitude,
    double? speed,
    double? accelX,
    double? accelY,
    double? accelZ,
    double? gyroX,
    double? gyroY,
    double? gyroZ,
    double? filteredAccelX,
    double? filteredAccelY,
    double? filteredAccelZ,
  }) {
    return SensorLog(
      packetId: packetId ?? this.packetId,
      timestamp: timestamp ?? this.timestamp,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      speed: speed ?? this.speed,
      accelX: accelX ?? this.accelX,
      accelY: accelY ?? this.accelY,
      accelZ: accelZ ?? this.accelZ,
      gyroX: gyroX ?? this.gyroX,
      gyroY: gyroY ?? this.gyroY,
      gyroZ: gyroZ ?? this.gyroZ,
      filteredAccelX: filteredAccelX ?? this.filteredAccelX,
      filteredAccelY: filteredAccelY ?? this.filteredAccelY,
      filteredAccelZ: filteredAccelZ ?? this.filteredAccelZ,
    );
  }
}