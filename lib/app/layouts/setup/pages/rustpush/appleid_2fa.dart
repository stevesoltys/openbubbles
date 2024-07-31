import 'dart:async';

import 'package:bluebubbles/app/layouts/settings/dialogs/custom_headers_dialog.dart';
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

class AppleId2FA extends StatefulWidget {
  @override
  State<AppleId2FA> createState() => _AppleId2FAState();
}

class _AppleId2FAState extends OptimizedState<AppleId2FA> {
  final TextEditingController codeController = TextEditingController();
  final controller = Get.find<SetupViewController>();
  final FocusNode focusNode = FocusNode();
  String currentCode = "";
  String submittedCode = "";

  bool obscureText = true;
  bool loading = false;
  bool appleHelping = false;

  @override
  void initState() {
    super.initState();

    // Start listening to changes.
    codeController.addListener(() {
      setState(() {
        currentCode = codeController.text;
      });
      if (codeController.text.length == 6 && submittedCode != codeController.text) {
        submittedCode = codeController.text;
        connect(codeController.text);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: "2fa Code",
      subtitle: "Enter the code sent to your ${controller.isSms.value ? "phone" : "Apple devices"}",
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
                            child: Stack(
                              children: [
                                Row(
                                  children: List.generate(6, (index) {
                                    var text = index < currentCode.length ? currentCode[index] : "";
                                    return Expanded(child: 
                                      Container(
                                        decoration: index == currentCode.length ? 
                                          BoxDecoration(
                                            border: Border.all(
                                              color: context.theme.colorScheme.primary,
                                              width: 2
                                            ),
                                            borderRadius: const BorderRadius.all(Radius.circular(10)),
                                          )
                                        : BoxDecoration(
                                          border: Border.all(
                                            color: context.theme.colorScheme.outline,
                                          ),
                                          borderRadius: const BorderRadius.all(Radius.circular(10)),
                                        ),
                                        margin: const EdgeInsets.all(3),
                                        height: 50,
                                        child: Center(
                                          child: Text(
                                            text,
                                            style: context.theme.textTheme.titleLarge
                                          ),
                                        )
                                      )
                                    );
                                  }),
                                ),
                                Opacity(
                                  opacity: 0,
                                  child: TextField(
                                    cursorColor: context.theme.colorScheme.primary,
                                    autocorrect: false,
                                    autofocus: controller.goingTo2fa, // if we're not going don't pop up the keyboard for a transitive state
                                    controller: codeController,
                                    textInputAction: TextInputAction.next,
                                    keyboardType: TextInputType.number,
                                  )),
                              ],
                            )
                          ),
                        ),
                        const SizedBox(height: 20),
                        TextButton(
                          onPressed: appleHelping ? null : () async {
                            appleHelp();
                          },
                          child: Text(
                            controller.isSms.value ? "Resend code" : "Can't access an Apple device?",
                            style: context.theme.textTheme.bodyLarge!.apply(fontSizeFactor: 1.1, color: appleHelping ? HexColor('777777') : HexColor('2772C3'))
                          )
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
                                  colors: loading ? [HexColor('777777'), HexColor('777777')] : [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
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
                                  connect(codeController.text);
                                },
                                onLongPress: () async {
                                  await showCustomHeadersDialog(context);
                                  connect(codeController.text);
                                },
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Opacity(opacity: loading ? 0 : 1, child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text("Sign In",
                                            style: context.theme.textTheme.bodyLarge!
                                                .apply(fontSizeFactor: 1.1, color: Colors.white)),
                                        const SizedBox(width: 10),
                                        const Icon(Icons.arrow_forward, color: Colors.white, size: 20),
                                      ],
                                    ),),
                                    if (loading)
                                    buildProgressIndicator(context, brightness: Brightness.dark),
                                  ],
                                )
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

  Future<void> appleHelp() async {
    setState(() {
      appleHelping = true;
    });
    await controller.updateLoginState(const api.DartLoginState.needsSms2Fa());
    setState(() {
      appleHelping = false;
    });
  }

  void goBack() {
    controller.twoFaUser = "";
    controller.twoFaPass = "";
    controller.pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> connect(String code) async {
    controller.updateConnectError("");
    setState(() {
      loading = true;
    });
    try {
      if (await controller.submitCode(code) is api.DartLoginState_LoggedIn) {
        if (controller.success) {
          controller.pageController.nextPage(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        } else {
          controller.pageController.previousPage(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        }
        FocusManager.instance.primaryFocus?.unfocus();
      }
    } catch (e) {
      if (e is AnyhowException) {
        controller.updateConnectError(e.message);
      }
      if (e is PanicException) {
        controller.updateConnectError(e.message);
      }
      rethrow;
    } finally {
      setState(() {
        loading = false;
      });
    }
  }
}