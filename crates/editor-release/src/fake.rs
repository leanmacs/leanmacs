//! The ports' fakes, published for this crate's tests and for any crate
//! that drives the core: an environment that is a map ([`FakeEnv`]), a
//! process that records each invocation and answers from a closure
//! ([`RecordingProcess`]), and a file system in memory ([`FakeFiles`]).
//!
//! [`contract::answers`](crate::contract::answers) is what the system does
//! with each of the contract's invocations, so the contract runs on a
//! [`RecordingProcess`] over it as on the real adapter; and
//! [`contract::check_files`](crate::contract::check_files) runs on
//! [`FakeFiles`] as on the real file system.

use std::collections::{BTreeMap, HashMap};
use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};

use crate::ports::{Entry, EntryKind, Env, Files, FilesError, Invocation, Kind, Process, RunError};

/// What the fake file system holds at a path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    /// A file: its bytes, and whether its executable bits are set.
    File {
        /// Its bytes.
        bytes: Vec<u8>,
        /// Whether its executable bits are set.
        executable: bool,
    },
    /// A directory.
    Dir,
    /// A symbolic link, with its target text.
    Link(PathBuf),
}

/// An in-memory file system of files, directories and links, every path
/// absolute. It resolves links as the system does: a link's relative
/// target from the link's directory, every link on the way to a path, and
/// the last one too when an operation follows it. A link that leads round
/// more than forty times is an error, as `ELOOP` is.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FakeFiles {
    nodes: BTreeMap<PathBuf, Node>,
}

/// How many links one resolution may pass through, as `MAXSYMLINKS`.
const MAX_LINKS: usize = 40;

/// One step of a path still to resolve.
enum Step {
    Root,
    Up,
    Name(OsString),
}

fn steps(path: &Path) -> Vec<Step> {
    path.components()
        .filter_map(|c| match c {
            Component::RootDir | Component::Prefix(_) => Some(Step::Root),
            Component::CurDir => None,
            Component::ParentDir => Some(Step::Up),
            Component::Normal(name) => Some(Step::Name(name.to_owned())),
        })
        .collect()
}

impl FakeFiles {
    /// A file system holding only its root, `/`.
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

