import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
///Class used to store the data of a session identified by the session splitter in [sessionClusterer].
///The class contains the logs associated with the session as well as Estimated statistics the user can use to identify the session and its type.
class SessionBlock {
  ///Start time of the session.
  final DateTime startTime;
  ///End time of the session.
  final DateTime endTime;
  ///[SensorLog] list containing the data of the session.
  final List<SensorLog> logs;
  ///Duration of the session.
  final Duration duration;
  
  //Estimated statistics the user can use to identify the session and its type.

  ///Estimated distance in meters.
  final double totalDistMeters;
  ///Estimated top speed in km/h.
  final double topSpeedKmh;
  ///Estimated average speed km/h
  final double avgSpeedKmh;

  SessionBlock({
    required this.startTime,
    required this.endTime,
    required this.logs,
    required this.duration,
    required this.totalDistMeters,
    required this.topSpeedKmh,
    required this.avgSpeedKmh,
  });
}