import 'dart:async';
import 'dart:isolate';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:emojis/emoji.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:get/get.dart';
import 'package:google_ml_kit/google_ml_kit.dart' hide Message;
import 'package:metadata_fetch/metadata_fetch.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:tuple/tuple.dart';
import 'package:universal_io/io.dart';

ConversationViewController cvc(Chat chat, {String? tag}) => Get.isRegistered<ConversationViewController>(tag: tag ?? chat.guid)
? Get.find<ConversationViewController>(tag: tag ?? chat.guid) : Get.put(ConversationViewController(chat, tag_: tag), tag: tag ?? chat.guid);

class ConversationViewController extends StatefulController with GetSingleTickerProviderStateMixin {
  final Chat chat;
  late final String tag;
  bool fromChatCreator = false;
  bool addedRecentPhotoReply = false;
  final AutoScrollController scrollController = AutoScrollController();

  ConversationViewController(this.chat, {String? tag_}) {
    tag = tag_ ?? chat.guid;
  }

  // caching items
  final Map<String, Uint8List> imageData = {};
  final List<Tuple4<Attachment, PlatformFile, BuildContext, Completer<Uint8List>>> imageCacheQueue = [];
  final Map<String, Map<String, (Uint8List, StickerData?)>> stickerData = {};
  final Map<String, Metadata> legacyUrlPreviews = {};
  final Map<String, VideoController> videoPlayers = {};
  final Map<String, PlayerController> audioPlayers = {};
  final Map<String, Player> audioPlayersDesktop = {};
  final Map<String, List<EntityAnnotation>> mlKitParsedText = {};

  // message view items
  final RxBool showTypingIndicator = false.obs;
  final RxBool showScrollDown = false.obs;
  final RxDouble timestampOffset = 0.0.obs;
  final RxBool inSelectMode = false.obs;
  final RxList<Message> selected = <Message>[].obs;
  final RxList<Tuple3<Message, MessagePart, MentionTextEditingController>> editing = <Tuple3<Message, MessagePart, MentionTextEditingController>>[].obs;
  final GlobalKey focusInfoKey = GlobalKey();
  final RxBool recipientNotifsSilenced = false.obs;
  bool showingOverlays = false;
  bool _subjectWasLastFocused = false; // If this is false, then message field was last focused (default)
  StreamSubscription<dynamic>? cancelTypingIndicator;

  FocusNode get lastFocusedNode => _subjectWasLastFocused ? subjectFocusNode : focusNode;
  SpellCheckTextEditingController get lastFocusedTextController => _subjectWasLastFocused ? subjectTextController : textController;

  // text field items
  bool showAttachmentPicker = false;
  RxBool showEmojiPicker = false.obs;
  final GlobalKey textFieldKey = GlobalKey();
  final RxList<PlatformFile> pickedAttachments = <PlatformFile>[].obs;
  final focusNode = FocusNode();
  final subjectFocusNode = FocusNode();
  late final textController = MentionTextEditingController(focusNode: focusNode);
  late final subjectTextController = SpellCheckTextEditingController(focusNode: subjectFocusNode);
  final Rx<(PlatformFile?, PayloadData)?> pickedApp = Rx<(PlatformFile, PayloadData)?>(null);
  final RxBool showRecording = false.obs;
  final RxList<Emoji> emojiMatches = <Emoji>[].obs;
  final RxInt emojiSelectedIndex = 0.obs;
  final RxList<Mentionable> mentionMatches = <Mentionable>[].obs;
  final RxInt mentionSelectedIndex = 0.obs;
  final ScrollController emojiScrollController = ScrollController();
  final Rxn<DateTime> scheduledDate = Rxn<DateTime>(null);
  final Rxn<Tuple2<Message, int>> _replyToMessage = Rxn<Tuple2<Message, int>>(null);
  Tuple2<Message, int>? get replyToMessage => _replyToMessage.value;
  set replyToMessage(Tuple2<Message, int>? m) {
    _replyToMessage.value = m;
    if (m != null) {
      lastFocusedNode.requestFocus();
    }
  }
  late final mentionables = chat.participants.map((e) => Mentionable(
    handle: e,
  )).toList();

