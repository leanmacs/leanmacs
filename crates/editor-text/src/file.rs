//! Files: a text loaded from a file and a snapshot saved as one, through
//! the file port.
//!
//! Everything here reaches the file system through an [`Fs`] the caller
//! supplies, and is tested on the published fake
//! ([`FakeFs`](crate::fs::FakeFs)) with no real file.
//!
//! # Loading
//!
//! [`load`] makes a [`Text`] of the file at a path, in this order:
//!
//! 1. A path that is not absolute is refused ([`LoadError::Relative`])
//!    before the file system is asked: nothing here depends on a working
//!    directory.
//! 2. The file's stat is taken. Nothing there is [`LoadError::NotFound`];
//!    a directory, or anything else that is not a file, is
//!    [`LoadError::NotAFile`], **before it is read**, so a pipe is never
//!    opened.
//! 3. A file longer than the caller's limit is refused
//!    ([`LoadError::TooLarge`]), again before it is read.
//! 4. The file is read, whole, once.
//! 5. What was read is checked against the limit again, for a file that
//!    grew between the stat and the read.
//! 6. A binary file is refused ([`LoadError::Binary`]).
//! 7. The text is made as [`Text::from_bytes`] makes one: a byte that is
//!    not part of valid UTF-8 is kept, as its escape.
//!
//! - **One read, with a limit.** The port reads a file whole: a reader that
//!   streams into the rope would be a second object across the port, with a
//!   fake and a contract of its own, to save one copy. So a load allocates
//!   the bytes read and the rope, and for a file with invalid bytes the
//!   decoded string as well; `tests/snapshot_cost.rs` pins both. The limit
//!   is the caller's, so a caller never reads a file it would not hold.
//! - **A file is binary when it has a NUL byte among its first
//!   [`BINARY_WINDOW`] bytes**, which is git's rule. Not "is not UTF-8":
//!   the text model keeps invalid bytes, and a Latin-1 file must load. Not
//!   the whole file: a megabyte of log with one stray NUL deep inside is
//!   text. A UTF-16 file is refused by this rule, which is right for a text
//!   model that is UTF-8 only. There is no override.
//! - **Line endings are counted and nothing is changed**
//!   ([`LineEndings`]): how many line feeds stand alone and how many follow
//!   a carriage return. A carriage return alone is neither: it ends no row
//!   in the text model. Which ending a new line gets is the editor's
//!   policy; this crate reports the counts.
//! - **The stamp** ([`Stamp`]) is the modification time and the size from
//!   the stat made *before* the read. If the file changes between the two,
//!   the text is newer than its stamp, and a save that expects the stamp
//!   reports the change: what was not loaded is never overwritten
//!   unnoticed. There is no retry and no "kept changing" error: a log that
//!   is being appended to must still open.
//! - **The permissions are not returned.** A save takes them from the file
//!   as it is on disk when the save is made.
//!
//! # Saving
//!
//! [`save`] saves a [`Snapshot`], so the thread that owns the text hands
//! over a value that copies none of it and goes on. The bytes are the
//! snapshot's [`byte_chunks`](Snapshot::byte_chunks), a rope piece at a
//! time. The steps, in order:
//!
//! 1. A path that is not absolute is refused ([`SaveError::Relative`]).
//! 2. The path is resolved: the file a link names is the one replaced, and
//!    the link stays. Nothing there is not an error: the path is then its
//!    own target.
//! 3. The target's stat is taken. Something that is not a file is refused
//!    ([`SaveError::NotAFile`]); the file is checked against what the
//!    caller expects (below); its permissions are kept for the next step.
//! 4. A temporary file is written **in the target's directory**, named
//!    `.<file name>.<n>.tmp` with `n` from 0, with those permissions. A
//!    name that is taken is passed over and left alone, for at most
//!    [`TEMPORARY_NAMES`] names, then [`SaveError::NoTemporaryName`].
//! 5. If the caller says the save is cancelled, it stops
//!    ([`SaveError::Cancelled`]).
//! 6. The target's stat is taken again and checked again: a change made
//!    while the temporary file was being written is caught.
//! 7. The temporary file is renamed over the target.
//! 8. The target's stat is taken: its stamp is returned, for the next save
//!    to expect.
//!
//! - **A crash never leaves a half-written file.** The target is only ever
//!   replaced by a rename of a file that is whole and on disk (the port's
//!   `write` has it there before it returns). A crash before the rename
//!   leaves the old file and perhaps a temporary one; after it, the new
//!   file.
//! - **A failure at any step from 4 to 7 removes the temporary file** and
//!   leaves the target as it was. A failure to remove it is ignored: the
//!   save says why it failed, not why its tidying up did.
//! - **Kept**: the nine permission bits the target had at step 3; a new
//!   file is written with none named, so it gets the platform's default.
//!   And every byte: nothing is translated, so line endings are as the text
//!   holds them.
//! - **Knowingly not kept**, since the file is replaced by a rename: the
//!   other names of a file with hard links (they keep the old content), the
//!   owner and group of a file that is not the user's own, the set-user-id,
//!   set-group-id and sticky bits, extended attributes and access-control
//!   lists. A file whose permissions deny writing is replaced like any
//!   other, since a rename needs only the directory.
//! - **A directory that cannot be written refuses the save**, with the file
//!   system's error. There is no fallback to writing the file in place:
//!   that is the half-written file this is for avoiding.
//! - A file name within a few bytes of the platform's longest cannot take
//!   the temporary name's suffix; the write is refused and so is the save.
//! - **Cost**: nothing sized by the text for a text with no escape; a rope
//!   piece that holds an escape is copied as it is written, one piece at a
//!   time. `tests/snapshot_cost.rs` pins both.
//!
//! # Noticing a change on disk
//!
//! - **What is compared** is a [`Stamp`], the modification time and the
//!   size, **for equality**. Not "newer than": a file put back from a
//!   backup, or written by a tool that sets an old time, has changed.
//! - **A save is told what to expect** ([`Expect`]): the file unchanged
//!   since a stamp, no file, or whatever is there, which checks nothing and
//!   is the override. A save that finds something else is refused with
//!   [`SaveError::Changed`] and what is on disk now, and writes nothing
//!   over the file. The caller reports it, and may ask again expecting
//!   whatever, or load again.
//! - **When**: twice in each save. Before anything is written, so a refusal
//!   costs one stat; and again just before the rename. The window left is
//!   between that stat and the rename.
//! - **Not otherwise.** Nothing here polls or watches: a change is noticed
//!   when a save is asked for.
//! - **What is not seen**: a change that keeps the size and lands in the
//!   same tick of the file system's clock (a second on some, nanoseconds on
//!   APFS and ext4). The fake makes that case on purpose, and a test pins
//!   that it is not seen. A content hash would close it, at the cost of
//!   reading the file at every save.

