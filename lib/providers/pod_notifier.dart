import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:metric_athlete_pod_ble/models/session_block_model.dart';

import 'package:metric_athlete_pod_ble/metric_athlete_pod_ble.dart';
import 'package:metric_athlete_pod_ble/utils/session_cluster.dart';
import 'package:metric_athlete_pod_ble/utils/trajectory_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:metric_athlete_pod_ble/utils/pod_protocol_decoder.dart';
import 'package:metric_athlete_pod_ble/services/storage_service.dart';

/// The central State Management class for the Pod Connector application.
/// 
/// This Notifier handles:
/// 1. **Bluetooth Management:** Scanning, connecting, and disconnecting from Pod devices.
/// 2. **Data Protocol:** Sending commands (Write) and processing incoming data (Read) via [PodProtocolHandler].
/// 3. **File Operations:** Syncing logs from the Pod, saving them to local storage, and managing live recording sessions.
/// 4. **State Updates:** Exposing the current [PodState] to the UI (e.g., connection status, progress bars, charts).
class PodNotifier extends Notifier<PodState> {
  // Connects to the native Kotlin/Swift interface for low-level Bluetooth operations.
  final _native = PodConnectorPlatform.instance;
  
  // Timer to sync UI with Native Scanner timeout
  Timer? _scanTimer;
  
  // Handles the decoding of raw bytes into usable Dart objects.
  late PodProtocolHandler _protocolHandler;
  
  // Service for saving CSV files to the device's document directory.
  final _storage = StorageService();

  // Stream subscriptions to listen for native events.
  StreamSubscription? _scanSub;
  StreamSubscription? _statusSub;
  StreamSubscription? _payloadSub;

  // Internal flags for state management.
  bool _hasAutoConnected = false;
  bool _isCancellingDownload = false; 
  
  // Buffer to hold live telemetry data during a recording session.
  List<LiveTelemetry> _liveSessionBuffer = [];
  
  // Completer used to turn the listener-based download flow into a Future-based awaitable.
  // This allows the UI to 'await' a file download even though the data comes in asynchronously via streams.
  Completer<List<SensorLog>>? _syncCompleter;

  @override
  PodState build() {
    _setupNativeListeners();
    // Initialize the Protocol Handler.
    // We pass the `_handleDecodedMessage` function so the handler can call back 
    // to this Notifier whenever it successfully parses a packet.
    _protocolHandler = PodProtocolHandler(onMessageDecoded: _handleDecodedMessage);
    
    // LIFECYCLE CLEANUP
    // This ensures that if the provider is destroyed, we kill the timer and streams.
    ref.onDispose(() {
      _scanTimer?.cancel();
      _scanSub?.cancel();
      _statusSub?.cancel();
      _payloadSub?.cancel();
    });

    return PodState();
  }

  // ===========================================================================
  // 1. MESSAGE HANDLING (INCOMING DATA)
  // ===========================================================================

