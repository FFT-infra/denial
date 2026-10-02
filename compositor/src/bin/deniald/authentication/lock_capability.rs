//! Advisory account metadata prevents automatic locks with no unlock method.
//! Unknown providers preserve the configured security policy; explicit locks
//! never depend on this probe. No password or fingerprint scan is attempted.

use super::*;
use std::io::Read;
use std::process::{Command, Stdio};
use zbus::blocking::{Connection, Proxy, connection::Builder};
use zbus::zvariant::OwnedObjectPath;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Capability {
    Pending,
    Unknown,
    Available,
    Unavailable,
}

impl Capability {
    pub(super) fn permits_lock(self) -> bool {
        matches!(self, Self::Unknown | Self::Available)
    }
}

#[derive(Clone, Copy)]
struct Account {
    locked: bool,
    password_mode: i32,
}

fn classify(account: Option<Account>, fingerprint: Option<bool>) -> Capability {
    match (account, fingerprint) {
        (
            Some(Account {
                locked: false,
                password_mode: 0,
            }),
            _,
        )
        | (_, Some(true)) => Capability::Available,
        (Some(Account { locked: true, .. }), _)
        | (
            Some(Account {
                password_mode: 1 | 2,
                ..
            }),
            _,
        ) => Capability::Unavailable,
        _ => Capability::Unknown,
    }
}

pub(super) fn run_worker(shared: &Arc<SharedAuthentication>) {
    loop {
        if lock_unpoisoned(&shared.state).stopping {
            return;
        }
        let capability = probe().unwrap_or_else(|error| {
            tracing::debug!(%error, "could not determine automatic lock capability");
            Capability::Unknown
        });
        let mut state = lock_unpoisoned(&shared.state);
        // Losing the metadata provider must not re-arm an account previously
        // established to have no unlock method.
        let capability = if capability == Capability::Unknown
            && state.automatic_lock == Capability::Unavailable
        {
            Capability::Unavailable
        } else {
            capability
        };
        if state.automatic_lock != capability {
            state.automatic_lock = capability;
            state.automatic_lock_warning_shown = false;
            match capability {
                Capability::Unavailable => warn!(
                    "automatic session locking disabled: account has no usable password or fingerprint unlock; explicit locking remains available"
                ),
                Capability::Unknown => warn!(
                    "automatic lock capability is unknown; retaining configured locking policy"
                ),
                _ => info!(?capability, "automatic session lock capability changed"),
            }
        }
        // Recheck changes to passwords, account locks, and fingerprint
        // enrollment. The condvar lets shutdown complete without waiting 30s.
        let deadline = Instant::now() + Duration::from_secs(30);
        while !state.stopping {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            state = shared
                .condition
                .wait_timeout(state, remaining)
                .unwrap_or_else(|error| error.into_inner())
                .0;
        }
    }
}

fn probe() -> Result<Capability, String> {
    // An explicitly selected PAM stack can authenticate independently of a
    // local password. AccountsService cannot establish its capabilities.
    if configured_pam_service() != "login" {
        return Ok(Capability::Unknown);
    }
    let connection = Builder::system()
        .and_then(|builder| builder.method_timeout(Duration::from_secs(3)).build());
    let account = match connection
        .as_ref()
        .ok()
        .and_then(|connection| account(connection).ok())
    {
        Some(account) => account,
        None => password_status().ok_or("account metadata is unavailable")?,
    };
    if !account.locked && account.password_mode == 0 {
        return Ok(Capability::Available);
    }
    let fingerprint = connection
        .as_ref()
        .ok()
        .and_then(|connection| fingerprint_enrolled(connection).ok())
        .map(|enrolled| {
            enrolled
                && PamBackend::load()
                    .and_then(|backend| backend.validate_account())
                    .is_ok()
        });
    Ok(classify(Some(account), fingerprint))
}

fn parse_password_status(output: &str, username: &str) -> Option<Account> {
    let mut fields = output.split_whitespace();
    if fields.next()? != username {
        return None;
    }
    match fields.next()? {
        "L" => Some(Account {
            locked: true,
            password_mode: 0,
        }),
        "NP" => Some(Account {
            locked: false,
            password_mode: 2,
        }),
        "P" => Some(Account {
            locked: false,
            password_mode: 0,
        }),
        _ => None,
    }
}

