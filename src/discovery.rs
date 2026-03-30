use std::fs;
use std::path::{Path, PathBuf};

use thiserror::Error;

#[derive(Debug, Error)]
pub enum DiscoveryError {
    #[error("failed to read sysfs: {0}")]
    Sysfs(#[from] std::io::Error),
}

/// How this card's PTP clock is provided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PtpSource {
    /// Driver registers its own PTP clock (e.g., iwlwifi).
    Native,
    /// PTP clock provided by the tsf-ptp kernel module.
    TsfPtp,
    /// No PTP clock available.
    None,
}

/// A discovered WiFi card.
#[derive(Debug, Clone)]
pub struct WifiCard {
    /// PHY name (e.g., "phy0").
    pub phy: String,
    /// Driver name (e.g., "iwlwifi", "mt76", "mac80211_hwsim").
    pub driver: String,
    /// PTP clock device path (e.g., "/dev/ptp0"), if available.
    pub ptp_clock: Option<PathBuf>,
    /// How the PTP clock is sourced.
    pub ptp_source: PtpSource,
    /// Whether the driver supports set_tsf (writable TSF).
    pub can_set_tsf: bool,
}

/// Drivers known to have native PTP clock support.
const NATIVE_PTP_DRIVERS: &[&str] = &["iwlwifi"];

/// FullMAC drivers that don't expose TSF at all.
const FULLMAC_DRIVERS: &[&str] = &["brcmfmac", "mwifiex", "ath6kl"];

/// Drivers that have get_tsf but NOT set_tsf (read-only).
const READ_ONLY_DRIVERS: &[&str] = &["rtl8xxxu", "wil6210"];

/// Discover WiFi cards by walking a sysfs-like directory.
///
/// `sysfs_root` is the path to the ieee80211 class directory,
/// typically `/sys/class/ieee80211`.
pub fn discover_cards(sysfs_root: &Path) -> Result<Vec<WifiCard>, DiscoveryError> {
    let mut cards = Vec::new();

    let entries = match fs::read_dir(sysfs_root) {
        Ok(e) => e,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(cards),
        Err(e) => return Err(e.into()),
    };

    for entry in entries {
        let entry = entry?;
        let phy_name = entry.file_name().to_string_lossy().to_string();

        // Only process phyN directories.
        if !phy_name.starts_with("phy") {
            continue;
        }

        let phy_path = entry.path();
        let driver = read_driver(&phy_path);

        let (ptp_clock, ptp_source) = find_ptp_clock(&phy_path, &driver);

        let can_set_tsf = !FULLMAC_DRIVERS.contains(&driver.as_str())
            && !READ_ONLY_DRIVERS.contains(&driver.as_str());

        cards.push(WifiCard {
            phy: phy_name,
            driver,
            ptp_clock,
            ptp_source,
            can_set_tsf,
        });
    }

    // Sort by phy name for deterministic output.
    cards.sort_by(|a, b| natural_sort_key(&a.phy).cmp(&natural_sort_key(&b.phy)));

    Ok(cards)
}

/// Read the driver name from the device/driver symlink.
fn read_driver(phy_path: &Path) -> String {
    let driver_link = phy_path.join("device/driver");
    match fs::read_link(&driver_link) {
        Ok(target) => target
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "unknown".to_string()),
        Err(_) => "unknown".to_string(),
    }
}

/// Find PTP clock for a phy. Checks device/ptp/ for native clocks,
/// then falls back to checking if the driver is known to have native PTP.
fn find_ptp_clock(phy_path: &Path, driver: &str) -> (Option<PathBuf>, PtpSource) {
    let ptp_dir = phy_path.join("device/ptp");

    if let Ok(entries) = fs::read_dir(&ptp_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("ptp") {
                let dev_path = PathBuf::from(format!("/dev/{}", name));
                let source = if NATIVE_PTP_DRIVERS.contains(&driver) {
                    PtpSource::Native
                } else {
                    PtpSource::TsfPtp
                };
                return (Some(dev_path), source);
            }
        }
    }

    // No PTP clock found.
    if FULLMAC_DRIVERS.contains(&driver) {
        (None, PtpSource::None)
    } else {
        (None, PtpSource::None)
    }
}

/// Format discovered cards as a table for display.
pub fn format_table(cards: &[WifiCard]) -> String {
    let mut out = String::new();
    out.push_str(&format!(
        "{:<10} {:<18} {:<14} {}\n",
        "PHY", "DRIVER", "PTP CLOCK", "STATUS"
    ));

    for card in cards {
        let ptp_str = card
            .ptp_clock
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "—".to_string());

        let status = match &card.ptp_source {
            PtpSource::Native => "native PTP".to_string(),
            PtpSource::TsfPtp => "tsf-ptp module".to_string(),
            PtpSource::None => {
                if FULLMAC_DRIVERS.contains(&card.driver.as_str()) {
                    "unsupported (FullMAC)".to_string()
                } else if !card.can_set_tsf {
                    "read-only TSF".to_string()
                } else {
                    "needs tsf-ptp module".to_string()
                }
            }
        };

        out.push_str(&format!(
            "{:<10} {:<18} {:<14} {}\n",
            card.phy, card.driver, ptp_str, status
        ));
    }

    out
}