  /// This function receives the decoded [PodMessage] from the [PodProtocolHandler].
  /// It serves as the central "Router" that updates the app state based on what the Pod sent.
  void _handleDecodedMessage(PodMessage msg) async {
      switch (msg.type) {
      
      // Live stream data
      case 0x01: 
        if (msg.payload is LiveTelemetry) {
          final newData = msg.payload as LiveTelemetry;
          
          // Manage History Buffer (Keep last 200 points)
          final history = List<LiveTelemetry>.from(state.telemetryHistory);
          history.insert(0, newData);
          if (history.length > 200) history.removeLast();

          //Record to buffer if the user has started a recording session
          if (state.isRecording) {
             _appendToFile(newData);
          }

          state = state.copyWith(
            latestTelemetry: newData,
            telemetryHistory: history,
            statusMessage: state.isRecording ? "Recording..." : state.statusMessage,
          );
        }
        break;

      // File list info
      case 0x02: 
        if (msg.payload is List<String>) {
          state = state.copyWith(
            podFiles: msg.payload as List<String>, 
            statusMessage: "File List Updated"
          );
        }
        break;

      // File Download (UPDATED WITH BACKGROUND FILTER)
      case 0x03: 
        if (msg.payload is List<SensorLog>) {
           final rawLogs = msg.payload as List<SensorLog>;
           
           if (rawLogs.isNotEmpty) {
             state = state.copyWith(statusMessage: "Processing Trajectory...");

             try {
               // --- 🚀 PERFORMANCE FIX: RUN FILTER IN BACKGROUND ---
               // We use compute() to prevent the UI from freezing while calculating 
               // the Kalman Filter and interpolating gaps.
               final TrajectoryResult result = await compute(TrajectoryFilter.process, rawLogs);

               // --- HEALTH CHECK ---
               if (result.healthScore < 60.0) {
                 debugPrint("⚠️ WARNING: Poor Data Quality (Health: ${result.healthScore.toStringAsFixed(1)}%)");
                 // Optional: You could update a specific state variable here to show a warning icon
               }
               
               debugPrint("✅ Filter Complete. Clean logs: ${result.logs.length} (Health: ${result.healthScore.toInt()}%)");
               
               state = state.copyWith(statusMessage: "Data Verified (Health: ${result.healthScore.toInt()}%)");
               
               // Complete the pending Future waiting in `downloadLogFile` with the SMOOTHED logs
               if (_syncCompleter != null && !_syncCompleter!.isCompleted) {
                 _syncCompleter!.complete(result.logs); 
               }

             } catch (e) {
               debugPrint("❌ Filter Error: $e");
               // Fallback: If filter crashes, return raw logs so user doesn't lose data
               if (_syncCompleter != null && !_syncCompleter!.isCompleted) {
                 _syncCompleter!.complete(rawLogs); 
               }
             }

           } else {
             state = state.copyWith(statusMessage: "Data Corrupt or Empty");
             // Signal failure to the download function
             if (_syncCompleter != null && !_syncCompleter!.isCompleted) {
               _syncCompleter!.complete([]); 
             }
           }
        }
        break;
      
      // Device settings
      case 0x05: 
        if (msg.payload is Map<String, dynamic>) {
          final settings = msg.payload as Map<String, dynamic>;
          state = state.copyWith(
            isLoadingSettings: false,
            settingsPlayerNumber: settings['playerNumber'],
            settingsLogInterval: settings['logInterval'], 
            statusMessage: "Settings Loaded",
          );
        }
        break;

      // Skipped file during download process
      case 0xda: 
        state = state.copyWith(statusMessage: "Skipped: Out of Range");
        if (_syncCompleter != null && !_syncCompleter!.isCompleted) {
           _syncCompleter!.complete([]);
        }
        break;
      
      // Default message to catch unknown messages
      default:
        if (msg.description.isNotEmpty) {
           state = state.copyWith(statusMessage: msg.description);
        }
    }
  }

  /// Sets up listeners for the native platform streams.
  void _setupNativeListeners() {
    _statusSub = _native.statusStream.listen((status) {
      state = state.copyWith(statusMessage: status);
      if (status == "Disconnected") _resetConnectionState();
    });

    _payloadSub = _native.payloadStream.listen((payload) {
      if (payload.isEmpty) return;
      _protocolHandler.handleMessage(payload[0], payload.sublist(1));
    });
  }

  /// Resets the connection state when the Pod disconnects.
  void _resetConnectionState() {
    _hasAutoConnected = false;
    _liveSessionBuffer.clear(); 

    // Fail-safe: Kill any pending download futures so the UI doesn't hang forever
    if (_syncCompleter != null && !_syncCompleter!.isCompleted) {
       _syncCompleter!.completeError("Disconnected during sync");
    }
    
    state = PodState(
      scannedDevices: state.scannedDevices, 
      isScanning: state.isScanning,
      podFiles: [],
      isRecording: false, // Ensure recording stops on disconnect
    );
  }

  // ===========================================================================
  // 2. SCANNING & CONNECTION
  // ===========================================================================

  /// Initiates a Bluetooth LE scan for available Pod devices.
  Future<void> startScan() async {
    // 1. Reset any existing timer to prevent bugs if user spams the button
    _scanTimer?.cancel();

    // 2. Request Permissions (mobile only — desktop doesn't need runtime permissions)
    if (Platform.isAndroid || Platform.isIOS) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
        Permission.notification,
      ].request();

