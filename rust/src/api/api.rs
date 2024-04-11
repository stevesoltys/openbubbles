

use std::{borrow::{Borrow, BorrowMut}, io::{Cursor, Write}, path::PathBuf, str::FromStr, sync::Arc, time::Duration};

use anyhow::anyhow;
use flutter_rust_bridge::{frb, IntoDart};
use icloud_auth::{LoginState, AnisetteConfiguration, AppleAccount};
pub use icloud_auth::{VerifyBody, TrustedPhoneNumber};
pub use rustpush::{APNSState, APNSConnection, IDSAppleUser, PushError, Message, IDSUser, IMClient, IMessage, ConversationData, register};

use serde::{Serialize, Deserialize};
use tokio::{runtime::Runtime, select, sync::{oneshot::{self, Sender}, Mutex, RwLock}};
use rustpush::{init_logger, Attachment, BalloonBody, MMCSFile, MessagePart, MessageParts, OSConfig, RegisterState};
pub use rustpush::{MacOSConfig, HardwareConfig};
use uniffi::{deps::log::info, HandleAlloc};
use std::io::Seek;
use async_recursion::async_recursion;

use crate::{frb_generated::{RustOpaque, StreamSink}, runtime};
use bincode::Options;


#[derive(Serialize, Deserialize, Clone)]
struct SavedState {
    push: APNSState,
    users: Vec<IDSUser>,
    os_config: MacOSConfig,
}

pub enum RegistrationPhase {
    WantsOSConfig,
    WantsUserPass,
    WantsRegister,
    Registered,
}

pub struct InnerPushState {
    pub conn: Option<Arc<APNSConnection>>,
    pub users: Vec<IDSUser>,
    pub client: Option<IMClient>,
    pub conf_dir: PathBuf,
    pub os_config: Option<Arc<MacOSConfig>>,
    pub account: Option<AppleAccount>,
    pub cancel_poll: Mutex<Option<Sender<()>>>
}

pub struct PushState (pub RwLock<InnerPushState>);

