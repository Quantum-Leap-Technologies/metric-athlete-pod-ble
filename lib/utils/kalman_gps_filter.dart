/// Simple 2D Kalman filter for GPS position smoothing.
///
/// Ported from `data/src/kalman_filter.py` — a constant-position model with
/// fixed process noise (Q=0.01) and measurement noise (R=5).
///
/// This is a simpler alternative to the adaptive Kalman+RTS in TrajectoryFilter,
/// useful for quick filtering when full RTS smoothing is not needed.
class KalmanGpsFilter {
  // State: [latitude, longitude]
  double _latState;
  double _lonState;

  // Covariance (diagonal — independent lat/lon)
  double _pLat;
  double _pLon;

  /// Process noise variance (how much we expect position to change per step).
  final double q;

  /// Measurement noise variance (how noisy the GPS readings are).
  final double r;

  bool _initialized = false;

  /// Creates a 2D Kalman GPS filter.
  ///
  /// [q] — process noise (default 0.01, low = trust prediction more).
  /// [r] — measurement noise (default 5.0, high = trust prediction more).
  KalmanGpsFilter({this.q = 0.01, this.r = 5.0})
      : _latState = 0,
        _lonState = 0,
        _pLat = 10.0,
        _pLon = 10.0;

  /// Resets the filter state.
  void reset() {
    _initialized = false;
    _pLat = 10.0;
    _pLon = 10.0;
  }

  /// Updates the filter with a new GPS measurement and returns the smoothed position.
  ///
  /// Returns `(filteredLat, filteredLon)`.
  (double, double) update(double measuredLat, double measuredLon) {
    if (!_initialized) {
      _latState = measuredLat;
      _lonState = measuredLon;
      _pLat = 10.0;
      _pLon = 10.0;
      _initialized = true;
      return (_latState, _lonState);
    }

    // Predict step (constant-position model: F = identity)
    // State prediction: x_pred = x (no change)
    // Covariance prediction: P_pred = P + Q
    double pLatPred = _pLat + q;
    double pLonPred = _pLon + q;

    // Update step
    // Kalman gain: K = P_pred / (P_pred + R)
    double kLat = pLatPred / (pLatPred + r);
    double kLon = pLonPred / (pLonPred + r);

    // State update: x = x_pred + K * (z - x_pred)
    _latState = _latState + kLat * (measuredLat - _latState);
    _lonState = _lonState + kLon * (measuredLon - _lonState);

    // Covariance update: P = (1 - K) * P_pred
    _pLat = (1.0 - kLat) * pLatPred;
    _pLon = (1.0 - kLon) * pLonPred;

    return (_latState, _lonState);
  }

  /// Batch-process a list of GPS coordinates.
  ///
  /// Returns a list of `(lat, lon)` tuples with smoothed positions.
  List<(double, double)> filterBatch(List<(double, double)> measurements) {
    reset();
    return measurements.map((m) => update(m.$1, m.$2)).toList();
  }
}