      if (!statuses.values.every((s) => s.isGranted)) {
        state = state.copyWith(statusMessage: "Permissions Denied.");
        return;
      }
    }

    // --- BATTERY EXEMPTION REQUEST (Android only) ---
    await requestBatteryExemption();

    // 3. Preserve currently connected device (Prevent UI flicker)
    final connectedDevices = state.scannedDevices.where(
      (device) => device['id'] == state.connectedDeviceId
    ).toList();
    
    state = state.copyWith(isScanning: true, scannedDevices: connectedDevices, statusMessage: "Scanning...");
    
    // 4. Check for Auto-Connect preference
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getString('last_pod_id');

    // 5. Listen for new devices
    _scanSub?.cancel();
    _scanSub = _native.scanResultStream.listen((deviceMap) {
      final id = deviceMap['id'];
      final name = (deviceMap['name'] as String).toUpperCase();

      if (name.startsWith("POD")) {
        final currentList = List<Map<String, dynamic>>.from(state.scannedDevices);
        
        if (!currentList.any((d) => d['id'] == id)) {
          currentList.add(deviceMap);
          state = state.copyWith(scannedDevices: currentList);
        }

        // Auto-Connect Logic
        if (lastId != null && id == lastId && !_hasAutoConnected && state.connectedDeviceId == null) {
           _hasAutoConnected = true;
           connect(id);
        }
      }
    });

    await _native.startScan();

    // 6. SYNC UI WITH NATIVE TIMEOUT
    // The native code auto-stops after 15s. We must update the UI to match.
    // We do NOT need to check 'mounted' because ref.onDispose cancels this timer automatically.
    _scanTimer = Timer(const Duration(seconds: 15), () {
      // Only update if we are still scanning to avoid weird state jumps
      if (state.isScanning) {
        state = state.copyWith(isScanning: false, statusMessage: "Scan Complete");
        _scanSub?.cancel(); // Optional: Stop listening to the stream since native stopped sending
      }
    });
  }

  /// Calls the native method to trigger the "Unrestricted Battery" dialog.
  Future<void> requestBatteryExemption() async {
    // We invoke the specific method channel we added to the Kotlin plugin
    // This corresponds to "requestBatteryExemption" in PodConnectorPlugin.kt
    try {
      if (Platform.isAndroid) {
        await _native.requestBatteryExemption();
      }
    } catch (e) {
      debugPrint("Battery exemption request skipped or failed: $e");
    }
  }

  /// Stops the native Bluetooth scanner.
  Future<void> stopScan() async {
    _scanTimer?.cancel(); // Cancel the UI countdown
    await _native.stopScan();
    state = state.copyWith(isScanning: false);
  }

  /// Connects to a specific Pod device by its ID.
  Future<void> connect(String id) async {
    await stopScan();
    state = state.copyWith(isScanning: false, statusMessage: "Connecting...");
    try {
      await _native.connect(id);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_pod_id', id);
      state = state.copyWith(connectedDeviceId: id);
      
      // Wait for connection stability before asking for data
      await Future.delayed(const Duration(seconds: 1));
      getDeviceSettings();
    } catch (e) {
      state = state.copyWith(statusMessage: "Connect Error: $e");
      _hasAutoConnected = false;
    }
  }

  /// Disconnects from the current device and removes the auto-connect preference.
  Future<void> disconnect() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('last_pod_id'); 
    await _native.disconnect();
  }

  // ===========================================================================
  // 3. LIVE RECORDING
  // ===========================================================================

  /// Toggles the recording state.
  Future<void> toggleRecording() async {
    if (state.isRecording) {
      // --- STOP RECORDING ---
      state = state.copyWith(isRecording: false, statusMessage: "Saving Live Session...");
      
      // 1. Tell Pod to stop streaming
      await setLiveStream(false);

      // 2. Save the buffered data to a CSV
      if (_liveSessionBuffer.isNotEmpty) {
        final startTime = DateTime.now();
        
        // Format Time: HHMMSS (e.g., 143005)
        final timeStr = "${startTime.hour.toString().padLeft(2,'0')}${startTime.minute.toString().padLeft(2,'0')}${startTime.second.toString().padLeft(2,'0')}";
        
        // Naming: LiveRec_Player[ID]_[Time].csv
        final fileName = "LiveRec_Player${state.settingsPlayerNumber}_$timeStr.csv";
        
        try {
          // Save the buffer to a .csv file
          await _storage.saveLiveTelemetryToCsv(_liveSessionBuffer, fileName);
          state = state.copyWith(statusMessage: "Saved: $fileName");
        } catch (e) {
          state = state.copyWith(statusMessage: "Save Error: $e");
        }
      } else {
        state = state.copyWith(statusMessage: "Recording Stopped (Empty)");
      }
      
      // 3. Cleanup
      _liveSessionBuffer.clear();

    } else {
      // Start recording
      _liveSessionBuffer.clear();
      
      // 1. Update UI State
      state = state.copyWith(isRecording: true, statusMessage: "Recording...");
      
      // 2. Tell Pod to start streaming live data
      await setLiveStream(true);
    }
  }

  /// Appends incoming live data to the temporary buffer.
  Future<void> _appendToFile(LiveTelemetry data) async {
    _liveSessionBuffer.add(data);
  }

  // ===========================================================================
  // 4. FILE SYNC & STORAGE
  // ===========================================================================

  /// Orchestrates the batch download of multiple log files from the Pod.
 Future<void> syncAllFiles(List<String> filesToSync, {DateTime? start, DateTime? end}) async {
    _isCancellingDownload = false;
    List<SensorLog> masterSessionLogs = [];

    debugPrint("🚀 Starting Batch Sync (${filesToSync.length} files)...");

    // Download loop
    for (int i = 0; i < filesToSync.length; i++) {
      // Check cancellation flag before starting the next file
      if (_isCancellingDownload) break;

      // --- HANDOVER GAP FIX ---
      // Give the Pod firmware 500ms to finish closing the previous file pointer
      if (i > 0) {
        debugPrint("⏳ Handover Cooldown (500ms)...");
        await Future.delayed(const Duration(milliseconds: 500));
      }

      String fileName = filesToSync[i];
      int currentIndex = i + 1;

      try {
        // Download individual file (with timeout and progress tracking)
        List<SensorLog> fileLogs = await downloadLogFile(
          fileName, 
          start: start,
          end: end,
          totalFiles: filesToSync.length, 
          currentIndex: currentIndex
        );
        
        if (fileLogs.isNotEmpty) {
           masterSessionLogs.addAll(fileLogs);
        }
      } catch (e) {
        // Log error but continue to next file (Best Effort Strategy)
        debugPrint("   ⚠️ Failed to download $fileName: $e");
      }
    }

    // --- 2. VALIDATION ---
    if (masterSessionLogs.isEmpty) {
      state = state.copyWith(statusMessage: "Sync Failed or Empty");
      return;
    }

    state = state.copyWith(statusMessage: "Finalizing Session...");

    // --- 3. SORTING & NAMING ---
    // Sort by time just in case files were downloaded in random order
    masterSessionLogs.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final startTime = masterSessionLogs.first.timestamp;
    // Format: YYYYMMDD_HHMM
    final formattedTime = "${startTime.year}${startTime.month.toString().padLeft(2,'0')}${startTime.day.toString().padLeft(2,'0')}_${startTime.hour.toString().padLeft(2,'0')}${startTime.minute.toString().padLeft(2,'0')}";
    
    // Naming: Player_X_YYYYMMDD_HHMM_Raw.csv
    String pNum = state.settingsPlayerNumber > 0 ? "Player_${state.settingsPlayerNumber}" : "Player_Unknown";
    String finalName = "${pNum}_${formattedTime}_Raw.csv";
    
    // --- 4. SAVE RAW ARCHIVE ---
    await _storage.saveSensorLogsToCsv(masterSessionLogs, finalName);
    
    // --- 5. INTELLIGENT CLUSTERING ---
    // Analyze the time gaps. If we find gaps > 5 minutes, split them into separate "Sessions".
    final rawClusters = SessionClusterer.cluster(masterSessionLogs);

    if (rawClusters.length > 1) {
       // Multiple sessions found (e.g., Morning Run + Afternoon Run downloaded together)
       state = state.copyWith(statusMessage: "Multi-Session Detected!", rawClusters: rawClusters);
    } else {
       // Single contiguous session
       state = state.copyWith(statusMessage: "Saved: $finalName", rawClusters: []);
    }
  }

  /// Manually triggers session analysis on a previously saved CSV file.
  Future<List<List<SensorLog>>> analyzeSavedFile(File file) async {
    state = state.copyWith(statusMessage: "Analyzing File...");
    final logs = await _storage.readCsvFile(file);
    
    if (logs.isEmpty) {
      state = state.copyWith(statusMessage: "File unreadable");
      return [];
    }

    final clusters = SessionClusterer.cluster(logs);
    state = state.copyWith(statusMessage: "Found ${clusters.length} sessions", rawClusters: clusters);
    return clusters;
  }

  /// Saves user-defined split sessions (SessionBlocks) to storage.
  Future<void> saveSplitSessions(List<SessionBlock> blocks, List<String> labels, String playerName) async {
    state = state.copyWith(statusMessage: "Saving Splits...");
    try {
      for (int i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        final label = labels[i];
        
        final st = block.startTime;
        final timeStr = "${st.year}${st.month.toString().padLeft(2,'0')}${st.day.toString().padLeft(2,'0')}_${st.hour.toString().padLeft(2,'0')}${st.minute.toString().padLeft(2,'0')}";
        final cleanLabel = label.replaceAll(" ", "");
        
        final fileName = "${playerName}_${timeStr}_$cleanLabel.csv";
        await _storage.saveSensorLogsToCsv(block.logs, fileName);
      }
      state = state.copyWith(statusMessage: "Saved ${blocks.length} split files.", rawClusters: []);
    } catch (e) {
      state = state.copyWith(statusMessage: "Error saving splits: $e");
    }
  }

  // ===========================================================================
  // 5. DOWNLOAD HELPER
  // ===========================================================================
  
  /// Helper function that wraps the native file download stream in a [Future].
  Future<List<SensorLog>> downloadLogFile(String fileInfo, { 
    DateTime? start,
    DateTime? end,
    int totalFiles = 1,
    int currentIndex = 1
  }) async {
    _syncCompleter = Completer<List<SensorLog>>(); 
    state = state.copyWith(downloadedFileBytes: null, statusMessage: "Requesting Data...");
    
    int startMillis = start?.millisecondsSinceEpoch ?? 0;
    int endMillis = end?.millisecondsSinceEpoch ?? 0;

    await _native.downloadFile(fileInfo, startMillis, endMillis, totalFiles, currentIndex);
    return _syncCompleter!.future.timeout(const Duration(minutes: 15));
  }

  // ===========================================================================
  // 6. WRITE COMMANDS (PROTOCOL SENDERS)
  // ===========================================================================

  Future<void> _write(List<int> bytes) async {
    try {
      await _native.writeCommand(Uint8List.fromList(bytes));
    } catch (e) {
      state = state.copyWith(statusMessage: "Write Error: $e");
    }
  }

  Future<void> setLiveStream(bool isEnabled) async {
    int status = isEnabled ? 0x01 : 0x00;
    await _write([0x03, 0x01, status]);
  }

  Future<void> setInternalLogging(bool isEnabled) async {
    int status = isEnabled ? 0x01 : 0x00;
    await _write([0x04, 0x01, status]);
  }

  Future<void> getLogFilesInfo() async {
    await _write([0x05, 0x00]); 
  }

  Future<void> deleteLogFile(String fileInfo) async {
    // 1. Optimistic UI Update
    List<String> currentFiles = List.from(state.podFiles);
    currentFiles.remove(fileInfo);
    state = state.copyWith(podFiles: currentFiles);

    // 2. Prepare Command
    String cleanName = fileInfo.split('(')[0].trim();
    List<int> nameBytes = ascii.encode(cleanName);
    
    // Ensure 32-byte padding
    List<int> paddedName = List<int>.filled(32, 0); 
    for(int i=0; i<nameBytes.length && i<32; i++) {
        paddedName[i] = nameBytes[i];
    }

    await _write([0x07, 0x20, ...paddedName]); 
    await Future.delayed(const Duration(seconds: 2));
    await getLogFilesInfo(); 
  }

  Future<void> cancelDownload() async {
    _isCancellingDownload = true;
    await _write([0x08, 0x00]); 
    
    state = state.copyWith(statusMessage: "Download Cancelled");
    if (_syncCompleter != null && !_syncCompleter!.isCompleted) {
      _syncCompleter!.completeError("Cancelled");
    }
    Future.delayed(const Duration(seconds: 1), () => _isCancellingDownload = false);
  }

  Future<void> getDeviceSettings() async {
    state = state.copyWith(isLoadingSettings: true);
    await _write([0x09, 0x00]); 
    
    Future.delayed(const Duration(seconds: 3), () {
      if (state.isLoadingSettings) state = state.copyWith(isLoadingSettings: false);
    });
  }

  Future<void> setPlayerNumber(int number) async {
    if (number < 1 || number > 99) return;
    await _write([0x0A, 0x01, number]);
    await Future.delayed(const Duration(milliseconds: 500));
    await getDeviceSettings();
  }

  Future<void> setLogInterval(int intervalMs) async {
    if (intervalMs < 100 || intervalMs > 1000) return;
    
    int lsb = intervalMs & 0xFF;
    int msb = (intervalMs >> 8) & 0xFF;

    await _write([0x0B, 0x02, lsb, msb]);
    await Future.delayed(const Duration(milliseconds: 500));
    await getDeviceSettings();
  }
}

final podNotifierProvider = NotifierProvider<PodNotifier, PodState>(PodNotifier.new);