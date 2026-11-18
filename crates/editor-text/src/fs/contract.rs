//! The contract of the file port: the rules every [`Fs`] keeps, as a check
//! that runs one.
//!
//! [`check`] works in one directory and checks every rule in this order,
//! stopping at the first that is broken:
//!
//! - **Nothing.** The stat of nothing is none; reading, removing and
//!   resolving nothing are refused as [`FsErrorKind::NotFound`]; and
//!   nothing is read as no link.
//! - **A file reads as what it was written from.** A file reads as the
//!   pieces it was written from, joined (an empty piece, a CRLF, bytes that
//!   are not UTF-8 and a four-byte character among them), and its stat says
//!   it is a file of that length.
//! - **A file has the permissions it was written with**, for three values,
//!   one of which a usual mask would cut down: as its stat says them **and
//!   as the ground reads them**, so an implementation whose `write` and
//!   `stat` agree on bits the file does not have is refused. And the stat
//!   of a file says the permissions the ground set.
//! - **A write makes a new file or nothing.** Writing where a file is is
//!   refused as [`FsErrorKind::Exists`] and the file is as it was; writing
//!   into a directory that is not there is refused as
//!   [`FsErrorKind::NotFound`].
//! - **The stat of a file says when it was modified**, for two instants a
//!   second apart that the ground sets.
//! - **A rename replaces.** After one the new name reads the file and the
//!   old name is gone; the file keeps its permissions, as the ground reads
//!   them, and **its stamp**: the stat of the new name says the
//!   modification time, which the ground set to an instant in the past, and
//!   the size that the stat of the old name said before the rename. A save
//!   returns the stamp it took of its temporary file, so it relies on this.
//!   Renaming nothing is refused as not found and the target is as it was.
//! - **A directory.** Its stat says it is one, and reading it is refused as
//!   [`FsErrorKind::NotAFile`].
//! - **Links.** A link resolves to the file it names and a file to itself;
//!   a link stats and reads as its file; writing where a link to a file is
//!   is refused as [`FsErrorKind::Exists`] and leaves the file; the link is
//!   read as the path it holds, and the file as no link.
//! - **A link to nothing.** Its stat is none and resolving it is refused as
//!   [`FsErrorKind::NotFound`], as for nothing; it is read as the path it
//!   holds, which is how a caller tells it from nothing; writing where it
//!   is is refused as [`FsErrorKind::Exists`] and does not make what it
//!   names. And a link that holds a path that is not absolute is read as
//!   it holds it.
//! - **A listing.** A directory holding a file, a directory, a link to a
//!   file and a link to nothing lists each once, with the kinds file,
//!   directory, file and other: links followed, and a link to nothing is
//!   other. Listing nothing is refused as [`FsErrorKind::NotFound`], and
//!   listing a file as [`FsErrorKind::NotAFile`].
//! - **A file is removed**, and its stat is then none.
//!
//! # The ground
//!
//! The port has no method to make a link or a directory, to set a file's
//! modification time, or to set or read its permissions behind the port's
//! back. The
//! check needs each done, so its caller supplies them as a [`Ground`]: the
//! truth the port's answers are compared with. For the fake it is the fake
//! itself ([`FakeFs::ground`](super::FakeFs::ground)); for a real adapter
//! it is the system, asked directly, in a directory the adapter's test
//! owns.
//!
//! # Where an addition goes
//!
//! A new rule is a step of [`check`], a variant of [`Violation`] with what
//! it says, a line of the list above, and in this module's tests a fake
//! written to break that one rule, refused with that violation.

use std::borrow::Cow;
use std::fmt;
use std::path::Path;

use super::{Fs, FsError, FsErrorKind, Kind, Modified, Permissions};

/// What [`check`] needs done, or read, that the port has no method for. It
/// is the truth the port's answers are compared with, so it must not be
/// built on the [`Fs`] being checked.
///
/// A method that cannot do what it is asked says why, and the check stops
/// with [`Violation::Ground`].
pub trait Ground {
    /// The directory the check works in: one that exists, is empty, and is
    /// the caller's own, written with every link in its path followed (so
    /// that a file in it resolves to itself).
    fn root(&self) -> &Path;

    /// Makes a link at `link` that names `to`, which may hold nothing.
    fn link(&self, link: &Path, to: &Path) -> Result<(), String>;

    /// Makes an empty directory at `path`, in a directory that is there.
    fn directory(&self, path: &Path) -> Result<(), String>;

    /// Stamps the file at `path` as modified at `to`.
    fn set_modified(&self, path: &Path, to: Modified) -> Result<(), String>;

    /// Gives the file at `path` the permissions `to`.
    fn set_permissions(&self, path: &Path, to: Permissions) -> Result<(), String>;

    /// The permissions the file at `path` has.
    fn permissions(&self, path: &Path) -> Result<Permissions, String>;
}

