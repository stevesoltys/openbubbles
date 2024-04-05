import 'package:async_task/async_task_extension.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger.dart';
import 'package:collection/collection.dart';
import 'package:get/get.dart';
import 'package:supercharged/supercharged.dart';
import 'package:tuple/tuple.dart';
import 'package:universal_io/io.dart';
import '../network/backend_service.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

var uuid = const Uuid();
RustPushService pushService =
    Get.isRegistered<RustPushService>() ? Get.find<RustPushService>() : Get.put(RustPushService());


// utils for communicating between dart and rustpush.
class RustPushBBUtils {
  static Handle rustHandleToBB(String handle) {
    var address = handle.replaceAll("tel:", "").replaceAll("mailto:", "");
    var mHandle = Handle.findOne(addressAndService: Tuple2(address, "iMessage"));
    if (mHandle == null) {
      mHandle = Handle(
        address: handle.replaceAll("tel:", "").replaceAll("mailto:", "")
      );
      mHandle.save();
    }
    if (mHandle.originalROWID == null) {
      mHandle.originalROWID = mHandle.id!;
      mHandle.save();
    }
    return mHandle;
  }

  static Future<String> formatAddress(String e) async {
    return e.isEmail ? e : await api.formatE164(number: e, country: countryCode ?? "US");
  }

  static Future<String> formatAndAddPrefix(String e) async {
    var address = await formatAddress(e);
    if (address.isEmail) {
      return "mailto:$address";
    } else {
      return "tel:$address";
    }
  }

  static String bbHandleToRust(Handle handle) {
    var address = handle.address;
    if (address.isEmail) {
      return "mailto:$address";
    } else {
      return "tel:$address";
    }
  }

  static Future<List<Handle>> rustParticipantsToBB(List<String> participants) async {
    var myHandles = (await api.getHandles(state: pushService.state));
    return participants.filter((e) => !myHandles.contains(e)).map((e) => rustHandleToBB(e)).toList();
  }
}

class RustPushBackend implements BackendService {
  Future<String> getDefaultHandle() async {
    var myHandles = await api.getHandles(state: pushService.state);
    return myHandles[0];
  }

  @override
  void init() {
    pushService.hello();
  }

  @override
  bool canCreateGroupChats() {
    return true;
  }

  @override
  bool supportsSmsForwarding() {
    // JJTech has already reversed this, but I don't have an iPhone so cannot test,
    // so unsupported for now
    return false;
  }

  @override
  Future<Chat> createChat(List<String> addresses, String? message, String service,
      {CancelToken? cancelToken}) async {
    var handle = await getDefaultHandle();
    var formattedHandles = (await Future.wait(
              addresses.map((e) async => RustPushBBUtils.rustHandleToBB(await RustPushBBUtils.formatAddress(e)))))
          .toList();
    var chat = Chat(
      guid: uuid.v4(),
      participants: formattedHandles,
      usingHandle: handle
    );
    if (message != null) {
      var msg = await api.newMsg(
          state: pushService.state,
          conversation: chat.getConversationData(),
          message: api.DartMessage.message(api.DartNormalMessage(
              parts: api.DartMessageParts(
                  field0: [api.DartIndexedMessagePart(field0: api.DartMessagePart.text(message))]))),
          sender: handle);
      await api.send(state: pushService.state, msg: msg);
      msg.sentTimestamp = DateTime.now().millisecondsSinceEpoch;

      chat.save(); //save for reflectMessage
      final newMessage = await pushService.reflectMessageDyn(msg);
      newMessage.chat.target = chat;
      newMessage.save();
    }
    return chat;
  }

  @override
  Future<PlatformFile> downloadAttachment(Attachment attachment,
      {void Function(int p1, int p2)? onReceiveProgress, bool original = false, CancelToken? cancelToken}) async {
    var rustAttachment = await api.DartAttachment.restore(saved: attachment.metadata!["rustpush"]);
    var stream = api.downloadAttachment(state: pushService.state, attachment: rustAttachment, path: attachment.path);
    await for (final event in stream) {
      if (onReceiveProgress != null) {
        onReceiveProgress(event.prog, event.total);
      }
    }
    return attachment.getFile();
  }

