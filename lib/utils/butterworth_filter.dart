import 'dart:math';

/// 2nd-order Butterworth low-pass filter implemented in pure Dart.
///
/// Applies forward-backward filtering (like scipy's `filtfilt`) to eliminate
/// phase lag while providing smooth attenuation of high-frequency noise.
///
/// Typical use: smoothing accelerometer and gyroscope channels at ~5Hz cutoff
/// for 10Hz sampled IMU data.
class ButterworthFilter {
  /// Cutoff frequency in Hz.
  final double cutoffHz;

  /// Sampling frequency in Hz.
  final double samplingHz;

  // Filter coefficients (computed in constructor)
  late final double _b0, _b1, _b2, _a1, _a2;

  /// Creates a 2nd-order Butterworth low-pass filter.
  ///
  /// [cutoffHz] — the -3dB cutoff frequency (default 5.0 Hz).
  /// [samplingHz] — the data sampling rate (default 10.0 Hz).
  ButterworthFilter({this.cutoffHz = 5.0, this.samplingHz = 10.0}) {
    _computeCoefficients();
  }

  void _computeCoefficients() {
    // Pre-warp the cutoff frequency using bilinear transform
    final double wc = tan(pi * cutoffHz / samplingHz);
    final double wc2 = wc * wc;
    final double sqrt2 = sqrt(2.0);

    // Denominator normalization factor
    final double k = 1.0 + sqrt2 * wc + wc2;

    // Transfer function coefficients (normalized)
    _b0 = wc2 / k;
    _b1 = 2.0 * wc2 / k;
    _b2 = wc2 / k;
    _a1 = 2.0 * (wc2 - 1.0) / k;
    _a2 = (1.0 - sqrt2 * wc + wc2) / k;
  }

  /// Applies forward-backward (zero-phase) filtering to the input signal.
  ///
  /// Returns a new list with the filtered values. The input is not modified.
  /// For signals shorter than 6 samples, returns the input unchanged.
  List<double> filtfilt(List<double> signal) {
    if (signal.length < 6) return List.from(signal);

    // Pad signal to reduce edge effects (reflect 3 samples at each end)
    final int padLen = min(3, signal.length - 1);
    final List<double> padded = [];

    // Reflect start
    for (int i = padLen; i > 0; i--) {
      padded.add(2.0 * signal[0] - signal[i]);
    }
    padded.addAll(signal);
    // Reflect end
    for (int i = signal.length - 2; i >= signal.length - 1 - padLen; i--) {
      padded.add(2.0 * signal.last - signal[i]);
    }

    // Forward pass
    final List<double> forward = _applyFilter(padded);

    // Reverse
    final List<double> reversed = forward.reversed.toList();

    // Backward pass
    final List<double> backward = _applyFilter(reversed);

    // Reverse again and strip padding
    final List<double> result = backward.reversed.toList();
    return result.sublist(padLen, padLen + signal.length);
  }

  /// Single-pass IIR filter (Direct Form I).
  List<double> _applyFilter(List<double> input) {
    final int n = input.length;
    final List<double> output = List.filled(n, 0.0);

    // Initialize with first value to avoid transient
    output[0] = input[0];
    if (n > 1) output[1] = input[1];

    for (int i = 2; i < n; i++) {
      output[i] = _b0 * input[i] + _b1 * input[i - 1] + _b2 * input[i - 2] -
          _a1 * output[i - 1] - _a2 * output[i - 2];
    }

    return output;
  }

  /// Convenience: filter a list of multi-channel data.
  /// [channels] is a map of channel name → signal values.
  /// Returns a new map with the same keys but filtered values.
  Map<String, List<double>> filterChannels(Map<String, List<double>> channels) {
    return channels.map((key, signal) => MapEntry(key, filtfilt(signal)));
  }
}
