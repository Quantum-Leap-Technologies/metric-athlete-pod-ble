import 'dart:math';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/models/session_stats_model.dart';
import 'package:metric_athlete_pod_ble/models/stats_input_model.dart';

/// Comprehensive session analytics engine for GPS/IMU data.
///
/// Ported from `Mock-bluetooth-app-main/lib/utils/stats_calculator.dart` with
/// additional metrics for database integration (acceleration/deceleration counts,
/// HSR distance, fatigue index, etc.).
///
/// Designed to run via `compute()` isolate for performance.
class StatsCalculator {
  // --- CONFIGURATION ---
  static const double gravityMss = 9.80665;
  static const double maxValidSpeedKmh = 45.0;
  static const double maxValidGForce = 16.0;
  static const double impactThresholdG = 5.0;
  static const int smoothingWindow = 3;

  // Speed zone thresholds (km/h)
  static const double zoneResting = 1.8;
  static const double zoneWalking = 7.0;
  static const double zoneJogging = 18.0;
  static const double zoneRunning = 25.0;

  // Acceleration thresholds (m/s^2)
  static const double accelThreshold = 2.0;
  static const double decelThreshold = -2.0;

  // Metabolic power threshold for HMLD (W/kg)
  static const double hmldThresholdWkg = 25.5;

  /// Backward-compatible entry point: accepts raw logs only.
  /// Call via `compute(StatsCalculator.analyzeLogs, logs)`.
  static SessionStats analyzeLogs(List<SensorLog> logs) {
    return analyze(StatsInput(logs: logs));
  }