use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::fmt;
use std::path::{Path, PathBuf};

use crate::fs::{Fs, FsError, FsErrorKind, Kind, Modified, Permissions, Stat};
use crate::{Snapshot, Text};

/// How many bytes from the start of a file are looked at for a NUL byte,
/// which makes the file binary ([`LoadError::Binary`]). It is git's number.
pub const BINARY_WINDOW: usize = 8000;

/// Named byte strings a file may hold, for a test that loads and saves
/// files: every kind of line ending, and bytes that are not UTF-8. They are
/// written out here, and are not files checked in, so that no tool that
/// rewrites line endings or re-encodes text can change them. Published, as
/// the fake is, so that the crates that test against the port share one
/// list.
pub const FIXTURES: &[(&str, &[u8])] = &[
    ("LF line endings", b"one\ntwo\nthree\n"),
    ("CRLF line endings", b"one\r\ntwo\r\nthree\r\n"),
    (
        "mixed line endings, with a carriage return alone",
        b"lf\ncrlf\r\ncr\rlf again\n\r\n",
    ),
    (
        "invalid UTF-8: Latin-1, two bytes that are never valid, a sequence cut short and an overlong form",
        b"caf\xE9\n\xFF\xFE\r\nabc\xE2\x82\n\xC0\xAF\n",
    ),
    (
        "invalid UTF-8 with CRLF endings and no final newline",
        b"na\xEFve\r\n\x80\r\n\xF0\x9F\x98",
    ),
    (
        "a reserved code point, validly encoded",
        "a\u{10DC80}b\n\u{10DCFF}\n".as_bytes(),
    ),
    (
        "two-byte and four-byte characters",
        "h\u{e9}llo w\u{f6}rld \u{1F600}\n\u{1F600}\u{1F600}\r\n".as_bytes(),
    ),
    ("no final newline", b"one\ntwo"),
    ("a NUL byte past the first 8,000 bytes", &LATE_NUL),
    ("empty", b""),
];

/// A file whose first NUL byte is the first byte that does not make a file
/// binary.
const LATE_NUL: [u8; BINARY_WINDOW + 2] = {
    let mut bytes = [b'a'; BINARY_WINDOW + 2];
    bytes[BINARY_WINDOW] = 0;
    bytes[BINARY_WINDOW + 1] = b'\n';
    bytes
};

/// What is compared to tell whether a file changed on disk: when it was
/// modified, and its length in bytes. Two stamps are compared for equality
/// and never ordered: a file put back from a backup is older, and has
/// changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Stamp {
    /// When the file was last modified.
    pub modified: Modified,
    /// The file's length in bytes.
    pub size: u64,
}

impl Stamp {
    /// The stamp of a file whose stat is `stat`.
    pub fn of(stat: &Stat) -> Self {
        Self {
            modified: stat.modified,
            size: stat.size,
        }
    }
}

/// The line endings of a file, counted on its bytes. A carriage return
/// with no line feed after it is neither: it ends no row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct LineEndings {
    /// How many line feeds do not follow a carriage return.
    pub lf: u64,
    /// How many line feeds follow a carriage return.
    pub crlf: u64,
}

impl LineEndings {
    /// The line endings of `bytes`, in one pass.
    pub fn count(bytes: &[u8]) -> Self {
        let mut endings = Self::default();
        let mut after_carriage_return = false;
        for byte in bytes {
            match byte {
                b'\n' if after_carriage_return => endings.crlf += 1,
                b'\n' => endings.lf += 1,
                _ => {}
            }
            after_carriage_return = *byte == b'\r';
        }
        endings
    }
}

/// A file loaded ([`load`]).
pub struct Loaded {
    /// The file's text, at revision 0.
    pub text: Text,
    /// What a save is to expect on disk if the file has not changed since.
    pub stamp: Stamp,
    /// The file's line endings.
    pub endings: LineEndings,
}

/// Why a file was not loaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError {
    /// The path is not absolute. The file system was not asked.
    Relative,
    /// Nothing is at the path.
    NotFound,
    /// What is at the path is not a file. It was not read.
    NotAFile,
    /// The file is longer than the caller's limit.
    TooLarge {
        /// The file's length in bytes.
        size: u64,
        /// The limit it is over.
        limit: u64,
    },
    /// The file has a NUL byte among its first [`BINARY_WINDOW`] bytes.
    Binary {
        /// The offset of the first one.
        offset: u64,
    },
    /// The file system refused, for another reason.
    Fs(FsError),
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Relative => f.write_str("the path is not absolute"),
            Self::NotFound => f.write_str("no file is there"),
            Self::NotAFile => f.write_str("what is there is not a file"),
            Self::TooLarge { size, limit } => {
                write!(
                    f,
                    "the file is {size} bytes long, over the limit of {limit}"
                )
            }
            Self::Binary { offset } => {
                write!(
                    f,
                    "the file is binary: it has a NUL byte at offset {offset}"
                )
            }
            Self::Fs(error) => write!(f, "the file system refused: {error}"),
        }
    }
}

impl Error for LoadError {}

/// A refusal by the file system, as a refusal of a load: nothing there and
/// not a file are the load's own, whichever call met them, and anything
/// else is handed on.
impl From<FsError> for LoadError {
    fn from(error: FsError) -> Self {
        match error.kind {
            FsErrorKind::NotFound => Self::NotFound,
            FsErrorKind::NotAFile => Self::NotAFile,
            FsErrorKind::Denied | FsErrorKind::Exists | FsErrorKind::Other => Self::Fs(error),
        }
    }
}

/// The length `length` as a file's size.
fn size_of(length: usize) -> u64 {
    // A length is at most the address space, which fits.
    u64::try_from(length).unwrap_or(u64::MAX)
}

