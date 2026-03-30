use std::path::PathBuf;

use tsf_sync::config_gen::{self, ConfigError};
use tsf_sync::discovery::{PtpSource, WifiCard};

fn make_card(phy: &str, driver: &str, ptp: Option<&str>, source: PtpSource) -> WifiCard {
    WifiCard {
        phy: phy.to_string(),
        driver: driver.to_string(),
        ptp_clock: ptp.map(|p| PathBuf::from(p)),
        ptp_source: source,
        can_set_tsf: true,
    }
}

#[test]
fn test_single_primary_n_secondaries() {
    let cards = vec![
        make_card("phy0", "iwlwifi", Some("/dev/ptp0"), PtpSource::Native),
        make_card("phy1", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
        make_card("phy2", "mt76", Some("/dev/ptp2"), PtpSource::TsfPtp),
        make_card("phy3", "ath9k", Some("/dev/ptp3"), PtpSource::TsfPtp),
    ];

    let config = config_gen::generate_config(&cards, "auto").unwrap();

    // Verify structure.
    assert!(config.contains("[global]"));
    assert!(config.contains("clockClass              248"));
    assert!(config.contains("domainNumber            42"));

    // Intel should be auto-selected as primary (serverOnly).
    assert!(config.contains("[/dev/ptp0]\nserverOnly"));

    // All others should be secondaries (no per-port role — ptp4l auto-negotiates).
    assert!(config.contains("[/dev/ptp1]"));
    assert!(config.contains("[/dev/ptp2]"));
    assert!(config.contains("[/dev/ptp3]"));
}

#[test]
fn test_auto_prefers_intel() {
    let cards = vec![
        make_card("phy0", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
        make_card("phy1", "iwlwifi", Some("/dev/ptp0"), PtpSource::Native),
    ];

    let config = config_gen::generate_config(&cards, "auto").unwrap();

    // Intel's PTP clock should be serverOnly.
    let ptp0_pos = config.find("[/dev/ptp0]").unwrap();
    let after_ptp0 = &config[ptp0_pos..];
    assert!(after_ptp0.starts_with("[/dev/ptp0]\nserverOnly"));
}

#[test]
fn test_no_ptp_cards_error() {
    let cards = vec![
        WifiCard {
            phy: "phy0".to_string(),
            driver: "brcmfmac".to_string(),
            ptp_clock: None,
            ptp_source: PtpSource::None,
            can_set_tsf: false,
        },
    ];

    let err = config_gen::generate_config(&cards, "auto").unwrap_err();
    assert!(matches!(err, ConfigError::NoPtpClocks));
}

#[test]
fn test_empty_cards_error() {
    let err = config_gen::generate_config(&[], "auto").unwrap_err();
    assert!(matches!(err, ConfigError::NoPtpClocks));
}

#[test]
fn test_only_one_clock_error() {
    let cards = vec![make_card(
        "phy0",
        "mt76",
        Some("/dev/ptp0"),
        PtpSource::TsfPtp,
    )];

    let err = config_gen::generate_config(&cards, "auto").unwrap_err();
    assert!(matches!(err, ConfigError::OnlyOneClock));
}

#[test]
fn test_explicit_primary_selection() {
    let cards = vec![
        make_card("phy0", "iwlwifi", Some("/dev/ptp0"), PtpSource::Native),
        make_card("phy1", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
    ];

    // Override auto to pick phy1 as primary.
    let config = config_gen::generate_config(&cards, "phy1").unwrap();

    let ptp1_pos = config.find("[/dev/ptp1]").unwrap();
    let after_ptp1 = &config[ptp1_pos..];
    assert!(after_ptp1.starts_with("[/dev/ptp1]\nserverOnly"));
}

#[test]
fn test_primary_not_found_error() {
    let cards = vec![
        make_card("phy0", "mt76", Some("/dev/ptp0"), PtpSource::TsfPtp),
        make_card("phy1", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
    ];

    let err = config_gen::generate_config(&cards, "phy99").unwrap_err();
    assert!(matches!(err, ConfigError::PrimaryNotFound(_)));
}

#[test]
fn test_cards_without_ptp_excluded_from_config() {
    let cards = vec![
        make_card("phy0", "mt76", Some("/dev/ptp0"), PtpSource::TsfPtp),
        WifiCard {
            phy: "phy1".to_string(),
            driver: "brcmfmac".to_string(),
            ptp_clock: None,
            ptp_source: PtpSource::None,
            can_set_tsf: false,
        },
        make_card("phy2", "mt76", Some("/dev/ptp2"), PtpSource::TsfPtp),
    ];

    let config = config_gen::generate_config(&cards, "auto").unwrap();

    // FullMAC card should not appear in config.
    assert!(!config.contains("brcmfmac"));
    assert!(!config.contains("phy1"));
    assert!(config.contains("[/dev/ptp0]"));
    assert!(config.contains("[/dev/ptp2]"));
}

#[test]
fn test_generated_config_has_comments() {
    let cards = vec![
        make_card("phy0", "iwlwifi", Some("/dev/ptp0"), PtpSource::Native),
        make_card("phy1", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
    ];

    let config = config_gen::generate_config(&cards, "auto").unwrap();

    // Config should have comments identifying cards.
    assert!(config.contains("# Primary: phy0 (iwlwifi)"));
    assert!(config.contains("# Secondary: phy1 (mt76)"));
}
