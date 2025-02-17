import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/settings/pages/theming/avatar/avatar_crop.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/next_button.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/main.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:get/get.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:skeletonizer/skeletonizer.dart';
import 'package:supercharged/supercharged.dart';
import 'package:telephony_plus/telephony_plus.dart';
import 'package:universal_io/io.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

class ProfilePanel extends StatefulWidget {

  ProfilePanel({super.key});

  @override
  State<ProfilePanel> createState() => _ProfilePanelState();
}

class _ProfilePanelState extends OptimizedState<ProfilePanel> with WidgetsBindingObserver {
  final RxDouble opacity = 1.0.obs;
  final RxMap<String, dynamic> accountInfo = RxMap({});
  final RxMap<String, dynamic> accountContact = RxMap({});
  final RxnBool reregisteringIds = RxnBool();

  StreamSubscription<PurchasesResultWrapper>? subscription;
  String? ticket;

  RxList<api.PrivateDeviceInfo> forwardingTargets = RxList([]);

  Future<void> handleSubscriptionToken(String subscription) async {
    var activated = await http.dio.post("https://hw.openbubbles.app/ticket/${ticket!}/activate", data: {"purchase_token": subscription});
    var useTicket = activated.data["ticket"];
    if (useTicket != ticket) {
      throw Exception("Ticket changed???");
    }
    (() async {
      try {
        reregisteringIds.value = true;
        await api.doReregister(state: pushService.state);
        getDetails();
        showSnackbar("Success", "Registered");
      } catch (e) {
        showSnackbar("Failure", e.toString());
        rethrow;
      } finally {
        reregisteringIds.value = false;
      }
    })();
  }

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
    getDetails();
    subscription = pushService.client.purchasesUpdatedStream.listen((PurchasesResultWrapper details) {
      handlePurchases(details);
    });
  }

  @override
  void dispose() {
    super.dispose();
    subscription?.cancel();
  }

  void getDetails() async {
    try {
      final result = await backend.getAccountInfo();
      accountInfo.addAll(result);
      opacity.value = 1.0;
      final result2 = await backend.getAccountContact();
      accountContact.addAll(result2);
    } catch (_) {

    }
    var myHandles = (await api.getHandles(state: pushService.state));
    List<api.PrivateDeviceInfo> pendingTargets = ss.settings.isSmsRouter.value ? await api.getSmsTargets(state: pushService.state, handle: myHandles.first, refresh: true) : [];
    ss.saveSettings();
    setState(() {
      forwardingTargets.value = pendingTargets;
    });
    setState(() {});
  }

  void updateName() async {
    final nameController = TextEditingController(text: ss.settings.userName.value);
    done() async {
      if (nameController.text.isEmpty) {
        showSnackbar("Error", "Enter a name!");
        return;
      }
      Get.back();
      ss.settings.userName.value = nameController.text;
      await ss.settings.saveOne("userName");
      setState(() {});
    }
    await showDialog(
        context: context,
        builder: (_) {
          return AlertDialog(
            actions: [
              TextButton(
                child: Text("Cancel", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                onPressed: () => Get.back(),
              ),
              TextButton(
                child: Text("OK", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)),
                onPressed: () async {
                  done.call();
                },
              ),
            ],
            content: TextField(
              controller: nameController,
              onSubmitted: (_) => done.call(),
              autofocus: true,
              decoration: const InputDecoration(
                labelText: "Name",
                border: OutlineInputBorder(),
              ),
            ),
            title: Text("User Profile Name", style: context.theme.textTheme.titleLarge),
            backgroundColor: context.theme.colorScheme.properSurface,
          );
        }
    );
  }

  void updatePhoto() async {
    Navigator.of(context).push(
      ThemeSwitcher.buildPageRoute(
        builder: (context) => AvatarCrop(),
      ),
    );
  }

  void removePhoto() {
    File file = File(ss.settings.userAvatarPath.value!);
    file.delete();
    ss.settings.userAvatarPath.value = null;
    ss.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      headerColor: headerColor,
      title: "iMessage Profile",
      tileColor: tileColor,
      initialHeader: null,
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      bodySlivers: [
        SliverToBoxAdapter(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 10),
                if (iOS)
                  Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        GestureDetector(
                          onTap: () async {
                            updatePhoto();
                          },
                          child: ContactAvatarWidget(
                            handle: null,
                            borderThickness: 0.1,
                            editable: false,
                            fontSize: 22,
                            size: 100,
                          ),
                        ),
                        Obx(() => ss.settings.userAvatarPath.value != null ? Positioned(
                          right: -5,
                          top: -5,
                          child: InkWell(
                            onTap: () async {
                              removePhoto();
                            },
                            child: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                border: Border.all(color: context.theme.colorScheme.background, width: 1),
                                shape: BoxShape.circle,
                                color: context.theme.colorScheme.tertiaryContainer,
                              ),
                              child: Icon(
                                Icons.close,
                                color: context.theme.colorScheme.onTertiaryContainer,
                                size: 20,
                              ),
                            ),
                          ),
                        ) : const SizedBox.shrink()),
                      ],
                    ),
                  ),
                if (iOS)
                  Padding(
                    padding: const EdgeInsets.only(top: 12.0),
                    child: Center(
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: context.theme.textTheme.headlineMedium!.copyWith(
                            fontWeight: FontWeight.bold,
                            color: context.theme.colorScheme.onBackground,
                          ),
                          children: MessageHelper.buildEmojiText(
                            ss.settings.redactedMode.value && ss.settings.hideContactInfo.value
                                ? "User Name" : ss.settings.userName.value,
                            context.theme.textTheme.headlineMedium!.copyWith(
                              fontWeight: FontWeight.bold,
                              color: context.theme.colorScheme.onBackground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (iOS)
                  Padding(
                    padding: const EdgeInsets.only(top: 2.0),
                    child: Center(
                      child: RichText(
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        text: TextSpan(
                          style: context.theme.textTheme.bodyMedium!.apply(color: context.theme.colorScheme.outline),
                          children: MessageHelper.buildEmojiText(
                              ss.settings.redactedMode.value && ss.settings.hideContactInfo.value
                                  ? "User iCloud"
                                  : ss.settings.iCloudAccount.isEmpty
                                  ? "Unknown iCloud account"
                                  : ss.settings.iCloudAccount.value,
                              context.theme.textTheme.bodyMedium!.apply(color: context.theme.colorScheme.outline)
                          ),
                        ),
                      ),
                    ),
                  ),
                if (iOS)
                  Center(
                    child: TextButton(
                      child: Text(
                        "Change Name",
                        style: context.theme.textTheme.bodyMedium!.apply(color: context.theme.colorScheme.primary),
                        textScaler: const TextScaler.linear(1.15),
                      ),
                      onPressed: () async {
                        updateName();
                      },
                    ),
                  ),
                if (!iOS)
                  Padding(
                    padding: const EdgeInsets.only(left: 15.0, bottom: 5.0),
                    child: Text(
                        "YOUR NAME AND PHOTO",
                        style: context.theme.textTheme.bodyMedium!.copyWith(color: context.theme.colorScheme.outline)
                    ),
                  ),
                if (!iOS)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        mouseCursor: MouseCursor.defer,
                        leading: ContactAvatarWidget(
                          handle: null,
                          borderThickness: 0.1,
                          editable: false,
                          fontSize: 22,
                          size: 50,
                        ),
                        onTap: () async {
                          updateName();
                        },
                        title: RichText(
                          text: TextSpan(
                            style: context.theme.textTheme.bodyLarge,
                            children: MessageHelper.buildEmojiText(
                              ss.settings.redactedMode.value && ss.settings.hideContactInfo.value
                                  ? "User Name" : ss.settings.userName.value,
                              context.theme.textTheme.bodyLarge!,
                            ),
                          ),
                        ),
                        subtitle: Text(ss.settings.redactedMode.value && ss.settings.hideContactInfo.value
                            ? "User iCloud"
                            : ss.settings.iCloudAccount.isEmpty
                            ? "Unknown iCloud account"
                            : ss.settings.iCloudAccount.value, style: context.theme.textTheme.bodyMedium!.apply(color: context.theme.colorScheme.outline)),
                        trailing: Icon(Icons.edit_outlined, color: context.theme.colorScheme.onBackground),
                      ),
                    ),
                  ),
                if (!iOS)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        mouseCursor: MouseCursor.defer,
                        onTap: () async {
                          updatePhoto();
                        },
                        title: Text("Update your photo", style: context.theme.textTheme.bodyLarge!),
                        trailing: Icon(Icons.edit_outlined, color: context.theme.colorScheme.onBackground),
                      ),
                    ),
                  ),
                if (!iOS)
                  Obx(() => ss.settings.userAvatarPath.value != null ? Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: Material(
                      color: Colors.transparent,
                      child: ListTile(
                        mouseCursor: MouseCursor.defer,
                        onTap: () async {
                          removePhoto();
                        },
                        title: Text("Remove your photo", style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.error)),
                        trailing: Icon(Icons.close, color: context.theme.colorScheme.error),
                      ),
                    ),
                  ) : const SizedBox.shrink()),
                SettingsHeader(
                    iosSubtitle: iosSubtitle,
                    materialSubtitle: materialSubtitle,
                    text: "Apple Account Info"),
                Skeletonizer(
                  enabled: accountInfo.isEmpty,
                  child: SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      Obx(() {
                        bool redact = ss.settings.redactedMode.value;
                        return Container(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 8.0, left: 15, top: 8.0, right: 15),
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 300),
                              opacity: opacity.value,
                              child: SelectableText.rich(
                                TextSpan(children: [
                                  TextSpan(text: redact ? "Account Name - Apple ID" : "${accountInfo['account_name']} - ${accountInfo['apple_id']}"),
                                  const TextSpan(text: "\n"),
                                  const TextSpan(text: "iMessage Status: ", style: TextStyle(height: 3.0)),
                                  TextSpan(
                                      text: accountInfo['login_status_message'],
                                      style: TextStyle(color: getIndicatorColor((accountInfo['login_status_message']?.startsWith("Connected") ?? false) ? SocketState.connected : SocketState.disconnected))),
                                  const TextSpan(text: "\n"),
                                  const TextSpan(text: "SMS Forwarding Status: "),
                                  TextSpan(
                                      text: accountInfo['sms_forwarding_enabled'] == true ? "ENABLED" : "DISABLED",
                                      style: TextStyle(color: getIndicatorColor(accountInfo['sms_forwarding_enabled'] == true ? SocketState.connected : SocketState.disconnected))),
                                  const TextSpan(text: "  |  "),
                                  TextSpan(
                                      text: accountInfo['sms_forwarding_capable'] == true ? "CAPABLE" : "INCAPABLE",
                                      style: TextStyle(color: getIndicatorColor(accountInfo['sms_forwarding_capable'] == true ? SocketState.connected : SocketState.disconnected))),
                                  const TextSpan(text: "\n"),
                                  const TextSpan(text: "VETTED ALIASES\n", style: TextStyle(fontWeight: FontWeight.w700, height: 3.0)),
                                  ...((accountInfo['vetted_aliases'] as List<dynamic>? ?? [])).map((e) => [
                                    TextSpan(text: "⬤  ", style: TextStyle(color: getIndicatorColor(e['Status'] == 3 ? SocketState.connected : SocketState.disconnected))),
                                    TextSpan(text: redact ? (GetUtils.isEmail(e['Alias']) ? "Redacted Email\n" : "Redacted Phone\n") : "${e['Alias']}\n")
                                  ]).toList().flattened,
                                  const TextSpan(text: "\n"),
                                  const TextSpan(text: "Tap to update values...", style: TextStyle(fontStyle: FontStyle.italic)),
                                ]),
                                onTap: () {
                                  opacity.value = 0.0;
                                  getDetails();
                                },
                              ),
                            ),
                          ));
                      }),
                      if (accountInfo['login_status_message']?.startsWith("Deregistered") ?? false)
                        Container(
                          color: tileColor,
                          child: SettingsDivider(color: context.theme.colorScheme.surfaceVariant, padding: EdgeInsets.zero,),
                        ),
                      if ((accountInfo['login_status_message']?.startsWith("Deregistered") ?? false) || (accountInfo['login_status_message']?.contains("Subscription not active!") ?? false))
                        SettingsTile(
                        title: accountInfo['login_status_message']!.contains("Ticket not reserved!") ? "Reserve a new device" : accountInfo['login_status_message']!.contains("Subscription not active!") ? "Renew subscription" : "Retry now",
                        onTap: () async {
                          if (accountInfo['login_status_message']!.contains("Ticket not reserved!")) {
                            final status = await http.dio.get("https://hw.openbubbles.app/status");
                            var hasCapacity = status.data["available"];
                            if (!hasCapacity) {
                              var description = "We had to release your device for maintenance purposes, and cannot currently reserve another device. Please contact support@openbubbles.app for assistance. We apologize for the inconvenience, and will process refunds if we don't have another device for you.";
                              // if we're not told we're not active, that means we have lost privileges to our device.
                              showDialog(
                                context: context,
                                builder: (context) => AlertDialog(
                                  title: Text(
                                    "We're so sorry!",
                                    style: context.theme.textTheme.titleLarge,
                                  ),
                                  backgroundColor: context.theme.colorScheme.properSurface,
                                  content: Text(description, style: context.theme.textTheme.bodyLarge),
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
                            } else {
                              (backend as RustPushBackend).markFailedToLogin(hw: true);
                            }
                            return;
                          }
                          if (accountInfo['login_status_message']!.contains("Subscription not active!")) {
                            wrapSubscriptionPromise((() async {
                              ticket = await api.validateRelay(state: pushService.state);
                              if (ticket == null) {
                                final status = await http.dio.get("https://hw.openbubbles.app/status");
                                var hasCapacity = status.data["available"];
                                var description = "When an OpenBubbles subscription becomes invalid, we reserve your device for a few days as a courtesy should you choose to restart your subscription. Unfortunately, however, we have already released your device to another user.";
                                if (hasCapacity) {
                                  description += " We have more devices available, however, you will have to re-activate. Backing up your messages now is recommended in case you aren't able to get back in.";
                                } else {
                                  description += " Double unfortunately, we are currently out of devices. Please check back later.";
                                }
                                // if we're not told we're not active, that means we have lost privileges to our device.
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text(
                                      "We're so sorry!",
                                      style: context.theme.textTheme.titleLarge,
                                    ),
                                    backgroundColor: context.theme.colorScheme.properSurface,
                                    content: Text(description, style: context.theme.textTheme.bodyLarge),
                                    actions: [
                                      TextButton(
                                        child: Text(
                                            "Close",
                                            style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)
                                        ),
                                        onPressed: () => Navigator.of(context).pop(),
                                      ),
                                      if (hasCapacity)
                                      TextButton(
                                        child: Text(
                                            "Restart subscription",
                                            style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.primary)
                                        ),
                                        onPressed: () {
                                          (backend as RustPushBackend).markFailedToLogin(hw: true);
                                        }
                                      ),
                                    ],
                                  ),
                                );
                                return;
                              }
                              pushService.client.runWithClientNonRetryable<void>((client) async {
                                var purchases = await client.queryPurchases(ProductType.subs);
                                if (await handlePurchases(purchases)) return;

                                var details = await client.queryProductDetails(productList: [const ProductWrapper(productId: 'monthly_hosted', productType: ProductType.subs)]);
                                if (details.productDetailsList.isEmpty) {
                                  return;
                                }
                                client.launchBillingFlow(product: 'monthly_hosted', offerToken: details.productDetailsList.first.subscriptionOfferDetails?.first.offerIdToken);
                              });
                            })());
                            return;
                          }
                          try {
                            reregisteringIds.value = true;
                            await api.doReregister(state: pushService.state);
                            getDetails();
                            showSnackbar("Success", "Registered");
                          } catch (e) {
                            showSnackbar("Failure", e.toString());
                            rethrow;
                          } finally {
                            reregisteringIds.value = false;
                          }
                        },
                        trailing: Obx(() => reregisteringIds.value == null
                            ? const NextButton()
                            : reregisteringIds.value == true ? Container(
                            constraints: const BoxConstraints(
                              maxHeight: 20,
                              maxWidth: 20,
                            ),
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                            )) : Icon(Icons.check, color: context.theme.colorScheme.outline))
                        ),
                      if (accountInfo['active_alias'] != null)
                        Container(
                          color: tileColor,
                          child: SettingsDivider(color: context.theme.colorScheme.surfaceVariant, padding: EdgeInsets.zero,),
                        ),
                      if (accountInfo['active_alias'] != null)
                        SettingsOptions<String>(
                          title: "Start Chats Using",
                          initial: accountInfo['active_alias'],
                          clampWidth: false,
                          options: accountInfo['vetted_aliases'].map((e) => e['Alias'].toString()).toList().cast<String>(),
                          secondaryColor: headerColor,
                          useCupertino: false,
                          textProcessing: (str) => ss.settings.redactedMode.value ? (GetUtils.isEmail(str) ? "Redacted Email" : "Redacted Phone") : str,
                          capitalize: false,
                          onChanged: (value) async {
                            if (value == null) return;
                            accountInfo['active_alias'] = value;
                            setState(() {});
                            await backend.setDefaultHandle(value);
                          },
                        ),
                    if (usingRustPush && Platform.isAndroid)
                      Obx(() => SettingsSwitch(
                          onChanged: (bool val) async {
                            if (val) {
                              var granted = await TelephonyPlus().requestPermissions();
                              if (!granted) {
                                showSnackbar("SMS denied", "Please enable SMS permission in settings");
                                return;
                              }
                            }
                            var myHandles = (await api.getHandles(state: pushService.state));
                            ss.settings.isSmsRouter.value = val;

                            List<api.PrivateDeviceInfo> pendingTargets = val ? await api.getSmsTargets(state: pushService.state, handle: myHandles.first, refresh: true) : [];
                            if (!val) {
                              await (backend as RustPushBackend).broadcastSmsForwardingState(false, ss.settings.smsForwardingTargets);
                            }
                            ss.settings.smsForwardingTargets.retainWhere((element) => pendingTargets.any((e) => e.uuid == element));
                            ss.saveSettings();
                            setState(() {
                              forwardingTargets.value = pendingTargets;
                            });
                          },
                          initialVal: ss.settings.isSmsRouter.value,
                          title: "Use SMS with this phone (BETA)",
                          subtitle: "Use this phone with OpenBubbles and your other Apple devices${(accountInfo['vetted_aliases']?.any((i) => !GetUtils.isEmail(i['Alias'])) ?? false) ? "" : ". Warning: no phone handles are registered; official Apple clients will only be able to receive forwarded SMS"}",
                          backgroundColor: tileColor,
                          isThreeLine: true,
                        )),
                      if (!ss.settings.redactedMode.value)
                      ...(usingRustPush && Platform.isAndroid && ss.settings.isSmsRouter.value ? 
                        forwardingTargets.filter((target) => target.uuid != null && target.deviceName != null).map((target) => SettingsSwitch(
                          onChanged: (bool val) async {
                            if (!target.isHsaTrusted) {
                              showSnackbar("Can't enable SMS forwarding!", "Re-log in with 2fa on the other device");
                              return;
                            }
                            if (ss.settings.smsForwardingTargets.contains(target.uuid)) {
                              ss.settings.smsForwardingTargets.remove(target.uuid);
                              setState(() { });
                              await (backend as RustPushBackend).broadcastSmsForwardingState(false, [target.uuid!]);
                            } else {
                              ss.settings.smsForwardingTargets.add(target.uuid!);
                              setState(() { });                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           
                              await (backend as RustPushBackend).broadcastSmsForwardingState(true, [target.uuid!]);
                            }
                            ss.saveSettings();
                          },
                          initialVal: ss.settings.smsForwardingTargets.contains(target.uuid),
                          title: target.deviceName!,
                          backgroundColor: tileColor,
                        ))
                       : [])
                    ],
                  )),
                if (!isNullOrEmpty(accountContact['name']))
                  SettingsHeader(
                      iosSubtitle: iosSubtitle,
                      materialSubtitle: materialSubtitle,
                      text: "iMessage Contact Card"),
                if (!isNullOrEmpty(accountContact['name']))
                  SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      SettingsTile(
                        leading: (accountContact['avatar'] == null) ? const CircleAvatar() : ContactAvatarWidget(
                          handle: null,
                          contact: isNullOrEmpty(accountContact['avatar']) ? null : Contact(id: randomString(9), displayName: "", avatar: base64Decode(accountContact['avatar'])),
                        ),
                        title: accountContact['name'],
                        subtitle: "Your sharable iMessage contact card",
                      ),
                      const SettingsSubtitle(subtitle: "Visit iMessage settings on your Mac to update.")
                    ],
                  ),
              ],
          ),
        ),
        const SliverPadding(
          padding: EdgeInsets.only(top: 50),
        ),
      ],
    );
  }
}
