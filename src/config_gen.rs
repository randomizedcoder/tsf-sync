use std::fmt::Write;

use thiserror::Error;

use crate::discovery::{PtpSource, WifiCard};

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("no cards with PTP clocks found (load tsf-ptp module first?)")]
    NoPtpClocks,
    #[error("specified primary '{0}' not found among discovered cards")]
    PrimaryNotFound(String),
    #[error("specified primary '{0}' has no PTP clock")]
    PrimaryNoPtp(String),
    #[error("no suitable primary card found (need at least one card with a PTP clock)")]
    NoPrimary,
    #[error("only one PTP clock found — need at least two for synchronization")]
    OnlyOneClock,
}

/// Generate a ptp4l configuration file from discovered cards.
///
/// `primary_selection` is either "auto" or a specific phy name (e.g., "phy0").
pub fn generate_config(
    cards: &[WifiCard],
    primary_selection: &str,
) -> Result<String, ConfigError> {
    // Filter to cards with PTP clocks.
    let ptp_cards: Vec<&WifiCard> = cards.iter().filter(|c| c.ptp_clock.is_some()).collect();

    if ptp_cards.is_empty() {
        return Err(ConfigError::NoPtpClocks);
    }

    if ptp_cards.len() < 2 {
        return Err(ConfigError::OnlyOneClock);
    }

    let primary = select_primary(&ptp_cards, primary_selection)?;

    let mut config = String::new();

    // Global section.
    writeln!(config, "[global]").unwrap();
    writeln!(config, "clockClass              248").unwrap();
    writeln!(config, "priority1               128").unwrap();
    writeln!(config, "priority2               128").unwrap();
    writeln!(config, "domainNumber            42").unwrap();
    writeln!(config, "slaveOnly               0").unwrap();
    writeln!(config).unwrap();

    // Primary card — grandmaster.
    let ptp_path = primary.ptp_clock.as_ref().unwrap();
    writeln!(config, "# Primary: {} ({})", primary.phy, primary.driver).unwrap();
    writeln!(config, "[{}]", ptp_path.display()).unwrap();
    writeln!(config, "masterOnly              1").unwrap();

    // Secondary cards — slaves.
    for card in &ptp_cards {
        if card.phy == primary.phy {
            continue;
        }
        let ptp_path = card.ptp_clock.as_ref().unwrap();
        writeln!(config).unwrap();
        writeln!(config, "# Secondary: {} ({})", card.phy, card.driver).unwrap();
        writeln!(config, "[{}]", ptp_path.display()).unwrap();
        writeln!(config, "slaveOnly               1").unwrap();
    }

    Ok(config)
}

