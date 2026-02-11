import 'dart:math';
import 'dart:collection';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';

/// **TrajectoryResult**
///
/// A wrapper class that returns both the cleaned sensor data AND
/// a quality report card for the session.
///
/// * [logs] - The final list of smooth, physics-valid sensor logs.
/// * [healthScore] - A 0-100% score indicating data trustworthiness.
///   (100% = Perfect data, <60% = Heavy interference/packet loss).
/// * [originalCount] - Number of valid logs before repair.
/// * [repairedCount] - Number of synthetic logs generated to fill gaps.
class TrajectoryResult {
  final List<SensorLog> logs;
  final double healthScore; 
  final int originalCount;
  final int repairedCount;

  TrajectoryResult({
    required this.logs,
    required this.healthScore,
    required this.originalCount,
    required this.repairedCount,
  });
}

/// **TrajectoryFilter**
///
/// The central processing engine for raw athlete telemetry data.
/// It converts a noisy, gap-filled stream of binary data into a smooth,
/// physically accurate trajectory using a 3-Stage Pipeline.
///
/// **Pipeline Overview:**
/// 1. **Stage -1 (Sanity Check):** "The Bouncer". Identifies and deletes data that is
/// physically impossible (e.g., supersonic speed) or corrupted (NaNs), preventing
/// garbage data from skewing the filter.
///
/// 2. **Stage 0 (Strict Repair):** "The Healer". Uses the hardware's `PacketID` to
/// detect exactly where data was lost. It uses Linear Interpolation to generate
/// synthetic packets, ensuring the timeline is perfectly monotonic (100ms intervals).
///
/// 3. **Stage 1 & 2 (Filtering):** "The Smoother". Runs the clean, repaired stream
/// through a Hybrid Kalman Filter and Backward (RTS) Smoother to eliminate
/// GPS jitter and phase lag.
class TrajectoryFilter {
  
