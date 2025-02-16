import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/appleid_2fa.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/appleid_login.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/finalize.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/hw_inp.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/phone_number.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/setup/pages/setup_checks/battery_optimization.dart';
import 'package:bluebubbles/app/layouts/setup/dialogs/failed_to_connect_dialog.dart';
import 'package:bluebubbles/app/layouts/setup/pages/sync/sync_settings.dart';
import 'package:bluebubbles/app/layouts/setup/pages/sync/server_credentials.dart';
import 'package:bluebubbles/app/layouts/setup/pages/contacts/request_contacts.dart';
import 'package:bluebubbles/app/layouts/setup/pages/setup_checks/mac_setup_check.dart';
import 'package:bluebubbles/app/layouts/setup/pages/sync/sync_progress.dart';
import 'package:bluebubbles/app/layouts/setup/pages/welcome/welcome_page.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/main.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/crypto_utils.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:url_launcher/url_launcher.dart';
import 'package:convert/convert.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';

class SetupViewController extends StatefulController {
  final pageController = PageController(initialPage: 0);
  int currentPage = 1;
  int numberToDownload = 25;
  bool skipEmptyChats = true;
  bool saveToDownloads = false;
  String error = "";
  bool obscurePass = true;
  RxBool isSms = false.obs;

  RxBool supportsPhoneReg = false.obs;

  final GlobalKey<HwInpState> _childKey = GlobalKey<HwInpState>();

  bool goingTo2fa = true;
  bool success = false;
  bool triedBattery = false;

  api.LoginState state = const api.LoginState.needsLogin();
  api.IdsUser? currentAppleUser;
  Map<int, api.IdsUser> currentPhoneUsers = {};

  RxBool phoneValidating = false.obs;
  Rxn<SubscriptionOfferDetailsWrapper> availableIAP = Rxn();
  String? token;
  DateTime tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  bool hasValidToken() {
    return !tokenExpiry.isBefore(DateTime.now());
  }

  Future<String> ensureToken() async {
    if (!hasValidToken()) {
      // we need to refresh tokens
      final response2 = await http.dio.post(
        "https://hw.openbubbles.app/ticket",
      );

      if (response2.statusCode == 429) {
        throw Exception("Too many reserved tickets!");
      }

      token = response2.data["code"];
      tokenExpiry = DateTime.fromMillisecondsSinceEpoch(response2.data["expiry"] * 1000, isUtc: true);
    }

    return token!;
  }

  Future<void> updateIAPState() async {
    await pushService.client.runWithClientNonRetryable<void>((client) async {
      if (!hasValidToken()) {
        final status = await http.dio.get("https://hw.openbubbles.app/status");
        var hasCapacity = status.data["available"];
        if (!hasCapacity) {
          availableIAP.value = null;
          return;
        }
      }
      var details = await client.queryProductDetails(productList: [const ProductWrapper(productId: 'monthly_hosted', productType: ProductType.subs)]);
      if (details.productDetailsList.isEmpty) {
        Logger.warn("Product not found!");
        availableIAP.value = null;
        return;
      }

      print(details);

      availableIAP.value = details.productDetailsList.first.subscriptionOfferDetails?.first;
    });
  }

  void updateSucceeded(Function finish) async {
    finish(true);
    updateConnectError('');
    try {
      currentAppleUser = await api.retryLogin(state: pushService.state);
      ss.settings.userName.value = await api.getUserName(state: pushService.state);
      await doRegister();
    } catch (e) {
      if (e is AnyhowException) {
        updateConnectError(e.message);
      }
      if (e is PanicException) {
        updateConnectError(e.message);
      }
      rethrow;
    } finally {
      finish(false);
    }
  }

