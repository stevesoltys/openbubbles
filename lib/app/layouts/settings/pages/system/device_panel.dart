import 'dart:convert';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/utils/share.dart';
import 'package:bluebubbles/utils/window_effects.dart';
import 'package:bluebubbles/utils/logger.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/avatar/custom_avatar_color_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/avatar/custom_avatar_panel.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/advanced/advanced_theming_panel.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:get/get.dart' hide Response;
import 'package:idb_shim/idb.dart';
import 'package:universal_io/io.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:convert/convert.dart';

class DevicePanelController extends StatefulController {

  final RxBool allowSharing = true.obs;
}

class DevicePanel extends CustomStateful<DevicePanelController> {
  DevicePanel() : super(parentController: Get.put(DevicePanelController()));

  @override
  State<StatefulWidget> createState() => _DevicePanelState();
}

class _DevicePanelState extends CustomState<DevicePanel, void, DevicePanelController> {

  api.DartDeviceInfo? deviceInfo;
  String deviceName = "";

  @override
  void initState() {
    super.initState();
    api.getDeviceInfoState(state: pushService.state).then((value) {
      setState(() {
        deviceInfo = value;
        deviceName = RustPushBBUtils.modelToUser(deviceInfo!.name);
      });
    });
  }

  String getQrInfo(bool allowSharing, Uint8List data) {
    var b = BytesBuilder();
    b.addByte(allowSharing ? 0 : 1);
    b.add(data);
    for (var slice in b.toBytes().slices(500)) {
      print(hex.encode(slice));
    }
    return "OABS${String.fromCharCodes(b.toBytes())}";
  }

  @override
  Widget build(BuildContext context) {
    Widget nextIcon = Obx(() => ss.settings.skin.value != Skins.Material ? Icon(
      ss.settings.skin.value != Skins.Material ? CupertinoIcons.chevron_right : Icons.arrow_forward,
      color: context.theme.colorScheme.outline,
      size: iOS ? 18 : 24,
    ) : const SizedBox.shrink());

    return Obx(
      () => SettingsScaffold(
        title: "${ss.settings.macIsMine.value ? 'My' : 'Shared'} Mac",
        initialHeader: null,
        iosSubtitle: iosSubtitle,
        materialSubtitle: materialSubtitle,
        tileColor: tileColor,
        headerColor: headerColor,
        bodySlivers: [
          SliverList(
            delegate: SliverChildListDelegate(
              <Widget>[
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    Center(
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(25),
                            child: Icon(
                              RustPushBBUtils.isLaptop(deviceName) ? CupertinoIcons.device_laptop : CupertinoIcons.device_desktop,
                              size: 200,
                              color: context.theme.colorScheme.properOnSurface,
                            ),
                          ),
                          Text(deviceName, style: context.theme.textTheme.titleLarge),
                          const SizedBox(height: 10),
                          Text(deviceInfo?.serial ?? ""),
                          const SizedBox(height: 10),
                          Text(deviceInfo?.osVersion ?? ""),
                          const SizedBox(height: 25),
                        ],
                      )
                    ),
                  ],
                ),
                if (ss.settings.macIsMine.value)
                SettingsHeader(
                    iosSubtitle: iosSubtitle,
                    materialSubtitle: materialSubtitle,
                    text: "Share Mac"),
                if (ss.settings.macIsMine.value)
                SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    Obx(() => SettingsSwitch(
                      onChanged: (bool val) {
                        controller.allowSharing.value = !val;
                      },
                      initialVal: !controller.allowSharing.value,
                      title: "Prevent sharing",
                      backgroundColor: tileColor,
                      subtitle: "Prevent further sharing of these identifiers. Apple can become suspicious after over 20 users use one Mac.",
                      isThreeLine: true,
                    )),
                    if (deviceInfo != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(15, 0, 15, 0),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: QrImageView(
                          data: getQrInfo(controller.allowSharing.value, deviceInfo!.encodedData),
                          version: QrVersions.auto,
                          gapless: true,
                          backgroundColor: context.theme.colorScheme.properSurface,
                          eyeStyle: QrEyeStyle(color: context.theme.colorScheme.properOnSurface),
                          dataModuleStyle: QrDataModuleStyle(color: context.theme.colorScheme.properOnSurface),
                        ),
                      )),
                    if (kIsDesktop)
                    SettingsTile(
                      backgroundColor: tileColor,
                      title: "Copy Activation Code",
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: base64Encode(getQrInfo(controller.allowSharing.value, deviceInfo!.encodedData).codeUnits)));
                      },
                      subtitle: controller.allowSharing.value ? "" : "Make sure you delete your code after activation to prevent sharing.",
                      trailing: Icon(
                        ss.settings.skin.value == Skins.iOS ? CupertinoIcons.doc_on_clipboard : Icons.copy
                      ),
                    ),
                    if (!kIsDesktop)
                    SettingsTile(
                      backgroundColor: tileColor,
                      title: "Share Activation Code",
                      onTap: () {
                        var code = base64Encode(getQrInfo(controller.allowSharing.value, deviceInfo!.encodedData).codeUnits);
                        Share.text("BlueBubbles", "Text me on BlueBubbles with my activation code! $code");
                      },
                      subtitle: controller.allowSharing.value ? null : "Make sure you delete your code after activation to prevent sharing.",
                      trailing: Icon(
                        ss.settings.skin.value == Skins.iOS ? CupertinoIcons.share : Icons.share
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void saveSettings() {
    ss.saveSettings();
  }
}
