import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/providers/pod_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// METRICAT-115: when the pod never sends a file header, native iOS now fails
/// the attempt with a "Download Failed: ..." status after a short timeout.
/// Before, nothing ended the download until the 45-minute Dart timeout, so the
/// app sat on "Requesting Data...".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.pod_connector/methods');
  const payloadChannel = EventChannel('com.example.pod_connector/payload');
  const statusChannel = EventChannel('com.example.pod_connector/status');
  const fileName = '20260606_104934_v01.bin';
  late MockStreamHandlerEventSink payloadSink;
  late MockStreamHandlerEventSink statusSink;
  late ProviderContainer container;
  late PodNotifier notifier;

  /// A file list notification (after the 0xAE strip) with one file.
  Uint8List fileList(String name, int size) {
    final entries = Uint8List(1 + 36);
    entries[0] = 1;
    final bytes = ascii.encode(name);
    for (var b = 0; b < bytes.length; b++) {
      entries[1 + b] = bytes[b];
    }
    ByteData.sublistView(entries, 33, 37).setUint32(0, size, Endian.little);
    return Uint8List.fromList([0x02, entries.length, ...entries]);
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    messenger.setMockStreamHandler(
      payloadChannel,
      MockStreamHandler.inline(onListen: (args, sink) => payloadSink = sink),
    );
    messenger.setMockStreamHandler(
      statusChannel,
      MockStreamHandler.inline(onListen: (args, sink) => statusSink = sink),
    );
    container = ProviderContainer();
    addTearDown(container.dispose);
    notifier = container.read(podNotifierProvider.notifier);
    await settle();
    payloadSink.success(fileList(fileName, 1000));
    await settle();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockStreamHandler(payloadChannel, null);
    messenger.setMockStreamHandler(statusChannel, null);
  });

  test('a native "Download Failed" status fails the download in flight',
      () async {
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    final failed = expectLater(download, throwsA(isA<StateError>()));
    await settle();

    statusSink.success('Download Failed: No response from pod');
    await failed;

    expect(
      container.read(podNotifierProvider).statusMessage,
      'Download failed: No response from pod',
    );
  });

  test('a "Download Failed" status with no download in flight is harmless',
      () async {
    statusSink.success('Download Failed: No response from pod');
    await settle();

    // Still usable: the file list is untouched.
    expect(container.read(podNotifierProvider).podFiles, hasLength(1));
  });
}
