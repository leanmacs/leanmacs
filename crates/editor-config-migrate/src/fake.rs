//! The port's fake, published for this crate's tests and for any crate that
//! drives the conversion: a file system in memory ([`FakeFiles`]), which
//! [`contract::check_files`](crate::contract::check_files) holds to the
//! same properties as the real one.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

use crate::ports::{Files, FilesError, Kind};

/// What the fake file system holds at a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    /// A file, with its bytes.
    File(Vec<u8>),
    /// A directory.
    Dir,
}

/// An in-memory file system of files and directories, every path absolute.
/// Its root, `/`, is always there.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FakeFiles {
    nodes: BTreeMap<PathBuf, Node>,
}

impl FakeFiles {
    /// A file system holding only its root.
    pub fn new() -> Self {
        Self::default()
    }

    /// This file system with the directory `path` and those above it.
    ///
    /// # Panics
    ///
    /// When a file is in the way.
    #[must_use]
    pub fn with_dir(mut self, path: impl AsRef<Path>) -> Self {
        self.make_dir(path.as_ref())
            .expect("a directory of the fake");
        self
    }

    /// This file system with the file `path` holding `bytes`, and the
    /// directories above it.
    ///
    /// # Panics
    ///
    /// When a file is in the way of its directory.
    #[must_use]
    pub fn with_file(mut self, path: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> Self {
        let path = path.as_ref();
        if let Some(parent) = path.parent() {
            self.make_dir(parent).expect("a directory of the fake");
        }
        self.write(path, bytes.as_ref())
            .expect("a file of the fake");
        self
    }

    /// Every path the file system holds but its root, with what is there,
    /// in the order of their paths, for a test to assert on.
    pub fn nodes(&self) -> &BTreeMap<PathBuf, Node> {
        &self.nodes
    }

    fn at(&self, path: &Path) -> Option<&Node> {
        if path == Path::new("/") {
            Some(&Node::Dir)
        } else {
            self.nodes.get(path)
        }
    }

    fn absolute(path: &Path) -> Result<(), FilesError> {
        if path.is_absolute() {
            Ok(())
        } else {
            Err(FilesError::new(path, "not an absolute path"))
        }
    }

    fn parent_is_dir(&self, path: &Path) -> Result<(), FilesError> {
        match path.parent().map(|p| self.at(p)) {
            Some(Some(Node::Dir)) => Ok(()),
            _ => Err(FilesError::new(path, "no such directory")),
        }
    }
}

impl Files for FakeFiles {
    fn kind(&self, path: &Path) -> Result<Kind, FilesError> {
        Self::absolute(path)?;
        Ok(match self.at(path) {
            None => Kind::Nothing,
            Some(Node::File(_)) => Kind::File,
            Some(Node::Dir) => Kind::Directory,
        })
    }

    fn names(&self, dir: &Path) -> Result<Vec<OsString>, FilesError> {
        Self::absolute(dir)?;
        if self.at(dir) != Some(&Node::Dir) {
            return Err(FilesError::new(dir, "not a directory"));
        }
        let mut names: Vec<OsString> = self
            .nodes
            .keys()
            .filter(|path| path.parent() == Some(dir))
            .filter_map(|path| path.file_name().map(ToOwned::to_owned))
            .collect();
        names.sort_by(|a, b| a.as_encoded_bytes().cmp(b.as_encoded_bytes()));
        Ok(names)
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, FilesError> {
        Self::absolute(path)?;
        match self.at(path) {
            Some(Node::File(bytes)) => Ok(bytes.clone()),
            Some(Node::Dir) => Err(FilesError::new(path, "a directory")),
            None => Err(FilesError::new(path, "no such file")),
        }
    }

    fn write(&mut self, path: &Path, bytes: &[u8]) -> Result<(), FilesError> {
        Self::absolute(path)?;
        self.parent_is_dir(path)?;
        if self.at(path) == Some(&Node::Dir) {
            return Err(FilesError::new(path, "a directory is there"));
        }
        self.nodes
            .insert(path.to_owned(), Node::File(bytes.to_vec()));
        Ok(())
    }

    fn make_dir(&mut self, path: &Path) -> Result<(), FilesError> {
        Self::absolute(path)?;
        let mut at = PathBuf::from("/");
        for part in path.iter().skip(1) {
            at.push(part);
            match self.nodes.get(&at) {
                None => {
                    self.nodes.insert(at.clone(), Node::Dir);
                }
                Some(Node::Dir) => {}
                Some(Node::File(_)) => return Err(FilesError::new(path, "a file is in the way")),
            }
        }
        Ok(())
    }

    fn remove(&mut self, path: &Path) -> Result<(), FilesError> {
        Self::absolute(path)?;
        match self.at(path) {
            Some(Node::File(_)) => {
                self.nodes.remove(path);
                Ok(())
            }
            Some(Node::Dir) => Err(FilesError::new(path, "a directory")),
            None => Err(FilesError::new(path, "no such file")),
        }
    }

    fn rename(&mut self, from: &Path, to: &Path) -> Result<(), FilesError> {
        let bytes = self.read(from)?;
        self.write(to, &bytes)?;
        if from != to {
            self.nodes.remove(from);
        }
        Ok(())
    }
}
