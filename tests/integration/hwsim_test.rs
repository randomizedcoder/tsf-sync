// Integration test: full stack with mac80211_hwsim
//
// This test requires:
//   - Root access
//   - mac80211_hwsim kernel module available
//   - tsf-ptp kernel module built and loadable
//   - linuxptp installed (ptp4l, phc_ctl, pmc)
//
// Run with: cargo test --test hwsim_test -- --ignored

use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;

use tsf_sync::config_gen;
use tsf_sync::discovery::{self, PtpSource};
use tsf_sync::module_loader;

const SYSFS_IEEE80211: &str = "/sys/class/ieee80211";

/// Helper: load mac80211_hwsim with N radios.
fn load_hwsim(radios: u32) {
    let _ = Command::new("rmmod")
        .arg("mac80211_hwsim")
        .output();

    let status = Command::new("modprobe")
        .args(["mac80211_hwsim", &format!("radios={}", radios)])
        .status()
        .expect("failed to run modprobe");
    assert!(status.success(), "failed to load mac80211_hwsim");

    // Give the kernel a moment to create sysfs entries.
    thread::sleep(Duration::from_millis(500));
}

/// Helper: unload mac80211_hwsim.
fn unload_hwsim() {
    let _ = Command::new("rmmod").arg("mac80211_hwsim").output();
}

/// Helper: count PTP device files.
fn count_ptp_devices() -> usize {
    std::fs::read_dir("/dev")
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with("ptp")
        })
        .count()
}

#[test]
#[ignore = "requires root and mac80211_hwsim"]
fn test_hwsim_discovery() {
    load_hwsim(4);

    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211)).unwrap();

    // Filter to hwsim cards only (there might be real cards too).
    let hwsim_cards: Vec<_> = cards
        .iter()
        .filter(|c| c.driver == "mac80211_hwsim")
        .collect();

    assert!(
        hwsim_cards.len() >= 4,
        "expected at least 4 hwsim cards, found {}",
        hwsim_cards.len()
    );

    // All hwsim cards should have no native PTP.
    for card in &hwsim_cards {
        assert_eq!(card.ptp_source, PtpSource::None,
                   "{} should not have native PTP", card.phy);
        assert!(card.can_set_tsf,
                "{} should support set_tsf", card.phy);
    }

    unload_hwsim();
}

#[test]
#[ignore = "requires root, mac80211_hwsim, and tsf-ptp module"]
fn test_hwsim_ptp_clocks_registered() {
    load_hwsim(4);

    let before = count_ptp_devices();

    // Load tsf-ptp.
    module_loader::load_tsf_ptp().expect("failed to load tsf-ptp");
    thread::sleep(Duration::from_millis(500));

    let after = count_ptp_devices();
    let new_clocks = after - before;

    assert!(
        new_clocks >= 4,
        "expected at least 4 new PTP clocks, got {}",
        new_clocks
    );

    // Re-discover — cards should now have PTP clocks.
    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211)).unwrap();
    let with_ptp: Vec<_> = cards
        .iter()
        .filter(|c| c.driver == "mac80211_hwsim" && c.ptp_clock.is_some())
        .collect();

    assert!(
        with_ptp.len() >= 4,
        "expected 4 hwsim cards with PTP, found {}",
        with_ptp.len()
    );

    module_loader::unload_tsf_ptp().expect("failed to unload tsf-ptp");
    unload_hwsim();
}

