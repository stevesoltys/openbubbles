pub use rustpush::{NSArrayClass, SupportAction, NSArray, SupportAlert, PrivateDeviceInfo, NormalMessage, MessageType, UpdateExtensionMessage, ErrorMessage, UnsendMessage, EditMessage, PartExtension, IconChangeMessage, RichLinkImageAttachmentSubstitute, ChangeParticipantMessage, ReactMessage, Reaction, ReactMessageType, RenameMessage, LPLinkMetadata, NSURL, LPIconMetadata, LPImageMetadata, LinkMeta, ExtensionApp, NSDictionaryClass, BalloonLayout, Balloon, IndexedMessagePart, AttachmentType, MacOSConfig, Message, MessageTarget, HardwareConfig, APSConnection, APSConnectionResource, APSState, Attachment, AuthPhone, IDSUserIdentity, MMCSFile, MessageInst, MessagePart, MessageParts, OSConfig, RelayConfig, ResourceState};
pub use rustpush::{PushError, IDSUser, IMClient, ConversationData, register};
pub use icloud_auth::{VerifyBody, TrustedPhoneNumber};
pub use icloud_auth::{LoginState, AnisetteConfiguration, AppleAccount};

#[repr(C)]
#[frb(mirror(SupportAction))]
pub struct DartSupportAction {
    pub url: String,
    pub button: String,
}

#[repr(C)]
#[frb(mirror(SupportAlert))]
pub struct DartSupportAlert {
    pub title: String,
    pub body: String,
    pub action: Option<SupportAction>,
}

#[frb(mirror(ConversationData))]
#[repr(C)]
pub struct DartConversationData {
    #[frb(non_final)]
    pub participants: Vec<String>,
    #[frb(non_final)]
    pub cv_name: Option<String>,
    #[frb(non_final)]
    pub sender_guid: Option<String>,
    #[frb(non_final)]
    pub after_guid: Option<String>,
}


#[frb(non_opaque, mirror(LoginState))]
#[repr(C)]
pub enum DartLoginState {
    LoggedIn,
    // NeedsSMS2FASent(Send2FAToDevices),
    NeedsDevice2FA,
    Needs2FAVerification,
    NeedsSMS2FA,
    NeedsSMS2FAVerification(VerifyBody),
    NeedsExtraStep(String),
    NeedsLogin,
}

#[repr(C)]
#[frb(type_64bit_int, mirror(MMCSFile))]
pub struct DartMMCSFile {
    pub signature: Vec<u8>,
    pub object: String,
    pub url: String,
    pub key: Vec<u8>,
    pub size: usize
}


#[repr(C)]
#[frb(mirror(AttachmentType))]
pub enum DartAttachmentType {
    Inline(Vec<u8>),
    MMCS(MMCSFile)
}

#[repr(C)]
#[frb(type_64bit_int, mirror(Attachment))]
pub struct DartAttachment {
    pub a_type: AttachmentType,
    pub part: u64,
    pub uti_type: String,
    pub mime: String,
    pub name: String,
    pub iris: bool
}

#[frb(external)]
impl Attachment {
    #[frb(type_64bit_int)]
    pub fn get_size(&self) -> usize { }
}

#[repr(C)]
#[frb(mirror(MessagePart))]
pub enum DartMessagePart {
    Text(String),
    Attachment(Attachment),
    Mention(String, String),
    Object(String),
}

#[repr(C)]
#[frb(type_64bit_int, mirror(PartExtension))]
pub enum DartPartExtension {
    Sticker {
        msg_width: f64,
        rotation: f64, // radians, -pi to +pi
        sai: u64,
        scale: f64,
        update: Option<bool>, // Some(false) for updates
        sli: u64,
        normalized_x: f64,
        normalized_y: f64,
        version: u64,
        hash: String,
        safi: u64,
        effect_type: i64,
        sticker_id: String,
    }
}

#[repr(C)]
#[frb(type_64bit_int, mirror(IndexedMessagePart))]
pub struct DartIndexedMessagePart {
    pub part: MessagePart,
    pub idx: Option<usize>,
    pub ext: Option<PartExtension>,
}

#[frb(mirror(MessageParts))]
#[repr(C)]
pub struct DartMessageParts(pub Vec<IndexedMessagePart>);

