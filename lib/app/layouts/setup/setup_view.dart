import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/appleid_2fa.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/appleid_login.dart';
import 'package:bluebubbles/app/layouts/setup/pages/rustpush/os_config.dart';
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
import 'package:bluebubbles/src/rust/api/api.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:get/get.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:url_launcher/url_launcher.dart';

class SetupViewController extends StatefulController {
  final pageController = PageController(initialPage: 0);
  int currentPage = 1;
  int numberToDownload = 25;
  bool skipEmptyChats = true;
  bool saveToDownloads = false;
  String error = "";
  bool obscurePass = true;
  RxBool isSms = false.obs;

  DartLoginState state = const api.DartLoginState.needsLogin();

  Future<DartLoginState> updateLoginState(DartLoginState ret) async {
    if (ret is DartLoginState_NeedsLogin) {
      ret = await api.tryAuth(state: pushService.state, username: twoFaUser, password: twoFaPass);
    }
    if (ret is DartLoginState_NeedsDevice2FA) {
      ret = await api.send2FaToDevices(state: pushService.state);
      isSms.value = false;
    }
    if (ret is DartLoginState_NeedsSMS2FA) {
      var options = await api.get2FaSmsOpts(state: pushService.state);
      if (options.length == 1) {
        ret = await api.send2FaSms(state: pushService.state, phoneId: options[0].id);
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
                  children: options.map((e) => RadioListTile(
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
    if (ret is DartLoginState_LoggedIn) {
      ss.settings.userName.value = await api.getUserName(state: pushService.state);
      var response = await api.registerIds(state: pushService.state);
      if (response != null) {
        await showDialog(
          context: Get.context!,
          builder: (context) => AlertDialog(
                backgroundColor: Get.theme.colorScheme.properSurface,
                title: Text(
                  response.title,
                  style: Get.textTheme.titleLarge,
                ),
                content: Text(
                  response.body,
                  style: Get.textTheme.bodyLarge,
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
        return ret;
      }
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
    }
    return ret;
  }

  Future<void> submitCode(String code) async {
    if (state is DartLoginState_Needs2FAVerification) {
      state = await api.verify2Fa(state: pushService.state, code: code);
    } else if (state is DartLoginState_NeedsSMS2FAVerification) {
      var myState = state as DartLoginState_NeedsSMS2FAVerification;
      state = await api.verify2FaSms(state: pushService.state, body: myState.field0, code: code);
    }
    await updateLoginState(state);
  }

  String twoFaUser = "";
  String twoFaPass = "";

  int get pageOfNoReturn => kIsWeb || kIsDesktop ? 3 : 5;

  void updatePage(int newPage) {
    currentPage = newPage;
    updateWidgets<PageNumber>(newPage);
  }

  void updateNumberToDownload(int num) {
    numberToDownload = num;
    updateWidgets<NumberOfMessagesText>(num);
  }

  void updateConnectError(String newError) {
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
                "BlueBubbles",
                style: context.theme.textTheme.bodyLarge!.apply(fontWeightDelta: 2, fontSizeFactor: 1.35),
              ),
            ],
          ),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(25),
              gradient: LinearGradient(
                begin: AlignmentDirectional.topStart,
                colors: [HexColor('2772C3'), HexColor('5CA7F8').darkenPercent(5)],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 13),
              child: PageNumber(parentController: controller),
            ),
          ),
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
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: "${controller.currentPage}",
            style: context.theme.textTheme.bodyLarge!.copyWith(color: Colors.white, fontWeight: FontWeight.bold)
          ),
          TextSpan(
            text: " of ${kIsWeb ? "4" : kIsDesktop ? "5" : "7"}",
            style: context.theme.textTheme.bodyLarge!.copyWith(color: Colors.white38, fontWeight: FontWeight.bold)
          ),
        ],
      ),
    );
  }
}

class SetupPages extends StatelessWidget {
  final SetupViewController controller = Get.find<SetupViewController>();

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: PageView(
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
            OsConfig(),
          if (usingRustPush)
            AppleIdLogin(),
          if (usingRustPush)
            AppleId2FA(),
          //ThemeSelector(),
        ],
      ),
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