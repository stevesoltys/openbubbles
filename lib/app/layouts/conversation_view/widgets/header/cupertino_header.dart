import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/conversation_details/conversation_details.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_group_widget.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:gesture_x_detector/gesture_x_detector.dart';
import 'package:flutter/material.dart' hide BackButton;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:universal_io/io.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

class CupertinoHeader extends StatelessWidget implements PreferredSizeWidget {
  const CupertinoHeader({Key? key, required this.controller});

  final ConversationViewController controller;

  // simulate apple's saturatioon
  static const List<double> darkMatrix = <double>[
    1.385, -0.56, -0.112, 0.0, 0.3, //
    -0.315, 1.14, -0.112, 0.0, 0.3, //
    -0.315, -0.56, 1.588, 0.0, 0.3, //
    0.0, 0.0, 0.0, 1.0, 0.0
  ];

  static const List<double> lightMatrix = <double>[
    1.74, -0.4, -0.17, 0.0, 0.0, //
    -0.26, 1.6, -0.17, 0.0, 0.0, //
    -0.26, -0.4, 1.83, 0.0, 0.0, //
    0.0, 0.0, 0.0, 1.0, 0.0
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
          filter: ImageFilter.compose(
              outer: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
              inner: ColorFilter.matrix(
                CupertinoTheme.maybeBrightnessOf(context) == Brightness.dark ? darkMatrix : lightMatrix,
              )),
          child: Stack(
            children: [
              Column(
                children: [
              Expanded(child: Container(
                decoration: BoxDecoration(
                  color: context.theme.colorScheme.properSurface.withOpacity(0.7),
                  border: Border(
                    bottom: BorderSide(color: context.theme.colorScheme.properSurface.darkenAmount(0.25), width: 0.5),
                  ),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Padding(
                    padding: EdgeInsets.only(
                        left: 20.0,
                        right: 20,
                        top: (MediaQuery.of(context).viewPadding.top - 2).clamp(0, double.infinity)),
                    child: Stack(alignment: Alignment.center, children: [
                      Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: XGestureDetector(
                              supportTouch: true,
                              onTap: !kIsDesktop
                                  ? null
                                  : (details) {
                                      if (controller.inSelectMode.value) {
                                        controller.inSelectMode.value = false;
                                        controller.selected.clear();
                                        return;
                                      }
                                      if (ls.isBubble) {
                                        SystemNavigator.pop();
                                        return;
                                      }
                                      controller.close();
                                      if (Get.isSnackbarOpen) {
                                        Get.closeAllSnackbars();
                                      }
                                      Navigator.of(context).pop();
                                    },
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () {
                                  if (kIsDesktop) return;
                                  if (controller.inSelectMode.value) {
                                    controller.inSelectMode.value = false;
                                    controller.selected.clear();
                                    return;
                                  }
                                  if (ls.isBubble) {
                                    SystemNavigator.pop();
                                    return;
                                  }
                                  controller.close();
                                  if (Get.isSnackbarOpen) {
                                    Get.closeAllSnackbars();
                                  }
                                  Navigator.of(context).pop();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(3.0),
                                  child: _UnreadIcon(controller: controller),
                                ),
                              ),
                            ),
                          )),
                      Align(
                        alignment: Alignment.center,
                        child: XGestureDetector(
                          supportTouch: true,
                          onTap: !kIsDesktop
                              ? null
                              : (details) {
                                  Navigator.of(context).push(
                                    ThemeSwitcher.buildPageRoute(
                                      builder: (context) => ConversationDetails(
                                        chat: controller.chat,
                                      ),
                                    ),
                                  );
                                },
                          child: InkWell(
                            onTap: () {
                              if (kIsDesktop) return;
                              Navigator.of(context).push(
                                ThemeSwitcher.buildPageRoute(
                                  builder: (context) => ConversationDetails(
                                    chat: controller.chat,
                                  ),
                                ),
                              );
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.all(3.0),
                              child: _ChatIconAndTitle(parentController: controller),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Align(alignment: Alignment.topRight, child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              FaceTimeBtn(controller: controller),
                              ManualMark(controller: controller),
                            ],
                          ))),
                    ]),
                  ),
                ),
              ),),  
                  Obx(() => controller.suggestedContact.value != null ? 
                    Container(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          if (controller.suggestedContact.value!.avatar != null)
                          ContactAvatarWidget(
                            contact: controller.suggestedContact.value,
                            size: 38,
                            preferHighResAvatar: true,
                            scaleSize: false,
                          ),
                          if (controller.suggestedContact.value!.avatar != null)  
                          const SizedBox(width: 15,),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("New Contact Info", style: context.theme.textTheme.titleMedium,),
                              Text(controller.suggestedContact.value!.displayName.replaceFirst("Maybe: ", ""), style: context.theme.textTheme.bodyMedium?.copyWith(color: context.theme.colorScheme.outline),),
                            ],
                          ),
                          const Spacer(),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.theme.colorScheme.outline.withAlpha(64),
                              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 13),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              elevation: 0.0,
                              minimumSize: Size.zero,
                            ),
                            onPressed: () async {
                              var contact = controller.suggestedContact.value!;
                              var existingParticipant = Handle.findOne(id: controller.chat.participants.first.id)!; // so contact field updates
                              if (Platform.isAndroid) {
                                var parameters = {'address': existingParticipant.address, 'address_type': existingParticipant.address.isEmail ? 'email' : 'phone'}; 
                                parameters["name"] = contact.displayName.replaceFirst("Maybe: ", "");
                                if (contact.avatar != null) parameters["image"] = base64Encode(contact.avatar!);
                                if (!(existingParticipant.contact?.isShared ?? true)) {
                                  parameters["existing"] = existingParticipant.contact!.id;

                                  // contact syncing takes forever...
                                  var update = existingParticipant.contact!;
                                  update.displayName = contact.displayName.replaceFirst("Maybe: ", "");
                                  update.structuredName = contact.structuredName;
                                  update.avatar = contact.avatar;   
                                  if (contact.id == update.id) {
                                    contact = update;
                                  } else {
                                    update.save();
                                  }
                                }
                                await mcs.invokeMethod("open-contact-form", parameters);
                              } else {
                                var update = existingParticipant.contact!;
                                update.displayName = contact.displayName.replaceFirst("Maybe: ", "");
                                update.structuredName = contact.structuredName;
                                update.avatar = contact.avatar;
                                update.isShared = false;
                                if (contact.id == update.id) {
                                  contact = update;
                                } else {
                                  update.save();
                                }
                              }
                              contact.isDismissed = true;
                              contact.save();
                              controller.suggestedContact.value = null;
                            },
                            child: Text(
                              (controller.chat.participants.first.contact?.isShared ?? true) ? "Add" : "Update", style: context.theme.textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(width: 5,),
                          Opacity(opacity: 0.5, child: IconButton(
                            icon: Icon(
                              CupertinoIcons.clear,
                              color: context.theme.colorScheme.outline,
                              size: 24,
                            ),
                            style: ElevatedButton.styleFrom(splashFactory: NoSplash.splashFactory),
                            visualDensity: Platform.isAndroid ? VisualDensity.compact : null,
                            onPressed: () async {
                              var contact = controller.suggestedContact.value!;
                              contact.isDismissed = true;
                              contact.save();
                              controller.suggestedContact.value = null;
                            },
                          ),)
                        ],
                      ),
                    ) : const SizedBox.shrink()),
                    Obx(() => controller.suggestedContact.value == null && controller.suggestShare.value ? 
                    Container(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          ContactAvatarWidget(
                            size: 38,
                            preferHighResAvatar: true,
                            scaleSize: false,
                          ),
                          const SizedBox(width: 15,),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Share your name and photo?", style: context.theme.textTheme.titleMedium,),
                              Text(ss.settings.userName.value, style: context.theme.textTheme.bodyMedium?.copyWith(color: context.theme.colorScheme.outline),),
                            ],
                          ),
                          const Spacer(),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: context.theme.colorScheme.outline.withAlpha(64),
                              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 13),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              elevation: 0.0,
                              minimumSize: Size.zero,
                            ),
                            onPressed: () async {
                              ss.settings.sharedContacts.add(controller.chat.participants.first.address);
                              ss.saveSettings();
                              controller.suggestShare.value = false;
                              pushService.updateShareState();

                              var msg = await api.newMsg(
                                state: pushService.state,
                                conversation: api.ConversationData(participants: [RustPushBBUtils.bbHandleToRust(controller.chat.participants.first)]),
                                sender: await controller.chat.ensureHandle(),
                                message: api.Message.shareProfile(await api.decodeProfileMessage(s: ss.settings.shareProfileMessage.value!)),
                              );
                              await (backend as RustPushBackend).sendMsg(msg);
                            },
                            child: Text("Share", style: context.theme.textTheme.titleMedium),
                          ),
                          const SizedBox(width: 5,),
                          Opacity(opacity: 0.5, child: IconButton(
                            icon: Icon(
                              CupertinoIcons.clear,
                              color: context.theme.colorScheme.outline,
                              size: 24,
                            ),
                            style: ElevatedButton.styleFrom(splashFactory: NoSplash.splashFactory),
                            visualDensity: Platform.isAndroid ? VisualDensity.compact : null,
                            onPressed: () async {
                              ss.settings.dismissedContacts.add(controller.chat.participants.first.address);
                              ss.saveSettings();
                              controller.suggestShare.value = false;
                              pushService.updateShareState();
                            },
                          ),)
                        ],
                      ),
                    ) : const SizedBox.shrink()),
                ],
              ),
              Positioned(
                child: Obx(() => TweenAnimationBuilder<double>(
                    duration: controller.chat.sendProgress.value == 0
                        ? Duration.zero
                        : controller.chat.sendProgress.value == 1
                            ? const Duration(milliseconds: 250)
                            : const Duration(seconds: 10),
                    curve: controller.chat.sendProgress.value == 1 ? Curves.easeInOut : Curves.easeOutExpo,
                    tween: Tween<double>(
                      begin: 0,
                      end: controller.chat.sendProgress.value,
                    ),
                    builder: (context, value, _) => AnimatedOpacity(
                          opacity: value == 1 ? 0 : 1,
                          duration: const Duration(milliseconds: 250),
                          child: LinearProgressIndicator(
                            value: value,
                            backgroundColor: Colors.transparent,
                            minHeight: 3,
                          ),
                        ))),
                bottom: 0,
                left: 0,
                right: 0,
              ),
            ],
          )),
    );
  }

  @override
  Size get preferredSize =>
      Size.fromHeight((Get.context!.orientation == Orientation.landscape && Platform.isAndroid ? 55 : 75) *
          ss.settings.avatarScale.value);
}

