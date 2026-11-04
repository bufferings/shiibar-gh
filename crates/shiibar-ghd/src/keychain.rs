//! Token storage. Only the daemon touches the Keychain (CLAUDE.md). Tokens
//! are generic passwords under service `shiibar-gh`, one account per target:
//! docs/tasks/M2.md, "Tokens and the Keychain".
//!
//! A `dev-ingest` build can swap in a JSON file or no Keychain at all, so
//! tests never reach the real one.

pub const SERVICE: &str = "shiibar-gh";

#[derive(Debug)]
pub struct KeychainError(pub String);

impl std::fmt::Display for KeychainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

pub trait Keychain: Send + Sync {
    /// `Ok(None)` when there is no such entry.
    fn get(&self, account: &str) -> Result<Option<String>, KeychainError>;
    fn set(&self, account: &str, token: &str) -> Result<(), KeychainError>;
    /// Deleting a missing entry succeeds.
    fn delete(&self, account: &str) -> Result<(), KeychainError>;
    /// Every account under the service.
    fn accounts(&self) -> Result<Vec<String>, KeychainError>;
}

/// The macOS Keychain through Security.framework.
pub struct SystemKeychain;

/// `errSecItemNotFound` in Security.framework's SecBase.h.
const ITEM_NOT_FOUND: i32 = -25300;

fn system_error(what: &str, e: security_framework::base::Error) -> KeychainError {
    KeychainError(format!("{what}: Keychain error {}", e.code()))
}

impl Keychain for SystemKeychain {
    fn get(&self, account: &str) -> Result<Option<String>, KeychainError> {
        match security_framework::passwords::get_generic_password(SERVICE, account) {
            Ok(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| KeychainError("the saved token is not text".into())),
            Err(e) if e.code() == ITEM_NOT_FOUND => Ok(None),
            Err(e) => Err(system_error("cannot read the token", e)),
        }
    }

    fn set(&self, account: &str, token: &str) -> Result<(), KeychainError> {
        security_framework::passwords::set_generic_password(SERVICE, account, token.as_bytes())
            .map_err(|e| system_error("cannot save the token", e))
    }

    fn delete(&self, account: &str) -> Result<(), KeychainError> {
        match security_framework::passwords::delete_generic_password(SERVICE, account) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == ITEM_NOT_FOUND => Ok(()),
            Err(e) => Err(system_error("cannot delete the token", e)),
        }
    }

    fn accounts(&self) -> Result<Vec<String>, KeychainError> {
        use security_framework::item::{ItemClass, ItemSearchOptions, Limit};
        let found = ItemSearchOptions::new()
            .class(ItemClass::generic_password())
            .service(SERVICE)
            .load_attributes(true)
            .limit(Limit::All)
            .search();
        let results = match found {
            Ok(results) => results,
            Err(e) if e.code() == ITEM_NOT_FOUND => return Ok(Vec::new()),
            Err(e) => return Err(system_error("cannot list the tokens", e)),
        };
        // `acct` is the string value of kSecAttrAccount.
        let mut accounts: Vec<String> = results
            .iter()
            .filter_map(|result| result.simplify_dict())
            .filter_map(|dict| dict.get("acct").cloned())
            .collect();
        accounts.sort();
        accounts.dedup();
        Ok(accounts)
    }
}

/// No Keychain: nothing is saved, and saving fails. A `dev-ingest` build
/// without `SHIIBAR_GH_DEV_KEYCHAIN` runs with this.
pub struct NoKeychain;

impl Keychain for NoKeychain {
    fn get(&self, _: &str) -> Result<Option<String>, KeychainError> {
        Ok(None)
    }

    fn set(&self, _: &str, _: &str) -> Result<(), KeychainError> {
        Err(KeychainError("this build has no Keychain".into()))
    }

    fn delete(&self, _: &str) -> Result<(), KeychainError> {
        Err(KeychainError("this build has no Keychain".into()))
    }

    fn accounts(&self) -> Result<Vec<String>, KeychainError> {
        Ok(Vec::new())
    }
}

/// A JSON object of account to token in one file, for tests.
#[cfg(feature = "dev-ingest")]
pub struct FileKeychain {
    path: std::path::PathBuf,
    lock: std::sync::Mutex<()>,
}

#[cfg(feature = "dev-ingest")]
impl FileKeychain {
    pub fn new(path: std::path::PathBuf) -> Self {
        Self {
            path,
            lock: std::sync::Mutex::new(()),
        }
    }

    fn read(&self) -> Result<std::collections::BTreeMap<String, String>, KeychainError> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) if text.trim().is_empty() => Ok(Default::default()),
            Ok(text) => serde_json::from_str(&text)
                .map_err(|e| KeychainError(format!("the test Keychain is not valid: {e}"))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Default::default()),
            Err(e) => Err(KeychainError(format!("cannot read the test Keychain: {e}"))),
        }
    }

    fn write(&self, map: &std::collections::BTreeMap<String, String>) -> Result<(), KeychainError> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let text = serde_json::to_string(map).unwrap_or_else(|_| "{}".into());
        let draft = self.path.with_extension("new");
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&draft)
            .map_err(|e| KeychainError(format!("cannot write the test Keychain: {e}")))?;
        file.write_all(text.as_bytes())
            .and_then(|()| std::fs::rename(&draft, &self.path))
            .map_err(|e| KeychainError(format!("cannot write the test Keychain: {e}")))
    }
}

#[cfg(feature = "dev-ingest")]
impl Keychain for FileKeychain {
    fn get(&self, account: &str) -> Result<Option<String>, KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        Ok(self.read()?.get(account).cloned())
    }

    fn set(&self, account: &str, token: &str) -> Result<(), KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut map = self.read()?;
        map.insert(account.to_string(), token.to_string());
        self.write(&map)
    }

    fn delete(&self, account: &str) -> Result<(), KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut map = self.read()?;
        map.remove(account);
        self.write(&map)
    }

    fn accounts(&self) -> Result<Vec<String>, KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        Ok(self.read()?.into_keys().collect())
    }
}
