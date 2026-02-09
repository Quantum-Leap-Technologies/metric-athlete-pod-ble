import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';

/// Wrapper for StatsCalculator input, allowing optional player data
/// to be passed alongside sensor logs for weight-dependent metrics.
class StatsInput {
  final List<SensorLog> logs;
  final double? weightKg;
  final double? personalMaxSpeedMs;

  const StatsInput({
    required this.logs,
    this.weightKg,
    this.personalMaxSpeedMs,
  });
}
