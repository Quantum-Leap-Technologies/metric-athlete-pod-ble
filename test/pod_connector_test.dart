import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/metric_athlete_pod_ble.dart';
import 'package:metric_athlete_pod_ble/pod_connector_platform_interface.dart';
import 'package:metric_athlete_pod_ble/pod_connector_method_channel.dart';


void main() {
  final PodConnectorPlatform initialPlatform = PodConnectorPlatform.instance;

  test('$MethodChannelPodConnector is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelPodConnector>());
  });

  test('getPlatformVersion', () async {


  });
}
