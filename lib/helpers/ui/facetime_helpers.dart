import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/helpers/ui/ui_helpers.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/intents_service.dart';
import 'package:bluebubbles/services/backend/java_dart_interop/method_channel_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:faker/faker.dart' hide Image;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:bluebubbles/services/backend/notifications/notifications_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:url_launcher/url_launcher.dart';

Map<String, Route> faceTimeOverlays = {}; // Map from call uuid to overlay route

/// Hides the FaceTime overlay with the given [callUuid]
/// Also calls [NotificationsService.clearFaceTimeNotification] to clear the notification
void hideFaceTimeOverlay(String callUuid, {bool timeout = false}) {
  if (Platform.isAndroid && timeout) {
    mcs.invokeMethod("update-call-state", {
      "callUuid": callUuid,
      "state": "timeout",
    });
  }

  notif.clearFaceTimeNotification(callUuid);
  if (faceTimeOverlays.containsKey(callUuid)) {
    Get.removeRoute(faceTimeOverlays[callUuid]!);
    faceTimeOverlays.remove(callUuid);
  }
}

/// Shows a FaceTime overlay with the given [callUuid], [caller], [chatIcon], and [isAudio]
/// Saves the overlay route in [faceTimeOverlays]
Future<void> showFaceTimeOverlay(String callUuid, String caller, Uint8List? chatIcon, String link) async {
  if (ss.settings.redactedMode.value && ss.settings.hideContactInfo.value) {
    if (chatIcon != null) chatIcon = null;
    caller = faker.person.name();
  }
  chatIcon ??= (await rootBundle.load("assets/images/person64.png")).buffer.asUint8List();
  chatIcon = await clip(chatIcon, size: 256, circle: true);

  // If we are somehow already showing an overlay for this call, close it
  hideFaceTimeOverlay(callUuid);

  showDialog(
    context: Get.context!,
    barrierDismissible: false,
    builder: (_) {
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
        child: AlertDialog(
          icon: Image.memory(chatIcon!, width: 48, height: 48),
          title: Text(caller),
          content: const Text(
            "Incoming FaceTime Call",
            textAlign: TextAlign.center,
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            MaterialButton(
              elevation: 0,
              hoverElevation: 0,
              color: Colors.red.withOpacity(0.2),
              splashColor: Colors.red,
              highlightColor: Colors.red.withOpacity(0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
              padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 36.0),
              child: Column(
                children: [
                  Icon(
                    ss.settings.skin.value == Skins.iOS ? CupertinoIcons.phone_down : Icons.call_end_outlined,
                    color: Colors.red,
                  ),
                  const Text(
                    "Decline",
                  ),
                ],
              ),
              onPressed: () async {
                hideFaceTimeOverlay(callUuid);
                await api.declineFacetime(state: pushService.state, guid: callUuid);
              },
            ),
            const SizedBox(width: 16.0),
            MaterialButton(
              elevation: 0,
              hoverElevation: 0,
              color: Colors.green.withOpacity(0.2),
              splashColor: Colors.green,
              highlightColor: Colors.green.withOpacity(0.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
              padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 36.0),
              child: Column(
                children: [
                  Icon(
                    ss.settings.skin.value == Skins.iOS ? CupertinoIcons.phone : Icons.call_outlined,
                    color: Colors.green,
                  ),
                  const Text(
                    "Accept",
                  ),
                ],
              ),
              onPressed: () async {
                hideFaceTimeOverlay(callUuid);
                if (Platform.isAndroid) {
                  await mcs.invokeMethod("launch-facetime", {'link': link, 'callUuid': callUuid, 'desc': caller, 'name': ss.settings.userName.value == "You" ? (await api.getHandles(state: pushService.state)).first.replaceFirst("tel:", "").replaceFirst("mailto:", "") : ss.settings.userName.value, 'answer': true});
                } else {
                  await launchUrl(
                      Uri.parse(link),
                      mode: LaunchMode.externalApplication
                  );
                }
              },
            ),
          ],
        ),
      );
    }).then((_) => faceTimeOverlays.remove(callUuid) /* Not explicitly necessary since all ways of closing the dialog do this, but just in case */
  );

  // Save dialog as overlay route
  faceTimeOverlays[callUuid] = Get.rawRoute!;
}



