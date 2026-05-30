use crate::constants;
use std::{backtrace, fs, io::Write};

/// Install a panic hook that prints the panic + backtrace to stderr (so it
/// reaches journald / `podman logs`) and also tries to drop a copy at
/// `${XDG_CACHE_HOME}/nanoviz_backtrace.log` for post-mortem reading.
///
/// Critical for the container deploy path: `Cargo.toml` sets
/// `panic = "abort"`, so a panic becomes SIGABRT → container exit 134. The
/// runtime aborts immediately after the hook returns, skipping destructors
/// and any buffered output. We explicitly `flush()` stderr inside the hook
/// so the message survives.
pub fn register_backtrace_panic_handler() {
    std::panic::set_hook(Box::new(|panic_info| {
        let backtrace = backtrace::Backtrace::force_capture();

        // stderr first — this is what journald and `podman logs` see. Use
        // a single write so the lines don't get interleaved with other
        // threads' output. Flush before returning because the abort below
        // skips destructors.
        let mut stderr = std::io::stderr().lock();
        let _ = writeln!(stderr, "\n=== NanoViz panicked ===");
        let _ = writeln!(stderr, "{panic_info}");
        let _ = writeln!(stderr, "{backtrace}");
        let _ = writeln!(stderr, "=== end panic ===\n");
        let _ = stderr.flush();

        // Best-effort copy to a file so users can grab it after the fact
        // (only useful on non-containerized installs — the container's
        // cache dir is ephemeral).
        if let Some(path) = dirs::cache_dir() {
            let path = path.join(constants::DEFAULT_BACKTRACE_FILE);
            if let Ok(mut file) = fs::File::create(&path) {
                let _ = writeln!(file, "{panic_info}");
                let _ = writeln!(file, "{backtrace}");
                let _ = writeln!(stderr, "Backtrace also saved to {}", path.display());
                let _ = stderr.flush();
            }
        }
    }));
}
