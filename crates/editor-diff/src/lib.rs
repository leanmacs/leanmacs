//! A line diff of two texts, as an edit script: what a reload of a file
//! applies to the buffer it is open in.
//!
//! [`script`] is what the editor asks: two texts and a line limit in, an
//! edit script out ([`Step`]), which walks the old text from its start to
//! its end and the new text likewise, and names byte counts and ranges of
//! them, never text. Which lines of the two texts match is a
//! [`LineDiff`]'s to say, the port a diff library fills; everything round
//! it is decided here, once. The crate has no dependencies and knows
//! nothing about Lean or about the rope.
//!
//! # The core
//!
//! - **The common head and tail lines are stripped first**, in linear
//!   time: the lines the two texts share at their start, and then those
//!   they share at their end, which never overlap the head. A *line* is
//!   its bytes and the line feed that ends it, if one does; a text that
//!   does not end in a line feed has a last line without one, and an
//!   empty text has no line.
//! - **The line limit.** The engine is asked about what is left, the
//!   *middle*, only when each side of it is at most `limit` lines. Over
//!   it, the middle is one hunk, replaced whole. So a text of any size
//!   costs linear time here, and an engine's own cost is bounded by the
//!   limit.
//! - **The engine's hunks are checked**: in order, within the middle, and
//!   with the lines between two of them equal and as many on each side. A
//!   hunk list that is not is taken as one hunk over the whole middle, so
//!   a wrong engine gives a script that is still right, only coarser.
//! - **Each hunk is trimmed** to the longest common prefix and suffix of
//!   its two byte ranges that end on a character boundary of both texts,
//!   the suffix taken from what the prefix left. So a cursor in the
//!   unchanged head of a changed line stays put, and no step starts or
//!   stops inside a character: `é` changing to `è` (`C3 A9` to `C3 A8`)
//!   is the whole of the character replaced, not its last byte. An escape
//!   that a load keeps for a byte that is not UTF-8 (`editor-text`'s
//!   `bytes`) is one character of four bytes, so it is one unit too.
//! - **The steps.** What lies between two hunks is a [`Step::Retain`]; a
//!   hunk is a [`Step::Delete`] of its old bytes and a [`Step::Insert`] of
//!   its new ones, in that order. No step has a length of 0, two retains
//!   are never neighbours, and hunks that touch after trimming are one
//!   delete and one insert. Equal texts, the empty text included, give one
//!   retain of the whole.
//!
//! [`run`] says what applying a script gives, and refuses a script that
//! does not walk both texts whole, at character boundaries.
//!
//! # Where an addition goes
//!
//! A rule of the core is a change here, pinned by this module's tests on
//! the fake. A rule every engine keeps is a property of [`contract`],
//! which the fake and every real adapter run. A new engine is an adapter
//! crate that implements [`LineDiff`] and runs the contract in its tests.

use std::ops::Range;

pub mod contract;
pub mod fake;

/// One step of an edit script. The script walks the old text from its
/// start to its end, and the new text likewise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    /// Keep the next `count` bytes of the old text, which are the next
    /// `count` bytes of the new.
    Retain(usize),
    /// Remove the next `count` bytes of the old text.
    Delete(usize),
    /// Put in the `count` bytes of the new text from `start`, which is
    /// where the walk of the new text is.
    Insert {
        /// Where the bytes start in the new text.
        start: usize,
        /// How many bytes.
        count: usize,
    },
}

/// A run of lines of the old text replaced by a run of lines of the new,
/// as indices of their lines, half-open. Either may be empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hunk {
    /// The old text's lines.
    pub old: Range<usize>,
    /// The new text's lines.
    pub new: Range<usize>,
}

/// The port: which lines of two texts match.
pub trait LineDiff {
    /// The hunks that turn the lines `old` into the lines `new`, in order:
    /// each starts at or after the end of the one before on both sides,
    /// and the lines between two of them, before the first and after the
    /// last are equal, as many on each side. A line is compared by its
    /// bytes. Which of several such lists is answered is the engine's.
    fn hunks(&mut self, old: &[&[u8]], new: &[&[u8]]) -> Vec<Hunk>;
}