  @override
  Future<Message> sendAttachment(Chat chat, Message m, bool isAudioMessage, Attachment att, {void Function(int p1, int p2)? onSendProgress, CancelToken? cancelToken}) async {
    var stream = api.uploadAttachment(
        state: pushService.state,
        path: att.getFile().path!,
        mime: att.mimeType ?? "application/octet-stream",
        uti: att.uti ?? "public.data",
        name: att.transferName!);
    api.DartAttachment? attachment;
    await for (final event in stream) {
      if (event.attachment != null) {
        print("upload finish");
        attachment = event.attachment;
      } else if (onSendProgress != null) {
        print("upload progress ${event.prog} of ${event.total}");
        onSendProgress(event.prog, event.total);
      }
    }
    print("uploaded");
    var partIndex = int.tryParse(m.threadOriginatorPart?.split(":").firstOrNull ?? "");
    var msg = await api.newMsg(
        state: pushService.state,
        conversation: chat.getConversationData(),
        sender: await chat.ensureHandle(),
        message: api.DartMessage.message(api.DartNormalMessage(
          parts: api.DartMessageParts(
              field0: [api.DartIndexedMessagePart(field0: api.DartMessagePart.attachment(attachment!))]),
          replyGuid: m.threadOriginatorGuid,
          replyPart: m.threadOriginatorGuid == null ? null : "$partIndex:0:0",
          effect: m.expressiveSendStyleId,
        )));
    await api.send(state: pushService.state, msg: msg);
    msg.sentTimestamp = DateTime.now().millisecondsSinceEpoch;
    return await pushService.reflectMessageDyn(msg);
  }

  @override
  bool canCancelUploads() {
    return false;
  }

  @override
  Future<bool> canUploadGroupPhotos() async {
    return true;
  }

  @override
  Future<bool> deleteChatIcon(Chat chat, {CancelToken? cancelToken}) async {
    var msg = await api.newMsg(
      state: pushService.state,
      conversation: chat.getConversationData(),
      sender: await chat.ensureHandle(),
      message: api.DartMessage.iconChange(api.DartIconChangeMessage(groupVersion: chat.groupVersion!)),
    );
    await api.send(state: pushService.state, msg: msg);
    return true;
  }

  @override
  Future<bool> setChatIcon(Chat chat,
      {void Function(int p1, int p2)? onSendProgress, CancelToken? cancelToken}) async {
    chat.groupVersion = (chat.groupVersion ?? -1) + 1;
    var mmcsStream = api.uploadMmcs(state: pushService.state, path: chat.customAvatarPath!);
    api.DartMMCSFile? mmcs;
    await for (final event in mmcsStream) {
      if (event.file != null) {
        print("upload finish");
        mmcs = event.file;
      } else if (onSendProgress != null) {
        print("upload progress ${event.prog} of ${event.total}");
        onSendProgress(event.prog, event.total);
      }
    }
    var msg = await api.newMsg(
      state: pushService.state,
      conversation: chat.getConversationData(),
      sender: await chat.ensureHandle(),
      message: api.DartMessage.iconChange(api.DartIconChangeMessage(groupVersion: chat.groupVersion!, file: mmcs!)),
    );
    await api.send(state: pushService.state, msg: msg);
    return true;
  }

  @override
  Future<Message> sendMessage(Chat chat, Message m, {CancelToken? cancelToken}) async {
    var partIndex = int.tryParse(m.threadOriginatorPart?.split(":").firstOrNull ?? "");
    var msg = await api.newMsg(
      state: pushService.state,
      conversation: chat.getConversationData(),
      sender: await chat.ensureHandle(),
      message: api.DartMessage.message(api.DartNormalMessage(
        parts: api.DartMessageParts(field0: [api.DartIndexedMessagePart(field0: api.DartMessagePart.text(m.text!))]),
        replyGuid: m.threadOriginatorGuid,
        replyPart: m.threadOriginatorGuid == null ? null : "$partIndex:0:0",
        effect: m.expressiveSendStyleId,
      )),
    );
    await api.send(state: pushService.state, msg: msg);
    msg.sentTimestamp = DateTime.now().millisecondsSinceEpoch;
    return await pushService.reflectMessageDyn(msg);
  }

  Future<bool> markDelivered(api.DartIMessage message) async {
    // all messages with c = 100 need to be acked
    if (!(message.message is api.DartMessage_React ||
        message.message is api.DartMessage_Message ||
        message.message is api.DartMessage_Typing)) {
      return true;
    }
    var chat = await Chat.findByRust(message.conversation!);
    var msg = await api.newMsg(
      state: pushService.state,
      conversation: message.conversation!,
      sender: await chat.ensureHandle(),
      message: const api.DartMessage.delivered(),
    );
    msg.id = message.id;
    await api.send(state: pushService.state, msg: msg);
    return true;
  }

