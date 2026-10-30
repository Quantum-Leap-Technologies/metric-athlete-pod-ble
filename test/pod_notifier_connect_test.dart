import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/providers/pod_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.pod_connector/methods');
  const statusChannel = EventChannel('com.example.pod_connector/status');
  late List<String> nativeCalls;
  MockStreamHandlerEventSink? statusSink;

  // What the native side reports once a connect finishes: "Connected" on
  // success, or a failure status. Tests set this per case.
  var connectOutcome = 'Connected';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nativeCalls = [];
    connectOutcome = 'Connected';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      statusChannel,
      MockStreamHandler.inline(onListen: (args, sink) => statusSink = sink),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      // A native connect takes a moment (GATT connect + service discovery),
      // then the native side reports how it went.
      if (call.method == 'connect') {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        statusSink?.success(connectOutcome);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(statusChannel, null);
  });

  test('connect() to the already-connected pod does not reconnect', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(podNotifierProvider.notifier);

    await notifier.connect('AA:BB:CC:DD:EE:FF');
    expect(container.read(podNotifierProvider).connectedDeviceId,
        'AA:BB:CC:DD:EE:FF');
    expect(nativeCalls.where((m) => m == 'connect'), hasLength(1));

    await notifier.connect('AA:BB:CC:DD:EE:FF');

    expect(nativeCalls.where((m) => m == 'connect'), hasLength(1));
    expect(container.read(podNotifierProvider).connectedDeviceId,
        'AA:BB:CC:DD:EE:FF');
  });

  test('connect() to a different pod still connects', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(podNotifierProvider.notifier);

    await notifier.connect('AA:BB:CC:DD:EE:FF');
    await notifier.connect('11:22:33:44:55:66');

    expect(nativeCalls.where((m) => m == 'connect'), hasLength(2));
    expect(container.read(podNotifierProvider).connectedDeviceId,
        '11:22:33:44:55:66');
  });

  test('a second connect() to a pod that is still connecting joins it', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(podNotifierProvider.notifier);

    // The scan's auto-connect and the user's pick, 50 ms apart, before the
    // first native connect has returned (so connectedDeviceId is still null).
    final first = notifier.connect('AA:BB:CC:DD:EE:FF');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(podNotifierProvider).connectedDeviceId, isNull);
    final second = notifier.connect('AA:BB:CC:DD:EE:FF');
    await Future.wait([first, second]);

    expect(nativeCalls.where((m) => m == 'connect'), hasLength(1));
    expect(container.read(podNotifierProvider).connectedDeviceId,
        'AA:BB:CC:DD:EE:FF');
  });

  test('a connection that fails is not marked connected and sends no settings',
      () async {
    connectOutcome =
        'Disconnected: connection failed (Android status 133)';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(podNotifierProvider.notifier);

    await notifier.connect('AA:BB:CC:DD:EE:FF');
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    final state = container.read(podNotifierProvider);
    expect(state.connectedDeviceId, isNull);
    // The reason, with the Android status code, is visible.
    expect(state.statusMessage, contains('status 133'));
    // No settings request is written to a link that is not up.
    expect(nativeCalls.where((m) => m == 'writeCommand'), isEmpty);
  });
}