  /// Main entry point. Takes a raw list of logs and returns a [TrajectoryResult].
  static TrajectoryResult process(List<SensorLog> logs) {
    if (logs.isEmpty) {
      return TrajectoryResult(logs: [], healthScore: 0, originalCount: 0, repairedCount: 0);
    }

    // ========================================================================
    // STAGE -1: SANITY CHECK (The Bouncer)
    // ========================================================================
    // Goal: Remove "Gibberish" caused by binary corruption or sensor glitches.
    // Strategy: It is better to have a "Gap" (which Stage 0 can fix) than to
    // have "Bad Data" (which Stage 1 will try to smooth, ruining the track).
    
    final List<SensorLog> cleanLogs = logs.where((log) => _isLogValid(log)).toList();

    if (cleanLogs.isEmpty) {
      return TrajectoryResult(logs: [], healthScore: 0, originalCount: 0, repairedCount: 0);
    }

    // ========================================================================
    // STAGE 0: STRICT DATA REPAIR (Linear Interpolation)
    // ========================================================================
    // Goal: Restore the "Heartbeat" of the data. The Kalman filter assumes
    // constant time steps (dt). Packet loss breaks this assumption.
    // We fix this by mathematically regenerating the missing rows.

    // 1. Sort the CLEAN logs by hardware ID
    // Hardware writes are sometimes buffered out of order; this enforces monotonicity.
    final List<SensorLog> sortedLogs = List.from(cleanLogs)
      ..sort((a, b) => a.packetId.compareTo(b.packetId));

    // 1b. Deduplicate by PacketID (keep last occurrence, as later readings
    // are more likely to be correct after sensor stabilization).
    // Duplicate IDs produce zero-distance segments that deflate speed calculations.
    final List<SensorLog> dedupedLogs = [];
    for (int i = 0; i < sortedLogs.length; i++) {
      if (i + 1 < sortedLogs.length && sortedLogs[i].packetId == sortedLogs[i + 1].packetId) {
        continue; // Skip this one, keep the next
      }
      dedupedLogs.add(sortedLogs[i]);
    }

    // 2. Determine Kernel Step Size (Hardware Median)
    // The hardware might step by 1, 10, or 100 counts per log.
    // We sample up to 50 consecutive diffs and apply IQR outlier rejection
    // to handle corrupted packets or irregular spacing after power-on.
    int kernelStepSize = 100; // Default fallback
    final int sampleSize = min(dedupedLogs.length, 51); // Need at least 2 for 1 diff
    if (sampleSize >= 2) {
      List<int> diffs = [];
      for (int i = 1; i < sampleSize; i++) {
        int d = dedupedLogs[i].packetId - dedupedLogs[i - 1].packetId;
        if (d > 0 && d < 5000) diffs.add(d);
      }
      if (diffs.length >= 3) {
        diffs.sort();
        // IQR outlier rejection
        final q1 = diffs[diffs.length ~/ 4];
        final q3 = diffs[(diffs.length * 3) ~/ 4];
        final iqr = q3 - q1;
        final lowerBound = q1 - 1.5 * iqr;
        final upperBound = q3 + 1.5 * iqr;
        final filtered = diffs.where((d) => d >= lowerBound && d <= upperBound).toList();
        if (filtered.isNotEmpty) {
          kernelStepSize = filtered[filtered.length ~/ 2]; // Median of inliers
        } else {
          kernelStepSize = diffs[diffs.length ~/ 2]; // Fallback to raw median
        }
      } else if (diffs.isNotEmpty) {
        diffs.sort();
        kernelStepSize = diffs[diffs.length ~/ 2];
      }
    }

    // 3. The Repair Loop
    // We iterate through the logs. If we see a jump in PacketID, we fill it.
    final List<SensorLog> repairedLogs = [];
    int repairedCount = 0; // NEW: Track how many packets we had to fake.

    // Anchor: Start with the first clean log
    DateTime currentTime = dedupedLogs.first.timestamp;
    repairedLogs.add(dedupedLogs.first.copyWith(timestamp: currentTime));

    for (int i = 1; i < dedupedLogs.length; i++) {
      final prev = dedupedLogs[i - 1];
      final curr = dedupedLogs[i];
      
      // Calculate how many "steps" the hardware skipped.
      // E.g., if IDs are 100 and 300, and step is 100, we missed 1 step (ID 200).
      int idDiff = curr.packetId - prev.packetId;
      int steps = (idDiff / kernelStepSize).round();

      // LOGIC BRANCH: INTERPOLATE OR RESET?
      // We only interpolate if the gap is manageable (< 500 steps / 50 seconds).
      // If the gap is massive, it's likely a user "Pause" or file merge, so we skip filling.
      if (steps > 1 && steps < 500) {
        
        int missingPackets = steps - 1;
        repairedCount += missingPackets; // <--- Count the damage for Health Score
        
        // Generate a synthetic log for EACH missing step
        for (int s = 1; s < steps; s++) {
          double ratio = s / steps; // Linear progress (e.g., 0.25, 0.5, 0.75)
          
          // Calculate exact time for this missing packet (100ms per step)
          DateTime interpTime = currentTime.add(Duration(milliseconds: s * 100));
          int newId = prev.packetId + (s * kernelStepSize);
          
          // Create the synthetic log with interpolated sensor values
          repairedLogs.add(_interpolateLog(prev, curr, ratio, interpTime, newId));
        }
        
        // Advance the master clock by the exact duration of the gap
        currentTime = currentTime.add(Duration(milliseconds: steps * 100));
        
      } else {
        // HUGE GAP or NORMAL STEP (steps == 1)
        if (steps >= 500) {
           // Massive Jump: Don't guess. Re-anchor to the new hardware timestamp.
           currentTime = curr.timestamp;
        } else {
           // Normal Operation: Just tick forward 100ms.
           // (Also handles duplicate IDs by essentially ignoring the zero-step time change)
           currentTime = currentTime.add(Duration(milliseconds: 100));
        }
      }

      // Add the current real log with the corrected/anchored timestamp
      repairedLogs.add(curr.copyWith(timestamp: currentTime));
    }

    // --- CALCULATE HEALTH SCORE ---
    // A perfect session has 0 repaired packets.
    // If we had to synthesize 50% of the data, confidence is 50%.
    int totalOutput = repairedLogs.length;
    double health = 100.0;
    if (totalOutput > 0) {
      health = ((totalOutput - repairedCount) / totalOutput) * 100.0;
    }

    // ========================================================================
    // STAGE 1 & 2: CORE FILTERING
    // ========================================================================
    // Now that we have a gap-free, time-aligned stream, we run the physics filter.
    final pipeline = _HybridTrajectoryPipeline();
    final smoothedLogs = pipeline.processStream(repairedLogs);

    // Return the Rich Result Object
    return TrajectoryResult(
      logs: smoothedLogs,
      healthScore: health,
      originalCount: cleanLogs.length,
      repairedCount: repairedCount,
    );
  }

