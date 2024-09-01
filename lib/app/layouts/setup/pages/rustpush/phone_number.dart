import 'dart:async';
import 'dart:convert';

import 'package:async_task/async_task_extension.dart';
import 'package:bluebubbles/app/layouts/settings/dialogs/custom_headers_dialog.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/settings_leading_icon.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/settings_switch.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/settings_tile.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/layout/settings_section.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/failed_to_scan_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/app/layouts/setup/pages/sync/qr_code_scanner.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/crypto_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart' hide Response;
import 'package:permission_handler/permission_handler.dart';
import 'package:telephony_plus/telephony_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:convert/convert.dart';
import 'package:app_links/app_links.dart';

class PhoneNumber extends StatefulWidget {
  @override
  State<PhoneNumber> createState() => PhoneNumberState();

  const PhoneNumber({super.key});
}

class PhoneNumberState extends OptimizedState<PhoneNumber> {
  final TextEditingController codeController = TextEditingController();
  final controller = Get.find<SetupViewController>();
  final FocusNode focusNode = FocusNode();

  final RxBool failed = false.obs;

  @override
  void initState() {
    super.initState();
    
    subscribe();
  }

  void subscribe() async {
    try {
      await mcs.invokeMethod("sim-info-query", {"subscribe": true});
      failed.value = false;
    } catch (e) {
      failed.value = true;
      rethrow;
    }
  }

  @override
  void dispose() {
    super.dispose();
    
    mcs.invokeMethod("sim-info-query", {"subscribe": false});
  }

  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: "Phone Number",
      subtitle: "Use your phone number with iMessage. Requires SMS permission to receive the silent confirmation code.",
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
                    child: Obx(() => Column(
                      children: [
                        if (failed.value)
                        SettingsTile(
                          title: "Load SIMs",
                          leading: const Icon(Icons.sim_card),
                          onTap: () async {
                            try {
                              await Permission.phone.request();
                            } catch (e) {
                              showSnackbar("Failed", "Enable phone permissions in settings");
                              rethrow;
                            }
                            subscribe();
                          }),
                        if (!failed.value)
                        ...mcs.simInfo.map((sim) => SettingsSwitch(
                            padding: false,
                            onChanged: (bool val) async {
                              if (controller.phoneValidating.value) return;
                              int subscription = sim["subscription"];
                              if (val) {
                                if (ss.settings.cachedCodes.containsKey("sms-auth-$subscription")) {
                                  controller.currentPhoneUsers[subscription] = await api.restoreUser(user: ss.settings.cachedCodes["sms-auth-$subscription"]!);
                                  controller.updateConnectError("");
                                  setState(() { });
                                  return;
                                }
                                controller.phoneValidating.value = true;
                                try {
                                  var granted = await TelephonyPlus().requestPermissions();
                                  if (!granted) {
                                    showSnackbar("SMS denied", "Please enable SMS permission in settings");
                                    return;
                                  }
                                  var token = await api.getToken(state: pushService.state);

                                  String resp = await mcs.invokeMethod("sms-auth-gateway", {'token': hex.encode(token).toUpperCase(), 'subscription': subscription});
                                  controller.currentPhoneUsers[subscription] = await api.authPhone(state: pushService.state, number: resp.split("|").first, sig: hex.decode(resp.split("|").last));
                                  ss.settings.cachedCodes["sms-auth-$subscription"] = await api.saveUser(user: controller.currentPhoneUsers[subscription]!);
                                  ss.saveSettings();
                                  controller.updateConnectError("");
                                  setState(() { });
                                } catch(e) {
                                  if (e is PlatformException) {
                                    var msg = e.code;
                                    controller.updateConnectError(msg);
                                  }
                                  rethrow;
                                } finally {
                                  controller.phoneValidating.value = false;
                                }
                              } else {
                                controller.currentPhoneUsers.remove(subscription);
                                setState(() { });
                              }
                            },
                            initialVal: controller.currentPhoneUsers.containsKey(sim["subscription"]),
                            title: sim["carrier"],
                            subtitle: "Use this phone number with OpenBubbles and your other Apple devices",
                            backgroundColor: tileColor,
                            isThreeLine: true,
                          )),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                              padding: const EdgeInsets.all(2),
                              child: ElevatedButton(
                                style: ButtonStyle(
                                  shape: MaterialStateProperty.all<RoundedRectangleBorder>(
                                    RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20.0),
                                    ),
                                  ),
                                  backgroundColor: MaterialStateProperty.all(context.theme.colorScheme.background),
                                  shadowColor: MaterialStateProperty.all(context.theme.colorScheme.background),
                                  maximumSize: MaterialStateProperty.all(const Size(200, 36)),
                                  minimumSize: MaterialStateProperty.all(const Size(30, 30)),
                                ),
                                onPressed: () async {
                                  goBack();
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.arrow_back, color: context.theme.colorScheme.onBackground, size: 20),
                                    const SizedBox(width: 10),
                                    Text("Back",
                                        style: context.theme.textTheme.bodyLarge!
                                            .apply(fontSizeFactor: 1.1, color: context.theme.colorScheme.onBackground)),
                                  ],
                                ),
                              ),
                            ),
                            Obx(() => Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(25),
                                gradient: LinearGradient(
                                  begin: AlignmentDirectional.topStart,
                                  colors: controller.phoneValidating.value ? [HexColor('777777'), HexColor('777777')] : [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
                                ),
                              ),
                              height: 40,
                              padding: const EdgeInsets.all(2),
                              child: ElevatedButton(
                                style: ButtonStyle(
                                  shape: MaterialStateProperty.all<RoundedRectangleBorder>(
                                    RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20.0),
                                    ),
                                  ),
                                  backgroundColor: MaterialStateProperty.all(controller.currentPhoneUsers.isNotEmpty || controller.phoneValidating.value ? Colors.transparent : context.theme.colorScheme.background),
                                  shadowColor: MaterialStateProperty.all(controller.currentPhoneUsers.isNotEmpty || controller.phoneValidating.value ? Colors.transparent : context.theme.colorScheme.background),
                                  maximumSize: MaterialStateProperty.all(const Size(200, 36)),
                                  minimumSize: MaterialStateProperty.all(const Size(30, 30)),
                                ),
                                onPressed: controller.phoneValidating.value ? null : () async {
                                  controller.pageController.nextPage(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                  );
                                },
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Opacity(opacity: controller.phoneValidating.value ? 0 : 1, child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(controller.currentPhoneUsers.isNotEmpty ? "Continue" : "Skip",
                                            style: context.theme.textTheme.bodyLarge!
                                                .apply(fontSizeFactor: 1.1, color: controller.currentPhoneUsers.isNotEmpty ? Colors.white : context.theme.colorScheme.onBackground)),
                                        const SizedBox(width: 10),
                                        Icon(Icons.arrow_forward, color: controller.currentPhoneUsers.isNotEmpty ? Colors.white : context.theme.colorScheme.onBackground, size: 20),
                                      ],
                                    ),),
                                    if (controller.phoneValidating.value)
                                    buildProgressIndicator(context, brightness: Brightness.dark),
                                  ],
                                )
                              ),
                            ),),
                          ],
                        ),
                      ],
                    )),
                  ),
          ),
        ],
      ),
    );
  }

  void goBack() {
    FocusManager.instance.primaryFocus?.unfocus();
    controller.pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

}