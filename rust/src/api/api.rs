

use std::{borrow::{Borrow, BorrowMut}, collections::HashSet, fs::{self, File}, future::Future, io::{Cursor, Read, Write}, ops::Deref, path::{Path, PathBuf}, str::FromStr, sync::{Arc, OnceLock}, time::{Duration, SystemTime}, u64};

use anyhow::anyhow;
use flutter_rust_bridge::{frb, IntoDart, JoinHandle};
use omnisette::{default_provider, ArcAnisetteClient, LoginClientInfo};
use log::{debug, error, info, warn};
use plist::{Data, Dictionary};
pub use plist::Value;
use sha2::Digest;


use prost::Message as prostMessage;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use tokio::{runtime::Runtime, select, sync::{broadcast, mpsc, oneshot::{self, Sender}, watch, Mutex, RwLock}};
use rustpush::{authenticate_apple, authenticate_phone, cloudkit::{CloudKitClient, CloudKitState}, facetime::{FTClient, FTState, FACETIME_SERVICE, VIDEO_SERVICE}, findmy::{FindMyClient, FindMyState, FindMyStateManager, MULTIPLEX_SERVICE}, login_apple_delegates, name_photo_sharing::ProfilesClient, sharedstreams::{AssetMetadata, FFMpegFilePackager, FileMetadata, FilePackager, PreparedAsset, PreparedFile, SharedStreamClient, SharedStreamsState, SyncController, SyncManager, SyncState}, statuskit::{ChannelInterestToken, StatusKitClient, StatusKitState, StatusKitStatus}, APSMessage, CircleServerSession, IDSNGMIdentity, LoginDelegate, MADRID_SERVICE};
use rustpush::AnisetteProvider;
pub use rustpush::findmy::{FindMyFriendsClient, FindMyPhoneClient};
pub use rustpush::sharedstreams::{SharedAlbum, SyncStatus};
pub use omnisette::DefaultAnisetteProvider;
use uniffi::HandleAlloc;
use rand::Rng;
use uuid::Uuid;
use std::io::Seek;
use async_recursion::async_recursion;
use base64::prelude::*;
use rustpush::IdmsAuthListener;

use crate::{frb_generated::{SseEncode, StreamSink}, init_logger, native::{PackagedFile, PACKAGER_LOCK, QUEUED_MESSAGES}, RUNTIME};

use flutter_rust_bridge::for_generated::{SimpleHandler, SimpleExecutor, NoOpErrorListener, SimpleThreadPool, BaseAsyncRuntime, lazy_static};

pub type MyHandler = SimpleHandler<SimpleExecutor<NoOpErrorListener, SimpleThreadPool, MyAsyncRuntime>, NoOpErrorListener>;

include!("./mirrors.rs");

#[derive(Debug, Default)]
pub struct MyAsyncRuntime();

