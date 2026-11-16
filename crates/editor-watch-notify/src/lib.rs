//! The watch port's real adapter, over `notify`: inotify on Linux,
//! FSEvents on macOS.
//!
//! [`NotifyWatch`] implements [`editor_watch::Watch`], and its test
//! `tests/contract.rs` holds it to the port's contract on real files in a
//! temporary directory. No `notify` type is in a public item.
//!
//! # One watcher for each registration
//!
//! Each [`Watch::watch`] makes a `notify` watcher of its own, so
//! registrations are independent, a rule of the port: inside one watcher,
//! `unwatch` of a directory drops the inotify watch that a recursive watch
//! of its parent also uses, as notify keeps one descriptor for each path.
//! On Linux each registration is an inotify instance and a thread, and
//! `max_user_instances` (often 128) caps them across every program of the
//! user; `max_user_watches` caps a tree's directories. Both come back as
//! [`RefusalKind::Limit`] at the registration, or as [`Kind::Missed`] for a
//! subdirectory made later that could not be watched. The service shares
//! one registration among the watches of one directory and depth.
//!
//! # What a registration does
//!
//! - It checks the directory first: one that is not there is
//!   [`RefusalKind::NotFound`], a dangling link among them, and something
//!   that is not a directory [`RefusalKind::NotADirectory`].
//! - **Paths are spelled as the caller gave them.** FSEvents reports
//!   canonical, firmlink-resolved paths (`/private/var/...` for a
//!   directory given as `/var/...`), and notify filters what FSEvents
//!   reports on the canonical path. So the directory is canonicalized once,
//!   here, and that spelling is the one registered; every notice under the
//!   canonical spelling is respelled under the given one.
//! - **Events map to notices** (`notices`): a creation is
//!   [`Kind::Created`]; a write of data, a write's close, and an event the
//!   platform could not name are [`Kind::Written`]; a rename is
//!   [`Kind::Renamed`] under each path it names, old and new; a removal is
//!   [`Kind::Removed`]. A change of metadata alone and every other access
//!   are dropped. An event that asks for a rescan (inotify's queue
//!   overflowing, FSEvents' must-scan-subdirectories) and an error in the
//!   event stream are one [`Kind::Missed`] on the directory.
//! - **A gate** keeps the port's rule that once a registration's drop has
//!   returned its sink is never called. The handler holds the gate for
//!   reading while it calls the sink; the drop takes it for writing, shuts
//!   it, and only then drops the watcher. notify's inotify watcher does not
//!   join its thread when it is dropped, so without the gate a notice could
//!   reach the sink after the drop. Its FSEvents watcher joins its run-loop
//!   thread, which may be in the sink: so no registration may be dropped
//!   while what the sink waits for is held, which the service keeps.
//!   Looked at by hand on 2026-11-15: with the gate's check taken out of
//!   the handler, the contract still passed, three runs in the Linux
//!   container, and on macOS. notify's inotify thread ends quickly once it
//!   is told to; the gate is kept because notify does not promise it.
//!
//! A path that is not UTF-8 can only come from inotify: APFS refuses such
//! names, and notify's FSEvents callback would panic on one. It is handed
//! on as it is.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, PoisonError, RwLock};

use editor_watch::{Depth, Kind, Notice, Refusal, RefusalKind, Sink, Watch};
use notify::event::{AccessKind, AccessMode, EventKind, ModifyKind};
use notify::{Config, Event, RecommendedWatcher, RecursiveMode, Watcher as _};

/// The system's watch, over `notify`. It holds nothing: each registration
/// is a watcher of its own.
#[derive(Debug, Clone, Copy)]
pub struct NotifyWatch {
    /// Nothing; made only by [`NotifyWatch::system`].
    _private: (),
}

impl NotifyWatch {
    /// The system's watch. Its users are the process's watch service and
    /// this crate's contract test; the `clippy.toml` of `editor-watch` and
    /// of `editor-ffi` keep it out of everything else.
    pub const fn system() -> Self {
        Self { _private: () }
    }
}

/// A live registration. Dropping it shuts its gate, then drops its
/// watcher.
pub struct Registration {
    /// Open while the sink may be called.
    gate: Arc<RwLock<bool>>,
    /// The watcher, dropped after the gate is shut.
    watcher: Option<RecommendedWatcher>,
}