  /// Main analysis function. Call via `compute(StatsCalculator.analyze, input)`.
  static SessionStats analyze(StatsInput input) {
    final rawLogs = input.logs;
    final double? weightKg = input.weightKg;
    if (rawLogs.isEmpty) return const SessionStats();

    // -------------------------------------------------------
    // STEP 1: CLEANING & UNIT CONVERSION
    // -------------------------------------------------------
    final List<SensorLog> cleanLogs = [];
    final List<double> cleanGForces = [];

    for (var log in rawLogs) {
      if (log.latitude == 0 && log.longitude == 0) continue;

      double gx = log.filteredAccelX / gravityMss;
      double gy = log.filteredAccelY / gravityMss;
      double gz = log.filteredAccelZ / gravityMss;

      if (gx.abs() > maxValidGForce ||
          gy.abs() > maxValidGForce ||
          gz.abs() > maxValidGForce) {
        continue;
      }

      double gTotal = sqrt(gx * gx + gy * gy + gz * gz);
      cleanLogs.add(log);
      cleanGForces.add(gTotal);
    }

    if (cleanLogs.isEmpty) return const SessionStats();

    // -------------------------------------------------------
    // STEP 2: GPS PROCESSING (Resample → Smooth → Zone)
    // -------------------------------------------------------
    List<SensorLog> resampledLogs = _resampleTo1Hz(cleanLogs);
    List<double> rawSpeedsKmh = [];
    List<double> distsMeters = [];
    Map<int, String> secondToZoneMap = {};

    for (int i = 1; i < resampledLogs.length; i++) {
      double d = _haversine(
        resampledLogs[i - 1].latitude,
        resampledLogs[i - 1].longitude,
        resampledLogs[i].latitude,
        resampledLogs[i].longitude,
      );

      double speed = d * 3.6; // m/s → km/h
      if (speed > maxValidSpeedKmh) {
        speed = 0.0;
        d = 0.0;
      }

      rawSpeedsKmh.add(speed);
      distsMeters.add(d);
    }

    if (rawSpeedsKmh.isNotEmpty) {
      rawSpeedsKmh.insert(0, 0.0);
      distsMeters.insert(0, 0.0);
    }

    List<double> smoothSpeeds = _applySmoothing(rawSpeedsKmh);

    // Zone classification & distance accumulation
    double totalDist = 0.0;
    double activeDist = 0.0;
    double sprintDist = 0.0;
    double hsrDist = 0.0;
    double explosiveDist = 0.0;
    int sprints = 0;
    double topSpeed = 0.0;
    double speedSum = 0.0;
    int accelCount = 0;
    int decelCount = 0;
    double maxAccel = 0.0;
    int hsrEfforts = 0;
    double distToMaxSpeed = 0.0;
    bool prevAboveHsr = false;

    Map<String, double> zoneDist = {
      'Resting': 0.0, 'Walking': 0.0, 'Jogging': 0.0,
      'Running': 0.0, 'Sprinting': 0.0,
    };
    Map<String, int> impactCounts = {
      'Resting': 0, 'Walking': 0, 'Jogging': 0,
      'Running': 0, 'Sprinting': 0,
    };
    Map<String, int> zoneTime = {
      'Resting': 0, 'Walking': 0, 'Jogging': 0,
      'Running': 0, 'Sprinting': 0,
    };

    String prevZone = 'Resting';

    for (int i = 0; i < smoothSpeeds.length; i++) {
      double s = smoothSpeeds[i];
      double d = distsMeters[i];
      int epochSecond =
          resampledLogs[i].timestamp.millisecondsSinceEpoch ~/ 1000;

      totalDist += d;
      speedSum += s;
      if (s > topSpeed) {
        topSpeed = s;
        distToMaxSpeed = totalDist;
      }
      if (s > zoneResting) activeDist += d;

      String currentZone = _getZone(s);
      secondToZoneMap[epochSecond] = currentZone;

      zoneDist[currentZone] = (zoneDist[currentZone] ?? 0) + (d / 1000.0);
      zoneTime[currentZone] = (zoneTime[currentZone] ?? 0) + 1;

      // Sprint distance
      if (currentZone == 'Sprinting') sprintDist += d;
      // HSR: Running + Sprinting
      if (s >= zoneJogging) hsrDist += d;
      // Explosive: >20 km/h
      if (s >= 20.0) explosiveDist += d;

      // Sprint counter (rising edge)
      if (currentZone == 'Sprinting' && prevZone != 'Sprinting') sprints++;

      // HSR effort counter (rising edge crossing above zoneJogging)
      bool aboveHsr = s >= zoneJogging;
      if (aboveHsr && !prevAboveHsr) hsrEfforts++;
      prevAboveHsr = aboveHsr;

      // Acceleration/deceleration detection
      if (i > 0) {
        double deltaSpeed = (smoothSpeeds[i] - smoothSpeeds[i - 1]) / 3.6; // to m/s
        if (deltaSpeed > accelThreshold) accelCount++;
        if (deltaSpeed < decelThreshold) decelCount++;
        if (deltaSpeed > maxAccel) maxAccel = deltaSpeed;
      }

      prevZone = currentZone;
    }

    // -------------------------------------------------------
    // STEP 3: IMU ANALYSIS
    // -------------------------------------------------------
    double playerLoad = 0.0;
    int totalImpacts = 0;
    double maxImpact = 0.0;
    int hieCount = 0;

    for (int i = 0; i < cleanGForces.length; i++) {
      double g = cleanGForces[i];

      // Player load (accumulated dynamic acceleration)
      playerLoad += (g - 1.0).abs() * 0.01;

      if (g > maxImpact) maxImpact = g;

      // Impact detection (rising edge)
      if (g > impactThresholdG) {
        double prevG = (i > 0) ? cleanGForces[i - 1] : 0.0;
        if (prevG <= impactThresholdG) {
          totalImpacts++;
          hieCount++;

          int logSecond =
              cleanLogs[i].timestamp.millisecondsSinceEpoch ~/ 1000;
          String zoneAtTime = secondToZoneMap[logSecond] ?? 'Resting';
          impactCounts[zoneAtTime] = (impactCounts[zoneAtTime] ?? 0) + 1;
        }
      }
    }

    // -------------------------------------------------------
    // STEP 4: DERIVED METRICS
    // -------------------------------------------------------
    int durationSec = resampledLogs.length;
    double durationMin = durationSec / 60.0;
    double distPerMin = durationMin > 0 ? (totalDist / 1000.0) / durationMin : 0;
    double avgSpeed =
        resampledLogs.isNotEmpty ? speedSum / resampledLogs.length : 0;

    // Load score: player load normalized per minute
    double loadScore = durationMin > 0 ? playerLoad / durationMin : 0;

    // Session intensity: distance * load / duration
    double intensity = durationMin > 0
        ? ((totalDist / 1000.0) * playerLoad) / durationMin
        : 0;

    // Fatigue index: ratio of 2nd-half load to 1st-half load
    double fatigueIndex = 0;
    if (cleanGForces.length > 10) {
      int mid = cleanGForces.length ~/ 2;
      double firstHalf = 0, secondHalf = 0;
      for (int i = 0; i < mid; i++) {
        firstHalf += (cleanGForces[i] - 1.0).abs();
      }
      for (int i = mid; i < cleanGForces.length; i++) {
        secondHalf += (cleanGForces[i] - 1.0).abs();
      }
      if (firstHalf > 0) {
        fatigueIndex = (firstHalf - secondHalf) / firstHalf * 100.0;
      }
    }

    // GPS quality: percentage of logs with valid GPS fix
    int validGps = cleanLogs
        .where((l) => l.latitude.abs() > 0.001 && l.longitude.abs() > 0.001)
        .length;
    double gpsQuality =
        rawLogs.isNotEmpty ? (validGps / rawLogs.length) * 100.0 : 0;

    // -------------------------------------------------------
    // STEP 5: WEIGHT-DEPENDENT METABOLIC METRICS
    // -------------------------------------------------------
    double hmldDist = 0.0;
    double momentumPeak = 0.0;
    double energyKcal = 0.0;
    int powerPlayCount = 0;
    bool prevAboveHmld = false;

    if (weightKg != null && weightKg > 0 && smoothSpeeds.length > 1) {
      double topSpeedMs = topSpeed / 3.6;
      momentumPeak = weightKg * topSpeedMs;

      for (int i = 1; i < smoothSpeeds.length; i++) {
        double speedMs = smoothSpeeds[i] / 3.6;
        double prevSpeedMs = smoothSpeeds[i - 1] / 3.6;
        double dt = 1.0; // 1 Hz resampled
        double accel = (speedMs - prevSpeedMs) / dt;
        double d = distsMeters[i];

        // di Prampero metabolic power model (simplified):
        // Equivalent slope = accel / gravity
        // Energy cost of running on slope ≈ (3.6 * ES + 3.5) * speed (J/kg/m → W/kg)
        double es = accel / gravityMss;
        double energyCostJPerKgPerM = 3.6 * es + 3.5;
        if (energyCostJPerKgPerM < 0) energyCostJPerKgPerM = 0;
        double metPowerWPerKg = energyCostJPerKgPerM * speedMs;

        // HMLD: distance where metabolic power > threshold
        bool aboveHmld = metPowerWPerKg > hmldThresholdWkg;
        if (aboveHmld) hmldDist += d;
        if (aboveHmld && !prevAboveHmld) powerPlayCount++;
        prevAboveHmld = aboveHmld;

        // Energy: integrate power over time
        double powerWatts = metPowerWPerKg * weightKg;
        energyKcal += (powerWatts * dt) / 4184.0; // J → kcal
      }
    }

    double hmldPct = totalDist > 0 ? (hmldDist / totalDist) * 100.0 : 0;
    double hmldPerMin = durationMin > 0 ? hmldDist / durationMin : 0;

    // -------------------------------------------------------
    // STEP 6: PERSONAL BEST METRICS
    // -------------------------------------------------------
    double personalMaxPct = 0.0;
    bool above90 = false;
    final personalMaxMs = input.personalMaxSpeedMs;
    if (personalMaxMs != null && personalMaxMs > 0) {
      double topSpeedMs = topSpeed / 3.6;
      personalMaxPct = (topSpeedMs / personalMaxMs) * 100.0;
      above90 = personalMaxPct >= 90.0;
    }

    return SessionStats(
      totalDistanceKm: totalDist / 1000.0,
      activeDistanceKm: activeDist / 1000.0,
      distancePerMin: distPerMin,
      sprintDistance: sprintDist / 1000.0,
      hsrDistance: hsrDist / 1000.0,
      explosiveDistance: explosiveDist / 1000.0,
      topSpeedKmh: topSpeed,
      avgSpeedKmh: avgSpeed,
      sprintCount: sprints,
      accelerationCount: accelCount,
      decelerationCount: decelCount,
      maxAcceleration: maxAccel,
      impactCount: totalImpacts,
      maxImpactG: maxImpact,
      hieCount: hieCount,
      playerLoad: playerLoad,
      loadScore: loadScore,
      sessionIntensity: intensity,
      fatigueIndex: fatigueIndex,
      hsrEfforts: hsrEfforts,
      distanceToMaxSpeedM: distToMaxSpeed,
      hmldDistanceM: hmldDist,
      hmldPercentage: hmldPct,
      hmldPerMin: hmldPerMin,
      momentumPeak: momentumPeak,
      energyKcal: energyKcal,
      powerPlayCount: powerPlayCount,
      personalMaxPercentage: personalMaxPct,
      above90PercentMax: above90,
      gpsQualityPercentage: gpsQuality,
      dataGapsCount: 0, // Populated by filter pipeline
      durationSeconds: durationSec,
      zoneDistances: zoneDist,
      impactCountsByZone: impactCounts,
      zoneTimeSeconds: zoneTime,
    );
  }