  Future<void> updateAccountUi(Function finish) async {
    var data = await api.updateAccountHeaders(state: pushService.state);
    var request = URLRequest(url: WebUri("https://inappwebview.dev/"));
    
    double height = 400;
    showDialog(
      context: Get.context!,
      builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        return Center(child: Container(
        height: height,
      child: InAppWebView(
        initialUrlRequest: request,
        initialData: InAppWebViewInitialData(data: data, baseUrl: WebUri("https://setup.icloud.com/setup/update_account_ui")),
        initialSettings: InAppWebViewSettings(
          useShouldInterceptAjaxRequest: true,
          interceptOnlyAsyncAjaxRequests: false,
          useShouldInterceptFetchRequest: true,
        ),
        shouldInterceptAjaxRequest: (controller, request) async {
          var anisette = await api.getAnisetteHeaders(state: pushService.state);
          for (var header in anisette.entries) {
            request.headers!.setRequestHeader(header.key, header.value);
          }
          return request;
        },
        shouldInterceptFetchRequest: (controller, request) async {
          var anisette = await api.getAnisetteHeaders(state: pushService.state);
          request.headers ??= {};
          request.headers!.addAll(anisette);
          return request;
        },
        onWebViewCreated: (controller) {
          controller.addJavaScriptHandler(handlerName: 'log', callback: (args) {
            Logger.info("AppleAccountSetup ${args[0]}");
          });
          controller.addJavaScriptHandler(handlerName: 'cancel', callback: (args) {
            Get.back();
          });
          controller.addJavaScriptHandler(handlerName: 'updateSucceeded', callback: (args) {
            updateSucceeded(finish);
            Get.back();
          });
          controller.addJavaScriptHandler(handlerName: 'resizeToWindow', callback: (args) {
            setState(() {
              height = args[1];
            });
          });
          controller.injectJavascriptFileFromAsset(assetFilePath: "assets/scripts/AppleAccountSetup.js");
        },
      )),);
      })
    );
  }

  Future<api.LoginState> updateLoginState(api.LoginState ret) async {
    if (ret is api.LoginState_NeedsLogin) {
      api.IdsUser? user;
      (ret, user) = await api.tryAuth(state: pushService.state, username: twoFaUser, password: twoFaPass);
      currentAppleUser = user;
    }
    if (ret is api.LoginState_NeedsDevice2FA) {
      ret = await api.send2FaToDevices(state: pushService.state);
      isSms.value = false;
    }
    if (ret is api.LoginState_NeedsSMS2FA) {
      var options = await api.get2FaSmsOpts(state: pushService.state);
      if (options.$2 != null) {
        ret = options.$2!;
      } else if (options.$1.length == 1) {
        ret = await api.send2FaSms(state: pushService.state, phoneId: options.$1[0].id);
      } else {
        int selectedRadio = -1;
        await showDialog(
          context: Get.context!,
          builder: (context) => AlertDialog(
            title: const Text('Choose number'),
            content: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: options.$1.map((e) => RadioListTile(
                      value: e.id,
                      groupValue: selectedRadio,
                      title: Text(e.numberWithDialCode),
                      onChanged: (val) {
                        setState(() {
                          selectedRadio = val!;
                        });
                      },
                    )).toList(),
                );
              },
            ),
            actions: <Widget>[
              TextButton(
                      onPressed: () {
                        selectedRadio = -1;
                        Get.back();
                      },
                      child: Text("Cancel", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary))),
              TextButton(
                      onPressed: () {
                        Get.back();
                      },
                      child: Text("OK", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary))),
            ],
          ),
        );
        if (selectedRadio == -1) {
          return ret;
        }
        ret = await api.send2FaSms(state: pushService.state, phoneId: selectedRadio);
      }
      isSms.value = true;
    }
    state = ret;
    if (ret is api.LoginState_LoggedIn) {
      ss.settings.userName.value = await api.getUserName(state: pushService.state);
      await doRegister();
    }
    return ret;
  }

  Future<void> doRegister() async {
    List<api.IdsUser> users = [];

    if (currentAppleUser != null) {
      users.add(currentAppleUser!);
    }

    if (currentPhoneUsers.isNotEmpty && supportsPhoneReg.value) {
      users.addAll(currentPhoneUsers.values);
    }

    if (users.isEmpty) {
      throw Exception("No users to register!");
    }
    try {
      var response = await api.registerIds(state: pushService.state, users: users);
      if (response != null) {
        var devInfo = await api.getDeviceInfoState(state: pushService.state);
        await showDialog(
          context: Get.context!,
          builder: (context) => AlertDialog(
                backgroundColor: Get.theme.colorScheme.properSurface,
                title: Text(
                  response.title,
                  style: Get.textTheme.titleLarge,
                ),
                content: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      response.body,
                      style: Get.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 20),
                    Align(
                      alignment: Alignment.center,
                      child: Text(
                        "The above message is from Apple.\nWarning: OpenBubbles is not an officially supported Apple product. If you can't login on this Mac, call Apple support.\n${RustPushBBUtils.modelToUser(devInfo.name)}\nS/N: ${devInfo.serial}\nmacOS ${devInfo.osVersion}",
                        textAlign: TextAlign.center,
                        style: Get.textTheme.bodySmall,
                      )
                    ),
                  ],
                ),
                actions: [
                  if (response.action != null)
                    TextButton(
                        onPressed: () => launchUrl(Uri.parse(response.action!.url), mode: LaunchMode.externalApplication),
                        child: Text(response.action!.button, style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary))),
                  TextButton(
                      onPressed: () => Get.back(),
                      child: Text("OK", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary))),
                ],
              ));
        return;
      }
      success = true;
      // persisting SMS auth certs is actually really useful
      // ss.settings.cachedCodes.clear();
      Logger.debug("Success registered!");
      await pushService.configured();

      var handles = await api.getHandles(state: pushService.state);
      var phone = handles.firstWhereOrNull((h) => h.startsWith("tel:"));
      if (phone != null) {
        ss.settings.defaultHandle.value = phone;
        ss.saveSettings();
      }

      Logger.debug("Finishing!");
      setup.finishSetup();
    } catch(e) {
      // reset currentPhoneUser because frb *insists* on taking ownership.
      var cpy = currentPhoneUsers.keys.toList(); // this is what happens when crappy languages have ambiguous reference semantics
      for (var item in cpy) {
        currentPhoneUsers[item] = await api.restoreUser(user: ss.settings.cachedCodes["sms-auth-$item"]!);
      }
      rethrow;
    }
  }

  Future<void> cacheCode(String code) async {
    if (ss.settings.cachedCodes.containsKey(code)) {
      return;
    }

    String hash = hex.encode(sha256.convert(code.codeUnits).bytes);

    final response = await http.dio.get(
      "$rpApiRoot/$hash",
      options: Options(
        headers: {
          "X-OpenBubbles-Get": ""
        },
      )
    );

    if (response.statusCode == 404) {
      return;
    }

    var data = response.data["data"];
    
     var myData = Uint8List.fromList(decryptAESCryptoJS(data, code));
    Logger.debug("cached code");
    ss.settings.cachedCodes[code] = base64Encode(myData);
    ss.saveSettings();
  }

  Future<api.LoginState> submitCode(String code) async {
    if (state is api.LoginState_Needs2FAVerification) {
      var (dart, isAnnoying) = await api.verify2Fa(state: pushService.state, code: code);
      state = dart;
      currentAppleUser = isAnnoying;
    } else if (state is api.LoginState_NeedsSMS2FAVerification) {
      var myState = state as api.LoginState_NeedsSMS2FAVerification;
      var (dart, isAnnoying) = await api.verify2FaSms(state: pushService.state, body: myState.field0, code: code);
      state = dart;
      currentAppleUser = isAnnoying;
    }
    return await updateLoginState(state);
  }

  String twoFaUser = "";
  String twoFaPass = "";

  int get pageOfNoReturn => kIsWeb || kIsDesktop ? 3 : 5;

  void restoreTicket(String ticket) async {
    token = ticket;
    // really just placeholder for never, token should be assumed to be valid.
    tokenExpiry = DateTime.now().add(const Duration(days: 7));
    if (availableIAP.value == null) {
      await updateIAPState();
    }
  }

  void updatePage(int newPage) {
    currentPage = newPage;
    updateWidgets<PageNumber>(newPage);
  }

  void updateNumberToDownload(int num) {
    numberToDownload = num;
    updateWidgets<NumberOfMessagesText>(num);
  }

  void updateConnectError(String newError) {
    if (newError.contains("6001")) {
      newError += " Make sure Contact Key Verification and Advanced Data Protection are off.";
    }
    error = newError;
    updateWidgets<ErrorText>(newError);
  }
}

