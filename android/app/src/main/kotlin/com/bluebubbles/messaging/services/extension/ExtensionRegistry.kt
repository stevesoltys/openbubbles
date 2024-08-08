package com.bluebubbles.messaging.services.extension

import android.content.ComponentName

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
}