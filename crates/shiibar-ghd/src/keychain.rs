//! Token storage. Only the daemon touches the Keychain (CLAUDE.md).
//!
//! Every account's token lives in ONE generic password item, service
//! `shiibar-gh`, account `accounts` (DESIGN.md, "Saved state"). The item
//! holds a JSON document
//! `{"version":2,"accounts":[{"id":"<numeric user id>","login":"<login>","token":"<token>"}]}`.
//! 0.1 used the account `tokens` of the same service; that item is neither
//! read nor deleted.
//!
//! A development build is signed without a Team ID, so the Keychain ties
//! the item's access to the build; one item asks once per reinstall.
//!
//! A `dev-ingest` build can swap in a file or no Keychain at all, so tests
//! never reach the real one.

use std::sync::Mutex;

pub const SERVICE: &str = "shiibar-gh";
/// The account of the one item that holds every token.
pub const ITEM_ACCOUNT: &str = "accounts";
/// The format of the item's document.
pub const FORMAT_VERSION: u64 = 2;

/// DESIGN.md, "When the Keychain cannot be read": an OS error, or an item
/// whose content cannot be read. A missing item is no error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeychainError {
    /// `keychain_unavailable`: the OS refused or failed.
    Unavailable(String),
    /// `tokens_unreadable`: the item is there but not readable.
    Unreadable(String),
}

impl std::fmt::Display for KeychainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            KeychainError::Unavailable(m) | KeychainError::Unreadable(m) => write!(f, "{m}"),
        }
    }
}

/// One account in the item. Never logged: it holds the token.
#[derive(Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct StoredAccount {
    pub id: String,
    pub login: String,
    pub token: String,
}

impl std::fmt::Debug for StoredAccount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("StoredAccount")
            .field("id", &self.id)
            .field("login", &self.login)
            .finish_non_exhaustive()
    }
}

pub trait Keychain: Send + Sync {
    /// `Ok(None)` when there is no item.
    fn load(&self) -> Result<Option<Vec<StoredAccount>>, KeychainError>;
    /// Replace the item's content.
    fn save(&self, accounts: &[StoredAccount]) -> Result<(), KeychainError>;
    /// Delete the item; a missing item succeeds.
    fn delete(&self) -> Result<(), KeychainError>;
}

/// Where the one item's bytes live: the real Keychain or a test file.
pub trait ItemStore: Send + Sync {
    /// `Ok(None)` when there is no item yet.
    fn read(&self) -> Result<Option<String>, KeychainError>;
    /// Replace the item's whole content in one write.
    fn write(&self, data: &str) -> Result<(), KeychainError>;
    fn remove(&self) -> Result<(), KeychainError>;
}

/// The accounts as one document in one item, under a lock.
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
}

/// The item's document as accounts.
pub fn parse(text: &str) -> Result<Vec<StoredAccount>, KeychainError> {
    let unreadable = || KeychainError::Unreadable("the saved tokens are not readable".into());
    let value: serde_json::Value = serde_json::from_str(text).map_err(|_| unreadable())?;
    if value["version"].as_u64() != Some(FORMAT_VERSION) {
        return Err(KeychainError::Unreadable(format!(
            "the saved tokens have format version {}, this build reads {FORMAT_VERSION}",
            value["version"]
        )));
    }
    serde_json::from_value(value["accounts"].clone()).map_err(|_| unreadable())
}

pub fn serialize(accounts: &[StoredAccount]) -> String {
    serde_json::json!({"version": FORMAT_VERSION, "accounts": accounts}).to_string()
}

impl<S: ItemStore> Keychain for TokenStore<S> {
    fn load(&self) -> Result<Option<Vec<StoredAccount>>, KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        match self.item.read()? {
            None => Ok(None),
            Some(text) => parse(&text).map(Some),
        }
    }

    fn save(&self, accounts: &[StoredAccount]) -> Result<(), KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.item.write(&serialize(accounts))
    }

    fn delete(&self) -> Result<(), KeychainError> {
        let _guard = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        self.item.remove()
    }
}

/// The one item in the macOS Keychain through Security.framework.
pub struct SystemItem;

/// `errSecItemNotFound` in Security.framework's SecBase.h.
const ITEM_NOT_FOUND: i32 = -25300;

fn system_error(what: &str, e: security_framework::base::Error) -> KeychainError {
    KeychainError::Unavailable(format!("{what}: Keychain error {}", e.code()))
}

