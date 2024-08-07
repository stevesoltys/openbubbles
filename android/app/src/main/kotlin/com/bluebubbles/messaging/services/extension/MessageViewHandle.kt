package com.bluebubbles.messaging.services.extension

import com.bluebubbles.messaging.IMessageViewHandle
import com.bluebubbles.messaging.ITaskCompleteCallback
import com.bluebubbles.messaging.MadridMessage
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import io.flutter.plugin.common.MethodChannel

class MessageViewHandle(val session: String, val appId: Int, val guid: String?, val destroy: () -> Unit) : IMessageViewHandle.Stub() {

    var locked = false
    var alive = false

    override fun updateMessage(
        message: MadridMessage?,
        callback: ITaskCompleteCallback?
    ) {
        val myMsg = MadridMessageUtil.toMap(message!!)
        myMsg["appId"] = appId
        myMsg["session"] = session
        myMsg["messageGuid"] = guid!!
        MethodCallHandler.invokeMethodCb("extension-update-message", myMsg, object: MethodChannel.Result {
            override fun success(result: Any?) {
                callback?.complete()
            }

            override fun notImplemented() {
                throw Exception("not implemeneted!")
            }

            override fun error(
                errorCode: String,
                errorMessage: String?,
                errorDetails: Any?
            ) {
                // handled in dart
            }
        })
    }

    override fun lock() {
        locked = true
    }

    override fun unlock() {
        locked = false
        if (!alive) {
            destroy()
            MessageViewRegistry.registered.remove(session)
        }
    }

    fun markDead() {
        alive = false
        if (!locked) {
            destroy()
            MessageViewRegistry.registered.remove(session)
        }
    }

}