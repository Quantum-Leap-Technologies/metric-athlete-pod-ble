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
    private let stuckThresholdSeconds: TimeInterval = 5.0
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

    // Download state
    private var isDownloadActive = false

    // Smart Peek filtering
    private var filterStart: Int64 = 0
    private var filterEnd: Int64 = 0
    private var isFiltering = false
    private var isSmartPeekDone = false

    // Watchdog
    private var watchdogTimer: Timer?
    private var lastPacketTime: Date = Date()

    // Keepalive — prevents BLE supervision timeout during
    // long pauses when the pod is reading from flash storage
    private var keepaliveTimer: Timer?
    private let keepaliveIntervalSeconds: TimeInterval = 5.0

    // Progress tracking
    private var totalFilesInPack = 1
    private var currentFileIndex = 1
    private var lastReportedProgress = -1

    // MARK: - Initialization

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - Scanning

    func startScan() {
        guard centralManager.state == .poweredOn else {
            let stateStr: String
            switch centralManager.state {
            case .unauthorized:
                stateStr = "Unauthorized"
                delegate?.didUpdateStatus("Bluetooth Unauthorized")
            case .poweredOff:
                stateStr = "PoweredOff"
                delegate?.didUpdateStatus("Bluetooth Off")
            default:
                stateStr = "Unavailable(\(centralManager.state.rawValue))"
                delegate?.didUpdateStatus("Bluetooth Unavailable")
            }
            NSLog("[PodBLE] startScan blocked — BLE state=%@", stateStr)
            return
        }

        NSLog("[PodBLE] startScan — scanning for POD devices (timeout=%.0fs)", scanDurationSeconds)
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
            NSLog("[PodBLE] connect — invalid device ID: %@", deviceId)
            delegate?.didUpdateStatus("Invalid Device ID")
            return
        }

        NSLog("[PodBLE] connect — looking up peripheral %@", deviceId)

        // All CoreBluetooth operations must happen on bleQueue
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            let peripherals = self.centralManager.retrievePeripherals(withIdentifiers: [uuid])
            guard let peripheral = peripherals.first else {
                NSLog("[PodBLE] connect — peripheral not found for UUID %@", deviceId)
                self.delegate?.didUpdateStatus("Device Not Found")
                return
            }

            NSLog("[PodBLE] connect — found peripheral '%@', initiating connection", peripheral.name ?? "unnamed")
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
                  let characteristic = self.writeCharacteristic else {
                if data.count > 0 {
                    NSLog("[PodBLE] writeCommand — DROPPED cmd=0x%02X (%d bytes), no connection/characteristic", data[0], data.count)
                }
                return
            }
            if data.count > 0 {
                NSLog("[PodBLE] writeCommand — cmd=0x%02X (%d bytes)", data[0], data.count)
            }
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

        let cleanName = filename.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? filename

        isDownloadActive = true

        NSLog("[PodBLE] downloadFile — file='%@' (%d/%d), filter=%@, range=[%lld..%lld]",
              cleanName, currentIndex, totalFiles,
              isFiltering ? "ON" : "OFF", start, end)

        // Construct command: 0x06 + 0x20 + [32 bytes filename]
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
        startKeepalive()
    }

    func cancelDownload() {
        NSLog("[PodBLE] cancelDownload — received=%d/%d packets, buffer=%d bytes",
              receivedPacketCount, totalExpectedPackets, payloadBuffer.count)
        stopWatchdog()
        stopKeepalive()
        writeCommand(Data([0x08]))

        resetDownloadState()

        // Send skip signal (0xDA) to Flutter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.delegate?.didReceivePayload(Data([0xDA]))
        }
    }

    // MARK: - Packet Reassembly

    private func processPacket(_ packet: Data) {
        guard packet.count >= 5 else {
            NSLog("[PodBLE] processPacket — DROPPED: too short (%d bytes)", packet.count)
            return
        }

        if receivedPacketCount == 0 {
            // First packet (header)
            guard packet.count >= 9 else {
                NSLog("[PodBLE] processPacket — DROPPED first packet: too short for header (%d bytes)", packet.count)
                return
            }

            let type = packet[0]
            currentMessageType = type

            // Read total expected packets (bytes 5-8, little endian)
            totalExpectedPackets = Int(packet.subdata(in: 5..<9).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            })

            NSLog("[PodBLE] processPacket — HEADER: type=0x%02X, expectedPackets=%d, packetSize=%d",
                  type, totalExpectedPackets, packet.count)

            // Sanity check — reject obviously corrupt headers.
            // A 2-hour session at 10 Hz ≈ 72 000 entries × ~64 bytes ≈ 72 000 packets.
            // Cap at 500 000 to allow headroom but prevent multi-GB allocations.
            let maxReasonablePackets = 500_000
            guard totalExpectedPackets > 0 && totalExpectedPackets <= maxReasonablePackets else {
                NSLog("[PodBLE] processPacket — REJECTED: unreasonable packet count %d (max=%d)", totalExpectedPackets, maxReasonablePackets)
                totalExpectedPackets = 0
                return
            }

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

        // Report download progress to Flutter
        if totalExpectedPackets > 0 && receivedPacketCount > 0 {
            let pct = min(Int((Double(receivedPacketCount) / Double(totalExpectedPackets)) * 100), 100)
            if pct != lastReportedProgress && (pct == 1 || pct % 5 == 0 || receivedPacketCount >= totalExpectedPackets) {
                lastReportedProgress = pct
                delegate?.didUpdateStatus("Downloading \(pct)%")
            }
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

    /// Detect firmware record size from peek data (47, 61, or 64 bytes).
    /// Checks if a valid record header exists at the start of the second record.
    /// Returns 47 for V3.6 (v01), 61 for Proewe, 64 for HTS firmware.
    private func detectRecordSize(from data: Data) -> Int {
        // Check for V3.6 v01 format (47-byte records)
        if data.count >= 55 {
            let year = Int(data.subdata(in: 51..<53).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
            let month = Int(data[53])
            let day = Int(data[54])
            if year >= 2022 && year <= 2030 && month >= 1 && month <= 12 && day >= 1 && day <= 31 {
                NSLog("[PodBLE] detectRecordSize — V3.6 firmware (47-byte v01 records), probe date=%d-%02d-%02d", year, month, day)
                return 47
            }
        }
        // Check for Proewe format (61-byte records)
        if data.count >= 69 {
            let year = Int(data.subdata(in: 65..<67).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian })
            let month = Int(data[67])
            let day = Int(data[68])
            if year >= 2022 && year <= 2030 && month >= 1 && month <= 12 && day >= 1 && day <= 31 {
                NSLog("[PodBLE] detectRecordSize — Proewe firmware (61-byte records), probe date=%d-%02d-%02d", year, month, day)
                return 61
            }
        }
        NSLog("[PodBLE] detectRecordSize — HTS firmware (64-byte records, default)")
        return 64
    }

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

        guard let startDate = calendar.date(from: components) else {
            NSLog("[PodBLE] smartPeek — FAILED to parse date: %d-%02d-%02d %02d:%02d:%02d", yr, mon, day, hr, min, sec)
            return
        }
        let startTimeMs = Int64(startDate.timeIntervalSince1970 * 1000)

        // Estimate duration — detect record size to handle 61-byte (Proewe) and 64-byte (HTS) firmware
        let recordSize = detectRecordSize(from: peekData)
        let t1 = Int(peekData.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let t2 = Int(peekData.subdata(in: recordSize..<(recordSize + 4)).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
        let rawInterval = Int64(t2 - t1)
        let interval = snapToStandardInterval(rawInterval)
        let payloadPerPacket = Int64(max(actualPacketSize - 5, 59))
        let dur = (Int64(totalExpectedPackets) * payloadPerPacket / Int64(recordSize)) * interval

        NSLog("[PodBLE] smartPeek — fileDate=%d-%02d-%02d %02d:%02d:%02d, recordSize=%d, interval=%lldms (raw=%lld), estDuration=%lldms",
              yr, mon, day, hr, min, sec, recordSize, interval, rawInterval, dur)
        NSLog("[PodBLE] smartPeek — startMs=%lld, filterStart=%lld, filterEnd=%lld, endMs=%lld",
              startTimeMs, filterStart, filterEnd, startTimeMs + dur)

        // Filter
        if (filterEnd > 0 && startTimeMs > filterEnd) || (filterStart > 0 && (startTimeMs + dur) < filterStart) {
            NSLog("[PodBLE] smartPeek — SKIPPING file (outside filter range)")
            cancelDownload()
        } else {
            NSLog("[PodBLE] smartPeek — KEEPING file (within filter range)")
        }
    }

    // MARK: - Message Completion

    private func finishMessage() {
        stopWatchdog()
        stopKeepalive()

        NSLog("[PodBLE] finishMessage — type=0x%02X, received=%d/%d packets, buffer=%d bytes",
              currentMessageType, receivedPacketCount, totalExpectedPackets, payloadBuffer.count)

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
            NSLog("[PodBLE] watchdog — HARD TIMEOUT after %.1fs, received=%d/%d packets", elapsed, receivedPacketCount, totalExpectedPackets)
            finishMessage()
            return
        }

        // Stuck at 99% check
        if totalExpectedPackets > 0 && elapsed > stuckThresholdSeconds {
            let progress = Double(receivedPacketCount) / Double(totalExpectedPackets)
            if progress > stuckProgressThreshold {
                NSLog("[PodBLE] watchdog — STUCK at %.1f%% for %.1fs, forcing finish", progress * 100, elapsed)
                finishMessage()
                return
            }
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        stopKeepalive()
        DispatchQueue.main.async { [weak self] in
            self?.keepaliveTimer = Timer.scheduledTimer(withTimeInterval: self?.keepaliveIntervalSeconds ?? 5.0, repeats: true) { [weak self] _ in
                self?.bleQueue.async { [weak self] in
                    guard let self = self, let peripheral = self.connectedPeripheral else { return }
                    peripheral.readRSSI()
                }
            }
        }
    }

    private func stopKeepalive() {
        DispatchQueue.main.async { [weak self] in
            self?.keepaliveTimer?.invalidate()
            self?.keepaliveTimer = nil
        }
    }

    // MARK: - Helpers

    private func resetDownloadState() {
        isDownloadActive = false
        receivedPacketCount = 0
        totalExpectedPackets = 0
        actualPacketSize = 0
        isSmartPeekDone = false
        lastReportedProgress = -1
        payloadBuffer = Data()
    }

    private func cleanupConnection() {
        stopKeepalive()
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

        let nameMatch = name.uppercased().hasPrefix("POD")

        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceMatch = advertisedServices.contains(serviceUUID)

        if nameMatch || serviceMatch {
            let displayName: String
            if nameMatch {
                displayName = name
            } else {
                displayName = "POD-\(peripheral.identifier.uuidString.prefix(8))"
            }

            let matchReason = nameMatch && serviceMatch ? "name+serviceUUID" : (nameMatch ? "name" : "serviceUUID")
            NSLog("[PodBLE] didDiscover — name='%@' id='%@' rssi=%d match=%@", displayName, peripheral.identifier.uuidString, RSSI.intValue, matchReason)

            delegate?.didDiscoverDevice(
                name: displayName,
                id: peripheral.identifier.uuidString,
                rssi: RSSI.intValue
            )
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("[PodBLE] didConnect — peripheral='%@' (%@)", peripheral.name ?? "unnamed", peripheral.identifier.uuidString)
        delegate?.didUpdateStatus("Connected")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let errCode = (error as NSError?)?.code ?? -1
        NSLog("[PodBLE] didFailToConnect — peripheral='%@', error='%@' (code=%d)",
              peripheral.name ?? "unnamed", error?.localizedDescription ?? "unknown", errCode)
        delegate?.didUpdateStatus("Connection Failed")
        cleanupConnection()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            let nsError = error as NSError
            NSLog("[PodBLE] didDisconnect — peripheral='%@', error='%@' (code=%d, domain=%@)",
                  peripheral.name ?? "unnamed", error.localizedDescription, nsError.code, nsError.domain)
            delegate?.didUpdateStatus("Disconnected: \(error.localizedDescription)")
        } else {
            NSLog("[PodBLE] didDisconnect — peripheral='%@' (clean disconnect)", peripheral.name ?? "unnamed")
            delegate?.didUpdateStatus("Disconnected")
        }
        cleanupConnection()
    }
}

// MARK: - CBPeripheralDelegate

extension PodBLECore: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            NSLog("[PodBLE] didDiscoverServices — ERROR: %@ (code=%d)", error.localizedDescription, (error as NSError).code)
            delegate?.didUpdateStatus("Service Discovery Error")
            return
        }
        let serviceCount = peripheral.services?.count ?? 0
        let matched = peripheral.services?.contains { $0.uuid == serviceUUID } ?? false
        NSLog("[PodBLE] didDiscoverServices — found %d services, podService=%@", serviceCount, matched ? "YES" : "NO")
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == serviceUUID {
                peripheral.discoverCharacteristics([notifyCharUUID, writeCharUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            NSLog("[PodBLE] didDiscoverCharacteristics — ERROR: %@ (code=%d)", error.localizedDescription, (error as NSError).code)
            delegate?.didUpdateStatus("Characteristic Discovery Error")
            return
        }
        guard let characteristics = service.characteristics else {
            NSLog("[PodBLE] didDiscoverCharacteristics — no characteristics found")
            return
        }

        var foundNotify = false
        var foundWrite = false
        for char in characteristics {
            if char.uuid == notifyCharUUID {
                notifyCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
                foundNotify = true
            } else if char.uuid == writeCharUUID {
                writeCharacteristic = char
                foundWrite = true
            }
        }

        NSLog("[PodBLE] didDiscoverCharacteristics — total=%d, notify=%@, write=%@",
              characteristics.count, foundNotify ? "YES" : "NO", foundWrite ? "YES" : "NO")

        if !foundNotify || !foundWrite {
            NSLog("[PodBLE] WARNING — missing characteristics! Available UUIDs: %@",
                  characteristics.map { $0.uuid.uuidString }.joined(separator: ", "))
        }

        // Clear any leftover buffers on the Pod side after characteristic setup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.writeCommand(Data([0x08]))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            // Notification read failed — device may have disconnected
            NSLog("[PodBLE] didUpdateValue — ERROR: %@ (code=%d)", error.localizedDescription, (error as NSError).code)
            return
        }
        guard characteristic.uuid == notifyCharUUID,
              let data = characteristic.value, !data.isEmpty else { return }

        lastPacketTime = Date()

        // Route packets: download reassembly vs direct passthrough
        if isDownloadActive || totalExpectedPackets > 0 || receivedPacketCount > 0 {
            // Active download — route through packet reassembly
            processPacket(data)
        } else {
            // Not downloading — pass through directly (live telemetry, file list, settings, etc.)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.didReceivePayload(data)
            }
        }
    }
}
