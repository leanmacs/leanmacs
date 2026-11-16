//! The port's contract held against its fake, and against fakes written to
//! break one rule each, which shows that the contract bites.
//!
//! The directory is made up: nothing here is a real file or a real watch.
//! The fake's file system in memory is the ground.

use std::path::Path;

use editor_watch::contract::{
    self, CREATED, DROPPED_IS_SILENT, INDEPENDENT, LIVE_ON_RETURN, REFUSED, REMOVED, RENAMED,
    RENAMED_OVER, SPELLED_AS_GIVEN, TREE, TREE_NEW_SUBDIRECTORY, WRITTEN,
};
use editor_watch::fake::{FakeWatch, Flaws};

/// The made-up directory the contract runs in.
const DIR: &str = "/fake/contract";

/// The properties a fake that breaks the rules `flaws` names fails.
fn failures(flaws: Flaws) -> Vec<&'static str> {
    let fake = FakeWatch::flawed(flaws);
    let ground = fake.ground();
    ground.make_dir(Path::new("/fake"));
    ground.make_dir(Path::new(DIR));
    contract::check(fake, &ground, Path::new(DIR))
}

#[test]
fn the_fake_keeps_the_contract() {
    assert_eq!(failures(Flaws::default()), [""; 0]);
}

#[test]
fn a_registration_that_goes_live_late_now_and_then_is_reported() {
    let flaws = Flaws {
        live_late: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [LIVE_ON_RETURN]);
}

#[test]
fn a_fake_that_misses_creations_is_reported() {
    let flaws = Flaws {
        misses_creation: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [CREATED, TREE_NEW_SUBDIRECTORY]);
}

#[test]
fn a_fake_that_misses_writes_is_reported() {
    let flaws = Flaws {
        misses_writes: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [WRITTEN, TREE]);
}

#[test]
fn a_fake_that_misses_removals_is_reported() {
    let flaws = Flaws {
        misses_removal: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [REMOVED]);
}

#[test]
fn a_fake_that_drops_renames_is_reported() {
    let flaws = Flaws {
        drops_renames: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [RENAMED, RENAMED_OVER]);
}

#[test]
fn a_fake_that_misses_a_rename_over_is_reported() {
    let flaws = Flaws {
        misses_rename_over: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [RENAMED_OVER]);
}

#[test]
fn a_fake_whose_tree_is_only_its_entries_is_reported() {
    let flaws = Flaws {
        no_tree: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [TREE, TREE_NEW_SUBDIRECTORY]);
}

#[test]
fn a_fake_whose_tree_misses_new_subdirectories_is_reported() {
    let flaws = Flaws {
        no_new_subdirectories: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [TREE_NEW_SUBDIRECTORY]);
}

#[test]
fn a_fake_that_tells_the_canonical_spelling_is_reported() {
    let flaws = Flaws {
        canonical_spelling: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [SPELLED_AS_GIVEN]);
}

#[test]
fn a_fake_whose_drop_ends_every_registration_of_the_directory_is_reported() {
    let flaws = Flaws {
        shared_drop: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [INDEPENDENT, DROPPED_IS_SILENT]);
}

#[test]
fn a_fake_that_calls_a_sink_after_its_drop_is_reported() {
    let flaws = Flaws {
        late_after_drop: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [DROPPED_IS_SILENT]);
}

#[test]
fn a_fake_that_refuses_nothing_is_reported() {
    let flaws = Flaws {
        accepts_anything: true,
        ..Flaws::default()
    };

    assert_eq!(failures(flaws), [REFUSED]);
}
