

use std::{borrow::{Borrow, BorrowMut}, future::Future, io::{Cursor, Write}, ops::Deref, path::PathBuf, str::FromStr, sync::{Arc, OnceLock}, time::Duration};

use anyhow::anyhow;
use flutter_rust_bridge::{frb, IntoDart, JoinHandle};
use icloud_auth::{LoginState, AnisetteConfiguration, AppleAccount};
pub use icloud_auth::{VerifyBody, TrustedPhoneNumber};
use plist::{Data, Dictionary};
pub use plist::Value;
use prost::Message;
pub use rustpush::{PushError, IDSUser, IMClient, ConversationData, register};

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use tokio::{runtime::Runtime, select, sync::{broadcast, oneshot::{self, Sender}, Mutex, RwLock}};
use rustpush::{authenticate_apple, authenticate_phone, get_gsa_config, APSConnection, APSConnectionResource, APSState, Attachment, AuthPhone, MMCSFile, MessageInst, MessagePart, MessageParts, OSConfig, RelayConfig, ResourceState};
pub use rustpush::{MacOSConfig, HardwareConfig};
use uniffi::{deps::log::{info, error}, HandleAlloc};
use uuid::Uuid;
use std::io::Seek;
use async_recursion::async_recursion;

use crate::{frb_generated::{SseEncode, StreamSink}, init_logger, runtime};

use flutter_rust_bridge::for_generated::{SimpleHandler, SimpleExecutor, NoOpErrorListener, SimpleThreadPool, BaseAsyncRuntime, lazy_static};

pub type MyHandler = SimpleHandler<SimpleExecutor<NoOpErrorListener, SimpleThreadPool, MyAsyncRuntime>, NoOpErrorListener>;

#[derive(Debug, Default)]
pub struct MyAsyncRuntime();

impl BaseAsyncRuntime for MyAsyncRuntime {
    fn spawn<F>(&self, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        runtime().spawn(future)
    }
}

lazy_static! {
    pub static ref FLUTTER_RUST_BRIDGE_HANDLER: MyHandler = {
        MyHandler::new(
            SimpleExecutor::new(NoOpErrorListener, Default::default(), Default::default()),
            NoOpErrorListener,
        )
    };
}

#[frb(opaque)]
#[derive(Serialize, Deserialize, Clone)]
#[serde(tag = "type")]
pub enum JoinedOSConfig {
    MacOS(Arc<MacOSConfig>),
    Relay(Arc<RelayConfig>),
}

impl JoinedOSConfig {
    fn config(&self) -> Arc<dyn OSConfig> {
        match self {
            Self::MacOS(conf) => conf.clone(),
            Self::Relay(conf) => conf.clone(),
        }
    }
}

impl Deref for JoinedOSConfig {
    type Target = dyn OSConfig;

    fn deref(&self) -> &Self::Target {
        match self {
            Self::MacOS(conf) => conf.as_ref(),
            Self::Relay(conf) => conf.as_ref(),
        }
    }
}

#[derive(Serialize, Deserialize, Clone)]
struct SavedHardwareState {
    push: APSState,
    os_config: JoinedOSConfig,
}

pub enum RegistrationPhase {
    WantsOSConfig,
    WantsRegister,
    Registered,
}

#[frb(ignore)]
pub struct InnerPushState {
    pub conn: Option<APSConnection>,
    pub client: Option<IMClient>,
    pub conf_dir: PathBuf,
    pub os_config: Option<JoinedOSConfig>,
    pub account: Option<AppleAccount>,
    pub cancel_poll: Mutex<Option<Sender<()>>>
}

#[frb(opaque)]
pub struct PushState (RwLock<InnerPushState>);

pub async fn new_push_state(dir: String) -> Arc<PushState> {
    let dir = PathBuf::from_str(&dir).unwrap();
    init_logger(&dir);
    // flutter_rust_bridge::setup_default_user_utils();
    let state = PushState(RwLock::new(InnerPushState {
        conn: None,
        client: None,
        conf_dir: dir,
        os_config: None,
        account: None,
        cancel_poll: Mutex::new(None)
    }));
    restore(&state).await;
    Arc::new(state)
}

pub fn service_from_ptr(ptr: String) -> Arc<PushState> {
    let pointer: u64 = ptr.parse().unwrap();
    info!("using state {pointer}");
    let service = unsafe {
        Arc::from_raw(pointer as *const PushState)
    };
    service
}

fn plist_to_buf<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, plist::Error> {
    let mut buf: Vec<u8> = Vec::new();
    let writer = Cursor::new(&mut buf);
    plist::to_writer_xml(writer, &value)?;
    Ok(buf)
}

fn plist_to_string<T: serde::Serialize>(value: &T) -> Result<String, plist::Error> {
    plist_to_buf(value).map(|val| String::from_utf8(val).unwrap())
}

fn plist_to_bin<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, plist::Error> {
    let mut buf: Vec<u8> = Vec::new();
    let writer = Cursor::new(&mut buf);
    plist::to_writer_binary(writer, &value)?;
    Ok(buf)
}

