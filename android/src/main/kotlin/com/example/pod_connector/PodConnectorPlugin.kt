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
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
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
import java.util.concurrent.atomic.AtomicBoolean

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
    // The download stream has no packet-count header (see PacketFraming). The expected
    // size is the exact byte size from the pod's file list, passed in by Flutter;
    // 0 means unknown. receivedBytes counts payload bytes (frame overhead excluded).
    @Volatile private var expectedBytes = 0L
    @Volatile private var receivedBytes = 0L
    private var actualPacketSize = 0 // Auto-detected from first packet (usually ~240 bytes for MTU 512)
    private var currentMessageType = 0
    
    // --- UI PROGRESS TRACKING ---
    private var totalFilesInPack = 1
    private var currentFileIndex = 1
    private var lastPercent = -1
    private var lastUiUpdateTime = 0L 

    // --- DOWNLOAD STATE ---
    @Volatile private var isDownloadActive = false

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

            // Case 1: no data for 60s during a download. The link is dead, and what we
            // have is a partial file: discard it and report a failure. It must NEVER be
            // delivered to Flutter as if it were a finished file.
            if (isDownloadActive && timeSinceLastPacket > WATCHDOG_TIMEOUT_MS) {
                Log.w(TAG, "Watchdog: no data for ${WATCHDOG_TIMEOUT_MS / 1000}s at $receivedBytes/$expectedBytes bytes. Discarding the partial download.")
                failDownload("Download timed out")
                return
            }

            // Case 2: the file size is unknown (no entry in the file list), so we cannot
            // tell when it is complete: treat a quiet gap after data as the end.
            if (isDownloadActive && expectedBytes == 0L && receivedPacketCount > 0 && timeSinceLastPacket > 5000) {
                Log.w(TAG, "Watchdog: size unknown, no data for 5s after $receivedBytes bytes. Finishing.")
                finishMessage()
                return
            }
            watchdogHandler.postDelayed(this, 1000)
        }
    }

    // --- BLUETOOTH STATE RECEIVER ---
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_OFF -> sendStatus("Bluetooth Off")
                    BluetoothAdapter.STATE_ON -> sendStatus("Bluetooth Ready")
                }
            }
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

        // Register Bluetooth state change receiver
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        context.registerReceiver(bluetoothStateReceiver, filter)
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
                val expected = call.argument<Number>("expectedBytes")?.toLong() ?: 0L
                startDownloadWithGatekeeper(filename, start, end, expected)
                result.success(null)
            }
            "cancelDownload" -> { abortDownload(); result.success(null) }
            // Requests Android permission to ignore battery optimizations (Doze mode)
            "requestBatteryExemption" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    try {
                        // Only launch the system settings screen if we are NOT already
                        // exempt. Launching it unconditionally steals and returns focus,
                        // which fires the app's lifecycle "resumed" handler and — when a
                        // scan screen re-scans on resume — drives a runaway startScan loop.
                        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (!pm.isIgnoringBatteryOptimizations(context.packageName)) {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            intent.data = Uri.parse("package:${context.packageName}")
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            context.startActivity(intent)
                        }
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
                    // Blocking wait for new data
                    val packet = packetQueue.take()
                    if (actualPacketSize == 0) actualPacketSize = packet.size

                    // 1. Route: only reassemble during active downloads,
                    //    otherwise pass raw packet directly to Flutter
                    val frame = PacketFraming.parseFrame(packet)
                    if (isDownloadActive && frame != null && frame.type == PacketFraming.TYPE_FILE_DATA) {
                        processPacket(frame)
                    } else {
                        Log.d(TAG, "[ROUTE] Non-download packet (${packet.size}B, type=0x${if (packet.isNotEmpty()) String.format("%02X", packet[0]) else "??"}) → Flutter")
                        mainHandler.post { payloadSink?.success(packet) }
                        continue
                    }

                    // 2. Smart Peek Logic
                    // Once we have enough bytes (128), check timestamp to see if we should abort.
                    if (isFiltering && currentMessageType == 0x03 && !isSmartPeekDone && payloadBuffer.size() >= 128) {
                        performSmartPeek()
                        isSmartPeekDone = true
                    }

                    // 3. UI Updates (throttled)
                    updateProgressUI()
                    
                    // 4. Completion Check
                    // Finish as soon as the file's declared size has arrived. This must
                    // not wait for the queue to be empty: the pod keeps sending while we
                    // process, so the queue never drained and the download only ended
                    // when the 5s watchdog fired.
                    if (expectedBytes > 0 && receivedBytes >= expectedBytes) {
                        finishMessage()
                        // Anything still queued belongs to a finished download; do not
                        // forward it to Flutter as individual "non-download" packets.
                        packetQueue.clear()
                    }
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                } catch (e: SecurityException) {
                    // BLE permissions revoked at runtime
                    Log.e(TAG, "SecurityException — BLE permissions may have been revoked", e)
                    sendStatus("Permissions Error")
                    break
                } catch (e: android.os.DeadObjectException) {
                    // GATT server died
                    Log.e(TAG, "DeadObjectException — GATT server died", e)
                    sendStatus("Connection Lost")
                    break
                } catch (e: android.os.RemoteException) {
                    // IPC failure
                    Log.e(TAG, "RemoteException — IPC failure", e)
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
    // Each notification is [0xAE][type][length][payload] (see PacketFraming). For a
    // file download (type 0x03) the payloads are consecutive raw records; we append them
    // in order and the download is complete when expectedBytes have arrived. There is no
    // header packet. Anything that is not a file-data frame never reaches this function.
    private fun processPacket(frame: PacketFraming.Frame) {
        if (receivedPacketCount == 0) {
            currentMessageType = frame.type
            // Allocate the whole file up front when the size is known.
            val estimated = if (expectedBytes > 0) {
                (expectedBytes + 2048).coerceAtMost((Int.MAX_VALUE / 2).toLong()).toInt()
            } else {
                1 shl 20
            }
            try {
                payloadBuffer = ByteArrayOutputStream(estimated)
            } catch (e: OutOfMemoryError) {
                // Fallback for extremely large files
                Log.e(TAG, "OOM allocating buffer. Falling back to default growth.", e)
                payloadBuffer = ByteArrayOutputStream()
            }
            // The Dart side dispatches on the first byte: the message type.
            payloadBuffer.write(currentMessageType)
            Log.d(TAG, "[PACKET] First data frame: type=0x${String.format("%02X", frame.type)}, payload=${frame.payload.size}B, expectedBytes=$expectedBytes")
        }
        payloadBuffer.write(frame.payload)
        receivedBytes += frame.payload.size
        receivedPacketCount++
    }

    /**
     * Detect firmware record size from peek data (47, 61 or 64 bytes).
     * Checks if a valid record header exists at the start of the second record.
     * Returns 47 for V3.6 (v01), 61 for Proewe, 64 for HTS firmware.
     */
    private fun detectRecordSize(peekData: ByteArray): Int {
        // Check for V3.6 v01 format (47-byte records)
        if (peekData.size >= 55) {
            val year = ByteBuffer.wrap(peekData, 51, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF
            val month = peekData[53].toInt() and 0xFF
            val day = peekData[54].toInt() and 0xFF
            if (year in 2022..2030 && month in 1..12 && day in 1..31) return 47
        }
        // Check for Proewe format (61-byte records)
        if (peekData.size >= 69) {
            val year = ByteBuffer.wrap(peekData, 65, 2).order(ByteOrder.LITTLE_ENDIAN).short.toInt() and 0xFFFF
            val month = peekData[67].toInt() and 0xFF
            val day = peekData[68].toInt() and 0xFF
            if (year in 2022..2030 && month in 1..12 && day in 1..31) return 61
        }
        return 64
    }

    /**
     * **Smart Peek Algorithm**
     * Instead of downloading the whole file to check the date, we check the first 128 bytes.
     * The first record contains the File Header (Time, Size, etc.).
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

            // Estimate duration — detect record size to handle 61-byte (Proewe) and 64-byte (HTS) firmware
            val recordSize = detectRecordSize(peekData)
            val t1 = ByteBuffer.wrap(peekData, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
            val t2 = ByteBuffer.wrap(peekData, recordSize, 4).order(ByteOrder.LITTLE_ENDIAN).int
            val interval = snapToStandardInterval((t2 - t1).toLong())
            // Without the file size we cannot estimate the duration, so do not filter.
            if (expectedBytes <= 0L) return
            val dur = (expectedBytes / recordSize) * interval

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
                // Allow both 1M and 2M PHY at connect time; 2M upgrade requested in onConnectionStateChange
                bluetoothGatt = device?.connectGatt(
                    context, false, gattCallback, BluetoothDevice.TRANSPORT_LE,
                    BluetoothDevice.PHY_LE_1M_MASK or BluetoothDevice.PHY_LE_2M_MASK, bluetoothHandler
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                bluetoothGatt = device?.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                bluetoothGatt = device?.connectGatt(context, false, gattCallback)
            }
        }
    }

    private fun disconnectDevice() {
        // A disconnect ends any download: reset the download state and drop the
        // buffer. Without this the watchdog fired 60s later and delivered the partial
        // file (e.g. 0.2 MB of 16 MB) to Flutter as a finished one.
        resetDownloadState()
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
    private fun startDownloadWithGatekeeper(filename: String, start: Long, end: Long, expected: Long) {
        stopWatchdog()
        // Reset State
        isDownloadActive = true
        packetQueue.clear()
        receivedPacketCount = 0
        receivedBytes = 0L
        expectedBytes = expected
        actualPacketSize = 0 
        lastPercent = -1
        isSmartPeekDone = false 
        lastUiUpdateTime = 0
        payloadBuffer.reset()
        
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
        
        Log.d(TAG, "[DOWNLOAD] Starting download: file='$cleanName', filter=${if (isFiltering) "${filterStart}-${filterEnd}" else "none"}, file $currentFileIndex/$totalFilesInPack")
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
        isDownloadActive = false

        // FLUSH DATA TO FLUTTER HERE
        var finalBytes = payloadBuffer.toByteArray()
        // 1 type byte + payload. Never deliver more than the file holds.
        if (expectedBytes > 0 && finalBytes.size - 1 > expectedBytes) {
            finalBytes = finalBytes.copyOf((expectedBytes + 1).toInt())
        }
        Log.d(TAG, "[FINISH] Download complete: type=0x${String.format("%02X", currentMessageType)}, ${finalBytes.size}B (expected ${if (expectedBytes > 0) expectedBytes else -1}), $receivedPacketCount packets")
        mainHandler.post { payloadSink?.success(finalBytes) }

        // Cleanup for next file
        receivedPacketCount = 0
        receivedBytes = 0L
        expectedBytes = 0L
        payloadBuffer.reset()
    }

    /** Throws away any download in progress: nothing partial is ever delivered. */
    private fun resetDownloadState() {
        stopWatchdog()
        isDownloadActive = false
        packetQueue.clear()
        receivedPacketCount = 0
        receivedBytes = 0L
        expectedBytes = 0L
        payloadBuffer.reset()
        isSmartPeekDone = false
    }

    /**
     * The download cannot finish (the link went quiet). Discard the partial file and
     * tell Flutter the connection is gone, so the sync fails and retries instead of
     * parsing half a file as a finished one.
     */
    private fun failDownload(reason: String) {
        resetDownloadState()
        sendStatus("Disconnected: $reason")
        disconnectDevice()
    }

    private fun abortDownload(reason: String = "User Cancelled") {
        updateNotification("Syncing Data", "Skipping file...", true, calculateOverallPercent(100))
        stopWatchdog()
        isDownloadActive = false
        writeData(byteArrayOf(0x08)) // Send Cancel Command (0x08)
        
        packetQueue.clear()
        receivedPacketCount = 0
        receivedBytes = 0L
        expectedBytes = 0L
        payloadBuffer.reset()
        isSmartPeekDone = false
        
        // Send "Skipped" signal (0xDA) to Flutter so it moves to next file
        mainHandler.postDelayed({ payloadSink?.success(byteArrayOf(0xDA.toByte())) }, 600)
    }

    // --- GATT CALLBACKS ---
    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                sendStatus("Connected")
                // Optimization: Request HIGH priority for fastest connection interval (~7.5ms)
                // This also triggers Data Length Extension (DLE) negotiation on Android 8+
                gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                mainHandler.postDelayed({ gatt.requestMtu(512) }, 300)
                // Request 2M PHY for double throughput (BLE 5.0)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    mainHandler.postDelayed({
                        gatt.setPreferredPhy(
                            BluetoothDevice.PHY_LE_2M_MASK,
                            BluetoothDevice.PHY_LE_2M_MASK,
                            BluetoothDevice.PHY_OPTION_NO_PREFERRED
                        )
                    }, 400)
                }
                mainHandler.postDelayed({ gatt.discoverServices() }, 600)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                disconnectDevice()
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.d(TAG, "[BLE] MTU negotiated: ${mtu} bytes (payload=${mtu - 3} bytes). DLE should be active if MTU > 27.")
            } else {
                Log.w(TAG, "[BLE] MTU negotiation failed with status $status, using default MTU")
            }
        }

        override fun onPhyUpdate(gatt: BluetoothGatt, txPhy: Int, rxPhy: Int, status: Int) {
            val phyName = { phy: Int -> when (phy) {
                BluetoothDevice.PHY_LE_1M -> "1M"
                BluetoothDevice.PHY_LE_2M -> "2M"
                BluetoothDevice.PHY_LE_CODED -> "Coded"
                else -> "Unknown($phy)"
            }}
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.d(TAG, "[BLE] PHY updated: TX=${phyName(txPhy)}, RX=${phyName(rxPhy)}")
            } else {
                Log.w(TAG, "[BLE] PHY update failed (status=$status), staying on current PHY")
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                enableNotifications(gatt)
                // Clear any leftover buffers on the Pod side
                mainHandler.postDelayed({ writeData(byteArrayOf(0x08)) }, 1000)
            }
        }

        // Android 13+ (API 33) delivers the notification bytes WITH the callback. Use
        // that: reading characteristic.value in the old callback reads a buffer shared
        // by every notification, so a packet arriving right behind another can
        // overwrite it before we copy it. A lost/duplicated header packet then makes
        // every following data packet be parsed as a header (garbage packet counts).
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            enqueueNotification(value.copyOf())
        }

        // Android 12 and older only call this one.
        @Suppress("DEPRECATION")
        @Deprecated("Replaced by the three-argument callback on API 33+")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            enqueueNotification(characteristic.value?.copyOf())
        }

        private fun enqueueNotification(rawPacket: ByteArray?) {
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
        if (now - lastUiUpdateTime < 500 && receivedBytes < expectedBytes) return
        lastUiUpdateTime = now
        
        if (expectedBytes > 0) {
            val filePercent = minOf(100L, (receivedBytes * 100) / expectedBytes).toInt()
            val overallPercent = calculateOverallPercent(filePercent)
            
            if (overallPercent != lastPercent) {
                lastPercent = overallPercent
                sendStatus("Downloading $filePercent%")
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
        if (bluetoothAdapter == null || bluetoothAdapter?.isEnabled != true) {
            sendStatus("Bluetooth Off")
            return
        }
        val scanner = bluetoothAdapter?.bluetoothLeScanner ?: run {
            sendStatus("Bluetooth Off")
            return
        }
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
                // Prepend 0xAE message header per BLE ICD V3.6 protocol spec.
                val packet = byteArrayOf(0xAE.toByte()) + d
                c.value = packet
                bluetoothGatt?.writeCharacteristic(c)
            }
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        try { context.unregisterReceiver(bluetoothStateReceiver) } catch (_: Exception) {}
        val serviceIntent = Intent(context, PodForegroundService::class.java)
        serviceIntent.action = "STOP"
        context.startService(serviceIntent)
        notificationManager.cancel(NOTIF_ID)
        bluetoothThread.quitSafely()
    }
}