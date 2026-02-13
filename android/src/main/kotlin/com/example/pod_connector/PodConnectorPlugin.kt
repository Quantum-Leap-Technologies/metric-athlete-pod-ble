package com.example.pod_connector

import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri                 
import android.os.*
import android.provider.Settings       
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.Calendar
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.TreeMap

/**
 * **PodConnectorPlugin**
 *
 * The Native Android Engine for the Pod Connector.
 * This class handles high-performance Bluetooth Low Energy (BLE) communication that
 * Dart/Flutter cannot handle efficiently on its own.
 *
 * **Core Responsibilities:**
 * 1. **Connection Management:** Handles GATT connections, priority requests, and MTU negotiation.
 * 2. **Packet Reassembly:** Reconstructs fragmented BLE packets into full 64-byte records.
 * 3. **Smart Peek:** Filters files purely on the native side to save bandwidth.
 * 4. **Watchdog:** Monitors data flow and kills hanging connections.
 * 5. **Backgrounding:** Ties into a Foreground Service to prevent OS killing during downloads.
 */
class PodConnectorPlugin: FlutterPlugin, MethodCallHandler {

    private val TAG = "PodConnector"
    private val CHANNEL_ID = "PodPersistentChannel" // Must match Service
    private val NOTIF_ID = 777 

    private lateinit var context: Context
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var notificationManager: NotificationManager

    // --- THREADING ARCHITECTURE ---
    // Bluetooth operations happen on 'bluetoothThread'.
    // Heavy data parsing/reassembly happens on 'processingThread'.
    // Results are posted back to 'mainHandler' for Flutter.
    private lateinit var bluetoothThread: HandlerThread
    private lateinit var bluetoothHandler: Handler
    private var processingThread: Thread? = null

    // --- METHOD CHANNELS (Bridge to Flutter) ---
    private lateinit var channel : MethodChannel
    private lateinit var statusChannel : EventChannel // Connection state updates
    private lateinit var scanChannel : EventChannel   // BLE Scan results
    private lateinit var payloadChannel : EventChannel // The heavy data pipe (Files/Telemetry)

    private var statusSink: EventChannel.EventSink? = null
    private var scanSink: EventChannel.EventSink? = null
    private var payloadSink: EventChannel.EventSink? = null

    // --- BLUETOOTH OBJECTS ---
    private var bluetoothAdapter: BluetoothAdapter? = null
    private var bluetoothGatt: BluetoothGatt? = null
    private val gattLock = Object()
    
    // --- UUID CONSTANTS ---
    // The specific UUIDs defined in the STM32 Firmware
    private val SERVICE_UUID = UUID.fromString("761993fb-ad28-4438-a7b0-6ab3f2e03816")
    private val NOTIFY_CHAR_UUID = UUID.fromString("5e0c4072-ee4d-450d-90a5-a1fefdb84692") // Pod -> Phone
    private val WRITE_CHAR_UUID  = UUID.fromString("fb4a9352-9bcd-4cc6-80e4-ae37d16ffbf1") // Phone -> Pod
    private val CLIENT_CONFIG    = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb") // Descriptor for Notifications

    // --- DATA PIPELINE BUFFERS ---
    // A thread-safe queue. The GATT callback pushes raw bytes here.
    // The processing thread pops them off to stitch them together.
    private val packetQueue = LinkedBlockingQueue<ByteArray>()
    private val isProcessing = AtomicBoolean(false)
    
    // The staging area where we rebuild the file before sending to Flutter.
    // For large files (10MB+), consider streaming chunks instead of buffering all at once.
    private var payloadBuffer = ByteArrayOutputStream() 
    
    // --- PACKET REASSEMBLY STATE ---
    @Volatile private var receivedPacketCount = 0
    @Volatile private var totalExpectedPackets = 0
    private var actualPacketSize = 0 // Auto-detected from first packet (usually ~240 bytes for MTU 512)
    private var currentMessageType = 0
    private var nextExpectedSeq = 1 // Next sequence number we expect (1 = header packet)
    