/// The lines of `text`: each with the line feed that ends it, the last
/// without one when the text does not end in one. An empty text has none.
pub fn lines(text: &str) -> Vec<&[u8]> {
    text.as_bytes()
        .split_inclusive(|&byte| byte == b'\n')
        .collect()
}

/// The edit script that turns `old` into `new`, with `engine` asked about
/// a middle of at most `limit` lines on each side. The module docs have
/// the rules.
pub fn script(engine: &mut impl LineDiff, old: &str, new: &str, limit: usize) -> Vec<Step> {
    let old_lines = lines(old);
    let new_lines = lines(new);
    let shorter = old_lines.len().min(new_lines.len());
    let head = (0..shorter)
        .take_while(|&index| old_lines[index] == new_lines[index])
        .count();
    let tail = (0..shorter - head)
        .take_while(|&back| {
            old_lines[old_lines.len() - 1 - back] == new_lines[new_lines.len() - 1 - back]
        })
        .count();
    let old_middle = head..old_lines.len() - tail;
    let new_middle = head..new_lines.len() - tail;
    let whole = Hunk {
        old: old_middle.clone(),
        new: new_middle.clone(),
    };
    let hunks = if old_middle.is_empty() && new_middle.is_empty() {
        Vec::new()
    } else if old_middle.len() <= limit && new_middle.len() <= limit {
        let old_part = &old_lines[old_middle.clone()];
        let new_part = &new_lines[new_middle.clone()];
        let found = engine.hunks(old_part, new_part);
        if well_formed(&found, old_part, new_part) {
            found
                .into_iter()
                .map(|hunk| Hunk {
                    old: hunk.old.start + head..hunk.old.end + head,
                    new: hunk.new.start + head..hunk.new.end + head,
                })
                .collect()
        } else {
            vec![whole]
        }
    } else {
        vec![whole]
    };
    let old_starts = starts(&old_lines);
    let new_starts = starts(&new_lines);
    let mut steps = Steps::default();
    let mut at = 0;
    for hunk in hunks {
        let (removed, added) = trim(
            old,
            new,
            old_starts[hunk.old.start]..old_starts[hunk.old.end],
            new_starts[hunk.new.start]..new_starts[hunk.new.end],
        );
        if removed.is_empty() && added.is_empty() {
            continue;
        }
        steps.retain(removed.start - at);
        steps.delete(removed.len());
        steps.insert(added.start, added.len());
        at = removed.end;
    }
    steps.retain(old.len() - at);
    steps.finish(old.len())
}

/// Whether `hunks` is a hunk list for the lines `old` and `new` by the
/// rule [`LineDiff::hunks`] gives. Linear in the lines.
fn well_formed(hunks: &[Hunk], old: &[&[u8]], new: &[&[u8]]) -> bool {
    let (mut at_old, mut at_new) = (0, 0);
    for hunk in hunks {
        let in_order = at_old <= hunk.old.start
            && hunk.old.start <= hunk.old.end
            && hunk.old.end <= old.len()
            && at_new <= hunk.new.start
            && hunk.new.start <= hunk.new.end
            && hunk.new.end <= new.len();
        if !in_order || !equal_between(old, new, at_old..hunk.old.start, at_new..hunk.new.start) {
            return false;
        }
        (at_old, at_new) = (hunk.old.end, hunk.new.end);
    }
    equal_between(old, new, at_old..old.len(), at_new..new.len())
}

/// Whether the lines `old` of `old_lines` are as many as the lines `new`
/// of `new_lines`, and equal one by one.
fn equal_between(
    old_lines: &[&[u8]],
    new_lines: &[&[u8]],
    old: Range<usize>,
    new: Range<usize>,
) -> bool {
    old.len() == new.len() && old_lines[old] == new_lines[new]
}

/// Where each of `lines` starts, as a byte offset, and then where the last
/// one ends: one more offset than lines.
fn starts(lines: &[&[u8]]) -> Vec<usize> {
    let mut starts = Vec::with_capacity(lines.len() + 1);
    let mut offset = 0;
    starts.push(offset);
    for line in lines {
        offset += line.len();
        starts.push(offset);
    }
    starts
}

