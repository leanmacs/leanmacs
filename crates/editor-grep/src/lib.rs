//! Project search: what the editor needs of the files under a directory, in
//! its own terms.
//!
//! [`Files`] is the port: walk the files under a root that ignore files and
//! the hidden-file rule leave in ([`Files::walk`]), and read a file a row at
//! a time, visiting the rows a predicate holds for ([`Files::rows`]). The
//! crate defines it, publishes a fake of it ([`fake::FakeFiles`]) and the
//! contract every implementation keeps ([`contract::check`]); the real
//! adapter, over ripgrep's libraries `ignore` and `grep-searcher`, is
//! another crate (`editor-grep-ripgrep`). The crate has no dependencies and
//! knows nothing about Lean.
//!
//! # The rules of the port
//!
//! - **[`Files::walk`]** visits each file under the root, by its path
//!   relative to the root, depth first, each directory's entries in the
//!   order of the bytes of their names. So `a/b` comes before `a-c`,
//!   though `-` is before `/`.
//! - It leaves out an entry whose name starts with `.` (and so `.git` and
//!   everything under it), and an entry an ignore file excludes, with
//!   everything under it. Which ignore files are read is the adapter's: the
//!   real one reads `.gitignore`, `.ignore`, `.git/info/exclude` and the
//!   global excludes. The fake has no ignore files; a test excludes a path
//!   by name.
//! - It visits files alone: a directory is walked into, never visited.
//! - It is refused, as a value, for a root that is not there
//!   ([`RefusalKind::NotFound`]), that is not a directory
//!   ([`RefusalKind::NotADirectory`]), or that the system will not let it
//!   read ([`RefusalKind::Denied`]). An entry below the root that cannot be
//!   read is left out, never a refusal. A root that is not absolute, or has
//!   a `..` component, is the core's to refuse ([`refusal_before_search`]),
//!   so no adapter is asked one.
//! - **[`Files::rows`]** reads a file a row at a time. A row ends at a line
//!   feed, which is not part of its text; a `\r` before it is. The last row
//!   is a row though no line feed ends it, and an empty file has none. Rows
//!   are numbered from 0, and each has the byte offset of its start in the
//!   file. A row that is not UTF-8 is decoded lossily.
//! - `holds` is asked of each row's text once, in order, and the rows it
//!   holds for are visited, and no other.
//! - **A binary file**, one that holds a NUL byte, is [`Read::Binary`] and
//!   no row of it is visited.
//! - [`Flow::Stop`] from a visit ends the walk or the read: nothing more is
//!   visited.
//!
//! # Where an addition goes
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Another rule of what is walked or read | The module docs here, and a property of [`contract`] | The property, on the fake and on implementations written to break it; the adapter's own tests for what only real ignore files show |
//! | Another failure the editor decides on | A variant of [`RefusalKind`] | The property that asks for it |
//! | Another way for a test to set the fake up | A method of [`fake::FakeFiles`] | The fake's tests |

pub mod contract;
pub mod fake;

use std::path::{Component, Path};

/// Whether a walk or a read goes on after a visit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Flow {
    /// Go on.
    Go,
    /// Stop: nothing more is visited.
    Stop,
}

/// One row of a file, as [`Files::rows`] visits it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Row<'a> {
    /// Its number, from 0.
    pub number: usize,
    /// The byte offset of its start in the file.
    pub offset: usize,
    /// Its text, without the line feed that ends it; a `\r` is kept.
    pub text: &'a str,
}

/// What a read of a file came to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Read {
    /// It was read, and the rows `holds` held for were visited.
    Searched,
    /// It holds a NUL byte, and no row of it was visited.
    Binary,
}

/// Why something was not searched: a kind the editor decides on, and the
/// words for a person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    /// What the editor decides on.
    pub kind: RefusalKind,
    /// The words for a person. A refusal of a path names it.
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
    /// The root is not absolute, or has a `..` component.
    NotAbsolute,
    /// The root is not there.
    NotFound,
    /// The root is not a directory.
    NotADirectory,
    /// The system does not let it be read.
    Denied,
    /// The pattern does not parse, or its engine refuses it; the detail is
    /// the sentence the echo area says.
    Invalid,
    /// The service has shut down, and starts nothing more.
    ShutDown,
    /// Anything else; the detail says what.
    Failed,
}

/// The files under a directory, as far as a project search needs them. The
/// module docs have the rules; [`contract::check`] holds an implementation
/// to them.
pub trait Files {
    /// Visits each file under `root` that the walk leaves in, by its path
    /// relative to `root`, in the walk's order, until a visit says
    /// [`Flow::Stop`]. A root that cannot be walked is a refusal, never a
    /// panic.
    fn walk(&mut self, root: &Path, visit: &mut dyn FnMut(&Path) -> Flow) -> Result<(), Refusal>;

    /// Reads the file at `path` a row at a time, asks `holds` of each row's
    /// text, and visits the rows it held for, until a visit says
    /// [`Flow::Stop`]. A file that cannot be read is a refusal.
    fn rows(
        &mut self,
        path: &Path,
        holds: &mut dyn FnMut(&str) -> bool,
        visit: &mut dyn FnMut(Row<'_>) -> Flow,
    ) -> Result<Read, Refusal>;
}

/// Why `root` may not be searched at all, if it may not: it is not
/// absolute, or it has a `..` component, which would make the spelling of
/// the paths a search answers ambiguous. It is the core's rule, so no
/// adapter is asked such a root.
pub fn refusal_before_search(root: &Path) -> Option<Refusal> {
    if !root.is_absolute() {
        return Some(Refusal::new(
            RefusalKind::NotAbsolute,
            format!("cannot search {}: the path is not absolute", root.display()),
        ));
    }
    if root.components().any(|part| part == Component::ParentDir) {
        return Some(Refusal::new(
            RefusalKind::NotAbsolute,
            format!(
                "cannot search {}: the path has a `..` component",
                root.display()
            ),
        ));
    }
    None
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{RefusalKind, refusal_before_search};

    fn kind(path: &str) -> Option<RefusalKind> {
        refusal_before_search(Path::new(path)).map(|refusal| refusal.kind)
    }

    #[test]
    fn a_root_that_is_not_absolute_is_refused_and_named() {
        let refusal = refusal_before_search(Path::new("relative/dir")).expect("refused");

        assert_eq!(refusal.kind, RefusalKind::NotAbsolute);
        assert!(refusal.detail.contains("relative/dir"));
        assert!(refusal.detail.contains("not absolute"));
        assert_eq!(kind(""), Some(RefusalKind::NotAbsolute));
    }

    #[test]
    fn a_root_with_a_parent_component_is_refused_and_says_so() {
        let refusal = refusal_before_search(Path::new("/a/../b")).expect("refused");

        assert_eq!(refusal.kind, RefusalKind::NotAbsolute);
        assert!(refusal.detail.contains("`..`"));
    }

    #[test]
    fn an_absolute_root_is_not_refused() {
        assert_eq!(kind("/"), None);
        assert_eq!(kind("/a/./b"), None);
    }
}
