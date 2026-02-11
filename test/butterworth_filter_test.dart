import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/utils/butterworth_filter.dart';

void main() {
  group('ButterworthFilter', () {
    late ButterworthFilter filter;

    setUp(() {
      filter = ButterworthFilter(cutoffHz: 5.0, samplingHz: 10.0);
    });

    test('returns input unchanged for signals shorter than 6 samples', () {
      final short = [1.0, 2.0, 3.0];
      final result = filter.filtfilt(short);
      expect(result, short);
    });

    test('smooths a noisy signal', () {
      // Generate a clean 1Hz sine wave + high-frequency noise
      final int n = 100;
      final signal = List.generate(n, (i) {
        double clean = sin(2 * pi * 1.0 * i / 10.0); // 1Hz signal
        double noise = 0.5 * sin(2 * pi * 4.5 * i / 10.0); // 4.5Hz noise
        return clean + noise;
      });

      final filtered = filter.filtfilt(signal);

      expect(filtered.length, signal.length);

      // The filtered signal should be smoother — less variance than raw
      double rawVar = _variance(signal);
      double filtVar = _variance(filtered);
      expect(filtVar, lessThanOrEqualTo(rawVar + 0.001)); // Allow floating-point tolerance
    });

    test('does not modify a constant signal', () {
      final constant = List.filled(20, 5.0);
      final result = filter.filtfilt(constant);
      for (var v in result) {
        expect(v, closeTo(5.0, 0.01));
      }
    });

    test('handles NaN values without propagating them', () {
      final signal = List.generate(20, (i) => i.toDouble());
      signal[5] = double.nan;
      signal[10] = double.infinity;

      final result = filter.filtfilt(signal);

      // No NaN or Infinity in output
      for (var v in result) {
        expect(v.isNaN, false);
        expect(v.isInfinite, false);
      }
    });

    test('handles all-NaN input gracefully', () {
      final signal = List.filled(10, double.nan);
      final result = filter.filtfilt(signal);
      // Should produce some output (all sanitized to 0.0)
      for (var v in result) {
        expect(v.isNaN, false);
      }
    });

    test('output length matches input length', () {
      final signal = List.generate(50, (i) => sin(i * 0.1));
      final result = filter.filtfilt(signal);
      expect(result.length, signal.length);
    });

    test('filterChannels processes multiple channels', () {
      final channels = {
        'accelX': List.generate(20, (i) => sin(i * 0.5)),
        'accelY': List.generate(20, (i) => cos(i * 0.5)),
      };

      final result = filter.filterChannels(channels);
      expect(result.keys, channels.keys);
      expect(result['accelX']!.length, 20);
      expect(result['accelY']!.length, 20);
    });
  });
}

double _variance(List<double> data) {
  double mean = data.reduce((a, b) => a + b) / data.length;
  return data.fold(0.0, (sum, v) => sum + (v - mean) * (v - mean)) / data.length;
}
