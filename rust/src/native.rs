use std::{fmt::Debug, sync::{Arc, RwLock}};

use rustpush::get_gateways_for_mccmnc;
use tokio::runtime::{Handle, Runtime};
use uniffi::deps::log::info;

use crate::{api::api::{get_phase, new_push_state, recv_wait, InnerPushState, PollResult, PushState, RegistrationPhase}, frb_generated::FLUTTER_RUST_BRIDGE_HANDLER, runtime};

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
    #[cfg(target_os = "android")]
    android_log::init("rustpush").unwrap();
    info!("rpljslf start");
    runtime().spawn(async move {
        info!("rpljslf initting");
        // TODO retry if this *unwrap* fails
        let state = Arc::new(NativePushState {
            state: new_push_state(dir).await.unwrap()
        });
        info!("rpljslf raed");
        handler.native_ready(state.get_ready().await, state.clone());
        info!("rpljslf dom");
    });
}

#[uniffi::export]
pub fn get_carrier(handler: Arc<dyn CarrierHandler>, mccmnc: String) {
    runtime().spawn(async move {
        match get_gateways_for_mccmnc(&mccmnc).await {
            Ok(gateway) => handler.got_gateway(Some(gateway), None),
            Err(err) => handler.got_gateway(None, Some(err.to_string())),
        }
    });
}

#[uniffi::export]
impl NativePushState {

    pub fn start_loop(self: Arc<NativePushState>, handler: Arc<dyn MsgReceiver>) {
        runtime().spawn(async move {
            loop {
                match recv_wait(&self.state).await {
                    PollResult::Cont(Some(msg)) => {
                        let result = Box::into_raw(Box::new(msg)) as u64;
                        info!("emitting pointer {result}");
                        handler.receieved_msg(result);
                    },
                    PollResult::Cont(None) => continue,
                    PollResult::Stop => break
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