/// A rule of the contract that a file system broke.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Violation {
    /// The ground could not do what the check asked of it, for the reason
    /// given. Nothing is known of the file system.
    Ground(String),
    /// The file system refused something every rule allows, which the check
    /// needed done: `doing` says what.
    Refused {
        /// What the check was doing.
        doing: &'static str,
        /// The refusal.
        error: FsError,
    },
    /// The stat of nothing was not none.
    StatOfNothing,
    /// Reading nothing was not refused as not found.
    ReadOfNothing,
    /// Removing nothing was not refused as not found.
    RemoveOfNothing,
    /// Resolving nothing was not refused as not found.
    ResolveOfNothing,
    /// A file did not read as the pieces it was written from, joined.
    ReadDiffers,
    /// The stat of a file did not say it is a file of the length written.
    StatOfFile,
    /// The stat of a file did not say the permissions it was written with.
    PermissionsNotSaid,
    /// A file did not have the permissions it was written with, as the
    /// ground reads them, though its stat said so.
    PermissionsNotGiven,
    /// The stat of a file did not say the permissions the ground set.
    PermissionsSetNotSaid,
    /// Writing where a file is was not refused as existing, or changed the
    /// file.
    WroteOverAFile,
    /// Writing into a directory that is not there was not refused as not
    /// found.
    WroteIntoNoDirectory,
    /// The stat of a file did not say when the ground set it as modified.
    ModifiedNotSaid,
    /// After a rename the new name did not read the file.
    RenameLostTheFile,
    /// After a rename the old name still held something.
    RenameLeftTheOldName,
    /// A renamed file did not keep its permissions, as the ground reads
    /// them.
    RenameChangedPermissions,
    /// A renamed file did not keep its stamp: the stat of its new name did
    /// not say the modification time and the size the stat of its old name
    /// said before the rename.
    RenameChangedTheStamp,
    /// Renaming nothing was not refused as not found, or changed the
    /// target.
    RenameOfNothing,
    /// The stat of a directory did not say it is one.
    DirectoryNotSaid,
    /// Reading a directory was not refused as not a file.
    DirectoryRead,
    /// A link did not resolve to the file it names.
    LinkNotResolved,
    /// A file that is no link did not resolve to itself.
    FileNotResolvedToItself,
    /// A link did not stat and read as the file it names.
    LinkNotFollowed,
    /// Writing where a link to a file is was not refused as existing, or
    /// changed the file.
    WroteThroughALink,
    /// Writing where a link to nothing is was not refused as existing, or
    /// made what the link names.
    MadeWhatALinkNames,
    /// A link was not read as the path it holds: one that names a file,
    /// one that names nothing, or one that holds a path that is not
    /// absolute.
    LinkNotRead,
    /// What is no link, nothing or a file, was not read as no link.
    NoLinkReadAsOne,
    /// The stat of a link to nothing was not none.
    StatOfALinkToNothing,
    /// Resolving a link to nothing was not refused as not found.
    ResolvedALinkToNothing,
    /// A directory did not list each thing it holds once, by its name.
    ListNotEachOnce,
    /// A directory listed something with the wrong kind: links are
    /// followed, and a link to nothing is other.
    ListKindsWrong,
    /// Listing nothing was not refused as not found.
    ListOfNothing,
    /// Listing a file was not refused as not a file.
    ListOfAFile,
    /// A removed file was still there.
    NotRemoved,
}

impl fmt::Display for Violation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Ground(reason) => {
                return write!(
                    f,
                    "the ground the check stands on could not do what was asked: {reason}"
                );
            }
            Self::Refused { doing, error } => return write!(f, "{doing} was refused: {error}"),
            Self::StatOfNothing => "the stat of nothing was not none",
            Self::ReadOfNothing => "reading nothing was not refused as not found",
            Self::RemoveOfNothing => "removing nothing was not refused as not found",
            Self::ResolveOfNothing => "resolving nothing was not refused as not found",
            Self::ReadDiffers => "a file did not read as the pieces it was written from, joined",
            Self::StatOfFile => {
                "the stat of a file did not say it is a file of the length written"
            }
            Self::PermissionsNotSaid => {
                "the stat of a file did not say the permissions it was written with"
            }
            Self::PermissionsNotGiven => {
                "a file did not have the permissions it was written with, though its stat said so"
            }
            Self::PermissionsSetNotSaid => {
                "the stat of a file did not say the permissions that were set on it"
            }
            Self::WroteOverAFile => {
                "writing where a file is was not refused as existing, or changed the file"
            }
            Self::WroteIntoNoDirectory => {
                "writing into a directory that is not there was not refused as not found"
            }
            Self::ModifiedNotSaid => "the stat of a file did not say when it was modified",
            Self::RenameLostTheFile => "after a rename the new name did not read the file",
            Self::RenameLeftTheOldName => "after a rename the old name still held something",
            Self::RenameChangedPermissions => "a renamed file did not keep its permissions",
            Self::RenameChangedTheStamp => {
                "a renamed file did not keep its modification time and its size"
            }
            Self::RenameOfNothing => {
                "renaming nothing was not refused as not found, or changed the target"
            }
            Self::DirectoryNotSaid => "the stat of a directory did not say it is one",
            Self::DirectoryRead => "reading a directory was not refused as not a file",
            Self::LinkNotResolved => "a link did not resolve to the file it names",
            Self::FileNotResolvedToItself => "a file that is no link did not resolve to itself",
            Self::LinkNotFollowed => "a link did not stat and read as the file it names",
            Self::WroteThroughALink => {
                "writing where a link to a file is was not refused as existing, or changed the file"
            }
            Self::MadeWhatALinkNames => {
                "writing where a link to nothing is was not refused as existing, or made what the link names"
            }
            Self::LinkNotRead => "a link was not read as the path it holds",
            Self::NoLinkReadAsOne => "what is no link was not read as no link",
            Self::StatOfALinkToNothing => "the stat of a link to nothing was not none",
            Self::ResolvedALinkToNothing => {
                "resolving a link to nothing was not refused as not found"
            }
            Self::ListNotEachOnce => "a directory did not list each thing it holds once",
            Self::ListKindsWrong => {
                "a directory listed something with the wrong kind, links followed"
            }
            Self::ListOfNothing => "listing nothing was not refused as not found",
            Self::ListOfAFile => "listing a file was not refused as not a file",
            Self::NotRemoved => "a removed file was still there",
        })
    }
}

