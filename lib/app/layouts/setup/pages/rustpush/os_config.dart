import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/settings/dialogs/custom_headers_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/failed_to_scan_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/app/layouts/setup/pages/sync/qr_code_scanner.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart' hide Response;
import 'package:permission_handler/permission_handler.dart';
import 'package:dio/dio.dart';

class OsConfig extends StatefulWidget {
  @override
  State<OsConfig> createState() => _OsConfigState();
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

class _OsConfigState extends OptimizedState<OsConfig> {
  final TextEditingController idsController = TextEditingController();
  final controller = Get.find<SetupViewController>();
  final FocusNode focusNode = FocusNode();

  bool obscureText = true;

  Future<void> scanQRCode() async {
    // Make sure we have the correct permissions
    PermissionStatus status = await Permission.camera.status;
    if (!status.isPermanentlyDenied && !status.isGranted) {
      final result = await Permission.camera.request();
      if (!result.isGranted) {
        showSnackbar("Error", "Camera permission required for QR scanning!");
        return;
      }
    } else if (status.isPermanentlyDenied) {
      showSnackbar("Error", "Camera permission permanently denied, please modify permissions from Android settings.");
      return;
    }

    // Open the QR Scanner and get the result
    try {
      final String? response = await Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (BuildContext context) {
            return QRCodeScanner();
          },
        ),
      );
      if (response == null) {
        return;
      }
      if (response.startsWith("OABS")) {
        var shared = response.codeUnits[4];
        var rawData = response.codeUnits.toList();
        rawData.removeRange(0, 5);
        
        var parsed = await api.configFromEncoded(encoded: rawData);
        controller.preparedMine = shared == 0;
        controller.prepareStaging = parsed;
        controller.asking = null;
        controller.pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      } else { throw Exception("Bad data!"); }
      
    } catch (e) {
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return FailedToScanDialog(title: "Error", exception: e.toString());
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    var options = [
      (
        icon: Icons.arrow_forward,
        text: "Mac Validation Data",
        call: () {
          controller.hardwareMode = 0;
          controller.asking = "Validation Data";
          controller.usingBeeper = false;
          controller.pageController.nextPage(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      ),
      (
        icon: Icons.arrow_forward,
        text: "Scan code",
        call: () {
          controller.usingBeeper = false;
          scanQRCode();
        }
      ),
      (
        icon: Icons.arrow_forward,
        text: "Input Code",
        call: () {
          controller.hardwareMode = 2;
          controller.asking = "Input Code";
          controller.usingBeeper = false;
          controller.pageController.nextPage(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
      ),
      (
        icon: Icons.arrow_forward,
        text: "Beeper Registration Code",
        call: () {
          final TextEditingController codeInput = TextEditingController();
          showDialog(
            context: context,
            builder: (_) {
              return AlertDialog(
                actions: [
                  TextButton(
                    child: Text("Cancel",
                        style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                    onPressed: () => Get.back(),
                  ),
                  TextButton(
                    child: Text("OK",
                        style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                    onPressed: () async {
                      if (codeInput.text.isEmpty) {
                        showSnackbar("Error", "Enter a valid code!");
                        return;
                      }
                      Get.back();
                      try {
                        showSnackbar("Fetching validation data", "This might take a minute");
                        final response = await http.dio.post(
                          "https://registration-relay.beeper.com/api/v1/bridge/get-validation-data",
                          data: {},
                          options: Options(
                            headers: {
                              // not a secret; burner account
                              "X-Beeper-Access-Token": "5c175851953ecaf5209185d897591badb6c3e712",
                              "Authorization": "Bearer ${codeInput.text}",
                            },
                          )
                        );

                        if (response.statusCode == 404) {
                          showSnackbar("Fetching validation data", "Mac Offline");
                          return;
                        }

                        final response2 = await http.dio.post(
                          "https://registration-relay.beeper.com/api/v1/bridge/get-version-info",
                          data: {},
                          options: Options(
                            headers: {
                              // not a secret; burner account
                              "X-Beeper-Access-Token": "5c175851953ecaf5209185d897591badb6c3e712",
                              "Authorization": "Bearer ${codeInput.text}",
                            },
                          )
                        );

                        var parsed = await api.configFromValidationData(data: base64Decode(response.data["data"]), extra: api.DartHwExtra(
                          version: response2.data["versions"]["software_version"],
                          protocolVersion: 1660,
                          deviceId: response2.data["versions"]["unique_device_id"],
                          icloudUa: "com.apple.iCloudHelper/282 CFNetwork/1408.0.4 Darwin/22.5.0",
                          aoskitVersion: "com.apple.AOSKit/282 (com.apple.accountsd/113)"
                        ));
                        showSnackbar("Fetching validation data", "Done");
                        controller.preparedMine = true;
                        controller.usingBeeper = true;
                        controller.prepareStaging = parsed;
                        controller.asking = null;
                        controller.pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      } catch (e) {
                        showSnackbar("Fetching validation data", "Failed");
                        rethrow;
                      }
                    },
                  ),
                ],
                content: TextField(
                  controller: codeInput,
                  decoration: const InputDecoration(
                    labelText: "Code",
                    border: OutlineInputBorder(),
                  ),
                  inputFormatters: [UpperCaseTextFormatter()],
                ),
                title: Text("Enter Registration Code", style: context.theme.textTheme.titleLarge),
                backgroundColor: context.theme.colorScheme.properSurface,
              );
            }
          );
        }
      )
    ];
    return SetupPageTemplate(
      title: "Hardware info",
      subtitle: "To authenticate with iMessage, Apple requires hardware identifiers. If you have a Mac, download and run the QR code generator. If you don't, ask a friend who does to share their code with you. The Mac does not need to remain online. How do you want to authenticate?",
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
                        const SizedBox(height: 20),
                        Container(
                          width: context.width * 5 / 6,
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
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: options.map((opt) =>
                                Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(13),
                                    gradient: LinearGradient(
                                      begin: AlignmentDirectional.topStart,
                                      colors: [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
                                    ),
                                  ),
                                  margin: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                                  height: 50,
                                  child: ElevatedButton(
                                    style: ButtonStyle(
                                      shape: MaterialStateProperty.all<RoundedRectangleBorder>(
                                        RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(13.0),
                                        ),
                                      ),
                                      backgroundColor: MaterialStateProperty.all(Colors.transparent),
                                      shadowColor: MaterialStateProperty.all(Colors.transparent),
                                    ),
                                    onPressed: opt.call,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(opt.text,
                                            style: context.theme.textTheme.bodyMedium!
                                                .apply(fontSizeFactor: 1.1, color: Colors.white, fontWeightDelta: 1)),
                                        if (opt.icon != null)
                                          const SizedBox(width: 10),
                                        if (opt.icon != null)
                                          Icon(opt.icon, color: Colors.white, size: 20),
                                      ],
                                    ),
                                  ),
                                )
                              ).toList(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.start,
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
                                  await goBack();
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.close, color: context.theme.colorScheme.onBackground, size: 20),
                                    const SizedBox(width: 10),
                                    Text("Cancel",
                                        style: context.theme.textTheme.bodyLarge!
                                            .apply(fontSizeFactor: 1.1, color: context.theme.colorScheme.onBackground)),
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

  Future<void> goBack() async {
    controller.pageController.animateToPage(
      (controller.pageController.page! - 1).toInt(),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }
}