    /// This file system with the file `path`, not executable, holding
    /// `bytes`, and the directories above it.
    ///
    /// # Panics
    ///
    /// When a file is in the way of its directory.
    #[must_use]
    pub fn with_file(self, path: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> Self {
        self.with_node(path.as_ref(), bytes.as_ref(), false)
    }

    /// This file system with the executable file `path` holding `bytes`,
    /// and the directories above it.
    ///
    /// # Panics
    ///
    /// When a file is in the way of its directory.
    #[must_use]
    pub fn with_executable(self, path: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> Self {
        self.with_node(path.as_ref(), bytes.as_ref(), true)
    }

    /// This file system with a link at `link` whose target text is
    /// `target`, and the directories above it.
    ///
    /// # Panics
    ///
    /// When something is at `link`, or a file is in the way.
    #[must_use]
    pub fn with_link(mut self, link: impl AsRef<Path>, target: impl AsRef<Path>) -> Self {
        let link = link.as_ref();
        if let Some(parent) = link.parent() {
            self.make_dir(parent).expect("a directory of the fake");
        }
        self.symlink(target.as_ref(), link)
            .expect("a link of the fake");
        self
    }

    fn with_node(mut self, path: &Path, bytes: &[u8], executable: bool) -> Self {
        if let Some(parent) = path.parent() {
            self.make_dir(parent).expect("a directory of the fake");
        }
        self.write(path, bytes, executable)
            .expect("a file of the fake");
        self
    }

    /// What is at `path` itself, a link not followed, for a test to assert
    /// on: `None` when nothing is.
    pub fn node(&self, path: impl AsRef<Path>) -> Option<&Node> {
        self.nodes.get(path.as_ref())
    }

    /// Every path the file system holds but its root, with what is there,
    /// in the order of their paths, for a test to assert on.
    pub fn nodes(&self) -> &BTreeMap<PathBuf, Node> {
        &self.nodes
    }

    /// `path` with every link on the way resolved, and the last one too
    /// when `follow` is set.
    fn resolve(&self, path: &Path, follow: bool) -> Result<PathBuf, FilesError> {
        if !path.is_absolute() {
            return Err(FilesError::new(path, "not an absolute path"));
        }
        let mut pending: Vec<Step> = steps(path).into_iter().rev().collect();
        let mut at = PathBuf::from("/");
        let mut links = 0;
        while let Some(step) = pending.pop() {
            match step {
                Step::Root => at = PathBuf::from("/"),
                Step::Up => {
                    at.pop();
                }
                Step::Name(name) => {
                    let next = at.join(&name);
                    match self.nodes.get(&next) {
                        Some(Node::Link(target)) if follow || !pending.is_empty() => {
                            links += 1;
                            if links > MAX_LINKS {
                                return Err(FilesError::new(path, "too many levels of links"));
                            }
                            pending.extend(steps(target).into_iter().rev());
                        }
                        _ => at = next,
                    }
                }
            }
        }
        Ok(at)
    }

    fn at(&self, path: &Path) -> Option<&Node> {
        if path == Path::new("/") {
            Some(&Node::Dir)
        } else {
            self.nodes.get(path)
        }
    }

    /// The directory a new entry at the resolved `path` goes in must be
    /// there.
    fn parent_is_dir(&self, path: &Path, shown: &Path) -> Result<(), FilesError> {
        match path.parent().map(|p| self.at(p)) {
            Some(Some(Node::Dir)) => Ok(()),
            _ => Err(FilesError::new(shown, "no such directory")),
        }
    }
}

impl Files for FakeFiles {
    fn kind(&self, path: &Path) -> Result<Kind, FilesError> {
        let resolved = self.resolve(path, true)?;
        Ok(match self.at(&resolved) {
            None => Kind::Nothing,
            Some(Node::File { executable, .. }) => Kind::File {
                executable: *executable,
            },
            Some(Node::Dir) => Kind::Directory,
            Some(Node::Link(_)) => return Err(FilesError::new(path, "a link left unresolved")),
        })
    }

    fn entries(&self, dir: &Path) -> Result<Vec<Entry>, FilesError> {
        let resolved = self.resolve(dir, true)?;
        if self.at(&resolved) != Some(&Node::Dir) {
            return Err(FilesError::new(dir, "not a directory"));
        }
        let mut entries: Vec<Entry> = self
            .nodes
            .iter()
            .filter(|(path, _)| path.parent() == Some(resolved.as_path()))
            .filter_map(|(path, node)| {
                Some(Entry {
                    name: path.file_name()?.to_owned(),
                    kind: match node {
                        Node::File { executable, .. } => EntryKind::File {
                            executable: *executable,
                        },
                        Node::Dir => EntryKind::Directory,
                        Node::Link(_) => EntryKind::Link,
                    },
                })
            })
            .collect();
        entries.sort_by(|a, b| a.name.as_encoded_bytes().cmp(b.name.as_encoded_bytes()));
        Ok(entries)
    }

    fn read_link(&self, path: &Path) -> Result<PathBuf, FilesError> {
        match self.at(&self.resolve(path, false)?) {
            Some(Node::Link(target)) => Ok(target.clone()),
            _ => Err(FilesError::new(path, "not a link")),
        }
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, FilesError> {
        match self.at(&self.resolve(path, true)?) {
            Some(Node::File { bytes, .. }) => Ok(bytes.clone()),
            Some(_) => Err(FilesError::new(path, "not a file")),
            None => Err(FilesError::new(path, "no such file")),
        }
    }

    fn write(&mut self, path: &Path, bytes: &[u8], executable: bool) -> Result<(), FilesError> {
        let resolved = self.resolve(path, true)?;
        self.parent_is_dir(&resolved, path)?;
        if let Some(Node::Dir) = self.at(&resolved) {
            return Err(FilesError::new(path, "a directory is there"));
        }
        self.nodes.insert(
            resolved,
            Node::File {
                bytes: bytes.to_vec(),
                executable,
            },
        );
        Ok(())
    }

    fn make_dir(&mut self, path: &Path) -> Result<(), FilesError> {
        let resolved = self.resolve(path, true)?;
        let mut at = PathBuf::from("/");
        for step in steps(&resolved) {
            if let Step::Name(name) = step {
                at.push(name);
                match self.nodes.get(&at) {
                    None => {
                        self.nodes.insert(at.clone(), Node::Dir);
                    }
                    Some(Node::Dir) => {}
                    Some(_) => return Err(FilesError::new(path, "a file is in the way")),
                }
            }
        }
        Ok(())
    }

    fn copy(&mut self, from: &Path, to: &Path) -> Result<(), FilesError> {
        let Some(Node::File { bytes, executable }) = self.at(&self.resolve(from, true)?).cloned()
        else {
            return Err(FilesError::new(from, "not a file"));
        };
        self.write(to, &bytes, executable)
    }

    fn symlink(&mut self, target: &Path, link: &Path) -> Result<(), FilesError> {
        let resolved = self.resolve(link, false)?;
        self.parent_is_dir(&resolved, link)?;
        if self.at(&resolved).is_some() {
            return Err(FilesError::new(link, "something is there"));
        }
        self.nodes.insert(resolved, Node::Link(target.to_owned()));
        Ok(())
    }
}

/// An environment that is a map of names to values; a name it does not
/// hold is unset.
#[derive(Debug, Clone, Default)]
pub struct FakeEnv(pub HashMap<String, OsString>);

impl FakeEnv {
    /// This environment with `name` set to `value`.
    #[must_use]
    pub fn with(mut self, name: &str, value: impl Into<OsString>) -> Self {
        self.0.insert(name.to_owned(), value.into());
        self
    }
}

impl Env for FakeEnv {
    fn var(&self, name: &str) -> Option<OsString> {
        self.0.get(name).cloned()
    }
}

/// A process that records every invocation, in order, and answers each
/// with what `respond` returns for it.
pub struct RecordingProcess<F> {
    /// Every invocation run, in order.
    pub runs: Vec<Invocation>,
    respond: F,
}

impl<F> RecordingProcess<F>
where
    F: FnMut(&Invocation) -> Result<Vec<u8>, RunError>,
{
    /// A process that has run nothing yet.
    pub fn new(respond: F) -> Self {
        Self {
            runs: Vec::new(),
            respond,
        }
    }
}

impl<F> Process for RecordingProcess<F>
where
    F: FnMut(&Invocation) -> Result<Vec<u8>, RunError>,
{
    fn run(&mut self, invocation: &Invocation) -> Result<Vec<u8>, RunError> {
        self.runs.push(invocation.clone());
        (self.respond)(invocation)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fake_env_holds_what_it_was_given_and_nothing_else() {
        let env = FakeEnv::default().with("A", "1");
        assert_eq!(env.var("A"), Some("1".into()));
        assert_eq!(env.var("B"), None);
    }

    #[test]
    fn the_recording_process_records_in_order_and_answers_from_its_closure() {
        let mut process = RecordingProcess::new(|i: &Invocation| {
            if i.program == "true" {
                Ok(Vec::new())
            } else {
                Err(RunError::Failed(Some(1)))
            }
        });
        assert_eq!(process.run(&Invocation::new("true")), Ok(Vec::new()));
        assert_eq!(
            process.run(&Invocation::new("false")),
            Err(RunError::Failed(Some(1)))
        );
        assert_eq!(
            process.runs,
            vec![Invocation::new("true"), Invocation::new("false")]
        );
    }
}
