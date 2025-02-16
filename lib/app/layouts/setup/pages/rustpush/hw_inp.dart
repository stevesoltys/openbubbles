import 'dart:async';
import 'dart:convert';

import 'package:async_task/async_task_extension.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/settings/dialogs/custom_headers_dialog.dart';
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
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart' hide Response;
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:convert/convert.dart';
import 'package:app_links/app_links.dart';

class HwInp extends StatefulWidget {
  @override
  State<HwInp> createState() => HwInpState();

  const HwInp({super.key});
}

class HwInpState extends OptimizedState<HwInp> {
  final TextEditingController codeController = TextEditingController();
  final controller = Get.find<SetupViewController>();
  final FocusNode focusNode = FocusNode();

  bool loading = false;
  bool hosted = true;

  bool stagingMine = true;
  api.JoinedOsConfig? staging;
  api.DeviceInfo? stagingInfo;
  String deviceName = "";


  bool stagingNonInp = false;
  bool alreadyActivated = false;
  bool usingBeeper = false;


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
      final Uint8List? response = await Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (BuildContext context) {
            return QRCodeScanner();
          },
        ),
      );
      if (response == null) {
        return;
      }
      if (utf8.decode(response.sublist(0, 4)) == "OABS") {
        var shared = response[4];
        var cpy = response.toList();
        cpy.removeRange(0, 5);
        
        var parsed = await api.configFromEncoded(encoded: cpy);
        stagingNonInp = true;
        select(parsed, shared == 0);
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

  void select(api.JoinedOsConfig parsed, bool mine) async {
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

  String lastCheckedCode = "";

  Future<void> handleBeeper(String code) async {
    if (code == lastCheckedCode) return;
    lastCheckedCode = code;
    try {
      if (staging == null) {
        FocusManager.instance.primaryFocus?.unfocus();
      }
      showSnackbar("Fetching validation data", "This might take a minute");
      final response2 = await http.dio.post(
        "https://registration-relay.beeper.com/api/v1/bridge/get-version-info",
        data: {},
        options: Options(
          headers: {
            // not a secret; burner account
            "X-Beeper-Access-Token": "5c175851953ecaf5209185d897591badb6c3e712",
            "Authorization": "Bearer $code",
          },
        )
      );

      api.JoinedOsConfig parsed;
      if (response2.data["versions"]["software_name"] == "iPhone OS") {
        Logger.debug("Using as iOS");
        parsed = await api.configFromRelay(code: code, host: "https://registration-relay.beeper.com", token: "5c175851953ecaf5209185d897591badb6c3e712");
        usingBeeper = false;
      } else {
        final response = await http.dio.post(
          "https://registration-relay.beeper.com/api/v1/bridge/get-validation-data",
          data: {},
          options: Options(
            headers: {
              // not a secret; burner account
              "X-Beeper-Access-Token": "5c175851953ecaf5209185d897591badb6c3e712",
              "Authorization": "Bearer $code",
            },
          )
        );

        if (response.statusCode == 404) {
          showSnackbar("Fetching validation data", "Mac Offline");
          return;
        }
        parsed = await api.configFromValidationData(data: base64Decode(response.data["data"]), extra: api.HwExtra(
          version: response2.data["versions"]["software_version"],
          protocolVersion: 1660,
          deviceId: response2.data["versions"]["unique_device_id"],
          icloudUa: "com.apple.iCloudHelper/282 CFNetwork/1408.0.4 Darwin/22.5.0",
          aoskitVersion: "com.apple.AOSKit/282 (com.apple.accountsd/113)"
        ));
        usingBeeper = true;
      }
      showSnackbar("Fetching validation data", "Done");
      stagingNonInp = true;
      select(parsed, true);
    } catch (e) {
      showSnackbar("Fetching validation data", "Failed");
      rethrow;
    }
  }

  Future<void> handleCode(Uint8List data) async {
    if (String.fromCharCodes(data).startsWith("OABS")) {
      var shared = data[4];
      var rawData = data.toList();
      rawData.removeRange(0, 5);
      
      var parsed = await api.configFromEncoded(encoded: rawData);
      stagingNonInp = true;
      select(parsed, shared == 0);
    } else {
      showSnackbar("Fetching data", "Invalid format!");
    }
  }

  Future<void> handleOpenAbsinthe(String code) async {
    if (code == lastCheckedCode) return;
    lastCheckedCode = code;

    if (ss.settings.cachedCodes.containsKey(code)) {
      return handleCode(base64Decode(ss.settings.cachedCodes[code]!));
    }

    
    String hash = hex.encode(sha256.convert(code.codeUnits).bytes);

    try {
      var timer = Timer(const Duration(milliseconds: 500), () {
        showSnackbar("Fetching data", "This might take a minute");
      });
      final response = await http.dio.get(
        "$rpApiRoot/$hash",
        options: Options(
          headers: {
            "X-OpenBubbles-Get": ""
          },
        )
      );
      timer.cancel();

      if (response.statusCode == 404) {
        showSnackbar("Fetching data", "Invalid code");
        return;
      }

      var data = response.data["data"];
      
      var myData = Uint8List.fromList(decryptAESCryptoJS(data, code));
      ss.settings.cachedCodes[code] = base64Encode(myData);
      ss.saveSettings();

      handleCode(myData);
    } catch (e) {
      showSnackbar("Fetching data", "Failed");
      rethrow;
    }
  }

  Future<void> checkCode(String text) async {
    Logger.debug("Here $text");
    if (text == "testing-please-letmein") {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() {
        loading = true;
      });
      controller.updateConnectError("");
      try {
        await api.configureAppReview(state: pushService.state);
        ss.settings.cachedCodes.clear();
        await pushService.configured();
        await setup.finishSetup();
        Get.offAll(() => ConversationList(
            showArchivedChats: false,
            showUnknownSenders: false,
          ),
          routeName: "",
          duration: Duration.zero,
          transition: Transition.noTransition
        );
        Get.delete<SetupViewController>(force: true);
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
      return;
    }
    var header = "$rpApiRoot/";
    if (text.startsWith(header)) {
      await handleOpenAbsinthe(text.replaceFirst(header, ""));
      return;
    }
    var firstDashPos = text.split("-").firstOrNull?.length ?? 0;
    if (firstDashPos == 6 && "-".allMatches(text).length == 3 && text.length == 21) {
      Logger.debug("here");
      await handleOpenAbsinthe(text);
      return;
    }
    if (firstDashPos == 4 && "-".allMatches(text).length == 3 && text.length == 19) {
      Logger.debug("here");
      await handleBeeper(text);
      return;
    }
    try {
      var data = base64Decode(text);
      if (String.fromCharCodes(data).startsWith("OABS")) {
        var shared = data[4];
        var rawData = data.toList();
        rawData.removeRange(0, 5);
        
        var parsed = await api.configFromEncoded(encoded: rawData);
        select(parsed, shared == 0);
      } else if (data.length == 517 && data[0] == 0x02) {
        var parsed = await api.configFromValidationData(data: data, extra: api.HwExtra(
          version: "13.6.4",
          protocolVersion: 1660,
          deviceId: uuid.v4(),
          icloudUa: "com.apple.iCloudHelper/282 CFNetwork/1408.0.4 Darwin/22.5.0",
          aoskitVersion: "com.apple.AOSKit/282 (com.apple.accountsd/113)"
        ));
        select(parsed, true);
      } else {
        Logger.debug("resettingb");
        setState(() => staging = stagingInfo = null);
      }
    } catch (e) {
      setState(() => staging = stagingInfo = null);
      rethrow;
    }
  }

  void updateInitial() async {
    Logger.debug("updating app link");
    final _appLinks = AppLinks();
    var link = await _appLinks.getLatestLink();

    if (link != null) {
      checkCode(link.toString());
    } else {
      var state = await api.getPhase(state: pushService.state);
      if (state != api.RegistrationPhase.wantsOsConfig) {
        // restore
        stagingNonInp = true;
        alreadyActivated = true;
        var parsed = (await api.getConfigState(state: pushService.state))!;
        select(parsed, ss.settings.macIsMine.value);
        if (ss.settings.deviceIsHosted.value) {
          var code = await api.validateRelay(state: pushService.state);
          if (code != null) {
            controller.restoreTicket(code);
          }
        }
      }
    }
  }

  StreamSubscription<PurchasesResultWrapper>? subscription;

  Future<T> wrapSubscriptionPromise<T>(Future<T> inner) async {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: context.theme.colorScheme.properSurface,
          title: Text(
            "Validating subscription...",
            style: context.theme.textTheme.titleLarge,
          ),
          content: Container(
            height: 70,
            child: Center(
              child: CircularProgressIndicator(
                backgroundColor: context.theme.colorScheme.properSurface,
                valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
              ),
            ),
          ),
        );
      }
    );
    T result;
    try {
      result = await inner;
    } catch (e, s) {
      Get.back();
      showSnackbar("Failure handling subscription! Please try again", e.toString());
      rethrow;
    }
    Get.back();
    return result;
  }

  Future<void> handleSubscriptionToken(String subscription) async {
    String token;
    try {
      token = await controller.ensureToken();
    } catch (e, s) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            "We're so sorry!",
            style: context.theme.textTheme.titleLarge,
          ),
          backgroundColor: context.theme.colorScheme.properSurface,
          content: Text("When you start the subscription process, we reserve a device for you for 15 minutes. Unfortunately, it appears you took longer to complete the subscription, and, in that time, we gave your device to someone else and no longer have a device free. Feel free to retry periodically in the app, and, if you don't manage to get in within the next few days, your subscription will be automatically refunded by Google.", style: context.theme.textTheme.bodyLarge),
          actions: [
            TextButton(
              child: Text(
                  "Close",
                  style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
      return;
    }
    
    var activated = await http.dio.post("https://hw.openbubbles.app/ticket/$token/activate", data: {"purchase_token": subscription});
    var ticket = activated.data["ticket"];
    var parsed = await api.configFromRelay(code: ticket, host: "https://hw.openbubbles.app");
    usingBeeper = false;
    await connect(parsed, isHosted: true);
  }

  @override
  void dispose() {
    super.dispose();
    subscription?.cancel();
  }

  Future<bool> handlePurchases(PurchasesResultWrapper details) async {
    for (var detail in details.purchasesList) {
      if (detail.purchaseState != PurchaseStateWrapper.purchased) continue;
      if (!detail.isAcknowledged) {
        ss.settings.hostedPendingTransaction.value = detail.purchaseToken;
      } else {
        ss.settings.hostedPendingTransaction.value = null;
      }
      ss.saveSettings();
      await wrapSubscriptionPromise(handleSubscriptionToken(detail.purchaseToken));
      Logger.info("Purchased token ${detail.purchaseToken}");
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();

    subscription = pushService.client.purchasesUpdatedStream.listen((PurchasesResultWrapper details) {
      handlePurchases(details);
    });

    updateInitial();

    controller.updateIAPState();

    if (ss.settings.cachedCodes.containsKey("restore")) {
      handleOpenAbsinthe("restore");
    }

    // Start listening to changes.
    codeController.addListener(() async {
      checkCode(codeController.text);
    });
  }

  Widget materialButton(Widget inner, bool selected, void Function() onTap) {
    if (!selected) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: context.theme.colorScheme.primary),
          borderRadius: BorderRadius.circular(15),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(15),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: inner,
          )
        ),
      );
    }
    return Material(
      borderRadius: BorderRadius.circular(15),
      color: context.theme.colorScheme.primary,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(17),
          child: inner
        )
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: staging == null ? "Activation" : ss.settings.deviceIsHosted.value ? "Hosted Device" : stagingMine ? "My Device" : "Shared Device",
      customSubtitle: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: RichText(
            text: TextSpan(
              style: context.theme.textTheme.bodyLarge!.apply(
                fontSizeDelta: 1.5,
                color: context.theme.colorScheme.outline,
              ).copyWith(height: 2),
              children: staging != null ? [
                const TextSpan(
                  text: "This device has no access to your Apple account or messages."
                ),
              ] : hosted ? [
                const TextSpan(
                  text: "To activate iMessage, Apple requires a physical iDevice to validate your sign in."
                ),
              ] : [
                const TextSpan(
                  text: "To activate iMessage, Apple requires a physical iDevice to validate your sign in. "
                ),
                TextSpan(
                  text: 'Learn how to activate OpenBubbles.',
                  style: const TextStyle(color: Colors.blue),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () {
                      launchUrl(Uri.parse("https://openbubbles.app/macos"), mode: LaunchMode.externalApplication);
                  },
                ),
              ]
            ),
          ),
        ),
      ),
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
                                        RustPushBBUtils.getIcon(deviceName),
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
                        if (usingBeeper)
                        Container(
                          child: Text(
                            "If you no longer need Beeper, you can safely turn off or disconnect your Mac now. We'll handle it from here.",
                            style: context.theme.textTheme.bodyMedium,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (!stagingNonInp)
                        const SizedBox(height: 20),
                        if(!stagingNonInp && stagingInfo == null)
                        Row(
                          children: [
                            Obx(() => Expanded(
                              child: controller.availableIAP.value != null ? materialButton(
                                Row(
                                  children: [
                                    Expanded(child: Column(
                                      mainAxisSize: MainAxisSize.max,
                                      mainAxisAlignment: MainAxisAlignment.start,
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text("Hosted",
                                            style: context.theme.textTheme.titleMedium!.copyWith(color: !hosted ? null : context.theme.colorScheme.onPrimary)),
                                        Text("We'll take care of everything for you. \nYour phone number will become a blue bubble!",
                                            style: context.theme.textTheme.bodySmall!.copyWith(color: !hosted ? null : context.theme.colorScheme.onPrimary)),
                                        Text("\n${controller.availableIAP.value!.pricingPhases.last.formattedPrice}/mo${controller.availableIAP.value!.pricingPhases.length > 1 ? '. 7-day free trial.' : ''}",
                                            style: context.theme.textTheme.bodySmall!.copyWith(color: !hosted ? null : context.theme.colorScheme.onPrimary)),
                                      ],
                                    ),),
                                    const SizedBox(width: 10),
                                    Icon(
                                      Icons.arrow_forward,
                                      color: hosted ? context.theme.colorScheme.onPrimary : Colors.transparent,
                                    ),
                                  ],
                                ),
                                hosted,
                                () async {
                                  if (hosted) {
                                    wrapSubscriptionPromise<void>((() async {
                                      await controller.ensureToken();
                                      pushService.client.runWithClientNonRetryable<void>((client) async {
                                        var purchases = await client.queryPurchases(ProductType.subs);
                                        if (await handlePurchases(purchases)) return;
                                        var d = controller.availableIAP.value;
                                        if (d == null) return;
                                        client.launchBillingFlow(product: 'monthly_hosted', offerToken: d.offerIdToken);
                                      });
                                    })());
                                  }
                                  setState(() {
                                    hosted = true;
                                  });
                                }
                              ) : Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: context.theme.colorScheme.primary),
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: InkWell(
                                  onTap: () async {
                                    launchUrl(Uri.parse("https://docs.google.com/forms/d/e/1FAIpQLSf0psSFctObU_2Ib44H4WZlXhwpy-nLWy-jteYExWgKZ_mnhg/viewform?usp=header"));
                                  },
                                  borderRadius: BorderRadius.circular(15),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      children: [
                                        Expanded(child: Column(
                                          mainAxisSize: MainAxisSize.max,
                                          mainAxisAlignment: MainAxisAlignment.start,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text("Hosted",
                                                style: context.theme.textTheme.titleMedium!),
                                            Text("Currently unavailable. If you got an invite, click your link. Otherwise, join the waitlist!",
                                                style: context.theme.textTheme.bodySmall!),
                                          ],
                                        )),
                                        const SizedBox(width: 10),
                                        const Icon(
                                          Icons.arrow_forward,
                                        ),
                                      ]),
                                  )
                                ),
                              )
                            )),
                          ],
                          mainAxisSize: MainAxisSize.max,
                        ),
                        if(!stagingNonInp && stagingInfo == null)
                        const SizedBox(height: 15),
                        if(!stagingNonInp && stagingInfo == null)
                        Row(
                          children: [
                            Expanded(
                              child: materialButton(
                                Column(
                                  mainAxisSize: MainAxisSize.max,
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Self-managed",
                                        style: context.theme.textTheme.titleMedium!.copyWith(color: hosted ? null : context.theme.colorScheme.onPrimary)),
                                    Text("One-time access to a Mac or a supported, always-online iPhone required. Mac devices cannot use this phone's number.",
                                        style: context.theme.textTheme.bodySmall!.copyWith(color: hosted ? null : context.theme.colorScheme.onPrimary)),
                                  ],
                                ),
                                !hosted,
                                () {
                                  setState(() {
                                    hosted = false;
                                  });
                                }
                              )
                            )
                          ],
                          mainAxisSize: MainAxisSize.max,
                        ),
                        if (!stagingNonInp && stagingInfo == null)
                        const SizedBox(height: 10),
                        if (!stagingNonInp && !hosted)
                        Container(
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
                              textInputAction: TextInputAction.done,
                              onSubmitted: (value) {
                                lastCheckedCode = "";
                                checkCode(codeController.text);
                              },
                              decoration: InputDecoration(
                                enabledBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.outline),
                                    borderRadius: BorderRadius.circular(20)),
                                focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(color: context.theme.colorScheme.primary),
                                    borderRadius: BorderRadius.circular(20)),
                                labelText: "Enter Code",
                              ),
                            ),
                          ),
                        ),
                        if (!stagingNonInp && stagingInfo == null)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
                          child: Text("Both options are open-source and secure. Your messages go straight to Apple servers. The device you use has no access to your account or messages.",
                                            style: context.theme.textTheme.bodySmall!),
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
                                  if (stagingNonInp) {
                                    setState(() {
                                      stagingNonInp = false;
                                      staging = stagingInfo = null;
                                      codeController.clear();
                                      alreadyActivated = false;
                                      usingBeeper = false;
                                    });
                                  } else {
                                    goBack();
                                  }
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(stagingNonInp ? Icons.close : Icons.arrow_back, color: context.theme.colorScheme.onBackground, size: 20),
                                    const SizedBox(width: 10),
                                    Text(stagingNonInp ? "Cancel" : "Back",
                                        style: context.theme.textTheme.bodyLarge!
                                            .apply(fontSizeFactor: 1.1, color: context.theme.colorScheme.onBackground)),
                                  ],
                                ),
                              ),
                            ),
                            if (staging == null && !kIsDesktop && !loading && !hosted)
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
                                  scanQRCode();
                                },
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text("Scan Code",
                                        style: context.theme.textTheme.bodyLarge!
                                            .apply(fontSizeFactor: 1.1, color: context.theme.colorScheme.onBackground)),
                                    const SizedBox(width: 10),
                                    Icon(Icons.qr_code, color: context.theme.colorScheme.onBackground, size: 20),
                                  ],
                                ),
                              ),
                            ),
                            if (staging != null || kIsDesktop || loading)
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(25),
                                gradient: LinearGradient(
                                  begin: AlignmentDirectional.topStart,
                                  colors: loading || (kIsDesktop && staging == null) ? [HexColor('777777'), HexColor('777777')] : [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
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
                                onPressed: loading || (kIsDesktop && staging == null) ? null : () async {
                                  ss.settings.customHeaders.value = {};
                                  http.onInit();
                                  connect(staging!);
                                },
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Opacity(opacity: loading ? 0 : 1, child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(kIsDesktop && staging == null ? "Continue" : "Use this Device",
                                            style: context.theme.textTheme.bodyLarge!
                                                .apply(fontSizeFactor: 1.1, color: Colors.white)),
                                        const SizedBox(width: 10),
                                        const Icon(Icons.arrow_forward, color: Colors.white, size: 20),
                                      ],
                                    )),
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

  void goBack() {
    controller.twoFaUser = "";
    controller.twoFaPass = "";
    FocusManager.instance.primaryFocus?.unfocus();
    controller.pageController.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> connect(api.JoinedOsConfig config, {bool isHosted = false}) async {
    setState(() {
      loading = true;
    });
    controller.updateConnectError("");
    try {
      if (!alreadyActivated) {
        ss.settings.macIsMine.value = stagingMine;
        ss.settings.deviceIsHosted.value = isHosted;
        ss.settings.save();
        await api.configureMacos(state: pushService.state, config: config);
        controller.currentPhoneUsers = {}; // reset validated phone numbers as we have a new token now
        var list = ss.settings.cachedCodes.entries.toList();
        for (var items in list) {
          if (!items.key.startsWith("sms-auth-")) continue;
          ss.settings.cachedCodes.remove(items.key);
        }
        ss.saveSettings();
      }

      var state = await api.getDeviceInfoState(state: pushService.state);
      controller.supportsPhoneReg.value = state.name.contains("iPhone") || state.name.contains("iPod") || state.name.contains("iPad");
      // controller.updatePhoneReg();
      
      controller.pageController.nextPage(
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