    // --- OUT-OF-ORDER PACKET BUFFERING ---
    // TreeMap to store out-of-order packets by sequence number
    // Key: sequence number, Value: packet payload (without header)
    private val outOfOrderBuffer = TreeMap<Int, ByteArray>()
    
    // Track which sequence numbers we've received (for duplicate detection)
    private val receivedSequences = mutableSetOf<Int>()
    
    // Timeout for missing packets (milliseconds)
    private val MISSING_PACKET_TIMEOUT_MS = 5000L
    private var lastFlushTime = 0L
    
    // --- UI PROGRESS TRACKING ---
    private var totalFilesInPack = 1
    private var currentFileIndex = 1
    private var lastPercent = -1
    private var lastUiUpdateTime = 0L 

    // --- SMART PEEK FILTERING ---
    private var filterStart: Long = 0
    private var filterEnd: Long = 0
    private var isFiltering: Boolean = false
    private var isSmartPeekDone = false 
    private val calendar = Calendar.getInstance()

    // --- WATCHDOG TIMER ---
    // Safety mechanism: If the Pod stops talking for 60 seconds during a download,
    // we assume the connection died and close it to prevent the app from hanging forever.
    private val watchdogHandler = Handler(Looper.getMainLooper())
    @Volatile private var lastPacketTime: Long = 0
    private val WATCHDOG_TIMEOUT_MS = 60000L 
    //Scanner time-out variables.
    private val scanTimeoutHandler = Handler(Looper.getMainLooper())
    private val SCAN_DURATION_MS = 15000L // 15 seconds auto-stop

    private val watchdogTicker = object : Runnable {
        override fun run() {
            val now = System.currentTimeMillis()
            val timeSinceLastPacket = now - lastPacketTime

            // Case 1: Hard Timeout (No data for 60s)
            if (totalExpectedPackets > 0 && timeSinceLastPacket > WATCHDOG_TIMEOUT_MS) {
                Log.w(TAG, "Watchdog: Timeout. Force closing download.")
                finishMessage()
                return
            }

            // Case 2: The "99% Stuck" Bug
            // Only check after receiving at least 1 packet to avoid false positives.
            // Increased threshold to 5s for slow BLE connections near completion.
            if (receivedPacketCount > 0 && totalExpectedPackets > 0 && timeSinceLastPacket > 5000) {
                val progress = (receivedPacketCount.toDouble() / totalExpectedPackets.toDouble())
                if (progress > 0.98) {
                    Log.w(TAG, "Watchdog: Stuck at ${(progress * 100).toInt()}%. Finishing.")
                    finishMessage()
                    return
                }
            }
            watchdogHandler.postDelayed(this, 1000)
        }
    }

    // --- FLUTTER LIFECYCLE ---
    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()

        // Initialize background thread for BLE IO
        bluetoothThread = HandlerThread("BluetoothGateway")
        bluetoothThread.start()
        bluetoothHandler = Handler(bluetoothThread.looper)

        // Setup Channels
        channel = MethodChannel(binding.binaryMessenger, "com.example.pod_connector/methods")
        channel.setMethodCallHandler(this)

