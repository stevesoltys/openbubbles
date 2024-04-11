use std::sync::OnceLock;

use tokio::runtime::Runtime;


uniffi::setup_scaffolding!();

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| Runtime::new().unwrap())
}

pub mod bbhwinfo {
    include!(concat!(env!("OUT_DIR"), "/bbhwinfo.rs"));
}

mod native;
pub mod api;
mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