#[frb(external)]
impl MessageParts {
    pub fn raw_text(&self) -> String { }
}


#[frb(mirror(MessageType))]
#[repr(C)]
#[derive(PartialEq, Clone)]
pub enum DartMessageType {
    IMessage,
    SMS {
        is_phone: bool,
        using_number: String, // prefixed with tel:
        from_handle: Option<String>,
    }
}

#[repr(C)]
#[frb(mirror(NSDictionaryClass))]
pub enum DartNSDictionaryClass {
    NSDictionary,
    NSMutableDictionary,
}

#[repr(C)]
#[frb(non_opaque, mirror(BalloonLayout))]
pub enum DartBalloonLayout {
    TemplateLayout {
        image_subtitle: String,
        image_title: String,
        caption: String,
        secondary_subcaption: String,
        tertiary_subcaption: String,
        subcaption: String,
        class: NSDictionaryClass,
    }
}

#[repr(C)]
#[frb(non_opaque, mirror(Balloon))]
pub struct DartBalloon {
    pub url: String,
    pub session: Option<String>, // UUID
    pub layout: BalloonLayout,
    pub ld_text: Option<String>,
    pub is_live: bool,

    pub icon: Vec<u8>,
}

#[repr(C)]
#[frb(type_64bit_int, mirror(ExtensionApp))]
pub struct DartExtensionApp {
    pub name: String,
    pub app_id: Option<u64>,
    pub bundle_id: String,

    pub balloon: Option<Balloon>,
}

#[frb(mirror(NormalMessage))]
#[repr(C)]
pub struct DartNormalMessage {
    #[frb(non_final)]
    pub parts: MessageParts,
    #[frb(non_final)]
    pub effect: Option<String>,
    #[frb(non_final)]
    pub reply_guid: Option<String>,
    #[frb(non_final)]
    pub reply_part: Option<String>,
    pub service: MessageType,
    #[frb(non_final)]
    pub subject: Option<String>,
    #[frb(non_final)]
    pub app: Option<ExtensionApp>,
    #[frb(non_final)]
    pub link_meta: Option<LinkMeta>,
    #[frb(non_final)]
    pub voice: bool,
}

#[repr(C)]
#[frb(mirror(NSURL))]
pub struct DartNSURL {
    pub base: String,
    pub relative: String,
}

#[repr(C)]
#[frb(mirror(LPImageMetadata))]
pub struct DartLPImageMetadata {
    pub size: String,
    pub url: NSURL,
    pub version: u8,
}

#[repr(C)]
#[frb(mirror(LPIconMetadata))]
pub struct DartLPIconMetadata {
    pub url: NSURL,
    pub version: u8,
}

#[repr(C)]
#[frb(mirror(RichLinkImageAttachmentSubstitute))]
pub struct DartRichLinkImageAttachmentSubstitute {
    pub mime_type: String,
    pub rich_link_image_attachment_substitute_index: u64,
}

#[repr(C)]
#[frb(mirror(NSArrayClass))]
pub enum DartNSArrayClass {
    NSArray,
    NSMutableArray,
}

// FRB doesn't support generics
// the things i do for this bridge...
#[repr(C)]
#[frb(non_opaque, mirror(NSArray<LPImageMetadata>))]
pub struct NSArrayImageArray {
    pub objects: Vec<LPImageMetadata>,
    pub class: NSArrayClass,
}

#[repr(C)]
#[frb(non_opaque, mirror(NSArray<LPIconMetadata>))]
pub struct NSArrayIconArray {
    pub objects: Vec<LPIconMetadata>,
    pub class: NSArrayClass,
}


#[repr(C)]
#[frb(mirror(LPLinkMetadata))]
pub struct DartLPLinkMetadata {
    pub image_metadata: Option<LPImageMetadata>,
    pub version: u8,
    pub icon_metadata: Option<LPIconMetadata>,
    pub original_url: NSURL,
    pub url: Option<NSURL>,
    pub title: Option<String>,
    pub summary: Option<String>,
    pub image: Option<RichLinkImageAttachmentSubstitute>,
    pub icon: Option<RichLinkImageAttachmentSubstitute>,
    pub images: Option<NSArray<LPImageMetadata>>,
    pub icons: Option<NSArray<LPIconMetadata>>,
}


