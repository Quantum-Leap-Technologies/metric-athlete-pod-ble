import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/pod_connector_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final platform = MethodChannelPodConnector();
  const channel = MethodChannel('com.example.pod_connector/methods');

  final List<MethodCall> methodCalls = [];

  setUp(() {
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      methodCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('startScan invokes native method', () async {
    await platform.startScan();
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'startScan');
  });

  test('stopScan invokes native method', () async {
    await platform.stopScan();
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'stopScan');
  });

  test('connect sends deviceId argument', () async {
    await platform.connect('AA:BB:CC:DD:EE:FF');
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'connect');
    expect(methodCalls.first.arguments, 'AA:BB:CC:DD:EE:FF');
  });

  test('disconnect invokes native method', () async {
    await platform.disconnect();
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'disconnect');
  });

  test('writeCommand sends byte data', () async {
    final bytes = Uint8List.fromList([0x03, 0x01, 0x01]);
    await platform.writeCommand(bytes);
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'writeCommand');
    expect(methodCalls.first.arguments, bytes);
  });

  test('downloadFile sends parameters as map', () async {
    await platform.downloadFile('20250725.bin', 1000, 2000, 5, 1);
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'downloadFile');
    final args = methodCalls.first.arguments as Map;
    expect(args['filename'], '20250725.bin');
    expect(args['filterStart'], 1000);
    expect(args['filterEnd'], 2000);
    expect(args['totalFiles'], 5);
    expect(args['currentIndex'], 1);
  });

  test('cancelDownload invokes native method', () async {
    await platform.cancelDownload();
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'cancelDownload');
  });

  test('requestBatteryExemption invokes native method', () async {
    await platform.requestBatteryExemption();
    expect(methodCalls.length, 1);
    expect(methodCalls.first.method, 'requestBatteryExemption');
  });
}