/// Natural sort key: split "phy12" into ("phy", 12) for proper ordering.
fn natural_sort_key(s: &str) -> (String, u64) {
    let prefix: String = s.chars().take_while(|c| !c.is_ascii_digit()).collect();
    let num: u64 = s
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .unwrap_or(0);
    (prefix, num)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::TempDir;

    /// Helper to create a mock sysfs phy directory.
    fn create_mock_phy(
        root: &Path,
        phy_name: &str,
        driver_name: &str,
        ptp_clock: Option<&str>,
    ) {
        let phy_dir = root.join(phy_name);
        let device_dir = phy_dir.join("device");
        fs::create_dir_all(&device_dir).unwrap();

        // Create driver symlink: device/driver -> .../drivers/<driver_name>
        let driver_target = root.join("_drivers").join(driver_name);
        fs::create_dir_all(&driver_target).unwrap();
        symlink(&driver_target, device_dir.join("driver")).unwrap();

        // Create PTP clock if specified.
        if let Some(ptp) = ptp_clock {
            let ptp_dir = device_dir.join("ptp").join(ptp);
            fs::create_dir_all(&ptp_dir).unwrap();
        }
    }

    #[test]
    fn test_discover_intel_native_ptp() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        create_mock_phy(root, "phy0", "iwlwifi", Some("ptp0"));

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].phy, "phy0");
        assert_eq!(cards[0].driver, "iwlwifi");
        assert_eq!(cards[0].ptp_source, PtpSource::Native);
        assert_eq!(cards[0].ptp_clock, Some(PathBuf::from("/dev/ptp0")));
        assert!(cards[0].can_set_tsf);
    }

    #[test]
    fn test_discover_mediatek_needs_module() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        create_mock_phy(root, "phy1", "mt76", None);

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].driver, "mt76");
        assert_eq!(cards[0].ptp_source, PtpSource::None);
        assert!(cards[0].ptp_clock.is_none());
        assert!(cards[0].can_set_tsf);
    }

    #[test]
    fn test_discover_mediatek_with_tsf_ptp() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        create_mock_phy(root, "phy1", "mt76", Some("ptp1"));

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].ptp_source, PtpSource::TsfPtp);
        assert_eq!(cards[0].ptp_clock, Some(PathBuf::from("/dev/ptp1")));
    }

    #[test]
    fn test_discover_fullmac_unsupported() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        create_mock_phy(root, "phy3", "brcmfmac", None);

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].ptp_source, PtpSource::None);
        assert!(!cards[0].can_set_tsf);
    }

    #[test]
    fn test_discover_missing_driver_symlink() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        // Create phy dir without a driver symlink.
        fs::create_dir_all(root.join("phy0/device")).unwrap();

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].driver, "unknown");
    }

    #[test]
    fn test_discover_read_only_driver() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        create_mock_phy(root, "phy0", "rtl8xxxu", None);

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards.len(), 1);
        assert!(!cards[0].can_set_tsf);
    }

    #[test]
    fn test_discover_empty_sysfs() {
        let tmp = TempDir::new().unwrap();
        let cards = discover_cards(tmp.path()).unwrap();
        assert!(cards.is_empty());
    }

    #[test]
    fn test_discover_nonexistent_path() {
        let cards = discover_cards(Path::new("/nonexistent/path")).unwrap();
        assert!(cards.is_empty());
    }

    #[test]
    fn test_discover_sorted_output() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        create_mock_phy(root, "phy10", "mt76", None);
        create_mock_phy(root, "phy2", "mt76", None);
        create_mock_phy(root, "phy0", "iwlwifi", Some("ptp0"));

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards[0].phy, "phy0");
        assert_eq!(cards[1].phy, "phy2");
        assert_eq!(cards[2].phy, "phy10");
    }

    #[test]
    fn test_format_table() {
        let cards = vec![
            WifiCard {
                phy: "phy0".to_string(),
                driver: "iwlwifi".to_string(),
                ptp_clock: Some(PathBuf::from("/dev/ptp0")),
                ptp_source: PtpSource::Native,
                can_set_tsf: true,
            },
            WifiCard {
                phy: "phy1".to_string(),
                driver: "mt76".to_string(),
                ptp_clock: None,
                ptp_source: PtpSource::None,
                can_set_tsf: true,
            },
        ];

        let table = format_table(&cards);
        assert!(table.contains("native PTP"));
        assert!(table.contains("needs tsf-ptp module"));
    }

    #[test]
    fn test_mixed_topology() {
        let tmp = TempDir::new().unwrap();
        let root = tmp.path();
        create_mock_phy(root, "phy0", "iwlwifi", Some("ptp0"));
        create_mock_phy(root, "phy1", "mt76", Some("ptp1"));
        create_mock_phy(root, "phy2", "mt76", None);
        create_mock_phy(root, "phy3", "brcmfmac", None);

        let cards = discover_cards(root).unwrap();
        assert_eq!(cards.len(), 4);

        let intel = cards.iter().find(|c| c.driver == "iwlwifi").unwrap();
        assert_eq!(intel.ptp_source, PtpSource::Native);

        let mt_with_ptp = cards.iter().find(|c| c.phy == "phy1").unwrap();
        assert_eq!(mt_with_ptp.ptp_source, PtpSource::TsfPtp);

        let mt_without = cards.iter().find(|c| c.phy == "phy2").unwrap();
        assert_eq!(mt_without.ptp_source, PtpSource::None);

        let fullmac = cards.iter().find(|c| c.driver == "brcmfmac").unwrap();
        assert!(!fullmac.can_set_tsf);
    }
}
