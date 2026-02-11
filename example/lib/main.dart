import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:metric_athlete_pod_ble/metric_athlete_pod_ble.dart';

void main() {
  runApp(const ProviderScope(child: PodExampleApp()));
}

class PodExampleApp extends StatelessWidget {
  const PodExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pod Connector Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final podState = ref.watch(podNotifierProvider);
    final isConnected = podState.connectedDeviceId != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pod Connector Test'),
        actions: [
          if (isConnected)
            IconButton(
              onPressed: () => ref.read(podNotifierProvider.notifier).disconnect(),
              icon: const Icon(Icons.bluetooth_disabled),
              tooltip: 'Disconnect',
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- Status ---
          Card(
            color: isConnected ? Colors.green.shade50 : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                    color: isConnected ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      podState.statusMessage,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // --- Connection Diagnostics ---
          if (isConnected)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    // RSSI
                    Expanded(
                      child: Row(
                        children: [
                          Icon(
                            _rssiIcon(podState.lastRssi),
                            color: _rssiColor(podState.lastRssi),
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            podState.lastRssi != null
                                ? '${podState.lastRssi} dBm'
                                : 'RSSI: --',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    // Clock Drift
                    Expanded(
                      child: Row(
                        children: [
                          Icon(
                            podState.clockDriftMs != null &&
                                    podState.clockDriftMs!.abs() > 5000
                                ? Icons.warning_amber
                                : Icons.access_time,
                            color: podState.clockDriftMs != null &&
                                    podState.clockDriftMs!.abs() > 5000
                                ? Colors.orange
                                : Colors.grey,
                            size: 20,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            podState.clockDriftMs != null
                                ? 'Drift: ${podState.clockDriftMs}ms'
                                : 'Drift: --',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (isConnected) const SizedBox(height: 16),

          // --- Scan ---
          const _SectionHeader('BLE Scanning'),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: podState.isScanning
                  ? () => ref.read(podNotifierProvider.notifier).stopScan()
                  : () => ref.read(podNotifierProvider.notifier).startScan(),
              icon: podState.isScanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.bluetooth_searching),
              label: Text(podState.isScanning ? 'Stop Scan' : 'Scan for Pods'),
            ),
          ),
          const SizedBox(height: 8),
          if (podState.scannedDevices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'No devices found. Tap scan to begin.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ...podState.scannedDevices.map((device) {
              final deviceId = device['id'] as String?;
              final deviceName = device['name'] as String? ?? 'Unknown';
              final rssi = device['rssi'] as int? ?? 0;
              final isThisConnected = deviceId == podState.connectedDeviceId;

              return Card(
                child: ListTile(
                  leading: Icon(
                    isThisConnected ? Icons.bluetooth_connected : Icons.podcasts,
                    color: isThisConnected ? Colors.green : null,
                  ),
                  title: Text(deviceName.toUpperCase()),
                  subtitle: Text(
                    isThisConnected ? 'Connected' : 'Signal: ${rssi}dBm',
                  ),
                  trailing: isThisConnected
                      ? TextButton(
                          onPressed: () =>
                              ref.read(podNotifierProvider.notifier).disconnect(),
                          child: const Text('Disconnect'),
                        )
                      : FilledButton(
                          onPressed: deviceId != null
                              ? () => ref
                                  .read(podNotifierProvider.notifier)
                                  .connect(deviceId)
                              : null,
                          child: const Text('Connect'),
                        ),
                ),
              );
            }),

          if (isConnected) ...[
            const Divider(height: 32),

            // --- Device Settings ---
            const _SectionHeader('Device Settings'),
            Row(
              children: [
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Text('Player #',
                              style: TextStyle(fontSize: 11)),
                          Text(
                            '${podState.settingsPlayerNumber}',
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Text('Log Interval',
                              style: TextStyle(fontSize: 11)),
                          Text(
                            '${podState.settingsLogInterval}ms',
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () =>
                    ref.read(podNotifierProvider.notifier).getDeviceSettings(),
                child: const Text('Refresh Settings'),
              ),
            ),
            const Divider(height: 32),

            // --- File Sync ---
            const _SectionHeader('File Sync'),
            if (podState.podFiles.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('No files detected on pod'),
              )
            else
              ...podState.podFiles.map((f) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.insert_drive_file),
                      title: Text(f, style: const TextStyle(fontSize: 12)),
                    ),
                  )),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => ref
                        .read(podNotifierProvider.notifier)
                        .getLogFilesInfo(),
                    child: const Text('Get Files'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: podState.podFiles.isEmpty
                        ? null
                        : () => ref
                            .read(podNotifierProvider.notifier)
                            .syncAllFiles(podState.podFiles),
                    child: const Text('Sync All'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => ref
                        .read(podNotifierProvider.notifier)
                        .cancelDownload(),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
            if (podState.rawClusters.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Clusters found: ${podState.rawClusters.length}',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              ...podState.rawClusters.asMap().entries.map((entry) {
                final logs = entry.value;
                return Card(
                  child: ListTile(
                    title: Text('Cluster ${entry.key + 1}'),
                    subtitle: Text(
                      '${logs.length} logs, '
                      '${logs.isNotEmpty ? logs.first.timestamp.toString().substring(0, 16) : ""}',
                    ),
                  ),
                );
              }),
            ],
            const Divider(height: 32),

            // --- Live Telemetry ---
            const _SectionHeader('Live Telemetry'),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: podState.isRecording
                        ? null
                        : () => ref
                            .read(podNotifierProvider.notifier)
                            .toggleRecording(),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          podState.isRecording
                              ? Icons.stop
                              : Icons.fiber_manual_record,
                          color: podState.isRecording ? null : Colors.red,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Text(podState.isRecording
                            ? 'Stop Recording'
                            : 'Start Recording'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (podState.latestTelemetry != null) ...[
              const SizedBox(height: 8),
              _TelemetryCard(podState.latestTelemetry!),
            ],
            const Divider(height: 32),

            // --- Diagnostic Logs ---
            const _SectionHeader('Diagnostic Logs'),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${PodLogger.entries.length} entries',
                  style: const TextStyle(fontSize: 13, color: Colors.grey),
                ),
                TextButton(
                  onPressed: () {
                    PodLogger.clear();
                    // Trigger rebuild via a no-op state read
                    ref.read(podNotifierProvider);
                  },
                  child: const Text('Clear Logs'),
                ),
              ],
            ),
            if (PodLogger.entries.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'No log entries yet.',
                  style: TextStyle(color: Colors.grey),
                ),
              )
            else
              ...PodLogger.entries
                  .reversed
                  .take(10)
                  .map((entry) => Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _logLevelIcon(entry.level),
                                color: _logLevelColor(entry.level),
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '[${entry.category}] ${entry.message}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _logLevelColor(entry.level),
                                      ),
                                    ),
                                    if (entry.detail != null)
                                      Text(
                                        entry.detail!,
                                        style: const TextStyle(
                                            fontSize: 11, color: Colors.grey),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      )),
          ],
        ],
      ),
    );
  }
}

