//! The fake of the file port: a file system in memory.
//!
//! A test builds one ([`FakeFs::directory`], [`FakeFs::file`],
//! [`FakeFs::link`], [`FakeFs::other`]), hands it to what it tests as an
//! [`Fs`], and reads what is left ([`FakeFs::bytes`], [`FakeFs::paths`])
//! and what was asked ([`FakeFs::calls`]). It is published, and not
//! `cfg(test)`, so that every crate that tests against the port uses this
//! one fake; [`contract::check`](super::contract::check) holds it to the
//! port's rules.
//!
//! - **Its time is the one a test sets.** A file made by [`FakeFs::file`]
//!   or by the port's `write` is stamped with the fake's own time, which
//!   only [`FakeFs::set_now`] moves. Two writes with no `set_now` between
//!   them have one modification time: that is a file system whose clock is
//!   coarser than the writes are apart, made on purpose.
//! - **It fails when a test says so**: [`FakeFs::fail`] fails the next call
//!   of one operation, and [`FakeFs::cut_write`] makes the next write stop
//!   partway, leave what it wrote, and fail.
//! - **A test can act between two calls**: [`FakeFs::after`] runs a closure
//!   once, when the next call of one operation has been answered, and
//!   [`FakeFs::on_next_call`] when the next call has been answered,
//!   whichever it is. The closure is given the fake and runs with no lock
//!   held, so it may change files, or block the thread that is asking.
//!
//! What it does not model: a link in the middle of a path (a link is
//! followed only where it is the whole path), a link that holds a path
//! that is not absolute (it is read as it is held, and followed as if the
//! path were absolute, so to nothing), permissions that refuse anything (a
//! test injects the refusal), and directories that are removed. Paths are
//! compared as they are written; nothing is normalised.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};

use super::contract::Ground;
use super::{Entry, Fs, FsError, FsErrorKind, Kind, Modified, Permissions, Pieces, Stat};

/// An operation of the port, for a test to say which call it means
/// ([`FakeFs::fail`], [`FakeFs::after`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    /// [`Fs::stat`].
    Stat,
    /// [`Fs::read`].
    Read,
    /// [`Fs::write`].
    Write,
    /// [`Fs::rename`].
    Rename,
    /// [`Fs::remove`].
    Remove,
    /// [`Fs::resolve`].
    Resolve,
    /// [`Fs::read_link`].
    ReadLink,
    /// [`Fs::list`].
    List,
    /// [`Fs::make_directory`].
    MakeDirectory,
}

/// A call the fake received ([`FakeFs::calls`]), with what it was asked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Call {
    /// [`Fs::stat`] of this path.
    Stat(PathBuf),
    /// [`Fs::read`] of this path.
    Read(PathBuf),
    /// [`Fs::write`] of a file at this path, with these permissions named.
    Write(PathBuf, Option<Permissions>),
    /// [`Fs::rename`] of the first path to the second.
    Rename(PathBuf, PathBuf),
    /// [`Fs::remove`] of this path.
    Remove(PathBuf),
    /// [`Fs::resolve`] of this path.
    Resolve(PathBuf),
    /// [`Fs::read_link`] of this path.
    ReadLink(PathBuf),
    /// [`Fs::list`] of this path.
    List(PathBuf),
    /// [`Fs::make_directory`] of this path.
    MakeDirectory(PathBuf),
}

impl Call {
    /// Which operation the call is of.
    pub fn op(&self) -> Op {
        match self {
            Self::Stat(_) => Op::Stat,
            Self::Read(_) => Op::Read,
            Self::Write(..) => Op::Write,
            Self::Rename(..) => Op::Rename,
            Self::Remove(_) => Op::Remove,
            Self::Resolve(_) => Op::Resolve,
            Self::ReadLink(_) => Op::ReadLink,
            Self::List(_) => Op::List,
            Self::MakeDirectory(_) => Op::MakeDirectory,
        }
    }
}

/// What a test runs between two calls: it is given the fake, with no lock
/// held.
type Hook = Box<dyn FnOnce(&FakeFs) + Send>;

/// How many links one path is followed through before the fake gives up,
/// so that two links that name each other end in a refusal and not a loop.
const LINKS: usize = 16;

/// What is at one path.
#[derive(Clone)]
enum Node {
    /// A file.
    File {
        /// What it holds.
        bytes: Vec<u8>,
        /// When it was written.
        modified: Modified,
        /// Who may do what with it.
        permissions: Permissions,
    },
    /// A directory, made at this instant.
    Directory(Modified),
    /// A link that names this path, which may hold nothing.
    Link(PathBuf),
    /// Something that is neither a file nor a directory, made at this
    /// instant.
    Other(Modified),
}

/// Everything the fake holds, behind its lock.
#[derive(Default)]
struct State {
    /// What is at each path. The root is a directory and is not listed.
    nodes: BTreeMap<PathBuf, Node>,
    /// The fake's time: what a file written now is stamped with.
    now: Modified,
    /// Every call received, in order.
    calls: Vec<Call>,
    /// The failures waiting, each for the next call of its operation.
    failures: Vec<(Op, FsError)>,
    /// How many bytes the next write keeps before it fails, if it is cut.
    cut: Option<usize>,
    /// The hooks waiting, each for the next call of its operation.
    after: Vec<(Op, Hook)>,
    /// The hook waiting for the next call, whichever it is.
    next: Option<Hook>,
}

/// A file system in memory, for tests. The module docs say what it does.
#[derive(Default)]
pub struct FakeFs {
    /// Everything it holds.
    state: Mutex<State>,
}

impl FakeFs {
    /// The permissions of a file made by [`FakeFs::file`], or written
    /// through the port with none named.
    pub const DEFAULT_PERMISSIONS: Permissions = Permissions::new(0o644);

