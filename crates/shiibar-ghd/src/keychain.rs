//! Token storage. Only the daemon touches the Keychain (CLAUDE.md).
//!
//! Every token (notifications, each scope, Public) lives in ONE generic
//! password item, service `shiibar-gh`, account `tokens` (DESIGN.md, "Saved
//! state"). A development build is signed without a Team ID, so the
//! Keychain ties each item's access to the build; one item asks once per
//! reinstall instead of once per token. The item holds a JSON document
//! `{"version":1,"tokens":{"<account>":"<token>"}}`, where `<account>` is
//! the per-token name used before: `notifications`, `public` or
//! `scope:<lowercase owner>`. The version lets the format grow (several
//! accounts in M4).
//!
//! Items of the earlier one-per-token layout (accounts `notifications`,
//! `public`, `scope:...`) are neither read nor deleted.
//!
//! A `dev-ingest` build can swap in a file or no Keychain at all, so tests
//! never reach the real one.

use std::collections::BTreeMap;
use std::sync::Mutex;

pub const SERVICE: &str = "shiibar-gh";
/// The account of the one item that holds every token.
pub const ITEM_ACCOUNT: &str = "tokens";
/// The format of the item's document.
pub const FORMAT_VERSION: u64 = 1;

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
    /// Every account that has a token.
    fn accounts(&self) -> Result<Vec<String>, KeychainError>;
}

/// Where the one item's bytes live: the real Keychain or a test file.
pub trait ItemStore: Send + Sync {
    /// `Ok(None)` when there is no item yet.
    fn read(&self) -> Result<Option<String>, KeychainError>;
    /// Replace the item's whole content in one write.
    fn write(&self, data: &str) -> Result<(), KeychainError>;
}

/// The tokens as one document in one item. Every change reads the item,
/// changes the map and writes it back whole, under a lock; a write that
/// fails leaves the item as it was, and an item that cannot be read is
/// never overwritten, so no other token is lost.
pub struct TokenStore<S: ItemStore> {
    item: S,
    lock: Mutex<()>,
}

impl<S: ItemStore> TokenStore<S> {
    pub fn new(item: S) -> Self {
        Self {
            item,
            lock: Mutex::new(()),
        }
    }

    fn load(&self) -> Result<BTreeMap<String, String>, KeychainError> {
        match self.item.read()? {
            None => Ok(BTreeMap::new()),
            Some(text) => parse(&text),
        }
    }

    fn save(&self, tokens: &BTreeMap<String, String>) -> Result<(), KeychainError> {
        self.item.write(&serialize(tokens))
    }
}

/// The item's document as a map of account to token.
pub fn parse(text: &str) -> Result<BTreeMap<String, String>, KeychainError> {
    let value: serde_json::Value = serde_json::from_str(text)
        .map_err(|_| KeychainError("the saved tokens are not readable".into()))?;
    if value["version"].as_u64() != Some(FORMAT_VERSION) {
        return Err(KeychainError(format!(
            "the saved tokens have format version {}, this build reads {FORMAT_VERSION}",
            value["version"]
        )));
    }
    serde_json::from_value(value["tokens"].clone())
        .map_err(|_| KeychainError("the saved tokens are not readable".into()))
}

pub fn serialize(tokens: &BTreeMap<String, String>) -> String {
    serde_json::json!({"version": FORMAT_VERSION, "tokens": tokens}).to_string()
}

impl<S: ItemStore> Keychain for TokenStore<S> {
    fn get(&self, account: &str) -> Result<Option<String>, KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        Ok(self.load()?.get(account).cloned())
    }

    fn set(&self, account: &str, token: &str) -> Result<(), KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut tokens = self.load()?;
        tokens.insert(account.to_string(), token.to_string());
        self.save(&tokens)
    }

    fn delete(&self, account: &str) -> Result<(), KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        let mut tokens = self.load()?;
        if tokens.remove(account).is_none() {
            return Ok(());
        }
        self.save(&tokens)
    }

    fn accounts(&self) -> Result<Vec<String>, KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        Ok(self.load()?.into_keys().collect())
    }
}

/// The one item in the macOS Keychain through Security.framework.
pub struct SystemItem;

/// `errSecItemNotFound` in Security.framework's SecBase.h.
const ITEM_NOT_FOUND: i32 = -25300;

fn system_error(what: &str, e: security_framework::base::Error) -> KeychainError {
    KeychainError(format!("{what}: Keychain error {}", e.code()))
}

impl ItemStore for SystemItem {
    fn read(&self) -> Result<Option<String>, KeychainError> {
        match security_framework::passwords::get_generic_password(SERVICE, ITEM_ACCOUNT) {
            Ok(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| KeychainError("the saved tokens are not text".into())),
            Err(e) if e.code() == ITEM_NOT_FOUND => Ok(None),
            Err(e) => Err(system_error("cannot read the tokens", e)),
        }
    }