#[frb(mirror(LinkMeta))]
#[repr(C)]
pub struct DartLinkMeta {
    pub data: LPLinkMetadata,
    pub attachments: Vec<Vec<u8>>,
}

#[repr(C)]
#[frb(mirror(RenameMessage))]
pub struct DartRenameMessage {
    pub new_name: String
}

#[repr(C)]
#[frb(type_64bit_int, mirror(ChangeParticipantMessage))]
pub struct DartChangeParticipantMessage {
    pub new_participants: Vec<String>,
    pub group_version: u64
}

#[repr(C)]
#[frb(mirror(Reaction))]
pub enum DartReaction {
    Heart,
    Like,
    Dislike,
    Laugh,
    Emphsize,
    Question
}

#[repr(C)]
#[frb(non_opaque, mirror(ReactMessageType))]
pub enum DartReactMessageType {
    React {
        reaction: Reaction,
        enable: bool,
    },
    Extension {
        spec: ExtensionApp,
        body: MessageParts
    },
}

#[repr(C)]
#[frb(type_64bit_int, mirror(ReactMessage))]
pub struct DartReactMessage {
    pub to_uuid: String,
    pub to_part: Option<u64>,
    pub reaction: ReactMessageType,
    pub to_text: String,
}

#[repr(C)]
#[frb(type_64bit_int, mirror(UnsendMessage))]
pub struct DartUnsendMessage {
    pub tuuid: String,
    pub edit_part: u64,
}

#[repr(C)]
#[frb(type_64bit_int, mirror(EditMessage))]
pub struct DartEditMessage {
    pub tuuid: String,
    pub edit_part: u64,
    pub new_parts: MessageParts
}

#[repr(C)]
#[frb(type_64bit_int, mirror(IconChangeMessage))]
pub struct DartIconChangeMessage {
    pub file: Option<MMCSFile>,
    pub group_version: u64
}

#[repr(C)]
#[frb(mirror(UpdateExtensionMessage))]
pub struct DartUpdateExtensionMessage {
    pub for_uuid: String,
    pub ext: PartExtension,
}

#[repr(C)]
#[frb(mirror(ErrorMessage))]
pub struct DartErrorMessage {
    pub for_uuid: String,
    pub status: u64,
    pub status_str: String,
}

#[repr(C)]
#[frb(non_opaque, mirror(Message))]
pub enum DartMessage {
    Message(NormalMessage),
    RenameMessage(RenameMessage),
    ChangeParticipants(ChangeParticipantMessage),
    React(ReactMessage),
    Delivered,
    Read,
    Typing,
    Unsend(UnsendMessage),
    Edit(EditMessage),
    IconChange(IconChangeMessage),
    StopTyping,
    EnableSmsActivation(bool),
    MessageReadOnDevice,
    SmsConfirmSent(bool),
    MarkUnread, // send for last message from other participant
    PeerCacheInvalidate,
    UpdateExtension(UpdateExtensionMessage),
    Error(ErrorMessage),
}

#[frb(mirror(MessageTarget))]
#[repr(C)]
pub enum DartMessageTarget {
    Token(Vec<u8>),
    Uuid(String),
}

#[frb(type_64bit_int, mirror(MessageInst))]
#[repr(C)]
pub struct DartIMessage {
    #[frb(non_final)]
    pub id: String,
    #[frb(non_final)]
    pub sender: Option<String>,
    #[frb(non_final)]
    pub conversation: Option<ConversationData>,
    #[frb(non_final)]
    pub message: Message,
    #[frb(non_final)]
    pub sent_timestamp: u64,
    #[frb(non_final)]
    pub target: Option<Vec<MessageTarget>>,
    #[frb(non_final)]
    pub send_delivered: bool,
    #[frb(non_final)]
    pub verification_failed: bool,
}

#[repr(C)]
#[frb(mirror(TrustedPhoneNumber))]
pub struct DartTrustedPhoneNumber {
    pub number_with_dial_code: String,
    pub last_two_digits: String,
    pub push_mode: String,
    pub id: u32
}


#[repr(C)]
#[frb(mirror(PrivateDeviceInfo))]
pub struct DartPrivateDeviceInfo {
    pub uuid: Option<String>,
    pub device_name: Option<String>,
    pub token: Vec<u8>,
    pub is_hsa_trusted: bool,
    pub identites: Vec<String>,
    pub sub_services: Vec<String>,
}