  @override
  bool supportsFocusStates() {
    return false;
  }

  @override
  Future<bool> markRead(Chat chat) async {
    var latestMsg = chat.latestMessage.guid;
    var msg = await api.newMsg(
        state: pushService.state,
        conversation: chat.getConversationData(),
        sender: await chat.ensureHandle(),
        message: const api.DartMessage.read());
    msg.id = latestMsg!;
    await api.send(state: pushService.state, msg: msg);
    return true;
  }

  @override
  Future<bool> renameChat(Chat chat, String newName) async {
    var data = chat.getConversationData();
    var msg = await api.newMsg(
        state: pushService.state,
        conversation: data,
        sender: await chat.ensureHandle(),
        message: api.DartMessage.renameMessage(api.DartRenameMessage(newName: newName)));
    await api.send(state: pushService.state, msg: msg);
    msg.sentTimestamp = DateTime.now().millisecondsSinceEpoch;
    inq.queue(IncomingItem(
      chat: chat,
      message: await pushService.reflectMessageDyn(msg),
      tempGuid: uuid.v4(),
      type: QueueType.newMessage
    ));
    return true;
  }

  @override
  Future<bool> chatParticipant(ParticipantOp method, Chat chat, String newName) async {
    chat.groupVersion = (chat.groupVersion ?? -1) + 1;
    var data = chat.getConversationData();
    var newParticipants = data.participants.copy();
    if (method == ParticipantOp.Add) {
      var target = await RustPushBBUtils.formatAndAddPrefix(newName);
      var valid =
          (await api.validateTargets(state: pushService.state, targets: [target], sender: await chat.ensureHandle()))
              .isNotEmpty;
      if (!valid) {
        return false;
      }
      newParticipants.add(target);
    } else if (method == ParticipantOp.Remove) {
      newParticipants.remove(await RustPushBBUtils.formatAndAddPrefix(newName));
    }
    var msg = await api.newMsg(
        state: pushService.state,
        conversation: data,
        sender: await chat.ensureHandle(),
        message: api.DartMessage.changeParticipants(
            api.DartChangeParticipantMessage(groupVersion: chat.groupVersion!, newParticipants: newParticipants)));
    await api.send(state: pushService.state, msg: msg);
    msg.sentTimestamp = DateTime.now().millisecondsSinceEpoch;
    inq.queue(IncomingItem(
      chat: chat,
      message: await pushService.reflectMessageDyn(msg),
      tempGuid: uuid.v4(),
      type: QueueType.newMessage
    ));
    return true;
  }

  @override
  Future<bool> leaveChat(Chat chat) async {
    var handle = RustPushBBUtils.rustHandleToBB(await chat.ensureHandle());
    return await chatParticipant(ParticipantOp.Remove, chat, handle.address);
  }

  var reactionMap = {
    ReactionTypes.LOVE: api.DartReaction.heart,
    ReactionTypes.LIKE: api.DartReaction.like,
    ReactionTypes.DISLIKE: api.DartReaction.dislike,
    ReactionTypes.LAUGH: api.DartReaction.laugh,
    ReactionTypes.EMPHASIZE: api.DartReaction.emphsize,
    ReactionTypes.QUESTION: api.DartReaction.question
  };

  @override
  Future<Message> sendTapback(
      Chat chat, Message selected, String reaction, int? repPart) async {
    var enabled = !reaction.startsWith("-");
    reaction = enabled ? reaction : reaction.substring(1);
    var msg = await api.newMsg(
        state: pushService.state,
        conversation: chat.getConversationData(),
        sender: await chat.ensureHandle(),
        message: api.DartMessage.react(api.DartReactMessage(
            toUuid: selected.guid!,
            toPart: repPart ?? 0,
            toText: selected.text ?? "",
            enable: enabled,
            reaction: reactionMap[reaction]!)));
    await api.send(state: pushService.state, msg: msg);
    msg.sentTimestamp = DateTime.now().millisecondsSinceEpoch;
    return await pushService.reflectMessageDyn(msg);
  }