impl Drop for Registration {
    fn drop(&mut self) {
        *self.gate.write().unwrap_or_else(PoisonError::into_inner) = false;
        drop(self.watcher.take());
    }
}

impl Watch for NotifyWatch {
    type Registration = Registration;

    fn watch(&self, directory: &Path, depth: Depth, sink: Sink) -> Result<Registration, Refusal> {
        let canonical = checked(directory)?;
        let gate = Arc::new(RwLock::new(true));
        let spelling = Spelling {
            given: directory.to_path_buf(),
            canonical: canonical.clone(),
        };
        let open = Arc::clone(&gate);
        let handler = move |event: notify::Result<Event>| {
            let open = open.read().unwrap_or_else(PoisonError::into_inner);
            if !*open {
                return;
            }
            for notice in notices(event, &spelling) {
                sink(notice);
            }
        };
        let mut watcher = RecommendedWatcher::new(handler, Config::default())
            .map_err(|error| refusal(directory, &error))?;
        let mode = match depth {
            Depth::Entries => RecursiveMode::NonRecursive,
            Depth::Tree => RecursiveMode::Recursive,
        };
        watcher
            .watch(&canonical, mode)
            .map_err(|error| refusal(directory, &error))?;
        Ok(Registration {
            gate,
            watcher: Some(watcher),
        })
    }
}

/// The canonical spelling of `directory`, once it is seen to be a
/// directory that is there.
fn checked(directory: &Path) -> Result<PathBuf, Refusal> {
    let refused = |kind, why: &str| {
        Refusal::new(kind, format!("cannot watch {}: {why}", directory.display()))
    };
    let io_refusal = |error: &io::Error| match error.kind() {
        io::ErrorKind::NotFound => refused(RefusalKind::NotFound, "it is not there"),
        io::ErrorKind::PermissionDenied => refused(RefusalKind::Denied, &error.to_string()),
        _ => refused(RefusalKind::Failed, &error.to_string()),
    };
    std::fs::symlink_metadata(directory).map_err(|error| io_refusal(&error))?;
    let metadata = std::fs::metadata(directory).map_err(|error| io_refusal(&error))?;
    if !metadata.is_dir() {
        return Err(refused(RefusalKind::NotADirectory, "it is not a directory"));
    }
    std::fs::canonicalize(directory).map_err(|error| io_refusal(&error))
}

/// The refusal a notify error comes to.
fn refusal(directory: &Path, error: &notify::Error) -> Refusal {
    let kind = match &error.kind {
        notify::ErrorKind::MaxFilesWatch => RefusalKind::Limit,
        notify::ErrorKind::PathNotFound => RefusalKind::NotFound,
        notify::ErrorKind::Io(io) if io.kind() == io::ErrorKind::PermissionDenied => {
            RefusalKind::Denied
        }
        notify::ErrorKind::Io(io) if io.kind() == io::ErrorKind::NotFound => RefusalKind::NotFound,
        _ => RefusalKind::Failed,
    };
    Refusal::new(
        kind,
        format!("cannot watch {}: {error}", directory.display()),
    )
}

/// The two spellings of a registration's directory.
struct Spelling {
    /// As the caller gave it.
    given: PathBuf,
    /// Canonical, as FSEvents reports it.
    canonical: PathBuf,
}

impl Spelling {
    /// `path` under the given spelling.
    fn respell(&self, path: PathBuf) -> PathBuf {
        match path.strip_prefix(&self.canonical) {
            Ok(rest) if rest.as_os_str().is_empty() => self.given.clone(),
            Ok(rest) => self.given.join(rest),
            Err(_) => path,
        }
    }
}

