import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/pod_connector_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MethodChannelPodConnector platform = MethodChannelPodConnector();
  const MethodChannel channel = MethodChannel('pod_connector');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall methodCall) async {
        return '42';
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('getPlatformVersion', () async {
    expect(await platform, '42');
  });
}
