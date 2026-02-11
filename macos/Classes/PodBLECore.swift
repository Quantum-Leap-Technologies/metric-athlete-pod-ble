import Foundation
import CoreBluetooth

/// Delegate protocol for communicating BLE events back to the Flutter plugin layer.
protocol PodBLECoreDelegate: AnyObject {
    func didUpdateStatus(_ status: String)
    func didDiscoverDevice(name: String, id: String, rssi: Int)
    func didReceivePayload(_ data: Data)
}

/// Pure Swift class encapsulating all CoreBluetooth BLE logic for communicating with Pod devices.
/// Shared between iOS and macOS platforms.
class PodBLECore: NSObject {

    // MARK: - Constants

    private let serviceUUID = CBUUID(string: "761993FB-AD28-4438-A7B0-6AB3F2E03816")
    private let notifyCharUUID = CBUUID(string: "5E0C4072-EE4D-450D-90A5-A1FEFDB84692") // Pod → Phone
    private let writeCharUUID = CBUUID(string: "FB4A9352-9BCD-4CC6-80E4-AE37D16FFBF1")  // Phone → Pod

    private let scanDurationSeconds: TimeInterval = 15
    private let watchdogTimeoutSeconds: TimeInterval = 60
    private let stuckThresholdSeconds: TimeInterval = 2.5
    private let stuckProgressThreshold: Double = 0.98

    // MARK: - Properties

    weak var delegate: PodBLECoreDelegate?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private let bleQueue = DispatchQueue(label: "com.pod_connector.ble", qos: .userInitiated)

    // Scanning
    private var scanTimer: Timer?
    private var isScanning = false

    // Packet reassembly
    private var payloadBuffer = Data()
    private var receivedPacketCount = 0
    private var totalExpectedPackets = 0
    private var actualPacketSize = 0
    private var currentMessageType: UInt8 = 0

    // Smart Peek filtering
    private var filterStart: Int64 = 0
    private var filterEnd: Int64 = 0
    private var isFiltering = false
    private var isSmartPeekDone = false

    // Watchdog
    private var watchdogTimer: Timer?
    private var lastPacketTime: Date = Date()

    // Progress tracking
    private var totalFilesInPack = 1
    private var currentFileIndex = 1

    // MARK: - Initialization

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - Scanning

    func startScan() {
        guard centralManager.state == .poweredOn else {
            delegate?.didUpdateStatus("Bluetooth Off")
            return
        }

        isScanning = true
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // Auto-stop after scan duration
        DispatchQueue.main.async { [weak self] in
            self?.scanTimer?.invalidate()
            self?.scanTimer = Timer.scheduledTimer(withTimeInterval: self?.scanDurationSeconds ?? 15, repeats: false) { [weak self] _ in
                self?.stopScan()
            }
        }
    }

    func stopScan() {
        isScanning = false
        centralManager.stopScan()
        DispatchQueue.main.async { [weak self] in
            self?.scanTimer?.invalidate()
            self?.scanTimer = nil
        }
    }

    // MARK: - Connection

