import Flutter
import UIKit

/// Flutter plugin for Pod BLE communication on iOS.
/// Bridges the PodBLECore to Flutter via MethodChannel and EventChannels.
public class PodConnectorPlugin: NSObject, FlutterPlugin {

    private var bleCore: PodBLECore!

    // Event sinks for streaming data to Flutter
    private var statusSink: FlutterEventSink?
    private var scanSink: FlutterEventSink?
    private var payloadSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PodConnectorPlugin()

        // Method Channel
        let methodChannel = FlutterMethodChannel(
            name: "com.example.pod_connector/methods",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        // Event Channels
        let statusChannel = FlutterEventChannel(
            name: "com.example.pod_connector/status",
            binaryMessenger: registrar.messenger()
        )
        statusChannel.setStreamHandler(instance.StatusStreamHandler(plugin: instance))

        let scanChannel = FlutterEventChannel(
            name: "com.example.pod_connector/scan",
            binaryMessenger: registrar.messenger()
        )
        scanChannel.setStreamHandler(instance.ScanStreamHandler(plugin: instance))

        let payloadChannel = FlutterEventChannel(
            name: "com.example.pod_connector/payload",
            binaryMessenger: registrar.messenger()
        )
        payloadChannel.setStreamHandler(instance.PayloadStreamHandler(plugin: instance))

        // Initialize BLE Core
        instance.bleCore = PodBLECore()
        instance.bleCore.delegate = instance
    }

    // MARK: - Method Call Handler

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startScan":
            bleCore.startScan()
            result(nil)

        case "stopScan":
            bleCore.stopScan()
            result(nil)

        case "connect":
            guard let deviceId = call.arguments as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "Device ID required", details: nil))
                return
            }
            bleCore.connect(deviceId: deviceId)
            result(nil)

        case "disconnect":
            bleCore.disconnect()
            result(nil)

        case "writeCommand":
            guard let bytes = call.arguments as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARG", message: "Byte array required", details: nil))
                return
            }
            bleCore.writeCommand(bytes.data)
            result(nil)

        case "downloadFile":
            guard let args = call.arguments as? [String: Any],
                  let filename = args["filename"] as? String else {
                result(FlutterError(code: "INVALID_ARG", message: "Download args required", details: nil))
                return
            }
            let start = (args["filterStart"] as? NSNumber)?.int64Value ?? 0
            let end = (args["filterEnd"] as? NSNumber)?.int64Value ?? 0
            let totalFiles = args["totalFiles"] as? Int ?? 1
            let currentIndex = args["currentIndex"] as? Int ?? 1

            bleCore.downloadFile(filename: filename, start: start, end: end, totalFiles: totalFiles, currentIndex: currentIndex)
            result(nil)

        case "cancelDownload":
            bleCore.cancelDownload()
            result(nil)

        case "requestBatteryExemption":
            // No-op on iOS — background BLE mode is handled via Info.plist
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Stream Handlers

    class StatusStreamHandler: NSObject, FlutterStreamHandler {
        weak var plugin: PodConnectorPlugin?
        init(plugin: PodConnectorPlugin) { self.plugin = plugin }

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            plugin?.statusSink = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            plugin?.statusSink = nil
            return nil
        }
    }

    class ScanStreamHandler: NSObject, FlutterStreamHandler {
        weak var plugin: PodConnectorPlugin?
        init(plugin: PodConnectorPlugin) { self.plugin = plugin }

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            plugin?.scanSink = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            plugin?.scanSink = nil
            return nil
        }
    }

    class PayloadStreamHandler: NSObject, FlutterStreamHandler {
        weak var plugin: PodConnectorPlugin?
        init(plugin: PodConnectorPlugin) { self.plugin = plugin }

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            plugin?.payloadSink = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            plugin?.payloadSink = nil
            return nil
        }
    }
}

// MARK: - PodBLECoreDelegate

extension PodConnectorPlugin: PodBLECoreDelegate {

    func didUpdateStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusSink?(status)
        }
    }

    func didDiscoverDevice(name: String, id: String, rssi: Int) {
        let deviceMap: [String: Any] = ["name": name, "id": id, "rssi": rssi]
        DispatchQueue.main.async { [weak self] in
            self?.scanSink?(deviceMap)
        }
    }

    func didReceivePayload(_ data: Data) {
        let flutterData = FlutterStandardTypedData(bytes: data)
        DispatchQueue.main.async { [weak self] in
            self?.payloadSink?(flutterData)
        }
    }
}
