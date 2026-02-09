import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';

/// Class used to separate raw session data into distinct sessions.
/// It uses the sensor logs' timestamps to identify gaps in data recording.
class SessionClusterer {
  
  /// The time threshold used to split sessions, measured in minutes.
  /// If the gap between two logs exceeds this value, a new session begins.
  /// Can be fine-tuned to split sessions more accurately.
  static const int sessionGapThreshold = 10;

  /// The minimum duration (in minutes) a session must last to be considered valid.
  /// Sessions shorter than this are discarded as noise or test data.
  static const int minSessionDuration = 5;

  /// Returns a list of [SensorLog] lists, where each inner list represents a valid session.
  ///
  /// Logic:
  /// 1. Sorts logs by time to ensure data integrity.
  /// 2. Iterates through logs; if the time gap between two logs > [sessionGapThreshold], the current session ends.
  /// 3. Filters out any resulting sessions shorter than [minSessionDuration].
  static List<List<SensorLog>> cluster(List<SensorLog> fullLogs) {
    if (fullLogs.isEmpty) return [];

    // Sort by Time to maintain data integrity.
    fullLogs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    List<List<SensorLog>> clusters = [];
    List<SensorLog> currentBuffer = [];

    for (int i = 0; i < fullLogs.length; i++) {
      var currentLog = fullLogs[i];

      if (currentBuffer.isEmpty) {
        currentBuffer.add(currentLog);
        continue;
      }

      var lastLog = currentBuffer.last;
      int gapMinutes = currentLog.timestamp.difference(lastLog.timestamp).inMinutes.abs();

      // If the gap is too large, push the current buffer as a finished session.
      if (gapMinutes > sessionGapThreshold) {
        if (_isValid(currentBuffer)) {
             clusters.add(List.from(currentBuffer));
        }
        currentBuffer = [currentLog]; // Start new session
      } else {
        currentBuffer.add(currentLog);
      }
    }

    // Don't forget the final buffer remaining after the loop ends
    if (_isValid(currentBuffer)) {
        clusters.add(List.from(currentBuffer));
    }
    
    return clusters;
  }

  /// Helper function used to filter out sessions that are shorter than [minSessionDuration].
  static bool _isValid(List<SensorLog> logs) {
    if (logs.isEmpty) return false;
    return logs.last.timestamp.difference(logs.first.timestamp).inMinutes >= minSessionDuration;
  }
}