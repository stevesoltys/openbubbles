import 'dart:async';

import 'package:bluebubbles/app/layouts/settings/dialogs/custom_headers_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/app/layouts/setup/setup_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart' hide Response;
import 'package:url_launcher/url_launcher.dart';

class AppleIdLogin extends StatefulWidget {
  @override
  State<AppleIdLogin> createState() => _AppleIdLoginState();
}

class _AppleIdLoginState extends OptimizedState<AppleIdLogin> {
  final TextEditingController appleIdController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final controller = Get.find<SetupViewController>();
  final FocusNode focusNode = FocusNode();
  final FocusNode pwFocusNode = FocusNode();
  bool loading = false;

  bool obscureText = true;

  @override
  void initState() {
    super.initState();

    // Start listening to changes.
    appleIdController.addListener(() {
      setState(() { });
    });

    passwordController.addListener(() {
      setState(() { });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: "Login with your Apple ID",
      subtitle: "Start using OpenBubbles with your Apple ID",
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
                            child: TextField(
                              cursorColor: context.theme.colorScheme.primary,
                              autocorrect: false,
                              autofocus: true,
                              controller: appleIdController,
                              textInputAction: TextInputAction.next,
                              onEditingComplete: () {
                                FocusScope.of(context).requestFocus(pwFocusNode);
                              },
                              decoration: InputDecoration(
                                enabledBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.outline),
                                    borderRadius: BorderRadius.circular(20)),
                                focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.primary),
                                    borderRadius: BorderRadius.circular(20)),
                                labelText: "Apple ID",
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          width: context.width * 2 / 3,
                          child: Focus(
                            onKey: (node, event) {
                              if (event is RawKeyDownEvent &&
                                  event.data.isShiftPressed &&
                                  event.logicalKey == LogicalKeyboardKey.tab) {
                                node.previousFocus();
                                node.previousFocus(); // This is intentional. Should probably figure out why it's needed
                                return KeyEventResult.handled;
                              }
                              return KeyEventResult.ignored;
                            },
                            child: TextField(
                              cursorColor: context.theme.colorScheme.primary,
                              autocorrect: false,
                              autofocus: false,
                              controller: passwordController,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (pass) => connect(appleIdController.text, pass),
                              focusNode: pwFocusNode,
                              decoration: InputDecoration(
                                enabledBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.outline),
                                    borderRadius: BorderRadius.circular(20)),
                                focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.primary),
                                    borderRadius: BorderRadius.circular(20)),
                                labelText: "Password",
                                contentPadding: const EdgeInsets.fromLTRB(12, 24, 40, 16),
                                suffixIcon: IconButton(
                                  icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility),
                                  color: context.theme.colorScheme.outline,
                                  onPressed: () {
                                    setState(() {
                                      obscureText = !obscureText;
                                    });
                                  },
                                ),
                              ),
                              obscureText: obscureText,
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: () async {
                            var devInfo = await api.getDeviceInfoState(state: pushService.state);
                            await showDialog(
                              context: Get.context!,
                              builder: (context) => AlertDialog(
                                title: const Text('Create Apple ID'),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      "Visit icloud.com to create an Apple ID. You may need to contact Apple support if it won't let you..",
                                      style: Get.textTheme.bodyLarge,
                                    ),
                                    const SizedBox(height: 20),
                                    Align(
                                      alignment: Alignment.center,
                                      child: Text(
                                        "Warning: OpenBubbles is not an officially supported Apple product.\n\n${RustPushBBUtils.modelToUser(devInfo.name)}\nS/N: ${devInfo.serial}\nmacOS ${devInfo.osVersion}",
                                        textAlign: TextAlign.center,
                                        style: Get.textTheme.bodySmall,
                                      )
                                    ),
                                  ],
                                ),
                                actions: <Widget>[
                                  TextButton(
                                          onPressed: () => Get.back(),
                                          child: Text("Cancel", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary))),
                                  TextButton(
                                          onPressed: () async {
                                             await launchUrl(Uri.parse("https://getsupport.apple.com"), mode: LaunchMode.externalApplication);
                                          },
                                          child: Text("Get Support", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary))),
                                  TextButton(
                                          onPressed: () async {
                                             await launchUrl(Uri.parse("https://icloud.com"), mode: LaunchMode.externalApplication);
                                          },
                                          child: Text("Open", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary))),
                                ],
                              ),
                            );
                          },
                          child: Text(
                            "Create new Apple ID",
                            style: context.theme.textTheme.bodyLarge!.apply(fontSizeFactor: 1.1, color: HexColor('2772C3'))
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
                                  controller.pageController.previousPage(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeInOut,
                                  );
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
                            if ((appleIdController.text != "" && passwordController.text != "") || controller.currentPhoneUser == null)
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
                                  connect(appleIdController.text, passwordController.text);
                                },
                                onLongPress: () async {
                                  await showCustomHeadersDialog(context);
                                  connect(appleIdController.text, passwordController.text);
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
                            if (!((appleIdController.text != "" && passwordController.text != "") || controller.currentPhoneUser == null))
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(25),
                                gradient: LinearGradient(
                                  begin: AlignmentDirectional.topStart,
                                  colors: loading ? [HexColor('777777'), HexColor('777777')] : [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
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
                                  controller.updateConnectError("");
                                  setState(() {
                                    loading = true;
                                  });
                                  try {
                                    ss.settings.customHeaders.value = {};
                                    http.onInit();
                                    await controller.doRegister();
                                    if (!controller.success) {
                                      return;
                                    }
                                    controller.goingTo2fa = false;
                                    controller.pageController.animateToPage(
                                      controller.pageController.page!.toInt() + 2,
                                      duration: const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut,
                                    );
                                  } catch (e) {
                                    if (e is AnyhowException) {
                                      controller.updateConnectError(e.message);
                                    }
                                    rethrow;
                                  } finally {
                                    setState(() {
                                      loading = false;
                                    });
                                  }
                                },
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Opacity(opacity: loading ? 0 : 1, child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text("Skip",
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

  Future<void> connect(String appleId, String password) async {
    controller.updateConnectError("");
    setState(() {
      loading = true;
    });
    try {
      var (result, user) = await api.tryAuth(state: pushService.state, username: appleId, password: password);
      controller.currentAppleUser = user;
      result = await controller.updateLoginState(result);


      // if (result is api.DartLoginState_NeedsSMS2FA) {
      //   result = api.DartLoginState.needsSms2FaVerification(api.VerifyBody(

      //   ))
      // }
      // if (result is api.DartLoginState_NeedsDevice2FA) {
      //   result = const api.DartLoginState.needs2FaVerification();
      // }

      ss.settings.iCloudAccount.value = appleId;
      if (result is api.DartLoginState_Needs2FAVerification || result is api.DartLoginState_NeedsSMS2FAVerification) {
        // we need 2fa
        controller.goingTo2fa = true;
        controller.twoFaUser = appleId;
        controller.twoFaPass = password;
        controller.pageController.nextPage(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        return;
      }
      if (result is api.DartLoginState_LoggedIn) {
        if (!controller.success) {
          return;
        }
        controller.goingTo2fa = false;
        controller.pageController.animateToPage(
          controller.pageController.page!.toInt() + 2,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
        FocusManager.instance.primaryFocus?.unfocus();
      }
    } catch (e) {
      if (e is AnyhowException) {
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