async fn restore(curr_state: &PushState) {
    if !matches!(curr_state.get_phase().await, RegistrationPhase::WantsOSConfig) {
        panic!("Wrong phase! (restore)")
    }

    let mut inner = curr_state.0.write().await;

    let hw_config_path = inner.conf_dir.join("hw_info.plist");
    let id_path = inner.conf_dir.join("id.plist");

    info!("restoring now");

    // migrate
    if let Ok(config) = plist::from_file::<_, SavedHardwareState>(&inner.conf_dir.join("config.plist")) {
        std::fs::write(&hw_config_path, plist_to_string(&config).unwrap()).unwrap();
        let data: Value = plist::from_file(&inner.conf_dir.join("config.plist")).unwrap();
        std::fs::write(&id_path, plist_to_string(&data.as_dictionary().unwrap().get("users").unwrap()).unwrap()).unwrap();
        std::fs::remove_file(inner.conf_dir.join("config.plist")).unwrap();
        info!("migrated!");
    }

    if let Ok(mut value) = plist::from_file::<_, Dictionary>(&hw_config_path) {
        let os_config = value["os_config"].as_dictionary_mut().unwrap();
        if !os_config.contains_key("type") {
            os_config.insert("type".to_string(), Value::String("MacOS".to_string()));
        }
        std::fs::write(&hw_config_path, plist_to_string(&value).unwrap()).unwrap();
        info!("migrated two!");
    }

    // second migrate
    if let Ok(mut users) = plist::from_file::<_, Vec<Dictionary>>(&id_path) {
        for user in &mut users {
            if user.contains_key("handles") {
                // migrate!
                let handles = user.remove("handles").unwrap();
                let identity = user.get_mut("identity").unwrap().as_dictionary_mut().unwrap();
                let id_keypair = identity.remove("id_keypair").unwrap();

                let registration = Dictionary::from_iter([
                    ("id_keypair", id_keypair),
                    ("handles", handles),
                ].into_iter());
                user.insert("registration".to_string(), Value::Dictionary(registration));

                info!("migrated!")
            }
        }
        std::fs::write(&id_path, plist_to_string(&users).unwrap()).unwrap();
    }

    let Ok(state) = plist::from_file::<_, SavedHardwareState>(&hw_config_path) else { return };

    // even if we failed on the initial connection, we don't care cuz we're restoring.
    inner.os_config = Some(state.os_config);
    let (connection, _err) = setup_push(inner.os_config.as_ref().unwrap(), Some(&state.push), hw_config_path).await;
    inner.conn = Some(connection);

    // id may not exist yet; that's fine
    let Ok(users) = plist::from_file::<_, Vec<IDSUser>>(&id_path) else { return };

    info!("registration expires at {}", users[0].registration.as_ref().unwrap().get_exp().unwrap());

    inner.client = Some(IMClient::new(inner.conn.as_ref().unwrap().clone(), users, 
        inner.conf_dir.join("id_cache.plist"), inner.os_config.as_ref().unwrap().config(), Box::new(move |updated_keys| {
            println!("updated keys!!!");
            std::fs::write(&id_path, plist_to_string(&updated_keys).unwrap()).unwrap();
        })).await);
}

#[repr(C)]
pub struct DartSupportAction {
    pub url: String,
    pub button: String,
}

#[repr(C)]
pub struct DartSupportAlert {
    pub title: String,
    pub body: String,
    pub action: Option<DartSupportAction>,
}

pub async fn register_ids(state: &Arc<PushState>, users: &Vec<IDSUser>) -> anyhow::Result<Option<DartSupportAlert>> {
    let mut users = users.clone(); // don't take ownership in case of failure
    if !matches!(state.get_phase().await, RegistrationPhase::WantsRegister) {
        panic!("Wrong phase! (register_ids)")
    }
    let mut inner = state.0.write().await;
    let conn_state = inner.conn.as_ref().unwrap().clone();

    if let Err(err) = register(inner.os_config.as_deref().unwrap(), &*conn_state.state.read().await, &mut users).await {
        return if let PushError::CustomerMessage(support) = err {
            Ok(Some(unsafe { std::mem::transmute(support) }))
        } else {
            Err(anyhow!(err))
        }
    }
    let id_path = inner.conf_dir.join("id.plist");
    std::fs::write(&id_path, plist_to_string(&users).unwrap()).unwrap();

    inner.client = Some(IMClient::new(conn_state, users, inner.conf_dir.join("id_cache.plist"), inner.os_config.as_ref().unwrap().config(), Box::new(move |updated_keys| {
        std::fs::write(&id_path, plist_to_string(&updated_keys).unwrap()).unwrap();
    })).await);

    Ok(None)
}