    /// The permissions the fake says a directory has.
    const DIRECTORY_PERMISSIONS: Permissions = Permissions::new(0o755);

    /// A file system that holds nothing but its root, at the instant zero.
    pub fn new() -> Self {
        Self::default()
    }

    /// The state, whatever a panicking test left of the lock.
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Makes a directory at `path`, and every directory on the way to it.
    pub fn directory(&self, path: impl AsRef<Path>) {
        self.lock().make_directories(path.as_ref());
    }

    /// Puts a file holding `bytes` at `path`, in place of whatever is
    /// there, stamped with the fake's time and with
    /// [`FakeFs::DEFAULT_PERMISSIONS`]. The directories on the way to it
    /// are made.
    pub fn file(&self, path: impl AsRef<Path>, bytes: &[u8]) {
        let mut state = self.lock();
        let node = Node::File {
            bytes: bytes.to_vec(),
            modified: state.now,
            permissions: Self::DEFAULT_PERMISSIONS,
        };
        state.put(path.as_ref(), node);
    }

    /// Puts a link at `path` that names `to`, which need not hold anything.
    /// The directories on the way to `path` are made.
    pub fn link(&self, path: impl AsRef<Path>, to: impl AsRef<Path>) {
        let node = Node::Link(to.as_ref().to_path_buf());
        self.lock().put(path.as_ref(), node);
    }

    /// Puts something that is neither a file nor a directory at `path`, as
    /// a pipe or a device is. The directories on the way to it are made.
    pub fn other(&self, path: impl AsRef<Path>) {
        let mut state = self.lock();
        let node = Node::Other(state.now);
        state.put(path.as_ref(), node);
    }

    /// Takes away whatever is at `path`, a directory included, without
    /// following a link. This is a test changing the disk behind the
    /// port's back: it is not a call, and [`FakeFs::calls`] does not list
    /// it.
    pub fn take_away(&self, path: impl AsRef<Path>) {
        self.lock().nodes.remove(path.as_ref());
    }

    /// The fake's time: what a file written now is stamped with.
    pub fn now(&self) -> Modified {
        self.lock().now
    }

    /// Moves the fake's time to `now`. Files already written keep their
    /// stamps.
    pub fn set_now(&self, now: Modified) {
        self.lock().now = now;
    }

    /// Stamps the file `path` names, following links, as modified at `to`,
    /// and says whether a file was there.
    pub fn set_modified(&self, path: impl AsRef<Path>, to: Modified) -> bool {
        let mut state = self.lock();
        match state.file_mut(path.as_ref()) {
            Some(Node::File { modified, .. }) => {
                *modified = to;
                true
            }
            _ => false,
        }
    }

    /// Gives the file `path` names, following links, the permissions `to`,
    /// and says whether a file was there.
    pub fn set_permissions(&self, path: impl AsRef<Path>, to: Permissions) -> bool {
        let mut state = self.lock();
        match state.file_mut(path.as_ref()) {
            Some(Node::File { permissions, .. }) => {
                *permissions = to;
                true
            }
            _ => false,
        }
    }

    /// What the file at `path` holds. `None` when what is there is not a
    /// file; a link is not followed.
    pub fn bytes(&self, path: impl AsRef<Path>) -> Option<Vec<u8>> {
        match self.lock().nodes.get(path.as_ref()) {
            Some(Node::File { bytes, .. }) => Some(bytes.clone()),
            _ => None,
        }
    }

    /// The permissions of the file at `path`. `None` when what is there is
    /// not a file; a link is not followed.
    pub fn permissions(&self, path: impl AsRef<Path>) -> Option<Permissions> {
        match self.lock().nodes.get(path.as_ref()) {
            Some(Node::File { permissions, .. }) => Some(*permissions),
            _ => None,
        }
    }

    /// The path the link at `path` names. `None` when what is there is not a
    /// link.
    pub fn link_target(&self, path: impl AsRef<Path>) -> Option<PathBuf> {
        match self.lock().nodes.get(path.as_ref()) {
            Some(Node::Link(to)) => Some(to.clone()),
            _ => None,
        }
    }

    /// Every path that holds something, directories and links included, in
    /// order. The root is not listed.
    pub fn paths(&self) -> Vec<PathBuf> {
        self.lock().nodes.keys().cloned().collect()
    }

    /// Every call the port has received, in order, a call that was made to
    /// fail included.
    pub fn calls(&self) -> Vec<Call> {
        self.lock().calls.clone()
    }

    /// Makes the next call of `op` fail with `error`, doing nothing. Calls
    /// of other operations are answered as usual meanwhile.
    pub fn fail(&self, op: Op, error: FsError) {
        self.lock().failures.push((op, error));
    }

    /// Makes the next write stop once it has taken `bytes` bytes, leave a
    /// file holding them, and fail.
    pub fn cut_write(&self, bytes: usize) {
        self.lock().cut = Some(bytes);
    }

    /// Runs `hook` once, when the next call of `op` has been answered,
    /// whether it was refused or not, and before the caller has its answer.
    /// It is given the fake and runs with no lock held.
    pub fn after(&self, op: Op, hook: impl FnOnce(&FakeFs) + Send + 'static) {
        self.lock().after.push((op, Box::new(hook)));
    }

    /// Runs `hook` once, when the next call has been answered, whichever
    /// operation it is of, and before the caller has its answer. It is
    /// given the fake and runs with no lock held, on the thread that made
    /// the call: so a hook that waits holds that thread where it is.
    pub fn on_next_call(&self, hook: impl FnOnce(&FakeFs) + Send + 'static) {
        self.lock().next = Some(Box::new(hook));
    }

