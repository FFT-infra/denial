//! Optional numeric unlock PIN. The account password stays the primary
//! credential: a PIN unlock still passes PAM account policy, the lock screen
//! always offers the password next to the PIN, and nothing outside the lock
//! screen accepts the PIN.
//!
//! The record is one Argon2id hash in the user's state directory, written only
//! after the account password is verified. A later security pass moves it
//! behind a root-owned helper; callers only see `PinStore` and `PinRecord`.

use super::*;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::{Algorithm, Argon2, Params, Version};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::PathBuf;

pub(super) const MIN_LENGTH: usize = 4;
pub(super) const MAX_LENGTH: usize = 12;
const RECORD_VERSION: u64 = 1;
const MAX_RECORD_BYTES: u64 = 1024;
const SALT_BYTES: usize = 16;
// OWASP's Argon2id baseline: 19 MiB, two passes, one lane.
const MEMORY_KIB: u32 = 19 * 1024;
const PASSES: u32 = 2;

pub(super) fn valid_pin(pin: &[u8]) -> bool {
    (MIN_LENGTH..=MAX_LENGTH).contains(&pin.len()) && pin.iter().all(u8::is_ascii_digit)
}

#[derive(Clone, Debug)]
pub(super) struct PinStore {
    path: PathBuf,
}

pub(super) struct PinRecord {
    length: u32,
    hash: String,
}

impl PinRecord {
    pub(super) fn length(&self) -> u32 {
        self.length
    }

    pub(super) fn verify(&self, pin: &[u8]) -> bool {
        // Wrong lengths are rejected without hashing; the length is not secret
        // because the lock screen draws one slot per digit.
        if pin.len() != self.length as usize || !valid_pin(pin) {
            return false;
        }
        PasswordHash::new(&self.hash)
            .is_ok_and(|hash| Argon2::default().verify_password(pin, &hash).is_ok())
    }
}

impl PinStore {
    pub(super) fn for_current_user() -> Option<Self> {
        let state_home = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .or_else(|| {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .filter(|path| path.is_absolute())
                    .map(|home| home.join(".local/state"))
            })?;
        Some(Self::at(state_home.join("denial/lock-pin")))
    }

    pub(super) fn at(path: PathBuf) -> Self {
        Self { path }
    }

    pub(super) fn load(&self) -> io::Result<Option<PinRecord>> {
        let mut file = match File::open(&self.path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let metadata = file.metadata()?;
        // SAFETY: getuid has no preconditions and cannot fail.
        let uid = unsafe { libc::getuid() };
        if !metadata.is_file() || metadata.uid() != uid || metadata.len() > MAX_RECORD_BYTES {
            return Err(invalid_record());
        }
        let mut text = String::new();
        Read::by_ref(&mut file)
            .take(MAX_RECORD_BYTES)
            .read_to_string(&mut text)?;
        let record: Value = serde_json::from_str(&text).map_err(|_| invalid_record())?;
        let length = record
            .get("length")
            .and_then(Value::as_u64)
            .filter(|length| (MIN_LENGTH as u64..=MAX_LENGTH as u64).contains(length))
            .ok_or_else(invalid_record)?;
        let hash = record
            .get("hash")
            .and_then(Value::as_str)
            .filter(|hash| {
                PasswordHash::new(hash)
                    .is_ok_and(|hash| hash.algorithm == Algorithm::Argon2id.ident())
            })
            .ok_or_else(invalid_record)?;
        if record.get("version").and_then(Value::as_u64) != Some(RECORD_VERSION) {
            return Err(invalid_record());
        }
        Ok(Some(PinRecord {
            length: length as u32,
            hash: hash.to_owned(),
        }))
    }

    pub(super) fn save(&self, pin: &[u8]) -> io::Result<u32> {
        if !valid_pin(pin) {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let mut salt = [0u8; SALT_BYTES];
        fill_random(&mut salt)?;
        let salt = SaltString::encode_b64(&salt).map_err(|_| invalid_record())?;
        let params = Params::new(MEMORY_KIB, PASSES, 1, None).map_err(|_| invalid_record())?;
        let hash = Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
            .hash_password(pin, &salt)
            .map_err(|_| invalid_record())?
            .to_string();
        let length = pin.len() as u32;
        let record = json!({"version": RECORD_VERSION, "length": length, "hash": hash});
        self.replace(record.to_string().as_bytes())?;
        Ok(length)
    }

    pub(super) fn clear(&self) -> io::Result<()> {
        match fs::remove_file(&self.path) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    /// Writes a private sibling and renames it over the record, so a reader
    /// never sees a partial record and a crash keeps the previous one.
    fn replace(&self, contents: &[u8]) -> io::Result<()> {
        let directory = self.path.parent().ok_or(io::ErrorKind::InvalidInput)?;
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)?;
        let staging = directory.join(format!(".lock-pin.{}", std::process::id()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&staging)?;
            file.write_all(contents)?;
            file.sync_all()?;
            fs::rename(&staging, &self.path)?;
            File::open(directory)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(&staging);
        }
        result
    }

    #[cfg(test)]
    pub(super) fn path(&self) -> &std::path::Path {
        &self.path
    }
}

fn invalid_record() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid lock PIN record")
}

fn fill_random(bytes: &mut [u8]) -> io::Result<()> {
    let mut filled = 0;
    while filled < bytes.len() {
        // SAFETY: the pointer and length describe the unfilled tail of `bytes`.
        let count = unsafe {
            libc::getrandom(bytes[filled..].as_mut_ptr().cast(), bytes.len() - filled, 0)
        };
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
            continue;
        }
        filled += count as usize;
    }
    Ok(())
}

