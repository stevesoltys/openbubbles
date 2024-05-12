package com.bluebubbles.messaging.services.rustpush

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
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorkManager
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.telephony_plus.receive.SMSObserver
import com.google.gson.GsonBuilder
import com.google.gson.ToNumberPolicy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import uniffi.rust_lib_bluebubbles.NativePushState
import uniffi.rust_lib_bluebubbles.initNative
import uniffi.rust_lib_bluebubbles.MsgReceiver

class APNService : Service(), MsgReceiver {
    lateinit var pushState: NativePushState
    private var started = false
    private val binder = APNBinder()
    private var ready = false;
    private var waitingHandleCb = ArrayList<(handle: ULong) -> Unit>();

    private val job = SupervisorJob()
    private val scope = CoroutineScope(Dispatchers.IO + job)

    companion object {
        var validPtrs: ArrayList<String> = arrayListOf()
    }

    fun ready() {
        Log.i("launching agent", "ready")
        synchronized(waitingHandleCb) {
            ready = true;
            for (cb in waitingHandleCb) {
                cb(pushState.getState())
            }
        }
    }

    override fun receievedMsg(ptr: ULong) {
        Handler(Looper.getMainLooper()).post {
            if (MainActivity.engine != null) {
                Log.i("ugh running", "here $ptr")
                // app is alive, deliver directly there
                MethodCallHandler.invokeMethod("APNMsg", mapOf("pointer" to ptr.toString()))
                return@post
            }
            Log.i("ugh running", "backend $ptr")
            validPtrs.add(ptr.toString())
            DartWorkManager.createWorker(this@APNService, "APNMsg", hashMapOf("pointer" to ptr.toString())) {}
        }
    }

    fun configured() {
        pushState.startLoop(this)
    }

    fun getHandle(cb: (handle: ULong) -> Unit) {
        Log.i("launching agent", "getting handle")
        synchronized(waitingHandleCb) {
            if (ready) {
                cb(pushState.getState())
            } else {
                Log.i("launching agent", "stalled")
                waitingHandleCb.add(cb)
            }
        }
    }

    override fun nativeReady(isReady: Boolean, state: NativePushState) {
        pushState = state
        if (isReady) {
            state.startLoop(this)
        }
        ready()
    }

    fun launchAgent() {
        Log.i("launching agent", "herer")
        SMSObserver.init(applicationContext) { context, map ->
            if (MainActivity.engine != null) {
                // app is alive, deliver directly there
                MethodCallHandler.invokeMethod("SMSMsg", map)
                return@init
            }
            MethodCallHandler.queueId += 1
            val gson = GsonBuilder()
                .setObjectToNumberStrategy(ToNumberPolicy.LONG_OR_DOUBLE)
                .create()
            MethodCallHandler.queuedMessages[MethodCallHandler.queueId] = gson.toJson(map).toString()
            DartWorkManager.createWorker(context, "SMSMsg", hashMapOf("id" to MethodCallHandler.queueId)) {}
        }
        initNative(applicationContext.filesDir.path, this)
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
        val text = "Hold and turn off notifications to hide this notification"
        val notification: Notification = Notification.Builder(this, FOREGROUND_SERVICE_CHANNEL)
            .setContentTitle("Connected to APNs")
            .setContentText(text)
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .setStyle(Notification.BigTextStyle()
                .bigText(text))
            .build()

        // Notification ID cannot be 0.
        startForeground(3884785, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!started) {
            Log.i("launching agent", "start commanded")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                notifyForeground()
            }
            launchAgent()
            started = true
        }
        return super.onStartCommand(intent, flags, startId)
    }

    override fun onDestroy() {
        super.onDestroy()
        pushState.destroy()
        job.cancel()
    }

    override fun onBind(intent: Intent): IBinder {
        Log.i("trybindsfsf", "bound")
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
            Log.i("trybindsfsf", "trying to bind")
            val result = context.bindService(intent, connection, 0)
            Log.i("trybindresult", result.toString());
        }
    }

    fun destroy() {
        context.unbindService(connection)
        mBound = false
    }
}