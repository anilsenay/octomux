//! macOS privacy permissions of the daemon process. Programs in sessions descend from the daemon, so macOS
//! asks for and checks screen recording / accessibility against it (its background app, "Octomux Sessions").

use serde_json::{json, Value};

#[cfg(target_os = "macos")]
mod sys {
    #[link(name = "CoreGraphics", kind = "framework")]
    unsafe extern "C" {
        pub fn CGPreflightScreenCaptureAccess() -> bool;
        pub fn CGRequestScreenCaptureAccess() -> bool;
    }
    #[link(name = "ApplicationServices", kind = "framework")]
    unsafe extern "C" {
        pub fn AXIsProcessTrusted() -> bool;
    }
}

/// `{ screen_recording, accessibility, app }`: booleans, plus the binary macOS checks them against.
pub fn status() -> Value {
    let app = std::env::current_exe().ok().map(|p| p.display().to_string()).unwrap_or_default();
    #[cfg(target_os = "macos")]
    unsafe {
        json!({ "screen_recording": sys::CGPreflightScreenCaptureAccess(), "accessibility": sys::AXIsProcessTrusted(), "app": app })
    }
    #[cfg(not(target_os = "macos"))]
    json!({ "screen_recording": true, "accessibility": true, "app": app })
}

/// Shows macOS's screen recording prompt for the daemon's app (once; later calls only report).
pub fn request_screen_recording() -> bool {
    #[cfg(target_os = "macos")]
    unsafe {
        sys::CGRequestScreenCaptureAccess()
    }
    #[cfg(not(target_os = "macos"))]
    true
}