impl std::error::Error for Violation {}

/// What the first file of the check is written from: an empty piece, a
/// CRLF, bytes that are not UTF-8 and a four-byte character among them.
const PIECES: &[&[u8]] = &[
    b"one\r\n",
    b"",
    b"\xFF\xFEtwo\n",
    "\u{1F600}".as_bytes(),
    b"\xE2\x82",
];

/// Holds `fs` to the rules of the port, in the directory `ground` names,
/// and says the first rule it breaks. The module docs list the rules.
///
/// It leaves files behind in the directory: the directory is the caller's
/// to remove.
pub fn check(fs: &dyn Fs, ground: &dyn Ground) -> Result<(), Violation> {
    let root = ground.root();
    let file = root.join("file");
    let joined = PIECES.concat();

    nothing(fs, root)?;
    a_file_reads_as_written(fs, &file, &joined)?;
    permissions(fs, ground, root)?;
    a_write_makes_a_new_file_or_nothing(fs, root, &file, &joined)?;
    modified(fs, ground, &file)?;
    a_rename_replaces(fs, ground, root)?;
    a_directory(fs, root)?;
    links(fs, ground, root, &file, &joined)?;
    a_link_to_nothing(fs, ground, root)?;
    a_listing(fs, ground, root, &file)?;

    must("removing a file", fs.remove(&file))?;
    if must("the stat of a removed file", fs.stat(&file))?.is_some() {
        return Err(Violation::NotRemoved);
    }
    Ok(())
}

/// Writes a new file of `parts` at `path`.
fn write(
    fs: &dyn Fs,
    path: &Path,
    parts: &[&[u8]],
    permissions: Option<Permissions>,
) -> Result<(), FsError> {
    let mut pieces = parts.iter().map(|part| Cow::Borrowed(*part));
    fs.write(path, &mut pieces, permissions)
}

/// What the file system answered, or the violation of it refusing what
/// every rule allows.
fn must<T>(doing: &'static str, answer: Result<T, FsError>) -> Result<T, Violation> {
    answer.map_err(|error| Violation::Refused { doing, error })
}

/// What the ground answered, or the violation of it not doing what was
/// asked.
fn grounded<T>(answer: Result<T, String>) -> Result<T, Violation> {
    answer.map_err(Violation::Ground)
}

/// Whether `answer` is a refusal of `kind`.
fn refused_as<T>(answer: &Result<T, FsError>, kind: FsErrorKind) -> bool {
    matches!(answer, Err(error) if error.kind == kind)
}

/// Whether the file at `path` reads as `bytes`.
fn reads(fs: &dyn Fs, path: &Path, bytes: &[u8]) -> Result<bool, Violation> {
    Ok(must("reading a file", fs.read(path))? == bytes)
}

/// Nothing: its stat is none, and reading, removing and resolving it are
/// refused as not found.
fn nothing(fs: &dyn Fs, root: &Path) -> Result<(), Violation> {
    let missing = root.join("missing");
    if !matches!(fs.stat(&missing), Ok(None)) {
        return Err(Violation::StatOfNothing);
    }
    if !refused_as(&fs.read(&missing), FsErrorKind::NotFound) {
        return Err(Violation::ReadOfNothing);
    }
    if !refused_as(&fs.remove(&missing), FsErrorKind::NotFound) {
        return Err(Violation::RemoveOfNothing);
    }
    if !refused_as(&fs.resolve(&missing), FsErrorKind::NotFound) {
        return Err(Violation::ResolveOfNothing);
    }
    if fs.read_link(&missing) != Ok(None) {
        return Err(Violation::NoLinkReadAsOne);
    }
    Ok(())
}

/// A file reads as the pieces it was written from, and its stat says it is
/// a file of that length. Leaves the file at `file`.
fn a_file_reads_as_written(fs: &dyn Fs, file: &Path, joined: &[u8]) -> Result<(), Violation> {
    must("writing a new file", write(fs, file, PIECES, None))?;
    if !reads(fs, file, joined)? {
        return Err(Violation::ReadDiffers);
    }
    let stat = must("the stat of a file", fs.stat(file))?;
    let length = u64::try_from(joined.len()).ok();
    if !stat.is_some_and(|stat| stat.kind == Kind::File && Some(stat.size) == length) {
        return Err(Violation::StatOfFile);
    }
    Ok(())
}

/// The permissions the stat of the file at `path` says.
fn said(fs: &dyn Fs, path: &Path) -> Result<Option<Permissions>, Violation> {
    Ok(must("the stat of a file", fs.stat(path))?.map(|stat| stat.permissions))
}

/// A file has the permissions it was written with, as its stat says them
/// and as the ground reads them; and its stat says the ones the ground set.
fn permissions(fs: &dyn Fs, ground: &dyn Ground, root: &Path) -> Result<(), Violation> {
    // The last is one a usual mask (`0o022`) would cut down to `0o644`.
    for mode in [0o600, 0o640, 0o666] {
        let path = root.join(format!("permissions-{mode:o}"));
        let asked = Permissions::new(mode);
        must(
            "writing a new file with its permissions named",
            write(fs, &path, &[b"x"], Some(asked)),
        )?;
        if said(fs, &path)? != Some(asked) {
            return Err(Violation::PermissionsNotSaid);
        }
        if grounded(ground.permissions(&path))? != asked {
            return Err(Violation::PermissionsNotGiven);
        }
    }
    let path = root.join("permissions-600");
    let set = Permissions::new(0o604);
    grounded(ground.set_permissions(&path, set))?;
    if said(fs, &path)? != Some(set) {
        return Err(Violation::PermissionsSetNotSaid);
    }
    Ok(())
}