    func connect(deviceId: String) {
        stopScan()

        // Find the peripheral by UUID
        let uuid = UUID(uuidString: deviceId)
        guard let uuid = uuid else {
            delegate?.didUpdateStatus("Invalid Device ID")
            return
        }

        // All CoreBluetooth operations must happen on bleQueue
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            let peripherals = self.centralManager.retrievePeripherals(withIdentifiers: [uuid])
            guard let peripheral = peripherals.first else {
                self.delegate?.didUpdateStatus("Device Not Found")
                return
            }

            self.connectedPeripheral = peripheral
            peripheral.delegate = self
            self.centralManager.connect(peripheral, options: nil)
            self.delegate?.didUpdateStatus("Connecting...")
        }
    }

    func disconnect() {
        stopWatchdog()
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            if let peripheral = self.connectedPeripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            self.cleanupConnection()
            self.delegate?.didUpdateStatus("Disconnected")
        }
    }

    // MARK: - Write Command

    func writeCommand(_ data: Data) {
        bleQueue.async { [weak self] in
            guard let self = self,
                  let peripheral = self.connectedPeripheral,
                  let characteristic = self.writeCharacteristic else { return }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    // MARK: - Download

    func downloadFile(filename: String, start: Int64, end: Int64, totalFiles: Int, currentIndex: Int) {
        stopWatchdog()
        resetDownloadState()

        totalFilesInPack = totalFiles
        currentFileIndex = currentIndex

        // Setup filter
        filterStart = start
        filterEnd = end
        isFiltering = (start > 0 || end > 0)

        // Construct command: 0x06 + 0x20 + [32 bytes filename]
        let cleanName = filename.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? filename
        var command = Data(count: 34)
        command[0] = 0x06
        command[1] = 0x20
        if let nameData = cleanName.data(using: .ascii) {
            let copyLength = min(nameData.count, 32)
            command.replaceSubrange(2..<(2 + copyLength), with: nameData.prefix(copyLength))
        }

        writeCommand(command)

        // Arm watchdog
        lastPacketTime = Date()
        startWatchdog()
    }

    func cancelDownload() {
        stopWatchdog()
        writeCommand(Data([0x08]))

        resetDownloadState()

        // Send skip signal (0xDA) to Flutter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.delegate?.didReceivePayload(Data([0xDA]))
        }
    }

    // MARK: - Packet Reassembly

    private func processPacket(_ packet: Data) {
        guard packet.count >= 5 else { return }

        if receivedPacketCount == 0 {
            // First packet (header)
            guard packet.count >= 9 else { return }

            let type = packet[0]
            currentMessageType = type

            // Read total expected packets (bytes 5-8, little endian)
            totalExpectedPackets = Int(packet.subdata(in: 5..<9).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            })

            // Pre-allocate buffer
            let safePacketSize = max(actualPacketSize, 64)
            let estimatedSize = totalExpectedPackets * (safePacketSize - 5) + 2048
            payloadBuffer = Data(capacity: estimatedSize)

            payloadBuffer.append(currentMessageType)

            if packet.count > 9 {
                payloadBuffer.append(packet.subdata(in: 9..<packet.count))
            }
            receivedPacketCount = 1

        } else {
            // Subsequent packet
            if packet.count > 5 {
                payloadBuffer.append(packet.subdata(in: 5..<packet.count))
            }
            receivedPacketCount += 1
        }

        // Auto-detect packet size from first packet
        if actualPacketSize == 0 {
            actualPacketSize = packet.count
        }

        // Smart Peek
        if isFiltering && currentMessageType == 0x03 && !isSmartPeekDone && payloadBuffer.count >= 129 {
            performSmartPeek()
            isSmartPeekDone = true
        }

        // Completion check
        if totalExpectedPackets > 0 && receivedPacketCount >= totalExpectedPackets {
            // Small grace period
            bleQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.finishMessage()
            }
        }
    }

    // MARK: - Smart Peek

    private func performSmartPeek() {
        guard payloadBuffer.count >= 129 else { return }

        let peekData = payloadBuffer.subdata(in: 1..<129)

        // Extract date from header
        let yr = Int(peekData.subdata(in: 4..<6).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
        let mon = Int(peekData[6])
        let day = Int(peekData[7])
        let hr = Int(peekData[8])
        let min = Int(peekData[9])
        let sec = Int(peekData[10])

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = yr
        components.month = mon
        components.day = day
        components.hour = hr
        components.minute = min
        components.second = sec

        guard let startDate = calendar.date(from: components) else { return }
        let startTimeMs = Int64(startDate.timeIntervalSince1970 * 1000)

        // Estimate duration
        let t1 = Int(peekData.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let t2 = Int(peekData.subdata(in: 64..<68).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let rawInterval = Int64(t2 - t1)
        let interval = snapToStandardInterval(rawInterval)
        let payloadPerPacket = Int64(max(actualPacketSize - 5, 59))
        let dur = (Int64(totalExpectedPackets) * payloadPerPacket / 64) * interval

        // Filter
        if (filterEnd > 0 && startTimeMs > filterEnd) || (filterStart > 0 && (startTimeMs + dur) < filterStart) {
            cancelDownload()
        }
    }

    // MARK: - Message Completion

    private func finishMessage() {
        stopWatchdog()

        let finalData = payloadBuffer
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.didReceivePayload(finalData)
        }

        // Reset for next file
        receivedPacketCount = 0
        totalExpectedPackets = 0
        payloadBuffer = Data()
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.watchdogTick()
            }
        }
    }

    private func stopWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = nil
        }
    }

    private func watchdogTick() {
        let elapsed = Date().timeIntervalSince(lastPacketTime)

        // Hard timeout
        if totalExpectedPackets > 0 && elapsed > watchdogTimeoutSeconds {
            finishMessage()
            return
        }

        // Stuck at 99% check
        if totalExpectedPackets > 0 && elapsed > stuckThresholdSeconds {
            let progress = Double(receivedPacketCount) / Double(totalExpectedPackets)
            if progress > stuckProgressThreshold {
                finishMessage()
                return
            }
        }
    }

    // MARK: - Helpers

    private func resetDownloadState() {
        receivedPacketCount = 0
        totalExpectedPackets = 0
        actualPacketSize = 0
        isSmartPeekDone = false
        payloadBuffer = Data()
    }

    private func cleanupConnection() {
        connectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        resetDownloadState()
    }

    private func snapToStandardInterval(_ raw: Int64) -> Int64 {
        let targets: [Int64] = [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]
        var closest: Int64 = 1000
        var minDiff = Int64.max
        for t in targets {
            let d = abs(raw - t)
            if d < minDiff {
                minDiff = d
                closest = t
            }
        }
        return closest
    }
}

