import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/models/pod_state_model.dart';

void main() {
  group('PodState', () {
    test('default constructor has correct defaults', () {
      final state = PodState();
      expect(state.isScanning, false);
      expect(state.scannedDevices, isEmpty);
      expect(state.connectedDeviceId, isNull);
      expect(state.statusMessage, 'Ready');
      expect(state.podFiles, isEmpty);
      expect(state.downloadedFileBytes, isNull);
      expect(state.latestTelemetry, isNull);
      expect(state.telemetryHistory, isEmpty);
      expect(state.isRecording, false);
      expect(state.isLoadingSettings, false);
      expect(state.settingsPlayerNumber, 0);
      expect(state.settingsLogInterval, 100);
      expect(state.rawClusters, isEmpty);
      expect(state.lastRssi, isNull);
      expect(state.clockDriftMs, isNull);
    });

    test('copyWith preserves unchanged fields', () {
      final state = PodState(
        isScanning: true,
        statusMessage: 'Scanning...',
        connectedDeviceId: 'ABC123',
        settingsPlayerNumber: 7,
      );

      final updated = state.copyWith(statusMessage: 'Connected');

      expect(updated.isScanning, true); // preserved
      expect(updated.statusMessage, 'Connected'); // updated
      expect(updated.connectedDeviceId, 'ABC123'); // preserved
      expect(updated.settingsPlayerNumber, 7); // preserved
    });

    test('copyWith updates specified fields', () {
      final state = PodState();
      final updated = state.copyWith(
        isScanning: true,
        statusMessage: 'Scanning...',
        podFiles: ['file1.bin', 'file2.bin'],
        settingsPlayerNumber: 42,
        settingsLogInterval: 200,
      );

      expect(updated.isScanning, true);
      expect(updated.statusMessage, 'Scanning...');
      expect(updated.podFiles.length, 2);
      expect(updated.settingsPlayerNumber, 42);
      expect(updated.settingsLogInterval, 200);
    });

    test('copyWith with no arguments returns equivalent state', () {
      final state = PodState(
        isScanning: true,
        connectedDeviceId: 'DEV1',
        statusMessage: 'Connected',
      );
      final copy = state.copyWith();

      expect(copy.isScanning, state.isScanning);
      expect(copy.connectedDeviceId, state.connectedDeviceId);
      expect(copy.statusMessage, state.statusMessage);
    });

    test('clearConnectedDeviceId nulls the device ID', () {
      final state = PodState(connectedDeviceId: 'ABC123');
      expect(state.connectedDeviceId, 'ABC123');

      final cleared = state.copyWith(clearConnectedDeviceId: true);
      expect(cleared.connectedDeviceId, isNull);
    });

    test('clearConnectedDeviceId overrides connectedDeviceId parameter', () {
      final state = PodState(connectedDeviceId: 'OLD');
      final cleared = state.copyWith(
        connectedDeviceId: 'NEW',
        clearConnectedDeviceId: true,
      );
      // clearConnectedDeviceId takes precedence
      expect(cleared.connectedDeviceId, isNull);
    });

    test('connectedDeviceId can be set without clearConnectedDeviceId', () {
      final state = PodState();
      final updated = state.copyWith(connectedDeviceId: 'NEW_DEVICE');
      expect(updated.connectedDeviceId, 'NEW_DEVICE');
    });

    test('list fields are independent from original', () {
      final files = ['a.bin', 'b.bin'];
      final state = PodState(podFiles: files);
      final updated = state.copyWith(podFiles: ['c.bin']);

      expect(state.podFiles.length, 2);
      expect(updated.podFiles.length, 1);
      expect(updated.podFiles.first, 'c.bin');
    });

    test('lastRssi can be set and preserved via copyWith', () {
      final state = PodState();
      final updated = state.copyWith(lastRssi: -65);
      expect(updated.lastRssi, -65);

      // Preserved when not specified
      final again = updated.copyWith(statusMessage: 'test');
      expect(again.lastRssi, -65);
    });

    test('clockDriftMs can be set and preserved via copyWith', () {
      final state = PodState();
      final updated = state.copyWith(clockDriftMs: 3500);
      expect(updated.clockDriftMs, 3500);

      // Preserved when not specified
      final again = updated.copyWith(statusMessage: 'test');
      expect(again.clockDriftMs, 3500);
    });
  });
}
