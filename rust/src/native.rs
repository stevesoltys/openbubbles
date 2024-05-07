use std::sync::{Arc, RwLock};

use tokio::runtime::{Handle, Runtime};
use uniffi::deps::log::info;

use crate::{api::api::{get_phase, new_push_state, recv_wait, runtime, InnerPushState, PollResult, PushState, RegistrationPhase}, frb_generated::FLUTTER_RUST_BRIDGE_HANDLER};

#[derive(uniffi::Object)] 
pub struct NativePushState {
    state: Arc<PushState>
}

#[uniffi::export]
pub fn init_native(dir: String) -> Arc<NativePushState> {
    runtime().block_on(async {
        Arc::new(NativePushState {
            state: new_push_state(dir).await.unwrap()
        })
    })
}

#[uniffi::export]
impl NativePushState {

    pub fn get_state(self: Arc<NativePushState>) -> u64 {
        let arc_val = Arc::into_raw(self.state.clone()) as u64;
        info!("emitting state {arc_val}");
        arc_val
    }

    pub fn get_ready(self: Arc<NativePushState>) -> bool {
        runtime().block_on(async {
            matches!(get_phase(&self.state).await, RegistrationPhase::Registered)
        })
    }

    pub fn recv_wait(self: Arc<NativePushState>) -> u64 {
        runtime().block_on(async {
            let msg = match recv_wait(&self.state).await {
                PollResult::Cont(Some(msg)) => msg,
                PollResult::Cont(None) => return 0,
                PollResult::Stop => return u64::MAX
            };
            let result = Box::into_raw(Box::new(msg)) as u64;
            info!("emitting pointer {result}");
            result
        })
    }
}