    /// The ground the contract is checked on: this fake, and the directory
    /// `root` in it, which is made.
    pub fn ground(&self, root: impl AsRef<Path>) -> FakeGround<'_> {
        self.directory(root.as_ref());
        FakeGround {
            fs: self,
            root: root.as_ref().to_path_buf(),
        }
    }

    /// Records `call`, answers it with `answer` unless a failure waits for
    /// its operation, and runs the hooks that wait for it.
    fn call<T>(
        &self,
        call: Call,
        answer: impl FnOnce(&mut State) -> Result<T, FsError>,
    ) -> Result<T, FsError> {
        let op = call.op();
        let (answer, hooks) = {
            let mut state = self.lock();
            state.calls.push(call);
            let failure = state
                .failures
                .iter()
                .position(|(of, _)| *of == op)
                .map(|index| state.failures.remove(index).1);
            let answer = match failure {
                Some(error) => Err(error),
                None => answer(&mut state),
            };
            // The hooks are taken out under the lock and run once it is
            // released, so one may call the fake, or add a hook of its own.
            let after = state
                .after
                .iter()
                .position(|(of, _)| *of == op)
                .map(|index| state.after.remove(index).1);
            let hooks: Vec<Hook> = after.into_iter().chain(state.next.take()).collect();
            (answer, hooks)
        };
        for hook in hooks {
            hook(self);
        }
        answer
    }
}

impl State {
    /// Makes a directory at `path` and at every path on the way to it that
    /// holds nothing.
    fn make_directories(&mut self, path: &Path) {
        let now = self.now;
        for ancestor in path.ancestors() {
            // The root has no parent, and is always there.
            if ancestor.parent().is_some() {
                self.nodes
                    .entry(ancestor.to_path_buf())
                    .or_insert(Node::Directory(now));
            }
        }
    }

    /// Puts `node` at `path`, in place of whatever is there, with the
    /// directories on the way to it.
    fn put(&mut self, path: &Path, node: Node) {
        if let Some(parent) = path.parent() {
            self.make_directories(parent);
        }
        self.nodes.insert(path.to_path_buf(), node);
    }

    /// Where following links from `path` ends, which may hold nothing.
    /// `None` when the links do not end.
    fn follow(&self, path: &Path) -> Option<PathBuf> {
        let mut at = path.to_path_buf();
        for _ in 0..LINKS {
            match self.nodes.get(&at) {
                Some(Node::Link(to)) => at = to.clone(),
                _ => return Some(at),
            }
        }
        None
    }

    /// What `path` names, following links, to change it.
    fn file_mut(&mut self, path: &Path) -> Option<&mut Node> {
        let at = self.follow(path)?;
        self.nodes.get_mut(&at)
    }

    /// Where following links from `path` ends, or the refusal of links
    /// that do not end.
    fn followed(&self, path: &Path) -> Result<PathBuf, FsError> {
        self.follow(path).ok_or_else(|| {
            FsError::new(
                FsErrorKind::Other,
                format!("too many links from {}", path.display()),
            )
        })
    }

    /// Whether `path` is a directory a file can be made in, or why not.
    fn directory_at(&self, path: &Path) -> Result<(), FsError> {
        // The root has no parent, and is always there.
        if path.parent().is_none() {
            return Ok(());
        }
        match self.nodes.get(path) {
            Some(Node::Directory(_)) => Ok(()),
            Some(_) => Err(refused(FsErrorKind::NotAFile, path)),
            None => Err(refused(FsErrorKind::NotFound, path)),
        }
    }

    /// [`Fs::stat`].
    fn stat(&self, path: &Path) -> Result<Option<Stat>, FsError> {
        if path.parent().is_none() {
            return Ok(Some(Stat {
                kind: Kind::Directory,
                size: 0,
                modified: Modified::default(),
                permissions: FakeFs::DIRECTORY_PERMISSIONS,
            }));
        }
        let at = self.followed(path)?;
        Ok(match self.nodes.get(&at) {
            Some(Node::File {
                bytes,
                modified,
                permissions,
            }) => Some(Stat {
                kind: Kind::File,
                size: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
                modified: *modified,
                permissions: *permissions,
            }),
            Some(Node::Directory(modified)) => Some(Stat {
                kind: Kind::Directory,
                size: 0,
                modified: *modified,
                permissions: FakeFs::DIRECTORY_PERMISSIONS,
            }),
            Some(Node::Other(modified)) => Some(Stat {
                kind: Kind::Other,
                size: 0,
                modified: *modified,
                permissions: FakeFs::DEFAULT_PERMISSIONS,
            }),
            // Following ends at something that is no link, or at nothing.
            Some(Node::Link(_)) | None => None,
        })
    }

    /// [`Fs::read`].
    fn read(&self, path: &Path) -> Result<Vec<u8>, FsError> {
        let at = self.followed(path)?;
        match self.nodes.get(&at) {
            Some(Node::File { bytes, .. }) => Ok(bytes.clone()),
            Some(Node::Directory(_) | Node::Other(_)) => Err(refused(FsErrorKind::NotAFile, path)),
            Some(Node::Link(_)) | None if path.parent().is_none() => {
                Err(refused(FsErrorKind::NotAFile, path))
            }
            Some(Node::Link(_)) | None => Err(refused(FsErrorKind::NotFound, path)),
        }
    }

    /// [`Fs::write`].
    fn write(
        &mut self,
        path: &Path,
        pieces: &mut Pieces<'_>,
        permissions: Option<Permissions>,
    ) -> Result<(), FsError> {
        let Some(parent) = path.parent() else {
            return Err(refused(FsErrorKind::Exists, path));
        };
        if self.nodes.contains_key(path) {
            return Err(refused(FsErrorKind::Exists, path));
        }
        self.directory_at(parent)?;
        // Only a write that gets this far is cut: one refused above wrote
        // nothing, and the cut waits for the next.
        let cut = self.cut.take();
        let mut bytes = Vec::new();
        for piece in pieces {
            bytes.extend_from_slice(&piece);
            if cut.is_some_and(|cut| bytes.len() >= cut) {
                break;
            }
        }
        if let Some(cut) = cut {
            bytes.truncate(cut);
        }
        let node = Node::File {
            bytes,
            modified: self.now,
            permissions: permissions.unwrap_or(FakeFs::DEFAULT_PERMISSIONS),
        };
        self.nodes.insert(path.to_path_buf(), node);
        match cut {
            Some(cut) => Err(FsError::new(
                FsErrorKind::Other,
                format!("the write was cut after {cut} bytes"),
            )),
            None => Ok(()),
        }
    }

