use std::{collections::{BTreeMap, HashMap}, fmt::Debug, sync::{Arc, LazyLock, OnceLock, RwLock}, time::Duration};

use flexi_logger::{FileSpec, Logger, WriteMode};
use log::error;
use rustpush::get_gateways_for_mccmnc;
use tokio::{runtime::{Handle, Runtime}, sync::Mutex};
use uniffi::deps::log::info;

use futures::FutureExt;
use crate::{api::api::{get_phase, new_push_state, recv_wait, PollResult, PushMessage, PushState, RegistrationPhase}, frb_generated::FLUTTER_RUST_BRIDGE_HANDLER, init_logger, RUNTIME};

#[uniffi::export(with_foreign)]
pub trait MsgReceiver: Send + Sync + Debug {
    fn receieved_msg(&self, msg: u64);
    fn native_ready(&self, is_ready: bool, state: Arc<NativePushState>);
}

#[uniffi::export(with_foreign)]
pub trait CarrierHandler: Send + Sync + Debug {
    fn got_gateway(&self, gateway: Option<String>, error: Option<String>);
}

#[derive(uniffi::Object)] 
pub struct NativePushState {
    state: Arc<PushState>
}

#[uniffi::export]
pub fn init_native(dir: String, handler: Arc<dyn MsgReceiver>) {
    info!("rpljslf start");
    RUNTIME.spawn(async move {
        info!("rpljslf initting");
        // TODO retry if this *unwrap* fails
        let state = Arc::new(NativePushState {
            state: new_push_state(dir).await
        });
        info!("rpljslf raed");
        handler.native_ready(state.get_ready().await, state.clone());
        info!("rpljslf dom");
    });
}

#[uniffi::export]
pub fn get_carrier(handler: Arc<dyn CarrierHandler>, mccmnc: String) {
    RUNTIME.spawn(async move {
        match get_gateways_for_mccmnc(&mccmnc).await {
            Ok(gateway) => handler.got_gateway(Some(gateway), None),
            Err(err) => handler.got_gateway(None, Some(err.to_string())),
        }
    });
}

pub static QUEUED_MESSAGES: LazyLock<Mutex<(u64, HashMap<u64, PushMessage>)>> = LazyLock::new(|| Mutex::new((0, HashMap::new())));

#[uniffi::export]
impl NativePushState {

    pub fn start_loop(self: Arc<NativePushState>, handler: Arc<dyn MsgReceiver>) {
        RUNTIME.spawn(async move {
            loop {
                match std::panic::AssertUnwindSafe(recv_wait(&self.state)).catch_unwind().await {
                    Ok(yes) => {
                        match yes {
                            PollResult::Cont(Some(msg)) => {
                                let mut locked_messages = QUEUED_MESSAGES.lock().await;
                                let key = locked_messages.0;
                                locked_messages.1.insert(key, msg);
                                locked_messages.0 = locked_messages.0.wrapping_add(1);
                                drop(locked_messages);

                                let handler_ref = handler.clone();
                                tokio::spawn(async move {
                                    tokio::time::sleep(Duration::from_secs(10)).await;
                                    while QUEUED_MESSAGES.lock().await.1.contains_key(&key) {
                                        info!("re-emitting pointer {key}");
                                        // we still haven't been handled, attempt to handle again
                                        handler_ref.receieved_msg(key);
                                        tokio::time::sleep(Duration::from_secs(10)).await;
                                    }
                                });

                                info!("emitting pointer {key}");
                                handler.receieved_msg(key);
                            },
                            PollResult::Cont(None) => continue,
                            PollResult::Stop => break
                        }
                    },
                    Err(payload) => {
                        let panic = match payload.downcast_ref::<&'static str>() {
                            Some(msg) => Some(*msg),
                            None => match payload.downcast_ref::<String>() {
                                Some(msg) => Some(msg.as_str()),
                                // Copy what rustc does in the default panic handler
                                None => None,
                            },
                        };
                        error!("Failed {:?}", panic);
                    }
                }
            }
            info!("finishing loop");
        });
    }

    pub fn get_state(self: Arc<NativePushState>) -> u64 {
        let arc_val = Arc::into_raw(self.state.clone()) as u64;
        info!("emitting state {arc_val}");
        arc_val
    }

    async fn get_ready(&self) -> bool {
        matches!(get_phase(&self.state).await, RegistrationPhase::Registered)
    }
}