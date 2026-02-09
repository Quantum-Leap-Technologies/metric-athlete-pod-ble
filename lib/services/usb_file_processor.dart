import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/services/storage_service.dart';
import 'package:metric_athlete_pod_ble/utils/logs_binary_parser.dart';
import 'package:metric_athlete_pod_ble/utils/trajectory_filter.dart';
import '../utils/usb_file_predictor.dart';
///Class containing functions to identify, filter and save .bin files to .csv files.
///The .bin files need to follow the SensorLog fields and BinaryParser format to be valid. 
class UsbFileProcessor {

///Uses the [start] and [end] time to search for valid .bin files the user chooses through the file picker.
///The raw data is then extracted and filtered from the files and stored as a single csv file.
///The [playerName] is used as a unique identifier in the name of the file.
///Returns the count of the [SensorLog] objects added to the save file.
///Will return 0 if the user cancels the process or no files are found.
  static Future<int> pickProcessAndSave({
    required String playerName,
    required DateTime start,
    required DateTime end,
  }) async {
    
    //Opens the file picker and filters acceptable files as .bin files.
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['bin'],
      allowMultiple: true,
      withData: false,
    );

    if (result == null || result.files.isEmpty) return 0;

    //Takes the user selected files and searches for files containing the begin time and starts before the end time.
    final validFiles = await _filterSelectedFiles(
      candidates: result.files, 
      windowStart: start, 
      windowEnd: end
    );

    if (validFiles.isEmpty) return 0;

    //Extracts the files to Sensor logs for filtering and concatenation.
    final cleanLogs = await _extractAll(
      validFiles: validFiles,
    );

    if (cleanLogs.isEmpty) return 0;

    //Saves the concatenated sensor logs to a single csv file.
    try {
      final storage = StorageService();
      final dateStr = DateFormat('yyyyMMdd_HHmm').format(start);
      final endDateStr = DateFormat('yyyyMMdd_HHmm').format(end);
      final filename = "${playerName}_$dateStr-$endDateStr";
      
      await storage.saveSensorLogsToCsv(cleanLogs, filename);
      
      return cleanLogs.length; // Return success count
    } catch (e) {
      return 0;
    }
  }

  
  ///Takes a list of .bin files and filters the [candidates] based on a start and end time.
  ///The file must either contain the [windowStart] or starts before the [windowEnd] to be a valid file.
  ///Requires a list of files to filter, a start time and end time in date format.
  ///Returns a filtered list of File objects
  static Future<List<File>> _filterSelectedFiles({
    required List<PlatformFile> candidates, 
    required DateTime windowStart, 
    required DateTime windowEnd
  }) async {
    final List<File> matches = [];
    final String datePattern = DateFormat('yyyyMMdd').format(windowStart);

    for (var pFile in candidates) {
      if (pFile.path == null) continue;
      
      // Stage 1: Filename
      if (!pFile.name.contains(datePattern)) continue; 

      // Stage 2: Binary Peeker
      final bounds = await UsbFilePredictor.getFileBounds(pFile.path!);
      if (bounds != null) {
        if (windowStart.isBefore(bounds.end) && windowEnd.isAfter(bounds.start)) {
          matches.add(File(pFile.path!));
        }
      }
    }
    return matches;
  }


  ///Takes the [validFiles] list and extracts each file's raw content to [SensorLog] Objects.
  ///The [SensorLog] objects returned are filtered for data validity using the [TrajectoryFilter].
  static Future<List<SensorLog>> _extractAll({
    required List<File> validFiles,
  }) async {
    List<SensorLog> finalProcessedLogs = [];

    for (var file in validFiles) {
      // 1. Read and Parse the individual file
      final bytes = await file.readAsBytes();
      final rawLogs = BinaryParser.parseBytes(bytes);

      if (rawLogs.isEmpty) continue;

      // 2. Sort this specific file's logs
      rawLogs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      // 3. Filter this session independently in a background Isolate
      // This prevents the filter from "jumping" across time gaps between files
      final filteredFileLogs = await compute(TrajectoryFilter.process, rawLogs);

      // 4. Add the clean results to our master list
      finalProcessedLogs.addAll(filteredFileLogs.logs);
    }

    // Final chronological sort of the total collection
    finalProcessedLogs.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    return finalProcessedLogs;
  }
}