use std::process::Command;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum HealthError {
    #[error("failed to run pmc: {0}")]
    PmcExec(std::io::Error),
    #[error("pmc not found — is linuxptp installed?")]
    PmcNotFound,
    #[error("failed to parse pmc output: {0}")]
    Parse(String),
}

/// Health state for a synchronized card.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthState {
    /// Recently started, offset still large but trending toward zero.
    Converging,
    /// Offset within tolerance, port state is SLAVE or MASTER.
    Healthy,
    /// Offset growing or state flapping.
    Degraded,
    /// Clock disappeared or persistent errors.
    Failed,
    /// Card physically removed.
    Removed,
}

impl std::fmt::Display for HealthState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HealthState::Converging => write!(f, "CONVERGING"),
            HealthState::Healthy => write!(f, "HEALTHY"),
            HealthState::Degraded => write!(f, "DEGRADED"),
            HealthState::Failed => write!(f, "FAILED"),
            HealthState::Removed => write!(f, "REMOVED"),
        }
    }
}

/// Status of a single clock as reported by pmc.
#[derive(Debug, Clone)]
pub struct ClockStatus {
    /// PTP clock identity or port name.
    pub port: String,
    /// Port state (e.g., "MASTER", "SLAVE", "LISTENING").
    pub port_state: String,
    /// Clock offset in nanoseconds (None if not yet measured).
    pub offset_ns: Option<i64>,
    /// Path delay in nanoseconds.
    pub path_delay_ns: Option<i64>,
    /// Computed health state.
    pub health: HealthState,
}

/// Offset threshold for healthy state (1 millisecond in nanoseconds).
const HEALTHY_THRESHOLD_NS: i64 = 1_000_000;

/// Query ptp4l status via pmc and return clock statuses.
///
/// `uds_path` is the path to the ptp4l UDS socket (default: /var/run/ptp4l).
pub fn query_health(uds_path: &str) -> Result<Vec<ClockStatus>, HealthError> {
    let output = Command::new("pmc")
        .args([
            "-u",
            "-b",
            "0",
            "-s",
            uds_path,
            "GET",
            "PORT_DATA_SET",
        ])
        .output()
        .map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                HealthError::PmcNotFound
            } else {
                HealthError::PmcExec(e)
            }
        })?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_port_data_set(&stdout)
}

/// Parse pmc PORT_DATA_SET output into clock statuses.
fn parse_port_data_set(output: &str) -> Result<Vec<ClockStatus>, HealthError> {
    let mut statuses = Vec::new();
    let mut current_port = None;
    let mut current_state = None;

    for line in output.lines() {
        let line = line.trim();

        if line.starts_with("portIdentity") {
            current_port = line.split_whitespace().last().map(String::from);
        } else if line.starts_with("portState") {
            current_state = line.split_whitespace().last().map(String::from);
        }

        // When we have both port and state, emit a status entry.
        if let (Some(port), Some(state)) = (&current_port, &current_state) {
            let health = match state.as_str() {
                "MASTER" => HealthState::Healthy,
                "SLAVE" => HealthState::Healthy,
                "LISTENING" | "UNCALIBRATED" | "PRE_MASTER" => HealthState::Converging,
                "FAULTY" | "DISABLED" => HealthState::Failed,
                _ => HealthState::Converging,
            };

            statuses.push(ClockStatus {
                port: port.clone(),
                port_state: state.clone(),
                offset_ns: None,
                path_delay_ns: None,
                health,
            });

            current_port = None;
            current_state = None;
        }
    }

    Ok(statuses)
}

/// Format health statuses as a table for display.
pub fn format_status_table(statuses: &[ClockStatus]) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "{:<20} {:<14} {:<12} {:<14} {}\n",
        "PORT", "STATE", "HEALTH", "OFFSET", "PATH DELAY"
    ));

    for s in statuses {
        let offset = s
            .offset_ns
            .map(|o| format!("{} ns", o))
            .unwrap_or_else(|| "—".to_string());
        let delay = s
            .path_delay_ns
            .map(|d| format!("{} ns", d))
            .unwrap_or_else(|| "—".to_string());

        out.push_str(&format!(
            "{:<20} {:<14} {:<12} {:<14} {}\n",
            s.port, s.port_state, s.health, offset, delay
        ));
    }

    out
}

/// Determine health from a clock offset value.
pub fn classify_offset(offset_ns: i64) -> HealthState {
    if offset_ns.abs() < HEALTHY_THRESHOLD_NS {
        HealthState::Healthy
    } else {
        HealthState::Converging
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_port_data_set() {
        let output = "\
sending: GET PORT_DATA_SET
    portIdentity            001122.fffe.334455-1
    portState               MASTER
    logMinDelayReqInterval  0
sending: GET PORT_DATA_SET
    portIdentity            001122.fffe.334455-2
    portState               SLAVE
    logMinDelayReqInterval  0
";
        let statuses = parse_port_data_set(output).unwrap();
        assert_eq!(statuses.len(), 2);
        assert_eq!(statuses[0].port_state, "MASTER");
        assert_eq!(statuses[0].health, HealthState::Healthy);
        assert_eq!(statuses[1].port_state, "SLAVE");
        assert_eq!(statuses[1].health, HealthState::Healthy);
    }

    #[test]
    fn test_classify_offset() {
        assert_eq!(classify_offset(500), HealthState::Healthy);
        assert_eq!(classify_offset(-999_999), HealthState::Healthy);
        assert_eq!(classify_offset(1_000_001), HealthState::Converging);
        assert_eq!(classify_offset(-2_000_000), HealthState::Converging);
    }

    #[test]
    fn test_health_state_display() {
        assert_eq!(format!("{}", HealthState::Healthy), "HEALTHY");
        assert_eq!(format!("{}", HealthState::Converging), "CONVERGING");
        assert_eq!(format!("{}", HealthState::Failed), "FAILED");
    }

    #[test]
    fn test_parse_empty_output() {
        let statuses = parse_port_data_set("").unwrap();
        assert!(statuses.is_empty());
    }
}