  final Rxn<Contact> suggestedContact = Rxn<Contact>(null);
  final RxBool suggestShare = false.obs;
  bool keyboardOpen = false;
  double _keyboardOffset = 0;
  Timer? _scrollDownDebounce;
  Future<void> Function(Tuple7<List<PlatformFile>, AttributedBody, String, String?, int?, String?, PayloadData?>, bool, DateTime?)? sendFunc;
  bool isProcessingImage = false;

  void updateContactInfo() {
    if (chat.participants.length == 1) {
      Contact? sharedContact;
      if ((chat.participants.first.contact?.isShared ?? false)) {
        sharedContact = chat.participants.firstOrNull!.contact!;
      } else {
        sharedContact = Contact.findOne(address: chat.participants.firstOrNull!.address, wantShared: true);
      }
      if (sharedContact != null && !sharedContact.isDismissed) {
        suggestedContact.value = sharedContact;
      }

      // (not in our contacts or contact sharing disabled) and not shared
      suggestShare.value = ((chat.participants.first.contact?.isShared ?? true) || !ss.settings.shareContactAutomatically.value) 
          && !ss.settings.sharedContacts.contains(chat.participants.first.address)
          && !ss.settings.dismissedContacts.contains(chat.participants.first.address);
    }
  }

  StreamSubscription<int>? shareSubscription;

  @override
  void onInit() {
    super.onInit();

    shareSubscription = ss.settings.shareVersion.listen((s) => updateContactInfo());

    updateContactInfo();

    textController.mentionables = mentionables;
    KeyboardVisibilityController().onChange.listen((bool visible) async {
      keyboardOpen = visible;
      if (scrollController.hasClients) {
        _keyboardOffset = scrollController.offset;
      }
    });

    scrollController.addListener(() {
      if (!scrollController.hasClients) return;
      if (keyboardOpen
          && ss.settings.hideKeyboardOnScroll.value
          && scrollController.offset > _keyboardOffset + 100) {
        focusNode.unfocus();
        subjectFocusNode.unfocus();
      }

      if (showScrollDown.value && scrollController.offset >= 500) return;
      if (!showScrollDown.value && scrollController.offset < 500) return;

      if (scrollController.offset >= 500 && !showScrollDown.value) {
        showScrollDown.value = true;
        if (_scrollDownDebounce?.isActive ?? false) _scrollDownDebounce?.cancel();
        _scrollDownDebounce = Timer(const Duration(seconds: 3), () {
          showScrollDown.value = false;
        });
      } else if (showScrollDown.value) {
        showScrollDown.value = false;
      }
    });

    focusNode.addListener(() {
      if (focusNode.hasFocus) {
        _subjectWasLastFocused = false;
      }
    });

    subjectFocusNode.addListener(() {
      if (subjectFocusNode.hasFocus) {
        _subjectWasLastFocused = true;
      }
    });
  }

  @override
  void onClose() {
    for (PlayerController a in audioPlayers.values) {
      a.pausePlayer();
      a.dispose();
    }
    for (Player a in audioPlayersDesktop.values) {
      a.dispose();
    }
    for (VideoController a in videoPlayers.values) {
      a.player.pause();
      a.player.dispose();
    }
    scrollController.dispose();
    shareSubscription?.cancel();
    super.onClose();
  }

  Future<void> scrollToBottom() async {
    if (scrollController.positions.isNotEmpty && scrollController.positions.first.extentBefore > 0) {
      await scrollController.animateTo(
        0.0,
        curve: Curves.easeOut,
        duration: const Duration(milliseconds: 300),
      );
    }

    if (ss.settings.openKeyboardOnSTB.value) {
      focusNode.requestFocus();
    }
  }