async fn setup_push(config: &JoinedOSConfig, state: Option<&APSState>, state_path: PathBuf) -> (APSConnection, Option<PushError>) {
    let (conn, error) = APSConnectionResource::new(config.config(), state.cloned()).await;

    if error.is_none() {
        let state = SavedHardwareState {
            push: conn.state.read().await.clone(),
            os_config: config.clone()
        };
        std::fs::write(&state_path, plist_to_string(&state).unwrap()).unwrap();
    }

    let mut to_refresh = conn.generated_signal.subscribe();
    let reconn_conn = Arc::downgrade(&conn);
    let config_ref = config.clone();
    tokio::spawn(async move {
        loop {
            match to_refresh.recv().await {
                Ok(()) => {
                    let Some(conn) = reconn_conn.upgrade() else { break };
                    // update keys
                    let state = SavedHardwareState {
                        push: conn.state.read().await.clone(),
                        os_config: config_ref.clone()
                    };
                    std::fs::write(&state_path, plist_to_string(&state).unwrap()).unwrap();
                },
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    (conn, error)
}

pub async fn configure_app_review(state: &Arc<PushState>) -> anyhow::Result<()> {
    let inner = state.0.write().await;
    std::fs::write(inner.conf_dir.join("id.plist"), include_str!("id_testing.plist"))?;
    std::fs::write(inner.conf_dir.join("hw_info.plist"), include_str!("hw_testing.plist"))?;
    drop(inner);
    restore(state).await;
    Ok(())
}

pub async fn configure_macos(state: &Arc<PushState>, config: &JoinedOSConfig) -> anyhow::Result<()> {
    let config = config.clone();
    let mut inner = state.0.write().await;
    inner.os_config = Some(config.clone());
    let conf_path = inner.conf_dir.join("hw_info.plist");
    let (connection, err) = setup_push(inner.os_config.as_ref().unwrap(), None, conf_path).await;
    if let Some(err) = err {
        return Err(err.into())
    }
    inner.conn = Some(connection);
    Ok(())
}

pub struct DartHwExtra {
    pub version: String,
    pub protocol_version: u32,
    pub device_id: String,
    pub icloud_ua: String,
    pub aoskit_version: String,
}

pub fn config_from_validation_data(data: Vec<u8>, extra: DartHwExtra) -> anyhow::Result<JoinedOSConfig> {
    let inner = HardwareConfig::from_validation_data(&data)?;
    Ok(JoinedOSConfig::MacOS(Arc::new(MacOSConfig {
        inner,
        version: extra.version,
        protocol_version: extra.protocol_version,
        device_id: extra.device_id,
        icloud_ua: extra.icloud_ua,
        aoskit_version: extra.aoskit_version,
    })))
}

pub async fn config_from_relay(code: String, host: String, token: &Option<String>) -> anyhow::Result<JoinedOSConfig> {
    Ok(JoinedOSConfig::Relay(Arc::new(RelayConfig {
        version: RelayConfig::get_versions(&host, &code, token).await?,
        icloud_ua: "com.apple.iCloudHelper/282 CFNetwork/1408.0.4 Darwin/22.5.0".to_string(),
        aoskit_version: "com.apple.AOSKit/282 (com.apple.accountsd/113)".to_string(),
        dev_uuid: Uuid::new_v4().to_string(),
        protocol_version: 1660,
        host: host.clone(),
        code: code.clone(),
        beeper_token: token.clone(),
    })))
}

pub struct DartDeviceInfo {
    pub name: String,
    pub serial: String,
    pub os_version: String,
    pub encoded_data: Option<Vec<u8>>,
}

pub async fn get_device_info_state(state: &Arc<PushState>) -> anyhow::Result<DartDeviceInfo> {
    let locked = state.0.read().await;
    get_device_info(locked.os_config.as_ref().unwrap())
}

pub async fn get_config_state(state: &Arc<PushState>) -> Option<JoinedOSConfig> {
    let locked = state.0.read().await;
    locked.os_config.clone()
}

pub fn get_device_info(config: &JoinedOSConfig) -> anyhow::Result<DartDeviceInfo> {
    let debug_info = config.get_debug_meta();
    Ok(DartDeviceInfo {
        name: debug_info.hardware_version.clone(),
        serial: debug_info.serial_number.clone(),
        os_version: debug_info.user_version.clone(),
        encoded_data: match config {
            JoinedOSConfig::MacOS(config) => {
                let copied = config.as_ref().clone();
                Some(crate::bbhwinfo::HwInfo {
                    inner: Some(crate::bbhwinfo::hw_info::InnerHwInfo {
                        product_name: copied.inner.product_name,
                        io_mac_address: copied.inner.io_mac_address.to_vec(),
                        platform_serial_number: copied.inner.platform_serial_number,
                        platform_uuid: copied.inner.platform_uuid,
                        root_disk_uuid: copied.inner.root_disk_uuid,
                        board_id: copied.inner.board_id,
                        os_build_num: copied.inner.os_build_num,
                        platform_serial_number_enc: copied.inner.platform_serial_number_enc,
                        platform_uuid_enc: copied.inner.platform_uuid_enc,
                        root_disk_uuid_enc: copied.inner.root_disk_uuid_enc,
                        rom: copied.inner.rom,
                        rom_enc: copied.inner.rom_enc,
                        mlb: copied.inner.mlb,
                        mlb_enc: copied.inner.mlb_enc
                    }),
                    version: copied.version,
                    protocol_version: copied.protocol_version as i32,
                    device_id: copied.device_id,
                    icloud_ua: copied.icloud_ua,
                    aoskit_version: copied.aoskit_version,
                }.encode_to_vec())
            },
            JoinedOSConfig::Relay(_) => None
        }
    })
}

pub fn config_from_encoded(encoded: Vec<u8>) -> anyhow::Result<JoinedOSConfig> {
    let copied = crate::bbhwinfo::HwInfo::decode(&mut Cursor::new(encoded))?;
    let inner = copied.inner.unwrap();
    Ok(JoinedOSConfig::MacOS(Arc::new(MacOSConfig {
        inner: HardwareConfig {
            product_name: inner.product_name,
            io_mac_address: inner.io_mac_address.try_into().unwrap(),
            platform_serial_number: inner.platform_serial_number,
            platform_uuid: inner.platform_uuid,
            root_disk_uuid: inner.root_disk_uuid,
            board_id: inner.board_id,
            os_build_num: inner.os_build_num,
            platform_serial_number_enc: inner.platform_serial_number_enc,
            platform_uuid_enc: inner.platform_uuid_enc,
            root_disk_uuid_enc: inner.root_disk_uuid_enc,
            rom: inner.rom,
            rom_enc: inner.rom_enc,
            mlb: inner.mlb,
            mlb_enc: inner.mlb_enc
        },
        version: copied.version,
        protocol_version: copied.protocol_version as u32,
        device_id: copied.device_id,
        icloud_ua: copied.icloud_ua,
        aoskit_version: copied.aoskit_version,
    })))
}


pub fn ptr_to_dart(ptr: String) -> DartIMessage {
    let pointer: u64 = ptr.parse().unwrap();
    info!("using pointer {pointer}");
    let recieved = unsafe {
        Box::from_raw(pointer as *mut DartIMessage)
    };
    *recieved
}


#[frb]
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


#[frb(non_opaque)]
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
#[derive(Serialize, Deserialize)]
#[frb(type_64bit_int)]
pub struct DartMMCSFile {
    #[serde(serialize_with = "bin_serialize", deserialize_with = "bin_deserialize")]
    pub signature: Vec<u8>,
    pub object: String,
    pub url: String,
    #[serde(serialize_with = "bin_serialize", deserialize_with = "bin_deserialize")]
    pub key: Vec<u8>,
    pub size: usize
}

impl DartMMCSFile {
    fn get_raw(&self) -> &MMCSFile {
        unsafe { std::mem::transmute(self) }
    }
}

impl From<MMCSFile> for DartMMCSFile {
    fn from(value: MMCSFile) -> Self {
        unsafe { std::mem::transmute(value) }
    }
}

pub fn bin_serialize<S>(x: &[u8], s: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    s.serialize_bytes(x)
}

pub fn bin_deserialize<'de, D>(d: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    let s: Data = Deserialize::deserialize(d)?;
    Ok(s.into())
}

#[repr(C)]
#[derive(Serialize, Deserialize)]
pub enum DartAttachmentType {
    Inline(#[serde(serialize_with = "bin_serialize", deserialize_with = "bin_deserialize")] Vec<u8>),
    MMCS(DartMMCSFile)
}

#[repr(C)]
#[derive(Serialize, Deserialize)]
#[frb(type_64bit_int)]
pub struct DartAttachment {
    pub a_type: DartAttachmentType,
    pub part_idx: u64,
    pub uti_type: String,
    pub mime: String,
    pub name: String,
    pub iris: bool
}

impl DartAttachment {
    pub fn save(&self) -> String {
        plist_to_string(self).unwrap()
    }

    pub fn restore(saved: String) -> DartAttachment {
        plist::from_reader_xml(Cursor::new(saved)).unwrap()
    }

    #[frb(type_64bit_int)]
    pub fn get_size(&self) -> usize {
        self.get_raw().get_size()
    }

    fn get_raw(&self) -> &Attachment {
        unsafe { std::mem::transmute(self) }
    }
}

impl From<Attachment> for DartAttachment {
    fn from(value: Attachment) -> Self {
        unsafe { std::mem::transmute(value) }
    }
}

#[repr(C)]
pub enum DartMessagePart {
    Text(String),
    Attachment(DartAttachment),
    Mention(String, String),
    Object(String),
}

#[repr(C)]
#[frb(type_64bit_int)]
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
#[frb(type_64bit_int)]
pub struct DartIndexedMessagePart {
    pub part: DartMessagePart,
    pub idx: Option<usize>,
    pub ext: Option<DartPartExtension>,
}

#[repr(C)]
pub struct DartMessageParts(pub Vec<DartIndexedMessagePart>);

impl DartMessageParts {
    fn get_raw(&self) -> &MessageParts {
        unsafe { std::mem::transmute(self) }
    }

    pub fn as_plain(&self) -> String {
        self.get_raw().raw_text()
    }
}


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
pub enum NSDictionaryClass {
    NSDictionary,
    NSMutableDictionary,
}

#[repr(C)]
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
pub struct DartBalloon {
    pub url: String,
    pub session: Option<String>, // UUID
    pub layout: DartBalloonLayout,
    pub ld_text: Option<String>,
    pub is_live: bool,

    pub icon: Vec<u8>,
}

#[repr(C)]
#[frb(type_64bit_int)]
pub struct DartExtensionApp {
    pub name: String,
    pub app_id: u64,
    pub bundle_id: String,

    pub balloon: Option<DartBalloon>,
}

#[frb]
#[repr(C)]
pub struct DartNormalMessage {
    #[frb(non_final)]
    pub parts: DartMessageParts,
    #[frb(non_final)]
    pub effect: Option<String>,
    #[frb(non_final)]
    pub reply_guid: Option<String>,
    #[frb(non_final)]
    pub reply_part: Option<String>,
    pub service: DartMessageType,
    #[frb(non_final)]
    pub subject: Option<String>,
    #[frb(non_final)]
    pub app: Option<DartExtensionApp>,
    #[frb(non_final)]
    pub link_meta: Option<DartLinkMeta>,
}

#[repr(C)]
pub struct NSURL {
    pub base: String,
    pub relative: String,
}

#[repr(C)]
pub struct LPImageMetadata {
    pub size: String,
    pub url: NSURL,
    pub version: u8,
}

#[repr(C)]
pub struct LPIconMetadata {
    pub url: NSURL,
    pub version: u8,
}

#[repr(C)]
pub struct RichLinkImageAttachmentSubstitute {
    pub mime_type: String,
    pub rich_link_image_attachment_substitute_index: u64,
}

#[repr(C)]
pub enum NSArrayClass {
    NSArray,
    NSMutableArray,
}

// FRB doesn't support generics
// the things i do for this bridge...
#[repr(C)]
pub struct NSArrayImageArray {
    pub objects: Vec<LPImageMetadata>,
    pub class: NSArrayClass,
}

#[repr(C)]
pub struct NSArrayIconArray {
    pub objects: Vec<LPIconMetadata>,
    pub class: NSArrayClass,
}

#[repr(C)]
pub struct LPLinkMetadata {
    pub image_metadata: Option<LPImageMetadata>,
    pub version: u8,
    pub icon_metadata: Option<LPIconMetadata>,
    pub original_url: NSURL,
    pub url: Option<NSURL>,
    pub title: Option<String>,
    pub summary: Option<String>,
    pub image: Option<RichLinkImageAttachmentSubstitute>,
    pub icon: Option<RichLinkImageAttachmentSubstitute>,
    pub images: Option<NSArrayImageArray>,
    pub icons: Option<NSArrayIconArray>,
}


#[repr(C)]
pub struct DartLinkMeta {
    pub data: LPLinkMetadata,
    pub attachments: Vec<Vec<u8>>,
}

#[repr(C)]
pub struct DartRenameMessage {
    pub new_name: String
}

#[repr(C)]
#[frb(type_64bit_int)]
pub struct DartChangeParticipantMessage {
    pub new_participants: Vec<String>,
    pub group_version: u64
}

#[repr(C)]
pub enum DartReaction {
    Heart,
    Like,
    Dislike,
    Laugh,
    Emphsize,
    Question
}

#[repr(C)]
#[frb(non_opaque)]
pub enum DartReactMessageType {
    React {
        reaction: DartReaction,
        enable: bool,
    },
    Extension {
        spec: DartExtensionApp,
        body: DartMessageParts
    },
}

#[repr(C)]
#[frb(type_64bit_int)]
pub struct DartReactMessage {
    pub to_uuid: String,
    pub to_part: Option<u64>,
    pub reaction: DartReactMessageType,
    pub to_text: String,
}

#[repr(C)]
#[frb(type_64bit_int)]
pub struct DartUnsendMessage {
    pub tuuid: String,
    pub edit_part: u64,
}

#[repr(C)]
#[frb(type_64bit_int)]
pub struct DartEditMessage {
    pub tuuid: String,
    pub edit_part: u64,
    pub new_parts: DartMessageParts
}

#[repr(C)]
#[frb(type_64bit_int)]
pub struct DartIconChangeMessage {
    pub file: Option<DartMMCSFile>,
    pub group_version: u64
}

#[repr(C)]
pub struct DartUpdateExtensionMessage {
    pub for_uuid: String,
    pub ext: DartPartExtension,
}

#[repr(C)]
pub struct DartErrorMessage {
    pub for_uuid: String,
    pub status: u64,
    pub status_str: String,
}

#[repr(C)]
#[frb(non_opaque)]
pub enum DartMessage {
    Message(DartNormalMessage),
    RenameMessage(DartRenameMessage),
    ChangeParticipants(DartChangeParticipantMessage),
    React(DartReactMessage),
    Delivered,
    Read,
    Typing,
    Unsend(DartUnsendMessage),
    Edit(DartEditMessage),
    IconChange(DartIconChangeMessage),
    StopTyping,
    EnableSmsActivation(bool),
    MessageReadOnDevice,
    SmsConfirmSent(bool),
    MarkUnread, // send for last message from other participant
    PeerCacheInvalidate,
    UpdateExtension(DartUpdateExtensionMessage),
    Error(DartErrorMessage),
}

#[repr(C)]
pub enum DartMessageTarget {
    Token(Vec<u8>),
    Uuid(String),
}

#[frb(type_64bit_int)]
#[repr(C)]
pub struct DartIMessage {
    #[frb(non_final)]
    pub id: String,
    #[frb(non_final)]
    pub sender: Option<String>,
    #[frb(non_final)]
    pub conversation: Option<DartConversationData>,
    #[frb(non_final)]
    pub message: DartMessage,
    #[frb(non_final)]
    pub sent_timestamp: u64,
    #[frb(non_final)]
    pub target: Option<Vec<DartMessageTarget>>,
    #[frb(non_final)]
    pub send_delivered: bool,
}

impl Into<rustpush::Message> for DartMessage {
    fn into(self) -> rustpush::Message {
        unsafe { std::mem::transmute(self) }
    }
}

impl Into<ConversationData> for DartConversationData {
    fn into(self) -> ConversationData {
        unsafe { std::mem::transmute(self) }
    }
}

impl From<MessageInst> for DartIMessage {
    fn from(value: MessageInst) -> Self {
        unsafe { std::mem::transmute(value) }
    }
}

impl DartIMessage {
    fn to_imsg(self) -> MessageInst {
        unsafe { std::mem::transmute(self) }
    }
}

pub enum PollResult {
    Stop,
    Cont(Option<DartIMessage>),
}

pub async fn recv_wait(state: &Arc<PushState>) -> PollResult {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (recv_wait)")
    }
    let (send, recv) = oneshot::channel();
    let recv_path = state.0.read().await;
    *recv_path.cancel_poll.lock().await = Some(send);
    select! {
        msg = recv_path.client.as_ref().expect("no client??/").receive_wait() => {
            *recv_path.cancel_poll.lock().await = None;
            let msg = match msg {
                Ok(msg) => msg,
                Err(err) => {
                    // log and ignore for now
                    error!("{}", err);
                    return PollResult::Cont(None);
                }
            };
            PollResult::Cont(unsafe { std::mem::transmute(msg) })
        }
        _cancel = recv => {
            PollResult::Stop
        }
    }
}

pub async fn send(state: &Arc<PushState>, msg: DartIMessage) -> anyhow::Result<()> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (send)")
    }
    let mut msg = msg.to_imsg();
    println!("sending_1");
    let inner = state.0.read().await;
    println!("sending_2");
    inner.client.as_ref().unwrap().send(&mut msg).await?;
    println!("sending_3");
    Ok(())
}

pub async fn get_handles(state: &Arc<PushState>) -> anyhow::Result<Vec<String>> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (send)")
    }
    Ok(state.0.read().await.client.as_ref().unwrap().identity.get_handles().await.to_vec())
}