    /// [`Fs::rename`].
    fn rename(&mut self, from: &Path, to: &Path) -> Result<(), FsError> {
        match self.nodes.get(from) {
            None => return Err(refused(FsErrorKind::NotFound, from)),
            Some(Node::Directory(_)) => return Err(refused(FsErrorKind::NotAFile, from)),
            Some(_) => {}
        }
        let Some(parent) = to.parent() else {
            return Err(refused(FsErrorKind::NotAFile, to));
        };
        self.directory_at(parent)?;
        if matches!(self.nodes.get(to), Some(Node::Directory(_))) {
            return Err(refused(FsErrorKind::NotAFile, to));
        }
        if let Some(node) = self.nodes.remove(from) {
            self.nodes.insert(to.to_path_buf(), node);
        }
        Ok(())
    }

    /// [`Fs::remove`].
    fn remove(&mut self, path: &Path) -> Result<(), FsError> {
        match self.nodes.get(path) {
            None if path.parent().is_none() => Err(refused(FsErrorKind::NotAFile, path)),
            None => Err(refused(FsErrorKind::NotFound, path)),
            Some(Node::Directory(_)) => Err(refused(FsErrorKind::NotAFile, path)),
            Some(_) => {
                self.nodes.remove(path);
                Ok(())
            }
        }
    }

    /// [`Fs::resolve`].
    fn resolve(&self, path: &Path) -> Result<PathBuf, FsError> {
        let at = self.followed(path)?;
        if at.parent().is_none() || self.nodes.contains_key(&at) {
            Ok(at)
        } else {
            Err(refused(FsErrorKind::NotFound, path))
        }
    }

    /// [`Fs::list`].
    fn list(&self, path: &Path) -> Result<Vec<Entry>, FsError> {
        let at = self.followed(path)?;
        if at.parent().is_some() {
            match self.nodes.get(&at) {
                Some(Node::Directory(_)) => {}
                Some(Node::File { .. } | Node::Other(_)) => {
                    return Err(refused(FsErrorKind::NotAFile, path));
                }
                Some(Node::Link(_)) | None => return Err(refused(FsErrorKind::NotFound, path)),
            }
        }
        let entries = self
            .nodes
            .keys()
            .filter(|child| child.parent() == Some(at.as_path()))
            .filter_map(|child| {
                let name = child.file_name()?.to_os_string();
                let kind = self
                    .stat(child)
                    .ok()
                    .flatten()
                    .map_or(Kind::Other, |stat| stat.kind);
                Some(Entry { name, kind })
            })
            .collect();
        Ok(entries)
    }

    /// [`Fs::make_directory`]. Every path from the root down to `path` is
    /// made a directory where nothing is; a file or anything else on the
    /// way is refused. The fake follows no link on the way.
    fn make_directory(&mut self, path: &Path) -> Result<(), FsError> {
        let mut on_the_way: Vec<&Path> = path.ancestors().collect();
        on_the_way.reverse();
        for at in &on_the_way {
            // The root has no parent, and is always there.
            if at.parent().is_none() {
                continue;
            }
            match self.nodes.get(*at) {
                Some(Node::Directory(_)) | None => {}
                Some(Node::File { .. } | Node::Other(_)) => {
                    return Err(refused(FsErrorKind::NotAFile, at));
                }
                Some(Node::Link(_)) => {
                    return Err(FsError::new(
                        FsErrorKind::Other,
                        format!(
                            "the fake follows no link to make a directory: {}",
                            at.display()
                        ),
                    ));
                }
            }
        }
        self.make_directories(path);
        Ok(())
    }

    /// [`Fs::read_link`].
    fn read_link(&self, path: &Path) -> Option<PathBuf> {
        match self.nodes.get(path) {
            Some(Node::Link(to)) => Some(to.clone()),
            _ => None,
        }
    }
}

/// A refusal of `kind` that names `path`, in the fake's own words.
fn refused(kind: FsErrorKind, path: &Path) -> FsError {
    FsError::new(kind, format!("the fake file system, at {}", path.display()))
}

impl Fs for FakeFs {
    fn stat(&self, path: &Path) -> Result<Option<Stat>, FsError> {
        self.call(Call::Stat(path.to_path_buf()), |state| state.stat(path))
    }

    fn read(&self, path: &Path) -> Result<Vec<u8>, FsError> {
        self.call(Call::Read(path.to_path_buf()), |state| state.read(path))
    }

    fn write(
        &self,
        path: &Path,
        pieces: &mut Pieces<'_>,
        permissions: Option<Permissions>,
    ) -> Result<(), FsError> {
        self.call(Call::Write(path.to_path_buf(), permissions), |state| {
            state.write(path, pieces, permissions)
        })
    }

    fn rename(&self, from: &Path, to: &Path) -> Result<(), FsError> {
        self.call(
            Call::Rename(from.to_path_buf(), to.to_path_buf()),
            |state| state.rename(from, to),
        )
    }

    fn remove(&self, path: &Path) -> Result<(), FsError> {
        self.call(Call::Remove(path.to_path_buf()), |state| state.remove(path))
    }

    fn resolve(&self, path: &Path) -> Result<PathBuf, FsError> {
        self.call(Call::Resolve(path.to_path_buf()), |state| {
            state.resolve(path)
        })
    }