#[test]
#[ignore = "requires root, mac80211_hwsim, and tsf-ptp module"]
fn test_hwsim_ptp_clock_readwrite() {
    load_hwsim(2);
    module_loader::load_tsf_ptp().expect("failed to load tsf-ptp");
    thread::sleep(Duration::from_millis(500));

    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211)).unwrap();
    let ptp_card = cards
        .iter()
        .find(|c| c.driver == "mac80211_hwsim" && c.ptp_clock.is_some())
        .expect("no hwsim card with PTP clock");

    let ptp_dev = ptp_card.ptp_clock.as_ref().unwrap();

    // Use phc_ctl to read time.
    let output = Command::new("phc_ctl")
        .args([&ptp_dev.display().to_string(), "--", "get"])
        .output()
        .expect("failed to run phc_ctl");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("clock time"),
        "phc_ctl get failed: {}",
        stdout
    );

    // Set a known time and read back.
    let _ = Command::new("phc_ctl")
        .args([&ptp_dev.display().to_string(), "--", "set", "500"])
        .output()
        .expect("failed to run phc_ctl set");

    let output = Command::new("phc_ctl")
        .args([&ptp_dev.display().to_string(), "--", "get"])
        .output()
        .expect("failed to run phc_ctl get");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("clock time"),
        "phc_ctl get after set failed: {}",
        stdout
    );

    module_loader::unload_tsf_ptp().expect("failed to unload tsf-ptp");
    unload_hwsim();
}

#[test]
#[ignore = "requires root, mac80211_hwsim, tsf-ptp, and ptp4l"]
fn test_hwsim_ptp4l_convergence() {
    load_hwsim(4);
    module_loader::load_tsf_ptp().expect("failed to load tsf-ptp");
    thread::sleep(Duration::from_millis(500));

    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211)).unwrap();
    let config = config_gen::generate_config(&cards, "auto")
        .expect("failed to generate config");

    let config_path = "/tmp/tsf-sync-test-ptp4l.conf";
    std::fs::write(config_path, &config).unwrap();

    // Start ptp4l.
    let mut child = Command::new("ptp4l")
        .args(["-f", config_path])
        .spawn()
        .expect("failed to start ptp4l");

    // Let it run for 5 seconds.
    thread::sleep(Duration::from_secs(5));

    // Verify it's still running.
    match child.try_wait() {
        Ok(None) => { /* still running — good */ }
        Ok(Some(status)) => {
            panic!("ptp4l exited prematurely with status: {}", status);
        }
        Err(e) => {
            panic!("error checking ptp4l status: {}", e);
        }
    }

    // Kill ptp4l.
    let _ = child.kill();
    let _ = child.wait();

    let _ = std::fs::remove_file(config_path);
    module_loader::unload_tsf_ptp().expect("failed to unload tsf-ptp");
    unload_hwsim();
}

#[test]
#[ignore = "requires root, mac80211_hwsim, and tsf-ptp module"]
fn test_hwsim_many_radios() {
    load_hwsim(100);
    module_loader::load_tsf_ptp().expect("failed to load tsf-ptp");
    thread::sleep(Duration::from_secs(2));

    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211)).unwrap();
    let hwsim_ptp: Vec<_> = cards
        .iter()
        .filter(|c| c.driver == "mac80211_hwsim" && c.ptp_clock.is_some())
        .collect();

    assert!(
        hwsim_ptp.len() >= 100,
        "expected 100 PTP clocks, found {}",
        hwsim_ptp.len()
    );

    module_loader::unload_tsf_ptp().expect("failed to unload tsf-ptp");
    unload_hwsim();
}

#[test]
#[ignore = "requires root and mac80211_hwsim"]
fn test_hwsim_config_generation() {
    load_hwsim(4);
    module_loader::load_tsf_ptp().expect("failed to load tsf-ptp");
    thread::sleep(Duration::from_millis(500));

    let cards = discovery::discover_cards(Path::new(SYSFS_IEEE80211)).unwrap();
    let config = config_gen::generate_config(&cards, "auto")
        .expect("failed to generate config");

    // Verify config structure.
    assert!(config.contains("[global]"));
    assert!(config.contains("masterOnly"));
    assert!(config.contains("slaveOnly"));
    assert!(config.contains("domainNumber"));

    // Count sections — should have at least 1 master + 3 slaves.
    let master_count = config.matches("masterOnly").count();
    let slave_count = config.matches("slaveOnly").count();
    assert_eq!(master_count, 1, "should have exactly 1 master");
    assert!(slave_count >= 3, "should have at least 3 slaves, got {}", slave_count);

    module_loader::unload_tsf_ptp().expect("failed to unload tsf-ptp");
    unload_hwsim();
}
