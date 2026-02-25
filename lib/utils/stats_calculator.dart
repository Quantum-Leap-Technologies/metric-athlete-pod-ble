import 'dart:math';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';
import 'package:metric_athlete_pod_ble/models/session_stats_model.dart';
import 'package:metric_athlete_pod_ble/models/stats_input_model.dart';

/// Comprehensive session analytics engine for GPS/IMU data.
///
/// Calculates 41+ metrics from raw GPS/IMU sensor logs using validated
/// sports science formulas:
/// - Metabolic power: Minetti et al. (2002) / Osgnach et al. (2010) polynomial
/// - Player Load: Boyd et al. (2011) triaxial delta formula
/// - HIE: Multi-criteria 5-second window detection
///
/// Designed to run via `compute()` isolate for performance.
class StatsCalculator {
  // --- CONFIGURATION ---
  static const double gravityMss = 9.80665; // SI standard gravity (m/s²)
  static const double maxValidSpeedKmh = 45.0;
  static const double maxValidGForce = 16.0;
  static const double impactThresholdG = 5.0;
  static const int smoothingWindow = 3;

  // Speed zone thresholds (km/h) — aligned with MetricsCalculator
  static const double zoneResting = 1.8;
  static const double zoneWalking = 7.0;
  static const double zoneHSR = 19.8; // 5.5 m/s × 3.6
  static const double zoneSprinting = 25.2; // 7.0 m/s × 3.6

  // Activity threshold (km/h) — movement above this is "active"
  static const double zoneActivity = 7.2; // 2.0 m/s × 3.6

  // Acceleration thresholds (m/s²)
  static const double accelThreshold = 3.0; // high-intensity accel
  static const double decelThreshold = -3.0; // high-intensity decel

  // Power play thresholds
  static const double powerPlaySpeedMs = 4.0; // m/s
  static const double powerPlayAccelMs2 = 2.5; // m/s²

  // Impact threshold (deceleration in m/s²)
  static const double impactDecelMs2 = 3.0;

  // Metabolic power threshold for HMLD (W/kg)
  static const double hmldThresholdWkg = 25.5;

  // Minimum event duration (seconds) for accel/decel events
  static const double minEventDurationSec = 0.3;

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

      double speed = d * 3.6; // m/s → km/h (at 1Hz, d in meters = speed in m/s)
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
    int sprints = 0;
    double topSpeed = 0.0;
    double speedSum = 0.0;
    int hsrEfforts = 0;
    double distToMaxSpeed = 0.0;
    bool prevAboveHsr = false;

    // Acceleration event detection (rising-edge, per-event not per-sample)
    int accelEventCount = 0;
    int decelEventCount = 0;
    double maxAccel = 0.0;
    bool inAccelEvent = false;
    bool inDecelEvent = false;
    int accelEventStartIdx = 0;
    int decelEventStartIdx = 0;

    // Power play detection (speed + accel combination)
    int powerPlayCount = 0;

    Map<String, double> zoneDist = {
      'Resting': 0.0,
      'Walking': 0.0,
      'Jogging': 0.0,
      'Running': 0.0,
      'Sprinting': 0.0,
    };
    Map<String, int> impactCounts = {
      'Resting': 0,
      'Walking': 0,
      'Jogging': 0,
      'Running': 0,
      'Sprinting': 0,
    };
    Map<String, int> zoneTime = {
      'Resting': 0,
      'Walking': 0,
      'Jogging': 0,
      'Running': 0,
      'Sprinting': 0,
    };

    String prevZone = 'Resting';

    // Track per-sample data for power play and accel event detection
    List<double> accelValues = []; // m/s² per sample
    List<double> speedMsValues = []; // m/s per sample