/// One PIN attempt: the shell answers a numeric prompt, the record decides,
/// and PAM account policy still runs exactly as it does for fingerprints.
pub(super) fn authenticate(
    record: &PinRecord,
    backend: &dyn AuthenticationBackend,
    conversation: &mut dyn FnMut(PromptStyle, &str) -> Option<SecureString>,
    cancelled: &dyn Fn() -> bool,
) -> BackendResult {
    let Some(mut response) = conversation(PromptStyle::Pin, "PIN") else {
        return BackendResult::Cancelled;
    };
    let matched = record.verify(response.as_bytes());
    response.clear();
    if cancelled() {
        return BackendResult::Cancelled;
    }
    if !matched {
        return BackendResult::Failure;
    }
    match backend.validate_account() {
        Ok(()) => BackendResult::Success,
        Err(error) => {
            warn!(%error, "PIN matched but PAM account policy refused the unlock");
            BackendResult::Error
        }
    }
}

/// `deniald --lock-pin`: Settings runs this as the session user. Secrets come
/// one per stdin line and never through argv, the environment or JSON:
/// `status`, `set` + password + PIN, or `clear` + password.
pub(crate) fn run_settings() -> Result<(), Box<dyn Error>> {
    let store = PinStore::for_current_user().ok_or("no state directory for the lock PIN")?;
    let mut input = io::BufReader::new(io::stdin());
    let command = read_bounded_line(&mut input)?.ok_or("lock PIN command closed")?;
    let reply = match command.as_slice() {
        b"status" => status_event(&store),
        b"set" | b"clear" => {
            let mut bytes = read_bounded_line(&mut input)?.ok_or("password input closed")?;
            let password = SecureString::new(&bytes);
            erase_bytes(&mut bytes);
            let mut backend = PamBackend::load()?;
            if authenticate_password(&mut backend, &current_username(), &password)
                != BackendResult::Success
            {
                json!({"event": "authentication-failed"})
            } else if command == b"clear" {
                store.clear()?;
                json!({"event": "cleared"})
            } else {
                let mut bytes = read_bounded_line(&mut input)?.ok_or("PIN input closed")?;
                let pin = SecureString::new(&bytes);
                erase_bytes(&mut bytes);
                if valid_pin(pin.as_bytes()) {
                    json!({"event": "saved", "length": store.save(pin.as_bytes())?})
                } else {
                    json!({"event": "invalid-pin"})
                }
            }
        }
        _ => return Err("unknown lock PIN command".into()),
    };
    println!("{reply}");
    Ok(())
}

fn status_event(store: &PinStore) -> Value {
    match store.load() {
        Ok(record) => json!({
            "event": "status",
            "length": record.map_or(0, |record| record.length()),
        }),
        Err(error) => {
            eprintln!("lock PIN record: {error}");
            json!({"event": "status", "length": 0, "invalid": true})
        }
    }
}