pub async fn new_push_state(dir: String) -> anyhow::Result<Arc<PushState>> {
    #[cfg(target_os = "android")]
    android_log::init("rustpush").unwrap();
    #[cfg(not(target_os = "android"))]
    init_logger();
    let state = PushState(RwLock::new(InnerPushState {
        conn: None,
        users: vec![],
        client: None,
        conf_dir: PathBuf::from_str(&dir).unwrap(),
        os_config: None,
        account: None,
        cancel_poll: Mutex::new(None)
    }));
    if PathBuf::from_str(&dir).unwrap().join("config.plist").exists() {
        restore(&state).await?;
    }
    Ok(Arc::new(state))
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

async fn restore(curr_state: &PushState) -> anyhow::Result<()> {
    if !matches!(curr_state.get_phase().await, RegistrationPhase::WantsOSConfig) {
        panic!("Wrong phase! (restore)")
    }

    let mut inner = curr_state.0.write().await;
    let conf_path = inner.conf_dir.join("config.plist");
    let mut state: SavedState = plist::from_file(&conf_path)?;

    let connection = setup_push_rec(&state.os_config, Some(&state.push)).await;
    inner.os_config = Some(Arc::new(state.os_config.clone()));
    inner.conn = Some(connection);

    println!("registration expires at {}", state.users[0].identity.as_ref().unwrap().get_exp().unwrap());

    inner.client = Some(IMClient::new(inner.conn.as_ref().unwrap().clone(), state.users.clone(), 
        inner.conf_dir.join("id_cache.plist"), inner.os_config.clone().unwrap(), Box::new(move |updated_keys| {
            println!("updated keys!!!");
            state.users = updated_keys;
            std::fs::write(&conf_path, plist_to_string(&state).unwrap()).unwrap();
        })).await);
    Ok(())
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

pub async fn register_ids(state: &Arc<PushState>) -> anyhow::Result<Option<DartSupportAlert>> {
    if !matches!(state.get_phase().await, RegistrationPhase::WantsRegister) {
        panic!("Wrong phase! (register_ids)")
    }
    let mut inner = state.0.write().await;
    let conn_state = inner.conn.as_ref().unwrap().clone();

    let mut empty_users = vec![];
    std::mem::swap(&mut empty_users, &mut inner.users);
    if let Err(err) = register(inner.os_config.as_ref().unwrap().as_ref(), &mut empty_users, &conn_state).await {
        return if let PushError::CustomerMessage(support) = err {
            Ok(Some(unsafe { std::mem::transmute(support) }))
        } else {
            Err(anyhow!(err))
        }
    }
    let conf_path = inner.conf_dir.join("config.plist");
    let conf_path_dup = conf_path.clone();

    let mut state = SavedState {
        push: inner.conn.as_ref().unwrap().clone_state().await,
        users: empty_users.clone(),
        os_config: inner.os_config.as_ref().unwrap().as_ref().clone()
    };
    std::fs::write(&conf_path_dup, plist_to_string(&state).unwrap()).unwrap();

    inner.client = Some(IMClient::new(conn_state, empty_users, inner.conf_dir.join("id_cache.plist"), inner.os_config.clone().unwrap(), Box::new(move |updated_keys| {
        state.users = updated_keys;
        std::fs::write(&conf_path, plist_to_string(&state).unwrap()).unwrap();
    })).await);

    Ok(None)
}

async fn setup_push(config: &dyn OSConfig, state: Option<&APNSState>) -> anyhow::Result<Arc<APNSConnection>> {
    let connection = Arc::new(APNSConnection::new(config, state.cloned()).await?);
    connection.submitter.set_state(1).await?;
    connection.submitter.filter(&["com.apple.madrid"]).await?;
    Ok(connection)
}

#[async_recursion]
async fn setup_push_rec(config: &dyn OSConfig, state: Option<&APNSState>) -> Arc<APNSConnection> {
    let Ok(push) = setup_push(config, state).await else {
        tokio::time::sleep(Duration::from_secs(30)).await;
        return setup_push_rec(config, state).await;
    };
    push
}

pub async fn configure_macos(state: &Arc<PushState>, config: MacOSConfig) -> anyhow::Result<()> {
    let mut inner = state.0.write().await;
    let connection = setup_push_rec(&config, None).await;
    inner.os_config = Some(Arc::new(config));
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

pub fn config_from_validation_data(data: Vec<u8>, extra: DartHwExtra) -> anyhow::Result<MacOSConfig> {
    let inner = HardwareConfig::from_validation_data(&data)?;
    Ok(MacOSConfig {
        inner,
        version: extra.version,
        protocol_version: extra.protocol_version,
        device_id: extra.device_id,
        icloud_ua: extra.icloud_ua,
        aoskit_version: extra.aoskit_version,
    })
}

pub struct DartDeviceInfo {
    pub name: String,
    pub serial: String,
    pub os_version: String,
    pub encoded_data: Vec<u8>,
}

pub async fn get_device_info_state(state: &Arc<PushState>) -> anyhow::Result<DartDeviceInfo> {
    let locked = state.0.read().await;
    get_device_info(locked.os_config.as_ref().unwrap())
}

pub fn get_device_info(config: &MacOSConfig) -> anyhow::Result<DartDeviceInfo> {
    Ok(DartDeviceInfo {
        name: config.inner.product_name.clone(),
        serial: config.inner.platform_serial_number.clone(),
        os_version: config.version.clone(),
        encoded_data: bincode::DefaultOptions::new().serialize(config).unwrap()
    })
}

pub fn config_from_encoded(encoded: Vec<u8>) -> anyhow::Result<MacOSConfig> {
    Ok(bincode::DefaultOptions::new().deserialize(&encoded)?)
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
pub struct DartBalloonBody {
    #[frb(non_final)]
    pub bid: String,
    #[frb(non_final)]
    pub data: Vec<u8>
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
pub struct DartMMCSFile {
    pub signature: Vec<u8>,
    pub object: String,
    pub url: String,
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

#[repr(C)]
#[derive(Serialize, Deserialize)]
pub enum DartAttachmentType {
    Inline(Vec<u8>),
    MMCS(DartMMCSFile)
}

#[repr(C)]
#[derive(Serialize, Deserialize)]
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
    Attachment(DartAttachment)
}

#[repr(C)]
pub struct DartIndexedMessagePart(pub DartMessagePart, pub Option<usize>);

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

#[frb]
#[repr(C)]
pub struct DartNormalMessage {
    #[frb(non_final)]
    pub parts: DartMessageParts,
    #[frb(non_final)]
    pub body: Option<DartBalloonBody>,
    #[frb(non_final)]
    pub effect: Option<String>,
    #[frb(non_final)]
    pub reply_guid: Option<String>,
    #[frb(non_final)]
    pub reply_part: Option<String>
}

#[repr(C)]
pub struct DartRenameMessage {
    pub new_name: String
}

#[repr(C)]
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
pub struct DartReactMessage {
    pub to_uuid: String,
    pub to_part: u64,
    pub enable: bool,
    pub reaction: DartReaction,
    pub to_text: String,
}

#[repr(C)]
pub struct DartUnsendMessage {
    pub tuuid: String,
    pub edit_part: u64,
}

#[repr(C)]
pub struct DartEditMessage {
    pub tuuid: String,
    pub edit_part: u64,
    pub new_parts: DartMessageParts
}

#[repr(C)]
pub struct DartIconChangeMessage {
    pub file: Option<DartMMCSFile>,
    pub group_version: u64
}

#[repr(C)]
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
    StopTyping
}

#[frb]
#[repr(C)]
pub struct DartIMessage {
    #[frb(non_final)]
    pub id: String,
    #[frb(non_final)]
    pub sender: Option<String>,
    #[frb(non_final)]
    pub after_guid: Option<String>,
    #[frb(non_final)]
    pub conversation: Option<DartConversationData>,
    #[frb(non_final)]
    pub message: DartMessage,
    #[frb(non_final)]
    pub sent_timestamp: u64
}

impl Into<Message> for DartMessage {
    fn into(self) -> Message {
        unsafe { std::mem::transmute(self) }
    }
}

impl Into<ConversationData> for DartConversationData {
    fn into(self) -> ConversationData {
        unsafe { std::mem::transmute(self) }
    }
}

impl From<IMessage> for DartIMessage {
    fn from(value: IMessage) -> Self {
        unsafe { std::mem::transmute(value) }
    }
}

impl DartIMessage {
    fn to_imsg(self) -> IMessage {
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
        msg = recv_path.client.as_ref().unwrap().recieve_wait() => {
            *recv_path.cancel_poll.lock().await = None;
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
    Ok(state.0.read().await.client.as_ref().unwrap().get_handles().await.to_vec())
}

pub async fn new_msg(state: &Arc<PushState>, conversation: DartConversationData, sender: String, message: DartMessage) -> DartIMessage {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (new_msg)")
    }
    let read = state.0.read().await;
    let client = read.client.as_ref().unwrap();
    client.new_msg(conversation.into(), &sender, message.into()).await.into()
}

pub async fn validate_targets(state: &Arc<PushState>, targets: Vec<String>, sender: String) -> anyhow::Result<Vec<String>> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (validate_targets)")
    }
    Ok(state.0.read().await.client.as_ref().unwrap().validate_targets(&targets, &sender).await?)
}

pub async fn get_phase(state: &Arc<PushState>) -> RegistrationPhase {
    state.get_phase().await
}

pub struct TransferProgress {
    pub prog: usize,
    pub total: usize,
    pub attachment: Option<DartAttachment>
}

pub async fn download_attachment(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, attachment: DartAttachment, path: String) -> anyhow::Result<()> {
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
}

pub async fn download_mmcs(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, attachment: DartMMCSFile, path: String) -> anyhow::Result<()> {
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
}

pub struct MMCSTransferProgress {
    pub prog: usize,
    pub total: usize,
    pub file: Option<DartMMCSFile>
}

pub async fn upload_mmcs(sink: StreamSink<MMCSTransferProgress>, state: &Arc<PushState>, path: String) -> anyhow::Result<()> {
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
}

pub async fn upload_attachment(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, path: String, mime: String, uti: String, name: String) -> anyhow::Result<()> {
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
}

pub async fn try_auth(state: &Arc<PushState>, username: String, password: String) -> anyhow::Result<DartLoginState> {
    if !matches!(state.get_phase().await, RegistrationPhase::WantsUserPass) {
        panic!("Wrong phase! (try_auth)")
    }
    let connection = state.0.read().await.conn.as_ref().unwrap().clone();

    let mut inner = state.0.write().await;
    let anisette_config = AnisetteConfiguration::new()
        .set_configuration_path(inner.conf_dir.join("anisette_test"));
    let mut apple_account = AppleAccount::new(anisette_config).await?;
    let mut login_state = apple_account.login_email_pass(&username, &password).await?;

    if let Some(pet) = apple_account.get_pet() {
        let identity = IDSAppleUser::authenticate(&connection, username.trim(), &pet, inner.os_config.as_ref().unwrap().as_ref()).await?;
        inner.users.push(identity);
        
        // who needs extra steps when you have a PET, amirite?
        println!("confirmed login {:?}", login_state);
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    inner.account = Some(apple_account);
    
    Ok(unsafe { std::mem::transmute(login_state) })
}

pub async fn send_2fa_to_devices(state: &Arc<PushState>) -> anyhow::Result<DartLoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    Ok(unsafe { std::mem::transmute(account.send_2fa_to_devices().await?) })
    
}

pub async fn verify_2fa(state: &Arc<PushState>, code: String) -> anyhow::Result<DartLoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    Ok(unsafe { std::mem::transmute(account.verify_2fa(code).await?) })
}

#[repr(C)]
pub struct DartTrustedPhoneNumber {
    pub number_with_dial_code: String,
    pub last_two_digits: String,
    pub push_mode: String,
    pub id: u32
}

pub async fn get_2fa_sms_opts(state: &Arc<PushState>) -> anyhow::Result<Vec<DartTrustedPhoneNumber>> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    Ok(account.get_auth_extras().await?.trusted_phone_numbers.into_iter().map(|i| unsafe { std::mem::transmute(i) }).collect())
}

pub async fn send_2fa_sms(state: &Arc<PushState>, phone_id: u32) -> anyhow::Result<DartLoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    Ok(unsafe { std::mem::transmute(account.send_sms_2fa_to_devices(phone_id).await?) })
}