  @override
  Future<Message?> unsend(Message msgObj, MessagePart part) async {
    var msg = await api.newMsg(
        state: pushService.state,
        sender: await msgObj.chat.target!.ensureHandle(),
        conversation: msgObj.chat.target!.getConversationData(),
        message: api.DartMessage.unsend(api.DartUnsendMessage(tuuid: msgObj.guid!, editPart: part.part)));
    await api.send(state: pushService.state, msg: msg);
    return await pushService.reflectMessageDyn(msg);
  }

  @override
  Future<Message?> edit(Message msgObj, String text, int part) async {
    var msg = await api.newMsg(
        state: pushService.state,
        conversation: msgObj.chat.target!.getConversationData(),
        sender: await msgObj.chat.target!.ensureHandle(),
        message: api.DartMessage.edit(api.DartEditMessage(
            tuuid: msgObj.guid!,
            editPart: part,
            newParts: api.DartMessageParts(
                field0: [api.DartIndexedMessagePart(field0: api.DartMessagePart.text(text), field1: part)]))));
    await api.send(state: pushService.state, msg: msg);
    msg.sentTimestamp = DateTime.now().millisecondsSinceEpoch;
    return await pushService.reflectMessageDyn(msg);
  }

  @override
  HttpService? getRemoteService() {
    return null;
  }

  @override
  bool canLeaveChat() {
    return true;
  }

  @override
  bool canEditUnsend() {
    return true;
  }

  @override
  Future<bool> downloadLivePhoto(Attachment attachment, String target,
      {void Function(int p1, int p2)? onReceiveProgress, CancelToken? cancelToken}) async {
    var rustAttachment = await api.DartAttachment.restore(saved: attachment.metadata!["myIris"]);
    var stream = api.downloadAttachment(state: pushService.state, attachment: rustAttachment, path: target);
    await for (final event in stream) {
      if (onReceiveProgress != null) {
        onReceiveProgress(event.prog, event.total);
      }
    }
    return true;
  }

  @override
  bool canSchedule() {
    return false; // don't want to write a local db for scheduled messages rn
  }

  @override
  bool supportsFindMy() {
    return false;
  }

  @override
  void startedTyping(Chat c) async {
    if (c.participants.length > 1) {
      return; // no typing indicators for multiple chats
    }
    var msg = await api.newMsg(
      state: pushService.state,
      conversation: c.getConversationData(),
      sender: await c.ensureHandle(),
      message: const api.DartMessage.typing()
    );
    await api.send(state: pushService.state, msg: msg);
  }

  @override
  void stoppedTyping(Chat c) async {
    if (c.participants.length > 1) {
      return; // no typing indicators for multiple chats
    }
    var msg = await api.newMsg(
      state: pushService.state,
      conversation: c.getConversationData(),
      sender: await c.ensureHandle(),
      message: const api.DartMessage.stopTyping()
    );
    await api.send(state: pushService.state, msg: msg);
  }

  @override
  void updateTypingStatus(Chat c) {  }

  @override
  Future<bool> handleiMessageState(String address) async {
    var handle = await getDefaultHandle();
    var formatted = await RustPushBBUtils.formatAndAddPrefix(address);
    var available = await api.validateTargets(state: pushService.state, targets: [formatted], sender: handle);
    return available.isNotEmpty;
  }

}

class RustPushService extends GetxService {
  late api.PushState state;

  Map<String, api.DartAttachment> attachments = {};

  var invReactionMap = {
    api.DartReaction.heart: ReactionTypes.LOVE,
    api.DartReaction.like: ReactionTypes.LIKE,
    api.DartReaction.dislike: ReactionTypes.DISLIKE,
    api.DartReaction.laugh: ReactionTypes.LAUGH,
    api.DartReaction.emphsize: ReactionTypes.EMPHASIZE,
    api.DartReaction.question: ReactionTypes.QUESTION,
  };