impl ItemStore for SystemItem {
    fn read(&self) -> Result<Option<String>, KeychainError> {
        match security_framework::passwords::get_generic_password(SERVICE, ITEM_ACCOUNT) {
            Ok(bytes) => String::from_utf8(bytes)
                .map(Some)
                .map_err(|_| KeychainError::Unreadable("the saved tokens are not text".into())),
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

    fn remove(&self) -> Result<(), KeychainError> {
        match security_framework::passwords::delete_generic_password(SERVICE, ITEM_ACCOUNT) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == ITEM_NOT_FOUND => Ok(()),
            Err(e) => Err(system_error("cannot delete the tokens", e)),
        }
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
    fn load(&self) -> Result<Option<Vec<StoredAccount>>, KeychainError> {
        Ok(None)
    }

    fn save(&self, _: &[StoredAccount]) -> Result<(), KeychainError> {
        Err(KeychainError::Unavailable(
            "this build has no Keychain".into(),
        ))
    }

    fn delete(&self) -> Result<(), KeychainError> {
        Ok(())
    }
}

/// The item in a file, for tests: the file holds exactly what the real item
/// would. A path that cannot be read (a directory, no permission) is
/// `keychain_unavailable`; content that is not the document is
/// `tokens_unreadable`.
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
            Err(e) if e.kind() == std::io::ErrorKind::InvalidData => Err(
                KeychainError::Unreadable("the test Keychain is not text".into()),
            ),
            Err(e) => Err(KeychainError::Unavailable(format!(
                "cannot read the test Keychain: {e}"
            ))),
        }
    }

    /// Written to a draft and renamed into place, so a failure leaves the
    /// file as it was.
    fn write(&self, data: &str) -> Result<(), KeychainError> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let unavailable = |e: std::io::Error| {
            KeychainError::Unavailable(format!("cannot write the test Keychain: {e}"))
        };
        let draft = self.path.with_extension("new");
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&draft)
            .map_err(unavailable)?;
        file.write_all(data.as_bytes())
            .and_then(|()| std::fs::rename(&draft, &self.path))
            .map_err(unavailable)
    }

    fn remove(&self) -> Result<(), KeychainError> {
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(KeychainError::Unavailable(format!(
                "cannot delete the test Keychain: {e}"
            ))),
        }
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
                return Err(KeychainError::Unavailable("write refused".into()));
            }
            *self.data.lock().unwrap() = Some(data.to_string());
            Ok(())
        }

        fn remove(&self) -> Result<(), KeychainError> {
            *self.data.lock().unwrap() = None;
            Ok(())
        }
    }

    fn store(data: Option<&str>, fail_writes: bool) -> TokenStore<Memory> {
        TokenStore::new(Memory {
            data: Mutex::new(data.map(str::to_string)),
            fail_writes,
        })
    }

    fn account(id: &str, token: &str) -> StoredAccount {
        StoredAccount {
            id: id.into(),
            login: format!("login-{id}"),
            token: token.into(),
        }
    }

    #[test]
    fn every_account_goes_into_one_versioned_item() {
        let tokens = store(None, false);
        assert_eq!(tokens.load().unwrap(), None);
        tokens
            .save(&[account("2001", "a"), account("2002", "b")])
            .unwrap();
        assert_eq!(
            tokens.load().unwrap().unwrap(),
            vec![account("2001", "a"), account("2002", "b")]
        );
        let item = tokens.item.data.lock().unwrap().clone().unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&item).unwrap(),
            serde_json::json!({"version":2,"accounts":[
                {"id":"2001","login":"login-2001","token":"a"},
                {"id":"2002","login":"login-2002","token":"b"}]})
        );
        tokens.delete().unwrap();
        tokens.delete().unwrap();
        assert_eq!(tokens.load().unwrap(), None);
    }

    #[test]
    fn a_failed_write_keeps_the_item() {
        let before = serialize(&[account("2001", "a")]);
        let tokens = store(Some(&before), true);
        assert!(tokens.save(&[]).is_err());
        assert_eq!(
            tokens.item.data.lock().unwrap().as_deref(),
            Some(before.as_str())
        );
    }

    #[test]
    fn content_that_is_not_the_document_is_unreadable() {
        for bad in [
            "not json",
            r#"{"version":1,"tokens":{}}"#,
            r#"{"accounts":[]}"#,
            r#"{"version":2,"accounts":[{"id":"U"}]}"#,
        ] {
            let tokens = store(Some(bad), false);
            assert!(
                matches!(tokens.load(), Err(KeychainError::Unreadable(_))),
                "{bad}"
            );
        }
    }

    #[test]
    fn a_stored_account_never_prints_its_token() {
        let text = format!("{:?}", account("2001", "secret-token"));
        assert!(!text.contains("secret-token"), "{text}");
    }
}
