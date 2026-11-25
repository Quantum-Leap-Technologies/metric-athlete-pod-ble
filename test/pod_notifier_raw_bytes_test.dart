import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/providers/pod_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// METRICAT-203: the app uploads the pod file's original bytes, so the notifier
/// exposes them as lastRawBytes next to lastRawLogs, for a good download only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.pod_connector/methods');
  const payloadChannel = EventChannel('com.example.pod_connector/payload');
  const fileName = '20260606_104934_v01.bin';
  const otherFileName = '20260607_090000_v01.bin';
  const v01RecordSize = 47;
  late MockStreamHandlerEventSink payloadSink;
  late ProviderContainer container;
  late PodNotifier notifier;

  Uint8List v01Record(int kernelTick) {
    final bytes = ByteData(v01RecordSize);
    bytes.setUint32(0, kernelTick, Endian.little);
    bytes.setUint16(4, 2026, Endian.little);
    bytes.setUint8(6, 3);
    bytes.setUint8(7, 16);
    bytes.setUint8(8, 14);
    bytes.setUint8(9, 49);
    bytes.setUint8(10, 37);
    bytes.setUint16(11, 300, Endian.little);
    bytes.setFloat32(13, -25.8356, Endian.little);
    bytes.setFloat32(17, 28.2056, Endian.little);
    bytes.setUint16(21, 15, Endian.little);
    bytes.setFloat32(23, 0.5, Endian.little);
    bytes.setFloat32(27, -0.3, Endian.little);
    bytes.setFloat32(31, 9.8, Endian.little);
    bytes.setFloat32(35, 0.01, Endian.little);
    bytes.setFloat32(39, -0.02, Endian.little);
    bytes.setFloat32(43, 0.03, Endian.little);
    return bytes.buffer.asUint8List();
  }

  Uint8List podFile(int firstTick) => Uint8List.fromList([
        ...v01Record(firstTick),
        ...v01Record(firstTick + 100),
        ...v01Record(firstTick + 200),
      ]);

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
    return Uint8List.fromList([0x02, entries.length, ...entries]);
  }

  Uint8List finishedFile(Uint8List fileBytes) =>
      Uint8List.fromList([0x03, ...fileBytes]);

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> publishFileList(Map<String, int> files) async {
    payloadSink.success(fileList(files));
    await settle();
  }

  /// Runs one download of [name] that the pod answers with [fileBytes].
  Future<void> completeDownload(String name, Uint8List fileBytes) async {
    final download = notifier.downloadLogFile(name, maxRetries: 0);
    await settle();
    payloadSink.success(finishedFile(fileBytes));
    await download;
  }

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
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(payloadChannel, null);
  });

  test('a good download exposes the exact payload bytes next to lastRawLogs', () async {
    final file = podFile(100);
    await publishFileList({fileName: file.length});

    await completeDownload(fileName, file);

    expect(notifier.lastRawBytes, orderedEquals(file));
    expect(notifier.lastRawLogs, hasLength(3));
  });

  test('lastRawBytes cannot be changed and does not follow the sender buffer', () async {
    final file = podFile(100);
    final sent = Uint8List.fromList(file);
    await publishFileList({fileName: file.length});

    await completeDownload(fileName, sent);
    sent[0] = 0xFF;

    expect(notifier.lastRawBytes, orderedEquals(file));
    expect(() => notifier.lastRawBytes![0] = 1, throwsUnsupportedError);
  });

  test('the file is not kept in PodState', () async {
    final file = podFile(100);
    await publishFileList({fileName: file.length});

    await completeDownload(fileName, file);

    expect(container.read(podNotifierProvider).downloadedFileBytes, isNull);
  });

  test('a length mismatch leaves no bytes', () async {
    final file = podFile(100);
    await publishFileList({fileName: file.length + 1});
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    final failed = expectLater(download, throwsA(isA<StateError>()));
    await settle();

    payloadSink.success(finishedFile(file));
    await failed;

    expect(notifier.lastRawBytes, isNull);
  });

  test('a file that parses to no records leaves no bytes', () async {
    final garbage = Uint8List.fromList(List<int>.filled(243, 0));
    await publishFileList({fileName: garbage.length});
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    final failed = expectLater(download, throwsA(isA<StateError>()));
    await settle();

    payloadSink.success(finishedFile(garbage));
    await failed;

    expect(notifier.lastRawBytes, isNull);
  });

  test('an empty file leaves no bytes', () async {
    await publishFileList({fileName: 0});
    final download = notifier.downloadLogFile(fileName, maxRetries: 0);
    final failed = expectLater(download, throwsA(isA<StateError>()));
    await settle();

    payloadSink.success(finishedFile(Uint8List(0)));
    await failed;

    expect(notifier.lastRawBytes, isNull);
  });

  test('a stray 0x03 with no download in flight exposes nothing', () async {
    final file = podFile(100);
    await publishFileList({fileName: file.length});

    payloadSink.success(finishedFile(file));
    await settle();

    expect(notifier.lastRawBytes, isNull);
  });

  test('a stray 0x03 after a download does not replace its bytes', () async {
    final first = podFile(100);
    await publishFileList({fileName: first.length});
    await completeDownload(fileName, first);

    payloadSink.success(finishedFile(podFile(900)));
    await settle();

    expect(notifier.lastRawBytes, orderedEquals(first));
  });

  test('the next download clears the previous bytes when it starts', () async {
    final first = podFile(100);
    await publishFileList({fileName: first.length, otherFileName: first.length});
    await completeDownload(fileName, first);

    final second = notifier.downloadLogFile(otherFileName, maxRetries: 0);
    await settle();
    expect(notifier.lastRawBytes, isNull);

    payloadSink.success(Uint8List.fromList([0xDA]));
    expect(await second, isEmpty);
    expect(notifier.lastRawBytes, isNull);
  });

  test('a second download replaces the first', () async {
    final first = podFile(100);
    final second = podFile(5000);
    await publishFileList({fileName: first.length, otherFileName: second.length});

    await completeDownload(fileName, first);
    await completeDownload(otherFileName, second);

    expect(notifier.lastRawBytes, orderedEquals(second));
    expect(notifier.lastRawLogs, hasLength(3));
  });
}