pub async fn do_reregister(state: &Arc<PushState>) -> anyhow::Result<()> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (send)")
    }
    state.0.read().await.client.as_ref().unwrap().identity.refresh_now().await?;
    Ok(())
}

pub async fn new_msg(state: &Arc<PushState>, conversation: DartConversationData, sender: String, message: DartMessage) -> DartIMessage {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (new_msg)")
    }
    MessageInst::new(conversation.into(), &sender, message.into()).into()
}

pub async fn validate_targets(state: &Arc<PushState>, targets: Vec<String>, sender: String) -> anyhow::Result<Vec<String>> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (validate_targets)")
    }
    Ok(state.0.read().await.client.as_ref().unwrap().identity.validate_targets(&targets, &sender).await?)
}

pub async fn get_phase(state: &Arc<PushState>) -> RegistrationPhase {
    state.get_phase().await
}

#[frb(type_64bit_int)]
pub struct TransferProgress {
    pub prog: usize,
    pub total: usize,
    pub attachment: Option<DartAttachment>
}

pub async fn download_attachment(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, attachment: DartAttachment, path: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;
        println!("donwloading file {}", path);
        let path = std::path::Path::new(&path);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;
        let mut file = std::fs::File::create(path)?;
        attachment.get_raw().get_attachment(inner.conn.as_ref().unwrap(), &mut file, &mut |prog, total| {
            println!("donwloading file {} of {}", prog, total);
            sink.add(TransferProgress {
                prog,
                total,
                attachment: None
            }).unwrap();
        }).await?;
        file.flush()?;
        Ok(())
    }).await
}