class _UnreadIcon extends StatefulWidget {
  const _UnreadIcon({required this.controller});

  final ConversationViewController controller;

  @override
  State<StatefulWidget> createState() => _UnreadIconState();
}

class _UnreadIconState extends OptimizedState<_UnreadIcon> {
  late final StreamSubscription<Query<Chat>> sub;
  bool hasStream = false;

  @override
  void dispose() {
    if (!kIsWeb && hasStream) sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3.0, right: 3),
          child: Obx(() {
            final icon = widget.controller.inSelectMode.value ? CupertinoIcons.xmark : CupertinoIcons.back;
            return Text(
              String.fromCharCode(icon.codePoint),
              style: TextStyle(
                fontFamily: icon.fontFamily,
                package: icon.fontPackage,
                fontSize: 36,
                color: context.theme.colorScheme.primary,
              ),
            );
          }),
        ),
        const SizedBox(width: 2),
        Obx(() {
          final _count = widget.controller.inSelectMode.value ? widget.controller.selected.length : GlobalChatService.unreadCount.value;
          if (_count == 0) return const SizedBox.shrink();
          return Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Container(
                  height: 25.0,
                  width: 25.0,
                  constraints: const BoxConstraints(minWidth: 20),
                  decoration: BoxDecoration(
                    color: context.theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  alignment: Alignment.center,
                  child: Padding(
                    padding: _count > 99 ? const EdgeInsets.symmetric(horizontal: 2.5) : EdgeInsets.zero,
                    child: Text(
                      _count.toString(),
                      style: context.textTheme.bodyMedium!.copyWith(
                          color: context.theme.colorScheme.onPrimary,
                          fontSize: _count > 99
                              ? context.textTheme.bodyMedium!.fontSize! - 1.0
                              : context.textTheme.bodyMedium!.fontSize),
                    ),
                  )));
        }),
      ],
    );
  }
}

