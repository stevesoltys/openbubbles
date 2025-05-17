package com.bluebubbles.messaging.services.extension

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager

data class AvailableExtension(
    val store: String,
    val appPackage: String,
    val madridName: String,
    val madridBundleId: String,
    val serviceName: String,
) {
    fun getServiceName(): ComponentName {
        return ComponentName.createRelative(appPackage, serviceName)
    }
}

// also add to queries in manifest
object ExtensionRegistry {
    val map = hashMapOf<Int, AvailableExtension>(
//        1124197642 to AvailableExtension(
//            "https://play.google.com/store/games?hl=en_US",
//            "com.example.openbubblesextension",
//            "GamePigeon",
//            "com.apple.messages.MSMessageExtensionBalloonPlugin:EWFNLB79LQ:com.gamerdelights.gamepigeon.ext",
//            ".MadridExtensionService"
//        )
    )

    fun registerDevExtension(context: Context, name: String) {
        val parts = ArrayList(name.split("."))
        val cls = "." + parts.removeLast()
        val pak = parts.joinToString(".")
        val component = ComponentName.createRelative(pak, cls)
        val service = context.packageManager.getServiceInfo(component, PackageManager.GET_META_DATA)

        map[service.metaData.getInt("madrid_id")] = AvailableExtension(
            "https://play.google.com/store/games?hl=en_US",
            pak,
            service.metaData.getString("madrid_name")!!,
            service.metaData.getString("madrid_bundle_id")!!,
            cls,
        )
    }
}