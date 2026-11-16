//! Watching files and directories: what the editor needs of a watch, in its
//! own terms, and the service that owns every watch it starts.
//!
//! [`Watch`] is the port: watch a directory, its entries or its whole tree
//! ([`Depth`]), and have each change inside it told to a [`Sink`] as a
//! [`Notice`]. The crate defines it, publishes a fake of it
//! (`fake::FakeWatch`) and the contract every implementation keeps
//! (`contract::check`); the real adapter, over `notify`, is another crate
//! (`editor-watch-notify`). Above the port, `batch` is the coalescing
//! rule, pure, and `service::Service` is what the editor asks: a watch on
//! a file or a directory, owned under an id of the caller's, whose changes
//! are coalesced over a window and delivered a read at a time, each read
//! completed through a closure the service is given. Time reaches the
//! crate only through `clock::Clock`. The crate has no dependencies and
//! knows nothing about Lean.
//!
//! # The rules of the port
//!
//! - **[`Watch::watch`]** is refused, as a value, for a directory that is
//!   not there ([`RefusalKind::NotFound`]), for something that is not a
//!   directory ([`RefusalKind::NotADirectory`]), and for one the system
//!   will not let it watch ([`RefusalKind::Denied`], [`RefusalKind::Limit`]).
//!   A path that is not absolute, or has a `..` component, is the core's to
//!   refuse ([`refusal_before_watch`]), so no adapter is asked one.
//! - **A registration is live when `watch` returns.** A change made after
//!   that is noticed.
//! - It notices each entry created, written, renamed (under its old path
//!   and under its new one) or removed inside the directory, or anywhere
//!   under it for [`Depth::Tree`]. That includes subdirectories made after
//!   `watch` returned.
//! - It may notice *more* than it covers: FSEvents is recursive underneath,
//!   and an earlier change can show up in a flag. It never notices *less*.
//!   The service's filter is the rule.
//! - A notice names its path under the directory as the caller spelled it,
//!   whatever spelling the platform reports it under.
//! - Registrations are independent: two of one directory each notice its
//!   changes, and dropping one leaves the other whole.
//! - **After a registration's drop returns, its sink is never called
//!   again.**
//! - Notices from one registration reach its sink in the order the
//!   platform reported them.
//! - An overflow, the platform's queue of changes lost, is one
//!   [`Kind::Missed`] notice naming the directory.
//! - A change of metadata alone, and a read, are not noticed.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Another kind of change | A variant of [`Kind`], its bit in `batch::Kinds` | A property of `contract`, the fake's ground making it, and the adapter's mapping |
//! | Another failure the editor decides on | A variant of [`RefusalKind`] | The property that asks for it |
//! | A rule of the service (what a delivery holds, what cancelling means) | `service::Service`, or `batch` for what a batch holds | The service's or the batch's unit tests, on the fake, and a service property of `contract` where a real file system must show it |
//! | Another way for a test to set the fake up | A method of `fake::FakeWatch` | The fake's tests |

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

/// How much of a directory a registration covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Depth {
    /// What is directly inside it, and itself.
    Entries,
    /// Everything under it, at any depth, and itself.
    Tree,
}

/// What happened to a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    /// It was made.
    Created,
    /// Its content was written.
    Written,
    /// It was renamed, from or to this path.
    Renamed,
    /// It was removed.
    Removed,
    /// Changes were lost: the platform's queue overflowed, or a batch held
    /// more paths than its bound. The path is the directory's, or the
    /// watch's.
    Missed,
}

/// One change, as a registration notices it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Notice {
    /// The path, under the directory as the caller spelled it.
    pub path: PathBuf,
    /// What happened there.
    pub kind: Kind,
}

impl Notice {
    /// A notice of `kind` at `path`.
    pub fn new(path: impl Into<PathBuf>, kind: Kind) -> Self {
        Self {
            path: path.into(),
            kind,
        }
    }
}

/// What a registration tells each notice to. It is called on the adapter's
/// thread, one notice at a time, in order.
pub type Sink = Arc<dyn Fn(Notice) + Send + Sync>;

/// Why something was not watched: a kind the editor decides on, and the
/// platform's words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    /// What the editor decides on.
    pub kind: RefusalKind,
    /// The platform's words, for a person. It names the path.
    pub detail: String,
}

impl Refusal {
    /// A refusal of `kind` that says `detail`.
    pub fn new(kind: RefusalKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }
}

/// What a refusal is, as the editor decides on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RefusalKind {
    /// The path is not absolute, or has a `..` component.
    NotAbsolute,
    /// The directory is not there.
    NotFound,
    /// The path names something that is not a directory.
    NotADirectory,
    /// The system does not let it be watched.
    Denied,
    /// The system's limit on watches is reached.
    Limit,
    /// The service has shut down, and starts nothing more.
    ShutDown,
    /// Anything else; the detail says what.
    Failed,
}

/// Watching, as far as the editor needs it. The module docs have the rules;
/// `contract::check` holds an implementation to them.
///
/// It is `Send + Sync`: the service registers on a thread of each start's.
pub trait Watch: Send + Sync + 'static {
    /// A live registration. Dropping it ends it: once the drop returns, its
    /// sink is never called again.
    type Registration: Send + 'static;

    /// Watches `directory` to `depth`, telling each change to `sink`, from
    /// the moment it returns. A directory that cannot be watched is a
    /// refusal, never a panic.
    fn watch(
        &self,
        directory: &Path,
        depth: Depth,
        sink: Sink,
    ) -> Result<Self::Registration, Refusal>;
}

/// Why `path` may not be watched at all, if it may not: it is not absolute,
/// or it has a `..` component, which would make its spelling ambiguous. It
/// is the core's rule, so no adapter is asked such a path.
pub fn refusal_before_watch(path: &Path) -> Option<Refusal> {
    if !path.is_absolute() {
        return Some(Refusal::new(
            RefusalKind::NotAbsolute,
            format!("cannot watch {}: the path is not absolute", path.display()),
        ));
    }
    if path.components().any(|part| part == Component::ParentDir) {
        return Some(Refusal::new(
            RefusalKind::NotAbsolute,
            format!(
                "cannot watch {}: the path has a `..` component",
                path.display()
            ),
        ));
    }
    None
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{RefusalKind, refusal_before_watch};

    fn kind(path: &str) -> Option<RefusalKind> {
        refusal_before_watch(Path::new(path)).map(|refusal| refusal.kind)
    }

    #[test]
    fn a_path_that_is_not_absolute_is_refused_and_named() {
        let refusal = refusal_before_watch(Path::new("relative/dir")).expect("refused");

        assert_eq!(refusal.kind, RefusalKind::NotAbsolute);
        assert!(refusal.detail.contains("relative/dir"));
        assert!(refusal.detail.contains("not absolute"));
        assert_eq!(kind(""), Some(RefusalKind::NotAbsolute));
    }

    #[test]
    fn a_path_with_a_parent_component_is_refused_and_says_so() {
        let refusal = refusal_before_watch(Path::new("/a/../b")).expect("refused");

        assert_eq!(refusal.kind, RefusalKind::NotAbsolute);
        assert!(refusal.detail.contains("/a/../b"));
        assert!(refusal.detail.contains("`..`"));
    }

    #[test]
    fn an_absolute_path_is_not_refused_a_dot_component_among_them() {
        assert_eq!(kind("/"), None);
        assert_eq!(kind("/a/b"), None);
        assert_eq!(kind("/a/./b"), None);
    }
}
