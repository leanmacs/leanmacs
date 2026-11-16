//! The coalescing rule, pure.
//!
//! A [`Batch`] is one watch's changes noticed and not yet taken. Time
//! reaches it as a number of milliseconds its caller passes in, on whatever
//! clock the caller keeps, so the rule is pinned here without one.
//!
//! - **One change per path.** A path noticed again gets the notice's kind
//!   added to its [`Kinds`]. Changes come in the order of each path's first
//!   notice. A set of kinds and not one kind, because a platform gives no
//!   order inside a record it coalesced itself, and can carry an earlier
//!   change's flag.
//! - **A fixed window from the first notice.** The first notice after a
//!   take opens the batch; it is deliverable once `window_ms` have passed
//!   since then ([`Batch::deadline`]), however many notices follow. So a
//!   path written without pause is delivered once a window, never held
//!   back for good, which a trailing debounce would do.
//! - **The bound** is how many distinct paths the batch may hold. A notice
//!   for a new path when it is full collapses the batch to one change,
//!   [`Kind::Missed`] on the batch's root, the watch's own path; and it
//!   stays collapsed until it is taken. A [`Kind::Missed`] notice, the
//!   platform's own overflow, collapses it the same way.
//! - **A take** gives every change and leaves the batch empty and not
//!   collapsed.

use std::path::PathBuf;

use crate::{Kind, Notice};

/// A set of kinds of change: a bit for each, laid out as [`Kinds::bits`]
/// says, which the C functions hand on as they are.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct Kinds(u8);

impl Kinds {
    /// The bit of `kind`: created 1, written 2, renamed 4, removed 8,
    /// missed 16.
    const fn bit(kind: Kind) -> u8 {
        match kind {
            Kind::Created => 1,
            Kind::Written => 2,
            Kind::Renamed => 4,
            Kind::Removed => 8,
            Kind::Missed => 16,
        }
    }

    /// The set with `kind` added.
    #[must_use]
    pub const fn with(self, kind: Kind) -> Self {
        Self(self.0 | Self::bit(kind))
    }

    /// The set's bits: created 1, written 2, renamed 4, removed 8, missed
    /// 16.
    pub const fn bits(self) -> u8 {
        self.0
    }

    /// Whether `kind` is in the set.
    pub const fn contains(self, kind: Kind) -> bool {
        self.0 & Self::bit(kind) != 0
    }

    /// Whether it holds [`Kind::Created`].
    pub const fn created(self) -> bool {
        self.contains(Kind::Created)
    }

    /// Whether it holds [`Kind::Written`].
    pub const fn written(self) -> bool {
        self.contains(Kind::Written)
    }

    /// Whether it holds [`Kind::Renamed`].
    pub const fn renamed(self) -> bool {
        self.contains(Kind::Renamed)
    }

    /// Whether it holds [`Kind::Removed`].
    pub const fn removed(self) -> bool {
        self.contains(Kind::Removed)
    }

    /// Whether it holds [`Kind::Missed`].
    pub const fn missed(self) -> bool {
        self.contains(Kind::Missed)
    }
}

/// One path's changes in a batch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    /// The path, as the watch spells it.
    pub path: PathBuf,
    /// Every kind noticed there since the last take.
    pub kinds: Kinds,
}

/// A watch's changes noticed and not yet taken. The module docs have the
/// rule.
#[derive(Debug, Clone)]
pub struct Batch {
    /// The watch's own path, which a collapsed batch names.
    root: PathBuf,
    /// How long after its first notice the batch is deliverable.
    window_ms: u64,
    /// How many distinct paths it may hold.
    bound: usize,
    /// When its first notice since the last take came, if one has.
    opened: Option<u64>,
    /// Its changes, in the order of each path's first notice.
    changes: Vec<Change>,
    /// Whether it has collapsed to [`Kind::Missed`] on the root.
    collapsed: bool,
}

impl Batch {
    /// An empty batch for the watch of `root`, deliverable `window_ms`
    /// after its first notice, holding at most `bound` paths.
    pub fn new(root: impl Into<PathBuf>, window_ms: u64, bound: usize) -> Self {
        Self {
            root: root.into(),
            window_ms,
            bound,
            opened: None,
            changes: Vec::new(),
            collapsed: false,
        }
    }

    /// Records `notice`, noticed at `now_ms`.
    pub fn record(&mut self, notice: Notice, now_ms: u64) {
        self.opened.get_or_insert(now_ms);
        if self.collapsed {
            return;
        }
        if notice.kind == Kind::Missed {
            self.collapse();
            return;
        }
        if let Some(change) = self.changes.iter_mut().find(|c| c.path == notice.path) {
            change.kinds = change.kinds.with(notice.kind);
        } else if self.changes.len() < self.bound {
            self.changes.push(Change {
                path: notice.path,
                kinds: Kinds::default().with(notice.kind),
            });
        } else {
            self.collapse();
        }
    }

    /// Collapses the batch to one change, [`Kind::Missed`] on the root.
    fn collapse(&mut self) {
        self.collapsed = true;
        self.changes = vec![Change {
            path: self.root.clone(),
            kinds: Kinds::default().with(Kind::Missed),
        }];
    }

    /// Whether the batch can be delivered at `now_ms`: it holds something,
    /// and its window has passed.
    pub fn deliverable(&self, now_ms: u64) -> bool {
        self.deadline().is_some_and(|deadline| now_ms >= deadline)
    }

    /// When the batch can be delivered: a window after its first notice, or
    /// `None` while it is empty.
    pub fn deadline(&self) -> Option<u64> {
        self.opened
            .map(|opened| opened.saturating_add(self.window_ms))
    }