    /// `set_generic_password` updates the item when it exists and adds it
    /// otherwise (security-framework 3.7.0, src/passwords.rs).
    fn write(&self, data: &str) -> Result<(), KeychainError> {
        security_framework::passwords::set_generic_password(SERVICE, ITEM_ACCOUNT, data.as_bytes())
            .map_err(|e| system_error("cannot save the tokens", e))
    }
}

/// The real Keychain: all tokens in the one item.
pub fn system() -> TokenStore<SystemItem> {
    TokenStore::new(SystemItem)
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

/// The item in a file, for tests: the file holds exactly what the real
/// item would.
#[cfg(feature = "dev-ingest")]
pub struct FileItem {
    path: std::path::PathBuf,
}

#[cfg(feature = "dev-ingest")]
impl FileItem {
    pub fn new(path: std::path::PathBuf) -> Self {
        Self { path }
    }
}

#[cfg(feature = "dev-ingest")]
impl ItemStore for FileItem {
    fn read(&self) -> Result<Option<String>, KeychainError> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) if text.trim().is_empty() => Ok(None),
            Ok(text) => Ok(Some(text)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(KeychainError(format!("cannot read the test Keychain: {e}"))),
        }
    }

    /// Written to a draft and renamed into place, so a failure leaves the
    /// file as it was.
    fn write(&self, data: &str) -> Result<(), KeychainError> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let draft = self.path.with_extension("new");
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&draft)
            .map_err(|e| KeychainError(format!("cannot write the test Keychain: {e}")))?;
        file.write_all(data.as_bytes())
            .and_then(|()| std::fs::rename(&draft, &self.path))
            .map_err(|e| KeychainError(format!("cannot write the test Keychain: {e}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An item in memory; `fail_writes` makes every write fail.
    struct Memory {
        data: Mutex<Option<String>>,
        fail_writes: bool,
    }

    impl ItemStore for Memory {
        fn read(&self) -> Result<Option<String>, KeychainError> {
            Ok(self.data.lock().unwrap().clone())
        }

        fn write(&self, data: &str) -> Result<(), KeychainError> {
            if self.fail_writes {
                return Err(KeychainError("write refused".into()));
            }
            *self.data.lock().unwrap() = Some(data.to_string());
            Ok(())
        }
    }

    fn store(data: Option<&str>, fail_writes: bool) -> TokenStore<Memory> {
        TokenStore::new(Memory {
            data: Mutex::new(data.map(str::to_string)),
            fail_writes,
        })
    }

    #[test]
    fn every_token_goes_into_one_versioned_item() {
        let tokens = store(None, false);
        assert_eq!(tokens.accounts().unwrap(), Vec::<String>::new());
        tokens.set("notifications", "a").unwrap();
        tokens.set("scope:org", "b").unwrap();
        tokens.set("public", "c").unwrap();
        tokens.set("scope:org", "b2").unwrap();
        assert_eq!(tokens.get("scope:org").unwrap().as_deref(), Some("b2"));
        assert_eq!(
            tokens.accounts().unwrap(),
            ["notifications", "public", "scope:org"]
        );
        let item = tokens.item.data.lock().unwrap().clone().unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&item).unwrap(),
            serde_json::json!({"version":1,"tokens":{"notifications":"a","public":"c","scope:org":"b2"}})
        );
        tokens.delete("public").unwrap();
        tokens.delete("public").unwrap();
        assert_eq!(tokens.get("public").unwrap(), None);
        assert_eq!(tokens.accounts().unwrap(), ["notifications", "scope:org"]);
    }

    #[test]
    fn a_failed_write_keeps_the_other_tokens() {
        let before = serialize(&BTreeMap::from([(
            "notifications".to_string(),
            "a".to_string(),
        )]));
        let tokens = store(Some(&before), true);
        assert!(tokens.set("scope:org", "b").is_err());
        assert!(tokens.delete("notifications").is_err());
        assert_eq!(
            tokens.item.data.lock().unwrap().as_deref(),
            Some(before.as_str())
        );
        assert_eq!(tokens.get("notifications").unwrap().as_deref(), Some("a"));
    }

    #[test]
    fn an_unreadable_item_is_never_overwritten() {
        for bad in [
            "not json",
            r#"{"version":2,"tokens":{}}"#,
            r#"{"tokens":{"a":"b"}}"#,
        ] {
            let tokens = store(Some(bad), false);
            assert!(tokens.set("notifications", "a").is_err(), "{bad}");
            assert!(tokens.accounts().is_err(), "{bad}");
            assert_eq!(tokens.item.data.lock().unwrap().as_deref(), Some(bad));
        }
    }
}