pub async fn download_mmcs(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, attachment: DartMMCSFile, path: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;
        let path = std::path::Path::new(&path);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;

        let mut file = std::fs::File::create(path)?;
        attachment.get_raw().get_attachment(inner.conn.as_ref().unwrap(), &mut file, &mut |prog, total| {
            sink.add(TransferProgress {
                prog,
                total,
                attachment: None
            }).unwrap();
        }).await?;
        file.flush()?;
        Ok(())
    }).await
}

async fn wrap_sink<Fut, T: SseEncode + Send + Sync>(sink: &StreamSink<T>, f: impl FnOnce() -> Fut)
    where Fut: Future<Output = anyhow::Result<()>> {
    if let Err(err) = f().await {
        sink.add_error(err).unwrap();
    }
}

#[frb(type_64bit_int)]
pub struct MMCSTransferProgress {
    pub prog: usize,
    pub total: usize,
    pub file: Option<DartMMCSFile>
}

pub async fn upload_mmcs(sink: StreamSink<MMCSTransferProgress>, state: &Arc<PushState>, path: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;

        let mut file = std::fs::File::open(path)?;
        let prepared = MMCSFile::prepare_put(&mut file).await?;
        file.rewind()?;
        let attachment = MMCSFile::new(inner.conn.as_ref().unwrap(), &prepared, &mut file, &mut |prog, total| {
            sink.add(MMCSTransferProgress {
                prog,
                total,
                file: None
            }).unwrap();
        }).await?;
        sink.add(MMCSTransferProgress { prog: 0, total: 0, file: Some(attachment.into()) }).unwrap();
        Ok(())
    }).await
}