    for (int i = 0; i < smoothSpeeds.length; i++) {
      double s = smoothSpeeds[i];
      double d = distsMeters[i];
      int epochSecond =
          resampledLogs[i].timestamp.millisecondsSinceEpoch ~/ 1000;

      double speedMs = s / 3.6;
      speedMsValues.add(speedMs);

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

      // Sprint distance (>25.2 km/h = 7.0 m/s)
      if (s >= zoneSprinting) sprintDist += d;
      // HSR distance (>19.8 km/h = 5.5 m/s)
      if (s >= zoneHSR) hsrDist += d;

      // Sprint counter (rising edge)
      if (currentZone == 'Sprinting' && prevZone != 'Sprinting') sprints++;

      // HSR effort counter (rising edge)
      bool aboveHsr = s >= zoneHSR;
      if (aboveHsr && !prevAboveHsr) hsrEfforts++;
      prevAboveHsr = aboveHsr;

      // Acceleration/deceleration — per-event counting (rising edge)
      if (i > 0) {
        double deltaSpeedMs =
            (smoothSpeeds[i] - smoothSpeeds[i - 1]) / 3.6; // km/h → m/s
        accelValues.add(deltaSpeedMs);

        if (deltaSpeedMs > maxAccel) maxAccel = deltaSpeedMs;

        // Acceleration event detection
        if (deltaSpeedMs > accelThreshold) {
          if (!inAccelEvent) {
            inAccelEvent = true;
            accelEventStartIdx = i;
          }
          // Check for power play: speed > 4.0 m/s AND accel > 2.5 m/s²
          if (speedMs > powerPlaySpeedMs && deltaSpeedMs > powerPlayAccelMs2) {
            // Will count the event when it ends
          }
        } else if (inAccelEvent) {
          // Event ended — check if it meets minimum duration
          double eventDuration = (i - accelEventStartIdx).toDouble(); // seconds at 1Hz
          if (eventDuration >= minEventDurationSec) {
            accelEventCount++;
            // Check if any sample in the event qualified as a power play
            bool isPowerPlay = false;
            for (int j = accelEventStartIdx; j < i; j++) {
              if (j < speedMsValues.length && j < accelValues.length) {
                if (speedMsValues[j] > powerPlaySpeedMs &&
                    accelValues[j - 1] > powerPlayAccelMs2) {
                  isPowerPlay = true;
                  break;
                }
              }
            }
            if (isPowerPlay) powerPlayCount++;
          }
          inAccelEvent = false;
        }

        // Deceleration event detection
        if (deltaSpeedMs < decelThreshold) {
          if (!inDecelEvent) {
            inDecelEvent = true;
            decelEventStartIdx = i;
          }
        } else if (inDecelEvent) {
          double eventDuration = (i - decelEventStartIdx).toDouble();
          if (eventDuration >= minEventDurationSec) {
            decelEventCount++;
          }
          inDecelEvent = false;
        }
      } else {
        accelValues.add(0.0);
      }

      prevZone = currentZone;
    }

    // Close any open events at the end
    if (inAccelEvent) {
      double eventDuration =
          (smoothSpeeds.length - accelEventStartIdx).toDouble();
      if (eventDuration >= minEventDurationSec) accelEventCount++;
    }
    if (inDecelEvent) {
      double eventDuration =
          (smoothSpeeds.length - decelEventStartIdx).toDouble();
      if (eventDuration >= minEventDurationSec) decelEventCount++;
    }

    // -------------------------------------------------------
    // STEP 3: IMU ANALYSIS — Player Load (Boyd formula)
    // -------------------------------------------------------
    double playerLoad = 0.0;
    int totalImpacts = 0;
    double maxImpact = 0.0;

    for (int i = 0; i < cleanLogs.length; i++) {
      double g = cleanGForces[i];
      if (g > maxImpact) maxImpact = g;

      // Player Load: Boyd et al. (2011) — √(Δax² + Δay² + Δaz²)
      // Uses filtered accelerometer values converted to G-force
      if (i > 0) {
        double gxCurr = cleanLogs[i].filteredAccelX / gravityMss;
        double gyCurr = cleanLogs[i].filteredAccelY / gravityMss;
        double gzCurr = cleanLogs[i].filteredAccelZ / gravityMss;
        double gxPrev = cleanLogs[i - 1].filteredAccelX / gravityMss;
        double gyPrev = cleanLogs[i - 1].filteredAccelY / gravityMss;
        double gzPrev = cleanLogs[i - 1].filteredAccelZ / gravityMss;

        double dx = gxCurr - gxPrev;
        double dy = gyCurr - gyPrev;
        double dz = gzCurr - gzPrev;

        playerLoad += sqrt(dx * dx + dy * dy + dz * dz);
      }

      // Impact detection (rising edge of total G-force)
      if (g > impactThresholdG) {
        double prevG = (i > 0) ? cleanGForces[i - 1] : 0.0;
        if (prevG <= impactThresholdG) {
          totalImpacts++;

          int logSecond =
              cleanLogs[i].timestamp.millisecondsSinceEpoch ~/ 1000;
          String zoneAtTime = secondToZoneMap[logSecond] ?? 'Resting';
          impactCounts[zoneAtTime] = (impactCounts[zoneAtTime] ?? 0) + 1;
        }
      }
    }