  Future<(AttributedBody, String, List<Attachment>)> indexedPartsToAttributedBodyDyn(
      List<api.DartIndexedMessagePart> parts, String msgId, Map<String, dynamic>? existingBody) async {
    var bodyString = "";
    List<Run> body = existingBody?["runs"] ?? [];
    List<Attachment> attachments = [];
    var index = -1;
    for (var indexedParts in parts) {
      index += 1;
      var part = indexedParts.field0;
      var fieldIdx = indexedParts.field1 ?? body.length;
      // remove old elements
      body.removeWhere((element) => element.attributes?.messagePart == fieldIdx);
      if (part is api.DartMessagePart_Text) {
        body.add(Run(
          range: [bodyString.length, part.field0.length],
          attributes: Attributes(
            messagePart: fieldIdx,
          )
        ));
        bodyString += part.field0;
      } else if (part is api.DartMessagePart_Attachment) {
        if (part.field0.iris) {
          continue;
        }
        api.DartAttachment? myIris;
        var next = parts.elementAtOrNull(index + 1);
        if (next != null && next.field0 is api.DartMessagePart_Attachment) {
          var nextA = next.field0 as api.DartMessagePart_Attachment;
          if (nextA.field0.iris) {
            myIris = nextA.field0;
          }
        }
        var myUuid = "${msgId}_$fieldIdx";
        attachments.add(Attachment(
          guid: myUuid,
          uti: part.field0.utiType,
          mimeType: part.field0.mime,
          isOutgoing: false,
          transferName: part.field0.name,
          totalBytes: await part.field0.getSize(),
          hasLivePhoto: myIris != null,
          metadata: {"rustpush": await part.field0.save(), "myIris": await myIris?.save()},
        ));
        body.add(Run(
          range: [bodyString.length, 1],
          attributes: Attributes(
            attachmentGuid: myUuid,
            messagePart: body.length
          )
        ));
        bodyString += " ";
      }
    }
    return (AttributedBody(string: bodyString, runs: body), bodyString, attachments);
  }

