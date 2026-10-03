//! Approving what plugins may use. A plugin from outside the folders Greed
//! ships that declares capabilities loads only once you've approved them.
//! Approvals are kept per plugin folder with the capabilities approved, so
//! a plugin asking for more waits again. Without a store, as in tests,
//! every plugin loads.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use super::capabilities::Grant;

/// The approvals file, and the folders whose plugins need none.
pub(crate) struct Approvals {
    path: PathBuf,
    shipped: Vec<PathBuf>,
    /// Approved capabilities, by plugin folder.
    approved: BTreeMap<String, BTreeSet<String>>,
}

impl Approvals {
    /// Reads the approvals in `path`; a missing or broken file approves
    /// nothing.
    pub fn load(path: PathBuf, shipped: Vec<PathBuf>) -> Approvals {
        let approved = std::fs::read_to_string(&path)
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let shipped = shipped
            .into_iter()
            .map(|dir| dir.canonicalize().unwrap_or(dir))
            .collect();
        Approvals {
            path,
            shipped,
            approved,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The capabilities the plugin in `dir` asks for that aren't approved,
    /// sorted; empty when it may load.
    pub fn missing(&self, dir: &Path, grant: &Grant) -> Vec<String> {
        let Grant::Only(asked) = grant else {
            return Vec::new();
        };
        if self.shipped.iter().any(|shipped| dir.starts_with(shipped)) {
            return Vec::new();
        }
        let approved = self.approved.get(&*dir.to_string_lossy());
        asked
            .iter()
            .filter(|c| approved.is_none_or(|a| !a.contains(*c)))
            .cloned()
            .collect()
    }

    /// Approves `capabilities` for the plugin in `dir`, adding to what was
    /// approved before, and writes the file.
    pub fn approve(&mut self, dir: &Path, capabilities: &BTreeSet<String>) -> std::io::Result<()> {
        self.approved
            .entry(dir.to_string_lossy().into_owned())
            .or_default()
            .extend(capabilities.iter().cloned());
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(&self.approved).map_err(std::io::Error::other)?;
        // Written whole and moved into place, so a crash never leaves half.
        let partial = self.path.with_extension("json.partial");
        std::fs::write(&partial, text)?;
        std::fs::rename(&partial, &self.path)
    }

    /// Whether `path` is the approvals file, which plugins may not write
    /// through Greed's API.
    pub fn protects(&self, path: &Path) -> bool {
        same_file(path, &self.path)
    }
}

/// Fails if `path` is the approvals file, so no plugin approves itself by
/// writing it.
pub(super) fn guard(lua: &mlua::Lua, path: &Path) -> mlua::Result<()> {
    let state = super::state(lua);
    if state.approvals.as_ref().is_some_and(|a| a.protects(path)) {
        return Err(mlua::Error::runtime(
            "plugins can't write Greed's approvals; :plugins-approve does",
        ));
    }
    Ok(())
}

/// Whether `a` and `b` name the same file: with their folders resolved where
/// they exist, so another spelling of the same file counts, and as written
/// where they don't yet.
pub(super) fn same_file(a: &Path, b: &Path) -> bool {
    let resolved = |p: &Path| {
        let absolute = std::path::absolute(p).unwrap_or_else(|_| p.to_owned());
        absolute
            .parent()
            .and_then(|dir| dir.canonicalize().ok())
            .zip(absolute.file_name())
            .map(|(dir, name)| dir.join(name))
            .unwrap_or(absolute)
    };
    resolved(a) == resolved(b)
}
