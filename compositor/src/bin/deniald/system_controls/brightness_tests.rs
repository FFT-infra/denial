use super::*;
use std::os::unix::fs::symlink;
use std::sync::atomic::AtomicUsize;

static NEXT_FIXTURE: AtomicUsize = AtomicUsize::new(0);

struct SysfsFixture(PathBuf);

impl SysfsFixture {
    fn new() -> Self {
        let sequence = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let root = std::env::temp_dir().join(format!(
            "denial-brightness-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&root).unwrap();
        for directory in ["drm", "backlight", "devices"] {
            fs::create_dir(root.join(directory)).unwrap();
        }
        Self(root)
    }

    fn connector(&self, name: &str, status: &str, device: &str, modern: bool) -> PathBuf {
        let path = self.0.join("drm").join(name);
        fs::create_dir(&path).unwrap();
        fs::write(path.join("status"), status).unwrap();
        if modern {
            fs::write(path.join("connector_id"), "42\n").unwrap();
        }
        self.device_link(&path, device);
        path
    }

    fn backlight(&self, name: &str, device: &str, kind: &str) {
        let path = self.0.join("backlight").join(name);
        fs::create_dir(&path).unwrap();
        fs::write(path.join("max_brightness"), "100\n").unwrap();
        fs::write(path.join("type"), kind).unwrap();
        self.device_link(&path, device);
    }

    fn device_link(&self, path: &Path, device: &str) {
        let target = self.0.join("devices").join(device);
        fs::create_dir_all(&target).unwrap();
        symlink(target, path.join("device")).unwrap();
    }

    fn backlights(&self) -> HashMap<String, BacklightDevice> {
        discover_backlights(&self.0.join("backlight"), &self.0.join("drm"))
    }
}

impl Drop for SysfsFixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn legacy_internal_connector_types_discover_standard_backlights() {
    for connector in ["DSI-1", "eDP-1", "LVDS-1"] {
        let fixture = SysfsFixture::new();
        fixture.connector(
            &format!("card0-{connector}"),
            "connected\n",
            "display",
            false,
        );
        fixture.backlight("panel", "separate-pwm-provider", "raw\n");
        let displays = fixture.backlights();
        assert_eq!(displays.len(), 1);
        assert_eq!(displays[connector].name, "panel");
    }
}

#[test]
fn modern_and_legacy_connectors_keep_their_own_backlights() {
    let fixture = SysfsFixture::new();
    fixture.connector("card0-eDP-1", "connected", "gpu0", true);
    fixture.connector("card1-DSI-1", "connected", "gpu1", false);
    fixture.backlight("laptop", "gpu0/panel", "raw");
    fixture.backlight("tablet", "gpu1/panel", "raw");
    let displays = fixture.backlights();
    assert_eq!(displays.len(), 2);
    assert_eq!(displays["eDP-1"].name, "laptop");
    assert_eq!(displays["DSI-1"].name, "tablet");
}

#[test]
fn disconnected_and_external_connectors_do_not_claim_backlights() {
    for modern in [false, true] {
        let fixture = SysfsFixture::new();
        fixture.connector("card0-eDP-1", "disconnected", "gpu", modern);
        fixture.connector("card0-HDMI-A-1", "connected", "gpu", modern);
        fixture.backlight("panel", "gpu/panel", "raw");
        assert!(fixture.backlights().is_empty());
    }
}

#[test]
fn legacy_discovery_keeps_backlight_priority_and_ambiguity_checks() {
    let fixture = SysfsFixture::new();
    fixture.connector("card0-eDP-1", "connected", "gpu", false);
    fixture.backlight("firmware", "gpu/panel", "firmware");
    fixture.backlight("native", "gpu/panel", "raw");
    assert_eq!(fixture.backlights()["eDP-1"].name, "native");
    fixture.backlight("other-native", "gpu/panel", "raw");
    assert!(fixture.backlights().is_empty());
}

#[test]
fn unrelated_multiple_backlights_remain_unclaimed() {
    for modern in [false, true] {
        let fixture = SysfsFixture::new();
        fixture.connector("card0-DSI-1", "connected", "display", modern);
        fixture.backlight("first", "first-pwm", "raw");
        fixture.backlight("second", "second-pwm", "raw");
        assert!(fixture.backlights().is_empty());
    }
}

#[test]
fn ddc_discovery_preserves_bus_and_edid_for_both_sysfs_layouts() {
    let fixture = SysfsFixture::new();
    for (name, modern, bus) in [("card0-DP-1", true, 7), ("card1-HDMI-A-1", false, 8)] {
        let connector = fixture.connector(name, "connected", "gpu", modern);
        let i2c = fixture.0.join(format!("i2c-{bus}"));
        fs::create_dir(&i2c).unwrap();
        symlink(i2c, connector.join("ddc")).unwrap();
        fs::write(connector.join("edid"), [bus as u8; 256]).unwrap();
    }
    for name in ["card0", "renderD128"] {
        fs::create_dir(fixture.0.join("drm").join(name)).unwrap();
    }
    let identities = drm_connector_identities(&fixture.0.join("drm"));
    assert_eq!(identities.len(), 2);
    for (name, bus) in [("DP-1", 7), ("HDMI-A-1", 8)] {
        let identity = identities.iter().find(|item| item.name == name).unwrap();
        assert_eq!(identity.i2c_bus, Some(bus));
        assert_eq!(identity.edid, Some([bus as u8; 128]));
    }
}