Future<void> showOutgoingFaceTimeOverlay(RxString callState, String desc, String caller, List<String> targets, Uint8List? chatIcon, String link) async {
  var callUuid = callState.value;

  if (ss.settings.redactedMode.value && ss.settings.hideContactInfo.value) {
    if (chatIcon != null) chatIcon = null;
    desc = faker.person.name();
  }
  chatIcon ??= (await rootBundle.load("assets/images/person64.png")).buffer.asUint8List();
  chatIcon = await clip(chatIcon, size: 256, circle: true);

  // If we are somehow already showing an overlay for this call, close it
  hideFaceTimeOverlay(callUuid);

  showDialog(
    context: Get.context!,
    barrierDismissible: false,
    builder: (_) {
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 2, sigmaY: 2),
        child: Obx(() {
          var state = callState.value;
          var hasEnded = state == "timeout" || state == "declined";
          return AlertDialog(
            icon: Image.memory(chatIcon!, width: 48, height: 48),
            title: Text(desc),
            content: Text(
              hasEnded ? "Not Available" : "Ringing...",
              textAlign: TextAlign.center,
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              if (hasEnded)
              MaterialButton(
                elevation: 0,
                hoverElevation: 0,
                color: Colors.green.withOpacity(0.2),
                splashColor: Colors.green,
                highlightColor: Colors.green.withOpacity(0.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 36.0),
                child: Column(
                  children: [
                    Icon(
                      ss.settings.skin.value == Skins.iOS ? CupertinoIcons.phone : Icons.call_outlined,
                      color: Colors.green,
                    ),
                    const Text(
                      "Call Again",
                    ),
                  ],
                ),
                onPressed: () async {
                  hideFaceTimeOverlay(callUuid);
                  await pushService.placeOutgoingCall(caller, targets);
                },
              ),
              if (hasEnded)
              const SizedBox(width: 16),
              if (hasEnded)
              MaterialButton(
                elevation: 0,
                hoverElevation: 0,
                color: Colors.red.withOpacity(0.2),
                splashColor: Colors.red,
                highlightColor: Colors.red.withOpacity(0.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 36.0),
                child: const Column(
                  children: [
                    Icon(
                      Icons.close,
                      color: Colors.red,
                    ),
                    Text(
                      "Cancel",
                    ),
                  ],
                ),
                onPressed: () async {
                  hideFaceTimeOverlay(callUuid);
                },
              ),
              if (!hasEnded)
              MaterialButton(
                elevation: 0,
                hoverElevation: 0,
                color: Colors.red.withOpacity(0.2),
                splashColor: Colors.red,
                highlightColor: Colors.red.withOpacity(0.5),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                padding: const EdgeInsets.symmetric(vertical: 16.0, horizontal: 36.0),
                child: Column(
                  children: [
                    Icon(
                      ss.settings.skin.value == Skins.iOS ? CupertinoIcons.phone_down : Icons.call_end_outlined,
                      color: Colors.red,
                    ),
                    const Text(
                      "End",
                    ),
                  ],
                ),
                onPressed: () async {
                  hideFaceTimeOverlay(callUuid, timeout: true);
                  pushService.outgoingCallTimer?.cancel();
                  await api.cancelFacetime(state: pushService.state, guid: callUuid);
                  pushService.currentOutgoingCall = null;
                },
              ),
            ],
          );
        })
      );
    }).then((_) async {
      faceTimeOverlays.remove(callUuid);
    }
  );

  // Save dialog as overlay route
  faceTimeOverlays[callUuid] = Get.rawRoute!;
}
