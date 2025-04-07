import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/layouts/settings/pages/misc/shared_streams_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/profile/profile_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/scheduling/scheduled_messages_panel.dart';
import 'package:bluebubbles/app/layouts/settings/pages/server/server_management_panel.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/helpers/ui/facetime_helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Notification;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;
import 'package:get/get.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path/path.dart';
import 'package:synchronized/synchronized.dart';
import 'package:timezone/timezone.dart';
import 'package:universal_html/html.dart' hide File, Platform, Navigator;
import 'package:universal_io/io.dart';
import 'package:window_manager/window_manager.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;

NotificationsService notif = Get.isRegistered<NotificationsService>() ? Get.find<NotificationsService>() : Get.put(NotificationsService());

class NotificationsService extends GetxService {
  static const String NEW_MESSAGE_CHANNEL = "com.bluebubbles.new_messages";
  static const String ERROR_CHANNEL = "com.bluebubbles.errors";
  static const String SHARED_STREAMS_CHANNEL = "com.bluebubbles.sharedstreams";
  static const String REMINDER_CHANNEL = "com.bluebubbles.reminders";
  static const String FACETIME_CHANNEL = "com.bluebubbles.incoming_facetimes";
  static const String FOREGROUND_SERVICE_CHANNEL = "com.bluebubbles.foreground_service";

  static const String NEW_MESSAGE_TAG = "com.bluebubbles.messaging.NEW_MESSAGE_NOTIFICATION";
  static const String NEW_FACETIME_TAG = "com.bluebubbles.messaging.NEW_FACETIME_NOTIFICATION";

  final FlutterLocalNotificationsPlugin flnp = FlutterLocalNotificationsPlugin();
  StreamSubscription? countSub;
  int currentCount = 0;

  /// For desktop use only
  static LocalNotification? allToast;
  static LocalNotification? failedToast;
  static LocalNotification? socketToast;
  static LocalNotification? aliasesToast;
  static Map<String, List<LocalNotification>> notifications = {};
  static Map<String, LocalNotification> facetimeNotifications = {};
  static Map<String, int> notificationCounts = {};
  static final Lock _lock = Lock();

  /// If more than [maxChatCount] chats have notifications, all notifications will be grouped into one
  static const maxChatCount = 2;
  static const maxLines = 4;

  bool get hideContent => ss.settings.hideTextPreviews.value;

  Future<void> init() async {
    if (!kIsWeb && !kIsDesktop) {
      const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('ic_stat_icon');
      const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
      await flnp.initialize(initializationSettings, onDidReceiveNotificationResponse: (NotificationResponse? response) {
        if (response?.payload != null) {
          intents.openChat(response!.payload);
        }
      });
      final details = await flnp.getNotificationAppLaunchDetails();
      if (details != null && details.didNotificationLaunchApp && details.notificationResponse?.payload != null) {
        intents.openChat(details.notificationResponse!.payload!);
      }
      // create notif channels
      createNotificationChannel(
        NEW_MESSAGE_CHANNEL,
        "New Messages",
        "Displays all received new messages",
      );
      createNotificationChannel(
        ERROR_CHANNEL,
        "Errors",
        "Displays message send failures, connection failures, and more",
      );
      createNotificationChannel(
        SHARED_STREAMS_CHANNEL, 
        "Shared Albums", 
        "Displays invitations and updates for shared albums."
      );
      createNotificationChannel(
        REMINDER_CHANNEL,
        "Message Reminders",
        "Displays message reminders set through the app",
      );
      createNotificationChannel(
        FACETIME_CHANNEL,
        "Incoming FaceTimes",
        "Displays incoming FaceTimes detected by the server",
      );
      createNotificationChannel(
        FOREGROUND_SERVICE_CHANNEL,
        "Foreground Service",
        "Allows BlueBubbles to stay open in the background for notifications if FCM is not being used",
      );
    }

    // watch for new messages and handle the notification
    if (!kIsWeb) {
      final countQuery = (Database.messages.query()..order(Message_.id, flags: Order.descending)).watch(triggerImmediately: true);
      countSub = countQuery.listen((event) {
        if (chats.restoring) return;
        if (!ss.settings.finishedSetup.value) return;
        final newCount = event.count();
        final activeChatFetching = cm.activeChat != null ? ms(cm.activeChat!.chat.guid).isFetching : false;
        if (ls.isAlive && (!sync.isIncrementalSyncing.value && !kIsDesktop) && !activeChatFetching && newCount > currentCount && currentCount != 0) {
          event.limit = newCount - currentCount;
          final messages = event.find();
          event.limit = 0;
          for (Message message in messages) {
            if (message.chat.target == null) continue;
            message.handle = message.getHandle();
            message.attachments = List<Attachment>.from(message.dbAttachments);
          }
          if (kIsDesktop && messages.length > 1) {
            MessageHelper.handleSummaryNotification(messages, findExisting: false);
          } else {
            for (Message message in messages) {
              MessageHelper.handleNotification(message, message.chat.target!, findExisting: false);
            }
          }
        }
        currentCount = newCount;
      });
    } else {
      countSub = WebListeners.newMessage.listen((tuple) {
        final activeChatFetching = cm.activeChat != null ? ms(cm.activeChat!.chat.guid).isFetching : false;
        if (ls.isAlive && !activeChatFetching && tuple.item2 != null) {
          MessageHelper.handleNotification(tuple.item1, tuple.item2!, findExisting: false);
        }
      });
    }
  }