    // Scale player load by /100 (Boyd convention)
    playerLoad /= 100.0;

    // -------------------------------------------------------
    // STEP 4: HIE DETECTION — Multi-criteria 5-second window
    // -------------------------------------------------------
    int hieCount = 0;
    if (smoothSpeeds.length > 5) {
      int windowSize = 5; // 5 seconds at 1Hz
      int idx = 0;
      while (idx < smoothSpeeds.length) {
        int windowEnd = min(idx + windowSize, smoothSpeeds.length);

        int criteriaCount = 0;
        bool hasHighAccel = false;
        bool hasHighDecel = false;
        bool hasSprint = false;

        for (int j = idx; j < windowEnd; j++) {
          if (smoothSpeeds[j] >= zoneSprinting) hasSprint = true;
          if (j > 0 && j - 1 < accelValues.length) {
            if (accelValues[j - 1] > accelThreshold) hasHighAccel = true;
            if (accelValues[j - 1] < decelThreshold) hasHighDecel = true;
          }
        }

        if (hasHighAccel) criteriaCount++;
        if (hasHighDecel) criteriaCount++;
        if (hasSprint) criteriaCount++;
        // HMLD criterion checked in Step 5 if weight available

        if (criteriaCount >= 3) {
          hieCount++;
          idx = windowEnd; // Skip to end of window (non-overlapping)
        } else {
          idx++;
        }
      }
    }

    // -------------------------------------------------------
    // STEP 5: DERIVED METRICS
    // -------------------------------------------------------

    // Duration from timestamps (not sample count)
    int durationSec;
    if (resampledLogs.length >= 2) {
      durationSec = resampledLogs.last.timestamp
              .difference(resampledLogs.first.timestamp)
              .inSeconds +
          1;
    } else {
      durationSec = resampledLogs.length;
    }
    double durationMin = durationSec / 60.0;

    // Distance per minute in m/min (not km/min)
    double distPerMin = durationMin > 0 ? totalDist / durationMin : 0;

    double avgSpeed =
        resampledLogs.isNotEmpty ? speedSum / resampledLogs.length : 0;

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

    // GPS quality: percentage of clean logs with valid GPS fix
    int validGps = cleanLogs
        .where((l) => l.latitude.abs() > 0.001 && l.longitude.abs() > 0.001)
        .length;
    double gpsQuality =
        cleanLogs.isNotEmpty ? (validGps / cleanLogs.length) * 100.0 : 0;

    // -------------------------------------------------------
    // STEP 6: WEIGHT-DEPENDENT METABOLIC METRICS
    // -------------------------------------------------------
    double hmldDist = 0.0;
    double momentumPeak = 0.0;
    double energyKcal = 0.0;

    if (weightKg != null && weightKg > 0 && smoothSpeeds.length > 1) {
      double topSpeedMs = topSpeed / 3.6;
      momentumPeak = weightKg * topSpeedMs;

      for (int i = 1; i < smoothSpeeds.length; i++) {
        double speedMs = smoothSpeeds[i] / 3.6;
        double prevSpeedMs = smoothSpeeds[i - 1] / 3.6;
        double dt = 1.0; // 1 Hz resampled
        double accel = (speedMs - prevSpeedMs) / dt;
        double d = distsMeters[i];

        // Minetti et al. (2002) / Osgnach et al. (2010) metabolic power
        double metPowerWPerKg =
            _calculateMetabolicPower(speedMs, accel);

        // HMLD: distance where metabolic power > threshold
        if (metPowerWPerKg > hmldThresholdWkg) hmldDist += d;

        // Energy: integrate power over time
        double powerWatts = metPowerWPerKg * weightKg;
        energyKcal += (powerWatts * dt) / 4184.0; // J → kcal
      }
    }

    // Explosive distance = HMLD - HSR (metabolic load not from high-speed running)
    double explosiveDist = max(0.0, hmldDist - hsrDist);

    double hmldPct = totalDist > 0 ? (hmldDist / totalDist) * 100.0 : 0;
    double hmldPerMin = durationMin > 0 ? hmldDist / durationMin : 0;

    // Session intensity classification (GREEN/AMBER/RED)
    String sessionIntensityStr;
    if (hmldPerMin < 10) {
      sessionIntensityStr = 'GREEN'; // Low intensity / recovery
    } else if (hmldPerMin < 15) {
      sessionIntensityStr = 'AMBER'; // Moderate intensity
    } else {
      sessionIntensityStr = 'RED'; // High intensity / match simulation
    }