  /// 🕵️ VALIDATION LOGIC
  /// Returns 'false' if the packet contains corrupted or physically impossible data.
  /// Used in Stage -1 to filter out "gibberish" before processing.
  static bool _isLogValid(SensorLog log) {
    // 1. Check for Binary Parsing Errors
    // NaN (Not a Number) or Infinity indicates the byte stream was misaligned.
    if (log.accelX.isNaN || log.gyroX.isNaN || log.speed.isNaN) return false;
    if (log.accelX.isInfinite || log.gyroX.isInfinite || log.speed.isInfinite) return false;

    // 2. Check for "Null Island"
    // Lat/Lon of 0.0 is the default "No Fix" state for GPS.
    if (log.latitude.abs() < 0.001 && log.longitude.abs() < 0.001) return false;

    // 3. PHYSICAL LIMITS CHECK (Tuned to hardware capabilities)
    
    // ACCEL: Units are m/s^2.
    // A standard 16G accelerometer maxes out at ~157 m/s^2.
    // We allow up to 200.0 to account for impact shocks (e.g., dropping the pod)
    // but reject massive corrupt values like 10,000.
    const double maxAccel = 200.0;
    if (log.accelX.abs() > maxAccel || log.accelY.abs() > maxAccel || log.accelZ.abs() > maxAccel) {
      return false;
    }

    // GYRO: Units are rad/s.
    // A 2000 dps (degrees per second) gyro maxes out at ~35 rad/s.
    // We cap at 40.0. Any higher usually means an Int16 overflow in the binary.
    const double maxGyro = 40.0;
    if (log.gyroX.abs() > maxGyro || log.gyroY.abs() > maxGyro || log.gyroZ.abs() > maxGyro) {
      return false;
    }

    // SPEED: Units are km/h.
    // World class sprinters hit ~45 km/h. 
    // We cap at 80.0 km/h to allow for noisy GPS spikes but filter out 
    // "teleportation" errors (like getting a fix 500km away).
    const double maxSpeed = 80.0;
    if (log.speed > maxSpeed) {
      return false;
    }

    // 4. Check for "Zero-Fill" Glitch
    // Sometimes hardware writes the header but fails to write the payload, 
    // leaving all sensors exactly at 0.0. This is statistically impossible for a moving object.
    bool isAllZeroes = log.accelX == 0 && log.accelY == 0 && log.accelZ == 0 &&
                       log.gyroX == 0 && log.gyroY == 0 && log.gyroZ == 0;
    if (isAllZeroes) return false;

    return true;
  }

  /// 📐 LINEAR INTERPOLATION
  /// Creates a synthetic SensorLog at time `t` between `start` and `end`.
  /// This fills the holes in the timeline so the Kalman Filter doesn't see jumps.
  static SensorLog _interpolateLog(SensorLog start, SensorLog end, double t, DateTime time, int newId) {
    return start.copyWith(
      timestamp: time,
      packetId: newId,
      // GPS: Linear path between two points
      latitude: start.latitude + (end.latitude - start.latitude) * t,
      longitude: start.longitude + (end.longitude - start.longitude) * t,
      speed: start.speed + (end.speed - start.speed) * t,
      // IMU (Raw): Smooth transition of forces
      accelX: start.accelX + (end.accelX - start.accelX) * t,
      accelY: start.accelY + (end.accelY - start.accelY) * t,
      accelZ: start.accelZ + (end.accelZ - start.accelZ) * t,
      gyroX: start.gyroX + (end.gyroX - start.gyroX) * t,
      gyroY: start.gyroY + (end.gyroY - start.gyroY) * t,
      gyroZ: start.gyroZ + (end.gyroZ - start.gyroZ) * t,
      // IMU (Filtered): Interpolating derived data ensures filter continuity
      filteredAccelX: start.filteredAccelX + (end.filteredAccelX - start.filteredAccelX) * t,
      filteredAccelY: start.filteredAccelY + (end.filteredAccelY - start.filteredAccelY) * t,
      filteredAccelZ: start.filteredAccelZ + (end.filteredAccelZ - start.filteredAccelZ) * t,
    );
  }
}

// ============================================================================
// EXISTING FILTER PIPELINE & HELPER CLASSES
// (These handle the Physics/Kalman logic on the now-clean data)
// ============================================================================