  Future<void> scrollToTime(DateTime time) async {
    var messages = ms(chat.guid).struct.messages;
    messages.sort(Message.sort);
    if (scrollController.positions.isNotEmpty) {
      var test = messages.indexWhere((element) => element.chatViewDate?.isBefore(time) ?? false);
      await scrollController.scrollToIndex(test, preferPosition: AutoScrollPosition.begin);
    }

    if (ss.settings.openKeyboardOnSTB.value) {
      focusNode.requestFocus();
    }
  }

  Future<void> send(List<PlatformFile> attachments, AttributedBody text, String subject, String? replyGuid, int? replyPart, String? effectId, PayloadData? payload, bool isAudioMessage, DateTime? scheduledDate) async {
    sendFunc?.call(Tuple7(attachments, text, subject, replyGuid, replyPart, effectId, payload), isAudioMessage, scheduledDate);
  }

  void queueImage(Tuple4<Attachment, PlatformFile, BuildContext, Completer<Uint8List>> item) {
    imageCacheQueue.add(item);
    if (!isProcessingImage) _processNextImage();
  }

  Future<void> _processNextImage() async {
    if (imageCacheQueue.isEmpty) {
      isProcessingImage = false;
      return;
    }

    isProcessingImage = true;
    final queued = imageCacheQueue.removeAt(0);
    final attachment = queued.item1;
    final file = queued.item2;
    Uint8List? tmpData;
    // If it's an image, compress the image when loading it
    if (kIsWeb || file.path == null) {
      if (attachment.mimeType?.contains("image/tif") ?? false) {
        final receivePort = ReceivePort();
        await Isolate.spawn(unsupportedToPngIsolate, IsolateData(file, receivePort.sendPort));
        // Get the processed image from the isolate.
        final image = await receivePort.first as Uint8List?;
        tmpData = image;
      } else {
        tmpData = file.bytes;
      }
    } else if (attachment.canCompress) {
      tmpData = await as.loadAndGetProperties(attachment, actualPath: file.path!);
      // All other attachments can be held in memory as bytes
    } else {
      tmpData = await File(file.path!).readAsBytes();
    }
    if (tmpData == null) {
      queued.item4.complete(Uint8List.fromList([]));
      return;
    }
    imageData[attachment.guid!] = tmpData;
    try {
      await precacheImage(MemoryImage(tmpData), queued.item3);
    } catch (_) {}
    queued.item4.complete(tmpData);

    await _processNextImage();
  }

  bool isSelected(String guid) {
    return selected.firstWhereOrNull((e) => e.guid == guid) != null;
  }

  bool isEditing(String guid, int part) {
    return editing.firstWhereOrNull((e) => e.item1.guid == guid && e.item2.part == part) != null;
  }

  void close() {
    eventDispatcher.emit("update-highlight", null);
    cm.setAllInactiveSync();
    Get.delete<ConversationViewController>(tag: tag);
  }

  Future<void> saveReplyToMessageState() async {
    if (replyToMessage != null) {
      await ss.prefs.setString('replyToMessage_${chat.guid}', replyToMessage!.item1.guid!);
      await ss.prefs.setInt('replyToMessagePart_${chat.guid}', replyToMessage!.item2);
    } else {
      await ss.prefs.remove('replyToMessage_${chat.guid}');
      await ss.prefs.remove('replyToMessagePart_${chat.guid}');
    }
  }

  Future<void> loadReplyToMessageState() async {
    final replyToMessageGuid = ss.prefs.getString('replyToMessage_${chat.guid}');
    final replyToMessagePart = ss.prefs.getInt('replyToMessagePart_${chat.guid}');
    if (replyToMessageGuid != null && replyToMessagePart != null) {
      final message = Message.findOne(guid: replyToMessageGuid);
      if (message != null) {
        replyToMessage = Tuple2(message, replyToMessagePart);
      }
    }
  }
}