  // --- HELPERS ---

  static List<SensorLog> _resampleTo1Hz(List<SensorLog> logs) {
    if (logs.isEmpty) return [];
    List<SensorLog> resampled = [];
    DateTime? lastSecond;

    for (var log in logs) {
      DateTime currentSecond = DateTime(
        log.timestamp.year, log.timestamp.month, log.timestamp.day,
        log.timestamp.hour, log.timestamp.minute, log.timestamp.second,
      );

      if (lastSecond == null || currentSecond.isAfter(lastSecond)) {
        resampled.add(log);
        lastSecond = currentSecond;
      }
    }
    return resampled;
  }

  static List<double> _applySmoothing(List<double> rawSpeeds) {
    List<double> smoothed = List.filled(rawSpeeds.length, 0.0);
    for (int i = 0; i < rawSpeeds.length; i++) {
      double sum = 0.0;
      int count = 0;
      for (int offset = -1; offset <= 1; offset++) {
        int idx = i + offset;
        if (idx >= 0 && idx < rawSpeeds.length) {
          sum += rawSpeeds[idx];
          count++;
        }
      }
      smoothed[i] = sum / count;
    }
    return smoothed;
  }

  static String _getZone(double speedKmh) {
    if (speedKmh < zoneResting) return 'Resting';
    if (speedKmh < zoneWalking) return 'Walking';
    if (speedKmh < zoneJogging) return 'Jogging';
    if (speedKmh < zoneRunning) return 'Running';
    return 'Sprinting';
  }

  static double _haversine(
      double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    var dLat = _toRadians(lat2 - lat1);
    var dLon = _toRadians(lon2 - lon1);
    var a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) *
            cos(_toRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    var c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return R * c;
  }

  static double _toRadians(double degree) => degree * pi / 180;
}
