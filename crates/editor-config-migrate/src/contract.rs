//! The contract of the [`Files`] port: what the conversion assumes of every
//! files adapter, as a check that runs one in a directory the caller owns.
//!
//! [`check_files`] runs on a [`FakeFiles`](crate::fake::FakeFiles) in this
//! module's test and on the real adapter in a temporary directory
//! (`editor-config-migrate-std`'s `tests/contract.rs`), so the fake cannot
//! drift from the file system.

use std::path::Path;

use crate::ports::{Files, Kind};

/// A written file reads back, and a write over it replaces it.
pub const WRITTEN: &str = "a written file reads back, and a write over it replaces it";
/// Nothing at a path is [`Kind::Nothing`].
pub const NOTHING: &str = "nothing at a path is reported as nothing";
/// Making a directory makes its parents, and making it again is fine.
pub const MAKE_DIR: &str = "making a directory makes its parents, and making it again is fine";
/// A directory's names are all of them, hidden ones too, sorted by bytes.
pub const NAMES: &str = "a directory's names are all of them, hidden ones too, sorted by bytes";
/// A removed file is gone.
pub const REMOVE: &str = "a removed file is gone";
/// A renamed file is at its new path, replacing a file there, and gone
/// from its old one.
pub const RENAME: &str = "a renamed file replaces the file at its new path and leaves its old one";

/// Runs every property against `files` in the directory `root`, which is
/// there and empty, and returns the names of those that fail.
pub fn check_files(files: &mut impl Files, root: &Path) -> Vec<&'static str> {
    let mut failed = Vec::new();
    let written = root.join("written");
    if files.write(&written, b"one\n").is_err()
        || files.write(&written, b"two\n").is_err()
        || files.read(&written).as_deref() != Ok(b"two\n".as_slice())
        || files.kind(&written) != Ok(Kind::File)
    {
        failed.push(WRITTEN);
    }
    if files.kind(&root.join("absent")) != Ok(Kind::Nothing) {
        failed.push(NOTHING);
    }
    let deep = root.join("a").join("b");
    if files.make_dir(&deep).is_err()
        || files.make_dir(&deep).is_err()
        || files.kind(&deep) != Ok(Kind::Directory)
        || files.kind(&root.join("a")) != Ok(Kind::Directory)
    {
        failed.push(MAKE_DIR);
    }
    let listed = root.join("listed");
    let made = files.make_dir(&listed.join("a-dir")).is_ok()
        && files.write(&listed.join("B-file"), b"B\n").is_ok()
        && files.write(&listed.join(".hidden"), b"h\n").is_ok();
    let names: Option<Vec<String>> = files.names(&listed).ok().map(|names| {
        names
            .into_iter()
            .map(|n| n.to_string_lossy().into_owned())
            .collect()
    });
    if !made
        || names.as_deref()
            != Some(
                &[
                    ".hidden".to_owned(),
                    "B-file".to_owned(),
                    "a-dir".to_owned(),
                ][..],
            )
    {
        failed.push(NAMES);
    }
    let removed = root.join("removed");
    if files.write(&removed, b"x\n").is_err()
        || files.remove(&removed).is_err()
        || files.kind(&removed) != Ok(Kind::Nothing)
    {
        failed.push(REMOVE);
    }
    let (from, to) = (root.join("from"), root.join("to"));
    if files.write(&from, b"moved\n").is_err()
        || files.write(&to, b"old\n").is_err()
        || files.rename(&from, &to).is_err()
        || files.read(&to).as_deref() != Ok(b"moved\n".as_slice())
        || files.kind(&from) != Ok(Kind::Nothing)
    {
        failed.push(RENAME);
    }
    failed
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::FakeFiles;

    #[test]
    fn the_fake_files_keep_the_contract() {
        let mut files = FakeFiles::new().with_dir("/contract");
        assert_eq!(
            check_files(&mut files, Path::new("/contract")),
            Vec::<&str>::new()
        );
    }
}