class SetupView extends StatefulWidget {
  SetupView({super.key});

  @override
  State<SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends OptimizedState<SetupView> {
  final controller = Get.put(SetupViewController(), permanent: true);

  @override
  void initState() {
    super.initState();

    (() async {
      if (ss.settings.cachedCodes.containsKey("sms-auth")) {
        ss.settings.cachedCodes["sms-auth-1"] = ss.settings.cachedCodes["sms-auth"]!;
        ss.settings.cachedCodes.remove("sms-auth");
        ss.saveSettings();
        Logger.debug("Migrated sms auth");
      }
      await pushService.initFuture; // wait for ready
      var list = ss.settings.cachedCodes.entries.toList();
      for (var items in list) {
        if (!items.key.startsWith("sms-auth-")) continue;

        var user = await api.restoreUser(user: items.value);
        controller.phoneValidating.value = true;
        try {
          Logger.debug("restore validating!");
          await api.validateCert(state: pushService.state, user: user);
        } catch (e) {
          Logger.debug("restore resetting! $e");
          ss.settings.cachedCodes.remove(items.key);
          ss.saveSettings();
          continue;
        } finally {
          Logger.debug("restore done!");
          controller.phoneValidating.value = false;
        }

        controller.currentPhoneUsers[int.parse(items.key.replaceFirst("sms-auth-", ""))] = user;
      }
    })();

    (() async {

      try {
        await controller.updateIAPState();
      } catch (e, s) {
        Logger.error("failed to fetch IAP state", error: e, trace: s);
      }
      final _appLinks = AppLinks();
      var link = await _appLinks.getLatestLink();

      _appLinks.uriLinkStream.listen((uri) async {
        var text = uri.toString();
        Logger.info("Got uri stream $text");
        var ticketheader = "https://hw.openbubbles.app/ticket/";
        if (text.startsWith(ticketheader)) {
          controller.restoreTicket(text.replaceFirst(ticketheader, ""));
          return;
        }
        var header = "$rpApiRoot/";
        if (text.startsWith(header)) {
          Logger.debug("caching code");
          await controller.cacheCode(text.replaceFirst(header, ""));
          controller._childKey.currentState?.updateInitial();
        }
      });

      if (link != null) {
        var text = link.toString();
        var ticketheader = "https://hw.openbubbles.app/ticket/";
        if (text.startsWith(ticketheader)) {
          controller.restoreTicket(text.replaceFirst(ticketheader, ""));
          return;
        }
        var header = "$rpApiRoot/";
        if (text.startsWith(header)) {
          Logger.debug("caching code");
          await controller.cacheCode(text.replaceFirst(header, ""));
        }
      }
    })();

    ever(socket.state, (event) {
      if (event == SocketState.error
          && !ss.settings.finishedSetup.value
          && controller.pageController.hasClients
          && controller.currentPage > controller.pageOfNoReturn) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => FailedToConnectDialog(
            onDismiss: () {
              controller.pageController.animateToPage(
                controller.pageOfNoReturn - 1,
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeInOut,
              );
              Navigator.of(context).pop();
            },
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: ss.settings.windowEffect.value != WindowEffect.disabled ? Colors.transparent : context.theme.colorScheme.background,
        body: SafeArea(
          child: Column(
            children: <Widget>[
              SetupHeader(),
              const SizedBox(height: 20),
              SetupPages(),
            ],
          ),
        ),
      ),
    );
  }
}

class SetupHeader extends StatelessWidget {
  final SetupViewController controller = Get.find<SetupViewController>();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: kIsDesktop ? 40 : 20, left: 20, right: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Hero(
                tag: "setup-icon",
                child: Image.asset("assets/icon/icon.png", width: 30, fit: BoxFit.contain)
              ),
              const SizedBox(width: 10),
              Text(
                "OpenBubbles",
                style: context.theme.textTheme.bodyLarge!.apply(fontWeightDelta: 2, fontSizeFactor: 1.35),
              ),
            ],
          ),
          PageNumber(parentController: controller),
        ],
      ),
    );
  }
}