IconData _rssiIcon(int? rssi) {
  if (rssi == null) return Icons.signal_wifi_off;
  if (rssi >= -60) return Icons.signal_cellular_alt;
  if (rssi >= -80) return Icons.signal_cellular_alt_2_bar;
  return Icons.signal_cellular_alt_1_bar;
}

Color _rssiColor(int? rssi) {
  if (rssi == null) return Colors.grey;
  if (rssi >= -60) return Colors.green;
  if (rssi >= -80) return Colors.orange;
  return Colors.red;
}

IconData _logLevelIcon(LogLevel level) {
  switch (level) {
    case LogLevel.debug:
      return Icons.bug_report;
    case LogLevel.info:
      return Icons.info_outline;
    case LogLevel.warn:
      return Icons.warning_amber;
    case LogLevel.error:
      return Icons.error_outline;
  }
}

Color _logLevelColor(LogLevel level) {
  switch (level) {
    case LogLevel.debug:
      return Colors.grey;
    case LogLevel.info:
      return Colors.green;
    case LogLevel.warn:
      return Colors.orange;
    case LogLevel.error:
      return Colors.red;
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _TelemetryCard extends StatelessWidget {
  final LiveTelemetry data;
  const _TelemetryCard(this.data);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Latest Telemetry',
                style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            Text('Lat: ${data.latitude.toStringAsFixed(6)}, '
                'Lng: ${data.longitude.toStringAsFixed(6)}'),
            Text('Speed: ${data.gpsSpeed.toStringAsFixed(1)} knots'),
            Text('Accel: X=${data.accelerometer.x.toStringAsFixed(2)}, '
                'Y=${data.accelerometer.y.toStringAsFixed(2)}, '
                'Z=${data.accelerometer.z.toStringAsFixed(2)}'),
            Text('Gyro: X=${data.gyroscope.x.toStringAsFixed(2)}, '
                'Y=${data.gyroscope.y.toStringAsFixed(2)}, '
                'Z=${data.gyroscope.z.toStringAsFixed(2)}'),
            Text('Battery: ${data.batteryVoltage.toStringAsFixed(2)}V'),
          ],
        ),
      ),
    );
  }
}
