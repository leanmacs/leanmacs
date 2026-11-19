//! The fake of the port: a tree of files in memory, published so that
//! everything above the port is tested with no real file.
//!
//! [`FakeFiles`] keeps a set of directories and files, and a set of paths a
//! test excluded ([`FakeFiles::excluded`]), standing in for the ignore
//! files a real adapter reads. It keeps the port's rules itself, which
//! [`contract::check`](crate::contract::check) holds it to: the walk's
//! order, the hidden-file rule, a file with a NUL byte read as binary, rows
//! split at line feeds and decoded lossily.
//!
//! Clones share one tree, and its ground ([`FakeFiles::ground`]) changes
//! it, so a test can change files while a search holds the fake.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use crate::contract::Ground;
use crate::{Files, Flow, Read, Refusal, RefusalKind, Row};

/// What the fake holds.
#[derive(Debug, Default)]
struct Tree {
    /// Each file's bytes, by its path.
    files: BTreeMap<PathBuf, Vec<u8>>,
    /// Each directory, the ones above a file among them.
    directories: BTreeSet<PathBuf>,
    /// The paths a test excluded.
    excluded: BTreeSet<PathBuf>,
}

impl Tree {
    /// Makes `path` and every directory above it a directory.
    fn make_dir(&mut self, path: &Path) {
        for ancestor in path.ancestors() {
            if ancestor.as_os_str().is_empty() {
                break;
            }
            self.directories.insert(ancestor.to_path_buf());
        }
    }
}

/// An entry under a walked root, as [`FakeFiles::listing`] gives it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Entry {
    /// Its path relative to the root.
    pub(crate) relative: PathBuf,
    /// Whether it is a directory.
    pub(crate) directory: bool,
    /// Whether its name, or a name above it under the root, starts with
    /// `.`.
    pub(crate) hidden: bool,
    /// Whether it, or a directory above it, was excluded.
    pub(crate) excluded: bool,
}

/// A tree of files in memory. A cheap handle: clones share one tree.
#[derive(Debug, Clone, Default)]
pub struct FakeFiles {
    /// The tree.
    tree: Arc<Mutex<Tree>>,
}

impl FakeFiles {
    /// An empty tree.
    pub fn new() -> Self {
        Self::default()
    }

    /// The tree with a file at `path` holding `bytes`, and the directories
    /// above it.
    #[must_use]
    pub fn file(self, path: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> Self {
        self.ground().write(path.as_ref(), bytes.as_ref());
        self
    }

    /// The tree with `path`, a file or a directory, and everything under it
    /// left out of every walk, as an ignore file would leave it out.
    #[must_use]
    pub fn excluded(self, path: impl AsRef<Path>) -> Self {
        self.ground().exclude(path.as_ref());
        self
    }

    /// What changes the tree, for the contract and for tests that change
    /// files while a search holds the fake.
    pub fn ground(&self) -> FakeGround {
        FakeGround {
            tree: Arc::clone(&self.tree),
        }
    }

    /// Locks the tree.
    fn tree(&self) -> MutexGuard<'_, Tree> {
        self.tree.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The bytes of the file at `path`, if there is one.
    pub fn bytes(&self, path: &Path) -> Option<Vec<u8>> {
        self.tree().files.get(path).cloned()
    }

    /// Every entry under `root`, in the walk's order, with what the walk
    /// decides each by: a refusal when `root` is not a directory.
    pub(crate) fn listing(&self, root: &Path) -> Result<Vec<Entry>, Refusal> {
        let tree = self.tree();
        if !tree.directories.contains(root) {
            let kind = if tree.files.contains_key(root) {
                RefusalKind::NotADirectory
            } else {
                RefusalKind::NotFound
            };
            return Err(Refusal::new(
                kind,
                format!("cannot search {}", root.display()),
            ));
        }
        // A path's order is its components', each by its bytes: depth
        // first, each directory's entries by name.
        let mut entries: BTreeMap<PathBuf, bool> = BTreeMap::new();
        for path in tree.files.keys() {
            entries.insert(path.clone(), false);
        }
        for path in &tree.directories {
            entries.insert(path.clone(), true);
        }
        Ok(entries
            .into_iter()
            .filter_map(|(path, directory)| {
                let relative = path.strip_prefix(root).ok()?.to_path_buf();
                if relative.as_os_str().is_empty() {
                    return None;
                }
                let hidden = relative
                    .components()
                    .any(|part| part.as_os_str().as_encoded_bytes().first() == Some(&b'.'));
                let excluded = path
                    .ancestors()
                    .take_while(|ancestor| *ancestor != root)
                    .any(|ancestor| tree.excluded.contains(ancestor));
                Some(Entry {
                    relative,
                    directory,
                    hidden,
                    excluded,
                })
            })
            .collect())
    }
}

impl Files for FakeFiles {
    fn walk(&mut self, root: &Path, visit: &mut dyn FnMut(&Path) -> Flow) -> Result<(), Refusal> {
        let walked = self
            .listing(root)?
            .into_iter()
            .filter(|entry| !entry.directory && !entry.hidden && !entry.excluded);
        for entry in walked {
            if visit(&entry.relative) == Flow::Stop {
                break;
            }
        }
        Ok(())
    }