class _HybridTrajectoryPipeline {
  _KalmanFilter1D? _kfLat;
  _KalmanFilter1D? _kfLon;

  // --- FILTER TUNING ---
  static const double physicsSpeedLimit = 45.0; // Hard clamp for output speed
  static const double innovationThreshold = 9.0; // Reject GPS updates > 3 standard deviations
  static const double stationaryVarThreshold = 2.5; // Variance floor to detect "Stopped"
  static const double movingSpeedThreshold = 3.0; // Speed to confirm "Moving"

  // Kalman matrices (Q = Process Noise, R = Measurement Noise)
  // Stopped: High R (distrust GPS), Low Q (assume position won't change)
  static const double qStopped = 0.0001; 
  static const double rStopped = 50.0;   
  // Moving: Low R (trust GPS more), High Q (allow position to change)
  static const double qMoving = 1.0;     
  static const double rMoving = 3.0;     

  bool _hasStartedMoving = false;
  int _sustainedMotionCounter = 0;
  static const int requiredSustainedFrames = 20; // Need ~2s of movement to trigger start

  final List<SensorLog> _provisionalBuffer = [];

  // Helper to run one predict/update cycle for both Lat and Lon
  (double, double) _runFilterStep(double lat, double lon, bool isStationary) {
    if (isStationary) {
      _kfLat!.setParameters(qStopped, rStopped);
      _kfLon!.setParameters(qStopped, rStopped);
    } else {
      _kfLat!.setParameters(qMoving, rMoving);
      _kfLon!.setParameters(qMoving, rMoving);
    }

    _kfLat!.predict();
    _kfLon!.predict();

    // Check if the new GPS point is statistically valid
    bool validLat = _kfLat!.validateInnovation(lat, innovationThreshold);
    bool validLon = _kfLon!.validateInnovation(lon, innovationThreshold);

    // If invalid (GPS Teleport), ignore measurement and use prediction
    double updateLat = validLat ? lat : _kfLat!.x;
    double updateLon = validLon ? lon : _kfLon!.x;

    return (_kfLat!.update(updateLat), _kfLon!.update(updateLon));
  }

  /// Processes the cleaned, monotonic stream of logs.
  List<SensorLog> processStream(List<SensorLog> rawLogs) {
    _kfLat = null;
    _kfLon = null;
    _hasStartedMoving = false;
    _sustainedMotionCounter = 0;
    _provisionalBuffer.clear();

    final varCalc = _VarianceCalculator(windowSize: 10);
    final speedSmoother = _SpeedSmoother(windowSize: 5);
    List<_InternalPassData> forwardResults = [];

    for (var log in rawLogs) {
      if (log.latitude.abs() < 0.1) continue; // Skip Null Island

      // Lazy Load: Initialize filter at first valid point
      if (_kfLat == null) {
        _kfLat = _KalmanFilter1D(initialValue: log.latitude);
        _kfLon = _KalmanFilter1D(initialValue: log.longitude);
      }

      // Calculate motion metrics
      varCalc.addReading(log.filteredAccelX, log.filteredAccelY, log.filteredAccelZ);
      double currentVariance = varCalc.getVariance();
      double cappedSpeed = log.speed > physicsSpeedLimit ? physicsSpeedLimit : log.speed;
      double smoothedSpeed = speedSmoother.update(cappedSpeed);

      // Determine State: Moving vs Stationary
      bool isActiveMotion = _hasStartedMoving 
          ? (currentVariance > stationaryVarThreshold || smoothedSpeed > movingSpeedThreshold)
          : (currentVariance > stationaryVarThreshold && smoothedSpeed > movingSpeedThreshold);

      // Motion Latch Logic (prevents drift when standing still at start)
      if (!_hasStartedMoving) {
        if (!isActiveMotion) {
          _sustainedMotionCounter = 0;
          _provisionalBuffer.clear();
        } else {
          _sustainedMotionCounter++;
          _provisionalBuffer.add(log);
          if (_sustainedMotionCounter >= requiredSustainedFrames) {
            _hasStartedMoving = true;
            // Align filter to start of movement
            _kfLat!.x = _provisionalBuffer.first.latitude;
            _kfLon!.x = _provisionalBuffer.first.longitude;
            _kfLat!.clearHistory();
            _kfLon!.clearHistory();
            
            // Process buffered logs
            for (var bufLog in _provisionalBuffer) {
              var (fLat, fLon) = _runFilterStep(bufLog.latitude, bufLog.longitude, false);
              forwardResults.add(_InternalPassData(fLat, fLon, bufLog.speed, bufLog));
            }
            _provisionalBuffer.clear();
          }
        }
      } else {
        // Normal processing once moving
        var (fLat, fLon) = _runFilterStep(log.latitude, log.longitude, !isActiveMotion);
        forwardResults.add(_InternalPassData(fLat, fLon, smoothedSpeed, log));
      }
    }

    if (_kfLat == null || forwardResults.isEmpty) return [];

    // --- BACKWARD PASS (RTS SMOOTHING) ---
    // Smooths the path by looking "backwards" from future data points
    List<double> rtsLats = _kfLat!.rtsSmooth();
    List<double> rtsLons = _kfLon!.rtsSmooth();

    List<SensorLog> finalLogs = [];
    for (int i = 0; i < min(forwardResults.length, rtsLats.length); i++) {
      double lat = rtsLats[i];
      double lon = rtsLons[i];
      var passData = forwardResults[i];
      double finalSpeed = passData.smoothedSpeed;

      // Force 0 speed if position is identical to previous frame
      if (i > 0 && lat == rtsLats[i - 1] && lon == rtsLons[i - 1]) finalSpeed = 0.0;

      finalLogs.add(passData.originalLog.copyWith(
        latitude: lat,
        longitude: lon,
        speed: finalSpeed,
      ));
    }

    return finalLogs;
  }
}