impl BaseAsyncRuntime for MyAsyncRuntime {
    fn spawn<F>(&self, future: F) -> JoinHandle<F::Output>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        RUNTIME.spawn(future)
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

pub trait SeekRead: Seek + Read {}
impl<T: Seek + Read> SeekRead for T {}

#[derive(Serialize, Deserialize, Clone)]
struct SavedHardwareState {
    push: APSState,
    identity: IDSNGMIdentity,
    os_config: JoinedOSConfig,
}

pub enum RegistrationPhase {
    WantsOSConfig,
    WantsRegister,
    Registered,
}

#[cfg(not(target_os = "android"))]
type MyFilePackager = FFMpegFilePackager;

#[cfg(target_os = "android")]
type MyFilePackager = FFIFilePackager;

#[derive(Default)]
pub struct FFIFilePackager {

}

impl FilePackager for FFIFilePackager {
    type Reader = Box<dyn SeekRead + Send + Sync>;
    async fn get_files(&mut self, path: PathBuf) -> Result<PreparedAsset<Self::Reader>, PushError> {
        info!("Preparing to package {}", PACKAGER_LOCK.get().is_some());
        let processed = PACKAGER_LOCK.get().expect("No FFI packager!").get_file(path.to_str().unwrap().to_string());

        info!("Packaged");
        let inner = match processed {
            PackagedFile::Failure(failure) => {
                return Err(PushError::FilePackageError(failure))
            },
            PackagedFile::Info(info) => info
        };

        let is_video = inner.duration.is_some();
        let file = PreparedFile::<Box<dyn SeekRead + Send + Sync>>::new(Box::new(File::open(&path)?), FileMetadata {
            width: inner.width as usize,
            height: inner.height as usize,
            uti_type: if is_video { "public.mpeg-4".to_string() } else { "public.jpeg".to_string() },
            video_type: if is_video { Some("720p".to_string()) } else { None },
            asset_metadata: if !is_video { Some(AssetMetadata {
                asset_type: "derivative".to_string(),
                asset_type_flags: 2,
            }) } else { None },
        }).await?;

        let mut prepared_files = vec![file];

        if let Some(thumbnail) = inner.thumbnail {
            let thumbnail = PreparedFile::<Box<dyn SeekRead + Send + Sync>>::new(Box::new(Cursor::new(thumbnail)), FileMetadata {
                width: inner.width as usize,
                height: inner.height as usize,
                uti_type: "public.jpeg".to_string(),
                video_type: Some("PosterFrame".to_string()),
                asset_metadata: None,
            }).await?;
            prepared_files.push(thumbnail);
        }


        Ok(PreparedAsset {
            files: prepared_files,
            name: path.file_name().unwrap().to_str().unwrap().to_string(),
            date_created: fs::metadata(path)?.created().unwrap_or(SystemTime::now()),
            video_duration: inner.duration,
            guid: Uuid::new_v4().to_string().to_uppercase(),
        })
    }
}

#[frb(ignore)]
pub struct InnerPushState {
    pub anisette: Option<ArcAnisetteClient<DefaultAnisetteProvider>>,
    pub conn: Option<APSConnection>,
    pub inq_queue: Option<Mutex<broadcast::Receiver<APSMessage>>>,
    pub client: Option<IMClient>,
    pub fmfd: Option<FindMyClient<DefaultAnisetteProvider>>,
    pub sharedstreams: Option<SyncManager<DefaultAnisetteProvider, MyFilePackager>>,
    pub ft_client: Option<FTClient>,
    pub profiles_client: Option<ProfilesClient<DefaultAnisetteProvider>>,
    pub statuskit_client: Option<Arc<StatusKitClient<DefaultAnisetteProvider>>>,
    pub statuskit_interest_token: Mutex<Option<ChannelInterestToken<DefaultAnisetteProvider>>>,
    pub idms_client: Option<IdmsAuthListener>,
    pub idms_circle_sessions: Mutex<Vec<ActiveCircleSession>>,
    pub conf_dir: PathBuf,
    pub os_config: Option<JoinedOSConfig>,
    pub account: Option<Arc<Mutex<AppleAccount<DefaultAnisetteProvider>>>>,
    pub cancel_poll: mpsc::Sender<()>,
    pub identity: Option<IDSNGMIdentity>,
    pub local_messages: Mutex<mpsc::Receiver<PushMessage>>,
    pub local_broadcast: mpsc::Sender<PushMessage>,
    pub reg_state: Option<Mutex<watch::Receiver<ResourceState>>>,
    pub cancel_poll_recv: Mutex<mpsc::Receiver<()>>,
}

pub struct ActiveCircleSession {
    session: CircleServerSession<DefaultAnisetteProvider>,
    atxnid: String,
    txnid: String,
    init_message: Option<IdmsCircleMessage>,
    otp: u32,
}

#[frb(opaque)]
pub struct PushState (RwLock<InnerPushState>);

pub async fn new_push_state(dir: String) -> Arc<PushState> {
    let dir = PathBuf::from_str(&dir).unwrap();
    init_logger(&dir);
    let (sender, recv) = mpsc::channel(999);
    let (cancel_send, cancel_recv) = mpsc::channel(1);
    // flutter_rust_bridge::setup_default_user_utils();
    let state = PushState(RwLock::new(InnerPushState {
        anisette: None,
        conn: None,
        client: None,
        inq_queue: None,
        reg_state: None,
        fmfd: None,
        sharedstreams: None,
        profiles_client: None,
        statuskit_client: None,
        statuskit_interest_token: Mutex::new(None),
        ft_client: None,
        conf_dir: dir,
        os_config: None,
        account: None,
        cancel_poll: cancel_send,
        identity: None,
        local_broadcast: sender,
        local_messages: Mutex::new(recv),
        idms_client: None,
        idms_circle_sessions: Mutex::new(vec![]),
        cancel_poll_recv: Mutex::new(cancel_recv),
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

    if let Ok(mut value) = plist::from_file::<_, Dictionary>(&hw_config_path) {
        if !value.contains_key("identity") {
            if let Ok(users) = plist::from_file::<_, Vec<Dictionary>>(&id_path) {
                // get first phone user or first user
                if let Some(user) = users.iter()
                    .find(|user| user["user_id"].as_string().unwrap().starts_with("P:")).or(users.first()) {

                    value.insert("identity".to_string(), user["identity"].clone());
                    std::fs::write(&hw_config_path, plist_to_string(&value).unwrap()).unwrap();

                    info!("migrated identity!");
                }
            }
        }
    }

    if let Ok(mut users) = plist::from_file::<_, Vec<Dictionary>>(&id_path) {
        for user in &mut users {
            let registration = user.get_mut("registration").unwrap().as_dictionary_mut().unwrap();
            if !registration.contains_key("com.apple.madrid") {
                // migrate!
                *registration = Dictionary::from_iter([
                    ("com.apple.madrid", Value::Dictionary(registration.clone()))
                ]);
            }
        }
        std::fs::write(&id_path, plist_to_string(&users).unwrap()).unwrap();
    }

    let mut needs_rereg = false;

    #[derive(Serialize, Deserialize, Clone)]
    struct LegacySavedHardwareState {
        push: APSState,
        identity: IDSUserIdentity,
        os_config: JoinedOSConfig,
    }

    if let Ok(config) = plist::from_file::<_, LegacySavedHardwareState>(&hw_config_path) {
        std::fs::write(&hw_config_path, plist_to_string(&SavedHardwareState {
            push: config.push,
            identity: IDSNGMIdentity::new_with_legacy(config.identity).expect("Failed to create new identity!"),
            os_config: config.os_config
        }).unwrap()).unwrap();
        needs_rereg = true;
    }


    let Ok(state) = plist::from_file::<_, SavedHardwareState>(&hw_config_path) else { return };

    // even if we failed on the initial connection, we don't care cuz we're restoring.
    inner.os_config = Some(state.os_config);
    inner.identity = Some(state.identity.clone());
    let (connection, _err) = setup_push(inner.os_config.as_ref().unwrap(), &state.identity, Some(&state.push), hw_config_path).await;
    inner.inq_queue = Some(Mutex::new(connection.messages_cont.subscribe()));
    inner.conn = Some(connection);
    let provider = Some(default_provider(inner.os_config.as_ref().unwrap().get_gsa_config(&*inner.conn.as_ref().unwrap().state.read().await), inner.conf_dir.join("anisette_test")));
    inner.anisette = provider;

    // id may not exist yet; that's fine
    let Ok(users) = plist::from_file::<_, Vec<IDSUser>>(&id_path) else { return };

    inner.client = Some(IMClient::new(inner.conn.as_ref().unwrap().clone(), users, state.identity,
        &[&MADRID_SERVICE, &MULTIPLEX_SERVICE, &FACETIME_SERVICE, &VIDEO_SERVICE], inner.conf_dir.join("id_cache.plist"), inner.os_config.as_ref().unwrap().config(), Box::new(move |updated_keys| {
            println!("updated keys!!!");
            std::fs::write(&id_path, plist_to_string(&updated_keys).unwrap()).unwrap();
        })).await);

    if let Ok(mut lock) = inner.cancel_poll_recv.try_lock() {
        let _ = lock.try_recv();
    }

    if needs_rereg {
        // mark rereg
        let _ = inner.client.as_ref().unwrap().identity.refresh_now().await;
    }

    inner.reg_state = Some(Mutex::new(inner.client.as_ref().unwrap().identity.resource_state.subscribe()));


    if let Ok(mut state) = plist::from_file::<_, GSAConfig>(inner.conf_dir.join("gsa.plist")) {
        let mut apple_account =
            AppleAccount::new_with_anisette(get_login_config(&*inner).await, inner.anisette.clone().unwrap()).expect("aacbf?");

        apple_account.username = Some(state.username.clone());
        apple_account.hashed_password = Some(state.password.clone().into());

        if state.postdata_done.is_none() {
            info!("Updating postdata");
            let _ = apple_account.update_postdata("Apple Device", None, &["icloud", "imessage", "facetime"]).await;
            state.postdata_done = Some(true);
            plist::to_file_xml(inner.conf_dir.join("gsa.plist"), &state).unwrap();
        }

        inner.account = Some(Arc::new(Mutex::new(apple_account)));
    }

    if inner.account.is_some() {
        let id_path = inner.conf_dir.join("findmy.plist");
        if let Ok(state) = plist::from_file(&id_path) {
            inner.fmfd = Some(FindMyClient::new(inner.conn.as_ref().unwrap().clone(), inner.os_config.as_ref().unwrap().config(), Arc::new(FindMyStateManager {
                state: Mutex::new(state),
                update: Box::new(move |state| {
                    plist::to_file_xml(&id_path, state).expect("Failed to serialize plist!");
                }),
            }), inner.account.clone().unwrap(), inner.anisette.clone().unwrap(), inner.client.as_ref().unwrap().identity.clone()).await.unwrap());
        }

        let stream_path = inner.conf_dir.join("sharedstreams.plist");
        if let Ok(state) = plist::from_file(&stream_path) {
            let client = SharedStreamClient::new(state, Box::new(move |update| {
                plist::to_file_xml(&stream_path, update).unwrap();
            }), inner.account.clone().expect("no account?"), inner.conn.as_ref().unwrap().clone(), inner.anisette.clone().unwrap(), inner.os_config.as_ref().unwrap().config()).await;
            inner.sharedstreams = Some(SyncController::new(client, inner.conf_dir.join("sync.plist"), MyFilePackager::default(), Duration::from_secs(60 * 30)).await);
            subscribe_streams(inner.sharedstreams.clone().unwrap());
        }
    }

    info!("heer");
    
    let facetime_path = inner.conf_dir.join("facetime.plist");
    let state: FTState = plist::from_file(&facetime_path).unwrap_or_default();
    inner.ft_client = Some(FTClient::new(state, Box::new(move |state| {
        plist::to_file_xml(&facetime_path, state).expect("Failed to serialize plist!");
    }), inner.conn.as_ref().unwrap().clone(), inner.client.as_ref().unwrap().identity.clone(), inner.os_config.as_ref().unwrap().config()).await);

    let cloudkit_path = inner.conf_dir.join("cloudkit.plist");
    if let Ok(state) = plist::from_file(&cloudkit_path) {
        let cloudkit = Arc::new(CloudKitClient {
            state: RwLock::new(state),
            anisette: inner.anisette.clone().unwrap(),
            config: inner.os_config.as_ref().unwrap().config(),
        });

        inner.profiles_client = Some(ProfilesClient::new(cloudkit));
    }

    if let Some(account) = &inner.account {
        let path = inner.conf_dir.join("statuskit.plist");
        let state: StatusKitState = plist::from_file(&path).unwrap_or_default();
        inner.statuskit_client = Some(StatusKitClient::new(state, Box::new(move |state| {
            plist::to_file_xml(&path, state).unwrap();
        }), account.clone(), inner.conn.as_ref().unwrap().clone(), inner.os_config.as_ref().unwrap().config(), inner.client.as_ref().unwrap().identity.clone()).await);
    }
    inner.idms_client = Some(IdmsAuthListener::new(inner.conn.as_ref().unwrap().clone()).await);
}

async fn shared_items<P: AnisetteProvider + Send + Sync + 'static, F: FilePackager + Send + Sync + 'static>(manager: &SyncManager<P, F>, seen_paths: &mut HashSet<PathBuf>) -> HashSet<PathBuf> {
    let paths = manager.sync_states.lock().await.values().map(|v| v.folder.clone()).collect::<Vec<_>>();
    let mut new = HashSet::new();
    seen_paths.retain(|a| fs::exists(a).is_ok_and(|a| a));
    for path in paths {
        let Ok(read) = fs::read_dir(path) else { continue };
        for file in read {
            let Ok(result) = file else { continue };
            if seen_paths.contains(&result.path()) { continue }
            seen_paths.insert(result.path());
            new.insert(result.path());
        }
    }
    new
}

fn subscribe_streams<P: AnisetteProvider + Send + Sync + 'static, F: FilePackager + Send + Sync + 'static>(manager: SyncManager<P, F>) {
    tokio::spawn(async move {
        let mut seen_paths = HashSet::new();
        shared_items(&manager, &mut seen_paths).await;
        let mut generated_sub = manager.generated_signal.subscribe();
        let manager_ref = Arc::downgrade(&manager);
        drop(manager);
        while let Ok(_) = generated_sub.recv().await {
            // drain any accumulations
            while let Ok(_) = generated_sub.try_recv() { }

            info!("Starting diff");
            let Some(manager) = manager_ref.upgrade() else { break };
            let new = shared_items(&manager, &mut seen_paths).await;
            info!("New files {:?}", new);
            if let Some(packager) = PACKAGER_LOCK.get() {
                packager.scan_files(new.into_iter().map(|a| a.to_str().expect("Path not str??").to_string()).collect());
            }
            info!("Diffed");
        }
    });
}

pub async fn can_find_my(state: &Arc<PushState>) -> anyhow::Result<bool> {
    let inner = state.0.read().await;
    let id_path = inner.conf_dir.join("findmy.plist");
    Ok(plist::from_file::<_, FindMyState>(id_path).is_ok())
}

pub async fn register_ids(state: &Arc<PushState>, users: &Vec<IDSUser>) -> anyhow::Result<Option<SupportAlert>> {
    let mut users = users.clone(); // don't take ownership in case of failure
    if !matches!(state.get_phase().await, RegistrationPhase::WantsRegister) {
        panic!("Wrong phase! (register_ids)")
    }
    let mut inner = state.0.write().await;
    let conn_state = inner.conn.as_ref().unwrap().clone();

    if let Err(err) = register(inner.os_config.as_deref().unwrap(), &*conn_state.state.read().await, &[&MADRID_SERVICE, &MULTIPLEX_SERVICE, &FACETIME_SERVICE, &VIDEO_SERVICE], &mut users, inner.identity.as_ref().unwrap()).await {
        return if let PushError::CustomerMessage(support) = err {
            Ok(Some(support))
        } else {
            Err(anyhow!(err))
        }
    }
    let id_path = inner.conf_dir.join("id.plist");
    std::fs::write(&id_path, plist_to_string(&users).unwrap()).unwrap();

    inner.client = Some(IMClient::new(conn_state, users, inner.identity.clone().unwrap(), &[&MADRID_SERVICE, &MULTIPLEX_SERVICE, &FACETIME_SERVICE, &VIDEO_SERVICE], inner.conf_dir.join("id_cache.plist"), inner.os_config.as_ref().unwrap().config(), Box::new(move |updated_keys| {
        std::fs::write(&id_path, plist_to_string(&updated_keys).unwrap()).unwrap();
    })).await);

    if let Ok(mut lock) = inner.cancel_poll_recv.try_lock() {
        let _ = lock.try_recv();
    }

    inner.reg_state = Some(Mutex::new(inner.client.as_ref().unwrap().identity.resource_state.subscribe()));

    let id_path = inner.conf_dir.join("findmy.plist");
    if let Ok(state) = plist::from_file(&id_path) {
        inner.fmfd = Some(FindMyClient::new(inner.conn.as_ref().unwrap().clone(), inner.os_config.as_ref().unwrap().config(), Arc::new(FindMyStateManager {
            state: Mutex::new(state),
            update: Box::new(move |state| {
                plist::to_file_xml(&id_path, state).expect("Failed to serialize plist!");
            }),
        }), inner.account.clone().unwrap(), inner.anisette.clone().unwrap(), inner.client.as_ref().unwrap().identity.clone()).await.unwrap());
    }
    let stream_path = inner.conf_dir.join("sharedstreams.plist");
    if let Ok(state) = plist::from_file(&stream_path) {
        let client = SharedStreamClient::new(state, Box::new(move |update| {
            plist::to_file_xml(&stream_path, update).unwrap();
        }), inner.account.clone().expect("no account?"), inner.conn.as_ref().unwrap().clone(), inner.anisette.clone().unwrap(), inner.os_config.as_ref().unwrap().config()).await;
        inner.sharedstreams = Some(SyncController::new(client, inner.conf_dir.join("sync.plist"), MyFilePackager::default(), Duration::from_secs(60 * 30)).await);
        subscribe_streams(inner.sharedstreams.clone().unwrap());
    }

    let facetime_path = inner.conf_dir.join("facetime.plist");
    let state: FTState = plist::from_file(&facetime_path).unwrap_or_default();
    inner.ft_client = Some(FTClient::new(state, Box::new(move |state| {
        plist::to_file_xml(&facetime_path, state).expect("Failed to serialize plist!");
    }), inner.conn.as_ref().unwrap().clone(), inner.client.as_ref().unwrap().identity.clone(), inner.os_config.as_ref().unwrap().config()).await);

    let cloudkit_path = inner.conf_dir.join("cloudkit.plist");
    if let Ok(state) = plist::from_file(&cloudkit_path) {
        let cloudkit = Arc::new(CloudKitClient {
            state: RwLock::new(state),
            anisette: inner.anisette.clone().unwrap(),
            config: inner.os_config.as_ref().unwrap().config(),
        });

        inner.profiles_client = Some(ProfilesClient::new(cloudkit));
    }

    if let Some(account) = &inner.account {
        let path = inner.conf_dir.join("statuskit.plist");
        let state: StatusKitState = plist::from_file(&path).unwrap_or_default();
        inner.statuskit_client = Some(StatusKitClient::new(state, Box::new(move |state| {
            plist::to_file_xml(&path, state).unwrap();
        }), account.clone(), inner.conn.as_ref().unwrap().clone(), inner.os_config.as_ref().unwrap().config(), inner.client.as_ref().unwrap().identity.clone()).await);
    }
    inner.idms_client = Some(IdmsAuthListener::new(inner.conn.as_ref().unwrap().clone()).await);
    Ok(None)
}

async fn setup_push(config: &JoinedOSConfig, identity: &IDSNGMIdentity, state: Option<&APSState>, state_path: PathBuf) -> (APSConnection, Option<PushError>) {
    let (conn, error) = APSConnectionResource::new(config.config(), state.cloned()).await;

    if error.is_none() {
        let state = SavedHardwareState {
            push: conn.state.read().await.clone(),
            os_config: config.clone(),
            identity: identity.clone(),
        };
        std::fs::write(&state_path, plist_to_string(&state).unwrap()).unwrap();
    }

    let mut to_refresh = conn.generated_signal.subscribe();
    let reconn_conn = Arc::downgrade(&conn);
    let config_ref = config.clone();
    let ident_ref = identity.clone();
    tokio::spawn(async move {
        loop {
            match to_refresh.recv().await {
                Ok(()) => {
                    let Some(conn) = reconn_conn.upgrade() else { break };
                    // update keys
                    let state = SavedHardwareState {
                        push: conn.state.read().await.clone(),
                        os_config: config_ref.clone(),
                        identity: ident_ref.clone(),
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

async fn get_login_config(inner: &InnerPushState) -> LoginClientInfo {
    inner.os_config.as_ref().unwrap().get_gsa_config(&*inner.conn.as_ref().unwrap().state.read().await)
}

pub async fn configure_app_review(state: &Arc<PushState>) -> anyhow::Result<()> {
    let inner = state.0.write().await;
    std::fs::write(inner.conf_dir.join("id.plist"), include_str!("id_testing.plist"))?;
    std::fs::write(inner.conf_dir.join("hw_info.plist"), include_str!("hw_testing.plist"))?;
    std::fs::write(inner.conf_dir.join("sharedstreams.plist"), include_str!("sharedstreams_testing.plist"))?;
    drop(inner);
    restore(state).await;
    Ok(())
}

pub async fn configure_macos(state: &Arc<PushState>, config: &JoinedOSConfig) -> anyhow::Result<()> {
    let config = config.clone();
    let mut inner = state.0.write().await;
    inner.os_config = Some(config.clone());
    inner.identity = Some(IDSNGMIdentity::new()?);
    // delete anisette provisioning to prevent 6005's
    let anisette_dir = inner.conf_dir.join("anisette_test");
    if anisette_dir.exists() {
        fs::remove_dir_all(inner.conf_dir.join("anisette_test"))?;
    }
    let conf_path = inner.conf_dir.join("hw_info.plist");
    let (connection, err) = setup_push(inner.os_config.as_ref().unwrap(), inner.identity.as_ref().unwrap(), None, conf_path).await;
    if let Some(err) = err {
        return Err(err.into())
    }
    inner.inq_queue = Some(Mutex::new(connection.messages_cont.subscribe()));
    inner.conn = Some(connection);
    let provider = Some(default_provider(get_login_config(&*inner).await, inner.conf_dir.join("anisette_test")));
    inner.anisette = provider;
    Ok(())
}

pub async fn refresh_token(state: &Arc<PushState>) -> anyhow::Result<()> {
    let mut inner = state.0.write().await;

    let InnerPushState { identity: Some(identity), os_config: Some(os_config), .. } = &*inner else {
        return Err(anyhow!("No indentity!"))
    };
    let conf_path = inner.conf_dir.join("hw_info.plist");
    let (connection, err) = setup_push(os_config, identity, None, conf_path).await;
    if let Some(err) = err {
        return Err(err.into())
    }
    inner.inq_queue = Some(Mutex::new(connection.messages_cont.subscribe()));
    inner.conn = Some(connection);

    Ok(())
}

pub struct HwExtra {
    pub version: String,
    pub protocol_version: u32,
    pub device_id: String,
    pub icloud_ua: String,
    pub aoskit_version: String,
}

pub fn config_from_validation_data(data: Vec<u8>, extra: HwExtra) -> anyhow::Result<JoinedOSConfig> {
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

pub async fn validate_relay(state: &Arc<PushState>) -> anyhow::Result<Option<String>> {
    let locked = state.0.read().await;
    let config_ref = locked.os_config.as_ref().expect("No os config??");
    let Err(PushError::RelayError(_, message)) = config_ref.generate_validation_data().await else { return Ok(match config_ref {
        JoinedOSConfig::MacOS(macos) => None,
        JoinedOSConfig::Relay(relay) => Some(relay.code.clone())
    }) };
    if !message.contains("Subscription not active!") && !message.contains("Ticket not activated!") {
        info!("Validation failed {message}");
        return Ok(None);
    }
    Ok(match config_ref {
        JoinedOSConfig::MacOS(macos) => None,
        JoinedOSConfig::Relay(relay) => Some(relay.code.clone())
    })
}

pub fn parse_transcript_poster(payload: Vec<u8>) -> anyhow::Result<SimplifiedTranscriptPoster> {
    Ok(SimplifiedTranscriptPoster::parse_payload(&payload)?)
}

pub fn pack_transcript_poster(mut payload: SimplifiedTranscriptPoster) -> anyhow::Result<Vec<u8>> {
    Ok(payload.to_payload()?)
}

pub fn parse_poster(poster: IMessagePosterRecord) -> anyhow::Result<SimplifiedIncomingCallPoster> {
    Ok(SimplifiedIncomingCallPoster::from_poster(&poster)?)
}

pub fn from_poster(mut poster: SimplifiedIncomingCallPoster) -> anyhow::Result<IMessagePosterRecord> {
    Ok(poster.to_poster()?)
}

// simple round trip to rust clones object
#[frb(sync)]
pub fn clone_poster(poster: SimplifiedIncomingCallPoster) -> anyhow::Result<SimplifiedIncomingCallPoster> {
    Ok(poster)
}

#[frb(sync)]
pub fn clone_transcript_poster(poster: SimplifiedTranscriptPoster) -> anyhow::Result<SimplifiedTranscriptPoster> {
    Ok(poster)
}

pub fn transcript_poster_save(poster: SimplifiedTranscriptPoster) -> anyhow::Result<Vec<u8>> {
    Ok(plist_to_bin(&poster)?)
}

pub fn from_transcript_poster_save(poster: Vec<u8>) -> anyhow::Result<SimplifiedTranscriptPoster> {
    debug!("Before");
    let got = plist::from_bytes(&poster)?;
    debug!("After");
    Ok(got)
}

pub fn parse_poster_save(poster: SimplifiedIncomingCallPoster) -> anyhow::Result<Vec<u8>> {
    Ok(plist_to_bin(&poster)?)
}

pub fn from_poster_save(poster: Vec<u8>) -> anyhow::Result<SimplifiedIncomingCallPoster> {
    debug!("Before");
    let got = match plist::from_bytes(&poster) {
        Ok(poster) => poster,
        Err(_) => {
            let result: SimplifiedPoster = plist::from_bytes(&poster)?;

            #[derive(Deserialize)]
            struct Extras {
                text_metadata: WallpaperMetadata,
                low_res: Data,
            }
            let extras: Extras = plist::from_bytes(&poster)?;
            SimplifiedIncomingCallPoster {
                poster: result,
                text_metadata: extras.text_metadata,
                low_res: extras.low_res.into(),
            }
        }
    };
    debug!("After");
    Ok(got)
}

pub struct DeviceInfo {
    pub name: String,
    pub serial: String,
    pub os_version: String,
    pub encoded_data: Option<Vec<u8>>,
}

pub async fn get_device_info_state(state: &Arc<PushState>) -> anyhow::Result<DeviceInfo> {
    let locked = state.0.read().await;
    get_device_info(locked.os_config.as_ref().unwrap())
}

pub async fn get_config_state(state: &Arc<PushState>) -> Option<JoinedOSConfig> {
    let locked = state.0.read().await;
    locked.os_config.clone()
}

pub fn get_device_info(config: &JoinedOSConfig) -> anyhow::Result<DeviceInfo> {
    let debug_info = config.get_debug_meta();
    Ok(DeviceInfo {
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


pub async fn ptr_to_dart(ptr: String) -> Option<PushMessage> {
    let pointer: u64 = ptr.parse().unwrap();
    info!("using pointer {pointer}");
    QUEUED_MESSAGES.lock().await.1.get(&pointer).cloned()
}

pub async fn complete_msg(ptr: String) {
    let pointer: u64 = ptr.parse().unwrap();
    info!("finishing pointer {pointer}");
    QUEUED_MESSAGES.lock().await.1.remove(&pointer);
}




pub fn restore_attachment(data: String) -> Attachment {
    plist::from_reader_xml(Cursor::new(data)).unwrap()
}

pub fn save_attachment(att: &Attachment) -> String {
    plist_to_string(att).unwrap()
}

pub fn create_image_array(img: LPImageMetadata) -> NSArray<LPImageMetadata> {
    NSArray {
        objects: vec![img],
        class: NSArrayClass::NSArray,
    }
}

pub fn create_icon_array(img: LPIconMetadata) -> NSArray<LPIconMetadata> {
    NSArray {
        objects: vec![img],
        class: NSArrayClass::NSArray,
    }
}

#[frb(sync)]
pub fn ns_null() -> Vec<u8> {
    plist_to_bin(&Value::String("$null".to_string())).unwrap()
}



#[repr(C)]
#[derive(Clone)]
pub enum PushMessage {
    IMessage(MessageInst),
    SendConfirm {
        uuid: String,
        error: Option<String>,
    },
    RegistrationState(RegisterState),
    NewPhotostream(SharedAlbum),
    FaceTime(FTMessage),
    StatusUpdate(StatusKitMessage),
    Idms(IdmsMessage),
    TwoFaAuthEvent(bool),
}

async fn handle_photostream(client: &SharedStreamClient<DefaultAnisetteProvider>, changes: Vec<String>, local: &mpsc::Sender<PushMessage>) {
    let lock = &client.state.read().await.albums;
    for change in changes {
        let Some(item) = lock.iter().find(|a| &a.albumguid == &change) else { continue };
        if item.sharingtype == "pending" {
            local.send(PushMessage::NewPhotostream(item.clone())).await.expect("Dropped?");
        }
    }
}

pub async fn update_account_headers(state: &Arc<PushState>) -> anyhow::Result<String> {
    let mut state = state.0.write().await;
    let account = state.account.as_ref().expect("no login state!").lock().await;

    Ok(account.request_update_account().await?)
}

pub async fn get_anisette_headers(state: &Arc<PushState>) -> anyhow::Result<HashMap<String, String>> {
    let state = state.0.read().await;

    let mut headers = state.anisette.as_ref().unwrap().lock().await.get_headers().await?.clone();
    headers.insert("X-Mme-Client-Info".to_string(), state.os_config.as_ref().unwrap().get_adi_mme_info("com.apple.AuthKit/1 (com.apple.findmy/375.20)"));
    Ok(headers)
}

pub async fn retry_login(state: &Arc<PushState>) -> anyhow::Result<IDSUser> {
    let inner = state.0.read().await;
    let mut account = inner.account.as_ref().expect("no login state!").lock().await;
    do_login(&inner.conf_dir, &mut *account, Some("termsAccepted=true"), inner.anisette.as_ref().unwrap(), inner.os_config.as_deref().unwrap()).await
}

pub async fn get_albums(state: &Arc<PushState>, refresh: bool) -> anyhow::Result<(Vec<SharedAlbum>, Vec<String>)> {
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");

    if refresh {
        let _ = lock.client.get_changes().await?;

        let nameless_albums: Vec<_> = lock.client.state.read().await.albums.iter().filter(|album| album.name.is_none()).map(|album| album.albumguid.clone()).collect();
        for album in nameless_albums {
            lock.client.get_album_summary(&album).await?;
        }
    }

    let albums_ref = lock.client.state.read().await.albums.clone();
    let extras = lock.dirty_map.lock().await.iter().map(|a| a.0.clone()).collect();
    Ok((albums_ref, extras))
}

pub async fn subscribe(state: &Arc<PushState>, guid: String) -> anyhow::Result<Vec<SharedAlbum>> {
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");
    let _ = lock.client.subscribe(&guid).await?;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn unsubscribe(state: &Arc<PushState>, guid: String) -> anyhow::Result<Vec<SharedAlbum>> {
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");
    let _ = lock.unsubscribe(&guid).await?;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn subscribe_token(state: &Arc<PushState>, token: String) -> anyhow::Result<Vec<SharedAlbum>> {
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");
    let _ = lock.client.subscribe_token(&token).await?;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn add_album(state: &Arc<PushState>, guid: String, folder: String) -> anyhow::Result<Vec<SharedAlbum>> {
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");
    lock.add_album(guid, PathBuf::from_str(&folder).unwrap()).await;

    let albums_ref = lock.client.state.read().await.albums.clone();
    Ok(albums_ref)
}

pub async fn remove_album(state: &Arc<PushState>, guid: String) -> anyhow::Result<Vec<SharedAlbum>> {
    debug!("a");
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");
    debug!("b");
    lock.remove_album(guid).await;
    debug!("c");
    let albums_ref = lock.client.state.read().await.albums.clone();
    debug!("d");
    Ok(albums_ref)
}

pub async fn get_syncstatus(state: &Arc<PushState>) -> anyhow::Result<(HashMap<String, SyncStatus>, Option<(String, u64)>)> {
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");
    let statuses = lock.sync_statuses.borrow().clone();

    let mut f: Option<(String, u64)> = None;
    if let ResourceState::Failed(failure) = &*lock.resource_state.borrow() {
        f = Some((format!("{}", failure.error), failure.retry_wait.unwrap_or(u64::MAX)))
    }

    Ok((statuses, f))
}

pub async fn sync_now(state: &Arc<PushState>) -> anyhow::Result<()> {
    let recv_path = state.0.read().await;
    let lock = recv_path.sharedstreams.as_ref().expect("Cannot use photostreams!");

    lock.refresh_now().await?;

    Ok(())
}


pub async fn supports_shared_streams(state: &Arc<PushState>) -> anyhow::Result<bool> {
    let inner = state.0.read().await;
    let id_path = inner.conf_dir.join("sharedstreams.plist");
    Ok(plist::from_file::<_, SharedStreamsState>(id_path).is_ok())
}


pub async fn ft_sessions(state: &Arc<PushState>) -> anyhow::Result<Vec<FTSession>> {
    let inner = state.0.read().await;
    let facetime = inner.ft_client.as_ref().expect("No ft client??");
    let sessions = facetime.state.read().await;
    Ok(sessions.sessions.values().cloned().collect())
}

pub async fn get_ft_link(state: &Arc<PushState>, usage: String) -> anyhow::Result<String> {
    let inner = state.0.read().await;
    let facetime = inner.ft_client.as_ref().expect("No ft client??");
    let handles = facetime.identity.get_handles().await.to_vec();
    
    let handle = handles[0].clone();
    Ok(facetime.get_link_for_usage(&handle, &usage).await?)
}

pub async fn use_link_for(state: &Arc<PushState>, old_usage: String, usage: String) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let facetime = inner.ft_client.as_ref().expect("No ft client??");
    
    Ok(facetime.use_link_for(&old_usage, &usage).await?)
}

pub async fn get_2fa_code(state: &Arc<PushState>) -> anyhow::Result<u32> {
    info!("state lock");
    let inner = state.0.read().await;
    info!("second lock");
    let account = inner.account.as_ref().ok_or(anyhow!("No apple account!"))?.lock().await;
    info!("third lock");
    let code = account.anisette.lock().await.provider.get_2fa_code().await?;
    info!("fouth lock");
    Ok(code)
}

pub async fn teardown_2fa(state: &Arc<PushState>, action: String, txnid: String) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let mut account = inner.account.as_ref().ok_or(anyhow!("No apple account!"))?.lock().await;
    account.teardown(&action, 100, &txnid).await?;
    Ok(())
}

pub async fn answer_ft_request(state: &Arc<PushState>, request: LetMeInRequest, approved_group: Option<String>) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let facetime = inner.ft_client.as_ref().expect("No ft client??");
    facetime.respond_letmein(request, approved_group.as_ref().map(|a| a.as_str())).await?;
    Ok(())
}

pub async fn decline_facetime(state: &Arc<PushState>, guid: String) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let facetime = inner.ft_client.as_ref().expect("No ft client??");
    let mut lock = facetime.state.write().await;
    let state = lock.sessions.get_mut(&guid).expect("state");
    facetime.ensure_allocations(state, &[]).await?;
    facetime.decline_invite(state).await?;
    Ok(())
}

pub async fn create_facetime(state: &Arc<PushState>, uuid: String, handle: String, participants: Vec<String>) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let facetime = inner.ft_client.as_ref().expect("No ft client??");
    facetime.create_session(uuid, handle, &participants).await?;
    Ok(())
}

pub async fn cancel_facetime(state: &Arc<PushState>, guid: String) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let facetime = inner.ft_client.as_ref().expect("No ft client??");
    let mut lock = facetime.state.write().await;
    let state = lock.sessions.get_mut(&guid).expect("state");
    facetime.unprop_conv(state).await?;
    Ok(())
}

pub async fn validate_targets_facetime(state: &Arc<PushState>, targets: Vec<String>, sender: String) -> anyhow::Result<Vec<String>> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (validate_targets)")
    }
    Ok(state.0.read().await.client.as_ref().unwrap().identity.validate_targets(&targets, "com.apple.private.alloy.facetime.multi", &sender).await?)
}

pub async fn certify_delivery(state: &Arc<PushState>, context: CertifiedContext, notify: bool) -> anyhow::Result<()> {
    state.0.read().await.client.as_ref().unwrap().identity.certify_delivery("com.apple.madrid", &context, notify).await?;
    Ok(())
}

pub async fn report_messages(state: &Arc<PushState>, handle: String, messages: Vec<ReportMessage>) -> anyhow::Result<()> {
    state.0.read().await.client.as_ref().unwrap().identity.report_spam(&handle, &messages).await?;
    Ok(())
}

pub fn encode_profile_message(p: &ShareProfileMessage) -> String {
    plist_to_string(&p).unwrap()
}

pub fn decode_profile_message(s: String) -> anyhow::Result<ShareProfileMessage> {
    Ok(plist::from_bytes(s.as_bytes())?)
}

pub async fn fetch_profile(state: &Arc<PushState>, message: &ShareProfileMessage) -> anyhow::Result<IMessageNicknameRecord> {
    let inner = state.0.read().await;
    let Some(profiles) = inner.profiles_client.as_ref() else { return Err(anyhow!("No profile client!")) };
    Ok(profiles.get_record(message).await?)
}

pub async fn set_profile(state: &Arc<PushState>, record: IMessageNicknameRecord, mut existing: Option<ShareProfileMessage>) -> anyhow::Result<ShareProfileMessage> {
    let inner = state.0.read().await;
    let Some(profiles) = inner.profiles_client.as_ref() else { return Err(anyhow!("No profile client!")) };
    profiles.set_record(record, &mut existing).await?;
    Ok(existing.expect("No profile set??"))
}

pub async fn can_profile_share(state: &Arc<PushState>) -> bool {
    let inner = state.0.read().await;
    inner.profiles_client.is_some()
}

pub async fn can_statuskit(state: &Arc<PushState>) -> bool {
    let inner = state.0.read().await;
    // let Some(status) = &inner.account else { return false };
    // status.lock().await.get_token("token")
    inner.account.is_some()
}

pub async fn invite_to_channel(state: &Arc<PushState>, handle: String, to: HashMap<String, StatusKitPersonalConfig>) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let Some(status) = inner.statuskit_client.as_ref() else { return Err(anyhow!("No profile client!")) };
    Ok(status.invite_to_channel(&handle, to).await?)
}

pub async fn reset_channel_keys(state: &Arc<PushState>) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let Some(status) = inner.statuskit_client.as_ref() else { return Err(anyhow!("No profile client!")) };
    Ok(status.reset_keys().await)
}

pub async fn request_handles(state: &Arc<PushState>, to: Vec<String>) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let Some(status) = inner.statuskit_client.as_ref() else { return Err(anyhow!("No profile client!")) };
    *inner.statuskit_interest_token.lock().await = if to.is_empty() { None } else { Some(status.request_handles(&to).await.0) };
    Ok(())
}

pub async fn set_status(state: &Arc<PushState>, new_status: Option<String>) -> anyhow::Result<()> {
    let inner = state.0.read().await;
    let Some(status) = inner.statuskit_client.as_ref() else { return Err(anyhow!("No profile client!")) };
    status.share_status(&StatusKitStatus {
        active: new_status.is_none(),
        id: new_status,
    }).await?;
    Ok(())
}

pub enum PollResult {
    Stop,
    Cont(Option<PushMessage>),
}

// returns false to skip the message because our adsid is wrong
async fn handle_2fa(state: &InnerPushState, signin: &IdmsRequestedSignIn) -> bool {
    let Some(account) = state.account.clone() else {
        warn!("Ignoring circle message for no account!");
        return false;
    };

    let mut lock = account.lock().await;
    if lock.spd.is_none() {
        // trigger gsa flow
        lock.get_token("com.apple.gs.idms.pet").await;
        if lock.spd.is_none() {
            warn!("Dropping message because GSA flow failed!");
            return false;
        }
    }
    let adsid = lock.spd.as_ref().unwrap().get("adsid").expect("no adsid???s").as_string().unwrap();
    if adsid != &signin.adsid {
        warn!("Dropping 2fa code for account because adsid is wrong {adsid} {}", signin.adsid);
        return false;
    }
    drop(lock);
    true
}

async fn handle_circle(state: &InnerPushState, signin: &Option<IdmsRequestedSignIn>, msg: &IdmsCircleMessage) {
    let mut circle_lock = state.idms_circle_sessions.lock().await;
    if !circle_lock.iter().any(|a| a.atxnid == msg.atxnid) {
        if msg.step != 1 {
            warn!("Ignoring middle session!");
            return;
        }
        let Some(signin) = signin else { return };
        let push_token = state.conn.as_ref().expect("no conn?").get_token().await;
        let Some(account) = state.account.clone() else {
            warn!("Ignoring circle message for no account!");
            return;
        };

        let mut lock = account.lock().await;
        if lock.spd.is_none() {
            // trigger gsa flow
            lock.get_token("com.apple.gs.idms.pet").await;
            if lock.spd.is_none() {
                warn!("Dropping message because GSA flow failed!");
                return;
            }
        }
        let dsid = lock.spd.as_ref().unwrap().get("DsPrsId").expect("no dsid???s").as_unsigned_integer().unwrap();
        drop(lock);

        let mut rng = rand::thread_rng();
        let otp: u32 = rng.gen_range(0..1_000_000);
        let session = CircleServerSession::new(dsid, otp, account, push_token);
        circle_lock.push(ActiveCircleSession {
            session,
            atxnid: msg.atxnid.clone(),
            txnid: signin.txnid.clone(),
            init_message: Some(msg.clone()),
            otp,
        });
        if circle_lock.len() > 5 {
            circle_lock.remove(0);
        }
        // wait for user to manually click approve to handle request
        return;
    }

    match circle_lock.iter_mut().find(|a| a.atxnid == msg.atxnid).unwrap().session.handle_circle_request(msg).await {
        Err(e) => {
            warn!("error {e}");
        },
        Ok(success) => {
            // login
            if msg.step == 3 {
                let _ = state.local_broadcast.send(PushMessage::TwoFaAuthEvent(success)).await;
            }
        }
    }

    if msg.step == 5 {
        // last step, delete entry after
        circle_lock.retain(|a| a.atxnid != msg.atxnid);
    }
}

pub async fn approve_circle(state: &Arc<PushState>, txnid: String) -> anyhow::Result<u32> {
    let state_lock = state.0.read().await;
    let mut circle_lock = state_lock.idms_circle_sessions.lock().await;
    let Some(item) = circle_lock.iter_mut().find(|a| a.txnid == txnid) else {
        let account = state_lock.account.as_ref().ok_or(anyhow!("No apple account!")).unwrap().lock().await;
        let code = account.anisette.lock().await.provider.get_2fa_code().await?;
        return Ok(code);
    };
    let Some(msg) = item.init_message.take() else {
        return Err(anyhow!("Idms init message missing for approve!"));
    };
    let otp = item.otp;
    drop(circle_lock);
    drop(state_lock);
    let state_ref = state.clone();
    RUNTIME.spawn(async move {
        let state = state_ref.0.read().await;
        let mut circle_lock = state.idms_circle_sessions.lock().await;
        let Some(item) = circle_lock.iter_mut().find(|a| a.txnid == txnid) else {
            warn!("Session disappeared??");
            return
        };
        if let Err(e) = item.session.handle_circle_request(&msg).await {
            warn!("cirlce error {e}");
            return;
        }
    });
    Ok(otp)
}

pub async fn recv_wait(state: &Arc<PushState>) -> PollResult {
    let recv_path = state.0.read().await;
    let mut cancel_recv = recv_path.cancel_poll_recv.lock().await;
    if cancel_recv.try_recv().is_ok() {
        return PollResult::Stop;
    }
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (recv_wait)")
    }
    let mut local_lock = recv_path.local_messages.lock().await;
    let mut inq_lock = recv_path.inq_queue.as_ref().unwrap().lock().await;
    let mut reg_state = recv_path.reg_state.as_ref().unwrap().lock().await;
    select! {
        msg = inq_lock.recv() => {
            let msg = msg.unwrap();
            if let Some(fmfd) = &recv_path.fmfd {
                if let Err(e) = fmfd.handle(msg.clone()).await {
                    warn!("FMF import error {e}");
                }
            }
            if let Some(photostream) = &recv_path.sharedstreams {
                if let Ok(Some(changes)) = photostream.handle(msg.clone()).await {
                    handle_photostream(&photostream.client, changes, &recv_path.local_broadcast).await;
                }
            }
            if let Some(idms) = &recv_path.idms_client {
                match idms.handle(msg.clone()) {
                    Err(e) => {
                        error!("IDMS handle error {e}");
                        return PollResult::Cont(None);
                    },
                    Ok(None) => {},
                    Ok(Some(IdmsMessage::CircleRequest(circle, req))) => {
                        if let Some(req) = &req {
                            if !handle_2fa(&*recv_path, req).await { return PollResult::Cont(None) }
                        }
                        debug!("Circle here");
                        handle_circle(&*recv_path, &req, &circle).await;
                        if let Some(req) = req {
                            return PollResult::Cont(Some(PushMessage::Idms(IdmsMessage::RequestedSignIn(req))))
                        }
                    },
                    Ok(Some(IdmsMessage::RequestedSignIn(s))) => {
                        if !handle_2fa(&*recv_path, &s).await { return PollResult::Cont(None) }
                        return PollResult::Cont(Some(PushMessage::Idms(IdmsMessage::RequestedSignIn(s))))
                    },
                    Ok(Some(msg)) => {
                        return PollResult::Cont(Some(PushMessage::Idms(msg)))
                    }
                }
            }
            if let Some(statuskit) = &recv_path.statuskit_client {
                match statuskit.handle(msg.clone()).await {
                    Err(e) => {
                        error!("Statuskit handle error {e}");
                        return PollResult::Cont(None);
                    },
                    Ok(None) => {},
                    Ok(Some(msg)) => {
                        return PollResult::Cont(Some(PushMessage::StatusUpdate(msg)))
                    }
                }
            }
            let ft_msg = recv_path.ft_client.as_ref().expect("no ft client??/").handle(msg.clone()).await;
            match ft_msg {
                Ok(Some(msg)) => return PollResult::Cont(Some(PushMessage::FaceTime(msg))),
                Ok(None) => {},
                Err(err) => {
                    // log and ignore for now
                    error!("ft err {}", err);
                    return PollResult::Cont(None);
                }
            }
            let msg = recv_path.client.as_ref().expect("no client??/").handle(msg).await;
            let msg = match msg {
                Ok(Some(msg)) => Some(PushMessage::IMessage(msg)),
                Ok(None) => None,
                Err(err) => {
                    // log and ignore for now
                    error!("{}", err);
                    return PollResult::Cont(None);
                }
            };
            PollResult::Cont(msg)
        },
        _reg_state = reg_state.changed() => {
            drop(inq_lock);
            drop(reg_state);
            drop(local_lock);
            drop(cancel_recv);
            drop(recv_path);
            PollResult::Cont(Some(PushMessage::RegistrationState(get_regstate(state).await.unwrap())))
        }
        reader = local_lock.recv() => {
            PollResult::Cont(Some(reader.unwrap()))
        },
        _cancel = cancel_recv.recv() => {
            PollResult::Stop
        }
    }
}

pub async fn send(state: &Arc<PushState>, mut msg: MessageInst) -> anyhow::Result<bool> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (send)")
    }
    info!("sending_1 {msg}");
    let state_cpy = state.clone();
    let inner = state.0.read().await;
    info!("sending_2");
    let result = inner.client.as_ref().unwrap().send(&mut msg).await?;
    info!("send_finish");

    if let Some(handle) = result.handle {
        let uuid = msg.id.clone();
        tokio::spawn(async move {
            let result = handle.await.unwrap();
            info!("Finished handle {}", uuid);
            let locked = state_cpy.0.read().await;
            let maybeerr = result.err().map(|err| format!("{}", err));
            let _ = locked.local_broadcast.send(PushMessage::SendConfirm { uuid, error: maybeerr }).await;
        });
        Ok(true)
    } else {
        Ok(false)
    }
}

pub async fn get_handles(state: &Arc<PushState>) -> anyhow::Result<Vec<String>> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (send)")
    }
    Ok(state.0.read().await.client.as_ref().unwrap().identity.get_handles().await.to_vec())
}

pub async fn get_my_phone_handles(state: &Arc<PushState>) -> anyhow::Result<Vec<String>> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (send)")
    }
    Ok(state.0.read().await.client.as_ref().unwrap().identity.get_my_phone_handles().await.to_vec())
}