/// Loads the file at `path`, which must be absolute, unless it is longer
/// than `limit` bytes. The module docs say what is done in what order.
///
/// A link is followed. The text is at revision 0, with an empty log.
pub fn load(fs: &dyn Fs, path: &Path, limit: u64) -> Result<Loaded, LoadError> {
    if !path.is_absolute() {
        return Err(LoadError::Relative);
    }
    let stat = fs.stat(path)?.ok_or(LoadError::NotFound)?;
    if stat.kind != Kind::File {
        return Err(LoadError::NotAFile);
    }
    if stat.size > limit {
        return Err(LoadError::TooLarge {
            size: stat.size,
            limit,
        });
    }
    let bytes = fs.read(path)?;
    // The file may have grown since the stat.
    let size = size_of(bytes.len());
    if size > limit {
        return Err(LoadError::TooLarge { size, limit });
    }
    let window = &bytes[..bytes.len().min(BINARY_WINDOW)];
    if let Some(offset) = window.iter().position(|byte| *byte == 0) {
        return Err(LoadError::Binary {
            offset: size_of(offset),
        });
    }
    Ok(Loaded {
        text: Text::from_bytes(&bytes),
        // The stat made before the read: if the file changed between the
        // two, the text is newer than its stamp, and a save says so.
        stamp: Stamp {
            modified: stat.modified,
            size: stat.size,
        },
        endings: LineEndings::count(&bytes),
    })
}

/// What a save expects to find at the path, which it checks before it
/// writes and again before it replaces the file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Expect {
    /// The file as it was when this stamp was taken: the stamp a [`load`]
    /// or the last [`save`] returned.
    Unchanged(Stamp),
    /// No file: one that has appeared is a change.
    Absent,
    /// Anything. Nothing is checked: this is how a caller overwrites a file
    /// it has been told changed.
    Whatever,
}

impl Expect {
    /// Whether `found`, the stamp of the file there now or none, is what
    /// is expected.
    fn met_by(self, found: Option<Stamp>) -> bool {
        match self {
            Self::Unchanged(stamp) => found == Some(stamp),
            Self::Absent => found.is_none(),
            Self::Whatever => true,
        }
    }
}

/// How many names a save tries for its temporary file before it gives up
/// ([`SaveError::NoTemporaryName`]).
pub const TEMPORARY_NAMES: u32 = 32;

/// Why a file was not saved. Unless it says otherwise, the file is as it
/// was and no temporary file is left.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveError {
    /// The path is not absolute. The file system was not asked.
    Relative,
    /// What is at the path is not a file.
    NotAFile,
    /// The file is not as the caller expected ([`Expect`]): it changed on
    /// disk, appeared, or is gone. Nothing was written over it. It is also
    /// what a save says, with no stamp found, when the file was gone again
    /// once it had been renamed into place: there is then no stamp to hand
    /// back.
    Changed {
        /// The stamp of the file there now, or none when there is no file.
        found: Option<Stamp>,
    },
    /// Every one of the [`TEMPORARY_NAMES`] names tried for the temporary
    /// file was taken.
    NoTemporaryName,
    /// The caller cancelled the save before the file was replaced.
    Cancelled,
    /// The file system refused. If it refused the stat that follows the
    /// rename, the file has been replaced; otherwise it is as it was.
    Fs(FsError),
}

impl fmt::Display for SaveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Relative => f.write_str("the path is not absolute"),
            Self::NotAFile => f.write_str("what is there is not a file"),
            Self::Changed { found: Some(stamp) } => write!(
                f,
                "the file on disk is not the one expected: it is {} bytes long now",
                stamp.size
            ),
            Self::Changed { found: None } => {
                f.write_str("the file on disk is not the one expected: no file is there now")
            }
            Self::NoTemporaryName => write!(
                f,
                "no name was free for a temporary file beside the file, after {TEMPORARY_NAMES} tries"
            ),
            Self::Cancelled => f.write_str("the save was cancelled before the file was replaced"),
            Self::Fs(error) => write!(f, "the file system refused: {error}"),
        }
    }
}

impl Error for SaveError {}

/// Saves what `snapshot` holds as the file at `path`, which must be
/// absolute, if what is there is what `expect` says. Returns the stamp of
/// the file written, for the next save to expect. The module docs say what
/// is done in what order.
///
/// `cancelled` is asked once, when the temporary file is written and before
/// the file is replaced: if it says yes, the file is not replaced.
pub fn save(
    fs: &dyn Fs,
    path: &Path,
    snapshot: &Snapshot,
    expect: Expect,
    cancelled: &dyn Fn() -> bool,
) -> Result<Stamp, SaveError> {
    if !path.is_absolute() {
        return Err(SaveError::Relative);
    }
    // The file a link names is the one replaced, and the link stays.
    // Nothing there is not an error: the path is then its own target.
    let target = match fs.resolve(path) {
        Ok(target) => target,
        Err(error) if error.kind == FsErrorKind::NotFound => path.to_path_buf(),
        Err(error) => return Err(SaveError::Fs(error)),
    };
    let (Some(directory), Some(name)) = (target.parent(), target.file_name()) else {
        // The root, or a path that ends in `..`: no file can be there.
        return Err(SaveError::NotAFile);
    };
    let permissions = expected(fs, &target, expect)?;
    let temporary = write_temporary(fs, directory, name, snapshot, permissions)?;
    // From here on a failure takes the temporary file away, and the target
    // is as it was until the rename.
    let replaced = replace(fs, &temporary, &target, expect, cancelled);
    if replaced.is_err() {
        // Its own failure is ignored: the save says why it failed.
        let _ = fs.remove(&temporary);
    }
    replaced?;
    match fs.stat(&target) {
        Ok(Some(stat)) => Ok(Stamp::of(&stat)),
        Ok(None) => Err(SaveError::Changed { found: None }),
        Err(error) => Err(SaveError::Fs(error)),
    }
}

/// Checks that what is at `target` is a file, or nothing, and is what
/// `expect` says, and returns the permissions of the file there.
fn expected(fs: &dyn Fs, target: &Path, expect: Expect) -> Result<Option<Permissions>, SaveError> {
    let stat = fs.stat(target).map_err(SaveError::Fs)?;
    if stat.is_some_and(|stat| stat.kind != Kind::File) {
        return Err(SaveError::NotAFile);
    }
    let found = stat.as_ref().map(Stamp::of);
    if !expect.met_by(found) {
        return Err(SaveError::Changed { found });
    }
    Ok(stat.map(|stat| stat.permissions))
}