class _KalmanFilter1D {
  double x, p, q, r;
  final List<(double, double, double)> _history = [];

  _KalmanFilter1D({required double initialValue}) 
    : x = initialValue, q = 1.0, r = 3.0, p = 1.0;

  void predict() => p = p + q;

  bool validateInnovation(double z, double threshold) {
    double s = p + r;
    return s <= 0 ? true : (pow(z - x, 2) / s) <= threshold;
  }

  double update(double z) {
    double k = p / (p + r);
    double innovation = z - x;
    // Innovation clamping prevents massive jumps from skewing the mean
    const double maxShift = 0.0001; 
    if (innovation.abs() > maxShift) innovation = innovation.sign * maxShift;

    x = x + k * innovation;
    p = (1 - k) * p;
    _history.add((x, p, q));
    return x;
  }

  void setParameters(double qVal, double rVal) { q = qVal; r = rVal; }
  void clearHistory() => _history.clear();

  List<double> rtsSmooth() {
    int n = _history.length;
    if (n == 0) return [];
    List<double> sX = List.filled(n, 0.0);
    sX[n - 1] = _history.last.$1;
    
    for (int k = n - 2; k >= 0; k--) {
      var state = _history[k];
      double pPriorNext = state.$2 + state.$3;
      double c = pPriorNext > 1e-9 ? state.$2 / pPriorNext : 0.0;
      sX[k] = state.$1 + c * (sX[k + 1] - state.$1);
    }
    return sX;
  }
}

class _InternalPassData {
  final double filteredLat, filteredLon, smoothedSpeed;
  final SensorLog originalLog;
  _InternalPassData(this.filteredLat, this.filteredLon, this.smoothedSpeed, this.originalLog);
}

class _VarianceCalculator {
  final int _windowSize;
  final ListQueue<double> _window = ListQueue<double>();
  
  _VarianceCalculator({int windowSize = 10}) : _windowSize = windowSize;
  
  void addReading(double ax, double ay, double az) {
    if (_window.length >= _windowSize) _window.removeFirst();
    _window.add(sqrt(ax * ax + ay * ay + az * az));
  }
  
  double getVariance() {
    if (_window.length < 2) return 0.0;
    double mean = _window.reduce((a, b) => a + b) / _window.length;
    return _window.fold(0.0, (sum, val) => sum + pow(val - mean, 2)) / _window.length;
  }
}

class _SpeedSmoother {
  final int _windowSize;
  final ListQueue<double> _window = ListQueue<double>();
  
  _SpeedSmoother({int windowSize = 5}) : _windowSize = windowSize;
  
  double update(double newSpeed) {
    if (_window.length >= _windowSize) _window.removeFirst();
    _window.add(newSpeed);
    return _window.isEmpty ? 0.0 : _window.reduce((a, b) => a + b) / _window.length;
  }
}