import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/providers/pod_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// METRICAT-92: raw file bytes that reach Flutter during a download (the pod
/// stopped framing) were read as message types. 0x03 completed the download with
/// an empty list, 0x02 replaced the file list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.pod_connector/methods');
  const payloadChannel = EventChannel('com.example.pod_connector/payload');
  const fileName = '20260606_104934_v01.bin';
  late MockStreamHandlerEventSink payloadSink;
  late ProviderContainer container;
  late PodNotifier notifier;

  /// A file list notification (after the 0xAE strip): [0x02, length, count, entries...].
  Uint8List fileList(Map<String, int> files) {
    final entries = Uint8List(1 + files.length * 36);
    entries[0] = files.length;
    var i = 0;
    files.forEach((name, size) {
      final base = 1 + i * 36;
      final bytes = ascii.encode(name);
      for (var b = 0; b < bytes.length; b++) {
        entries[base + b] = bytes[b];
      }
      ByteData.sublistView(entries, base + 32, base + 36)
          .setUint32(0, size, Endian.little);
      i++;
    });
    return Uint8List.fromList([0x02, entries.length > 255 ? 255 : entries.length, ...entries]);
  }

  /// What the plugin delivers for a finished file: type byte + file bytes.
  Uint8List finishedFile(int fileBytes) =>
      Uint8List.fromList([0x03, ...List<int>.filled(fileBytes, 0)]);

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      payloadChannel,
      MockStreamHandler.inline(onListen: (args, sink) => payloadSink = sink),
    );
    container = ProviderContainer();
    addTearDown(container.dispose);
    notifier = container.read(podNotifierProvider.notifier);
    await settle();
    payloadSink.success(fileList({fileName: 1000}));
    await settle();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(payloadChannel, null);
  });

  test('the file list sets podFiles before a download', () {
    expect(container.read(podNotifierProvider).podFiles, hasLength(1));
  });

  test('an unframed 0x02 during a download does not replace the file list', () async {
    final before = container.read(podNotifierProvider).podFiles;
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    final failed = expectLater(download, throwsA(isA<StateError>()));
    await settle();

    // Raw file bytes starting with 0x02: a false list of 50 files.
    payloadSink.success(fileList({for (var i = 0; i < 50; i++) 'x$i.bin': 1}));
    await settle();

    expect(container.read(podNotifierProvider).podFiles, before);

    // The download is still in flight; fail it so the test can end.
    payloadSink.success(finishedFile(0));
    await failed;
  });

  test('an unframed 0x03 that parses to 0 records fails the download', () async {
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    final failed = expectLater(download, throwsA(isA<StateError>()));
    await settle();

    // The 243 bytes from the field log: not a whole file, not records.
    payloadSink.success(finishedFile(243));
    await failed;
  });

  test('a finished file of the wrong size fails the download', () async {
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    final failed = expectLater(download, throwsA(isA<StateError>()));
    await settle();

    payloadSink.success(finishedFile(999)); // the file list says 1000
    await failed;
  });

  test('a skipped file (0xDA) still completes with an empty list', () async {
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    await settle();

    payloadSink.success(Uint8List.fromList([0xDA]));

    expect(await download, isEmpty);
  });

  test('file data with no download in flight is ignored', () async {
    payloadSink.success(finishedFile(243));
    await settle();

    expect(container.read(podNotifierProvider).statusMessage,
        isNot('Data Corrupt or Empty'));
  });
}