/// Writes what `snapshot` holds to a new file in `directory`, named after
/// `name`, with `permissions`, and returns its path. A name that is taken
/// is passed over and left alone, for [`TEMPORARY_NAMES`] names.
///
/// The name is `.<name>.<n>.tmp`, with `n` counted from 0. There is no
/// randomness and no clock in it: the port's `write` refuses a name in
/// use, which is what makes a counter safe, between two editors as well.
fn write_temporary(
    fs: &dyn Fs,
    directory: &Path,
    name: &OsStr,
    snapshot: &Snapshot,
    permissions: Option<Permissions>,
) -> Result<PathBuf, SaveError> {
    for n in 0..TEMPORARY_NAMES {
        let mut file = OsString::from(".");
        file.push(name);
        file.push(format!(".{n}.tmp"));
        let temporary = directory.join(file);
        // A rope piece at a time, borrowed unless it holds an escape:
        // never the text at once.
        match fs.write(&temporary, &mut snapshot.byte_chunks(), permissions) {
            Ok(()) => return Ok(temporary),
            // Someone else's, or one a crash left: not ours to touch.
            Err(error) if error.kind == FsErrorKind::Exists => {}
            Err(error) => {
                // A write that failed partway may have left a file; one
                // that made none has nothing to remove, and that refusal
                // is ignored.
                let _ = fs.remove(&temporary);
                return Err(SaveError::Fs(error));
            }
        }
    }
    Err(SaveError::NoTemporaryName)
}