    // Load score: weighted composite (aligned with MetricsCalculator)
    double loadScore = 0;
    if (durationMin > 0) {
      final hmldPm = hmldDist / durationMin;
      final hiePm = hieCount / durationMin;
      final sprintsPm = sprints / durationMin;
      final accelPm = accelEventCount / durationMin;
      loadScore = min(
          100.0,
          (hmldPm * 0.4) +
              (hiePm * 3.0 * 0.3) +
              (sprintsPm * 5.0 * 0.2) +
              (accelPm * 0.5 * 0.1));
    }

    // -------------------------------------------------------
    // STEP 7: PERSONAL BEST METRICS
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
      accelerationCount: accelEventCount,
      decelerationCount: decelEventCount,
      maxAcceleration: maxAccel,
      impactCount: totalImpacts,
      maxImpactG: maxImpact,
      hieCount: hieCount,
      playerLoad: playerLoad,
      loadScore: loadScore,
      sessionIntensity: sessionIntensityStr,
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

  // --- METABOLIC POWER ---

  /// Minetti et al. (2002) / Osgnach et al. (2010) metabolic power formula.
  ///
  /// This is the validated 5th-order polynomial for energy cost of locomotion
  /// on equivalent slopes, matching the app-side MetricsCalculator.
  ///
  /// [velocity] - Instantaneous velocity in m/s
  /// [acceleration] - Linear acceleration in m/s²
  ///
  /// Returns metabolic power in W/kg
  static double _calculateMetabolicPower(
      double velocity, double acceleration) {
    if (velocity < 0.1) return 0;

    // Equivalent slope: ratio of acceleration to gravity
    final es = acceleration / gravityMss;

    // Energy cost of locomotion C(es) — Minetti polynomial
    // Units: J/(kg·m)
    final ec = (155.4 * pow(es, 5)) -
        (30.4 * pow(es, 4)) -
        (43.3 * pow(es, 3)) +
        (46.3 * pow(es, 2)) +
        (19.5 * es) +
        3.6;

    // Floor at zero: negative EC from steep deceleration is not meaningful
    final ecClamped = ec < 0 ? 0.0 : ec;

    // Equivalent mass factor
    final em = sqrt(1 + pow(es, 2));

    return ecClamped * em * velocity;
  }

  // --- HELPERS ---

  /// Resamples to 1Hz by binning samples per calendar second.
  static List<SensorLog> _resampleTo1Hz(List<SensorLog> logs) {
    if (logs.isEmpty) return [];
    List<SensorLog> resampled = [];
    List<SensorLog> bin = [];
    DateTime? binSecond;

    for (var log in logs) {
      DateTime currentSecond = DateTime(
        log.timestamp.year,
        log.timestamp.month,
        log.timestamp.day,
        log.timestamp.hour,
        log.timestamp.minute,
        log.timestamp.second,
      );

      if (binSecond == null || currentSecond == binSecond) {
        bin.add(log);
        binSecond = currentSecond;
      } else {
        if (bin.isNotEmpty) {
          resampled.add(_aggregateBin(bin));
        }
        bin = [log];
        binSecond = currentSecond;
      }
    }
    if (bin.isNotEmpty) {
      resampled.add(_aggregateBin(bin));
    }
    return resampled;
  }

  /// Aggregates a 1-second bin of samples into a single representative sample.
  static SensorLog _aggregateBin(List<SensorLog> bin) {
    if (bin.length == 1) return bin.first;

    double meanLat = 0, meanLon = 0;
    double maxSpeed = 0;
    SensorLog bestImu = bin.first;
    double bestG = 0;

    for (var log in bin) {
      meanLat += log.latitude;
      meanLon += log.longitude;
      if (log.speed > maxSpeed) maxSpeed = log.speed;
      double g = sqrt(log.filteredAccelX * log.filteredAccelX +
          log.filteredAccelY * log.filteredAccelY +
          log.filteredAccelZ * log.filteredAccelZ);
      if (g > bestG) {
        bestG = g;
        bestImu = log;
      }
    }

    meanLat /= bin.length;
    meanLon /= bin.length;

    return bestImu.copyWith(
      latitude: meanLat,
      longitude: meanLon,
      speed: maxSpeed,
      timestamp: bin.first.timestamp,
    );
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
    if (speedKmh < zoneHSR) return 'Jogging';
    if (speedKmh < zoneSprinting) return 'Running';
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