    /// Every change, leaving the batch empty and not collapsed.
    pub fn take(&mut self) -> Vec<Change> {
        self.opened = None;
        self.collapsed = false;
        std::mem::take(&mut self.changes)
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::{Batch, Change, Kinds};
    use crate::{Kind, Notice};

    const ROOT: &str = "/w";

    fn path(name: &str) -> PathBuf {
        PathBuf::from(ROOT).join(name)
    }

    fn notice(name: &str, kind: Kind) -> Notice {
        Notice::new(path(name), kind)
    }

    fn kinds(of: &[Kind]) -> Kinds {
        of.iter()
            .fold(Kinds::default(), |kinds, &kind| kinds.with(kind))
    }

    fn change(name: &str, of: &[Kind]) -> Change {
        Change {
            path: path(name),
            kinds: kinds(of),
        }
    }

    fn missed() -> Change {
        Change {
            path: PathBuf::from(ROOT),
            kinds: kinds(&[Kind::Missed]),
        }
    }

    #[test]
    fn each_kind_is_its_own_bit_and_a_set_holds_what_was_added() {
        let bits: Vec<u8> = [
            Kind::Created,
            Kind::Written,
            Kind::Renamed,
            Kind::Removed,
            Kind::Missed,
        ]
        .into_iter()
        .map(|kind| Kinds::default().with(kind).bits())
        .collect();

        assert_eq!(bits, [1, 2, 4, 8, 16]);
        let set = kinds(&[Kind::Written, Kind::Removed, Kind::Written]);
        assert_eq!(set.bits(), 10);
        assert!(set.contains(Kind::Written) && set.contains(Kind::Removed));
        assert!(!set.contains(Kind::Created));
    }

    #[test]
    fn a_path_noticed_many_times_is_one_change_with_every_kind_added() {
        let mut batch = Batch::new(ROOT, 0, 10);

        batch.record(notice("a", Kind::Written), 0);
        batch.record(notice("a", Kind::Created), 0);
        batch.record(notice("a", Kind::Written), 0);
        batch.record(notice("b", Kind::Removed), 0);

        assert_eq!(
            batch.take(),
            [
                change("a", &[Kind::Created, Kind::Written]),
                change("b", &[Kind::Removed])
            ]
        );
    }

    #[test]
    fn changes_come_in_the_order_of_each_paths_first_notice() {
        let mut batch = Batch::new(ROOT, 0, 10);

        for name in ["b", "a", "b", "c", "a"] {
            batch.record(notice(name, Kind::Written), 0);
        }

        let order: Vec<PathBuf> = batch.take().into_iter().map(|c| c.path).collect();
        assert_eq!(order, [path("b"), path("a"), path("c")]);
    }

    #[test]
    fn a_batch_is_deliverable_a_window_after_its_first_notice_and_not_before() {
        let mut batch = Batch::new(ROOT, 300, 10);

        batch.record(notice("a", Kind::Written), 100);
        batch.record(notice("a", Kind::Written), 350);

        assert_eq!(batch.deadline(), Some(400));
        assert!(!batch.deliverable(399));
        assert!(batch.deliverable(400));
        assert!(batch.deliverable(1000));
    }

    #[test]
    fn an_empty_batch_is_never_deliverable_and_has_no_deadline() {
        let batch = Batch::new(ROOT, 0, 10);

        assert_eq!(batch.deadline(), None);
        assert!(!batch.deliverable(u64::MAX));
    }

    #[test]
    fn with_a_window_of_zero_a_batch_is_deliverable_at_its_first_notice() {
        let mut batch = Batch::new(ROOT, 0, 10);

        batch.record(notice("a", Kind::Written), 7);

        assert_eq!(batch.deadline(), Some(7));
        assert!(batch.deliverable(7));
    }

    #[test]
    fn a_new_path_past_the_bound_collapses_the_batch_to_missed_on_the_root_until_it_is_taken() {
        let mut batch = Batch::new(ROOT, 0, 2);

        batch.record(notice("a", Kind::Written), 0);
        batch.record(notice("b", Kind::Written), 0);
        batch.record(notice("a", Kind::Removed), 0);
        assert_eq!(batch.deadline(), Some(0));
        batch.record(notice("c", Kind::Written), 0);
        batch.record(notice("d", Kind::Created), 0);

        assert_eq!(batch.take(), [missed()]);
    }

    #[test]
    fn a_bound_of_paths_exactly_is_not_collapsed() {
        let mut batch = Batch::new(ROOT, 0, 2);

        batch.record(notice("a", Kind::Written), 0);
        batch.record(notice("b", Kind::Written), 0);

        assert_eq!(batch.take().len(), 2);
    }

    #[test]
    fn a_missed_notice_collapses_the_batch_and_names_the_root() {
        let mut batch = Batch::new(ROOT, 0, 10);

        batch.record(notice("a", Kind::Written), 0);
        batch.record(Notice::new("/elsewhere", Kind::Missed), 0);
        batch.record(notice("b", Kind::Written), 0);

        assert_eq!(batch.take(), [missed()]);
    }

    #[test]
    fn a_take_leaves_the_batch_empty_not_collapsed_and_the_next_notice_opens_it_again() {
        let mut batch = Batch::new(ROOT, 300, 1);
        batch.record(notice("a", Kind::Written), 0);
        batch.record(notice("b", Kind::Written), 10);
        assert_eq!(batch.take(), [missed()]);

        assert_eq!(batch.take(), []);
        assert_eq!(batch.deadline(), None);
        batch.record(notice("c", Kind::Written), 1000);

        assert_eq!(batch.deadline(), Some(1300));
        assert_eq!(batch.take(), [change("c", &[Kind::Written])]);
    }
}
