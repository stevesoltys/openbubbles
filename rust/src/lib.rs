use std::sync::OnceLock;

use tokio::runtime::Runtime;
use uniffi::deps::log::info;


uniffi::setup_scaffolding!();

pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    info!("creating runner");
    RUNTIME.get_or_init(|| tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .thread_name("tokio-rustpush")
        .enable_all()
        .build().unwrap())
}

pub mod bbhwinfo {
    include!(concat!(env!("OUT_DIR"), "/bbhwinfo.rs"));
}

mod native;
pub mod api;
mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
