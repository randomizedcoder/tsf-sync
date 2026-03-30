use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

use tempfile::TempDir;
use tsf_sync::discovery::{self, PtpSource};

/// Helper to create a mock sysfs phy directory.
fn create_mock_phy(root: &Path, phy_name: &str, driver_name: &str, ptp_clock: Option<&str>) {
    let phy_dir = root.join(phy_name);
    let device_dir = phy_dir.join("device");
    fs::create_dir_all(&device_dir).unwrap();

    // Create driver symlink.
    let driver_target = root.join("_drivers").join(driver_name);
    fs::create_dir_all(&driver_target).unwrap();
    let driver_link = device_dir.join("driver");
    if !driver_link.exists() {
        symlink(&driver_target, &driver_link).unwrap();
    }

    // Create PTP clock entry if specified.
    // In real sysfs, PTP clocks appear as direct children of the
    // device (e.g., device/ptp0), not in a ptp/ subdirectory.
    if let Some(ptp) = ptp_clock {
        let ptp_dir = device_dir.join(ptp);
        fs::create_dir_all(&ptp_dir).unwrap();
    }
}

#[test]
fn test_intel_native_ptp() {
    let tmp = TempDir::new().unwrap();
    create_mock_phy(tmp.path(), "phy0", "iwlwifi", Some("ptp0"));

    let cards = discovery::discover_cards(tmp.path()).unwrap();
    assert_eq!(cards.len(), 1);
    assert_eq!(cards[0].phy, "phy0");
    assert_eq!(cards[0].driver, "iwlwifi");
    assert_eq!(cards[0].ptp_source, PtpSource::Native);
    assert_eq!(cards[0].ptp_clock, Some(PathBuf::from("/dev/ptp0")));
}

#[test]
fn test_mediatek_needs_module() {
    let tmp = TempDir::new().unwrap();
    create_mock_phy(tmp.path(), "phy0", "mt76", None);

    let cards = discovery::discover_cards(tmp.path()).unwrap();
    assert_eq!(cards.len(), 1);
    assert_eq!(cards[0].ptp_source, PtpSource::None);
    assert!(cards[0].ptp_clock.is_none());
    assert!(cards[0].can_set_tsf);
}

#[test]
fn test_fullmac_unsupported() {
    let tmp = TempDir::new().unwrap();
    create_mock_phy(tmp.path(), "phy0", "brcmfmac", None);

    let cards = discovery::discover_cards(tmp.path()).unwrap();
    assert_eq!(cards.len(), 1);
    assert!(!cards[0].can_set_tsf);

    let table = discovery::format_table(&cards);
    assert!(table.contains("unsupported (FullMAC)"));
}

#[test]
fn test_missing_driver_symlink() {
    let tmp = TempDir::new().unwrap();
    // Create phy dir without a driver symlink.
    fs::create_dir_all(tmp.path().join("phy0/device")).unwrap();

    let cards = discovery::discover_cards(tmp.path()).unwrap();
    assert_eq!(cards.len(), 1);
    assert_eq!(cards[0].driver, "unknown");
}

#[test]
fn test_ptp_clock_index_mapping() {
    let tmp = TempDir::new().unwrap();
    create_mock_phy(tmp.path(), "phy0", "iwlwifi", Some("ptp3"));

    let cards = discovery::discover_cards(tmp.path()).unwrap();
    assert_eq!(cards[0].ptp_clock, Some(PathBuf::from("/dev/ptp3")));
}

#[test]
fn test_mixed_topology() {
    let tmp = TempDir::new().unwrap();
    create_mock_phy(tmp.path(), "phy0", "iwlwifi", Some("ptp0"));
    create_mock_phy(tmp.path(), "phy1", "mt76", Some("ptp1"));
    create_mock_phy(tmp.path(), "phy2", "mt76", None);
    create_mock_phy(tmp.path(), "phy3", "brcmfmac", None);

    let cards = discovery::discover_cards(tmp.path()).unwrap();
    assert_eq!(cards.len(), 4);

    // Intel: native PTP.
    let c0 = cards.iter().find(|c| c.phy == "phy0").unwrap();
    assert_eq!(c0.ptp_source, PtpSource::Native);

    // MediaTek with tsf-ptp loaded.
    let c1 = cards.iter().find(|c| c.phy == "phy1").unwrap();
    assert_eq!(c1.ptp_source, PtpSource::TsfPtp);

    // MediaTek without module.
    let c2 = cards.iter().find(|c| c.phy == "phy2").unwrap();
    assert_eq!(c2.ptp_source, PtpSource::None);

    // FullMAC — unsupported.
    let c3 = cards.iter().find(|c| c.phy == "phy3").unwrap();
    assert!(!c3.can_set_tsf);
}

#[test]
fn test_many_radios() {
    let tmp = TempDir::new().unwrap();
    for i in 0..20 {
        create_mock_phy(
            tmp.path(),
            &format!("phy{}", i),
            "mt76",
            Some(&format!("ptp{}", i)),
        );
    }

    let cards = discovery::discover_cards(tmp.path()).unwrap();
    assert_eq!(cards.len(), 20);

    // Verify sorted order.
    for (i, card) in cards.iter().enumerate() {
        assert_eq!(card.phy, format!("phy{}", i));
    }
}