pub async fn verify_2fa_sms(state: &Arc<PushState>, body: VerifyBody, code: String) -> anyhow::Result<DartLoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap();
    Ok(unsafe { std::mem::transmute(account.verify_sms_2fa(code, body).await?) })
}

pub async fn reset_state(state: &Arc<PushState>) -> anyhow::Result<()> {
    // tell any poll to stop
    let inner = state.0.read().await;
    if let Some(cancel) = inner.cancel_poll.lock().await.take() {
        cancel.send(()).unwrap();
    }
    drop(inner);
    let mut inner = state.0.write().await;
    let conn_state = inner.conn.as_ref().unwrap().clone();
    inner.client = None;
    // try deregistering from iMessage, but if it fails we don't really care
    let _ = register(inner.os_config.as_ref().unwrap().as_ref(), &mut [], &conn_state).await;
    inner.conn = None;
    inner.os_config = None;
    inner.account = None;
    inner.users = vec![];
    let _ = std::fs::remove_file(inner.conf_dir.join("config.plist"));
    let _ = std::fs::remove_file(inner.conf_dir.join("id_cache.plist"));
    Ok(())
}

impl PushState {
    async fn get_phase(&self) -> RegistrationPhase {
        let inner = self.0.read().await;
        if inner.os_config.is_none() {
            return RegistrationPhase::WantsOSConfig
        }
        if inner.users.len() == 0 && inner.client.is_none() {
            return RegistrationPhase::WantsUserPass
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


pub enum DartRegisterState {
    Registered,
    Registering,
    Failed {
        retry_wait: u64,
        error: String
    }
}

pub async fn get_regstate(state: &Arc<PushState>) -> anyhow::Result<DartRegisterState> {
    let inner = state.0.read().await;
    let mutex_ref = inner.client.as_ref().unwrap().get_regstate().await;
    let regstate = mutex_ref.lock().await;
    Ok(match &*regstate {
        RegisterState::Registering => DartRegisterState::Registering,
        RegisterState::Registered => DartRegisterState::Registered,
        RegisterState::Failed { retry_wait, error } => 
            DartRegisterState::Failed { retry_wait: *retry_wait, error: format!("{error}") },
    })
}