fn password_status() -> Option<Account> {
    let username = current_username();
    if username.starts_with('-') || username.is_empty() {
        return None;
    }
    // shadow-utils allows an unprivileged user to query their own status.
    // Fixed paths avoid selecting an executable from the shell's PATH. -S is
    // read-only; never invoke passwd without it or provide password input.
    for path in ["/usr/bin/passwd", "/bin/passwd"] {
        let Ok(mut child) = Command::new(path)
            .args(["-S", &username])
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
        else {
            continue;
        };
        let deadline = Instant::now() + Duration::from_secs(3);
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
            }
        };
        if status.is_some_and(|status| status.success()) {
            let mut output = String::new();
            if child
                .stdout
                .take()?
                .take(1024)
                .read_to_string(&mut output)
                .is_ok()
                && let Some(account) = parse_password_status(&output, &username)
            {
                return Some(account);
            }
        }
    }
    None
}

fn account(connection: &Connection) -> zbus::Result<Account> {
    let manager = Proxy::new(
        connection,
        "org.freedesktop.Accounts",
        "/org/freedesktop/Accounts",
        "org.freedesktop.Accounts",
    )?;
    // Use the native UID, never USER or another shell-supplied identity.
    let uid = unsafe { libc::getuid() };
    let path: OwnedObjectPath = manager.call("FindUserById", &(i64::from(uid),))?;
    let user = Proxy::new(
        connection,
        "org.freedesktop.Accounts",
        path,
        "org.freedesktop.Accounts.User",
    )?;
    Ok(Account {
        locked: user.get_property("Locked")?,
        password_mode: user.get_property("PasswordMode")?,
    })
}

fn fingerprint_enrolled(connection: &Connection) -> zbus::Result<bool> {
    let bus = zbus::blocking::fdo::DBusProxy::new(connection)?;
    // An absent, non-activatable service cannot provide native unlock.
    let running = bus.name_has_owner("net.reactivated.Fprint".try_into()?)?;
    if !running {
        let names = bus.list_activatable_names()?;
        if !names
            .iter()
            .any(|name| name.as_str() == "net.reactivated.Fprint")
        {
            return Ok(false);
        }
    }
    let manager = Proxy::new(
        connection,
        "net.reactivated.Fprint",
        "/net/reactivated/Fprint/Manager",
        "net.reactivated.Fprint.Manager",
    )?;
    let devices: Vec<OwnedObjectPath> = manager.call("GetDevices", &())?;
    for path in devices {
        let device = Proxy::new(
            connection,
            "net.reactivated.Fprint",
            path,
            "net.reactivated.Fprint.Device",
        )?;
        let fingers: Vec<String> = device.call("ListEnrolledFingers", &("",))?;
        if !fingers.is_empty() {
            return Ok(true);
        }
    }
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unusable_accounts_require_a_validated_fingerprint() {
        for account in [
            Account {
                locked: true,
                password_mode: 0,
            },
            Account {
                locked: false,
                password_mode: 1,
            },
            Account {
                locked: false,
                password_mode: 2,
            },
        ] {
            assert_eq!(
                classify(Some(account), Some(false)),
                Capability::Unavailable
            );
            assert_eq!(classify(Some(account), Some(true)), Capability::Available);
            assert_eq!(classify(Some(account), None), Capability::Unavailable);
        }
    }

    #[test]
    fn unknown_metadata_does_not_disable_configured_security() {
        assert!(Capability::Unknown.permits_lock());
        assert!(!Capability::Pending.permits_lock());
        assert_eq!(classify(None, Some(false)), Capability::Unknown);
        assert_eq!(
            classify(
                Some(Account {
                    locked: false,
                    password_mode: 7
                }),
                Some(false)
            ),
            Capability::Unknown
        );
        assert_eq!(
            classify(
                Some(Account {
                    locked: false,
                    password_mode: 0
                }),
                None
            ),
            Capability::Available
        );
    }

    #[test]
    fn password_status_fallback_accepts_only_the_native_users_known_status() {
        let locked = parse_password_status("alice L 2026-01-01 0 99999 7 -1\n", "alice").unwrap();
        assert_eq!(classify(Some(locked), Some(false)), Capability::Unavailable);
        let empty = parse_password_status("alice NP 2026-01-01 0 99999 7 -1\n", "alice").unwrap();
        assert_eq!(classify(Some(empty), Some(false)), Capability::Unavailable);
        let password = parse_password_status("alice P 2026-01-01 0 99999 7 -1\n", "alice").unwrap();
        assert_eq!(classify(Some(password), Some(false)), Capability::Available);
        for output in ["bob L", "alice", "alice invalid", "", "warning: alice L"] {
            assert!(parse_password_status(output, "alice").is_none());
        }
    }
}