pub async fn upload_attachment(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, path: String, mime: String, uti: String, name: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;

        let mut file = std::fs::File::open(path)?;
        let prepared = MMCSFile::prepare_put(&mut file).await?;
        file.rewind()?;
        let attachment = Attachment::new_mmcs(inner.conn.as_ref().unwrap(), &prepared, &mut file, &mime, &uti, &name, &mut |prog, total| {
            sink.add(TransferProgress {
                prog,
                total,
                attachment: None
            }).unwrap();
        }).await?;
        sink.add(TransferProgress { prog: 0, total: 0, attachment: Some(attachment.into()) }).unwrap();
        Ok(())
    }).await
}

pub async fn get_token(state: &Arc<PushState>) -> Vec<u8> {
    let connection = state.0.read().await.conn.as_ref().unwrap().clone();

    connection.get_token().await.to_vec()
}

pub fn save_user(user: &IDSUser) -> anyhow::Result<String> {
    Ok(plist_to_string(user)?)
}

pub fn restore_user(user: String) -> anyhow::Result<IDSUser> {
    Ok(plist::from_reader(Cursor::new(user))?)
}

pub async fn try_auth(state: &Arc<PushState>, username: String, password: String) -> anyhow::Result<(DartLoginState, Option<IDSUser>)> {
    let mut inner = state.0.write().await;
    let anisette_config = AnisetteConfiguration::new()
        .set_client_info(get_gsa_config(&*inner.conn.as_ref().unwrap().state.read().await, inner.os_config.as_deref().unwrap()))
        .set_configuration_path(inner.conf_dir.join("anisette_test"));
    let mut apple_account = AppleAccount::new(anisette_config).await?;
    let mut login_state = apple_account.login_email_pass(&username, &password).await?;

    let mut user = None;
    if let Some(pet) = apple_account.get_pet() {
        let identity = authenticate_apple(username.trim(), &pet, inner.os_config.as_deref().unwrap()).await?;
        user = Some(identity);
        
        // who needs extra steps when you have a PET, amirite?
        println!("confirmed login {:?}", login_state);
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    inner.account = Some(apple_account);
    
    Ok((unsafe { std::mem::transmute(login_state) }, user))
}

pub async fn auth_phone(state: &Arc<PushState>, number: String, sig: Vec<u8>) -> anyhow::Result<IDSUser> {
    let inner = state.0.read().await;

    let identity = authenticate_phone(&number, AuthPhone {
        push_token: inner.conn.as_deref().unwrap().get_token().await.to_vec().into(),
        sigs: vec![sig.into()]
    }, inner.os_config.as_deref().unwrap()).await?;

    Ok(identity)
}

pub async fn send_2fa_to_devices(state: &Arc<PushState>) -> anyhow::Result<DartLoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    Ok(unsafe { std::mem::transmute(account.send_2fa_to_devices().await?) })
    
}

