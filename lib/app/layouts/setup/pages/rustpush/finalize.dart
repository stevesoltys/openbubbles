import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/settings_dropdown.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/settings_switch.dart';
import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart' hide Response;
import 'package:telephony_plus/telephony_plus.dart';

class FinalizePage extends StatefulWidget {
  @override
  State<FinalizePage> createState() => _FinalizePageState();
}

class _FinalizePageState extends OptimizedState<FinalizePage> {
  final controller = Get.find<SetupViewController>();

  List<String> handles = [];

  @override
  void initState() {
    super.initState();
    api.getHandles(state: pushService.state).then((result) {
      setState(() {
        handles = result;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: "Done!",
      subtitle: "",
      customSubtitle: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "You can be reached on iMessage at",
              style: context.theme.textTheme.bodyLarge!.apply(
                fontSizeDelta: 1.5,
                color: context.theme.colorScheme.outline,
              ).copyWith(height: 2)
            ),
            ...handles.map((e) => Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                e.replaceFirst("tel:", "").replaceAll("mailto:", ""),
                style: context.theme.textTheme.titleMedium,
              ),
            )),
            if (!kIsDesktop && !controller.supportsPhoneReg.value)
            const Text(
              "Note: Phone numbers cannot be registered without an iOS device"
            ),
            SettingsOptions<String>(
              title: "Start Chats Using",
              initial: ss.settings.defaultHandle.value.replaceFirst("tel:", "").replaceAll("mailto:", ""),
              clampWidth: false,
              options: handles.map((handle) => handle.replaceFirst("tel:", "").replaceAll("mailto:", "")).toList(),
              secondaryColor: headerColor,
              useCupertino: false,
              textProcessing: (str) => ss.settings.redactedMode.value ? (GetUtils.isEmail(str) ? "Redacted Email" : "Redacted Phone") : str,
              capitalize: false,
              onChanged: (value) async {
                if (value == null) return;
                setState(() {});
                await backend.setDefaultHandle(value);
              },
            ),
            if (!kIsDesktop)
              Padding(padding: const EdgeInsets.symmetric(vertical: 5),
                child: Obx(() => SettingsSwitch(
                  padding: false,
                  onChanged: (bool val) async {
                    if (val) {
                      var granted = await TelephonyPlus().requestPermissions();
                      if (!granted) {
                        showSnackbar("SMS denied", "Please enable SMS permission in settings");
                        return;
                      }
                    }
                    setState(() {
                      ss.settings.isSmsRouter.value = val;
                      ss.saveSettings();
                    });
                  },
                  initialVal: ss.settings.isSmsRouter.value,
                  title: "Use SMS with this phone",
                  subtitle: "Use this phone with OpenBubbles and your other Apple devices",
                  backgroundColor: tileColor,
                  isThreeLine: true,
                )),
              ),
            if (ss.settings.isSmsRouter.value)
              const Padding(padding: EdgeInsets.symmetric(vertical: 5),
                child: Text(
                  "Enable SMS on other devices in settings.",
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
      customButton: Column(
        children: [
          ErrorText(parentController: controller),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            child: Theme(
                    data: context.theme.copyWith(
                      inputDecorationTheme: InputDecorationTheme(
                        labelStyle: TextStyle(color: context.theme.colorScheme.outline),
                      ),
                    ),
                    child: Column(
                      children: [
                        if (ss.settings.macIsMine.value)
                          const Padding(padding: EdgeInsets.symmetric(vertical: 5),
                            child: Text(
                              "You can manage your hardware identifiers in settings.",
                              textAlign: TextAlign.center,
                            ),
                          ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(25),
                                gradient: LinearGradient(
                                  begin: AlignmentDirectional.topStart,
                                  colors: [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
                                ),
                              ),
                              height: 40,
                              child: ElevatedButton(
                                style: ButtonStyle(
                                  shape: MaterialStateProperty.all<RoundedRectangleBorder>(
                                    RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20.0),
                                    ),
                                  ),
                                  backgroundColor: MaterialStateProperty.all(Colors.transparent),
                                  shadowColor: MaterialStateProperty.all(Colors.transparent),
                                  maximumSize: MaterialStateProperty.all(const Size(200, 36)),
                                  minimumSize: MaterialStateProperty.all(const Size(30, 30)),
                                ),
                                onPressed: () async {
                                  connect();
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text("Done",
                                        style: context.theme.textTheme.bodyLarge!
                                            .apply(fontSizeFactor: 1.1, color: Colors.white)),
                                    const SizedBox(width: 10),
                                    const Icon(Icons.check, color: Colors.white, size: 20),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> connect() async {
    Get.offAll(() => ConversationList(
        showArchivedChats: false,
        showUnknownSenders: false,
      ),
      routeName: "",
      duration: Duration.zero,
      transition: Transition.noTransition
    );
    Get.delete<SetupViewController>(force: true);
  }

}