  Future<Message> reflectMessageDyn(api.DartIMessage myMsg) async {
    var chat = myMsg.conversation != null ? await Chat.findByRust(myMsg.conversation!) : null;
    var myHandles = (await api.getHandles(state: pushService.state));
    if (myMsg.message is api.DartMessage_Message) {
      var innerMsg = myMsg.message as api.DartMessage_Message;
      var attributedBodyData = await indexedPartsToAttributedBodyDyn(innerMsg.field0.parts.field0, myMsg.id, null);

      return Message(
        guid: myMsg.id,
        text: attributedBodyData.$2,
        isFromMe: myHandles.contains(myMsg.sender),
        handle: RustPushBBUtils.rustHandleToBB(myMsg.sender!),
        dateCreated: DateTime.fromMillisecondsSinceEpoch(myMsg.sentTimestamp),
        threadOriginatorPart: innerMsg.field0.replyPart?.toString(),
        threadOriginatorGuid: innerMsg.field0.replyGuid,
        expressiveSendStyleId: innerMsg.field0.effect,
        attributedBody: [attributedBodyData.$1],
        attachments: attributedBodyData.$3,
      );
    } else if (myMsg.message is api.DartMessage_RenameMessage) {
      var msg = myMsg.message as api.DartMessage_RenameMessage;
      
      return Message(
        guid: myMsg.id,
        isFromMe: myHandles.contains(myMsg.sender),
        handleId: RustPushBBUtils.rustHandleToBB(myMsg.sender!).originalROWID!,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(myMsg.sentTimestamp),
        itemType: 2,
        groupActionType: 2,
        groupTitle: msg.field0.newName
      );
    } else if (myMsg.message is api.DartMessage_ChangeParticipants) {
      var msg = myMsg.message as api.DartMessage_ChangeParticipants;
      var isAdd = msg.field0.newParticipants.length > chat!.participants.length;
      var participantHandles = await RustPushBBUtils.rustParticipantsToBB(msg.field0.newParticipants);
      var didLeave = !msg.field0.newParticipants.contains(await chat.ensureHandle());
      var changed = didLeave
          ? RustPushBBUtils.rustHandleToBB(await chat.ensureHandle())
          : isAdd
              ? participantHandles
                  .firstWhere((element) => chat!.participants.none((p0) => p0.address == element.address))
              : chat.participants
                  .firstWhere((element) => participantHandles.none((p0) => p0.address == element.address));
      chat.groupVersion = msg.field0.groupVersion;
      chat.handles.clear();
      chat.handles.addAll(participantHandles);
      chat.handles.applyToDb();
      chat = chat.getParticipants();
      chat.save(updateGroupVersion: true);
      return Message(
        guid: myMsg.id,
        isFromMe: myHandles.contains(myMsg.sender),
        handleId: RustPushBBUtils.rustHandleToBB(myMsg.sender!).originalROWID!,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(myMsg.sentTimestamp),
        itemType: didLeave ? 3 : 1,
        groupActionType: isAdd || didLeave ? 0 : 1,
        otherHandle: changed.originalROWID
      );
    } else if (myMsg.message is api.DartMessage_IconChange) {
      if (!chat!.lockChatIcon) {
        var innerMsg = myMsg.message as api.DartMessage_IconChange;
        var file = innerMsg.field0.file;
        chat.groupVersion = innerMsg.field0.groupVersion;
        if (file != null) {
          var path = chat.getIconPath(file.size);
          var stream = api.downloadMmcs(state: pushService.state, attachment: file, path: path);
          await for (final event in stream) {
            print("Downloaded attachment ${event.prog} bytes of ${event.total}");
          }
          chat.customAvatarPath = path;
        } else {
          chat.removeProfilePhoto();
        }
        chat.save(updateCustomAvatarPath: true, updateGroupVersion: true);
      }
      return Message(
        guid: myMsg.id,
        isFromMe: myHandles.contains(myMsg.sender),
        handleId: RustPushBBUtils.rustHandleToBB(myMsg.sender!).originalROWID!,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(myMsg.sentTimestamp),
        itemType: 3,
        groupActionType: 1,
      );
    } else if (myMsg.message is api.DartMessage_React) {
      var msg = myMsg.message as api.DartMessage_React;
      var reaction = invReactionMap[msg.field0.reaction]!;
      if (!msg.field0.enable) {
        reaction = "-$reaction";
      }
      return Message(
        guid: myMsg.id,
        isFromMe: myHandles.contains(myMsg.sender),
        handleId: RustPushBBUtils.rustHandleToBB(myMsg.sender!).originalROWID!,
        dateCreated: DateTime.fromMillisecondsSinceEpoch(myMsg.sentTimestamp),
        itemType: 1,
        associatedMessagePart: msg.field0.toPart,
        associatedMessageGuid: msg.field0.toUuid,
        associatedMessageType: reaction,
      );
    } else if (myMsg.message is api.DartMessage_Unsend) {
      var msg = myMsg.message as api.DartMessage_Unsend;
      var msgObj = Message.findOne(guid: msg.field0.tuuid)!;
      msgObj.dateEdited = DateTime.now();
      var summaryInfo = msgObj.messageSummaryInfo.firstOrNull;
      if (summaryInfo == null) {
        summaryInfo = MessageSummaryInfo.empty();
        msgObj.messageSummaryInfo.add(summaryInfo);
      }
      summaryInfo.retractedParts.add(msg.field0.editPart);
      return msgObj;
    } else if (myMsg.message is api.DartMessage_Edit) {
      var msg = myMsg.message as api.DartMessage_Edit;
      var msgObj = Message.findOne(guid: msg.field0.tuuid);
      if (msgObj == null) {
        throw Exception("Cannot find msg!");
      }
      
      var attributedBodyDataInclusive = await indexedPartsToAttributedBodyDyn(
          msg.field0.newParts.field0, myMsg.id, msgObj.attributedBody.map((e) => e.toMap()).toList().firstOrNull);
      var attributedBodyEdited = await indexedPartsToAttributedBodyDyn(msg.field0.newParts.field0, myMsg.id, null);
      msgObj.text = attributedBodyDataInclusive.$2;
      msgObj.dateEdited = DateTime.now();

      var summaryInfo = msgObj.messageSummaryInfo.firstOrNull;
      if (summaryInfo == null) {
        summaryInfo = MessageSummaryInfo.empty();
        msgObj.messageSummaryInfo.add(summaryInfo);
      }
      if (!summaryInfo.editedParts.contains(msg.field0.editPart)) {
        summaryInfo.editedParts.add(msg.field0.editPart);
      }

      // TODO need i set originalTextRange?
      var contentMap = summaryInfo.editedContent;
      if (contentMap[msg.field0.editPart.toString()] == null) {
        contentMap[msg.field0.editPart.toString()] = [
          EditedContent(
            date: (msgObj.dateCreated?.millisecondsSinceEpoch ?? 0).toDouble(),
            text: Content(values: msgObj.attributedBody)
          )
        ];
      }

      contentMap[msg.field0.editPart.toString()]!.add(
        EditedContent(
          date: myMsg.sentTimestamp.toDouble(),
          text: Content(values: [attributedBodyEdited.$1])
        )
      );

      msgObj.attributedBody = [attributedBodyDataInclusive.$1];
      return msgObj;
    }
    throw Exception("bad message type!");
  }