class PageNumber extends CustomStateful<SetupViewController> {
  PageNumber({required super.parentController});

  @override
  State<StatefulWidget> createState() => _PageNumberState();
}

class _PageNumberState extends CustomState<PageNumber, int, SetupViewController> {

  @override
  void updateWidget(int newVal) {
    controller.currentPage = newVal;
    super.updateWidget(newVal);
  }

  @override
  Widget build(BuildContext context) {
    return controller.currentPage == 1 ? const SizedBox.square(dimension: 40.0,) : Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(25),
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          colors: [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 13),
        child: RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: "${controller.currentPage}",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: Colors.white, fontWeight: FontWeight.bold)
              ),
              TextSpan(
                text: " of ${kIsWeb ? "4" : kIsDesktop ? "5" : "8"}",
                style: context.theme.textTheme.bodyLarge!.copyWith(color: Colors.white38, fontWeight: FontWeight.bold)
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SetupPages extends StatelessWidget {
  final SetupViewController controller = Get.find<SetupViewController>();

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Obx(() => PageView(
        onPageChanged: (page) {
          // skip pages if the things required are already complete
          if (!kIsWeb && !kIsDesktop && page == 1 && controller.currentPage == 1) {
            Permission.contacts.status.then((status) {
              if (status.isGranted) {
                controller.pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            });
          }
          if (!kIsWeb && !kIsDesktop && page == 2 && controller.currentPage == 2) {
            DisableBatteryOptimization.isAllBatteryOptimizationDisabled.then((isDisabled) {
              if (isDisabled ?? false) {
                controller.pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
              }
            });
          }
          controller.updatePage(page + 1);
        },
        physics: const NeverScrollableScrollPhysics(),
        controller: controller.pageController,
        children: <Widget>[
          WelcomePage(),
          if (!kIsWeb && !kIsDesktop) RequestContacts(),
          if (!kIsWeb && !kIsDesktop) BatteryOptimizationCheck(),
          if (!usingRustPush)
            MacSetupCheck(),
          if (!usingRustPush)
            ServerCredentials(),
          if (!kIsWeb && !usingRustPush)
            SyncSettings(),
          if (!usingRustPush)
            SyncProgress(),
          if (usingRustPush)
            HwInp(key: controller._childKey),
          if (usingRustPush && controller.supportsPhoneReg.value && !kIsDesktop)
            const PhoneNumber(),
          if (usingRustPush)
            AppleIdLogin(),
          if (usingRustPush)
            AppleId2FA(),
          if (usingRustPush)
            FinalizePage(),
          //ThemeSelector(),
        ],
      ),)
    );
  }
}


class ErrorText extends CustomStateful<SetupViewController> {
  ErrorText({required super.parentController});

  @override
  State<StatefulWidget> createState() => _ErrorTextState();
}

class _ErrorTextState extends CustomState<ErrorText, String, SetupViewController> {
  @override
  void updateWidget(String newVal) {
    controller.error = newVal;
    super.updateWidget(newVal);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.error.isNotEmpty)
          Container(
            width: context.width * 2 / 3,
            child: Align(
              alignment: Alignment.center,
              child: SelectableText(controller.error,
                  style: context.theme.textTheme.bodyLarge!
                      .apply(
                        fontSizeDelta: 1.5,
                        color: context.theme.colorScheme.error,
                      )
                      .copyWith(height: 2)),
            ),
          ),
        if (controller.error.isNotEmpty) const SizedBox(height: 20),
      ],
    );
  }
}