/// The bytes `old` of the text `old_text` and `new` of `new_text`, less
/// their longest common prefix and then their longest common suffix that
/// end on a character boundary of both texts. Both ranges start and end on
/// one already.
fn trim(
    old_text: &str,
    new_text: &str,
    old: Range<usize>,
    new: Range<usize>,
) -> (Range<usize>, Range<usize>) {
    let old_bytes = &old_text.as_bytes()[old.clone()];
    let new_bytes = &new_text.as_bytes()[new.clone()];
    let boundary =
        |a: usize, b: usize| old_text.is_char_boundary(a) && new_text.is_char_boundary(b);
    let mut prefix = old_bytes
        .iter()
        .zip(new_bytes)
        .take_while(|(a, b)| a == b)
        .count();
    while !boundary(old.start + prefix, new.start + prefix) {
        prefix -= 1;
    }
    let mut suffix = old_bytes[prefix..]
        .iter()
        .rev()
        .zip(new_bytes[prefix..].iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    while !boundary(old.end - suffix, new.end - suffix) {
        suffix -= 1;
    }
    (
        old.start + prefix..old.end - suffix,
        new.start + prefix..new.end - suffix,
    )
}

/// A script as it is built: neighbouring retains made one, and a changed
/// range's deletes and inserts made one delete and one insert.
#[derive(Default)]
struct Steps {
    /// The steps so far, but for the changed range being built.
    steps: Vec<Step>,
    /// The bytes the changed range being built removes.
    deleted: usize,
    /// The bytes it puts in, as a start in the new text and a count.
    inserted: Option<(usize, usize)>,
}

impl Steps {
    /// Keeps `count` bytes. Nothing for 0.
    fn retain(&mut self, count: usize) {
        if count == 0 {
            return;
        }
        self.flush();
        if let Some(Step::Retain(kept)) = self.steps.last_mut() {
            *kept += count;
        } else {
            self.steps.push(Step::Retain(count));
        }
    }

    /// Removes `count` bytes. Nothing for 0.
    fn delete(&mut self, count: usize) {
        self.deleted += count;
    }

    /// Puts in the `count` bytes of the new text from `start`. Nothing
    /// for 0.
    fn insert(&mut self, start: usize, count: usize) {
        if count == 0 {
            return;
        }
        self.inserted = match self.inserted {
            Some((first, so_far)) => Some((first, so_far + count)),
            None => Some((start, count)),
        };
    }

    /// Ends the changed range being built.
    fn flush(&mut self) {
        if self.deleted > 0 {
            self.steps.push(Step::Delete(self.deleted));
            self.deleted = 0;
        }
        if let Some((start, count)) = self.inserted.take() {
            self.steps.push(Step::Insert { start, count });
        }
    }

    /// The script, for an old text of `len` bytes: one retain of the whole
    /// when nothing changed.
    fn finish(mut self, len: usize) -> Vec<Step> {
        self.flush();
        if self
            .steps
            .iter()
            .all(|step| matches!(step, Step::Retain(_)))
        {
            return vec![Step::Retain(len)];
        }
        self.steps
    }
}

/// What applying `script` to `old` gives, taking what it puts in from
/// `new`: `None` when the script does not walk the whole of both texts, a
/// step runs past one, an insert does not start where the walk of the new
/// text is, or a step starts or stops inside a character of either.
pub fn run(old: &str, new: &str, script: &[Step]) -> Option<String> {
    let (mut at_old, mut at_new): (usize, usize) = (0, 0);
    let mut out = String::with_capacity(new.len());
    for step in script {
        match *step {
            Step::Retain(count) => {
                out.push_str(old.get(at_old..at_old.checked_add(count)?)?);
                new.get(at_new..at_new.checked_add(count)?)?;
                at_old += count;
                at_new += count;
            }
            Step::Delete(count) => {
                old.get(at_old..at_old.checked_add(count)?)?;
                at_old += count;
            }
            Step::Insert { start, count } => {
                if start != at_new {
                    return None;
                }
                out.push_str(new.get(start..start.checked_add(count)?)?);
                at_new += count;
            }
        }
    }
    (at_old == old.len() && at_new == new.len()).then_some(out)
}

/// The ranges of the old text that `script` retains, in order.
pub fn retained(script: &[Step]) -> Vec<Range<usize>> {
    let mut at = 0;
    let mut ranges = Vec::new();
    for step in script {
        match *step {
            Step::Retain(count) => {
                ranges.push(at..at + count);
                at += count;
            }
            Step::Delete(count) => at += count,
            Step::Insert { .. } => {}
        }
    }
    ranges
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fake::Lcs;

    /// An engine that answers what it was built with, whatever it is
    /// asked, and counts how often it was asked.
    struct Canned {
        hunks: Vec<Hunk>,
        asked: usize,
    }

    impl LineDiff for Canned {
        fn hunks(&mut self, _old: &[&[u8]], _new: &[&[u8]]) -> Vec<Hunk> {
            self.asked += 1;
            self.hunks.clone()
        }
    }

    fn canned(hunks: Vec<Hunk>) -> Canned {
        Canned { hunks, asked: 0 }
    }

    fn diff(old: &str, new: &str) -> Vec<Step> {
        script(&mut Lcs, old, new, 100)
    }

    #[test]
    fn lines_keep_their_line_feeds_and_an_empty_text_has_none() {
        assert_eq!(lines("a\nbc\n"), [b"a\n" as &[u8], b"bc\n"]);
        assert_eq!(lines("a\nb"), [b"a\n" as &[u8], b"b"]);
        assert!(lines("").is_empty());
    }

    #[test]
    fn equal_texts_give_one_retain_of_the_whole() {
        assert_eq!(diff("a\nb\n", "a\nb\n"), [Step::Retain(4)]);
        assert_eq!(diff("", ""), [Step::Retain(0)]);
    }

    #[test]
    fn a_changed_line_is_trimmed_to_its_changed_bytes() {
        assert_eq!(
            diff("one\ntwo\nthree\n", "one\ntwx\nthree\n"),
            [
                Step::Retain(6),
                Step::Delete(1),
                Step::Insert { start: 6, count: 1 },
                Step::Retain(7)
            ]
        );
    }

    #[test]
    fn a_character_that_differs_only_in_its_last_byte_is_replaced_whole() {
        // é is C3 A9 and è is C3 A8.
        assert_eq!(
            diff("café\n", "cafè\n"),
            [
                Step::Retain(3),
                Step::Delete(2),
                Step::Insert { start: 3, count: 2 },
                Step::Retain(1)
            ]
        );
        // 日 is E6 97 A5 and 时 is E6 97 B6.
        assert_eq!(
            diff("日日\n", "日时\n"),
            [
                Step::Retain(3),
                Step::Delete(3),
                Step::Insert { start: 3, count: 3 },
                Step::Retain(1)
            ]
        );
    }

    #[test]
    fn an_escape_is_one_unit() {
        // The escapes of the bytes 0x80 and 0x81: F4 8D B2 80, F4 8D B2 81.
        assert_eq!(
            diff("a\u{10DC80}b\n", "a\u{10DC81}b\n"),
            [
                Step::Retain(1),
                Step::Delete(4),
                Step::Insert { start: 1, count: 4 },
                Step::Retain(2)
            ]
        );
    }

    #[test]
    fn a_line_put_in_and_one_taken_out_are_an_insert_and_a_delete() {
        assert_eq!(
            diff("a\nc\n", "a\nb\nc\n"),
            [
                Step::Retain(2),
                Step::Insert { start: 2, count: 2 },
                Step::Retain(2)
            ]
        );
        assert_eq!(
            diff("a\nb\nc\n", "a\nc\n"),
            [Step::Retain(2), Step::Delete(2), Step::Retain(2)]
        );
    }

    #[test]
    fn a_last_line_that_gains_a_line_feed_gains_only_that() {
        assert_eq!(
            diff("a\nb", "a\nb\n"),
            [Step::Retain(3), Step::Insert { start: 3, count: 1 }]
        );
    }

    #[test]
    fn the_engine_is_asked_about_the_middle_alone() {
        struct Asked(Vec<Vec<u8>>, Vec<Vec<u8>>);
        impl LineDiff for Asked {
            fn hunks(&mut self, old: &[&[u8]], new: &[&[u8]]) -> Vec<Hunk> {
                self.0 = old.iter().map(|line| line.to_vec()).collect();
                self.1 = new.iter().map(|line| line.to_vec()).collect();
                Lcs.hunks(old, new)
            }
        }
        let mut engine = Asked(Vec::new(), Vec::new());
        script(&mut engine, "h\nx\ny\nt\n", "h\nz\nt\n", 100);
        assert_eq!(engine.0, [b"x\n".to_vec(), b"y\n".to_vec()]);
        assert_eq!(engine.1, [b"z\n".to_vec()]);
    }

    #[test]
    fn over_the_limit_the_middle_is_one_hunk_and_the_engine_is_not_asked() {
        let mut engine = canned(Vec::new());
        let steps = script(&mut engine, "h\na\nk\nb\nt\n", "h\nA\nk\nB\nt\n", 2);
        assert_eq!(engine.asked, 0);
        assert_eq!(
            steps,
            [
                Step::Retain(2),
                Step::Delete(5),
                Step::Insert { start: 2, count: 5 },
                Step::Retain(3)
            ]
        );
        // At the limit, the engine is asked, and the kept line is kept.
        assert_eq!(
            script(&mut Lcs, "h\na\nk\nb\nt\n", "h\nA\nk\nB\nt\n", 3).len(),
            7
        );
    }

    #[test]
    fn hunks_that_are_not_a_hunk_list_are_taken_as_one_hunk() {
        // Out of range.
        let mut engine = canned(vec![Hunk {
            old: 0..9,
            new: 0..1,
        }]);
        let steps = script(&mut engine, "a\nb\n", "a\nc\n", 100);
        assert_eq!(engine.asked, 1);
        assert_eq!(run("a\nb\n", "a\nc\n", &steps).as_deref(), Some("a\nc\n"));
        // Lines left out of every hunk that are not equal.
        let mut engine = canned(Vec::new());
        let steps = script(&mut engine, "a\nb\n", "a\nc\n", 100);
        assert_eq!(run("a\nb\n", "a\nc\n", &steps).as_deref(), Some("a\nc\n"));
    }

    #[test]
    fn hunks_that_touch_after_the_trim_are_one_delete_and_one_insert() {
        let mut engine = canned(vec![
            Hunk {
                old: 0..1,
                new: 0..0,
            },
            Hunk {
                old: 1..2,
                new: 0..1,
            },
        ]);
        assert_eq!(
            script(&mut engine, "a\nb\n", "c\n", 100),
            [
                Step::Delete(3),
                Step::Insert { start: 0, count: 1 },
                Step::Retain(1)
            ]
        );
    }

    #[test]
    fn run_refuses_a_script_that_does_not_walk_both_texts_whole() {
        assert_eq!(run("ab", "ab", &[Step::Retain(1)]), None);
        assert_eq!(run("ab", "ab", &[Step::Retain(3)]), None);
        assert_eq!(
            run(
                "ab",
                "xab",
                &[Step::Insert { start: 1, count: 1 }, Step::Retain(2)]
            ),
            None
        );
        assert_eq!(
            run(
                "é",
                "è",
                &[
                    Step::Retain(1),
                    Step::Delete(1),
                    Step::Insert { start: 1, count: 1 }
                ]
            ),
            None
        );
        assert_eq!(
            run(
                "ab",
                "xab",
                &[Step::Insert { start: 0, count: 1 }, Step::Retain(2)]
            )
            .as_deref(),
            Some("xab")
        );
    }

    #[test]
    fn the_fake_keeps_the_contract() {
        assert_eq!(contract::check(&mut Lcs), [""; 0]);
    }

    #[test]
    fn an_engine_that_answers_nothing_fails_the_contracts_hunks_alone() {
        assert_eq!(
            contract::check(&mut canned(Vec::new())),
            [contract::KEPT, contract::HUNKS]
        );
    }
}