  Future handleMsg(api.DartRecievedMessage msg) async {
    if (msg is api.DartRecievedMessage_Message) {
      var myMsg = msg.msg;
      if (myMsg.message is api.DartMessage_Delivered || myMsg.message is api.DartMessage_Read) {
        var message = Message.findOne(guid: myMsg.id);
        if (message == null) {
          return;
        }
        var map = message.toMap();
        map["chats"] = [message.chat.target!.toMap()];
        if (myMsg.message is api.DartMessage_Delivered) {
          map["dateDelivered"] = myMsg.sentTimestamp;
        } else {
          map["dateRead"] = myMsg.sentTimestamp;
        }
        inq.queue(IncomingItem.fromMap(QueueType.updatedMessage, map));
        return;
      }
      var chat = await Chat.findByRust(myMsg.conversation!);
      if (myMsg.message is api.DartMessage_RenameMessage) {
        var msg = myMsg.message as api.DartMessage_RenameMessage;
        if (!chat.lockChatName) {
          chat.displayName = msg.field0.newName;
        }
        chat.apnTitle = msg.field0.newName;
        myMsg.conversation?.cvName = msg.field0.newName;
        chat = chat.save(updateDisplayName: true, updateAPNTitle: true);
      }
      if (myMsg.message is api.DartMessage_Typing) {
        final controller = cvc(chat);
        controller.showTypingIndicator.value = true;
        var future = Future.delayed(const Duration(minutes: 1));
        var subscription = future.asStream().listen((any) {
          controller.showTypingIndicator.value = false;
          controller.cancelTypingIndicator = null;
        });
        controller.cancelTypingIndicator = subscription;
        return;
      }
      if (myMsg.message is api.DartMessage_StopTyping) {
        final controller = cvc(chat);
        controller.showTypingIndicator.value = false;
        if (controller.cancelTypingIndicator != null) {
          controller.cancelTypingIndicator!.cancel();
          controller.cancelTypingIndicator = null;
        }
        return;
      }
      if (myMsg.message is api.DartMessage_Message) {
        final controller = cvc(chat);
        controller.showTypingIndicator.value = false;
        controller.cancelTypingIndicator?.cancel();
        controller.cancelTypingIndicator = null;
        var msg = myMsg.message as api.DartMessage_Message;
        if ((await msg.field0.parts.asPlain()) == "" &&
            msg.field0.parts.field0.none((p0) => p0.field0 is api.DartMessagePart_Attachment)) {
          return;
        }
      }
      var service = backend as RustPushBackend;
      service.markDelivered(myMsg);
      inq.queue(IncomingItem(
        chat: chat,
        message: await pushService.reflectMessageDyn(myMsg),
        type: QueueType.newMessage
      ));
    }
  }

  Future recievedMsgPointer(String pointer) async {
    var message = await api.ptrToDart(ptr: pointer);
    try {
      await handleMsg(message);
    } catch (e, s) {
      print("$e\n$s");
      rethrow;
    }
  }

  void doPoll() async {
    while (true) {
      try {
        var msg = await api.recvWait(state: pushService.state);
        if (msg == null) {
          continue;
        }
        await handleMsg(msg);
      } catch (e, t) {
        // if there was an error somewhere, log it and move on.
        // don't stop our loop
        Logger.error("$e: $t");
      }
    }
  }

  void hello() {
    // used to get GetX to get up off it's ass
  }

  late Future initFuture;

  @override
  Future<void> onInit() async {
    super.onInit();
    initFuture = (() async {
      if (Platform.isAndroid) {
        String result = await mcs.invokeMethod("get-native-handle");
        // TODO
        // state = await api.serviceFromPtr(ptr: result);
      } else {
        state = await api.newPushState(dir: fs.appDocDir.path);
        if ((await api.getPhase(state: state)) == api.RegistrationPhase.registered) {
          doPoll();
        }
      }
    })();
    await initFuture;
  }

  Future configured() async {
    if (Platform.isAndroid) {
      await mcs.invokeMethod("notify-native-configured");
    } else {
      doPoll();
    }
  }

  @override
  void onClose() {
    state.dispose();
    super.onClose();
  }
}
