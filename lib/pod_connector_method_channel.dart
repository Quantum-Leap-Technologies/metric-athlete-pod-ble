import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'pod_connector_platform_interface.dart';

/// An implementation of [PodConnectorPlatform] that uses method channels.
/// 
/// This class acts as the "Bridge" between the Flutter Dart code and the 
/// Native Android (Kotlin) / iOS (Swift) code.
class MethodChannelPodConnector extends PodConnectorPlatform {
  
  MethodChannelPodConnector() : super();

  /// The method channel used to send commands TO the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('com.example.pod_connector/methods');

  // --- EVENT CHANNELS (INCOMING STREAMS) ---
  // These channels allow the native side to push data to Flutter whenever it wants.
  
  final EventChannel _statusChannel = const EventChannel('com.example.pod_connector/status');
  final EventChannel _scanChannel = const EventChannel('com.example.pod_connector/scan');
  final EventChannel _payloadChannel = const EventChannel('com.example.pod_connector/payload');

  // --- STREAMS ---
  
  /// Listens for connection status updates (e.g., "Connecting", "Connected", "Disconnected").
  @override
  Stream<String> get statusStream {
    return _statusChannel.receiveBroadcastStream().map((event) => event.toString());
  }

  /// Listens for Bluetooth scan results.
  /// Returns a Map containing the device's Name and ID (MAC address or UUID).
  @override
  Stream<Map<String, dynamic>> get scanResultStream {
    return _scanChannel.receiveBroadcastStream().map((event) {
      return Map<String, dynamic>.from(event as Map);
    });
  }

  /// Listens for raw byte data coming from the connected Pod.
  /// This is the main data pipe for Telemetry and File Downloads.
  @override
  Stream<Uint8List> get payloadStream {
    return _payloadChannel.receiveBroadcastStream().map((event) {
      return event as Uint8List;
    });
  }

  // --- COMMANDS (OUTGOING) ---

  /// Triggers the native platform to start scanning for BLE devices.
  @override
  Future<void> startScan() async {
    await methodChannel.invokeMethod<void>('startScan');
  }

  /// Stops the native BLE scanner.
  @override
  Future<void> stopScan() async {
    await methodChannel.invokeMethod<void>('stopScan');
  }

  /// Connects to a specific device using its unique ID (MAC Address on Android).
  @override
  Future<void> connect(String deviceId) async {
    await methodChannel.invokeMethod<void>('connect', deviceId); 
  }

  /// Disconnects from the current device.
  @override
  Future<void> disconnect() async {
    await methodChannel.invokeMethod<void>('disconnect');
  }

  /// Sends a raw byte command to the connected Pod.
  /// Used for setting config, deleting files, etc.
  @override
  Future<void> writeCommand(Uint8List bytes) async {
    await methodChannel.invokeMethod<void>('writeCommand', bytes);
  }

  /// Initiates a robust file download on the native side.
  /// 
  /// Wraps the parameters into a [Map] so the Kotlin side can extract them easily.
  /// * [filename]: The specific file to request (e.g., "20250101.bin").
  /// * [start] / [end]: Epoch timestamps (ms) to filter the file content.
  /// * [totalFiles] / [currentIndex]: Used by the native notification to show a "File 1 of 5" progress bar.
  @override
  Future<void> downloadFile(String filename, int start, int end, int totalFiles, int currentIndex) async {
    await methodChannel.invokeMethod<void>('downloadFile', {
      'filename': filename,
      'filterStart': start,
      'filterEnd': end,
      'totalFiles': totalFiles,     
      'currentIndex': currentIndex, 
    });
  }

  /// Cancels an in-progress file download on the native side.
  @override
  Future<void> cancelDownload() async {
    await methodChannel.invokeMethod<void>('cancelDownload');
  }

  /// Requests the "Unrestricted" battery optimization permission dialog on Android.
  @override
  Future<void> requestBatteryExemption() async {
    await methodChannel.invokeMethod<void>('requestBatteryExemption');
  }
}