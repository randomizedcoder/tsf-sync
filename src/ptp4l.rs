use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum SyncError {
    #[error("failed to start {name}: {source}")]
    Start { name: String, source: std::io::Error },
    #[error("{0} not found — is linuxptp installed?")]
    NotFound(String),
    #[error("{name} exited with status {code}")]
    Exited { name: String, code: i32 },
    #[error("failed to stop {name}: {reason}")]
    Stop { name: String, reason: String },
}

/// Manages a child process (ptp4l or phc2sys) with log forwarding
/// and graceful shutdown.
pub struct SyncProcess {
    child: Child,
    name: String,
}

impl SyncProcess {
    /// Spawn a process with stdout/stderr forwarded to tracing.
    fn spawn(bin: &str, args: &[String], name: &str) -> Result<Self, SyncError> {
        tracing::info!(bin, ?args, "starting {}", name);

        let mut child = Command::new(bin)
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::NotFound {
                    SyncError::NotFound(bin.to_string())
                } else {
                    SyncError::Start {
                        name: name.to_string(),
                        source: e,
                    }
                }
            })?;

        let log_name = name.to_string();
        if let Some(stdout) = child.stdout.take() {
            let n = log_name.clone();
            thread::spawn(move || {
                let reader = BufReader::new(stdout);
                for line in reader.lines() {
                    match line {
                        Ok(line) => tracing::info!(target: "linuxptp", proc = %n, "{}", line),
                        Err(_) => break,
                    }
                }
            });
        }

        if let Some(stderr) = child.stderr.take() {
            let n = log_name.clone();
            thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    match line {
                        Ok(line) => tracing::warn!(target: "linuxptp", proc = %n, "{}", line),
                        Err(_) => break,
                    }
                }
            });
        }

        tracing::info!(pid = child.id(), "started {}", name);
        Ok(Self {
            child,
            name: name.to_string(),
        })
    }

    pub fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    pub fn stop(&mut self) -> Result<(), SyncError> {
        let pid = self.child.id();
        tracing::info!(pid, "stopping {}", self.name);

        #[cfg(unix)]
        unsafe {
            libc::kill(pid as i32, libc::SIGTERM);
        }

        for _ in 0..50 {
            if let Ok(Some(_)) = self.child.try_wait() {
                tracing::info!(pid, "{} stopped gracefully", self.name);
                return Ok(());
            }
            thread::sleep(std::time::Duration::from_millis(100));
        }

        tracing::warn!(pid, "{} did not stop gracefully, sending SIGKILL", self.name);
        self.child.kill().map_err(|e| SyncError::Stop {
            name: self.name.clone(),
            reason: e.to_string(),
        })?;
        self.child.wait().map_err(|e| SyncError::Stop {
            name: self.name.clone(),
            reason: e.to_string(),
        })?;

        tracing::info!(pid, "{} killed", self.name);
        Ok(())
    }
}

impl Drop for SyncProcess {
    fn drop(&mut self) {
        if self.is_running() {
            let _ = self.stop();
        }
    }
}

// ── phc2sys: Phase 1 local PHC-to-PHC sync ──

/// Start a phc2sys process that syncs a secondary clock to the primary.
///
/// `phc2sys -s /dev/ptp0 -c /dev/ptp1 -R 10 -O 0 -m`
///   -s: source (master) clock
///   -c: client (slave) clock
///   -R 10: update rate 10 Hz
///   -O 0: no TAI-UTC offset (both are raw TSF)
///   -m: print messages to stdout
pub fn start_phc2sys(
    primary_clock: &Path,
    secondary_clock: &Path,
    phc2sys_bin: &str,
) -> Result<SyncProcess, SyncError> {
    let args = vec![
        "-s".to_string(),
        primary_clock.display().to_string(),
        "-c".to_string(),
        secondary_clock.display().to_string(),
        "-R".to_string(),
        "10".to_string(),
        "-O".to_string(),
        "0".to_string(),
        "-m".to_string(),
    ];

    let name = format!(
        "phc2sys[{}→{}]",
        primary_clock.display(),
        secondary_clock.display()
    );

    SyncProcess::spawn(phc2sys_bin, &args, &name)
}

// ── ptp4l: Phase 2 multi-host sync ──

/// Start ptp4l with a config file (for Phase 2 multi-host sync).
pub fn start_ptp4l(config_path: &Path, ptp4l_bin: &str) -> Result<SyncProcess, SyncError> {
    let args = vec![
        "-f".to_string(),
        config_path.display().to_string(),
        "-m".to_string(),
    ];

    SyncProcess::spawn(ptp4l_bin, &args, "ptp4l")
}

/// Derive the phc2sys binary path from the ptp4l path.
/// They're always in the same directory (both from linuxptp).
pub fn phc2sys_bin_from(linuxptp_bin: &str) -> PathBuf {
    let p = Path::new(linuxptp_bin);
    if let Some(dir) = p.parent() {
        if dir.as_os_str().is_empty() {
            // bare command name like "ptp4l" → "phc2sys"
            PathBuf::from("phc2sys")
        } else {
            dir.join("phc2sys")
        }
    } else {
        PathBuf::from("phc2sys")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_phc2sys_bin_from_full_path() {
        let p = phc2sys_bin_from("/nix/store/abc-linuxptp-4.4/bin/ptp4l");
        assert_eq!(
            p,
            PathBuf::from("/nix/store/abc-linuxptp-4.4/bin/phc2sys")
        );
    }

    #[test]
    fn test_phc2sys_bin_from_bare_name() {
        let p = phc2sys_bin_from("ptp4l");
        assert_eq!(p, PathBuf::from("phc2sys"));
    }
}
