//! The real [`Locate`]: `cargo metadata`.

use crate::not_a_dependency;
use crate::ports::Locate;
use serde_json::Value;
use std::cell::OnceCell;
use std::path::{Path, PathBuf};

/// Finds a dependency's directory with `cargo metadata`, run once and kept:
/// `<cargo> metadata --format-version 1 --locked --filter-platform <target>
/// --manifest-path <manifest>`. A name is resolved through the calling
/// package's own node of the resolve, so the version found is the one the
/// lock pins for it, whichever other versions the graph holds. `--locked`
/// keeps the lock as it is; Cargo fetches a locked package it lacks, which
/// is all that is ever fetched. Every input is an argument: it reads no
/// variable.
#[derive(Debug)]
pub struct CargoMetadata {
    cargo: PathBuf,
    target: String,
    manifest: PathBuf,
    package: String,
    metadata: OnceCell<Result<Value, String>>,
}

impl CargoMetadata {
    /// A locator for the package `package`, whose manifest is `manifest`,
    /// asking the Cargo at `cargo` for the graph of the target `target`.
    pub fn new(
        cargo: impl Into<PathBuf>,
        target: &str,
        manifest: impl Into<PathBuf>,
        package: &str,
    ) -> Self {
        Self {
            cargo: cargo.into(),
            target: target.to_owned(),
            manifest: manifest.into(),
            package: package.to_owned(),
            metadata: OnceCell::new(),
        }
    }

    fn metadata(&self) -> Result<&Value, String> {
        self.metadata
            .get_or_init(|| run_metadata(&self.cargo, &self.target, &self.manifest))
            .as_ref()
            .map_err(Clone::clone)
    }
}

impl Locate for CargoMetadata {
    fn locate(&self, package: &str) -> Result<PathBuf, String> {
        let metadata = self.metadata()?;
        dependency_dir(metadata, &self.package, package)
            .ok_or_else(|| not_a_dependency(package, &self.package))
    }
}

/// Runs `cargo metadata` and reads its JSON.
fn run_metadata(cargo: &Path, target: &str, manifest: &Path) -> Result<Value, String> {
    #[expect(
        clippy::disallowed_methods,
        reason = "the locator's adapter asks the real Cargo for the dependency graph; a build script has no other way to find a dependency's directory"
    )]
    let mut command = std::process::Command::new(cargo);
    command
        .args(["metadata", "--format-version", "1", "--locked"])
        .args(["--filter-platform", target])
        .arg("--manifest-path")
        .arg(manifest);
    let ran = command
        .output()
        .map_err(|error| format!("running {command:?}: {error}"))?;
    if !ran.status.success() {
        return Err(format!(
            "{command:?} failed: {}",
            String::from_utf8_lossy(&ran.stderr).trim()
        ));
    }
    serde_json::from_slice(&ran.stdout)
        .map_err(|error| format!("reading the output of {command:?}: {error}"))
}

/// The directory of the package named `wanted` that the workspace member
/// named `caller` depends on, read from `cargo metadata`'s JSON: the
/// caller's id among the workspace's members, its node of the resolve, the
/// dependency of that node whose package is named `wanted`, and that
/// package's manifest's directory. None when any of them is missing.
fn dependency_dir(metadata: &Value, caller: &str, wanted: &str) -> Option<PathBuf> {
    let packages = metadata.get("packages")?.as_array()?;
    let package_of = |id: &str| {
        packages
            .iter()
            .find(|package| package.get("id").and_then(Value::as_str) == Some(id))
    };
    let name_of = |id: &str| {
        package_of(id)
            .and_then(|package| package.get("name"))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let caller_id = metadata
        .get("workspace_members")?
        .as_array()?
        .iter()
        .filter_map(Value::as_str)
        .find(|id| name_of(id).as_deref() == Some(caller))?;
    let node = metadata
        .get("resolve")?
        .get("nodes")?
        .as_array()?
        .iter()
        .find(|node| node.get("id").and_then(Value::as_str) == Some(caller_id))?;
    let dependency = node
        .get("deps")?
        .as_array()?
        .iter()
        .filter_map(|dep| dep.get("pkg").and_then(Value::as_str))
        .find(|id| name_of(id).as_deref() == Some(wanted))?;
    let manifest = package_of(dependency)?.get("manifest_path")?.as_str()?;
    Path::new(manifest).parent().map(Path::to_path_buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape of `cargo metadata`'s JSON, cut to what is read: a
    /// workspace member `caller` that depends on `grammar` 0.2.0, while
    /// another member depends on `grammar` 0.1.0.
    fn metadata() -> Value {
        serde_json::json!({
            "packages": [
                { "id": "path+file:///w/caller#0.1.0", "name": "caller",
                  "manifest_path": "/w/caller/Cargo.toml" },
                { "id": "path+file:///w/other#0.1.0", "name": "other",
                  "manifest_path": "/w/other/Cargo.toml" },
                { "id": "registry+x#grammar@0.1.0", "name": "grammar",
                  "manifest_path": "/reg/grammar-0.1.0/Cargo.toml" },
                { "id": "registry+x#grammar@0.2.0", "name": "grammar",
                  "manifest_path": "/reg/grammar-0.2.0/Cargo.toml" },
            ],
            "workspace_members": ["path+file:///w/caller#0.1.0", "path+file:///w/other#0.1.0"],
            "resolve": { "nodes": [
                { "id": "path+file:///w/caller#0.1.0",
                  "deps": [{ "name": "grammar", "pkg": "registry+x#grammar@0.2.0" }] },
                { "id": "path+file:///w/other#0.1.0",
                  "deps": [{ "name": "grammar", "pkg": "registry+x#grammar@0.1.0" }] },
            ] }
        })
    }

    #[test]
    fn a_dependency_is_found_through_the_callers_own_node() {
        assert_eq!(
            dependency_dir(&metadata(), "caller", "grammar"),
            Some(PathBuf::from("/reg/grammar-0.2.0"))
        );
        assert_eq!(
            dependency_dir(&metadata(), "other", "grammar"),
            Some(PathBuf::from("/reg/grammar-0.1.0"))
        );
    }

    #[test]
    fn a_name_that_is_no_dependency_of_the_caller_is_not_found() {
        assert_eq!(dependency_dir(&metadata(), "caller", "other"), None);
        assert_eq!(dependency_dir(&metadata(), "nobody", "grammar"), None);
    }
}
