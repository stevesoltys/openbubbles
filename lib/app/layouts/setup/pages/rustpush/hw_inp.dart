import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/settings/dialogs/custom_headers_dialog.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/layout/settings_section.dart';
import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart' hide Response;
import 'package:url_launcher/url_launcher.dart';

class HwInp extends StatefulWidget {
  @override
  State<HwInp> createState() => _HwInpState();
}

class _HwInpState extends OptimizedState<HwInp> {
  final TextEditingController codeController = TextEditingController();
  final controller = Get.find<SetupViewController>();
  final FocusNode focusNode = FocusNode();

  bool loading = false;

  bool stagingMine = true;
  api.MacOsConfig? staging;
  api.DartDeviceInfo? stagingInfo;
  String deviceName = "";

  void select(api.MacOsConfig parsed, bool mine) async {
    var info = await api.getDeviceInfo(config: parsed);
    setState(() {
      if (staging == null) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
      staging = parsed;
      stagingMine = mine;
      stagingInfo = info;
      deviceName = RustPushBBUtils.modelToUser(stagingInfo!.name);
    });
  }

  @override
  void initState() {
    super.initState();

    if (controller.asking == null) {
      select(controller.prepareStaging!, controller.preparedMine);
    }

    // Start listening to changes.
    codeController.addListener(() async {
      try {
        var data = base64Decode(codeController.text);
        if (controller.hardwareMode == 0) {
          if (data.length == 517) {
            var parsed = await api.configFromValidationData(data: data, extra: api.DartHwExtra(
              version: "13.6.4",
              protocolVersion: 1660,
              deviceId: uuid.v4(),
              icloudUa: "com.apple.iCloudHelper/282 CFNetwork/1408.0.4 Darwin/22.5.0",
              aoskitVersion: "com.apple.AOSKit/282 (com.apple.accountsd/113)"
            ));
            select(parsed, true);
          } else { print("resettingb"); setState(() => staging = stagingInfo = null); }
        } else if (controller.hardwareMode == 2) {
          // magic header
          if (String.fromCharCodes(data).startsWith("OABS")) {
            var shared = data[4];
            var rawData = data.toList();
            rawData.removeRange(0, 5);
            
            var parsed = await api.configFromEncoded(encoded: rawData);
            select(parsed, shared == 0);
          } else { print("resettingb"); setState(() => staging = stagingInfo = null); }
        }
      } catch (e) {
        print("resettinga");
        setState(() => staging = stagingInfo = null);
        rethrow;
      }
    });
  }


  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: staging == null ? "${controller.asking}" : stagingMine ? "My Mac" : "Shared Mac",
      subtitle: "",
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
                        if(stagingInfo != null)
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
                                    Text(stagingInfo?.serial ?? ""),
                                    const SizedBox(height: 10),
                                    Text(stagingInfo?.osVersion ?? ""),
                                    const SizedBox(height: 25),
                                  ],
                                )
                              ),
                            ],
                          ),
                        if (controller.usingBeeper)
                        Container(
                          child: Text(
                            "If you no longer need Beeper, you can safely turn off or disconnect your Mac now. We'll handle it from here.",
                            style: context.theme.textTheme.bodyMedium,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (controller.asking != null)
                        const SizedBox(height: 20),
                        if (controller.asking != null)
                        Container(
                          width: context.width * 2 / 3,
                          child: Focus(
                            focusNode: focusNode,
                            onKey: (node, event) {
                              if (event is RawKeyDownEvent &&
                                  !event.data.isShiftPressed &&
                                  event.logicalKey == LogicalKeyboardKey.tab) {
                                node.nextFocus();
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: TextField(
                              cursorColor: context.theme.colorScheme.primary,
                              autocorrect: false,
                              autofocus: false,
                              controller: codeController,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                enabledBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.outline),
                                    borderRadius: BorderRadius.circular(20)),
                                focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.primary),
                                    borderRadius: BorderRadius.circular(20)),
                                labelText: controller.asking,
                              ),
                            ),
                          ),
                        ),
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
                                onPressed: loading ? null : () async {
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
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(25),
                                gradient: LinearGradient(
                                  begin: AlignmentDirectional.topStart,
                                  colors: staging == null || loading ? [HexColor('777777'), HexColor('777777')] : [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
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
                                onPressed: loading ? null : () async {
                                  ss.settings.customHeaders.value = {};
                                  http.onInit();
                                  connect(staging!);
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(staging == null ? "Continue" : "Use this Mac",
                                        style: context.theme.textTheme.bodyLarge!
                                            .apply(fontSizeFactor: 1.1, color: Colors.white)),
                                    const SizedBox(width: 10),
                                    const Icon(Icons.arrow_forward, color: Colors.white, size: 20),
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

  void goBack() {
    controller.twoFaUser = "";
    controller.twoFaPass = "";
    controller.pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> connect(api.MacOsConfig config) async {
    setState(() {
      loading = true;
    });
    try {
      ss.settings.macIsMine.value = stagingMine;
      ss.settings.save();
      await api.configureMacos(state: pushService.state, config: config);
      controller.pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } finally {
      setState(() {
        loading = false;
      });
    }
    // var response = await api.registerIds(state: pushService.state, validationData: validationData);
    // if (response != 0) {
    //   controller.updateConnectError("Error registering with IDS: $response");
    //   return;
    // }
    // await pushService.configured();
    // await setup.finishSetup();
    // Get.offAll(() => ConversationList(
    //     showArchivedChats: false,
    //     showUnknownSenders: false,
    //   ),
    //   routeName: "",
    //   duration: Duration.zero,
    //   transition: Transition.noTransition
    // );
    // Get.delete<SetupViewController>(force: true);
  }

}