// MARK: - CBCentralManagerDelegate

extension PodBLECore: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            delegate?.didUpdateStatus("Bluetooth Ready")
        case .poweredOff:
            delegate?.didUpdateStatus("Bluetooth Off")
        case .unauthorized:
            delegate?.didUpdateStatus("Bluetooth Unauthorized")
        default:
            delegate?.didUpdateStatus("Bluetooth Unavailable")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"

        if name.uppercased().hasPrefix("POD") {
            delegate?.didDiscoverDevice(
                name: name,
                id: peripheral.identifier.uuidString,
                rssi: RSSI.intValue
            )
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.didUpdateStatus("Connected")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        delegate?.didUpdateStatus("Connection Failed")
        cleanupConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        delegate?.didUpdateStatus("Disconnected")
        cleanupConnection()
    }
}

// MARK: - CBPeripheralDelegate

extension PodBLECore: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == serviceUUID {
                peripheral.discoverCharacteristics([notifyCharUUID, writeCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for char in characteristics {
            if char.uuid == notifyCharUUID {
                notifyCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == writeCharUUID {
                writeCharacteristic = char
            }
        }

        // Clear any leftover buffers on the Pod side after characteristic setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeCommand(Data([0x08]))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyCharUUID,
              let data = characteristic.value, !data.isEmpty else { return }

        lastPacketTime = Date()

        // If we're in a download (expecting packets), route through reassembly
        if totalExpectedPackets > 0 || receivedPacketCount == 0 {
            // Check if this looks like the start of a new message or a continuation
            if receivedPacketCount == 0 && data.count >= 5 {
                // Could be a new message - check for header
                processPacket(data)
            } else if receivedPacketCount > 0 {
                processPacket(data)
            } else {
                // Direct payload (live telemetry, file list, etc.)
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.didReceivePayload(data)
                }
            }
        } else {
            // Not in a download — pass through directly
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didReceivePayload(data)
            }
        }
    }
}