/// The notices one notify event, or error, comes to: the module docs'
/// mapping.
fn notices(event: notify::Result<Event>, spelling: &Spelling) -> Vec<Notice> {
    let missed = || vec![Notice::new(spelling.given.clone(), Kind::Missed)];
    let Ok(event) = event else {
        return missed();
    };
    if event.need_rescan() {
        return missed();
    }
    let kind = match event.kind {
        EventKind::Create(_) => Kind::Created,
        EventKind::Modify(ModifyKind::Name(_)) => Kind::Renamed,
        EventKind::Modify(ModifyKind::Metadata(_)) | EventKind::Access(_)
            if !matches!(
                event.kind,
                EventKind::Access(AccessKind::Close(AccessMode::Write))
            ) =>
        {
            return Vec::new();
        }
        EventKind::Modify(_) | EventKind::Access(_) | EventKind::Any | EventKind::Other => {
            Kind::Written
        }
        EventKind::Remove(_) => Kind::Removed,
    };
    event
        .paths
        .into_iter()
        .map(|path| Notice::new(spelling.respell(path), kind))
        .collect()
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use editor_watch::{Kind, Notice};
    use notify::Event;
    use notify::event::{
        AccessKind, AccessMode, CreateKind, DataChange, EventKind, Flag, MetadataKind, ModifyKind,
        RemoveKind, RenameMode,
    };

    use super::{Spelling, notices};

    fn spelling() -> Spelling {
        Spelling {
            given: PathBuf::from("/var/w"),
            canonical: PathBuf::from("/private/var/w"),
        }
    }

    fn told(kind: EventKind, paths: &[&str]) -> Vec<Notice> {
        let event = paths.iter().fold(Event::new(kind), |event, path| {
            event.add_path(PathBuf::from(path))
        });
        notices(Ok(event), &spelling())
    }

    fn notice(path: &str, kind: Kind) -> Notice {
        Notice::new(Path::new(path), kind)
    }

    #[test]
    fn each_kind_of_event_maps_to_its_notice_respelled_under_the_given_directory() {
        let at = "/private/var/w/f";
        let f = "/var/w/f";

        assert_eq!(
            told(EventKind::Create(CreateKind::File), &[at]),
            [notice(f, Kind::Created)]
        );
        assert_eq!(
            told(
                EventKind::Modify(ModifyKind::Data(DataChange::Content)),
                &[at]
            ),
            [notice(f, Kind::Written)]
        );
        assert_eq!(
            told(EventKind::Modify(ModifyKind::Any), &[at]),
            [notice(f, Kind::Written)]
        );
        assert_eq!(
            told(
                EventKind::Access(AccessKind::Close(AccessMode::Write)),
                &[at]
            ),
            [notice(f, Kind::Written)]
        );
        assert_eq!(told(EventKind::Any, &[at]), [notice(f, Kind::Written)]);
        assert_eq!(told(EventKind::Other, &[at]), [notice(f, Kind::Written)]);
        assert_eq!(
            told(EventKind::Remove(RemoveKind::File), &[at]),
            [notice(f, Kind::Removed)]
        );
    }

    #[test]
    fn a_rename_is_renamed_under_every_path_it_names() {
        assert_eq!(
            told(
                EventKind::Modify(ModifyKind::Name(RenameMode::Both)),
                &["/private/var/w/a", "/private/var/w/b"]
            ),
            [
                notice("/var/w/a", Kind::Renamed),
                notice("/var/w/b", Kind::Renamed)
            ]
        );
        assert_eq!(
            told(
                EventKind::Modify(ModifyKind::Name(RenameMode::From)),
                &["/var/w/a"]
            ),
            [notice("/var/w/a", Kind::Renamed)]
        );
    }

    #[test]
    fn metadata_alone_and_other_accesses_are_dropped() {
        let at = ["/private/var/w/f"];

        assert_eq!(
            told(
                EventKind::Modify(ModifyKind::Metadata(MetadataKind::Any)),
                &at
            ),
            []
        );
        assert_eq!(
            told(EventKind::Access(AccessKind::Open(AccessMode::Any)), &at),
            []
        );
        assert_eq!(
            told(EventKind::Access(AccessKind::Close(AccessMode::Read)), &at),
            []
        );
    }

    #[test]
    fn a_rescan_or_an_error_is_one_missed_on_the_directory() {
        let rescan = Event::new(EventKind::Other)
            .set_flag(Flag::Rescan)
            .add_path(PathBuf::from("/private/var/w/x"));

        assert_eq!(
            notices(Ok(rescan), &spelling()),
            [notice("/var/w", Kind::Missed)]
        );
        assert_eq!(
            notices(Err(notify::Error::generic("lost")), &spelling()),
            [notice("/var/w", Kind::Missed)]
        );
    }

    #[test]
    fn the_directory_itself_is_spelled_as_given() {
        assert_eq!(
            told(EventKind::Remove(RemoveKind::Folder), &["/private/var/w"]),
            [notice("/var/w", Kind::Removed)]
        );
    }
}
