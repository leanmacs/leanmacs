//! Properties of loading and saving a file, on the published fake of the
//! file port: no file is made.

use std::path::Path;

use editor_text::file::{self, BINARY_WINDOW, Expect, LoadError};
use editor_text::fs::FakeFs;
use proptest::prelude::*;

use crate::{check, edited, file_bytes, initial_text, saved, steps};

/// Where the properties' file is, in the fake.
const PATH: &str = "/dir/a file.txt";

/// A save that is never cancelled.
fn never() -> bool {
    false
}

#[test]
fn any_bytes_with_no_early_nul_load_and_save_back_byte_for_byte() {
    check(512, file_bytes(), |bytes| {
        let fs = FakeFs::new();
        fs.file(PATH, &bytes);
        let window = &bytes[..bytes.len().min(BINARY_WINDOW)];

        let loaded = file::load(&fs, Path::new(PATH), u64::MAX);

        if let Some(offset) = window.iter().position(|byte| *byte == 0) {
            // The generator makes NUL bytes too: such a file is refused,
            // with where the first one is.
            let refused = loaded.err();
            prop_assert_eq!(
                refused,
                Some(LoadError::Binary {
                    offset: offset as u64
                })
            );
            return Ok(());
        }
        let Ok(loaded) = loaded else {
            return Err(TestCaseError::fail("the file did not load"));
        };
        // Saved over itself, and saved as a new file beside it.
        let over = file::save(
            &fs,
            Path::new(PATH),
            &loaded.text.snapshot(),
            Expect::Unchanged(loaded.stamp),
            &never,
        );
        let beside = file::save(
            &fs,
            Path::new("/dir/a copy.txt"),
            &loaded.text.snapshot(),
            Expect::Absent,
            &never,
        );

        prop_assert!(over.is_ok(), "{:?}", over);
        prop_assert!(beside.is_ok(), "{:?}", beside);
        prop_assert_eq!(fs.bytes(PATH), Some(bytes.clone()));
        prop_assert_eq!(fs.bytes("/dir/a copy.txt"), Some(bytes));
        // The two files and their directory, and no temporary file.
        prop_assert_eq!(fs.paths().len(), 3);
        Ok(())
    });
}

#[test]
fn what_a_save_writes_is_what_the_snapshot_holds() {
    check(256, (initial_text(), steps(8)), |(initial, steps)| {
        // The edits leave the rope's pieces uneven, as a text that was
        // only ever loaded does not.
        let (snapshot, reference) = edited(initial, &steps);
        let fs = FakeFs::new();
        fs.directory("/dir");

        let stamp = file::save(&fs, Path::new(PATH), &snapshot, Expect::Absent, &never);

        let expected = saved(&reference);
        prop_assert_eq!(
            stamp.ok().map(|stamp| stamp.size),
            Some(expected.len() as u64)
        );
        prop_assert_eq!(fs.bytes(PATH), Some(expected));
        Ok(())
    });
}