/// Select the primary card based on user preference or auto-selection.
fn select_primary<'a>(
    ptp_cards: &[&'a WifiCard],
    selection: &str,
) -> Result<&'a WifiCard, ConfigError> {
    if selection != "auto" {
        // User specified a phy name.
        let card = ptp_cards
            .iter()
            .find(|c| c.phy == selection)
            .ok_or_else(|| {
                // Check if the phy exists at all (just without PTP).
                ConfigError::PrimaryNotFound(selection.to_string())
            })?;
        if card.ptp_clock.is_none() {
            return Err(ConfigError::PrimaryNoPtp(selection.to_string()));
        }
        return Ok(card);
    }

    // Auto-selection priority:
    // 1. Native PTP (Intel) — best clock quality.
    // 2. First available card with PTP clock.
    if let Some(card) = ptp_cards.iter().find(|c| c.ptp_source == PtpSource::Native) {
        return Ok(card);
    }

    ptp_cards.first().copied().ok_or(ConfigError::NoPrimary)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

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
    fn test_generate_config_basic() {
        let cards = vec![
            make_card("phy0", "iwlwifi", Some("/dev/ptp0"), PtpSource::Native),
            make_card("phy1", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
            make_card("phy2", "mt76", Some("/dev/ptp2"), PtpSource::TsfPtp),
        ];

        let config = generate_config(&cards, "auto").unwrap();

        assert!(config.contains("[global]"));
        assert!(config.contains("clockClass              248"));
        assert!(config.contains("domainNumber            42"));
        assert!(config.contains("[/dev/ptp0]"));
        assert!(config.contains("masterOnly              1"));
        assert!(config.contains("[/dev/ptp1]"));
        assert!(config.contains("[/dev/ptp2]"));
        assert!(config.contains("slaveOnly               1"));
    }

    #[test]
    fn test_auto_prefers_intel() {
        let cards = vec![
            make_card("phy0", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
            make_card("phy1", "iwlwifi", Some("/dev/ptp0"), PtpSource::Native),
        ];

        let config = generate_config(&cards, "auto").unwrap();

        // Intel (ptp0) should be primary (masterOnly), mt76 (ptp1) should be slave.
        let master_pos = config.find("[/dev/ptp0]").unwrap();
        let master_only_pos = config[master_pos..].find("masterOnly").unwrap();
        assert!(master_only_pos < 50); // masterOnly should be right after the section header
    }

    #[test]
    fn test_explicit_primary() {
        let cards = vec![
            make_card("phy0", "iwlwifi", Some("/dev/ptp0"), PtpSource::Native),
            make_card("phy1", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
        ];

        let config = generate_config(&cards, "phy1").unwrap();

        // phy1 should be primary.
        let master_pos = config.find("[/dev/ptp1]").unwrap();
        let master_only_pos = config[master_pos..].find("masterOnly").unwrap();
        assert!(master_only_pos < 50);
    }

    #[test]
    fn test_no_ptp_clocks_error() {
        let cards = vec![make_card("phy0", "brcmfmac", None, PtpSource::None)];

        let err = generate_config(&cards, "auto").unwrap_err();
        assert!(matches!(err, ConfigError::NoPtpClocks));
    }

    #[test]
    fn test_only_one_clock_error() {
        let cards = vec![make_card(
            "phy0",
            "iwlwifi",
            Some("/dev/ptp0"),
            PtpSource::Native,
        )];

        let err = generate_config(&cards, "auto").unwrap_err();
        assert!(matches!(err, ConfigError::OnlyOneClock));
    }

    #[test]
    fn test_primary_not_found() {
        let cards = vec![
            make_card("phy0", "mt76", Some("/dev/ptp0"), PtpSource::TsfPtp),
            make_card("phy1", "mt76", Some("/dev/ptp1"), PtpSource::TsfPtp),
        ];

        let err = generate_config(&cards, "phy99").unwrap_err();
        assert!(matches!(err, ConfigError::PrimaryNotFound(_)));
    }

    #[test]
    fn test_auto_without_intel() {
        let cards = vec![
            make_card("phy0", "mt76", Some("/dev/ptp0"), PtpSource::TsfPtp),
            make_card("phy1", "ath9k", Some("/dev/ptp1"), PtpSource::TsfPtp),
        ];

        // Should pick first available (phy0).
        let config = generate_config(&cards, "auto").unwrap();
        let master_pos = config.find("[/dev/ptp0]").unwrap();
        let master_only = config[master_pos..].find("masterOnly").unwrap();
        assert!(master_only < 50);
    }

    #[test]
    fn test_cards_without_ptp_excluded() {
        let cards = vec![
            make_card("phy0", "mt76", Some("/dev/ptp0"), PtpSource::TsfPtp),
            make_card("phy1", "brcmfmac", None, PtpSource::None),
            make_card("phy2", "mt76", Some("/dev/ptp2"), PtpSource::TsfPtp),
        ];

        let config = generate_config(&cards, "auto").unwrap();

        // brcmfmac should not appear in config.
        assert!(!config.contains("brcmfmac"));
        assert!(config.contains("[/dev/ptp0]"));
        assert!(config.contains("[/dev/ptp2]"));
    }
}
