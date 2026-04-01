use std::sync::atomic::{AtomicBool, Ordering};

/// Global flag: true while the sync loop should keep running.
pub static RUNNING: AtomicBool = AtomicBool::new(true);

/// Install SIGINT + SIGTERM handlers that set RUNNING to false.
pub fn install_handler() {
    unsafe {
        libc::signal(
            libc::SIGINT,
            signal_handler as *const () as libc::sighandler_t,
        );
        libc::signal(
            libc::SIGTERM,
            signal_handler as *const () as libc::sighandler_t,
        );
    }
}

extern "C" fn signal_handler(_sig: libc::c_int) {
    RUNNING.store(false, Ordering::SeqCst);
}