    fn read_link(&self, path: &Path) -> Result<Option<PathBuf>, FsError> {
        self.call(Call::ReadLink(path.to_path_buf()), |state| {
            Ok(state.read_link(path))
        })
    }

    fn list(&self, path: &Path) -> Result<Vec<Entry>, FsError> {
        self.call(Call::List(path.to_path_buf()), |state| state.list(path))
    }

    fn make_directory(&self, path: &Path) -> Result<(), FsError> {
        self.call(Call::MakeDirectory(path.to_path_buf()), |state| {
            state.make_directory(path)
        })
    }
}

/// The ground the contract is checked on, for the fake: the fake itself
/// and a directory in it ([`FakeFs::ground`]).
pub struct FakeGround<'a> {
    /// The fake.
    fs: &'a FakeFs,
    /// The directory the check works in.
    root: PathBuf,
}

impl Ground for FakeGround<'_> {
    fn root(&self) -> &Path {
        &self.root
    }

    fn link(&self, link: &Path, to: &Path) -> Result<(), String> {
        self.fs.link(link, to);
        Ok(())
    }

    fn directory(&self, path: &Path) -> Result<(), String> {
        self.fs.directory(path);
        Ok(())
    }

    fn set_modified(&self, path: &Path, to: Modified) -> Result<(), String> {
        if self.fs.set_modified(path, to) {
            Ok(())
        } else {
            Err(format!("no file is at {}", path.display()))
        }
    }

    fn set_permissions(&self, path: &Path, to: Permissions) -> Result<(), String> {
        if self.fs.set_permissions(path, to) {
            Ok(())
        } else {
            Err(format!("no file is at {}", path.display()))
        }
    }

    fn permissions(&self, path: &Path) -> Result<Permissions, String> {
        self.fs
            .permissions(path)
            .ok_or_else(|| format!("no file is at {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    /// Writes a file of `parts` at `path` through the port.
    fn write(
        fs: &FakeFs,
        path: &str,
        parts: &[&[u8]],
        permissions: Option<Permissions>,
    ) -> Result<(), FsError> {
        let mut pieces = parts.iter().map(|part| Cow::Borrowed(*part));
        fs.write(Path::new(path), &mut pieces, permissions)
    }

    /// An instant `seconds` after the epoch.
    fn at(seconds: i64) -> Modified {
        Modified {
            seconds,
            nanoseconds: 0,
        }
    }

    /// A refusal of `kind`, as a test injects one.
    fn refusal(kind: FsErrorKind) -> FsError {
        FsError::new(kind, "injected")
    }

    #[test]
    fn a_file_the_fake_is_given_stats_reads_and_resolves() {
        let fs = FakeFs::new();
        fs.set_now(at(7));
        fs.file("/dir/a.txt", b"h\xFFllo\r\n");

        assert_eq!(
            fs.stat(Path::new("/dir/a.txt")),
            Ok(Some(Stat {
                kind: Kind::File,
                size: 7,
                modified: at(7),
                permissions: FakeFs::DEFAULT_PERMISSIONS,
            }))
        );
        assert_eq!(
            fs.read(Path::new("/dir/a.txt")),
            Ok(b"h\xFFllo\r\n".to_vec())
        );
        assert_eq!(
            fs.resolve(Path::new("/dir/a.txt")),
            Ok(PathBuf::from("/dir/a.txt"))
        );
        // The directory on the way to it was made.
        assert_eq!(
            fs.stat(Path::new("/dir"))
                .map(|stat| stat.map(|stat| stat.kind)),
            Ok(Some(Kind::Directory))
        );
        assert_eq!(fs.stat(Path::new("/dir/b.txt")), Ok(None));
    }

    #[test]
    fn a_written_file_is_stamped_with_the_fakes_time_which_only_set_now_moves() {
        let fs = FakeFs::new();
        fs.directory("/dir");
        fs.set_now(at(100));

        assert_eq!(write(&fs, "/dir/one", &[b"1"], None), Ok(()));
        assert_eq!(write(&fs, "/dir/two", &[b"2"], None), Ok(()));
        fs.set_now(at(101));
        assert_eq!(write(&fs, "/dir/three", &[b"3"], None), Ok(()));

        let modified = |path: &str| {
            fs.stat(Path::new(path))
                .ok()
                .flatten()
                .map(|stat| stat.modified)
        };
        assert_eq!(modified("/dir/one"), Some(at(100)));
        assert_eq!(modified("/dir/two"), Some(at(100)));
        assert_eq!(modified("/dir/three"), Some(at(101)));
    }

    #[test]
    fn a_written_file_holds_its_pieces_joined_with_the_permissions_named_or_the_default() {
        let fs = FakeFs::new();
        fs.directory("/dir");

        assert_eq!(
            write(
                &fs,
                "/dir/named",
                &[b"a\r\n", b"", b"\xFFb"],
                Some(Permissions::new(0o600))
            ),
            Ok(())
        );
        assert_eq!(write(&fs, "/dir/plain", &[], None), Ok(()));

        assert_eq!(fs.bytes("/dir/named"), Some(b"a\r\n\xFFb".to_vec()));
        assert_eq!(fs.permissions("/dir/named"), Some(Permissions::new(0o600)));
        assert_eq!(fs.bytes("/dir/plain"), Some(Vec::new()));
        assert_eq!(
            fs.permissions("/dir/plain"),
            Some(FakeFs::DEFAULT_PERMISSIONS)
        );
    }

    #[test]
    fn a_write_needs_its_directory_and_refuses_a_path_that_holds_anything() {
        let fs = FakeFs::new();
        fs.file("/dir/file", b"old");
        fs.directory("/dir/sub");
        fs.other("/dir/pipe");

        let kind = |path: &str| write(&fs, path, &[b"new"], None).map_err(|error| error.kind);
        assert_eq!(kind("/nowhere/file"), Err(FsErrorKind::NotFound));
        assert_eq!(kind("/dir/file/under"), Err(FsErrorKind::NotAFile));
        assert_eq!(kind("/dir/file"), Err(FsErrorKind::Exists));
        assert_eq!(kind("/dir/sub"), Err(FsErrorKind::Exists));
        assert_eq!(kind("/dir/pipe"), Err(FsErrorKind::Exists));
        assert_eq!(fs.bytes("/dir/file"), Some(b"old".to_vec()));
    }

    #[test]
    fn calls_lists_every_call_in_order_with_what_it_was_asked() {
        let fs = FakeFs::new();
        fs.file("/dir/a", b"a");

        let _ = fs.stat(Path::new("/dir/a"));
        let _ = fs.resolve(Path::new("/dir/a"));
        let _ = fs.read(Path::new("/dir/a"));
        let _ = write(&fs, "/dir/b", &[b"b"], Some(Permissions::new(0o640)));
        let _ = write(&fs, "/dir/c", &[b"c"], None);
        let _ = fs.rename(Path::new("/dir/b"), Path::new("/dir/a"));
        let _ = fs.remove(Path::new("/dir/missing"));

        assert_eq!(
            fs.calls(),
            [
                Call::Stat("/dir/a".into()),
                Call::Resolve("/dir/a".into()),
                Call::Read("/dir/a".into()),
                Call::Write("/dir/b".into(), Some(Permissions::new(0o640))),
                Call::Write("/dir/c".into(), None),
                Call::Rename("/dir/b".into(), "/dir/a".into()),
                Call::Remove("/dir/missing".into()),
            ]
        );
        assert_eq!(fs.bytes("/dir/a"), Some(b"b".to_vec()));
        assert_eq!(fs.bytes("/dir/b"), None);
    }

    #[test]
    fn fail_fails_the_next_call_of_its_operation_and_no_other() {
        let fs = FakeFs::new();
        fs.file("/dir/a", b"a");
        fs.fail(Op::Read, refusal(FsErrorKind::Denied));

        // A call of another operation is answered as usual meanwhile.
        assert!(matches!(fs.stat(Path::new("/dir/a")), Ok(Some(_))));
        assert_eq!(
            fs.read(Path::new("/dir/a")),
            Err(refusal(FsErrorKind::Denied))
        );
        // Only the next one.
        assert_eq!(fs.read(Path::new("/dir/a")), Ok(b"a".to_vec()));
        // The failed call is listed, and did nothing.
        fs.fail(Op::Remove, refusal(FsErrorKind::Other));
        assert_eq!(
            fs.remove(Path::new("/dir/a")),
            Err(refusal(FsErrorKind::Other))
        );
        assert_eq!(fs.bytes("/dir/a"), Some(b"a".to_vec()));
        assert_eq!(fs.calls().last(), Some(&Call::Remove("/dir/a".into())));
    }

    #[test]
    fn cut_write_leaves_the_bytes_it_kept_and_fails() {
        let fs = FakeFs::new();
        fs.directory("/dir");
        fs.cut_write(4);

        let cut = write(&fs, "/dir/a", &[b"abc", b"def"], None);

        assert_eq!(cut.map_err(|error| error.kind), Err(FsErrorKind::Other));
        assert_eq!(fs.bytes("/dir/a"), Some(b"abcd".to_vec()));
        // Only the next write is cut.
        assert_eq!(write(&fs, "/dir/b", &[b"abc", b"def"], None), Ok(()));
        assert_eq!(fs.bytes("/dir/b"), Some(b"abcdef".to_vec()));
    }

    #[test]
    fn after_runs_its_hook_once_when_the_call_of_its_operation_has_been_answered() {
        let fs = FakeFs::new();
        fs.file("/dir/a", b"old");
        let runs = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&runs);
        fs.after(Op::Read, move |fs| {
            counted.fetch_add(1, Ordering::SeqCst);
            // The hook holds no lock, so it may change the file system.
            fs.file("/dir/a", b"new");
        });

        // A call of another operation does not run it.
        let _ = fs.stat(Path::new("/dir/a"));
        assert_eq!(runs.load(Ordering::SeqCst), 0);
        // The call it waits for is answered first, with the file as it was.
        assert_eq!(fs.read(Path::new("/dir/a")), Ok(b"old".to_vec()));
        assert_eq!(runs.load(Ordering::SeqCst), 1);
        assert_eq!(fs.read(Path::new("/dir/a")), Ok(b"new".to_vec()));
        assert_eq!(runs.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn after_runs_its_hook_when_the_call_was_made_to_fail() {
        let fs = FakeFs::new();
        fs.file("/dir/a", b"a");
        let runs = Arc::new(AtomicUsize::new(0));
        let counted = Arc::clone(&runs);
        fs.after(Op::Read, move |_| {
            counted.fetch_add(1, Ordering::SeqCst);
        });
        fs.fail(Op::Read, refusal(FsErrorKind::Denied));

        assert!(fs.read(Path::new("/dir/a")).is_err());

        assert_eq!(runs.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn on_next_call_runs_its_hook_once_when_the_next_call_has_been_answered_whichever_it_is() {
        for op in [Op::Stat, Op::Read, Op::Resolve, Op::Remove] {
            let fs = FakeFs::new();
            fs.file("/dir/a", b"a");
            let runs = Arc::new(AtomicUsize::new(0));
            let counted = Arc::clone(&runs);
            fs.on_next_call(move |fs| {
                counted.fetch_add(1, Ordering::SeqCst);
                // The call has been recorded by the time the hook runs.
                assert_eq!(fs.calls().len(), 1);
            });
            let path = Path::new("/dir/a");

            match op {
                Op::Stat => drop(fs.stat(path)),
                Op::Read => drop(fs.read(path)),
                Op::Resolve => drop(fs.resolve(path)),
                _ => drop(fs.remove(path)),
            }
            assert_eq!(runs.load(Ordering::SeqCst), 1, "{op:?}");
            let _ = fs.stat(path);
            assert_eq!(runs.load(Ordering::SeqCst), 1, "{op:?}");
        }
    }

    #[test]
    fn a_link_is_followed_by_stat_read_and_resolve() {
        let fs = FakeFs::new();
        fs.file("/dir/file", b"file");
        fs.link("/dir/link", "/dir/file");
        fs.link("/dir/again", "/dir/link");

        assert_eq!(
            fs.stat(Path::new("/dir/again")),
            fs.stat(Path::new("/dir/file"))
        );
        assert_eq!(fs.read(Path::new("/dir/again")), Ok(b"file".to_vec()));
        assert_eq!(
            fs.resolve(Path::new("/dir/again")),
            Ok(PathBuf::from("/dir/file"))
        );
    }

    #[test]
    fn a_link_to_nothing_stats_as_nothing_and_is_still_something_a_write_refuses() {
        let fs = FakeFs::new();
        fs.link("/dir/link", "/dir/nothing");

        assert_eq!(fs.stat(Path::new("/dir/link")), Ok(None));
        assert_eq!(
            fs.resolve(Path::new("/dir/link"))
                .map_err(|error| error.kind),
            Err(FsErrorKind::NotFound)
        );
        assert_eq!(
            write(&fs, "/dir/link", &[b"new"], None).map_err(|error| error.kind),
            Err(FsErrorKind::Exists)
        );
        assert_eq!(fs.stat(Path::new("/dir/nothing")), Ok(None));
    }

    #[test]
    fn a_link_is_read_as_the_path_it_holds_and_what_is_no_link_as_none() {
        let fs = FakeFs::new();
        fs.file("/dir/file", b"a");
        fs.link("/dir/link", "/dir/file");
        fs.link("/dir/dangling", "/dir/nothing");
        fs.link("/dir/relative", "file");
        fs.link("/dir/first", "/dir/link");
        let held = |path: &str| fs.read_link(Path::new(path));

        assert_eq!(held("/dir/link"), Ok(Some("/dir/file".into())));
        assert_eq!(held("/dir/dangling"), Ok(Some("/dir/nothing".into())));
        // As the link holds it: it is not made absolute.
        assert_eq!(held("/dir/relative"), Ok(Some("file".into())));
        // One link, and not the links after it.
        assert_eq!(held("/dir/first"), Ok(Some("/dir/link".into())));
        // What is no link: a file, a directory, nothing, the root.
        assert_eq!(held("/dir/file"), Ok(None));
        assert_eq!(held("/dir"), Ok(None));
        assert_eq!(held("/dir/nothing"), Ok(None));
        assert_eq!(held("/nowhere/nothing"), Ok(None));
        assert_eq!(held("/"), Ok(None));
        assert_eq!(fs.calls().last(), Some(&Call::ReadLink("/".into())));
        assert_eq!(Call::ReadLink("/".into()).op(), Op::ReadLink);
    }

    #[test]
    fn two_links_that_name_each_other_are_refused_and_not_followed_for_ever() {
        let fs = FakeFs::new();
        fs.link("/dir/a", "/dir/b");
        fs.link("/dir/b", "/dir/a");

        assert_eq!(
            fs.stat(Path::new("/dir/a")).map_err(|error| error.kind),
            Err(FsErrorKind::Other)
        );
        assert_eq!(
            fs.resolve(Path::new("/dir/a")).map_err(|error| error.kind),
            Err(FsErrorKind::Other)
        );
    }

    #[test]
    fn what_is_not_a_file_stats_as_what_it_is_and_is_not_read() {
        let fs = FakeFs::new();
        fs.directory("/dir");
        fs.other("/dir/pipe");

        let kind = |path: &str| {
            fs.stat(Path::new(path))
                .ok()
                .flatten()
                .map(|stat| stat.kind)
        };
        assert_eq!(kind("/"), Some(Kind::Directory));
        assert_eq!(kind("/dir"), Some(Kind::Directory));
        assert_eq!(kind("/dir/pipe"), Some(Kind::Other));
        let read = |path: &str| fs.read(Path::new(path)).map_err(|error| error.kind);
        assert_eq!(read("/dir"), Err(FsErrorKind::NotAFile));
        assert_eq!(read("/dir/pipe"), Err(FsErrorKind::NotAFile));
        assert_eq!(read("/dir/nothing"), Err(FsErrorKind::NotFound));
    }

    #[test]
    fn a_test_sets_a_files_time_and_permissions_and_takes_a_file_away() {
        let fs = FakeFs::new();
        fs.file("/dir/a", b"a");
        fs.link("/dir/link", "/dir/a");

        assert!(fs.set_modified("/dir/link", at(-5)));
        assert!(fs.set_permissions("/dir/a", Permissions::new(0o400)));
        assert!(!fs.set_modified("/dir/nothing", at(1)));
        assert!(!fs.set_permissions("/dir", Permissions::new(0o700)));

        let stat = fs.stat(Path::new("/dir/a")).ok().flatten();
        assert_eq!(stat.map(|stat| stat.modified), Some(at(-5)));
        assert_eq!(fs.permissions("/dir/a"), Some(Permissions::new(0o400)));
        fs.take_away("/dir/a");
        assert_eq!(
            fs.paths(),
            [PathBuf::from("/dir"), PathBuf::from("/dir/link")]
        );
        // Neither changed the record of what the port was asked.
        assert_eq!(fs.calls(), [Call::Stat("/dir/a".into())]);
    }

    #[test]
    fn a_rename_and_a_remove_refuse_what_is_not_there_and_a_directory() {
        let fs = FakeFs::new();
        fs.file("/dir/a", b"a");
        fs.directory("/dir/sub");

        let rename = |from: &str, to: &str| {
            fs.rename(Path::new(from), Path::new(to))
                .map_err(|error| error.kind)
        };
        assert_eq!(rename("/dir/missing", "/dir/a"), Err(FsErrorKind::NotFound));
        assert_eq!(rename("/dir/a", "/nowhere/a"), Err(FsErrorKind::NotFound));
        assert_eq!(rename("/dir/a", "/dir/sub"), Err(FsErrorKind::NotAFile));
        let remove = |path: &str| fs.remove(Path::new(path)).map_err(|error| error.kind);
        assert_eq!(remove("/dir/missing"), Err(FsErrorKind::NotFound));
        assert_eq!(remove("/dir/sub"), Err(FsErrorKind::NotAFile));
        assert_eq!(remove("/dir/a"), Ok(()));
        assert_eq!(
            fs.paths(),
            [PathBuf::from("/dir"), PathBuf::from("/dir/sub")]
        );
    }

    /// The names and kinds of `entries`, by name.
    fn named(mut entries: Vec<Entry>) -> Vec<(String, Kind)> {
        entries.sort_by(|one, other| one.name.cmp(&other.name));
        entries
            .into_iter()
            .map(|entry| (entry.name.to_string_lossy().into_owned(), entry.kind))
            .collect()
    }

    #[test]
    fn a_listing_names_a_directorys_own_children_with_their_kinds_links_followed() {
        let fs = FakeFs::new();
        fs.file("/w/a.txt", b"a");
        fs.file("/w/sub/deep.txt", b"deep");
        fs.other("/w/pipe");
        fs.link("/w/to-a", "/w/a.txt");
        fs.link("/w/to-sub", "/w/sub");
        fs.link("/w/dangling", "/nowhere");

        assert_eq!(
            named(fs.list(Path::new("/w")).expect("a directory lists")),
            [
                (String::from("a.txt"), Kind::File),
                (String::from("dangling"), Kind::Other),
                (String::from("pipe"), Kind::Other),
                (String::from("sub"), Kind::Directory),
                (String::from("to-a"), Kind::File),
                (String::from("to-sub"), Kind::Directory),
            ]
        );
        assert_eq!(
            named(
                fs.list(Path::new("/w/to-sub"))
                    .expect("a link to a directory lists")
            ),
            [(String::from("deep.txt"), Kind::File)]
        );
        assert_eq!(
            named(fs.list(Path::new("/")).expect("the root lists")),
            [(String::from("w"), Kind::Directory)]
        );
    }

    #[test]
    fn a_listing_of_nothing_or_of_what_is_not_a_directory_is_refused() {
        let fs = FakeFs::new();
        fs.file("/w/a.txt", b"a");
        fs.other("/w/pipe");
        let kind = |path: &str| fs.list(Path::new(path)).map_err(|error| error.kind);

        assert_eq!(kind("/w/missing"), Err(FsErrorKind::NotFound));
        assert_eq!(kind("/w/a.txt"), Err(FsErrorKind::NotAFile));
        assert_eq!(kind("/w/pipe"), Err(FsErrorKind::NotAFile));
        assert_eq!(
            fs.calls().last(),
            Some(&Call::List(PathBuf::from("/w/pipe")))
        );
    }

    #[test]
    fn a_directory_is_made_with_its_parents_and_one_already_there_is_no_error() {
        let fs = FakeFs::new();
        fs.directory("/w");

        assert_eq!(fs.make_directory(Path::new("/w/a/b/c")), Ok(()));
        for path in ["/w/a", "/w/a/b", "/w/a/b/c"] {
            assert_eq!(
                fs.stat(Path::new(path))
                    .ok()
                    .flatten()
                    .map(|stat| stat.kind),
                Some(Kind::Directory),
                "{path}"
            );
        }
        assert_eq!(fs.make_directory(Path::new("/w/a/b")), Ok(()));
        assert_eq!(fs.make_directory(Path::new("/")), Ok(()));
        assert_eq!(
            fs.calls().last(),
            Some(&Call::MakeDirectory(PathBuf::from("/")))
        );
    }

    #[test]
    fn a_directory_where_a_file_is_or_under_one_is_refused_and_nothing_is_made() {
        let fs = FakeFs::new();
        fs.file("/w/a.txt", b"a");
        fs.other("/w/pipe");
        let kind = |path: &str| {
            fs.make_directory(Path::new(path))
                .map_err(|error| error.kind)
        };

        assert_eq!(kind("/w/a.txt"), Err(FsErrorKind::NotAFile));
        assert_eq!(kind("/w/a.txt/under/deeper"), Err(FsErrorKind::NotAFile));
        assert_eq!(kind("/w/pipe"), Err(FsErrorKind::NotAFile));
        assert_eq!(fs.bytes("/w/a.txt").as_deref(), Some(&b"a"[..]));
        assert_eq!(fs.stat(Path::new("/w/a.txt/under")), Ok(None));
    }

    #[test]
    fn fail_fails_the_next_directory_made() {
        let fs = FakeFs::new();
        fs.fail(Op::MakeDirectory, refusal(FsErrorKind::Denied));

        assert_eq!(
            fs.make_directory(Path::new("/w")),
            Err(refusal(FsErrorKind::Denied))
        );
        assert_eq!(fs.stat(Path::new("/w")), Ok(None));
        assert_eq!(fs.make_directory(Path::new("/w")), Ok(()));
    }

    #[test]
    fn fail_fails_the_next_listing() {
        let fs = FakeFs::new();
        fs.directory("/w");
        fs.fail(Op::List, refusal(FsErrorKind::Denied));

        assert_eq!(fs.list(Path::new("/w")), Err(refusal(FsErrorKind::Denied)));
        assert_eq!(fs.list(Path::new("/w")), Ok(Vec::new()));
    }
}
