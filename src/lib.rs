#[cfg(not(any(target_os = "linux", target_os = "macos")))]
compile_error!(
    "nanoviz supports Linux (the prod target — Raspberry Pi container) and \
     macOS (dev). Other targets are unsupported."
);

pub mod audio;
pub mod config;
pub mod constants;
pub mod layout_visualizer;
pub mod nanoleaf;
pub mod now_playing;
pub mod palettes;
pub mod panic;
pub mod processing;
pub mod ssdp;
pub mod utils;
pub mod visualizer;
