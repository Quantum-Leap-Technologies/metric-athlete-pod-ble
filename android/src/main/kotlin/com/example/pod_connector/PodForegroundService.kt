package com.example.pod_connector

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * A Foreground Service that keeps the app alive during long operations.
 * * **Why is this needed?**
 * Modern Android (8.0+) aggressively kills background apps to save battery. 
 * If the user turns off the screen during a large file download, the OS will kill the Bluetooth connection 
 * within minutes unless we run a "Foreground Service" which shows a visible notification to the user.
 * * **Key Features:**
 * 1. **WakeLock:** Keeps the CPU awake even when the screen is off.
 * 2. **Foreground Notification:** Marks this process as "User Visible" so Android doesn't kill it.
 */
class PodForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    
    // Must match the ID used in the Plugin class so we can update the same notification
    private val CHANNEL_ID = "PodPersistentChannel"
    private val NOTIF_ID = 777

    /**
     * Called when the service is first created.
     * We acquire the WakeLock here to ensure the CPU never sleeps while we are active.
     */
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        
        // 1. Acquire the WakeLock
        // PARTIAL_WAKE_LOCK = Screen can be off, but CPU remains on.
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "PodConnector:ForegroundServiceLock")
        
        // Safety: Limit lock to 4 hours. 
        // If the app crashes or forgets to stop the service, this prevents draining the user's battery forever.
        wakeLock?.acquire(4 * 60 * 60 * 1000L) 
    }

    /**
     * Called every time startService() is called.
     * Handles the commands to Start (Default) or Stop the service.
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Handle "STOP" action sent from the Plugin disconnect logic
        if (intent?.action == "STOP") {
            stopSelf()
            return START_NOT_STICKY
        }

        // 2. Start the Foreground Notification
        // This is the magic line that promotes this Service to "Foreground" status.
        // Without this, the app would be killed in background.
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Pod Connected")
            .setContentText("Maintaining active link...")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true) // User cannot swipe this away (must disconnect to remove)
            .build()

        startForeground(NOTIF_ID, notification)
        
        // START_NOT_STICKY: If the system kills us for memory, don't restart automatically.
        // (We rely on the user to reopen the app).
        return START_NOT_STICKY
    }

    /**
     * Cleanup when the service is stopped.
     * CRITICAL: We must release the WakeLock to allow the phone to sleep again.
     */
    override fun onDestroy() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        super.onDestroy()
    }

    // We don't allow binding to this service (we communicate via Plugin MethodChannels instead)
    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    /**
     * Boilerplate to create the Notification Channel required by Android 8.0+ (Oreo).
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Pod Active Connection",
                NotificationManager.IMPORTANCE_LOW // Low importance = No sound/vibration
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }
}