pub async fn do_reregister(state: &Arc<PushState>) -> anyhow::Result<()> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (send)")
    }
    state.0.read().await.client.as_ref().unwrap().identity.refresh_now().await?;
    Ok(())
}

pub async fn new_msg(state: &Arc<PushState>, conversation: ConversationData, sender: String, message: Message) -> MessageInst {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (new_msg)")
    }
    MessageInst::new(conversation, &sender, message)
}

pub async fn validate_targets(state: &Arc<PushState>, targets: Vec<String>, sender: String) -> anyhow::Result<Vec<String>> {
    if !matches!(state.get_phase().await, RegistrationPhase::Registered) {
        panic!("Wrong phase! (validate_targets)")
    }
    Ok(state.0.read().await.client.as_ref().unwrap().identity.validate_targets(&targets, "com.apple.madrid", &sender).await?)
}

pub async fn get_phase(state: &Arc<PushState>) -> RegistrationPhase {
    state.get_phase().await
}

#[frb(type_64bit_int)]
pub struct TransferProgress {
    pub prog: usize,
    pub total: usize,
    pub attachment: Option<Attachment>
}

pub async fn download_attachment(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, attachment: Attachment, path: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;
        println!("donwloading file {}", path);
        let path = std::path::Path::new(&path);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;
        let mut file = std::fs::File::create(path)?;
        attachment.get_attachment(inner.conn.as_ref().unwrap(), &mut file, |prog, total| {
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

pub async fn download_mmcs(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, attachment: MMCSFile, path: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;
        let path = std::path::Path::new(&path);
        let prefix = path.parent().unwrap();
        std::fs::create_dir_all(prefix)?;

        let mut file = std::fs::File::create(path)?;
        attachment.get_attachment(inner.conn.as_ref().unwrap(), &mut file, |prog, total| {
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
    pub file: Option<MMCSFile>
}

pub async fn upload_mmcs(sink: StreamSink<MMCSTransferProgress>, state: &Arc<PushState>, path: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;

        let mut file = std::fs::File::open(path)?;
        let prepared = MMCSFile::prepare_put(&mut file).await?;
        file.rewind()?;
        let attachment = MMCSFile::new(inner.conn.as_ref().unwrap(), &prepared, file, |prog, total| {
            sink.add(MMCSTransferProgress {
                prog,
                total,
                file: None
            }).unwrap();
        }).await?;
        sink.add(MMCSTransferProgress { prog: 0, total: 0, file: Some(attachment) }).unwrap();
        Ok(())
    }).await
}

pub async fn upload_attachment(sink: StreamSink<TransferProgress>, state: &Arc<PushState>, path: String, mime: String, uti: String, name: String) {
    wrap_sink(&sink, || async {
        let inner = state.0.read().await;

        let mut file = std::fs::File::open(path)?;
        let prepared = MMCSFile::prepare_put(&mut file).await?;
        file.rewind()?;
        let attachment = Attachment::new_mmcs(inner.conn.as_ref().unwrap(), &prepared, file, &mime, &uti, &name,|prog, total| {
            sink.add(TransferProgress {
                prog,
                total,
                attachment: None
            }).unwrap();
        }).await?;
        sink.add(TransferProgress { prog: 0, total: 0, attachment: Some(attachment) }).unwrap();
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

pub async fn make_find_my_phone(state: &Arc<PushState>) -> anyhow::Result<FindMyPhoneClient<DefaultAnisetteProvider>> {
    let inner = state.0.read().await;

    let id_path = inner.conf_dir.join("findmy.plist");
    let state: FindMyState = plist::from_file(id_path)?;

    Ok(FindMyPhoneClient::new(inner.os_config.as_deref().unwrap(), state, inner.conn.clone().unwrap(), inner.anisette.clone().unwrap()).await?)
}

pub async fn get_devices(client: &mut FindMyPhoneClient<DefaultAnisetteProvider>) -> Vec<FoundDevice> {
    client.devices.clone()
}

pub async fn refresh_devices(state: &Arc<PushState>, client: &mut FindMyPhoneClient<DefaultAnisetteProvider>) -> anyhow::Result<Vec<FoundDevice>> {
    let inner = state.0.read().await;
    client.refresh(inner.os_config.as_deref().unwrap()).await?;
    Ok(client.devices.clone())
}

pub async fn make_find_my_friends(state: &Arc<PushState>) -> anyhow::Result<FindMyFriendsClient<DefaultAnisetteProvider>> {
    let inner = state.0.read().await;

    let fmfd = inner.fmfd.as_ref().ok_or(anyhow!("Fmfd!"))?;

    Ok(FindMyFriendsClient::new(inner.os_config.as_deref().unwrap(), fmfd.state.clone(), inner.account.clone().ok_or(anyhow!("No account?"))?, inner.conn.clone().unwrap(), inner.anisette.clone().unwrap(), false).await?)
}

pub async fn get_following(client: &mut FindMyFriendsClient<DefaultAnisetteProvider>) -> Vec<Follow> {
    client.following.clone()
}

pub async fn refresh_following(state: &Arc<PushState>, client: &mut FindMyFriendsClient<DefaultAnisetteProvider>) -> anyhow::Result<Vec<Follow>> {
    let inner = state.0.read().await;
    client.refresh(inner.os_config.as_deref().unwrap()).await?;
    Ok(client.following.clone())
}

pub async fn select_friend(state: &Arc<PushState>, client: &mut FindMyFriendsClient<DefaultAnisetteProvider>, friend: Option<String>) -> anyhow::Result<Vec<Follow>> {
    let inner = state.0.read().await;
    client.selected_friend = friend;
    client.refresh(inner.os_config.as_deref().unwrap()).await?;
    Ok(client.following.clone())
}

pub async fn select_background_friend(state: &Arc<PushState>, friend: Option<String>) -> anyhow::Result<Vec<Follow>> {
    let inner = state.0.read().await;
    let mut x = inner.fmfd.as_ref().unwrap().daemon.lock().await;
    x.selected_friend = friend;
    Ok(x.following.clone())
}

pub async fn get_background_following(state: &Arc<PushState>) -> Vec<Follow> {
    let inner = state.0.read().await;
    let x = inner.fmfd.as_ref().unwrap().daemon.lock().await.following.clone();
    x
}

pub async fn refresh_background_following(state: &Arc<PushState>) -> anyhow::Result<Vec<Follow>> {
    let inner = state.0.read().await;
    let mut x = inner.fmfd.as_ref().unwrap().daemon.lock().await;
    x.refresh(inner.os_config.as_deref().unwrap()).await?;
    Ok(x.following.clone())
}

#[derive(Serialize, Deserialize)]
struct GSAConfig {
    username: String,
    password: Data,
    postdata_done: Option<bool>,
}

async fn do_login(conf_dir: &Path, account: &mut AppleAccount<DefaultAnisetteProvider>, cookie: Option<&str>, anisette: &ArcAnisetteClient<DefaultAnisetteProvider>, os_config: &dyn OSConfig) -> anyhow::Result<IDSUser> {
    account.update_postdata("Apple Device", None, &["icloud", "imessage", "facetime"]).await?;

    let Some(pet) = account.get_pet() else { return Err(anyhow!("No pet!")) };
    let Some(spd) = &account.spd else { return Err(anyhow!("No spd!")) };

    debug!("Got spd {:?}", spd);
    let adsid = spd.get("adsid").ok_or(anyhow!("No adsid!"))?.as_string().unwrap();
    let acname = spd.get("acname").ok_or(anyhow!("No acname!"))?.as_string().unwrap().to_string();
    let dsid = spd.get("DsPrsId").ok_or(anyhow!("No dsid!"))?.as_unsigned_integer().unwrap().to_string();
    
    let delegates = login_apple_delegates(account.username.as_ref().unwrap(), &pet, adsid, cookie, &mut *anisette.lock().await, os_config, &[LoginDelegate::IDS, LoginDelegate::MobileMe]).await?;

    plist::to_file_xml(conf_dir.join("gsa.plist"), &GSAConfig {
        username: account.username.clone().unwrap(),
        password: account.hashed_password.clone().unwrap().into(),
        postdata_done: Some(true),
    }).unwrap();

    let path = conf_dir.join("statuskit.plist");
    std::fs::write(&path, plist_to_string(&StatusKitState {
        my_key: None,
        ..plist::from_file(&path).unwrap_or_default()
    }).unwrap()).unwrap();

    let mobileme = delegates.mobileme.unwrap();
    let findmy = FindMyState::new(dsid.clone(), acname, &mobileme);

    if let Some(findmy) = findmy {
        let id_path = conf_dir.join("findmy.plist");
        std::fs::write(id_path, plist_to_string(&findmy).unwrap()).unwrap();
    } else {
        warn!("missing findmy tokens!");
    }

    let shared_streams = SharedStreamsState::new(dsid.clone(), &mobileme);
    if let Some(shared_streams) = shared_streams {
        let id_path = conf_dir.join("sharedstreams.plist");
        std::fs::write(id_path, plist_to_string(&shared_streams).unwrap()).unwrap();
    } else {
        warn!("missing shared streams tokens!");
    }

    let cloudkitstate = CloudKitState::new(dsid.clone(), &mobileme);
    if let Some(cloudkitstate) = cloudkitstate {
        let id_path = conf_dir.join("cloudkit.plist");
        std::fs::write(id_path, plist_to_string(&cloudkitstate).unwrap()).unwrap();
    } else {
        warn!("missing cloudkit tokens!");
    }

    debug!("Spd finish parse");

    let user = authenticate_apple(delegates.ids.unwrap(), os_config).await?;
    Ok(user)
}

pub async fn try_auth(state: &Arc<PushState>, username: String, password: String) -> anyhow::Result<(LoginState, Option<IDSUser>)> {
    let mut inner = state.0.write().await;
    let mut apple_account =
        AppleAccount::new_with_anisette(get_login_config(&*inner).await, inner.anisette.clone().unwrap())?;

    let mut password_hasher = sha2::Sha256::new();
    password_hasher.update(&password.as_bytes());
    let hashed_password = password_hasher.finalize();

    let mut login_state = apple_account.login_email_pass(&username, &hashed_password).await?;

    inner.account = Some(Arc::new(Mutex::new(apple_account)));
    let mut apple_account = inner.account.as_ref().unwrap().lock().await;

    let mut user = None;
    if let Some(pet) = apple_account.get_pet() {
        let identity = do_login(&inner.conf_dir, &mut *apple_account,None, inner.anisette.as_ref().unwrap(), inner.os_config.as_deref().unwrap()).await?;
        user = Some(identity);

        // who needs extra steps when you have a PET, amirite?
        println!("confirmed login {:?}", login_state);
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }


    Ok((login_state, user))
}

pub async fn auth_phone(state: &Arc<PushState>, number: String, sig: Vec<u8>) -> anyhow::Result<IDSUser> {
    let inner = state.0.read().await;

    let identity = authenticate_phone(&number, AuthPhone {
        push_token: inner.conn.as_deref().unwrap().get_token().await.to_vec().into(),
        sigs: vec![sig.into()]
    }, inner.os_config.as_deref().unwrap()).await?;

    Ok(identity)
}

pub async fn send_2fa_to_devices(state: &Arc<PushState>) -> anyhow::Result<LoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap().lock().await;
    Ok(account.send_2fa_to_devices().await?)

}

pub async fn verify_2fa(state: &Arc<PushState>, code: String) -> anyhow::Result<(LoginState, Option<IDSUser>)> {
    let mut inner = state.0.write().await;
    let mut account = inner.account.as_ref().unwrap().lock().await;
    let mut login_state = account.verify_2fa(code).await?;

    let mut user = None;
    if let Some(pet) = account.get_pet() {
        let identity = do_login(&inner.conf_dir, &mut *account, None, inner.anisette.as_ref().unwrap(), inner.os_config.as_deref().unwrap()).await?;
        user = Some(identity);

        // who needs extra steps when you have a PET, amirite?
        println!("confirmed login {:?}", login_state);
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    Ok((login_state, user))
}



pub async fn get_2fa_sms_opts(state: &Arc<PushState>) -> anyhow::Result<(Vec<TrustedPhoneNumber>, Option<LoginState>)> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap().lock().await;
    let extras = account.get_auth_extras().await?;
    Ok((
        extras.trusted_phone_numbers,
        extras.new_state
    ))
}

pub async fn send_2fa_sms(state: &Arc<PushState>, phone_id: u32) -> anyhow::Result<LoginState> {
    let inner = state.0.read().await;
    let account = inner.account.as_ref().unwrap().lock().await;
    Ok(account.send_sms_2fa_to_devices(phone_id).await?)
}

pub async fn verify_2fa_sms(state: &Arc<PushState>, body: &VerifyBody, code: String) -> anyhow::Result<(LoginState, Option<IDSUser>)> {
    let mut inner = state.0.write().await;
    let mut account = inner.account.as_ref().unwrap().lock().await;
    let mut login_state = account.verify_sms_2fa(code, body.clone()).await?;

    let mut user = None;
    if let Some(pet) = account.get_pet() {
        let identity = do_login(&inner.conf_dir, &mut *account, None, inner.anisette.as_ref().unwrap(), inner.os_config.as_deref().unwrap()).await?;
        user = Some(identity);

        // who needs extra steps when you have a PET, amirite?
        println!("confirmed login {:?}", login_state);
        if matches!(login_state, LoginState::NeedsExtraStep(_)) {
            login_state = LoginState::LoggedIn;
        }
    }

    Ok((login_state, user))
}

pub async fn validate_cert(state: &Arc<PushState>, user: &IDSUser) -> anyhow::Result<Vec<String>> {
    let inner = state.0.read().await;
    let x = Ok(user.get_possible_handles(&*inner.conn.as_ref().unwrap().state.read().await).await?);
    x
}

pub async fn reset_state(state: &Arc<PushState>, reset_hw: bool, logout: bool) -> anyhow::Result<()> {
    // tell any poll to stop
    let inner = state.0.read().await;
    let _ = inner.cancel_poll.try_send(());
    drop(inner);
    let mut inner = state.0.write().await;
    info!("a");
    let conn_state = inner.conn.as_ref().unwrap().clone();
    info!("b {:?}", inner.os_config.is_some());
    inner.client = None;
    inner.fmfd = None;
    inner.sharedstreams = None;
    inner.reg_state = None;
    inner.profiles_client = None;
    inner.statuskit_client = None;
    inner.ft_client = None;
    inner.idms_client = None;
    inner.idms_circle_sessions.lock().await.clear();
    *inner.statuskit_interest_token.lock().await = None;
    // try deregistering from iMessage, but if it fails we don't really care
    let _ = register(inner.os_config.as_deref().unwrap(), &*conn_state.state.read().await, &[], &mut [], inner.identity.as_ref().unwrap()).await;
    info!("c");
    if logout {
        if let Some(account) = &inner.account {
            let _ = account.lock().await.logout_all("Apple Device").await;
        }
    }
    inner.account = None;
    let _ = std::fs::remove_file(inner.conf_dir.join("id.plist"));
    let _ = std::fs::remove_file(inner.conf_dir.join("findmy.plist"));
    let _ = std::fs::remove_file(inner.conf_dir.join("facetime.plist"));
    let _ = std::fs::remove_dir(inner.conf_dir.join("cloudkit.plist"));
    let _ = std::fs::remove_file(inner.conf_dir.join("sharedstreams.plist"));
    let _ = std::fs::remove_file(inner.conf_dir.join("gsa.plist"));
    if let Ok(mut cache) = plist::from_file::<_, Dictionary>(inner.conf_dir.join("id_cache.plist")) {
        // keep replay counters which are nessesary if our identity doesn't change
        cache.get_mut("cache").expect("No cache?").as_dictionary_mut().unwrap().clear();
        plist::to_file_xml(inner.conf_dir.join("id_cache.plist"), &cache)?;
    }

    let path = inner.conf_dir.join("statuskit.plist");
    std::fs::write(&path, plist_to_string(&StatusKitState {
        my_key: None,
        ..plist::from_file(&path).unwrap_or_default()
    }).unwrap()).unwrap();

    if reset_hw {
        inner.inq_queue = None;
        inner.conn = None;
        inner.os_config = None;
        let _ = std::fs::remove_file(inner.conf_dir.join("hw_info.plist"));
        let _ = std::fs::remove_file(inner.conf_dir.join("id_cache.plist")); // our identity is wiped so we can wipe our counters too
        let _ = std::fs::remove_file(inner.conf_dir.join("statuskit.plist"));
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
    let (first, last) = inner.account.as_ref().unwrap().lock().await.get_name();
    Ok(format!("{first} {last}"))
}


#[derive(Clone)]
#[frb(type_64bit_int)]
pub enum RegisterState {
    Registered {
        next_s: i64,
    },
    Registering,
    Failed {
        retry_wait: Option<u64>,
        error: String
    }
}

pub async fn get_regstate(state: &Arc<PushState>) -> anyhow::Result<RegisterState> {
    let inner = state.0.read().await;
    let mutex_ref = inner.client.as_ref().unwrap().identity.resource_state.borrow().clone();
    Ok(match &mutex_ref {
        ResourceState::Generating => RegisterState::Registering,
        ResourceState::Generated => RegisterState::Registered {
            next_s: inner.client.as_ref().unwrap().identity.calculate_rereg_time_s().await
        },
        ResourceState::Failed(failure) =>
            RegisterState::Failed { retry_wait: failure.retry_wait, error: format!("{}", failure.error) },
    })
}

pub async fn convert_token_to_uuid(state: &Arc<PushState>, handle: String, token: Vec<u8>) -> anyhow::Result<String> {
    let inner = state.0.read().await;
    let uuid = inner.client.as_ref().unwrap().identity.token_to_uuid(&handle, &token).await?;
    Ok(uuid)
}


pub async fn get_sms_targets(state: &Arc<PushState>, handle: String, refresh: bool) -> anyhow::Result<Vec<PrivateDeviceInfo>> {
    let inner = state.0.read().await;
    let targets = inner.client.as_ref().unwrap().identity.get_sms_targets(&handle, refresh).await?;
    Ok(targets)
}