/// Writing where a file is is refused and leaves the file; writing into a
/// directory that is not there is refused as not found.
fn a_write_makes_a_new_file_or_nothing(
    fs: &dyn Fs,
    root: &Path,
    file: &Path,
    joined: &[u8],
) -> Result<(), Violation> {
    let over = write(fs, file, &[b"other"], None);
    if !refused_as(&over, FsErrorKind::Exists) || !reads(fs, file, joined)? {
        return Err(Violation::WroteOverAFile);
    }
    let into = write(fs, &root.join("no-directory").join("file"), &[b"x"], None);
    if !refused_as(&into, FsErrorKind::NotFound) {
        return Err(Violation::WroteIntoNoDirectory);
    }
    Ok(())
}

/// The stat of a file says when it was modified, for two instants a second
/// apart that the ground sets.
fn modified(fs: &dyn Fs, ground: &dyn Ground, file: &Path) -> Result<(), Violation> {
    for seconds in [1_000_000_000, 1_000_000_001] {
        let to = Modified {
            seconds,
            nanoseconds: 0,
        };
        grounded(ground.set_modified(file, to))?;
        let stat = must("the stat of a file", fs.stat(file))?;
        if stat.map(|stat| stat.modified) != Some(to) {
            return Err(Violation::ModifiedNotSaid);
        }
    }
    Ok(())
}

/// After a rename the new name reads the file, the old name is gone and
/// the file has kept its permissions and its stamp; renaming nothing is
/// refused.
fn a_rename_replaces(fs: &dyn Fs, ground: &dyn Ground, root: &Path) -> Result<(), Violation> {
    let (from, to) = (root.join("from"), root.join("to"));
    let kept = Permissions::new(0o640);
    must(
        "writing a new file",
        write(fs, &from, &[b"new"], Some(kept)),
    )?;
    must(
        "writing a new file",
        write(fs, &to, &[b"old"], Some(Permissions::new(0o600))),
    )?;
    // An instant in the past, so that a rename that stamps the file with
    // the time it was renamed at cannot land on it.
    let written_at = Modified {
        seconds: 1_000_000_007,
        nanoseconds: 0,
    };
    grounded(ground.set_modified(&from, written_at))?;
    let stamp = |stat: Option<super::Stat>| stat.map(|stat| (stat.modified, stat.size));
    let before = stamp(must("the stat of a file", fs.stat(&from))?);
    must("renaming a file over a file", fs.rename(&from, &to))?;
    if !reads(fs, &to, b"new")? {
        return Err(Violation::RenameLostTheFile);
    }
    if must("the stat of a renamed file's old name", fs.stat(&from))?.is_some() {
        return Err(Violation::RenameLeftTheOldName);
    }
    if grounded(ground.permissions(&to))? != kept {
        return Err(Violation::RenameChangedPermissions);
    }
    let after = stamp(must("the stat of a renamed file", fs.stat(&to))?);
    if before.is_none() || after != before {
        return Err(Violation::RenameChangedTheStamp);
    }
    let of_nothing = fs.rename(&root.join("missing"), &to);
    if !refused_as(&of_nothing, FsErrorKind::NotFound) || !reads(fs, &to, b"new")? {
        return Err(Violation::RenameOfNothing);
    }
    Ok(())
}

/// The stat of a directory says it is one, and reading it is refused as
/// not a file.
fn a_directory(fs: &dyn Fs, root: &Path) -> Result<(), Violation> {
    let stat = must("the stat of a directory", fs.stat(root))?;
    if stat.map(|stat| stat.kind) != Some(Kind::Directory) {
        return Err(Violation::DirectoryNotSaid);
    }
    if !refused_as(&fs.read(root), FsErrorKind::NotAFile) {
        return Err(Violation::DirectoryRead);
    }
    Ok(())
}

/// A link resolves to its file and a file to itself; a link stats and
/// reads as its file; a write where a link to a file is is refused and
/// leaves the file; the link is read as the path it holds, and the file as
/// no link.
fn links(
    fs: &dyn Fs,
    ground: &dyn Ground,
    root: &Path,
    file: &Path,
    joined: &[u8],
) -> Result<(), Violation> {
    let link = root.join("link");
    grounded(ground.link(&link, file))?;
    if fs.resolve(&link).ok().as_deref() != Some(file) {
        return Err(Violation::LinkNotResolved);
    }
    if fs.resolve(file).ok().as_deref() != Some(file) {
        return Err(Violation::FileNotResolvedToItself);
    }
    let through = must("the stat of a link to a file", fs.stat(&link))?;
    let direct = must("the stat of a file", fs.stat(file))?;
    if through != direct || !reads(fs, &link, joined)? {
        return Err(Violation::LinkNotFollowed);
    }
    let over = write(fs, &link, &[b"through"], None);
    if !refused_as(&over, FsErrorKind::Exists) || !reads(fs, file, joined)? {
        return Err(Violation::WroteThroughALink);
    }
    if fs.read_link(&link).ok().flatten().as_deref() != Some(file) {
        return Err(Violation::LinkNotRead);
    }
    if fs.read_link(file) != Ok(None) {
        return Err(Violation::NoLinkReadAsOne);
    }
    Ok(())
}