pub async fn verify_2fa(state: &Arc<PushState>, code: String) -> anyhow::Result<(DartLoginState, Option<IDSUser>)> {
    let mut inner = state.0.write().await;
    let account = inner.account.as_mut().unwrap();
    let mut login_state = account.verify_2fa(code).await?;
    let account = inner.account.as_ref().unwrap();
    
    let mut user = None;
    if let Some(pet) = account.get_pet() {
        let identity = authenticate_apple(account.username.as_ref().unwrap().trim(), &pet, inner.os_config.as_deref().unwrap()).await?;
        user = Some(identity);
        
        // who needs extra steps when you have a PET, amirite?
        println!("confirmed login {:?}", login_state);
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    Ok((unsafe { std::mem::transmute(login_state) }, user))
}

#[repr(C)]
pub struct DartTrustedPhoneNumber {
    pub number_with_dial_code: String,
    pub last_two_digits: String,
    pub push_mode: String,
    pub id: u32
}

pub async fn get_2fa_sms_opts(state: &Arc<PushState>) -> anyhow::Result<(Vec<DartTrustedPhoneNumber>, Option<DartLoginState>)> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    let extras = account.get_auth_extras().await?;
    Ok((
        extras.trusted_phone_numbers.into_iter().map(|i| unsafe { std::mem::transmute(i) }).collect(),
        extras.new_state.map(|i| unsafe { std::mem::transmute(i) })
    ))
}

