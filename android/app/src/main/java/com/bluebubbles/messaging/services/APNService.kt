package com.bluebubbles.messaging.services

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.annotation.RequiresApi
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import uniffi.native_lib.NativePushState

const val APNS_PREFS = "APNS_PREFS"
const val APNS_STATE = "state"

class APNService : Service() {
    val pushState = NativePushState()
    private var started = false
    private val binder = APNBinder()
    private var ready = false;
    private var waitingHandleCb = ArrayList<(handle: ULong) -> Unit>();

    fun ready() {
        synchronized(waitingHandleCb) {
            ready = true;
            for (cb in waitingHandleCb) {
                cb(pushState.getState())
            }
        }
    }

    fun recievedMsg(ptr: ULong) {
        Handler(Looper.getMainLooper()).post {
            if (MainActivity.channel != null) {
                Log.i("ugh running", "here")
                // app is alive, deliver directly there
                MainActivity.channel.invokeMethod("APNMsg", ptr.toString())
                return@post
            }
            val onBackgroundMessageIntent = Intent(
                this@APNService,
                FlutterFirebaseMessagingBackgroundService::class.java
            )
            onBackgroundMessageIntent.putExtra("type", "APNMsg")
            onBackgroundMessageIntent.putExtra("data", ptr.toString())
            FlutterFirebaseMessagingBackgroundService.enqueueMessageProcessing(
                this@APNService,
                onBackgroundMessageIntent
            )
        }
    }

    fun configured() {
        val state = pushState.savePush()
        val sharedPrefs = applicationContext.getSharedPreferences(APNS_PREFS, Context.MODE_PRIVATE)
        with (sharedPrefs.edit()) {
            putString(APNS_STATE, state)
            apply()
        }
        listenLoop()
    }

    fun getHandle(cb: (handle: ULong) -> Unit) {
        synchronized(waitingHandleCb) {
            if (ready) {
                cb(pushState.getState())
            } else {
                waitingHandleCb.add(cb)
            }
        }
    }

    fun listenLoop() {
        Log.i("launching agent", "stalling")
        Thread {
            while (true) {
                val recievedMsg = pushState.recvWait()
                if (recievedMsg != 0UL) {
                    recievedMsg(recievedMsg)
                }
            }
        }.start()
    }
    fun launchAgent() {
        Log.i("launching agent", "herer")
        Thread {
            val sharedPrefs =
                applicationContext.getSharedPreferences(APNS_PREFS, Context.MODE_PRIVATE)
            if (sharedPrefs.contains(APNS_STATE)) {
                pushState.restore(sharedPrefs.getString(APNS_STATE, "")!!)
                listenLoop()
            } else {
                pushState.newPush()
            }
            ready()
        }.start()
    }

    @RequiresApi(Build.VERSION_CODES.O)
    fun createNotificationChannel() {
        val importance = NotificationManager.IMPORTANCE_HIGH
        val channel = NotificationChannel(FOREGROUND_SERVICE_CHANNEL, "Foreground Service", importance).apply {
            description = "Allows BlueBubbles to stay open in the background for notifications if FCM is not being used"
        }
        // Register the channel with the system
        val notificationManager: NotificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        notificationManager.createNotificationChannel(channel)
    }

    val FOREGROUND_SERVICE_CHANNEL = "com.bluebubbles.foreground_service";
    @RequiresApi(Build.VERSION_CODES.O)
    fun notifyForeground() {
        createNotificationChannel()
        val text = "BlueBubbles stays connected directly to Apple Push Notification service to keep you up to date on your messages. Hold and turn off notifications for this channel to hide this notification."
        val notification: Notification = Notification.Builder(this, FOREGROUND_SERVICE_CHANNEL)
            .setContentTitle("Connected to APNs")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setStyle(Notification.BigTextStyle()
                .bigText(text))
            .build()

        // Notification ID cannot be 0.
        startForeground(3884785, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifyForeground()
        }
        if (!started) {
            if (ContextHolder.getApplicationContext() == null) {
                ContextHolder.setApplicationContext(applicationContext)
            }
            launchAgent()
            started = true
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onDestroy() {
        super.onDestroy()
        pushState.destroy()
    }

    override fun onBind(intent: Intent): IBinder {
        if (!started) {
            throw Exception("APNService not started!")
        }
        return binder
    }

    inner class APNBinder : Binder() {
        fun getService(): APNService = this@APNService
    }
}

class APNClient(val context: Context) {
    private lateinit var mService: APNService
    private var mBound: Boolean = false
    private var mCallback: ((service: APNService) -> Unit)? = null

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(className: ComponentName, service: IBinder) {
            // We've bound to LocalService, cast the IBinder and get LocalService instance.
            val binder = service as APNService.APNBinder
            mService = binder.getService()
            mBound = true
            mCallback?.let { it(mService) }
        }

        override fun onServiceDisconnected(arg0: ComponentName) {
            mBound = false
        }
    }

    fun getService(): APNService {
        return mService
    }

    fun bind(cb: (service: APNService) -> Unit) {
        mCallback = cb
        Intent(context, APNService::class.java).also { intent ->
            context.bindService(intent, connection, 0)
        }
    }

    fun destroy() {
        context.unbindService(connection)
        mBound = false
    }
}