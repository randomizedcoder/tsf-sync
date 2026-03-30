use std::process::Command;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum ModuleError {
    #[error("failed to read /proc/modules: {0}")]
    ProcModules(std::io::Error),
    #[error("modprobe failed: {0}")]
    Modprobe(String),
    #[error("rmmod failed: {0}")]
    Rmmod(String),
    #[error("command execution failed: {0}")]
    Exec(#[from] std::io::Error),
}

const MODULE_NAME: &str = "tsf_ptp";

/// Check if a kernel module is currently loaded.
pub fn is_module_loaded(module: &str) -> Result<bool, ModuleError> {
    is_module_loaded_from(&std::fs::read_to_string("/proc/modules").map_err(ModuleError::ProcModules)?, module)
}

/// Parse /proc/modules content to check if a module is loaded.
/// Exported for testing.
fn is_module_loaded_from(proc_modules: &str, module: &str) -> Result<bool, ModuleError> {
    // /proc/modules format: "module_name size refcount deps state offset"
    // Module names use underscores in /proc/modules regardless of how they were loaded.
    let normalized = module.replace('-', "_");
    Ok(proc_modules
        .lines()
        .any(|line| {
            line.split_whitespace()
                .next()
                .is_some_and(|name| name == normalized)
        }))
}

/// Check if the tsf-ptp module is loaded.
pub fn is_tsf_ptp_loaded() -> Result<bool, ModuleError> {
    is_module_loaded(MODULE_NAME)
}

/// Load a kernel module via modprobe.
pub fn load_module(module: &str, params: &[&str]) -> Result<(), ModuleError> {
    let output = Command::new("modprobe")
        .arg(module)
        .args(params)
        .output()
        .map_err(ModuleError::Exec)?;

    if output.status.success() {
        tracing::info!(module, "loaded kernel module");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        Err(ModuleError::Modprobe(stderr))
    }
}

/// Load a kernel module via insmod (for out-of-tree modules).
pub fn insmod(path: &str, params: &[&str]) -> Result<(), ModuleError> {
    let output = Command::new("insmod")
        .arg(path)
        .args(params)
        .output()
        .map_err(ModuleError::Exec)?;

    if output.status.success() {
        tracing::info!(path, "loaded kernel module via insmod");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        Err(ModuleError::Modprobe(stderr))
    }
}

/// Load the tsf-ptp module. Tries modprobe first, falls back to insmod
/// from the known build location.
pub fn load_tsf_ptp(adjtime_threshold_ns: u64) -> Result<(), ModuleError> {
    if is_tsf_ptp_loaded()? {
        tracing::info!("tsf-ptp module already loaded");
        return Ok(());
    }

    let threshold_param = format!("adjtime_threshold_ns={}", adjtime_threshold_ns);
    let params = [threshold_param.as_str()];

    // Try modprobe first (works if installed via DKMS/modules_install).
    match load_module(MODULE_NAME, &params) {
        Ok(()) => return Ok(()),
        Err(e) => tracing::debug!("modprobe failed, will try insmod: {}", e),
    }

    // Try insmod from project directory.
    let module_path = "kernel/tsf_ptp.ko";
    if std::path::Path::new(module_path).exists() {
        insmod(module_path, &params)
    } else {
        Err(ModuleError::Modprobe(format!(
            "tsf_ptp module not found via modprobe or at {}",
            module_path
        )))
    }
}

/// Unload a kernel module via rmmod.
pub fn unload_module(module: &str) -> Result<(), ModuleError> {
    let output = Command::new("rmmod")
        .arg(module)
        .output()
        .map_err(ModuleError::Exec)?;

    if output.status.success() {
        tracing::info!(module, "unloaded kernel module");
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        Err(ModuleError::Rmmod(stderr))
    }
}

/// Unload the tsf-ptp module.
pub fn unload_tsf_ptp() -> Result<(), ModuleError> {
    if !is_tsf_ptp_loaded()? {
        tracing::info!("tsf-ptp module not loaded, nothing to unload");
        return Ok(());
    }
    unload_module(MODULE_NAME)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_PROC_MODULES: &str = "\
mac80211_hwsim 69632 0 - Live 0xffffffffa0200000
tsf_ptp 16384 0 - Live 0xffffffffa0100000
mac80211 1036288 2 mac80211_hwsim,tsf_ptp, Live 0xffffffffa0000000
cfg80211 1130496 2 mac80211_hwsim,mac80211, Live 0xffffffff9fe00000
rfkill 36864 4 cfg80211, Live 0xffffffff9fd00000
";

    #[test]
    fn test_module_loaded() {
        assert!(is_module_loaded_from(SAMPLE_PROC_MODULES, "tsf_ptp").unwrap());
        assert!(is_module_loaded_from(SAMPLE_PROC_MODULES, "mac80211_hwsim").unwrap());
        assert!(is_module_loaded_from(SAMPLE_PROC_MODULES, "mac80211").unwrap());
        assert!(is_module_loaded_from(SAMPLE_PROC_MODULES, "cfg80211").unwrap());
    }

    #[test]
    fn test_module_not_loaded() {
        assert!(!is_module_loaded_from(SAMPLE_PROC_MODULES, "iwlwifi").unwrap());
        assert!(!is_module_loaded_from(SAMPLE_PROC_MODULES, "nonexistent").unwrap());
    }

    #[test]
    fn test_hyphen_underscore_normalization() {
        // Module names with hyphens should match underscored names in /proc/modules.
        assert!(is_module_loaded_from(SAMPLE_PROC_MODULES, "tsf-ptp").unwrap());
        assert!(is_module_loaded_from(SAMPLE_PROC_MODULES, "mac80211-hwsim").unwrap());
    }

    #[test]
    fn test_empty_proc_modules() {
        assert!(!is_module_loaded_from("", "tsf_ptp").unwrap());
    }

    #[test]
    fn test_partial_name_no_false_positive() {
        // "tsf" should NOT match "tsf_ptp".
        assert!(!is_module_loaded_from(SAMPLE_PROC_MODULES, "tsf").unwrap());
        // "ptp" should NOT match "tsf_ptp".
        assert!(!is_module_loaded_from(SAMPLE_PROC_MODULES, "ptp").unwrap());
    }
}
