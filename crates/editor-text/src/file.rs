//! Files: a text loaded from a file, through the file port.
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

use std::error::Error;
use std::fmt;
use std::path::Path;

use crate::Text;
use crate::fs::{Fs, FsError, FsErrorKind, Kind, Modified};

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Revision;
    use crate::fs::{Call, FakeFs, FsErrorKind, Op};

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
}
