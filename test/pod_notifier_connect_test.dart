import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/providers/pod_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.example.pod_connector/methods');
  late List<String> nativeCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    nativeCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
}
