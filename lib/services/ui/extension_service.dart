

import 'dart:convert';

import 'package:bluebubbles/helpers/types/constants.dart';
import 'package:bluebubbles/main.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bluebubbles/helpers/types/constants.dart' as constants;


class App {
    int appId;
    String store;
    String madridName;
    String madridBundleId;
    AvailableApp? available;

    App({
        required this.appId,
        required this.store,
        required this.madridName,
        required this.madridBundleId,
        this.available,
    });

    factory App.fromMap(Map<String, dynamic> json) => App(
        appId: json["appId"],
        store: json["store"],
        madridName: json["madridName"],
        madridBundleId: json["madridBundleId"],
        available: json["available"] == null ? null : AvailableApp.fromMap(json["available"]),
    );

    Map<String, dynamic> toMap() => {
        "appId": appId,
        "store": store,
        "madridName": madridName,
        "madridBundleId": madridBundleId,
        "available": available?.toMap(),
    };
}

class AvailableApp {
    String name;
    String icon;

    AvailableApp({
        required this.name,
        required this.icon,
    });

    factory AvailableApp.fromMap(Map<String, dynamic> json) => AvailableApp(
        name: json["name"],
        icon: json["icon"],
    );

    Map<String, dynamic> toMap() => {
        "name": name,
        "icon": icon,
    };
}


ExtensionService es = Get.isRegistered<ExtensionService>() ? Get.find<ExtensionService>() : Get.put(ExtensionService());

class ExtensionService extends GetxService {

  List<App> cachedStatus = [];

  Map<String, String?> amkToLatest = {};

  String? getLatest(String amk) {
    if (amkToLatest.containsKey(amk)) {
      return amkToLatest[amk]!;
    }

    final query = (messageBox.query(Message_.amkSessionId.equals(amk))
            ..order(Message_.dateCreated, flags: Order.descending))
          .build();
          query.limit = 1;

      final messages = query.find();
      query.close();
    
    String? guid;
    if (messages.isNotEmpty) {
      guid = messages[0].stagingGuid ?? messages[0].guid;
    }
    amkToLatest[amk] = guid;
    return guid;
  }

  bool isAppSupported(int app) {
    return cachedStatus.any((a) => a.appId == app);
  }

  String getExtensionBundle(int app) {
    return cachedStatus.firstWhere((a) => a.appId == app).madridBundleId;
  }

  void engageApp(Message data) async {
    var app = data.payloadData!.appData!.first.appId!;
    var myId = cachedStatus.firstWhereOrNull((a) => a.appId == app);
    if (myId == null) return;

    if (myId.available == null) {
      // redirect to store
      launchUrl(Uri.parse(myId.store));
    }

    var payload = data.payloadData!.appData![0];
    var myMap = payload.toNative(null);
    myMap["messageGuid"] = data.guid;
    await mcs.invokeMethod("extension-template-tap", myMap);
  }

  Future<void> refreshCache() async {
    print("Refreshing extension state");
    var result = await mcs.invokeMethod("extension-status");
    if (result == null) return;
    List<dynamic> parsed = json.decode(result);
    cachedStatus = parsed.map((item) => App.fromMap(item)).toList();
    print("Extension state refreshed");
  }

  Future<void> updateMessage(Map<String, dynamic> args) async {
    var app = cachedStatus.firstWhere((a) => a.appId == args["appId"]);
    var payload = PayloadData(
      type: constants.PayloadType.app,
      appData: [
        iMessageAppData.fromNative(args, app)
      ],
    );

    var old = Message.findOne(guid: args["messageGuid"])!;

    var message = await backend.updateMessage(old.chat.target!, old, payload);
    inq.queue(IncomingItem(
      chat: old.chat.target!,
      message: message,
      type: QueueType.newMessage
    ));
  }

  Future<void> informUpdate(Message message) async {
    var payload = message.payloadData!.appData![0];
    var myMap = payload.toNative(null);
    myMap["messageGuid"] = message.guid;
    await mcs.invokeMethod("message-update-handler", myMap);
  }

  void addMessage(Map<String, dynamic> args) {
    var app = cachedStatus.firstWhere((a) => a.appId == args["appId"]);

    var payload = PayloadData(
      type: constants.PayloadType.app,
      appData: [
        iMessageAppData.fromNative(args, app)
      ],
    );

    PlatformFile? file;
    if (args["imageBase64"] != null) {
      var decoded = base64Decode(args["imageBase64"]);
      file = PlatformFile(
        name: "jpeg-image.jpeg",
        size: decoded.length,
        bytes: decoded,
      );
    }

    cm.activeChat!.controller!.pickedApp.value = (file, payload);
    print("set");
  }
}