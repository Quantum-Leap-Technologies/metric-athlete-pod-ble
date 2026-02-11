import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:metric_athlete_pod_ble/models/live_data_model.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
///Class contains functions used to save .bin files and [SensorLog] lists as .csv files.
class StorageService {
  
  //Returns the application document directory path.
  Future<String> _getDirPath() async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path;
  }

  ///Takes the raw bytes of a downloaded .bin file and stores a .bin file in the filepath directory.
  ///Use the filename string to set the name of the .bin file.
  Future<File> saveRawBin(String filename, Uint8List bytes) async {
    final path = await _getDirPath();
    String name = filename.endsWith('.bin') ? filename : '$filename.bin';
    final file = File('$path/$name');
    return await file.writeAsBytes(bytes);
  }

  ///Takes a list of [SensorLog] objects and saves the content to a .csv file.
  ///Use the [filename] to set the name of the file.
  ///The file headers will be the fields of the [SensorLog] object.
  Future<File> saveSensorLogsToCsv(List<SensorLog> logs, String filename) async {
    final path = await _getDirPath();
    
    // Swap extension from .bin to .csv
    String csvName = filename.replaceAll('.bin', '.csv');
    if (!csvName.endsWith('.csv')) csvName += '.csv';

    final file = File('$path/$csvName');

    // Build CSV String using StringBuffer
    StringBuffer sb = StringBuffer();
    
    // Headers
    sb.writeln("Timestamp,KernelCount,Lat,Lon,Speed_Kph,AccelX,AccelY,AccelZ,GyroX,GyroY,GyroZ,FiltAccelX,FiltAccelY,FiltAccelZ");

    // Rows
    for (var log in logs) {
      sb.writeln(
        "${log.timestamp.toIso8601String()},"
        "${log.packetId},"
        "${log.latitude},"
        "${log.longitude},"
        "${log.speed},"
        "${log.accelX},"
        "${log.accelY},"
        "${log.accelZ},"
        "${log.gyroX},"
        "${log.gyroY},"
        "${log.gyroZ},"
        "${log.filteredAccelX},"
        "${log.filteredAccelY},"
        "${log.filteredAccelZ}"
      );
    }

    await file.writeAsString(sb.toString());
    return file;
  }

  ///Returns all the saved csv files in the filepath directory.
  ///The list is sorted by newest and last modified.
  Future<List<File>> getAllCsvSessions() async {
    final path = await _getDirPath();
    final dir = Directory(path);
    
    if (!dir.existsSync()) return [];

    // List files, filter for .csv, sort by date (newest first)
    List<File> files = dir.listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.csv'))
        .toList();

    // Sort by Modification Date (Newest first)
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    
    return files;
  }

  ///Used to extract a saved csv file into a list of [SensorLog] objects.
  ///Takes the file as an input and returns a list of [SensorLog] objects.
  ///File needs to contain at least two rows(one row of data and one row of headers).
  ///Function skips malformed rows to prevent crashes.
  ///Returns an empty list if an error occured while processing the file.
  ///Uses streaming line-by-line reading to avoid loading the entire file into memory.
  Future<List<SensorLog>> readCsvFile(File file) async {
    try {
      final List<SensorLog> logs = [];
      bool isHeader = true;

      // Stream the file line-by-line to avoid loading the entire file into memory
      final stream = file.openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stream) {
        // Skip header row
        if (isHeader) {
          isHeader = false;
          continue;
        }

        final row = line.split(',');

        // Ensure row has the correct amount of columns (SensorLog fields)
        if (row.length < 14) continue;

        try {
          logs.add(SensorLog(
            timestamp: DateTime.parse(row[0]),
            packetId: int.tryParse(row[1]) ?? 0,
            latitude: double.tryParse(row[2]) ?? 0.0,
            longitude: double.tryParse(row[3]) ?? 0.0,
            speed: double.tryParse(row[4]) ?? 0.0,
            accelX: double.tryParse(row[5]) ?? 0.0,
            accelY: double.tryParse(row[6]) ?? 0.0,
            accelZ: double.tryParse(row[7]) ?? 0.0,
            gyroX: double.tryParse(row[8]) ?? 0.0,
            gyroY: double.tryParse(row[9]) ?? 0.0,
            gyroZ: double.tryParse(row[10]) ?? 0.0,
            filteredAccelX: double.tryParse(row[11]) ?? 0.0,
            filteredAccelY: double.tryParse(row[12]) ?? 0.0,
            filteredAccelZ: double.tryParse(row[13]) ?? 0.0,
          ));
        } catch (e) {
          // Skip malformed lines (prevents crash on corrupted rows)
          continue;
        }
      }
      return logs;
    } catch (e) {
      return [];
    }
  }

  ///Takes the data from a file in string format and saves it to a .csv file.
  ///Primarily used when saving the splitted session files.
  Future<File> saveStringAsCsv(String filename, String content) async {
    final path = await _getDirPath();
    final file = File('$path/$filename');
    
    await file.writeAsString(content);
    return file;
  }


  /// Saves a list of [LiveTelemetry] objects to a CSV file.
  /// Used for "Live Recording" sessions to capture high-fidelity debug data.
  Future<File> saveLiveTelemetryToCsv(List<LiveTelemetry> logs, String fileName) async {
    // 1. Get Directory
    final directory = await getApplicationDocumentsDirectory();
    final path = "${directory.path}/$fileName";
    final file = File(path);

    StringBuffer csvBuffer = StringBuffer();

    // 2. Write Header (Matches your Class Fields)
    csvBuffer.writeln(
      "Timestamp,KernelTick,Battery,"
      "AccelX,AccelY,AccelZ,"
      "GyroX,GyroY,GyroZ,"
      "GravX,GravY,GravZ," // Derived from filteredGravity
      "Lat,Lon,Speed,Course,"
      "FixValid,Satellites,FixQuality"
    );

    // 3. Write Rows
    for (var log in logs) {
      // safely get timestamp, defaulting to ISO string or "Invalid" if Year is 0
      final dt = log.getTimestamp();
      final timeStr = dt?.toIso8601String() ?? "Invalid_Time";

      csvBuffer.writeln(
        "$timeStr,"
        "${log.kernelTickCount},"
        "${log.batteryVoltage.toStringAsFixed(2)},"
        
        // Flatten Vector3 Accelerometer
        "${log.accelerometer.x.toStringAsFixed(3)},"
        "${log.accelerometer.y.toStringAsFixed(3)},"
        "${log.accelerometer.z.toStringAsFixed(3)},"
        
        // Flatten Vector3 Gyroscope
        "${log.gyroscope.x.toStringAsFixed(3)},"
        "${log.gyroscope.y.toStringAsFixed(3)},"
        "${log.gyroscope.z.toStringAsFixed(3)},"
        
        // Flatten Vector3 Filtered Gravity
        "${log.filteredGravity.x.toStringAsFixed(3)},"
        "${log.filteredGravity.y.toStringAsFixed(3)},"
        "${log.filteredGravity.z.toStringAsFixed(3)},"
        
        // GPS Data
        "${log.latitude.toStringAsFixed(6)},"
        "${log.longitude.toStringAsFixed(6)},"
        "${log.gpsSpeed.toStringAsFixed(2)},"
        "${log.gpsCourse.toStringAsFixed(1)},"
        
        // Status Flags
        "${log.isGpsFixValid ? 1 : 0},"
        "${log.gpsSatellites},"
        "${log.gpsFixQuality}"
      );
    }

    // 4. Save to Disk
    return await file.writeAsString(csvBuffer.toString());
  }
}