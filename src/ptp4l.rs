use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::thread;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Ptp4lError {
    #[error("failed to start ptp4l: {0}")]
    Start(std::io::Error),
    #[error("ptp4l not found — is linuxptp installed?")]
    NotFound,
    #[error("ptp4l exited with status {0}")]
    Exited(i32),
    #[error("failed to stop ptp4l: {0}")]
    Stop(String),
}

/// Manages a ptp4l child process.
pub struct Ptp4lProcess {
    child: Child,
}

impl Ptp4lProcess {
    /// Start ptp4l with the given config file.
    pub fn start(config_path: &Path) -> Result<Self, Ptp4lError> {
        let args = build_args(config_path);

        tracing::info!(config = %config_path.display(), "starting ptp4l");

        let mut child = Command::new("ptp4l")
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::NotFound {
                    Ptp4lError::NotFound
                } else {
                    Ptp4lError::Start(e)
                }
            })?;

        // Forward stdout to tracing in a background thread.
        if let Some(stdout) = child.stdout.take() {
            thread::spawn(move || {
                let reader = BufReader::new(stdout);
                for line in reader.lines() {
                    match line {
                        Ok(line) => tracing::info!(target: "ptp4l", "{}", line),
                        Err(_) => break,
                    }
                }
            });
        }

        // Forward stderr to tracing in a background thread.
        if let Some(stderr) = child.stderr.take() {
            thread::spawn(move || {
                let reader = BufReader::new(stderr);
                for line in reader.lines() {
                    match line {
                        Ok(line) => tracing::warn!(target: "ptp4l", "{}", line),
                        Err(_) => break,
                    }
                }
            });
        }

        tracing::info!(pid = child.id(), "ptp4l started");
        Ok(Self { child })
    }

    /// Check if ptp4l is still running.
    pub fn is_running(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// Stop ptp4l gracefully (SIGTERM), then force kill after timeout.
    pub fn stop(&mut self) -> Result<(), Ptp4lError> {
        let pid = self.child.id();
        tracing::info!(pid, "stopping ptp4l");

        // Send SIGTERM.
        #[cfg(unix)]
        {
            unsafe {
                libc::kill(pid as i32, libc::SIGTERM);
            }
        }

        // Wait up to 5 seconds for graceful shutdown.
        for _ in 0..50 {
            if let Ok(Some(_)) = self.child.try_wait() {
                tracing::info!(pid, "ptp4l stopped gracefully");
                return Ok(());
            }
            thread::sleep(std::time::Duration::from_millis(100));
        }

        // Force kill.
        tracing::warn!(pid, "ptp4l did not stop gracefully, sending SIGKILL");
        self.child
            .kill()
            .map_err(|e| Ptp4lError::Stop(e.to_string()))?;
        self.child
            .wait()
            .map_err(|e| Ptp4lError::Stop(e.to_string()))?;

        tracing::info!(pid, "ptp4l killed");
        Ok(())
    }

    /// Wait for ptp4l to exit and return its exit code.
    pub fn wait(&mut self) -> Result<i32, Ptp4lError> {
        let status = self
            .child
            .wait()
            .map_err(|e| Ptp4lError::Stop(e.to_string()))?;
        Ok(status.code().unwrap_or(-1))
    }
}

impl Drop for Ptp4lProcess {
    fn drop(&mut self) {
        if self.is_running() {
            let _ = self.stop();
        }
    }
}

/// Build the ptp4l command-line arguments.
fn build_args(config_path: &Path) -> Vec<String> {
    vec!["-f".to_string(), config_path.display().to_string()]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn test_build_args() {
        let config = PathBuf::from("/tmp/ptp4l.conf");
        let args = build_args(&config);
        assert_eq!(args, vec!["-f", "/tmp/ptp4l.conf"]);
    }

    #[test]
    fn test_build_args_complex_path() {
        let config = PathBuf::from("/run/tsf-sync/ptp4l-domain42.conf");
        let args = build_args(&config);
        assert_eq!(args, vec!["-f", "/run/tsf-sync/ptp4l-domain42.conf"]);
    }
}