pub async fn send_2fa_sms(state: &Arc<PushState>, phone_id: u32) -> anyhow::Result<DartLoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    Ok(unsafe { std::mem::transmute(account.send_sms_2fa_to_devices(phone_id).await?) })
}

pub async fn verify_2fa_sms(state: &Arc<PushState>, body: &VerifyBody, code: String) -> anyhow::Result<(DartLoginState, Option<IDSUser>)> {
    let mut inner = state.0.write().await;
    let account = inner.account.as_mut().unwrap();
    let mut login_state = account.verify_sms_2fa(code, body.clone()).await?;
    let account = inner.account.as_ref().unwrap();
    
    let mut user = None;
    if let Some(pet) = account.get_pet() {
        let identity = authenticate_apple(account.username.as_ref().unwrap().trim(), &pet, inner.os_config.as_deref().unwrap()).await?;
        user = Some(identity);
        
        // who needs extra steps when you have a PET, amirite?
        println!("confirmed login {:?}", login_state);
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    Ok((unsafe { std::mem::transmute(login_state) }, user))
}

pub async fn validate_cert(state: &Arc<PushState>, user: &IDSUser) -> anyhow::Result<Vec<String>> {
    let inner = state.0.read().await;
    let x = Ok(user.get_possible_handles(&*inner.conn.as_ref().unwrap().state.read().await).await?);
    x
}

pub async fn reset_state(state: &Arc<PushState>, reset_hw: bool) -> anyhow::Result<()> {
    // tell any poll to stop
    let inner = state.0.read().await;
    if let Some(cancel) = inner.cancel_poll.lock().await.take() {
        cancel.send(()).unwrap();
    }
    drop(inner);
    let mut inner = state.0.write().await;
    info!("a");
    let conn_state = inner.conn.as_ref().unwrap().clone();
    info!("b {:?}", inner.os_config.is_some());
    inner.client = None;
    // try deregistering from iMessage, but if it fails we don't really care
    let _ = register(inner.os_config.as_deref().unwrap(), &*conn_state.state.read().await, &mut []).await;
    info!("c");
    inner.account = None;
    let _ = std::fs::remove_file(inner.conf_dir.join("id.plist"));
    let _ = std::fs::remove_file(inner.conf_dir.join("id_cache.plist"));

    if reset_hw {
        inner.conn = None;
        inner.os_config = None;
        let _ = std::fs::remove_file(inner.conf_dir.join("hw_info.plist"));
    }

    Ok(())
}

pub async fn invalidate_id_cache(state: &Arc<PushState>) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    inner.client.as_ref().unwrap().identity.invalidate_id_cache().await;
    Ok(())
}

impl PushState {
    async fn get_phase(&self) -> RegistrationPhase {
        let inner = self.0.read().await;
        if inner.os_config.is_none() {
            return RegistrationPhase::WantsOSConfig
        }
        if inner.client.is_none() {
            return RegistrationPhase::WantsRegister
        }
        RegistrationPhase::Registered
    }
}

// NOTE, breaks linux registration for some god stupid awful reason
// only valid before registration
pub async fn get_user_name(state: &Arc<PushState>) -> anyhow::Result<String> {
    let inner = state.0.read().await;
    let (first, last) = inner.account.as_ref().unwrap().get_name();
    Ok(format!("{first} {last}"))
}


#[frb(type_64bit_int)]
pub enum DartRegisterState {
    Registered {
        next_s: i64,
    },
    Registering,
    Failed {
        retry_wait: Option<u64>,
        error: String
    }
}

pub async fn get_regstate(state: &Arc<PushState>) -> anyhow::Result<DartRegisterState> {
    let inner = state.0.read().await;
    let mutex_ref = inner.client.as_ref().unwrap().identity.resource_state.lock().await;
    Ok(match &*mutex_ref {
        ResourceState::Generating => DartRegisterState::Registering,
        ResourceState::Generated => DartRegisterState::Registered {
            next_s: inner.client.as_ref().unwrap().identity.calculate_rereg_time_s().await
        },
        ResourceState::Failed(failure) => 
            DartRegisterState::Failed { retry_wait: failure.retry_wait, error: format!("{}", failure.error) },
    })
}

pub async fn convert_token_to_uuid(state: &Arc<PushState>, handle: String, token: Vec<u8>) -> anyhow::Result<String> {
    let inner = state.0.read().await;
    let uuid = inner.client.as_ref().unwrap().identity.token_to_uuid(&handle, &token).await?;
    Ok(uuid)
}

#[repr(C)]
pub struct DartPrivateDeviceInfo {
    pub uuid: Option<String>,
    pub device_name: Option<String>,
    pub token: Vec<u8>,
    pub is_hsa_trusted: bool,
    pub identites: Vec<String>,
    pub sub_services: Vec<String>,
}

pub async fn get_sms_targets(state: &Arc<PushState>, handle: String, refresh: bool) -> anyhow::Result<Vec<DartPrivateDeviceInfo>> {
    let inner = state.0.read().await;
    let targets = inner.client.as_ref().unwrap().identity.get_sms_targets(&handle, refresh).await?;
    Ok(unsafe { std::mem::transmute(targets) })
}
