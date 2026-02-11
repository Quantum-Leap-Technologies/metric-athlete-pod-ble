import 'package:metric_athlete_pod_ble/models/live_data_model.dart';
import 'package:metric_athlete_pod_ble/models/sensor_log_model.dart';

///Class used to store the different states and data associated with a pod.
///Main class used by the provider to determine state and program flow.
class PodState {
  // --- Connection & Scanning ---
  ///Flag to determine if the app is scanning for bluetooth devices.
  final bool isScanning;
  ///List containing the devices scanned and detected by the bluetooth protocols.
  final List<Map<String, dynamic>> scannedDevices;
  ///Stores the pod's ID.
  final String? connectedDeviceId;
  ///Stores the current status of the pod. This field is updated as different actions are performed by the pod.
  final String statusMessage;

  // --- File Management ---
  ///Stores the list of files detected on the pods
  final List<String> podFiles;
  ///Stores the bytes of downloaded .bin files.
  final List<int>? downloadedFileBytes; // Null when not downloading

  // --- Live Data ---
  ///Stores the latest live data received by the pod.
  final LiveTelemetry? latestTelemetry;
  ///A list of [LiveTelemetry] Objects to keep as a history of live data.
  final List<LiveTelemetry> telemetryHistory;
  ///Flag used to tell the notifier to start or stop recording the live data to a .csv file.
  final bool isRecording;

  // --- Settings ---
  ///Flag to determine if the settings is being retrieved from the pod.
  final bool isLoadingSettings;
  ///The player/pod number stored in the pods settings.
  final int settingsPlayerNumber;
  ///The log interval set in the pods settings.
  final int settingsLogInterval;


  ///This holds the raw lists of data of a downloaded session.
  final List<List<SensorLog>> rawClusters;

  // --- Signal Quality ---
  /// Last known RSSI (Received Signal Strength Indicator) in dBm.
  /// Null if no RSSI has been received yet.
  final int? lastRssi;

  // --- Clock Drift ---
  /// Estimated clock drift between pod RTC and device system clock, in milliseconds.
  /// Positive means pod clock is ahead of device clock.
  /// Null if no drift measurement has been taken.
  final int? clockDriftMs;

  PodState({
    this.isScanning = false,
    this.scannedDevices = const [],
    this.connectedDeviceId,
    this.statusMessage = "Ready",
    this.podFiles = const [],
    this.downloadedFileBytes,
    this.latestTelemetry,
    this.telemetryHistory = const [],
    this.isRecording = false,
    this.isLoadingSettings = false,
    this.settingsPlayerNumber = 0,
    this.settingsLogInterval = 100, // Default 10Hz
    this.rawClusters = const [], // Default empty
    this.lastRssi,
    this.clockDriftMs,
  });
  ///Creates a copy of the object with its values.
  ///Crucial to let the notifier know there was an update to the object.
  PodState copyWith({
    bool? isScanning,
    List<Map<String, dynamic>>? scannedDevices,
    String? connectedDeviceId,
    bool clearConnectedDeviceId = false,
    String? statusMessage,
    List<String>? podFiles,
    List<int>? downloadedFileBytes,
    LiveTelemetry? latestTelemetry,
    List<LiveTelemetry>? telemetryHistory,
    bool? isRecording,
    bool? isLoadingSettings,
    int? settingsPlayerNumber,
    int? settingsLogInterval,
    List<List<SensorLog>>? rawClusters,
    int? lastRssi,
    int? clockDriftMs,
  }) {
    return PodState(
      isScanning: isScanning ?? this.isScanning,
      scannedDevices: scannedDevices ?? this.scannedDevices,
      connectedDeviceId: clearConnectedDeviceId ? null : (connectedDeviceId ?? this.connectedDeviceId),
      statusMessage: statusMessage ?? this.statusMessage,
      podFiles: podFiles ?? this.podFiles,
      downloadedFileBytes: downloadedFileBytes ?? this.downloadedFileBytes,
      latestTelemetry: latestTelemetry ?? this.latestTelemetry,
      telemetryHistory: telemetryHistory ?? this.telemetryHistory,
      isRecording: isRecording ?? this.isRecording,
      isLoadingSettings: isLoadingSettings ?? this.isLoadingSettings,
      settingsPlayerNumber: settingsPlayerNumber ?? this.settingsPlayerNumber,
      settingsLogInterval: settingsLogInterval ?? this.settingsLogInterval,
      rawClusters: rawClusters ?? this.rawClusters,
      lastRssi: lastRssi ?? this.lastRssi,
      clockDriftMs: clockDriftMs ?? this.clockDriftMs,
    );
  }
}