  @override
  void onClose() {
    countSub?.cancel();
    super.onClose();
  }

  Future<void> createNotificationChannel(String channelID, String channelName, String channelDescription) async {
    await mcs.invokeMethod("create-notification-channel", {
      "channel_name": channelName,
      "channel_description": channelDescription,
      "channel_id": channelID,
    });
  }

  Future<void> createReminder(Chat? chat, Message? message, DateTime time, {String? chatTitle, String? messageText}) async {
    await flnp.zonedSchedule(
      Random().nextInt(9998) + 50000,
      chatTitle ?? 'Reminder: ${chat!.getTitle()}',
      messageText ?? (hideContent ? "iMessage" : MessageHelper.getNotificationText(message!)),
      TZDateTime.from(time, local),
      NotificationDetails(
        android: AndroidNotificationDetails(
          REMINDER_CHANNEL,
          'Reminders',
          channelDescription: 'Message reminder notifications',
          priority: Priority.max,
          importance: Importance.max,
          color: HexColor("4990de"),
        ),
      ),
      payload: "${time.millisecondsSinceEpoch}",
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> createNotification(Chat chat, Message message) async {
    if (chat.shouldMuteNotification(message) || message.isFromMe!) return;
    final isGroup = chat.isGroup;
    final guid = chat.guid;
    final contactName = message.handle?.displayName ?? "Unknown";
    final title = isGroup ? chat.getTitle() : contactName;
    final text = hideContent ? "iMessage" : MessageHelper.getNotificationText(message);
    final isReaction = !isNullOrEmpty(message.associatedMessageGuid);
    final personIcon = (await rootBundle.load("assets/images/person64.png")).buffer.asUint8List();

    Uint8List chatIcon = await avatarAsBytes(chat: chat, quality: 256);
    Uint8List contactIcon = message.isFromMe!
        ? personIcon
        : await avatarAsBytes(
            participantsOverride: !chat.isGroup ? null : chat.participants.where((e) => e.address == message.handle!.address).toList(),
            chat: chat,
            quality: 256);
    if (chatIcon.isEmpty) {
      chatIcon = personIcon;
    }
    if (contactIcon.isEmpty) {
      contactIcon = personIcon;
    }

    if (kIsWeb && Notification.permission == "granted") {
      final notif = Notification(title, body: text, icon: "data:image/png;base64,${base64Encode(chatIcon)}", tag: message.guid);
      notif.onClick.listen((event) async {
        await intents.openChat(guid);
      });
    } else if (kIsDesktop) {
      _lock.synchronized(() async => await showDesktopNotif(message, text, chat, guid, title, contactName, isGroup, isReaction));
    } else {
      await mcs.invokeMethod("create-incoming-message-notification", {
        "channel_id": NEW_MESSAGE_CHANNEL,
        "chat_id": chat.id,
        "chat_guid": guid,
        "chat_is_group": isGroup,
        "chat_title": title,
        "chat_icon": isGroup ? chatIcon : contactIcon,
        "contact_name": contactName,
        "contact_avatar": contactIcon,
        "message_guid": message.guid!,
        "message_text": text,
        "message_date": message.dateCreated!.millisecondsSinceEpoch,
        "message_is_from_me": false,
      });
    }
  }

  Future<void> createIncomingFaceTimeNotification(String? callUuid, String caller, String link, Uint8List? chatIcon) async {
    // Set some notification defaults
    String title = caller;
    String text = "${callUuid == null ? "Incoming" : "Answer"} FaceTime Call";
    chatIcon ??= (await rootBundle.load("assets/images/person64.png")).buffer.asUint8List();

    if (kIsWeb && Notification.permission == "granted") {
      final notif = Notification(title, body: text, icon: "data:image/png;base64,${base64Encode(chatIcon)}", tag: callUuid);
      if (callUuid != null) {
        notif.onClick.listen((event) async {
          await intents.answerFaceTime(callUuid);
        });
      }
    } else if (kIsDesktop) {
      _lock.synchronized(() async => await showPersistentDesktopFaceTimeNotif(callUuid, caller, chatIcon));
    } else {
      final numeric = callUuid?.numericOnly();
      await mcs.invokeMethod("create-incoming-facetime-notification", {
        "channel_id": FACETIME_CHANNEL,
        "notification_id": numeric != null ? int.parse(numeric.substring(0, min(8, numeric.length))) : Random().nextInt(9998) + 1,
        "title": title,
        "body": text,
        "caller_avatar": chatIcon,
        "caller": caller,
        "call_uuid": callUuid,
        "link": link,
        "name": ss.settings.userName.value == "You" ? (await api.getHandles(state: pushService.state)).first.replaceFirst("tel:", "").replaceFirst("mailto:", "") : ss.settings.userName.value,
      });
    }
  }

  Future<void> clearFaceTimeNotification(String callUuid) async {
    if (kIsDesktop) {
      await clearDesktopFaceTimeNotif(callUuid);
    } else if (!kIsWeb) {
      final numeric = callUuid.numericOnly();
      mcs.invokeMethod(
        "delete-notification",
        {
          "notification_id": int.parse(numeric.substring(0, min(8, numeric.length))),
          "tag": NEW_FACETIME_TAG
        }
      );
    }
  }

  Future<void> showPersistentDesktopFaceTimeNotif(String? callUuid, String caller, Uint8List? avatar) async {
    List<String> actions = ["Answer", "Ignore"];
    List<LocalNotificationAction> nActions = actions.map((String a) => LocalNotificationAction(text: a)).toList();
    LocalNotification? toast;
    String? path;

    if (avatar != null) {
      Uint8List? _avatar = await clip(avatar, size: 256, circle: true);
      if (_avatar != null) {
        // Create a temp file with the avatar
        path = join(fs.appDocDir.path, "temp", "${randomString(8)}.png");
        await File(path).create(recursive: true);
        await File(path).writeAsBytes(_avatar);
      }
    }

    toast = LocalNotification(
      imagePath: path,
      title: caller,
      body: "Incoming FaceTime Call",
      duration: LocalNotificationDuration.long,
      actions: callUuid == null ? null : nActions,
    );

    toast.onClick = () async {
      await windowManager.show();
    };

    if (callUuid != null) {
      toast.onClickAction = (index) async {
        if (actions[index] == "Answer") {
          await windowManager.show();
          await intents.answerFaceTime(callUuid);
        } else {
          hideFaceTimeOverlay(callUuid);
          await toast?.close();
        }
      };
    }

    toast.onClose = (reason) async {
      if (reason == LocalNotificationCloseReason.timedOut && faceTimeOverlays.containsKey(callUuid)) {
        await toast?.show();
      }
    };

    if (facetimeNotifications[callUuid ?? caller] != null) {
      await facetimeNotifications[callUuid ?? caller]?.close();
    }

    facetimeNotifications[callUuid ?? caller] = toast;

    await toast.show();
  }

  Future<void> clearDesktopFaceTimeNotif(String callerUuid) async {
    await facetimeNotifications[callerUuid]?.close();
    facetimeNotifications.remove(callerUuid);
  }

  Future<void> showDesktopNotif(Message message, String text, Chat chat, String guid, String title, String contactName, bool isGroup, bool isReaction) async {
    List<int> selectedIndices = ss.settings.selectedActionIndices;
    List<String> _actions = ss.settings.actionList;
    final papi = ss.settings.enablePrivateAPI.value;

    List<String> actions = _actions
        .whereIndexed((i, e) => selectedIndices.contains(i))
        .map((action) => action == "Mark Read"
            ? action
            : !isReaction && !message.isGroupEvent && papi
                ? ReactionTypes.reactionToEmoji[action]!
                : null)
        .whereNotNull()
        .toList();

    bool showMarkRead = actions.contains("Mark Read");

    List<LocalNotificationAction> nActions = actions.map((String a) => LocalNotificationAction(text: a)).toList();

    LocalNotification? toast;

    notifications.removeWhere((key, value) => value.isEmpty);
    notifications[guid] ??= [];
    notificationCounts[guid] = (notificationCounts[guid] ?? 0) + 1;

    Iterable<String> _chats = notifications.keys.toList();

    if (_chats.length > maxChatCount) {
      return await showSummaryNotifDesktop(notificationCounts.values.sum, _chats, showMarkRead);
    }

    Uint8List avatar = await avatarAsBytes(chat: chat, quality: 256);

    // Create a temp file with the avatar
    String path = join(fs.appDocDir.path, "temp", "${randomString(8)}.png");
    await File(path).create(recursive: true);
    await File(path).writeAsBytes(avatar);

    const int charsPerLineEst = 30;

    bool combine = false;
    bool multiple = false;
    String? sender;
    RegExp re = RegExp("\n");
    if (isGroup && !message.isGroupEvent && !isReaction) {
      Contact? contact = message.handle != null ? cs.getContact(message.handle!.address) : null;
      sender = contact?.displayName.split(" ")[0];
    }
    int newLines = (((sender == null ? 0 : "$sender: ".length) + text.length) / charsPerLineEst).ceil() + re.allMatches(text).length;
    String body = "";
    int count = 0;
    for (LocalNotification _toast in notifications[guid]!) {
      if (newLines + ((_toast.body ?? "").length ~/ charsPerLineEst).ceil() + re.allMatches("${_toast.body}\n").length <= maxLines) {
        if (isGroup && count == 0 && notifications[guid]!.isNotEmpty && _toast.title.length > "$title: ".length) {
          String name = _toast.title.substring("$title: ".length).split(" ")[0];
          body += "$name: ";
        }
        body += "${_toast.body}\n";
        count += int.tryParse(_toast.subtitle ?? "1") ?? 1;
        multiple = true;
      } else {
        combine = true;
      }
    }
    if (isGroup && sender != null) {
      body += "$sender: ";
    }
    body += text;
    count += 1;

    if (!combine && (notificationCounts[guid]! == count)) {
      bool toasted = false;
      for (LocalNotification _toast in List.from(notifications[guid]!)) {
        if (_toast.body != body) {
          await _toast.close();
        } else {
          toasted = true;
        }
      }
      if (toasted) return;
      toast = LocalNotification(
        imagePath: path,
        title: isGroup && count == 1 && !isReaction && !message.isGroupEvent ? "$title: $contactName" : title,
        subtitle: "$count",
        body: sender != null && count == 1 ? body.split("$sender: ")[1] : body,
        duration: LocalNotificationDuration.long,
        actions: notifications[guid]!.isNotEmpty
            ? showMarkRead
                ? [LocalNotificationAction(text: "Mark ${notificationCounts[guid]!} Messages Read")]
                : []
            : nActions,
      );
      notifications[guid]!.add(toast);

      toast.onClick = () async {
        notifications[guid]!.remove(toast);
        notificationCounts[guid] = 0;

        Chat? chat = Chat.findOne(guid: guid);
        if (chat == null) {
          await windowManager.show();
          return;
        }

        if (ChatManager().activeChat?.chat.guid != guid && Get.context != null) {
          ns.pushAndRemoveUntil(
            Get.context!,
            ConversationView(chat: chat),
            (route) => route.isFirst,
          );
        }

        await windowManager.show();
      };

      toast.onClickAction = (index) async {
        notifications[guid]!.remove(toast);
        notificationCounts[guid] = 0;

        Chat? chat = Chat.findOne(guid: guid);
        if (chat == null) return;
        if (actions[index] == "Mark Read" || multiple) {
          chat.toggleHasUnread(false);
          EventDispatcher().emit('refresh', null);
        } else if (ss.settings.enablePrivateAPI.value) {
          String reaction = ReactionTypes.emojiToReaction[actions[index]]!;
          outq.queue(
            OutgoingItem(
              type: QueueType.sendMessage,
              chat: chat,
              message: Message(
                associatedMessageGuid: message.guid,
                associatedMessageType: reaction,
                associatedMessagePart: 0,
                dateCreated: DateTime.now(),
                hasAttachments: false,
                isFromMe: true,
                handleId: 0,
              ),
              selected: message,
              reaction: reaction,
            ),
          );
        }

        if (await File(path).exists()) {
          await File(path).delete();
        }
      };

      toast.onClose = (reason) async {
        notifications[guid]?.remove(toast);
        if (reason != LocalNotificationCloseReason.unknown) {
          notificationCounts[guid] = 0;
        }
        if (await File(path).exists()) {
          await File(path).delete();
        }
      };
    } else {
      String body = "${notificationCounts[guid]!} messages";

      bool toasted = false;
      for (LocalNotification _toast in List.from(notifications[guid]!)) {
        if (_toast.body != body) {
          await _toast.close();
        } else {
          toasted = true;
        }
      }
      if (toasted) return;

      notifications[guid] = [];
      toast = LocalNotification(
        imagePath: path,
        title: title,
        body: "${notificationCounts[guid]!} messages",
        duration: LocalNotificationDuration.short,
        actions: showMarkRead ? [LocalNotificationAction(text: "Mark Read")] : [],
      );
      notifications[guid]!.add(toast);

      toast.onClick = () async {
        notifications[guid]!.remove(toast);
        notificationCounts[guid] = 0;

        // Show window and open the right chat
        Chat? chat = Chat.findOne(guid: guid);
        if (chat == null) {
          await windowManager.show();
          return;
        }

        if (ChatManager().activeChat?.chat.guid != guid && Get.context != null) {
          ns.pushAndRemoveUntil(
            Get.context!,
            ConversationView(chat: chat),
            (route) => route.isFirst,
          );
        }

        await windowManager.show();

        if (await File(path).exists()) {
          await File(path).delete();
        }
      };

      toast.onClickAction = (index) async {
        notifications[guid]!.remove(toast);
        notificationCounts[guid] = 0;

        Chat? chat = Chat.findOne(guid: guid);
        if (chat == null) {
          await windowManager.show();
          return;
        }

        chat.toggleHasUnread(false);
        EventDispatcher().emit('refresh', null);

        await windowManager.show();

        if (await File(path).exists()) {
          await File(path).delete();
        }
      };

      toast.onClose = (reason) async {
        notifications[guid]!.remove(toast);
        if (reason != LocalNotificationCloseReason.unknown) {
          notificationCounts[guid] = 0;
          notifications.remove(guid);
        }
        if (await File(path).exists()) {
          await File(path).delete();
        }
      };
    }

    await toast.show();
  }

  Future<void> showSummaryNotifDesktop(int count, Iterable<String> _chats, bool showMarkRead) async {
    for (String chat in _chats) {
      for (LocalNotification _toast in (notifications[chat] ?? [])) {
        await _toast.close();
      }
      notifications[chat] = [];
    }

    await allToast?.close();

    String title = "$count messages";
    String body = "from ${_chats.length} chat${_chats.length == 1 ? "" : "s"}";

    // Don't create notification for no reason
    if (allToast?.title == title && allToast?.body == body) return;

    allToast = LocalNotification(
      title: title,
      body: body,
      duration: LocalNotificationDuration.short,
      actions: showMarkRead ? [LocalNotificationAction(text: "Mark All Read")] : [],
    );

    allToast!.onClick = () async {
      notifications = {};
      notificationCounts = {};
      await windowManager.show();
    };

    allToast!.onClickAction = (index) async {
      notifications = {};
      notificationCounts = {};

      chats.markAllAsRead();
    };

    allToast!.onClose = (reason) {
      if (reason != LocalNotificationCloseReason.unknown) {
        notifications = {};
        notificationCounts = {};
      }
    };

    await allToast!.show();
  }

  Future<void> createSocketError() async {
    const title = 'Could not connect';
    const subtitle = 'Your server may be offline!';
    if (kIsDesktop) {
      if (socketToast != null) return;
      socketToast = LocalNotification(
        title: title,
        body: subtitle,
        actions: [],
      );

      socketToast!.onClick = () async {
        socketToast = null;
        await windowManager.show();
        Navigator.of(Get.context!).push(
          ThemeSwitcher.buildPageRoute(
            builder: (BuildContext context) {
              return ServerManagementPanel();
            },
          ),
        );
      };

      await socketToast!.show();
      return;
    } else {
      final notifs = await flnp.getActiveNotifications();
      if (notifs.firstWhereOrNull((element) => element.id == -2) != null) return;
      await flnp.show(
        -2,
        title,
        subtitle,
        NotificationDetails(
          android: AndroidNotificationDetails(
            ERROR_CHANNEL,
            'Errors',
            channelDescription: 'Displays message send failures, connection failures, and more',
            priority: Priority.max,
            importance: Importance.max,
            color: HexColor("4990de"),
            ongoing: true,
            onlyAlertOnce: true,
          ),
        ),
      );
    }
  }

  Future<void> createMissedCallNotification(String name, String callUuid) async {
    const text = "Missed FaceTime Call";

    if (kIsDesktop) {
      if (aliasesToast?.body == text) {
        return;
      } else {
        await aliasesToast?.close();
      }

      aliasesToast = LocalNotification(
        title: name,
        body: text,
        actions: [],
      );

      aliasesToast!.onClick = () async {
        aliasesToast = null;
        await windowManager.show();
      };

      await aliasesToast!.show();
    } else {
      final numeric = callUuid.numericOnly();
      var notifId = int.parse(numeric.substring(0, min(8, numeric.length))) + 2;


      await mcs.invokeMethod("create-missed-facetime-notification", {
        "channel_id": FACETIME_CHANNEL,
        "notification_id": notifId,
        "call_uuid": callUuid,
        "title": name,
      });
    }
  }

  Future<void> createAliasesRemovedNotification(List<String> aliases) async {
    const title = "iMessage alias deregistered!";
    const notifId = -3;
    final text = aliases.length == 1 ? "${aliases[0]} has been deregistered!" : "The following aliases have been deregistered:\n${aliases.join("\n")}";

    if (kIsDesktop) {
      if (aliasesToast?.body == text) {
        return;
      } else {
        await aliasesToast?.close();
      }

      aliasesToast = LocalNotification(
        title: title,
        body: text,
        actions: [],
      );

      aliasesToast!.onClick = () async {
        aliasesToast = null;
        await windowManager.show();
      };

      await aliasesToast!.show();
    } else {
        final notifs = await flnp.getActiveNotifications();

        //Already have this notification
        if (notifs.firstWhereOrNull((n) => n.id == notifId && n.body == text) != null) {
          return;
        }

        await flnp.show(
          notifId,
          title,
          text,
          NotificationDetails(
            android: AndroidNotificationDetails(
              ERROR_CHANNEL,
              'Errors',
              channelDescription: 'Displays message send failures, connection failures, and more',
              priority: Priority.max,
              importance: Importance.max,
              color: HexColor("4990de"),
              ongoing: false,
              onlyAlertOnce: false,
              styleInformation: const BigTextStyleInformation('')
            ),
          ),
        );
    }
  }

  Future<void> createFailedToSend(Chat chat, {bool scheduled = false}) async {
    final title = 'Failed to send${scheduled ? " scheduled" : ""} message';
    final subtitle = scheduled ? 'Tap to open scheduled messages list' : 'Tap to see more details or retry';
    if (kIsDesktop) {
      failedToast = LocalNotification(
        title: title,
        body: subtitle,
        actions: [],
      );

      failedToast!.onClick = () async {
        failedToast = null;
        await windowManager.show();
        if (scheduled) {
          Navigator.of(Get.context!).push(
            ThemeSwitcher.buildPageRoute(
              builder: (BuildContext context) {
                return ScheduledMessagesPanel();
              },
            ),
          );
        } else {
          bool chatIsOpen = cm.activeChat?.chat.guid == chat.guid;
          if (!chatIsOpen) {
            ns.pushAndRemoveUntil(
              Get.context!,
              ConversationView(
                chat: chat,
              ),
              (route) => route.isFirst,
            );
          }
        }
      };

      await failedToast!.show();
      return;
    }
    await flnp.show(
      (chat.id!  + 75000) * (scheduled ? -1 : 1),
      title,
      subtitle,
      NotificationDetails(
        android: AndroidNotificationDetails(
          ERROR_CHANNEL,
          'Errors',
          channelDescription: 'Displays message send failures, connection failures, and more',
          priority: Priority.max,
          importance: Importance.max,
          color: HexColor("4990de"),
        ),
      ),
      payload: chat.guid + (scheduled ? "-scheduled" : ""),
    );
  }

  void clearRegisterFailed() {
    if (Platform.isAndroid) {
      mcs.invokeMethod(
        "delete-notification",
        {
          "notification_id": -1 - 50,
        }
      );
    }
  }

  Future<void> createRegisterFailed(bool loggedOut) async {
    final title = loggedOut ? 'Logged out by Apple!' : 'Failed to renew registration!';
    const subtitle =
        'You can no longer send or receive iMessages. Tap for more info.';
    if (kIsDesktop) {
      failedToast = LocalNotification(
        title: title,
        body: subtitle,
        actions: [],
      );

      failedToast!.onClick = () async {
        failedToast = null;
        await windowManager.show();
        if (ss.settings.finishedSetup.value) {
          ns.pushLeft(Get.context!, ProfilePanel());
        }
      };

      await failedToast!.show();
      return;
    }
    await flnp.show(
      -1 - 50 /* OB */,
      title,
      subtitle,
      NotificationDetails(
        android: AndroidNotificationDetails(
          ERROR_CHANNEL,
          'Errors',
          channelDescription:
              'Displays message send failures, connection failures, and more',
          priority: Priority.max,
          importance: Importance.max,
          color: HexColor("4990de"),
        ),
      ),
      payload: loggedOut ? "" : "-51"
    );
  }

  Future<void> createSubscriptionFailed() async {
    const title = "Your subscription is no longer active!";
    const subtitle =
        "Your device will be given to someone else soon, and iMessage will no longer be activated.";
    if (kIsDesktop) {
      failedToast = LocalNotification(
        title: title,
        body: subtitle,
        actions: [],
      );

      failedToast!.onClick = () async {
        failedToast = null;
        await windowManager.show();
        if (ss.settings.finishedSetup.value) {
          ns.pushLeft(Get.context!, ProfilePanel());
        }
      };

      await failedToast!.show();
      return;
    }
    await flnp.show(
      -1 - 50 /* OB */,
      title,
      subtitle,
      NotificationDetails(
        android: AndroidNotificationDetails(
          ERROR_CHANNEL,
          'Errors',
          channelDescription:
              'Displays message send failures, connection failures, and more',
          priority: Priority.max,
          importance: Importance.max,
          color: HexColor("4990de"),
        ),
      ),
      payload: "-51"
    );
  }

  Future<void> createInvitation(api.SharedAlbum album) async {
    const title = "Shared albums";
    final subtitle =
        "${album.fullname} invited you to join \"${album.name}\"";
    if (kIsDesktop) {
      failedToast = LocalNotification(
        title: title,
        body: subtitle,
        actions: [],
      );

      failedToast!.onClick = () async {
        failedToast = null;
        await windowManager.show();
        if (ss.settings.finishedSetup.value) {
          ns.pushLeft(Get.context!, SharedStreamsPanel());
        }
      };

      await failedToast!.show();
      return;
    }
    await flnp.show(
      -2 - 50 /* OB */,
      title,
      subtitle,
      NotificationDetails(
        android: AndroidNotificationDetails(
          SHARED_STREAMS_CHANNEL,
          'Shared Albums',
          channelDescription:
              'Displays invitations and updates for shared albums.',
          priority: Priority.max,
          importance: Importance.max,
          color: HexColor("4990de"),
        ),
      ),
      payload: "-52"
    );
  }

  Future<void> clearSocketError() async {
    if (kIsDesktop) {
      await socketToast?.close();
      socketToast = null;
      return;
    }
    await flnp.cancel(-2);
  }

  Future<void> clearFailedToSend(int id) async {
    if (kIsDesktop) {
      await failedToast?.close();
      failedToast = null;
      return;
    }
    await flnp.cancel(id);
  }

  Future<void> clearDesktopNotificationsForChat(String chatGuid) async {
    await _lock.synchronized(() async {
      if (!notifications.containsKey(chatGuid)) return;
      List<LocalNotification> toasts = [...notifications[chatGuid]!];
      for (LocalNotification toast in toasts) {
        await toast.close();
      }
      notifications.remove(chatGuid);
      notificationCounts[chatGuid] = 0;
    });
  }
}
