//! The one place that resolves the state directory and the files inside it.
//! Default `~/.local/state/shiibar-gh/`, overridden by `SHIIBAR_GH_STATE_DIR`
//! (DESIGN.md, section "Constants").

use std::path::{Path, PathBuf};

pub const STATE_DIR_ENV: &str = "SHIIBAR_GH_STATE_DIR";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateDir {
    root: PathBuf,
}

impl StateDir {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Resolve from the environment. `None` when neither the override nor
    /// `HOME` is set.
    pub fn from_env() -> Option<Self> {
        if let Some(root) = std::env::var_os(STATE_DIR_ENV) {
            return Some(Self::new(root));
        }
        let home = std::env::var_os("HOME")?;
        Some(Self::new(
            PathBuf::from(home).join(".local/state/shiibar-gh"),
        ))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn socket(&self) -> PathBuf {
        self.root.join("shiibar-ghd.sock")
    }

    pub fn lock(&self) -> PathBuf {
        self.root.join("shiibar-ghd.lock")
    }

    pub fn db(&self) -> PathBuf {
        self.root.join("state.db")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_live_in_the_state_directory() {
        let dir = StateDir::new("state");
        assert_eq!(dir.socket(), Path::new("state/shiibar-ghd.sock"));
        assert_eq!(dir.lock(), Path::new("state/shiibar-ghd.lock"));
        assert_eq!(dir.db(), Path::new("state/state.db"));
    }
}