/// A link to nothing stats as nothing, is not resolved, and is read as the
/// path it holds; a write where it is is refused and makes nothing. And a
/// link is read as it is held, when what it holds is not absolute.
fn a_link_to_nothing(fs: &dyn Fs, ground: &dyn Ground, root: &Path) -> Result<(), Violation> {
    let (dangling, nowhere) = (root.join("dangling"), root.join("nowhere"));
    grounded(ground.link(&dangling, &nowhere))?;
    if !matches!(fs.stat(&dangling), Ok(None)) {
        return Err(Violation::StatOfALinkToNothing);
    }
    if !refused_as(&fs.resolve(&dangling), FsErrorKind::NotFound) {
        return Err(Violation::ResolvedALinkToNothing);
    }
    if fs.read_link(&dangling).ok().flatten().as_deref() != Some(nowhere.as_path()) {
        return Err(Violation::LinkNotRead);
    }
    let over = write(fs, &dangling, &[b"through"], None);
    let made = must(
        "the stat of what a link to nothing names",
        fs.stat(&nowhere),
    )?;
    if !refused_as(&over, FsErrorKind::Exists) || made.is_some() {
        return Err(Violation::MadeWhatALinkNames);
    }
    // As the link holds it: a path that is not absolute is not made so.
    let (relative, held) = (root.join("relative"), Path::new("nowhere"));
    grounded(ground.link(&relative, held))?;
    if fs.read_link(&relative).ok().flatten().as_deref() != Some(held) {
        return Err(Violation::LinkNotRead);
    }
    Ok(())
}