class _ChatIconAndTitle extends CustomStateful<ConversationViewController> {
  const _ChatIconAndTitle({required super.parentController});

  @override
  State<StatefulWidget> createState() => _ChatIconAndTitleState();
}

class _ChatIconAndTitleState extends CustomState<_ChatIconAndTitle, void, ConversationViewController> {
  String title = "Unknown";
  late final StreamSubscription sub;
  String? cachedDisplayName = "";
  List<Handle> cachedParticipants = [];
  late String cachedGuid;

  late StreamSubscription sub2;

  @override
  void initState() {
    super.initState();
    sub2 = controller.suggestedContact.listen((c) {
      setState(() {
        cachedDisplayName = controller.chat.displayName;
        cachedParticipants = controller.chat.handles;
        title = controller.chat.getTitle();
        cachedGuid = controller.chat.guid;
      });
    });

    tag = controller.chat.guid;
    // keep controller in memory since the widget is part of a list
    // (it will be disposed when scrolled out of view)
    forceDelete = false;
    cachedDisplayName = controller.chat.displayName;
    cachedParticipants = controller.chat.handles;
    title = controller.chat.getTitle();
    cachedGuid = controller.chat.guid;

    // run query after render has completed
    if (!kIsWeb) {
      updateObx(() {
        final titleQuery = Database.chats.query(Chat_.guid.equals(controller.chat.guid)).watch();
        sub = titleQuery.listen((Query<Chat> query) async {
          final chat = await runAsync(() {
            final cquery = Database.chats.query(Chat_.guid.equals(cachedGuid)).build();
            return cquery.findFirst();
          });

          // If we don't find a chat, return
          if (chat == null) return;

          // check if we really need to update this widget
          if (chat.displayName != cachedDisplayName || chat.handles.length != cachedParticipants.length) {
            final newTitle = chat.getTitle();
            if (newTitle != title) {
              setState(() {
                title = newTitle;
              });
            }
          }
          cachedDisplayName = chat.displayName;
          cachedParticipants = chat.handles;
        });
      });
    } else {
      sub = WebListeners.chatUpdate.listen((chat) {
        if (chat.guid == controller.chat.guid) {
          // check if we really need to update this widget
          if (chat.displayName != cachedDisplayName || chat.participants.length != cachedParticipants.length) {
            final newTitle = chat.getTitle();
            if (newTitle != title) {
              setState(() {
                title = newTitle;
              });
            }
          }
          cachedDisplayName = chat.displayName;
          cachedParticipants = chat.participants;
        }
      });
    }
  }

  @override
  void dispose() {
    sub.cancel();
    sub2.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hideInfo = ss.settings.redactedMode.value && ss.settings.hideContactInfo.value;
    String _title = title;
    if (hideInfo) {
      _title = controller.chat.participants.length > 1 ? "Group Chat" : controller.chat.participants[0].fakeName;
    }
    final children = [
      IgnorePointer(
        ignoring: true,
        child: ContactAvatarGroupWidget(
          chat: controller.chat,
          size: 54,
        ),
      ),
      const SizedBox(height: 5, width: 5),
      Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: ns.width(context) / 2.5,
          ),
          child: RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            text: TextSpan(
              style: context.theme.textTheme.bodyMedium,
              children: MessageHelper.buildEmojiText(
                _title,
                context.theme.textTheme.bodyMedium!,
              ),
            ),
          ),
        ),
        Icon(
          CupertinoIcons.chevron_right,
          size: context.theme.textTheme.bodyMedium!.fontSize!,
          color: context.theme.colorScheme.outline,
        ),
      ]),
    ];

    if (context.orientation == Orientation.landscape && Platform.isAndroid) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: children,
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: children,
      );
    }
  }
}