    fn rows(
        &mut self,
        path: &Path,
        holds: &mut dyn FnMut(&str) -> bool,
        visit: &mut dyn FnMut(Row<'_>) -> Flow,
    ) -> Result<Read, Refusal> {
        let Some(bytes) = self.bytes(path) else {
            let kind = if self.tree().directories.contains(path) {
                RefusalKind::Failed
            } else {
                RefusalKind::NotFound
            };
            return Err(Refusal::new(
                kind,
                format!("cannot read {}", path.display()),
            ));
        };
        if bytes.contains(&0) {
            return Ok(Read::Binary);
        }
        let mut offset = 0;
        for (number, piece) in bytes.split(|&byte| byte == b'\n').enumerate() {
            let start = offset;
            offset += piece.len() + 1;
            // A line feed at the end, or none at all, makes no row after it.
            if start == bytes.len() {
                break;
            }
            let text = String::from_utf8_lossy(piece);
            if holds(&text)
                && visit(Row {
                    number,
                    offset: start,
                    text: &text,
                }) == Flow::Stop
            {
                break;
            }
        }
        Ok(Read::Searched)
    }
}

/// What changes a [`FakeFiles`]'s tree: the ground the contract makes its
/// files on.
#[derive(Debug, Clone)]
pub struct FakeGround {
    /// The tree it changes.
    tree: Arc<Mutex<Tree>>,
}

impl FakeGround {
    /// Locks the tree.
    fn tree(&self) -> MutexGuard<'_, Tree> {
        self.tree.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Removes the file at `path`, if there is one.
    pub fn remove(&self, path: &Path) {
        self.tree().files.remove(path);
    }
}

impl Ground for FakeGround {
    fn write(&self, path: &Path, bytes: &[u8]) {
        let mut tree = self.tree();
        if let Some(parent) = path.parent() {
            tree.make_dir(parent);
        }
        tree.files.insert(path.to_path_buf(), bytes.to_vec());
    }

    fn make_dir(&self, path: &Path) {
        self.tree().make_dir(path);
    }

    fn exclude(&self, path: &Path) {
        self.tree().excluded.insert(path.to_path_buf());
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use super::FakeFiles;
    use crate::{Files, Flow, Read, RefusalKind};

    fn walked(files: &mut FakeFiles, root: &str) -> Vec<PathBuf> {
        let mut seen = Vec::new();
        files
            .walk(Path::new(root), &mut |path| {
                seen.push(path.to_path_buf());
                Flow::Go
            })
            .expect("walked");
        seen
    }

    #[test]
    fn a_tree_built_with_files_and_exclusions_is_walked_by_its_rules() {
        let mut files = FakeFiles::new()
            .file("/w/b.txt", "b")
            .file("/w/a/x.txt", "x")
            .file("/w/.hidden", "h")
            .file("/w/gen/y", "y")
            .file("/elsewhere/z", "z")
            .excluded("/w/gen");

        assert_eq!(
            walked(&mut files, "/w"),
            [PathBuf::from("a/x.txt"), PathBuf::from("b.txt")]
        );
    }

    #[test]
    fn a_hidden_or_excluded_root_is_walked_itself() {
        let mut files = FakeFiles::new()
            .file("/w/.config/a", "a")
            .excluded("/w/.config");

        assert_eq!(walked(&mut files, "/w/.config"), [PathBuf::from("a")]);
    }

    #[test]
    fn a_file_that_is_not_there_is_not_found_and_a_directory_is_not_read() {
        let mut files = FakeFiles::new().file("/w/a", "a");
        let kind = |files: &mut FakeFiles, path: &str| {
            files
                .rows(Path::new(path), &mut |_| true, &mut |_| Flow::Go)
                .unwrap_err()
                .kind
        };

        assert_eq!(kind(&mut files, "/w/b"), RefusalKind::NotFound);
        assert_eq!(kind(&mut files, "/w"), RefusalKind::Failed);
        assert_eq!(
            files.rows(Path::new("/w/a"), &mut |_| true, &mut |_| Flow::Go),
            Ok(Read::Searched)
        );
    }

    #[test]
    fn clones_share_one_tree_and_the_ground_changes_it() {
        let files = FakeFiles::new().file("/w/a", "a");
        let mut clone = files.clone();
        files.ground().remove(Path::new("/w/a"));

        assert!(walked(&mut clone, "/w").is_empty());
    }
}
