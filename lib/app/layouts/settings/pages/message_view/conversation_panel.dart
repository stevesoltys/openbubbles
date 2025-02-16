import 'package:animated_size_and_fade/animated_size_and_fade.dart';
import 'package:audio_waveforms/audio_waveforms.dart' as aw;
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/reaction/reaction.dart';
import 'package:bluebubbles/app/layouts/settings/pages/message_view/message_options_order_panel.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/next_button.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart' hide PlatformFile;
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Response;
import 'package:path/path.dart';
import 'package:universal_io/io.dart';

class ConversationPanel extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends OptimizedState<ConversationPanel> {
  final RxnBool gettingIcons = RxnBool(null);
  final RxBool playingSendSound = false.obs;
  final RxBool playingReceiveSound = false.obs;
  late final dynamic sendPlayer;
  late final dynamic receivePlayer;

  bool sendPrepared = false;
  bool receivePrepared = false;

  @override
  void initState() {
    super.initState();

    if (kIsDesktop) {
      sendPlayer = Player();
      receivePlayer = Player();
      (sendPlayer as Player).stream.playing.listen((value) => playingSendSound.value = value);
      (receivePlayer as Player).stream.playing.listen((value) => playingReceiveSound.value = value);
    } else {
      sendPlayer = aw.PlayerController();
      receivePlayer = aw.PlayerController();
      (sendPlayer as aw.PlayerController).onPlayerStateChanged.listen((value) => playingSendSound.value = value == aw.PlayerState.playing);
      (receivePlayer as aw.PlayerController).onPlayerStateChanged.listen((value) => playingReceiveSound.value = value == aw.PlayerState.playing);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScaffold(
      title: "Conversations",
      initialHeader: "Customization",
      iosSubtitle: iosSubtitle,
      materialSubtitle: materialSubtitle,
      tileColor: tileColor,
      headerColor: headerColor,
      bodySlivers: [
        SliverList(
          delegate: SliverChildListDelegate(
            <Widget>[
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) {
                          ss.settings.showDeliveryTimestamps.value = val;
                          saveSettings();
                        },
                        initialVal: ss.settings.showDeliveryTimestamps.value,
                        title: "Show Delivery Timestamps",
                        backgroundColor: tileColor,
                      )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) {
                          ss.settings.recipientAsPlaceholder.value = val;
                          saveSettings();
                        },
                        initialVal: ss.settings.recipientAsPlaceholder.value,
                        title: "Show Chat Name as Placeholder",
                        subtitle: "Changes the default hint text in the message box to display the recipient name",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) {
                          ss.settings.alwaysShowAvatars.value = val;
                          saveSettings();
                        },
                        initialVal: ss.settings.alwaysShowAvatars.value,
                        title: "Show Avatars in DM Chats",
                        subtitle: "Shows contact avatars in direct messages rather than just in group messages",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  if (!kIsWeb && !kIsDesktop)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.smartReply.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.smartReply.value,
                          title: "Smart Suggestions",
                          subtitle:
                              "Shows smart reply suggestions above the message text field and detects various interactive content in message text",
                          backgroundColor: tileColor,
                          isThreeLine: true,
                        )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) {
                          ss.settings.repliesToPrevious.value = val;
                          saveSettings();
                        },
                        initialVal: ss.settings.repliesToPrevious.value,
                        title: "Show Replies To Previous Message",
                        subtitle: "Shows replies to the previous message in the thread rather than the original",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  if (!kIsWeb)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb)
                    SettingsTile(
                      title: "Message Options Order",
                      subtitle:
                      "Set the order for the options when ${ss.settings.doubleTapForDetails.value ? "double-tapping" : "pressing and holding"} a message",
                      onTap: () {
                        ns.pushSettings(
                          context,
                          MessageOptionsOrderPanel(),
                        );
                      },
                      trailing: const NextButton(),
                    ),
                  if (!kIsWeb && backend.getRemoteService() != null)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && backend.getRemoteService() != null)
                    SettingsTile(
                      title: "Sync Group Chat Icons",
                      trailing: Obx(() => gettingIcons.value == null
                          ? const SizedBox.shrink()
                          : gettingIcons.value == true
                              ? Container(
                                  constraints: const BoxConstraints(
                                    maxHeight: 20,
                                    maxWidth: 20,
                                  ),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                                  ))
                              : Icon(Icons.check, color: context.theme.colorScheme.outline)),
                      onTap: () async {
                        gettingIcons.value = true;
                        for (Chat c in chats.chats.where((c) => c.isGroup)) {
                          await Chat.getIcon(c, force: true);
                        }
                        gettingIcons.value = false;
                      },
                      subtitle: "Get iMessage group chat icons from the server",
                    ),
                  if (!kIsWeb && backend.getRemoteService() != null)
                    const SettingsSubtitle(
                      subtitle: "Note: Overrides any custom avatars set for group chats.",
                    ),
                  if (!kIsWeb)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.scrollToLastUnread.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.scrollToLastUnread.value,
                          title: "Store Last Read Message",
                          subtitle: "Remembers the last opened message and allows automatically scrolling back to it if out of view",
                          backgroundColor: tileColor,
                          isThreeLine: true,
                        )),
                  Obx(() => SettingsSwitch(
                      onChanged: (bool val) {
                        ss.settings.hideNamesForReactions.value = val;
                        ss.settings.saveOne("hideNamesForReactions");
                      },
                      initialVal: ss.settings.hideNamesForReactions.value,
                      title: "Hide Names in Reaction Details",
                      subtitle: "Enable this to hide names under participant avatars when you view a message's reactions",
                      backgroundColor: tileColor,
                    )),
                ],
              ),
              if (!kIsWeb)
                SettingsHeader(
                  iosSubtitle: iosSubtitle,
                  materialSubtitle: materialSubtitle,
                  text: "Sounds",
                ),
              if (!kIsWeb)
                Obx(
                  () => SettingsSection(
                    backgroundColor: tileColor,
                    children: [
                      SettingsTile(
                        title: "Download Sounds",
                        subtitle: "Downloads the official send/receive sounds",
                        onTap: () async {
                          showDialog(
                            context: context,
                            builder: (BuildContext context) {
                              return AlertDialog(
                                backgroundColor: context.theme.colorScheme.properSurface,
                                title: Text(
                                  "Downloading sounds...",
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
                          try {
                            final sendmsgaudio = await http.downloadFromUrl(
                                  "https://chatsupport.apple.com/WebAPI801/sound/send-message-audio.m4a",
                              progress: (current, total) {},
                            );
                            final recvmsgaudio = await http.downloadFromUrl(
                                  "https://chatsupport.apple.com/WebAPI801/sound/received-message-audio.m4a",
                              progress: (current, total) {},
                            );
                            String path = "${fs.appDocDir.path}/sounds/send-message-audio.m4a";
                            await File(path).create(recursive: true);
                            await File(path).writeAsBytes(sendmsgaudio.data!);
                            ss.settings.sendSoundPath.value = path;
                            String path2 = "${fs.appDocDir.path}/sounds/receive-message-audio.m4a";
                            await File(path2).create(recursive: true);
                            await File(path2).writeAsBytes(recvmsgaudio.data!);
                            ss.settings.receiveSoundPath.value = path2;
                            ss.saveSettings();
                            Get.back();
                          } catch (e, s) {
                            Get.back();
                            showSnackbar("Error", "Failed to fetch audio");
                            rethrow;
                          }
                        },
                      ),
                      SettingsTile(
                        title: "${ss.settings.sendSoundPath.value == null ? "Add" : "Change"} Send Sound",
                        subtitle: ss.settings.sendSoundPath.value != null
                            ? basename(ss.settings.sendSoundPath.value!).substring("send-".length)
                            : "Adds a sound to be played when sending a message",
                        onTap: () async {
                          FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio, withData: true);
                          if (result != null) {
                            PlatformFile platformFile = result.files.first;
                            String path = "${fs.appDocDir.path}/sounds/${"send-"}${platformFile.name}";
                            await File(path).create(recursive: true);
                            await File(path).writeAsBytes(platformFile.bytes!);
                            ss.settings.sendSoundPath.value = path;
                            ss.saveSettings();
                          }
                        },
                        trailing: (ss.settings.sendSoundPath.value == null)
                            ? const SizedBox.shrink()
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                      icon: playingSendSound.value
                                          ? Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.stop : Icons.stop_outlined)
                                          : Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.play : Icons.play_arrow_outlined),
                                      onPressed: () async {
                                        if (sendPlayer is Player) {
                                          final Player _sendPlayer = sendPlayer as Player;
                                          if (playingSendSound.value) {
                                            await _sendPlayer.stop();
                                          } else {
                                            await _sendPlayer.setVolume(ss.settings.soundVolume.value.toDouble());
                                            await _sendPlayer.open(Media(ss.settings.sendSoundPath.value!));
                                          }
                                        } else if (sendPlayer is aw.PlayerController) {
                                          final aw.PlayerController _sendPlayer = sendPlayer as aw.PlayerController;
                                          if (playingSendSound.value) {
                                            await _sendPlayer.pausePlayer();
                                          } else {
                                            if (!sendPrepared) {
                                              await _sendPlayer.preparePlayer(path: ss.settings.sendSoundPath.value!, volume: ss.settings.soundVolume.value.toDouble() / 100);
                                              sendPrepared = true;
                                            }
                                            await _sendPlayer.startPlayer(finishMode: aw.FinishMode.pause);
                                          }
                                        }
                                      }),
                                  IconButton(
                                    icon: Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.trash : Icons.delete_outline),
                                    onPressed: () async {
                                      File file = File(ss.settings.sendSoundPath.value!);
                                      if (await file.exists()) {
                                        await file.delete();
                                      }
                                      ss.settings.sendSoundPath.value = null;
                                      ss.saveSettings();
                                    },
                                  ),
                                ],
                              ),
                      ),
                      const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                      SettingsTile(
                        title: "${ss.settings.receiveSoundPath.value == null ? "Add" : "Change"} Receive Sound",
                        subtitle: ss.settings.receiveSoundPath.value != null
                            ? basename(ss.settings.receiveSoundPath.value!).substring("receive-".length)
                            : "Adds a sound to be played when receiving a message",
                        onTap: () async {
                          FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio, withData: true);
                          if (result != null) {
                            PlatformFile platformFile = result.files.first;
                            String path = "${fs.appDocDir.path}/sounds/${"receive-"}${platformFile.name}";
                            await File(path).create(recursive: true);
                            await File(path).writeAsBytes(platformFile.bytes!);
                            ss.settings.receiveSoundPath.value = path;
                            ss.saveSettings();
                          }
                        },
                        trailing: (ss.settings.receiveSoundPath.value == null)
                            ? const SizedBox.shrink()
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                      icon: playingReceiveSound.value
                                          ? Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.stop : Icons.stop_outlined)
                                          : Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.play : Icons.play_arrow_outlined),
                                      onPressed: () async {
                                        if (receivePlayer is Player) {
                                          final Player _receivePlayer = receivePlayer as Player;
                                          if (playingReceiveSound.value) {
                                            await _receivePlayer.stop();
                                          } else {
                                            await _receivePlayer.setVolume(ss.settings.soundVolume.value.toDouble());
                                            await _receivePlayer.open(Media(ss.settings.receiveSoundPath.value!));
                                          }
                                        } else if (receivePlayer is aw.PlayerController) {
                                          final aw.PlayerController _receivePlayer = receivePlayer as aw.PlayerController;
                                          if (playingReceiveSound.value) {
                                            await _receivePlayer.pausePlayer();
                                          } else {
                                            if (!receivePrepared) {
                                              await _receivePlayer.preparePlayer(path: ss.settings.receiveSoundPath.value!, volume: ss.settings.soundVolume.value / 100);
                                              receivePrepared = true;
                                            }
                                            await _receivePlayer.startPlayer(finishMode: aw.FinishMode.pause);
                                          }
                                        }
                                      }),
                                  IconButton(
                                    icon: Icon(ss.settings.skin.value == Skins.iOS ? CupertinoIcons.trash : Icons.delete_outline),
                                    onPressed: () async {
                                      File file = File(ss.settings.receiveSoundPath.value!);
                                      if (await file.exists()) {
                                        await file.delete();
                                      }
                                      ss.settings.receiveSoundPath.value = null;
                                      ss.saveSettings();
                                    },
                                  ),
                                ],
                              ),
                      ),
                      const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                      const SettingsTile(
                        title: "Send/Receive Sound Volume",
                        subtitle: "Controls the volume of the send and receive sounds",
                      ),
                      Obx(() => SettingsSlider(
                        startingVal: ss.settings.soundVolume.value.toDouble(),
                        min: 0,
                        max: 100,
                        divisions: 100,
                        formatValue: (val) => "${val.toInt()}",
                        update: (val) => ss.settings.soundVolume.value = val.toInt(),
                      )),
                    ],
                  ),
                ),
              SettingsHeader(
                iosSubtitle: iosSubtitle,
                materialSubtitle: materialSubtitle,
                text: "Gestures",
              ),
              SettingsSection(
                backgroundColor: tileColor,
                children: [
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.autoOpenKeyboard.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.autoOpenKeyboard.value,
                          title: "Auto-open Keyboard",
                          subtitle: "Automatically open the keyboard when entering a chat",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.swipeToCloseKeyboard.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.swipeToCloseKeyboard.value,
                          title: "Swipe Message Box to Close Keyboard",
                          subtitle: "Swipe down on the message box to hide the keyboard",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.swipeToOpenKeyboard.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.swipeToOpenKeyboard.value,
                          title: "Swipe Message Box to Open Keyboard",
                          subtitle: "Swipe up on the message box to show the keyboard",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.hideKeyboardOnScroll.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.hideKeyboardOnScroll.value,
                          title: "Hide Keyboard When Scrolling",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsWeb && !kIsDesktop)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.openKeyboardOnSTB.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.openKeyboardOnSTB.value,
                          title: "Open Keyboard After Tapping Scroll To Bottom",
                          backgroundColor: tileColor,
                        )),
                  if (!kIsWeb && !kIsDesktop)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) {
                          ss.settings.doubleTapForDetails.value = val;
                          if (val && ss.settings.enableQuickTapback.value) {
                            ss.settings.enableQuickTapback.value = false;
                          }
                          saveSettings();
                        },
                        initialVal: ss.settings.doubleTapForDetails.value,
                        title: "Double-${kIsWeb || kIsDesktop ? "Click" : "Tap"} Message for Details",
                        subtitle: "Opens the message details popup when double ${kIsWeb || kIsDesktop ? "click" : "tapp"}ing a message",
                        backgroundColor: tileColor,
                        isThreeLine: true,
                      )),
                  if (!kIsDesktop && !kIsWeb)
                    const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  if (!kIsDesktop && !kIsWeb)
                    Obx(() => SettingsSwitch(
                          onChanged: (bool val) {
                            ss.settings.sendWithReturn.value = val;
                            saveSettings();
                          },
                          initialVal: ss.settings.sendWithReturn.value,
                          title: "Send Message with Enter",
                          backgroundColor: tileColor,
                        )),
                  const SettingsDivider(padding: EdgeInsets.only(left: 16.0)),
                  Obx(() => SettingsSwitch(
                        onChanged: (bool val) {
                          ss.settings.scrollToBottomOnSend.value = val;
                          saveSettings();
                        },
                        initialVal: ss.settings.scrollToBottomOnSend.value,
                        title: "Scroll To Bottom When Sending Messages",
                        subtitle: "Scroll to the most recent messages in the chat when sending a new text",
                        backgroundColor: tileColor,
                      )),
                ],
              ),

              SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Interaction Settings"),
                Obx(() => SettingsSection(
                  backgroundColor: tileColor,
                  children: [
                    SettingsSwitch(
                      onChanged: (bool val) {
                        ss.settings.privateSendTypingIndicators.value = val;
                        saveSettings();
                      },
                      initialVal: ss.settings.privateSendTypingIndicators.value,
                      title: "Send Typing Indicators",
                      subtitle: "Sends typing indicators to other iMessage users",
                      backgroundColor: tileColor,
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.keyboard_chevron_compact_down,
                        materialIcon: Icons.keyboard_alt_outlined,
                        containerColor: Colors.green,
                      ),
                    ),
                    AnimatedSizeAndFade(
                    child: !ss.settings.privateManualMarkAsRead.value
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SettingsDivider(),
                                SettingsSwitch(
                                  onChanged: (bool val) {
                                    ss.settings.privateMarkChatAsRead.value = val;
                                    if (val) {
                                      ss.settings.privateManualMarkAsRead.value = false;
                                    }
                                    saveSettings();
                                  },
                                  initialVal: ss.settings.privateMarkChatAsRead.value,
                                  title: "Automatic Mark Read / Send Read Receipts",
                                  subtitle:
                                      "Marks chats read in the iMessage app on your server and sends read receipts to other iMessage users",
                                  backgroundColor: tileColor,
                                  isThreeLine: true,
                                  leading: const SettingsLeadingIcon(
                                    iosIcon: CupertinoIcons.rectangle_fill_badge_checkmark,
                                    materialIcon: Icons.playlist_add_check,
                                    containerColor: Colors.blueAccent,
                                  )
                                ),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                    AnimatedSizeAndFade.showHide(
                      show: !ss.settings.privateMarkChatAsRead.value,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SettingsDivider(),
                          SettingsSwitch(
                            onChanged: (bool val) {
                              ss.settings.privateManualMarkAsRead.value = val;
                              saveSettings();
                            },
                            initialVal: ss.settings.privateManualMarkAsRead.value,
                            title: "Manual Mark Read / Send Read Receipts",
                            subtitle: "Only mark a chat read when pressing the manual mark read button",
                            backgroundColor: tileColor,
                            isThreeLine: true,
                            leading: const SettingsLeadingIcon(
                              iosIcon: CupertinoIcons.check_mark_circled,
                              materialIcon: Icons.check_circle_outline,
                              containerColor: Colors.orange,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SettingsDivider(),
                    SettingsSwitch(
                      title: "Double-${kIsWeb || kIsDesktop ? "Click" : "Tap"} Message for Quick Tapback",
                      initialVal: ss.settings.enableQuickTapback.value,
                      onChanged: (bool val) {
                        ss.settings.enableQuickTapback.value = val;
                        if (val && ss.settings.doubleTapForDetails.value) {
                          ss.settings.doubleTapForDetails.value = false;
                        }
                        saveSettings();
                      },
                      subtitle: "Send a tapback of your choosing when double ${kIsWeb || kIsDesktop ? "click" : "tapp"}ing a message",
                      backgroundColor: tileColor,
                      isThreeLine: true,
                      leading: const SettingsLeadingIcon(
                        iosIcon: CupertinoIcons.rays,
                        materialIcon: Icons.touch_app_outlined,
                        containerColor: Colors.purple,
                      ),
                    ),
                    AnimatedSizeAndFade.showHide(
                      show: ss.settings.enableQuickTapback.value,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 5.0),
                        child: SettingsOptions<String>(
                          title: "Quick Tapback",
                          options: ReactionTypes.toList().take(6).toList(),
                          cupertinoCustomWidgets: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7.5),
                              child: ReactionWidget(
                                reaction: Message(
                                    guid: "",
                                    associatedMessageType: ReactionTypes.LOVE,
                                    isFromMe: ss.settings.quickTapbackType.value != ReactionTypes.LOVE),
                                message: null,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7.5),
                              child: ReactionWidget(
                                reaction: Message(
                                    guid: "",
                                    associatedMessageType: ReactionTypes.LIKE,
                                    isFromMe: ss.settings.quickTapbackType.value != ReactionTypes.LIKE),
                                message: null,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7.5),
                              child: ReactionWidget(
                                reaction: Message(
                                    guid: "",
                                    associatedMessageType: ReactionTypes.DISLIKE,
                                    isFromMe: ss.settings.quickTapbackType.value != ReactionTypes.DISLIKE),
                                message: null,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7.5),
                              child: ReactionWidget(
                                reaction: Message(
                                    guid: "",
                                    associatedMessageType: ReactionTypes.LAUGH,
                                    isFromMe: ss.settings.quickTapbackType.value != ReactionTypes.LAUGH),
                                message: null,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7.5),
                              child: ReactionWidget(
                                reaction: Message(
                                    guid: "",
                                    associatedMessageType: ReactionTypes.EMPHASIZE,
                                    isFromMe: ss.settings.quickTapbackType.value != ReactionTypes.EMPHASIZE),
                                message: null,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 7.5),
                              child: ReactionWidget(
                                reaction: Message(
                                    guid: "",
                                    associatedMessageType: ReactionTypes.QUESTION,
                                    isFromMe: ss.settings.quickTapbackType.value != ReactionTypes.QUESTION),
                                message: null,
                              ),
                            ),
                          ],
                          initial: ss.settings.quickTapbackType.value,
                          textProcessing: (val) => val,
                          onChanged: (val) {
                            if (val == null) return;
                            ss.settings.quickTapbackType.value = val;
                            saveSettings();
                          },
                          secondaryColor: headerColor,
                        ),
                      ),
                    ),
                    AnimatedSizeAndFade.showHide(
                      show: backend.canEditUnsend(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SettingsDivider(),
                          SettingsSwitch(
                            title: "Up Arrow for Quick Edit",
                            initialVal: ss.settings.editLastSentMessageOnUpArrow.value,
                            onChanged: (bool val) {
                              ss.settings.editLastSentMessageOnUpArrow.value = val;
                              saveSettings();
                            },
                            subtitle: "Press the Up Arrow to begin editing the last message you sent",
                            backgroundColor: tileColor,
                            leading: const SettingsLeadingIcon(
                              iosIcon: CupertinoIcons.arrow_up_square,
                              materialIcon: Icons.arrow_circle_up,
                              containerColor: Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                    AnimatedSizeAndFade.showHide(
                      show: backend.canSendSubject(),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SettingsDivider(),
                          SettingsSwitch(
                            onChanged: (bool val) {
                              ss.settings.privateSubjectLine.value = val;
                              saveSettings();
                            },
                            initialVal: ss.settings.privateSubjectLine.value,
                            title: "Send Subject Lines",
                            subtitle: "Show the subject line field when sending a message",
                            backgroundColor: tileColor,
                            isThreeLine: true,
                            leading: const SettingsLeadingIcon(
                              iosIcon: CupertinoIcons.textformat,
                              materialIcon: Icons.text_format_rounded,
                              containerColor: Colors.blueAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ))
            ],
          ),
        ),
      ],
    );
  }

  void saveSettings() {
    ss.saveSettings();
  }

  @override
  void dispose() {
    if (kIsDesktop) {
      (sendPlayer as Player).dispose();
      (receivePlayer as Player).dispose();
    } else {
      (sendPlayer as aw.PlayerController).dispose();
      (receivePlayer as aw.PlayerController).dispose();
    }
    super.dispose();
  }
}