        statusChannel = EventChannel(binding.binaryMessenger, "com.example.pod_connector/status")
        statusChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(a: Any?, e: EventChannel.EventSink?) { statusSink = e }
            override fun onCancel(a: Any?) { statusSink = null }
        })

        scanChannel = EventChannel(binding.binaryMessenger, "com.example.pod_connector/scan")
        scanChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(a: Any?, e: EventChannel.EventSink?) { scanSink = e }
            override fun onCancel(a: Any?) { scanSink = null }
        })

        payloadChannel = EventChannel(binding.binaryMessenger, "com.example.pod_connector/payload")
        payloadChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(a: Any?, e: EventChannel.EventSink?) { payloadSink = e }
            override fun onCancel(a: Any?) { payloadSink = null }
        })
        
        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        bluetoothAdapter = bluetoothManager.adapter
    }

    // --- COMMAND HANDLER (Flutter -> Kotlin) ---
    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        when (call.method) {
            "startScan" -> { startScanning(); result.success(null) }
            "stopScan" -> { stopScanning(); result.success(null) }
            "connect" -> { connectToDevice(call.arguments as String); result.success(null) }
            "disconnect" -> { disconnectDevice(); result.success(null) }
            // Writes raw bytes (e.g., Stream On command)
            "writeCommand" -> { writeData(call.arguments as ByteArray); result.success(null) }
            // Initiates the complex download logic with filtering
            "downloadFile" -> {
                val filename = call.argument<String>("filename") ?: ""
                val start = call.argument<Number>("filterStart")?.toLong() ?: 0L
                val end = call.argument<Number>("filterEnd")?.toLong() ?: 0L
                totalFilesInPack = call.argument<Int>("totalFiles") ?: 1
                currentFileIndex = call.argument<Int>("currentIndex") ?: 1
                startDownloadWithGatekeeper(filename, start, end)
                result.success(null)
            }
            "cancelDownload" -> { abortDownload(); result.success(null) }
            // Requests Android permission to ignore battery optimizations (Doze mode)
            "requestBatteryExemption" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    try {
                        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        intent.data = Uri.parse("package:${context.packageName}")
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        context.startActivity(intent)
                    } catch (e: Exception) { Log.e(TAG, "Battery exemption failed", e) }
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // --- PROCESSING THREAD (The Worker) ---
    // Decouples data reception (GATT Thread) from data processing to prevent choking the BLE stack.
    private fun startProcessingThread() {
        if (isProcessing.get()) return
        isProcessing.set(true)
        
        processingThread = Thread {
            // High priority ensures we drain the queue faster than BLE fills it
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_AUDIO)

            while (isProcessing.get()) {
                try {
                    // Blocking wait for new data (with timeout to check for missing packets)
                    val packet = packetQueue.poll(1000, TimeUnit.MILLISECONDS)
                    
                    if (packet != null) {
                        if (actualPacketSize == 0) actualPacketSize = packet.size

                        // 1. Reassemble
                        processPacket(packet)

                        // 2. Smart Peek Logic
                        // Once we have enough bytes (128), check timestamp to see if we should abort.
                        if (isFiltering && currentMessageType == 0x03 && !isSmartPeekDone && payloadBuffer.size() >= 128) {
                            performSmartPeek()
                            isSmartPeekDone = true
                        }

                        // 3. UI Updates (throttled)
                        updateProgressUI()
                    } else {
                        // Timeout occurred - check if we should flush buffered packets
                        checkAndFlushOnTimeout()
                    }
                    
                    // 4. Completion Check
                    if (totalExpectedPackets > 0 && receivedPacketCount >= totalExpectedPackets) {
                        Thread.sleep(50) // Small grace period for any stragglers
                        if (packetQueue.isEmpty()) finishMessage()
                    }
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                } catch (e: Exception) {
                    Log.e(TAG, "Error in processing", e)
                }
            }
        }
        processingThread?.start()
    }

    private fun stopProcessingThread() {
        isProcessing.set(false)
        processingThread?.interrupt()
        packetQueue.clear()
    }

    // --- PACKET REASSEMBLY LOGIC ---
    // The STM32 sends data in chunks (Packets).
    // Packet 0: [Type][Seq][...][TotalPackets][...Header...] (9 bytes overhead)
    // Packet N: [Type][Seq][...Header...] (5 bytes overhead)
    // We must strip these headers to rebuild the clean binary file.
    // 
    // **OUT-OF-ORDER HANDLING**: BLE can deliver packets out of order.
    // We buffer out-of-order packets and reorder them before writing to payloadBuffer.
    private fun processPacket(packet: ByteArray) {
        if (packet.size < 5) return 

        // Extract sequence number (bytes 1-4, little endian)
        val seq = ByteBuffer.wrap(packet, 1, 4).order(ByteOrder.LITTLE_ENDIAN).int
        
        // Check for duplicate packets
        if (receivedSequences.contains(seq)) {
            Log.d(TAG, "Duplicate packet detected (seq=$seq), ignoring")
            return
        }

        if (receivedPacketCount == 0) {
            // --- HEADER PACKET (seq=1) ---
            if (packet.size < 9) {
                Log.w(TAG, "Packet too small for header (seq=$seq, size=${packet.size})")
                return
            }
            
            // Validate that this is actually the header packet (seq=1)
            if (seq != 1) {
                Log.w(TAG, "Expected header packet (seq=1), got seq=$seq. Buffering...")
                // Buffer it and wait for the real header
                outOfOrderBuffer[seq] = packet.copyOf()
                receivedSequences.add(seq)
                return
            }
            
            val type = packet[0].toInt() and 0xFF
            currentMessageType = type

            // Read Total Packets
            totalExpectedPackets = ByteBuffer.wrap(packet, 5, 4).order(ByteOrder.LITTLE_ENDIAN).int

            // Guard against corrupted headers: cap at 500,000 packets (~32MB at 64B/packet)
            val MAX_EXPECTED_PACKETS = 500_000
            if (totalExpectedPackets <= 0 || totalExpectedPackets > MAX_EXPECTED_PACKETS) {
                Log.e(TAG, "Invalid totalExpectedPackets: $totalExpectedPackets — aborting download")
                totalExpectedPackets = 0
                return
            }

            // --- OPTIMIZATION: DYNAMIC MEMORY ALLOCATION ---
            // Use the 'actualPacketSize' variable (already captured in the thread loop).
            // This ensures we respect the dynamic MTU (e.g. 64 vs 247).
            
            // Safety: Ensure we don't calculate negative numbers if packet is tiny
            val safePacketSize = if (actualPacketSize > 5) actualPacketSize else 64
            
            // Formula: Total Packets * (Payload Size) + Safety Buffer
            // Payload Size = Packet Size - 5 bytes (Type + Seq overhead)
            val estimatedSize = (totalExpectedPackets * (safePacketSize - 5)) + 2048
            
            try {
                // Allocate the exact size needed immediately
                payloadBuffer = ByteArrayOutputStream(estimatedSize)
            } catch (e: OutOfMemoryError) {
                // Fallback for extremely large files
                Log.e(TAG, "OOM allocating buffer. Falling back to default growth.", e)
                payloadBuffer = ByteArrayOutputStream()
            }
            // -----------------------------------------------

            payloadBuffer.write(currentMessageType) 
            
            if (packet.size > 9) {
                payloadBuffer.write(packet, 9, packet.size - 9)
            }
            
            receivedSequences.add(seq)
            receivedPacketCount = 1
            nextExpectedSeq = 2 // Next packet should be seq=2
            
            // Try to flush any buffered packets that arrived before the header
            flushBufferedPackets()
            
        } else {
            // --- PAYLOAD PACKET (seq >= 2) ---
            if (seq == nextExpectedSeq) {
                // Expected packet arrived in order
                if (packet.size > 5) {
                    payloadBuffer.write(packet, 5, packet.size - 5)
                }
                receivedSequences.add(seq)
                receivedPacketCount++
                nextExpectedSeq++
                
                // Flush any buffered packets that are now in order
                flushBufferedPackets()
                
            } else if (seq > nextExpectedSeq) {
                // Out-of-order packet - buffer it
                Log.d(TAG, "Out-of-order packet: expected seq=$nextExpectedSeq, got seq=$seq. Buffering...")
                outOfOrderBuffer[seq] = packet.copyOf()
                receivedSequences.add(seq)
                lastFlushTime = System.currentTimeMillis()
                
                // Check if we should flush despite gaps (timeout handling)
                checkAndFlushOnTimeout()
                
            } else {
                // seq < nextExpectedSeq - this is a duplicate or very old packet
                Log.d(TAG, "Received old/duplicate packet: seq=$seq (expected >= $nextExpectedSeq), ignoring")
            }
        }
    }
    
    /**
     * Flush buffered packets that are now in order.
     * Processes packets sequentially starting from nextExpectedSeq.
     */
    private fun flushBufferedPackets() {
        while (outOfOrderBuffer.containsKey(nextExpectedSeq)) {
            val bufferedPacket = outOfOrderBuffer.remove(nextExpectedSeq)!!
            
            if (bufferedPacket.size > 5) {
                payloadBuffer.write(bufferedPacket, 5, bufferedPacket.size - 5)
            }
            receivedPacketCount++
            nextExpectedSeq++
        }
    }
    
    /**
     * Check if we should flush buffered packets despite gaps.
     * If we've been waiting too long for missing packets, flush what we have.
     */
    private fun checkAndFlushOnTimeout() {
        if (outOfOrderBuffer.isEmpty()) return
        
        val now = System.currentTimeMillis()
        if (lastFlushTime > 0 && (now - lastFlushTime) > MISSING_PACKET_TIMEOUT_MS) {
            // Find the lowest sequence number in the buffer
            val lowestBufferedSeq = outOfOrderBuffer.firstKey()
            
            // If there's a significant gap, log a warning
            val gapSize = lowestBufferedSeq - nextExpectedSeq
            if (gapSize > 10) {
                Log.w(TAG, "Missing packets detected: gap from seq=$nextExpectedSeq to seq=$lowestBufferedSeq (size=$gapSize). Flushing buffered packets after timeout.")
            }
            
            // Flush all buffered packets in order (TreeMap maintains sorted order)
            // This allows download to continue even if some packets are lost
            val keysToProcess = outOfOrderBuffer.keys.toList()
            var maxFlushedSeq = nextExpectedSeq - 1
            
            for (seq in keysToProcess) {
                val bufferedPacket = outOfOrderBuffer.remove(seq)!!
                if (bufferedPacket.size > 5) {
                    payloadBuffer.write(bufferedPacket, 5, bufferedPacket.size - 5)
                }
                receivedPacketCount++
                maxFlushedSeq = seq
            }
            
            // Update nextExpectedSeq to skip the gap and continue from the highest flushed sequence
            if (keysToProcess.isNotEmpty()) {
                nextExpectedSeq = maxFlushedSeq + 1
                Log.d(TAG, "Timeout flush complete. Skipped gap, continuing from seq=$nextExpectedSeq")
            }
            
            lastFlushTime = 0 // Reset timeout
        }
    }

    /**
     * **Smart Peek Algorithm**
     * Instead of downloading the whole file to check the date, we check the first 128 bytes.
     * The first 64 bytes contain the File Header (Time, Size, etc.).
     * If the file time is outside the user's requested range, we send an ABORT command.
     */
    private fun performSmartPeek() {
        try {
            val allData = payloadBuffer.toByteArray()
            // Guard: need at least 129 bytes (1 type byte + 128 data bytes)
            if (allData.size < 129) return
            val peekData = ByteArray(128)
            System.arraycopy(allData, 1, peekData, 0, 128)

            // Extract Date from Header
            val yr = ByteBuffer.wrap(peekData, 4, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt()
            val mon = peekData[6].toInt() and 0xFF
            val day = peekData[7].toInt() and 0xFF
            val hr  = peekData[8].toInt() and 0xFF
            val min = peekData[9].toInt() and 0xFF
            val sec = peekData[10].toInt() and 0xFF

            calendar.clear()
            calendar.set(yr, mon - 1, day, hr, min, sec)
            val startTime = calendar.timeInMillis
            
            // Estimate duration to check end time
            val t1 = ByteBuffer.wrap(peekData, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
            val t2 = ByteBuffer.wrap(peekData, 64, 4).order(ByteOrder.LITTLE_ENDIAN).int 
            val interval = snapToStandardInterval((t2 - t1).toLong())
            val ppp = (actualPacketSize - 5).toLong() 
            val dur = ((totalExpectedPackets * ppp) / 64) * interval
            
            // Filter Logic
            if ((filterEnd > 0 && startTime > filterEnd) || (filterStart > 0 && (startTime + dur) < filterStart)) {
                abortDownload("Filtered Out")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Smart Peek Parsing Failed", e)
        }
    }

    // --- CONNECTION LOGIC ---
    private fun connectToDevice(address: String) {
        stopScanning()
        // Start Foreground Service immediately to ensure we have a WakeLock
        val serviceIntent = Intent(context, PodForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(serviceIntent)
        else context.startService(serviceIntent)
        
        startProcessingThread()
        val device = bluetoothAdapter?.getRemoteDevice(address)

        // Auto-connect set to 'false' for faster initial connection
        synchronized(gattLock) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                bluetoothGatt = device?.connectGatt(
                    context, false, gattCallback, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, bluetoothHandler
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                bluetoothGatt = device?.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                bluetoothGatt = device?.connectGatt(context, false, gattCallback)
            }
        }
    }

    private fun disconnectDevice() {
        // Send Stop signal to Service (release WakeLock)
        val serviceIntent = Intent(context, PodForegroundService::class.java)
        serviceIntent.action = "STOP"
        context.startService(serviceIntent)

        stopProcessingThread()
        synchronized(gattLock) {
            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
            bluetoothGatt = null
        }
        notificationManager.cancel(NOTIF_ID)
        sendStatus("Disconnected")
    }

    // --- DOWNLOAD FLOW ---
    private fun startDownloadWithGatekeeper(filename: String, start: Long, end: Long) {
        stopWatchdog()
        // Reset State
        packetQueue.clear()
        receivedPacketCount = 0
        totalExpectedPackets = 0
        actualPacketSize = 0 
        lastPercent = -1
        isSmartPeekDone = false 
        lastUiUpdateTime = 0
        payloadBuffer.reset()
        nextExpectedSeq = 1
        outOfOrderBuffer.clear()
        receivedSequences.clear()
        lastFlushTime = 0
        
        updateNotification("Syncing Data", "File $currentFileIndex of $totalFilesInPack", true, calculateOverallPercent(0))
        
        // Setup Filter
        filterStart = start
        filterEnd = end
        isFiltering = (start > 0L || end > 0L)
        
        // Construct Command: 0x06 + 0x20 + [32 bytes filename]
        val cleanName = filename.split("(")[0].trim()
        val nameBytes = cleanName.toByteArray(Charsets.US_ASCII)
        val command = ByteArray(34)
        command[0] = 0x06
        command[1] = 0x20
        for (i in nameBytes.indices) if (i < 32) command[i+2] = nameBytes[i]
        
        writeData(command)
        
        // Arm Watchdog
        lastPacketTime = System.currentTimeMillis()
        watchdogHandler.postDelayed(watchdogTicker, 2000)
    }

    private fun finishMessage() {
        if (currentFileIndex >= totalFilesInPack) {
            updateNotification("Pod Connected", "Sync Complete. Processing...", false)
        }
        stopWatchdog()
        
        // FLUSH DATA TO FLUTTER HERE
        val finalBytes = payloadBuffer.toByteArray()
        mainHandler.post { payloadSink?.success(finalBytes) }
        
        // Cleanup for next file
        receivedPacketCount = 0
        totalExpectedPackets = 0
        payloadBuffer.reset()
    }

    private fun abortDownload(reason: String = "User Cancelled") {
        updateNotification("Syncing Data", "Skipping file...", true, calculateOverallPercent(100))
        stopWatchdog()
        writeData(byteArrayOf(0x08)) // Send Cancel Command (0x08)
        
        packetQueue.clear()
        receivedPacketCount = 0
        totalExpectedPackets = 0
        payloadBuffer.reset()
        isSmartPeekDone = false
        nextExpectedSeq = 1
        outOfOrderBuffer.clear()
        receivedSequences.clear()
        lastFlushTime = 0
        
        // Send "Skipped" signal (0xDA) to Flutter so it moves to next file
        mainHandler.postDelayed({ payloadSink?.success(byteArrayOf(0xDA.toByte())) }, 600)
    }

    // --- GATT CALLBACKS ---
    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                sendStatus("Connected")
                // Optimization: Request priority immediately
                gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_BALANCED)
                mainHandler.postDelayed({ gatt.requestMtu(512) }, 300)
                mainHandler.postDelayed({ gatt.discoverServices() }, 600)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                disconnectDevice()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                enableNotifications(gatt)
                // Clear any leftover buffers on the Pod side
                mainHandler.postDelayed({ writeData(byteArrayOf(0x08)) }, 1000)
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val rawPacket = characteristic.value?.copyOf()
            if (rawPacket != null && rawPacket.isNotEmpty()) {
                lastPacketTime = System.currentTimeMillis()
                // Fast handoff to processing thread
                packetQueue.offer(rawPacket) 
            }
        }
    }

    // --- UI HELPERS ---
    private fun updateProgressUI() {
        val now = System.currentTimeMillis()
        // Throttle updates to max 2 per second to save UI thread
        if (now - lastUiUpdateTime < 500 && receivedPacketCount < totalExpectedPackets) return
        lastUiUpdateTime = now
        
        if (totalExpectedPackets > 0) {
            val filePercent = (receivedPacketCount * 100) / totalExpectedPackets
            val overallPercent = calculateOverallPercent(filePercent)
            
            if (overallPercent != lastPercent) {
                lastPercent = overallPercent
                mainHandler.post {
                    updateNotification("Syncing Data", "Progress: $overallPercent%", true, overallPercent)
                }
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(CHANNEL_ID, "Pod Active Connection", NotificationManager.IMPORTANCE_LOW)
            notificationManager.createNotificationChannel(serviceChannel)
        }
    }

    private fun updateNotification(title: String, text: String, isSyncing: Boolean, progress: Int = 0) {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(if (isSyncing) android.R.drawable.stat_notify_sync else android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true) 
            .setOnlyAlertOnce(true)
            .setAutoCancel(false)
        if (isSyncing) builder.setProgress(100, progress, false)
        else builder.setProgress(0, 0, false)
        notificationManager.notify(NOTIF_ID, builder.build())
    }

    private fun calculateOverallPercent(filePercent: Int): Int {
        val baseProgress = (currentFileIndex - 1).toDouble() * 100.0
        return ((baseProgress + filePercent.toDouble()) / totalFilesInPack.toDouble()).toInt().coerceIn(0, 100)
    }

    private fun snapToStandardInterval(raw: Long): Long {
        val targets = longArrayOf(100, 200, 300, 400, 500, 600, 700, 800, 900, 1000)
        var closest = 1000L
        var minDiff = Long.MAX_VALUE
        for (t in targets) { val d = Math.abs(raw - t); if (d < minDiff) { minDiff = d; closest = t } }
        return closest
    }
    
    private fun stopWatchdog() { 
        watchdogHandler.removeCallbacks(watchdogTicker) 
    }

    private fun sendStatus(msg: String) { mainHandler.post { statusSink?.success(msg) } }
    
    private fun hasPermissions() = ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED

    private fun startScanning() {
        val scanner = bluetoothAdapter?.bluetoothLeScanner ?: return
        if (hasPermissions()) {
            scanner.startScan(null, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
            
            // Auto-stop to save battery
            scanTimeoutHandler.removeCallbacksAndMessages(null)
            scanTimeoutHandler.postDelayed({ 
                Log.i(TAG, "Scan timeout reached")
                stopScanning()
                // Optional: Send event to Flutter via statusSink if you want the UI to update
            }, SCAN_DURATION_MS)
        }
    }

    private fun stopScanning() {
        // Cancel the timer if user stops manually so it doesn't fire later
        scanTimeoutHandler.removeCallbacksAndMessages(null) 
        if (hasPermissions()) bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val deviceMap = mapOf("name" to (result.device.name ?: "Unknown"), "id" to result.device.address, "rssi" to result.rssi)
            mainHandler.post { scanSink?.success(deviceMap) }
        }
    }

    private fun enableNotifications(g: BluetoothGatt) {
        val c = g.getService(SERVICE_UUID)?.getCharacteristic(NOTIFY_CHAR_UUID)
        if (c != null) {
            g.setCharacteristicNotification(c, true)
            val d = c.getDescriptor(CLIENT_CONFIG)
            d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            g.writeDescriptor(d)
        }
    }

    private fun writeData(d: ByteArray) {
        synchronized(gattLock) {
            val c = bluetoothGatt?.getService(SERVICE_UUID)?.getCharacteristic(WRITE_CHAR_UUID)
            if (c != null) {
                c.value = d
                bluetoothGatt?.writeCharacteristic(c)
            }
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        val serviceIntent = Intent(context, PodForegroundService::class.java)
        serviceIntent.action = "STOP"
        context.startService(serviceIntent)
        notificationManager.cancel(NOTIF_ID)
        bluetoothThread.quitSafely()
    }
}