/// Puts the temporary file in place of the target, unless the save was
/// cancelled or the target is no longer what `expect` says.
fn replace(
    fs: &dyn Fs,
    temporary: &Path,
    target: &Path,
    expect: Expect,
    cancelled: &dyn Fn() -> bool,
) -> Result<(), SaveError> {
    if cancelled() {
        return Err(SaveError::Cancelled);
    }
    // Again: writing the temporary file took time, and the file may have
    // changed meanwhile.
    expected(fs, target, expect)?;
    fs.rename(temporary, target).map_err(SaveError::Fs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Revision;
    use crate::fs::{Call, FakeFs, FsErrorKind, Op, Permissions};

    /// Where the tests' file is.
    const PATH: &str = "/dir/file.txt";

    /// The time the tests' fake is at when its files are made.
    const THEN: Modified = Modified {
        seconds: 1_700_000_000,
        nanoseconds: 123_456_789,
    };

    /// A limit no test file is over.
    const NO_LIMIT: u64 = u64::MAX;

    /// A fake holding `bytes` at [`PATH`], made at [`THEN`].
    fn fake_with(bytes: &[u8]) -> FakeFs {
        let fs = FakeFs::new();
        fs.set_now(THEN);
        fs.file(PATH, bytes);
        fs
    }

    /// The file at [`PATH`], loaded, or a failed test.
    fn loaded(fs: &FakeFs) -> Loaded {
        match load(fs, Path::new(PATH), NO_LIMIT) {
            Ok(loaded) => loaded,
            Err(error) => panic!("the file did not load: {error}"),
        }
    }

    /// Why the file at `path` did not load, if it did not.
    fn refusal(fs: &FakeFs, path: &str, limit: u64) -> Option<LoadError> {
        load(fs, Path::new(path), limit).err()
    }

    /// The length of `bytes` as a file's size.
    fn size(bytes: &[u8]) -> u64 {
        u64::try_from(bytes.len()).unwrap_or(u64::MAX)
    }

    #[test]
    fn a_file_loads_as_the_text_its_bytes_are_kept_as_with_its_stamp_and_its_line_endings() {
        for (name, bytes) in FIXTURES {
            let fs = fake_with(bytes);

            let loaded = loaded(&fs);

            let expected = Text::from_bytes(bytes);
            assert_eq!(
                loaded.text.current().to_string(),
                expected.current().to_string(),
                "{name}"
            );
            assert_eq!(loaded.text.current().to_bytes(), *bytes, "{name}");
            assert_eq!(loaded.text.current().revision(), Revision::new(0), "{name}");
            assert_eq!(
                loaded.stamp,
                Stamp {
                    modified: THEN,
                    size: size(bytes),
                },
                "{name}"
            );
            assert_eq!(loaded.endings, LineEndings::count(bytes), "{name}");
        }
    }

    #[test]
    fn a_stamps_size_is_the_files_length_in_bytes_and_not_the_texts() {
        // Each invalid byte is four bytes of text.
        let fs = fake_with(b"\xFF\xFE");

        let loaded = loaded(&fs);

        assert_eq!(loaded.stamp.size, 2);
        assert_eq!(loaded.text.current().len(), 8);
    }

    #[test]
    fn line_endings_are_counted_and_a_carriage_return_alone_is_neither() {
        let table: &[(&[u8], u64, u64)] = &[
            (b"", 0, 0),
            (b"no line break", 0, 0),
            (b"a\nb\n", 2, 0),
            (b"a\r\nb\r\n", 0, 2),
            (b"a\nb\r\nc\n", 2, 1),
            (b"a\rb\r", 0, 0),
            (b"\r\r\n\n\r", 1, 1),
            (b"\n", 1, 0),
            (b"\r\n", 0, 1),
            (b"\n\r", 1, 0),
            (b"\xFF\r\n\xFE\n", 1, 1),
        ];

        for (bytes, lf, crlf) in table {
            let expected = LineEndings {
                lf: *lf,
                crlf: *crlf,
            };
            assert_eq!(LineEndings::count(bytes), expected, "{bytes:?}");
            assert_eq!(loaded(&fake_with(bytes)).endings, expected, "{bytes:?}");
        }
    }

    #[test]
    fn a_nul_byte_in_the_first_8000_bytes_is_binary_and_a_first_nul_after_them_is_not() {
        let with_nul_at = |offset: usize| {
            let mut bytes = vec![b'a'; 8001];
            bytes[offset] = 0;
            fake_with(&bytes)
        };

        assert_eq!(
            refusal(&with_nul_at(0), PATH, NO_LIMIT),
            Some(LoadError::Binary { offset: 0 })
        );
        assert_eq!(
            refusal(&with_nul_at(7999), PATH, NO_LIMIT),
            Some(LoadError::Binary { offset: 7999 })
        );
        assert_eq!(refusal(&with_nul_at(8000), PATH, NO_LIMIT), None);
        // The first one is the one reported.
        let fs = fake_with(b"ab\0cd\0");
        assert_eq!(
            refusal(&fs, PATH, NO_LIMIT),
            Some(LoadError::Binary { offset: 2 })
        );
    }

    #[test]
    fn a_file_over_the_limit_is_refused_before_it_is_read() {
        let fs = fake_with(b"eleven byte");

        assert_eq!(
            refusal(&fs, PATH, 10),
            Some(LoadError::TooLarge {
                size: 11,
                limit: 10
            })
        );
        assert_eq!(fs.calls(), [Call::Stat(PATH.into())]);
        // At the limit it loads.
        assert_eq!(refusal(&fs, PATH, 11), None);
    }

    #[test]
    fn a_file_that_grew_past_the_limit_between_the_stat_and_the_read_is_refused() {
        let fs = fake_with(b"eleven byte");
        fs.after(Op::Stat, |fs| fs.file(PATH, b"twelve bytes"));

        assert_eq!(
            refusal(&fs, PATH, 11),
            Some(LoadError::TooLarge {
                size: 12,
                limit: 11
            })
        );
    }

    #[test]
    fn what_is_not_a_file_is_refused_before_it_is_read() {
        let fs = FakeFs::new();
        fs.directory("/dir/sub");
        fs.other("/dir/pipe");

        for path in ["/dir/sub", "/dir/pipe"] {
            assert_eq!(
                refusal(&fs, path, NO_LIMIT),
                Some(LoadError::NotAFile),
                "{path}"
            );
        }
        assert!(fs.calls().iter().all(|call| matches!(call, Call::Stat(_))));
    }

    #[test]
    fn a_path_that_is_not_absolute_is_refused_before_the_file_system_is_asked() {
        let fs = fake_with(b"text");

        for path in ["dir/file.txt", "file.txt", "./file.txt", ""] {
            assert_eq!(
                refusal(&fs, path, NO_LIMIT),
                Some(LoadError::Relative),
                "{path:?}"
            );
        }
        assert_eq!(fs.calls(), []);
    }

    #[test]
    fn nothing_at_the_path_is_not_found() {
        let fs = fake_with(b"text");

        assert_eq!(
            refusal(&fs, "/dir/other.txt", NO_LIMIT),
            Some(LoadError::NotFound)
        );
        // A file taken away between the stat and the read is not found
        // either.
        fs.after(Op::Stat, |fs| fs.take_away(PATH));
        assert_eq!(refusal(&fs, PATH, NO_LIMIT), Some(LoadError::NotFound));
    }

    #[test]
    fn a_refusal_by_the_file_system_is_handed_on_with_its_kind() {
        for op in [Op::Stat, Op::Read] {
            for kind in [FsErrorKind::Denied, FsErrorKind::Other] {
                let fs = fake_with(b"text");
                let error = FsError::new(kind, "injected");
                fs.fail(op, error.clone());

                assert_eq!(
                    refusal(&fs, PATH, NO_LIMIT),
                    Some(LoadError::Fs(error)),
                    "{op:?} {kind:?}"
                );
            }
        }
    }

    #[test]
    fn a_load_follows_a_link() {
        let fs = fake_with(b"the file\n");
        fs.link("/elsewhere/link", PATH);

        let Ok(loaded) = load(&fs, Path::new("/elsewhere/link"), NO_LIMIT) else {
            panic!("the link did not load");
        };

        assert_eq!(loaded.text.current().to_string(), "the file\n");
        assert_eq!(loaded.stamp.size, 9);
    }

    #[test]
    fn the_stamp_is_the_one_taken_before_the_read() {
        let fs = fake_with(b"older");
        fs.after(Op::Stat, |fs| {
            fs.set_now(Modified {
                seconds: THEN.seconds + 60,
                nanoseconds: 0,
            });
            fs.file(PATH, b"newer, and longer");
        });

        let loaded = loaded(&fs);

        // The text is what was read, and the stamp is of the file the stat
        // saw: so a save that expects the stamp finds the file changed.
        assert_eq!(loaded.text.current().to_string(), "newer, and longer");
        assert_eq!(
            loaded.stamp,
            Stamp {
                modified: THEN,
                size: 5
            }
        );
    }

    #[test]
    fn each_refusal_of_a_load_says_what_was_refused() {
        let said = [
            (LoadError::Relative, "the path is not absolute"),
            (LoadError::NotFound, "no file is there"),
            (LoadError::NotAFile, "what is there is not a file"),
            (
                LoadError::TooLarge {
                    size: 11,
                    limit: 10,
                },
                "the file is 11 bytes long, over the limit of 10",
            ),
            (
                LoadError::Binary { offset: 7 },
                "the file is binary: it has a NUL byte at offset 7",
            ),
            (
                LoadError::Fs(FsError::new(FsErrorKind::Denied, "os error 13")),
                "the file system refused: it is not allowed: os error 13",
            ),
        ];

        for (error, expected) in &said {
            assert_eq!(error.to_string(), *expected, "{error:?}");
        }
    }

    /// Where the first temporary file of a save of [`PATH`] is.
    const TEMPORARY: &str = "/dir/.file.txt.0.tmp";

    /// What the tests' file holds before a save.
    const OLD: &[u8] = b"the old text\n";

    /// What the tests save over it.
    const NEW: &str = "the new text, with an \u{e9} and a raw byte \u{10DCFF}\r\n";

    /// What [`NEW`] is saved as.
    const NEW_BYTES: &[u8] = b"the new text, with an \xC3\xA9 and a raw byte \xFF\r\n";

    /// A later time than [`THEN`].
    const LATER: Modified = Modified {
        seconds: THEN.seconds + 3600,
        nanoseconds: 5,
    };

    /// A save that is never cancelled.
    fn never() -> bool {
        false
    }

    /// Saves [`NEW`] at `path`, expecting `expect`.
    fn save_new(fs: &FakeFs, path: &str, expect: Expect) -> Result<Stamp, SaveError> {
        let snapshot = Text::from(NEW).snapshot();
        save(fs, Path::new(path), &snapshot, expect, &never)
    }

    /// The stamp of the file at [`PATH`], as the port says it.
    fn stamp_on_disk(fs: &FakeFs) -> Option<Stamp> {
        let stat = fs.stat(Path::new(PATH)).ok().flatten()?;
        Some(Stamp {
            modified: stat.modified,
            size: stat.size,
        })
    }

    /// The paths a fake holds that are neither the directory nor the file.
    fn left_over(fs: &FakeFs) -> Vec<std::path::PathBuf> {
        fs.paths()
            .into_iter()
            .filter(|path| path != Path::new("/dir") && path != Path::new(PATH))
            .collect()
    }

    /// Makes the call of `op` that is `nth` from now fail with `error`; 0
    /// is the next one.
    fn fail_nth(fs: &FakeFs, op: Op, nth: usize, error: FsError) {
        if nth == 0 {
            fs.fail(op, error);
        } else {
            fs.after(op, move |fs| fail_nth(fs, op, nth - 1, error));
        }
    }

    #[test]
    fn a_file_loaded_and_saved_without_edits_is_byte_identical() {
        for (name, bytes) in FIXTURES {
            let fs = fake_with(bytes);
            let loaded = loaded(&fs);
            fs.set_now(LATER);

            let saved = save(
                &fs,
                Path::new(PATH),
                &loaded.text.snapshot(),
                Expect::Unchanged(loaded.stamp),
                &never,
            );

            assert_eq!(
                saved,
                Ok(Stamp {
                    modified: LATER,
                    size: size(bytes)
                }),
                "{name}"
            );
            assert_eq!(fs.bytes(PATH).as_deref(), Some(*bytes), "{name}");
            // Nothing else is left in the directory.
            assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new(), "{name}");
        }
    }

    #[test]
    fn a_save_writes_a_temporary_file_beside_the_file_and_renames_it_over_the_file() {
        let fs = fake_with(OLD);
        let before = stamp_on_disk(&fs);
        let calls_before = fs.calls().len();

        let saved = save_new(&fs, PATH, Expect::Whatever);

        assert!(saved.is_ok(), "{saved:?}");
        assert_ne!(saved.ok(), before);
        assert_eq!(
            fs.calls()[calls_before..],
            [
                Call::Resolve(PATH.into()),
                Call::Stat(PATH.into()),
                Call::Write(TEMPORARY.into(), Some(FakeFs::DEFAULT_PERMISSIONS)),
                Call::Stat(PATH.into()),
                Call::Rename(TEMPORARY.into(), PATH.into()),
                Call::Stat(PATH.into()),
            ]
        );
        assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES));
        assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new());
    }

    #[test]
    fn a_save_that_fails_at_any_step_leaves_the_file_whole_and_no_temporary_file() {
        // The calls of a save, in order, as the test above pins them.
        let steps = [
            (Op::Resolve, 0),
            (Op::Stat, 0),
            (Op::Write, 0),
            (Op::Stat, 1),
            (Op::Rename, 0),
        ];
        for (op, nth) in steps {
            for kind in [FsErrorKind::Denied, FsErrorKind::Other] {
                let fs = fake_with(OLD);
                let error = FsError::new(kind, "injected");
                fail_nth(&fs, op, nth, error.clone());

                let saved = save_new(&fs, PATH, Expect::Whatever);

                assert_eq!(saved, Err(SaveError::Fs(error)), "{op:?} {nth}");
                assert_eq!(fs.bytes(PATH).as_deref(), Some(OLD), "{op:?} {nth}");
                assert_eq!(
                    left_over(&fs),
                    Vec::<std::path::PathBuf>::new(),
                    "{op:?} {nth}"
                );
            }
        }
    }

    #[test]
    fn a_failure_of_the_stat_after_the_rename_is_reported_and_the_file_is_the_new_one() {
        let fs = fake_with(OLD);
        let error = FsError::new(FsErrorKind::Other, "injected");
        fail_nth(&fs, Op::Stat, 2, error.clone());

        let saved = save_new(&fs, PATH, Expect::Whatever);

        assert_eq!(saved, Err(SaveError::Fs(error)));
        assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES));
        assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new());
    }

    #[test]
    fn a_write_cut_short_leaves_the_file_as_it_was_and_no_temporary_file() {
        for cut in [0, 1, 5, NEW_BYTES.len() - 1] {
            let fs = fake_with(OLD);
            fs.cut_write(cut);

            let saved = save_new(&fs, PATH, Expect::Whatever);

            assert!(
                matches!(&saved, Err(SaveError::Fs(error)) if error.kind == FsErrorKind::Other),
                "{cut}: {saved:?}"
            );
            assert_eq!(fs.bytes(PATH).as_deref(), Some(OLD), "{cut}");
            assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new(), "{cut}");
            assert_eq!(fs.calls().last(), Some(&Call::Remove(TEMPORARY.into())));
        }
    }

    #[test]
    fn a_file_gone_once_it_was_renamed_into_place_is_reported_as_changed() {
        let fs = fake_with(OLD);
        fs.after(Op::Rename, |fs| fs.take_away(PATH));

        let saved = save_new(&fs, PATH, Expect::Whatever);

        // There is no stamp to hand back for the next save to expect.
        assert_eq!(saved, Err(SaveError::Changed { found: None }));
        assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new());
    }

    #[test]
    fn a_failure_to_remove_the_temporary_file_is_ignored() {
        let fs = fake_with(OLD);
        let error = FsError::new(FsErrorKind::Denied, "the rename");
        fs.fail(Op::Rename, error.clone());
        fs.fail(Op::Remove, FsError::new(FsErrorKind::Other, "the remove"));

        let saved = save_new(&fs, PATH, Expect::Whatever);

        // The save says why it failed, not why its tidying up did.
        assert_eq!(saved, Err(SaveError::Fs(error)));
        assert_eq!(fs.bytes(PATH).as_deref(), Some(OLD));
    }

    #[test]
    fn the_saved_file_keeps_the_permissions_the_file_had() {
        let fs = fake_with(OLD);
        let had = Permissions::new(0o750);
        assert_ne!(had, FakeFs::DEFAULT_PERMISSIONS);
        fs.set_permissions(PATH, had);

        let saved = save_new(&fs, PATH, Expect::Whatever);

        assert!(saved.is_ok(), "{saved:?}");
        assert_eq!(fs.permissions(PATH), Some(had));
        // They were handed to the port's write, and not set afterwards.
        assert!(
            fs.calls()
                .contains(&Call::Write(TEMPORARY.into(), Some(had)))
        );
    }

    #[test]
    fn a_new_file_is_written_with_no_permissions_named() {
        let fs = FakeFs::new();
        fs.directory("/dir");

        let saved = save_new(&fs, PATH, Expect::Absent);

        assert!(saved.is_ok(), "{saved:?}");
        assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES));
        assert!(fs.calls().contains(&Call::Write(TEMPORARY.into(), None)));
        assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new());
    }

    /// A way a file comes not to be what a save expects: its name, what the
    /// save expected, and a change to the fake made since.
    type Change = (&'static str, Expect, fn(&FakeFs));

    /// The ways the tests make a file not what a save expects.
    fn changes() -> Vec<Change> {
        let loaded = Stamp {
            modified: THEN,
            size: size(OLD),
        };
        vec![
            (
                "another time and the same size",
                Expect::Unchanged(loaded),
                |fs| assert!(fs.set_modified(PATH, LATER)),
            ),
            (
                "the same time and another size",
                Expect::Unchanged(loaded),
                |fs| fs.file(PATH, b"the old text, and more\n"),
            ),
            ("an earlier time", Expect::Unchanged(loaded), |fs| {
                let earlier = Modified {
                    seconds: THEN.seconds - 86_400,
                    nanoseconds: THEN.nanoseconds,
                };
                assert!(fs.set_modified(PATH, earlier));
            }),
            ("removed", Expect::Unchanged(loaded), |fs| {
                fs.take_away(PATH);
            }),
            ("appeared where none was expected", Expect::Absent, |_| {}),
        ]
    }

    #[test]
    fn a_file_that_is_not_as_expected_is_not_overwritten() {
        for (name, expect, change) in changes() {
            let fs = fake_with(OLD);
            change(&fs);
            let found = stamp_on_disk(&fs);
            let held = fs.bytes(PATH);
            let calls_before = fs.calls().len();

            let saved = save_new(&fs, PATH, expect);

            assert_eq!(saved, Err(SaveError::Changed { found }), "{name}");
            assert_eq!(fs.bytes(PATH), held, "{name}");
            assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new(), "{name}");
            // A refusal costs one stat: nothing was written.
            assert_eq!(
                fs.calls()[calls_before..],
                [Call::Resolve(PATH.into()), Call::Stat(PATH.into())],
                "{name}"
            );
        }
    }

    #[test]
    fn whatever_overwrites() {
        for (name, _, change) in changes() {
            let fs = fake_with(OLD);
            change(&fs);

            let saved = save_new(&fs, PATH, Expect::Whatever);

            assert!(saved.is_ok(), "{name}: {saved:?}");
            assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES), "{name}");
        }
    }

    #[test]
    fn a_change_that_keeps_the_size_within_one_tick_of_the_clock_is_not_seen() {
        let fs = fake_with(OLD);
        let loaded = loaded(&fs);
        // Someone else writes the file, the same length, before the file
        // system's clock has moved: the fake's time is the one a test sets.
        let theirs = b"THE OLD TEXT\n";
        assert_eq!(theirs.len(), OLD.len());
        fs.file(PATH, theirs);

        let saved = save_new(&fs, PATH, Expect::Unchanged(loaded.stamp));

        // A stamp is a time and a size, and both are what they were. This
        // is the limit of the check, pinned so that it is a recorded fact.
        assert!(saved.is_ok(), "{saved:?}");
        assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES));
    }

    #[test]
    fn a_file_changed_while_the_temporary_file_was_written_is_not_overwritten() {
        let fs = fake_with(OLD);
        let loaded = loaded(&fs);
        fs.after(Op::Write, |fs| {
            fs.set_now(LATER);
            fs.file(PATH, b"someone else's text\n");
        });

        let saved = save_new(&fs, PATH, Expect::Unchanged(loaded.stamp));

        assert_eq!(
            saved,
            Err(SaveError::Changed {
                found: Some(Stamp {
                    modified: LATER,
                    size: 20
                })
            })
        );
        assert_eq!(
            fs.bytes(PATH).as_deref(),
            Some(b"someone else's text\n".as_slice())
        );
        assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new());
    }

    #[test]
    fn a_save_through_a_link_replaces_the_file_the_link_names_and_keeps_the_link() {
        let fs = fake_with(OLD);
        fs.link("/elsewhere/link.txt", PATH);

        let saved = save_new(&fs, "/elsewhere/link.txt", Expect::Whatever);

        assert!(saved.is_ok(), "{saved:?}");
        assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES));
        assert_eq!(fs.link_target("/elsewhere/link.txt"), Some(PATH.into()));
        // The temporary file was beside the file, not beside the link: a
        // rename is one step only within a directory's file system.
        assert!(
            fs.calls()
                .contains(&Call::Rename(TEMPORARY.into(), PATH.into()))
        );
        assert_eq!(
            fs.paths(),
            ["/dir", PATH, "/elsewhere", "/elsewhere/link.txt"].map(std::path::PathBuf::from)
        );
    }

    #[test]
    fn a_taken_temporary_name_is_passed_over_and_left_alone() {
        let fs = fake_with(OLD);
        fs.file(TEMPORARY, b"left by a crash");

        let saved = save_new(&fs, PATH, Expect::Whatever);

        assert!(saved.is_ok(), "{saved:?}");
        assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES));
        assert_eq!(
            fs.bytes(TEMPORARY).as_deref(),
            Some(b"left by a crash".as_slice())
        );
        assert_eq!(left_over(&fs), [std::path::PathBuf::from(TEMPORARY)]);
        assert!(
            fs.calls()
                .contains(&Call::Rename("/dir/.file.txt.1.tmp".into(), PATH.into()))
        );
    }

    #[test]
    fn with_every_temporary_name_taken_the_save_is_refused_after_32_tries() {
        let fs = fake_with(OLD);
        // More names are taken than are tried, so the bound is the save's.
        for n in 0..40 {
            fs.file(format!("/dir/.file.txt.{n}.tmp"), b"taken");
        }

        let saved = save_new(&fs, PATH, Expect::Whatever);

        assert_eq!(saved, Err(SaveError::NoTemporaryName));
        let writes: Vec<Call> = fs
            .calls()
            .into_iter()
            .filter(|call| call.op() == Op::Write)
            .collect();
        assert_eq!(writes.len(), 32);
        assert_eq!(
            writes.last(),
            Some(&Call::Write(
                "/dir/.file.txt.31.tmp".into(),
                Some(FakeFs::DEFAULT_PERMISSIONS)
            ))
        );
        assert_eq!(fs.bytes(PATH).as_deref(), Some(OLD));
        // None of the names it found taken was removed.
        assert_eq!(left_over(&fs).len(), 40);
    }

    #[test]
    fn a_cancelled_save_does_not_replace_the_file_and_leaves_no_temporary_file() {
        let fs = fake_with(OLD);
        let calls_before = fs.calls().len();
        let snapshot = Text::from(NEW).snapshot();

        let saved = save(&fs, Path::new(PATH), &snapshot, Expect::Whatever, &|| true);

        assert_eq!(saved, Err(SaveError::Cancelled));
        assert_eq!(fs.bytes(PATH).as_deref(), Some(OLD));
        assert_eq!(left_over(&fs), Vec::<std::path::PathBuf>::new());
        // The flag is read once the temporary file is written, and the
        // file is not looked at again.
        assert_eq!(
            fs.calls()[calls_before..],
            [
                Call::Resolve(PATH.into()),
                Call::Stat(PATH.into()),
                Call::Write(TEMPORARY.into(), Some(FakeFs::DEFAULT_PERMISSIONS)),
                Call::Remove(TEMPORARY.into()),
            ]
        );
    }

    #[test]
    fn a_save_is_not_cancelled_by_a_flag_that_says_no() {
        let fs = fake_with(OLD);
        let asked = std::cell::Cell::new(0);
        let snapshot = Text::from(NEW).snapshot();

        let saved = save(&fs, Path::new(PATH), &snapshot, Expect::Whatever, &|| {
            asked.set(asked.get() + 1);
            false
        });

        assert!(saved.is_ok(), "{saved:?}");
        assert_eq!(asked.get(), 1);
        assert_eq!(fs.bytes(PATH).as_deref(), Some(NEW_BYTES));
    }

    #[test]
    fn a_save_returns_the_stamp_of_what_it_wrote_and_the_next_save_accepts_it() {
        let fs = fake_with(OLD);
        let loaded = loaded(&fs);
        fs.set_now(LATER);

        let first = save_new(&fs, PATH, Expect::Unchanged(loaded.stamp));

        let expected = Stamp {
            modified: LATER,
            size: size(NEW_BYTES),
        };
        assert_eq!(first, Ok(expected));
        assert_eq!(stamp_on_disk(&fs), Some(expected));
        // The stamp of the load is stale now, and the save's is not.
        assert_eq!(
            save_new(&fs, PATH, Expect::Unchanged(loaded.stamp)),
            Err(SaveError::Changed {
                found: Some(expected)
            })
        );
        assert_eq!(
            save_new(&fs, PATH, Expect::Unchanged(expected)),
            Ok(expected)
        );
    }

    #[test]
    fn a_directory_that_cannot_be_written_refuses_the_save_and_the_file_is_as_it_was() {
        let fs = fake_with(OLD);
        let error = FsError::new(FsErrorKind::Denied, "the directory is read-only");
        fs.fail(Op::Write, error.clone());

        let saved = save_new(&fs, PATH, Expect::Whatever);

        // There is no fallback to writing the file in place.
        assert_eq!(saved, Err(SaveError::Fs(error)));
        assert_eq!(fs.bytes(PATH).as_deref(), Some(OLD));
        assert!(
            fs.calls()
                .iter()
                .all(|call| !matches!(call, Call::Write(path, _) if path == Path::new(PATH)))
        );
    }

    #[test]
    fn a_save_into_a_directory_that_is_not_there_is_refused_as_not_found() {
        let fs = FakeFs::new();

        let saved = save_new(&fs, "/nowhere/file.txt", Expect::Absent);

        assert!(
            matches!(&saved, Err(SaveError::Fs(error)) if error.kind == FsErrorKind::NotFound),
            "{saved:?}"
        );
        assert_eq!(fs.paths(), Vec::<std::path::PathBuf>::new());
    }

    #[test]
    fn what_is_not_a_file_is_not_replaced() {
        let fs = FakeFs::new();
        fs.directory("/dir/sub");
        fs.other("/dir/pipe");

        for path in ["/dir/sub", "/dir/pipe", "/"] {
            assert_eq!(
                save_new(&fs, path, Expect::Whatever),
                Err(SaveError::NotAFile),
                "{path}"
            );
        }
        assert!(fs.calls().iter().all(|call| call.op() != Op::Write));
        assert_eq!(
            fs.paths(),
            ["/dir", "/dir/pipe", "/dir/sub"].map(std::path::PathBuf::from)
        );
    }

    #[test]
    fn a_save_to_a_path_that_is_not_absolute_is_refused_before_anything_is_asked() {
        let fs = fake_with(OLD);
        let calls_before = fs.calls().len();

        for path in ["dir/file.txt", "file.txt", ""] {
            assert_eq!(
                save_new(&fs, path, Expect::Whatever),
                Err(SaveError::Relative),
                "{path:?}"
            );
        }
        assert_eq!(fs.calls().len(), calls_before);
    }

    #[test]
    fn each_refusal_of_a_save_says_what_was_refused() {
        let said = [
            (SaveError::Relative, "the path is not absolute"),
            (SaveError::NotAFile, "what is there is not a file"),
            (
                SaveError::Changed {
                    found: Some(Stamp {
                        modified: THEN,
                        size: 42,
                    }),
                },
                "the file on disk is not the one expected: it is 42 bytes long now",
            ),
            (
                SaveError::Changed { found: None },
                "the file on disk is not the one expected: no file is there now",
            ),
            (
                SaveError::NoTemporaryName,
                "no name was free for a temporary file beside the file, after 32 tries",
            ),
            (
                SaveError::Cancelled,
                "the save was cancelled before the file was replaced",
            ),
            (
                SaveError::Fs(FsError::new(FsErrorKind::Denied, "os error 13")),
                "the file system refused: it is not allowed: os error 13",
            ),
        ];

        for (error, expected) in &said {
            assert_eq!(error.to_string(), *expected, "{error:?}");
        }
    }
}