/// A directory holding a file, a directory, a link to a file and a link to
/// nothing lists each once, with its kind, links followed; listing nothing
/// and listing a file are refused.
fn a_listing(fs: &dyn Fs, ground: &dyn Ground, root: &Path, file: &Path) -> Result<(), Violation> {
    let listed = root.join("listed");
    grounded(ground.directory(&listed))?;
    must(
        "writing a new file",
        write(fs, &listed.join("a-file"), &[b"x"], None),
    )?;
    grounded(ground.directory(&listed.join("a-directory")))?;
    grounded(ground.link(&listed.join("a-link"), file))?;
    grounded(ground.link(&listed.join("dangling"), &root.join("nowhere")))?;
    let mut entries = must("listing a directory", fs.list(&listed))?;
    entries.sort_by(|one, other| one.name.cmp(&other.name));
    let names: Vec<&std::ffi::OsStr> = entries.iter().map(|entry| entry.name.as_os_str()).collect();
    if names != ["a-directory", "a-file", "a-link", "dangling"] {
        return Err(Violation::ListNotEachOnce);
    }
    let kinds: Vec<Kind> = entries.iter().map(|entry| entry.kind).collect();
    if kinds != [Kind::Directory, Kind::File, Kind::File, Kind::Other] {
        return Err(Violation::ListKindsWrong);
    }
    if !refused_as(&fs.list(&root.join("missing")), FsErrorKind::NotFound) {
        return Err(Violation::ListOfNothing);
    }
    if !refused_as(&fs.list(file), FsErrorKind::NotAFile) {
        return Err(Violation::ListOfAFile);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::sync::{Mutex, PoisonError};

    use super::super::{Entry, FakeFs, Pieces, Stat};
    use super::*;

    /// One way to break one rule of the port.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Fault {
        /// A write replaces a file that is there.
        Overwrites,
        /// A write gives the file the default permissions, whatever it is
        /// asked.
        IgnoresPermissions,
        /// A write gives the file the default permissions, and the stat
        /// says the ones that were asked for.
        AgreesOnPermissionsNotGiven,
        /// A write keeps only its last piece.
        KeepsTheLastPiece,
        /// A write where a link to a file is replaces the file.
        FollowsALink,
        /// A write where a link to nothing is makes what the link names.
        MakesWhatALinkNames,
        /// A read of nothing gives no bytes.
        ReadsNothingAsEmpty,
        /// A stat says a file is a byte longer than it is.
        StatsTheWrongSize,
        /// A rename leaves the file at its old name too.
        RenameLeavesTheOldName,
        /// A rename stamps the file as modified when it was renamed.
        RenameRestamps,
        /// A resolve answers the path it was given.
        ResolveIgnoresLinks,
        /// A link that names nothing is read as no link.
        ReadsALinkToNothingAsNoLink,
        /// What is no link is read as a link to itself.
        ReadsWhatIsNoLinkAsALink,
        /// The stat of a link to nothing says something is there.
        StatsALinkToNothing,
        /// A resolve of a link to nothing answers the path the link names.
        ResolvesALinkToNothing,
        /// A listing leaves out its last entry by name.
        ListLeavesOutAnEntry,
        /// A listing says a link is other, whatever it names.
        ListDoesNotFollowLinks,
        /// A listing of a file answers no entries.
        ListOfAFileIsNotRefused,
    }

    impl Broken {
        /// The path the link at `path` names, when it names nothing.
        fn names_nothing(&self, path: &Path) -> Option<PathBuf> {
            let named = self.inner.link_target(path)?;
            matches!(self.inner.stat(&named), Ok(None)).then_some(named)
        }
    }

    /// The fake with one fault.
    struct Broken {
        /// The fake that does everything else.
        inner: FakeFs,
        /// What this one gets wrong.
        fault: Fault,
        /// The permissions each write was asked for, for the fault that
        /// claims them.
        claimed: Mutex<BTreeMap<PathBuf, Permissions>>,
    }

    impl Fs for Broken {
        fn stat(&self, path: &Path) -> Result<Option<Stat>, FsError> {
            if self.fault == Fault::StatsALinkToNothing && self.names_nothing(path).is_some() {
                return Ok(Some(Stat {
                    kind: Kind::Other,
                    size: 0,
                    modified: Modified::default(),
                    permissions: FakeFs::DEFAULT_PERMISSIONS,
                }));
            }
            let mut stat = self.inner.stat(path)?;
            if let Some(stat) = &mut stat {
                if self.fault == Fault::StatsTheWrongSize && stat.kind == Kind::File {
                    stat.size += 1;
                }
                let claimed = self.claimed.lock().unwrap_or_else(PoisonError::into_inner);
                if let Some(permissions) = claimed.get(path) {
                    stat.permissions = *permissions;
                }
            }
            Ok(stat)
        }

        fn read(&self, path: &Path) -> Result<Vec<u8>, FsError> {
            match self.inner.read(path) {
                Err(error)
                    if self.fault == Fault::ReadsNothingAsEmpty
                        && error.kind == FsErrorKind::NotFound =>
                {
                    Ok(Vec::new())
                }
                answer => answer,
            }
        }

        fn write(
            &self,
            path: &Path,
            pieces: &mut Pieces<'_>,
            permissions: Option<Permissions>,
        ) -> Result<(), FsError> {
            match self.fault {
                Fault::Overwrites => {
                    if self.inner.bytes(path).is_some() {
                        self.inner.take_away(path);
                    }
                    self.inner.write(path, pieces, permissions)
                }
                Fault::IgnoresPermissions => self.inner.write(path, pieces, None),
                Fault::AgreesOnPermissionsNotGiven => {
                    if let Some(permissions) = permissions {
                        self.claimed
                            .lock()
                            .unwrap_or_else(PoisonError::into_inner)
                            .insert(path.to_path_buf(), permissions);
                    }
                    self.inner.write(path, pieces, None)
                }
                Fault::KeepsTheLastPiece => {
                    let mut last = pieces.last().into_iter();
                    self.inner.write(path, &mut last, permissions)
                }
                Fault::FollowsALink => match self.inner.link_target(path) {
                    Some(target) if self.inner.bytes(&target).is_some() => {
                        self.inner.take_away(&target);
                        self.inner.write(&target, pieces, permissions)
                    }
                    _ => self.inner.write(path, pieces, permissions),
                },
                Fault::MakesWhatALinkNames => match self.inner.link_target(path) {
                    Some(target) if self.inner.bytes(&target).is_none() => {
                        self.inner.write(&target, pieces, permissions)
                    }
                    _ => self.inner.write(path, pieces, permissions),
                },
                _ => self.inner.write(path, pieces, permissions),
            }
        }

        fn rename(&self, from: &Path, to: &Path) -> Result<(), FsError> {
            let kept = self.inner.bytes(from);
            self.inner.rename(from, to)?;
            if let (Fault::RenameLeavesTheOldName, Some(kept)) = (self.fault, kept) {
                self.inner.file(from, &kept);
            }
            if self.fault == Fault::RenameRestamps {
                // An instant no file of the check was written or set at.
                let renamed_at = Modified {
                    seconds: 2_000_000_000,
                    nanoseconds: 0,
                };
                self.inner.set_modified(to, renamed_at);
            }
            Ok(())
        }

        fn remove(&self, path: &Path) -> Result<(), FsError> {
            self.inner.remove(path)
        }

        fn resolve(&self, path: &Path) -> Result<PathBuf, FsError> {
            if self.fault == Fault::ResolveIgnoresLinks && self.inner.stat(path)?.is_some() {
                return Ok(path.to_path_buf());
            }
            if self.fault == Fault::ResolvesALinkToNothing
                && let Some(named) = self.names_nothing(path)
            {
                return Ok(named);
            }
            self.inner.resolve(path)
        }

        fn list(&self, path: &Path) -> Result<Vec<Entry>, FsError> {
            if self.fault == Fault::ListOfAFileIsNotRefused && self.inner.bytes(path).is_some() {
                return Ok(Vec::new());
            }
            let mut entries = self.inner.list(path)?;
            match self.fault {
                Fault::ListLeavesOutAnEntry => {
                    entries.sort_by(|one, other| one.name.cmp(&other.name));
                    entries.pop();
                }
                Fault::ListDoesNotFollowLinks => {
                    for entry in &mut entries {
                        if self.inner.link_target(path.join(&entry.name)).is_some() {
                            entry.kind = Kind::Other;
                        }
                    }
                }
                _ => {}
            }
            Ok(entries)
        }

        fn read_link(&self, path: &Path) -> Result<Option<PathBuf>, FsError> {
            let held = self.inner.read_link(path)?;
            Ok(match self.fault {
                Fault::ReadsALinkToNothingAsNoLink if self.names_nothing(path).is_some() => None,
                Fault::ReadsWhatIsNoLinkAsALink => held.or_else(|| Some(path.to_path_buf())),
                _ => held,
            })
        }
    }

    /// What the contract says of the fake with `fault`. The ground is the
    /// fake underneath, which is the truth the broken one is compared with.
    fn verdict_on(fault: Fault) -> Result<(), Violation> {
        let broken = Broken {
            inner: FakeFs::new(),
            fault,
            claimed: Mutex::default(),
        };
        let ground = broken.inner.ground("/ground");
        check(&broken, &ground)
    }

    #[test]
    fn the_contract_holds_of_the_fake() {
        let fs = FakeFs::new();
        let ground = fs.ground("/ground");

        assert_eq!(check(&fs, &ground), Ok(()));
    }

    #[test]
    fn the_contract_holds_of_the_fake_whatever_time_it_is() {
        let fs = FakeFs::new();
        fs.set_now(Modified {
            seconds: -86_400,
            nanoseconds: 999_999_999,
        });
        let ground = fs.ground("/deep/in/the/ground");

        assert_eq!(check(&fs, &ground), Ok(()));
    }

    #[test]
    fn a_write_that_overwrites_is_refused() {
        assert_eq!(
            verdict_on(Fault::Overwrites),
            Err(Violation::WroteOverAFile)
        );
    }

    #[test]
    fn a_write_that_ignores_the_permissions_is_refused() {
        assert_eq!(
            verdict_on(Fault::IgnoresPermissions),
            Err(Violation::PermissionsNotSaid)
        );
    }

    #[test]
    fn a_write_and_a_stat_that_agree_on_permissions_the_file_does_not_have_are_refused() {
        assert_eq!(
            verdict_on(Fault::AgreesOnPermissionsNotGiven),
            Err(Violation::PermissionsNotGiven)
        );
    }

    #[test]
    fn a_write_that_keeps_only_its_last_piece_is_refused() {
        assert_eq!(
            verdict_on(Fault::KeepsTheLastPiece),
            Err(Violation::ReadDiffers)
        );
    }

    #[test]
    fn a_write_that_follows_a_link_is_refused() {
        assert_eq!(
            verdict_on(Fault::FollowsALink),
            Err(Violation::WroteThroughALink)
        );
    }

    #[test]
    fn a_write_that_makes_the_file_a_link_to_nothing_names_is_refused() {
        assert_eq!(
            verdict_on(Fault::MakesWhatALinkNames),
            Err(Violation::MadeWhatALinkNames)
        );
    }

    #[test]
    fn a_read_of_nothing_that_gives_no_bytes_is_refused() {
        assert_eq!(
            verdict_on(Fault::ReadsNothingAsEmpty),
            Err(Violation::ReadOfNothing)
        );
    }

    #[test]
    fn a_stat_with_the_wrong_size_is_refused() {
        assert_eq!(
            verdict_on(Fault::StatsTheWrongSize),
            Err(Violation::StatOfFile)
        );
    }

    #[test]
    fn a_rename_that_leaves_the_old_name_is_refused() {
        assert_eq!(
            verdict_on(Fault::RenameLeavesTheOldName),
            Err(Violation::RenameLeftTheOldName)
        );
    }

    #[test]
    fn a_rename_that_stamps_the_file_as_modified_then_is_refused() {
        assert_eq!(
            verdict_on(Fault::RenameRestamps),
            Err(Violation::RenameChangedTheStamp)
        );
    }

    #[test]
    fn a_resolve_that_does_not_follow_a_link_is_refused() {
        assert_eq!(
            verdict_on(Fault::ResolveIgnoresLinks),
            Err(Violation::LinkNotResolved)
        );
    }

    #[test]
    fn a_read_of_a_link_to_nothing_that_says_no_link_is_there_is_refused() {
        assert_eq!(
            verdict_on(Fault::ReadsALinkToNothingAsNoLink),
            Err(Violation::LinkNotRead)
        );
    }

    #[test]
    fn a_read_of_what_is_no_link_that_says_a_link_is_there_is_refused() {
        assert_eq!(
            verdict_on(Fault::ReadsWhatIsNoLinkAsALink),
            Err(Violation::NoLinkReadAsOne)
        );
    }

    #[test]
    fn a_stat_of_a_link_to_nothing_that_says_something_is_there_is_refused() {
        assert_eq!(
            verdict_on(Fault::StatsALinkToNothing),
            Err(Violation::StatOfALinkToNothing)
        );
    }

    #[test]
    fn a_resolve_of_a_link_to_nothing_that_is_not_refused_is_refused() {
        assert_eq!(
            verdict_on(Fault::ResolvesALinkToNothing),
            Err(Violation::ResolvedALinkToNothing)
        );
    }

    #[test]
    fn a_listing_that_leaves_out_an_entry_is_refused() {
        assert_eq!(
            verdict_on(Fault::ListLeavesOutAnEntry),
            Err(Violation::ListNotEachOnce)
        );
    }

    #[test]
    fn a_listing_that_does_not_follow_links_is_refused() {
        assert_eq!(
            verdict_on(Fault::ListDoesNotFollowLinks),
            Err(Violation::ListKindsWrong)
        );
    }

    #[test]
    fn a_listing_of_a_file_that_is_not_refused_is_refused() {
        assert_eq!(
            verdict_on(Fault::ListOfAFileIsNotRefused),
            Err(Violation::ListOfAFile)
        );
    }

    /// A ground that cannot set a file's permissions.
    struct NoPermissions<'a>(super::super::FakeGround<'a>);

    impl Ground for NoPermissions<'_> {
        fn root(&self) -> &Path {
            self.0.root()
        }

        fn link(&self, link: &Path, to: &Path) -> Result<(), String> {
            self.0.link(link, to)
        }

        fn directory(&self, path: &Path) -> Result<(), String> {
            self.0.directory(path)
        }

        fn set_modified(&self, path: &Path, to: Modified) -> Result<(), String> {
            self.0.set_modified(path, to)
        }

        fn set_permissions(&self, _: &Path, _: Permissions) -> Result<(), String> {
            Err(String::from("this ground sets no permissions"))
        }

        fn permissions(&self, path: &Path) -> Result<Permissions, String> {
            self.0.permissions(path)
        }
    }

    #[test]
    fn a_ground_that_cannot_do_what_is_asked_is_reported_and_is_not_a_pass() {
        let fs = FakeFs::new();
        let ground = NoPermissions(fs.ground("/ground"));

        assert_eq!(
            check(&fs, &ground),
            Err(Violation::Ground(String::from(
                "this ground sets no permissions"
            )))
        );
    }

    #[test]
    fn a_refusal_of_something_every_rule_allows_is_reported_with_what_was_being_done() {
        let fs = FakeFs::new();
        let ground = fs.ground("/ground");
        let error = FsError::new(FsErrorKind::Denied, "injected");
        fs.fail(super::super::Op::Write, error.clone());

        assert_eq!(
            check(&fs, &ground),
            Err(Violation::Refused {
                doing: "writing a new file",
                error,
            })
        );
    }

    #[test]
    fn each_violation_says_which_rule_broke() {
        let said = [
            (
                Violation::Ground(String::from("no links here")),
                "the ground the check stands on could not do what was asked: no links here",
            ),
            (
                Violation::Refused {
                    doing: "writing a new file",
                    error: FsError::new(FsErrorKind::Denied, "os error 13"),
                },
                "writing a new file was refused: it is not allowed: os error 13",
            ),
            (Violation::StatOfNothing, "the stat of nothing was not none"),
            (
                Violation::ReadOfNothing,
                "reading nothing was not refused as not found",
            ),
            (
                Violation::RemoveOfNothing,
                "removing nothing was not refused as not found",
            ),
            (
                Violation::ResolveOfNothing,
                "resolving nothing was not refused as not found",
            ),
            (
                Violation::ReadDiffers,
                "a file did not read as the pieces it was written from, joined",
            ),
            (
                Violation::StatOfFile,
                "the stat of a file did not say it is a file of the length written",
            ),
            (
                Violation::PermissionsNotSaid,
                "the stat of a file did not say the permissions it was written with",
            ),
            (
                Violation::PermissionsNotGiven,
                "a file did not have the permissions it was written with, though its stat said so",
            ),
            (
                Violation::PermissionsSetNotSaid,
                "the stat of a file did not say the permissions that were set on it",
            ),
            (
                Violation::WroteOverAFile,
                "writing where a file is was not refused as existing, or changed the file",
            ),
            (
                Violation::WroteIntoNoDirectory,
                "writing into a directory that is not there was not refused as not found",
            ),
            (
                Violation::ModifiedNotSaid,
                "the stat of a file did not say when it was modified",
            ),
            (
                Violation::RenameLostTheFile,
                "after a rename the new name did not read the file",
            ),
            (
                Violation::RenameLeftTheOldName,
                "after a rename the old name still held something",
            ),
            (
                Violation::RenameChangedPermissions,
                "a renamed file did not keep its permissions",
            ),
            (
                Violation::RenameChangedTheStamp,
                "a renamed file did not keep its modification time and its size",
            ),
            (
                Violation::RenameOfNothing,
                "renaming nothing was not refused as not found, or changed the target",
            ),
            (
                Violation::DirectoryNotSaid,
                "the stat of a directory did not say it is one",
            ),
            (
                Violation::DirectoryRead,
                "reading a directory was not refused as not a file",
            ),
            (
                Violation::LinkNotResolved,
                "a link did not resolve to the file it names",
            ),
            (
                Violation::FileNotResolvedToItself,
                "a file that is no link did not resolve to itself",
            ),
            (
                Violation::LinkNotFollowed,
                "a link did not stat and read as the file it names",
            ),
            (
                Violation::WroteThroughALink,
                "writing where a link to a file is was not refused as existing, or changed the file",
            ),
            (
                Violation::MadeWhatALinkNames,
                "writing where a link to nothing is was not refused as existing, or made what the link names",
            ),
            (
                Violation::LinkNotRead,
                "a link was not read as the path it holds",
            ),
            (
                Violation::NoLinkReadAsOne,
                "what is no link was not read as no link",
            ),
            (
                Violation::StatOfALinkToNothing,
                "the stat of a link to nothing was not none",
            ),
            (
                Violation::ResolvedALinkToNothing,
                "resolving a link to nothing was not refused as not found",
            ),
            (
                Violation::ListNotEachOnce,
                "a directory did not list each thing it holds once",
            ),
            (
                Violation::ListKindsWrong,
                "a directory listed something with the wrong kind, links followed",
            ),
            (
                Violation::ListOfNothing,
                "listing nothing was not refused as not found",
            ),
            (
                Violation::ListOfAFile,
                "listing a file was not refused as not a file",
            ),
            (Violation::NotRemoved, "a removed file was still there"),
        ];

        for (violation, expected) in &said {
            assert_eq!(violation.to_string(), *expected, "{violation:?}");
        }
        // No two say the same thing.
        for (index, (_, one)) in said.iter().enumerate() {
            for (_, other) in &said[index + 1..] {
                assert_ne!(one, other);
            }
        }
    }
}
