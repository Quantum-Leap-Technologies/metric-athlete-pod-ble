#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint metric_athlete_pod_ble.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'metric_athlete_pod_ble'
  s.version          = '0.0.1'
  s.summary          = 'Pod BLE connector plugin for macOS.'
  s.description      = <<-DESC
Flutter plugin for communicating with Pod GPS/IMU devices over Bluetooth Low Energy on macOS.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.osx.frameworks = 'CoreBluetooth'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
