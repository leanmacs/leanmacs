//! The contract of the line diff port: the rules a script made over any
//! [`LineDiff`] keeps, as a check that runs one.
//!
//! [`check`] asks the engine it is given, directly and through
//! [`script`], and returns the names of the properties that fail. The
//! exact hunks an engine picks may differ from the fake's, so the
//! properties are relational: what a script gives, what it must keep, and
//! where its steps may start and stop. The same properties, over the
//! editor's diff request, are the Lean job port's `diffProperties`.

use std::ops::Range;

use crate::{Hunk, LineDiff, Step, retained, run, script};

/// A script applied to the old text gives the new text.
pub const APPLIES: &str = "a script applied to the old text gives the new text";
/// Equal texts, the empty text among them, give one retain of the whole.
pub const EQUAL: &str = "equal texts give one retain";
/// Every step starts and stops at a character boundary of both texts: a
/// character that differs only in its trailing bytes, and an escape, are
/// replaced whole.
pub const BOUNDARIES: &str = "every step starts and stops at a character boundary of both texts";
/// The longest common prefix and suffix that end on a character boundary
/// are retained.
pub const AFFIX: &str =
    "the longest common prefix and suffix that end on a character boundary are retained";
/// Of an old text `h1 K h2` and a new text `h1' K h2'`, where the block
/// `K` shares no line with the hunks and the hunks share no line across
/// it, every byte of `K` is retained.
pub const KEPT: &str = "a block both texts keep, sharing no line with the hunks, is retained";
/// Over the line limit the middle is one hunk: no retain between two
/// changes.
pub const LIMIT: &str = "over the line limit the middle is one hunk";
/// The engine's own hunks are in order, in range, and the lines between
/// them equal, as many on each side.
pub const HUNKS: &str =
    "the engine's hunks are in order, in range, and the lines between them equal";
/// Generated texts, from a fixed seed, over lines of one- to four-byte
/// characters: each script applies and keeps to character boundaries.
pub const SWEEP: &str = "generated texts give scripts that apply at character boundaries";

/// Every property, by name, in the order [`check`] reports them.
pub const PROPERTIES: [&str; 8] = [APPLIES, EQUAL, BOUNDARIES, AFFIX, KEPT, LIMIT, HUNKS, SWEEP];

/// The limit the cases are diffed under but for [`LIMIT`]'s: more lines
/// than any case has.
const ROOM: usize = 1000;

/// Pairs of an old and a new text.
const PAIRS: &[(&str, &str)] = &[
    ("", ""),
    ("", "a\n"),
    ("a\n", ""),
    ("a\nb\nc\n", "a\nb\nc\n"),
    ("a\nb\nc\n", "a\nX\nc\n"),
    ("a\nc\n", "a\nb\nc\n"),
    ("a\nb\nc\n", "a\nc\n"),
    ("a\nb", "a\nb\n"),
    ("a\nb\n", "a\nb"),
    ("one\ntwo\nthree\n", "one\ntwo and more\nthree\n"),
    ("x\r\ny\r\n", "x\r\nz\r\n"),
    ("café\n", "cafè\n"),
    ("日日\n", "日时\n"),
    ("a\u{10DC80}b\n", "a\u{10DC81}b\n"),
    ("\u{10DC80}\n", "\u{10DC80}\u{10DC80}\n"),
    ("p\nq\nr\ns\nt\n", "t\ns\nr\nq\np\n"),
    ("é\n", "e\u{301}\n"),
];

/// Kept-block cases: an old text and a new one, and the bytes of the
/// block `K` in the old text.
const KEPT_CASES: &[(&str, &str, Range<usize>)] = &[
    ("one\nkeep\nthis\ntwo\n", "uno\nkeep\nthis\ndos\n", 4..14),
    ("a\nb\nK1\nK2\nc\n", "x\nK1\nK2\ny\nz\n", 4..10),
    ("é\nkept\nx\n", "è\nkept\ny\n", 3..8),
];

/// Holds `engine` to the contract, and returns the names of the properties
/// that fail: none when it keeps them all.
pub fn check(engine: &mut impl LineDiff) -> Vec<&'static str> {
    [
        (APPLIES, applies(engine)),
        (EQUAL, equal(engine)),
        (BOUNDARIES, boundaries(engine)),
        (AFFIX, affix(engine)),
        (KEPT, kept(engine)),
        (LIMIT, limit(engine)),
        (HUNKS, hunks(engine)),
        (SWEEP, sweep(engine)),
    ]
    .into_iter()
    .filter_map(|(name, holds)| (!holds).then_some(name))
    .collect()
}

fn applies(engine: &mut impl LineDiff) -> bool {
    PAIRS
        .iter()
        .all(|(old, new)| run(old, new, &script(engine, old, new, ROOM)).as_deref() == Some(*new))
}

fn equal(engine: &mut impl LineDiff) -> bool {
    ["", "a", "a\n", "a\nb\nc\n", "é\n日\n"]
        .iter()
        .all(|text| script(engine, text, text, ROOM) == [Step::Retain(text.len())])
}

/// Whether every step of `steps` starts and stops at a character boundary
/// of both texts.
pub fn on_boundaries(old: &str, new: &str, steps: &[Step]) -> bool {
    let (mut at_old, mut at_new) = (0, 0);
    for step in steps {
        match *step {
            Step::Retain(count) => {
                at_old += count;
                at_new += count;
            }
            Step::Delete(count) => at_old += count,
            Step::Insert { count, .. } => at_new += count,
        }
        if !old.is_char_boundary(at_old) || !new.is_char_boundary(at_new) {
            return false;
        }
    }
    true
}

fn boundaries(engine: &mut impl LineDiff) -> bool {
    PAIRS
        .iter()
        .all(|(old, new)| on_boundaries(old, new, &script(engine, old, new, ROOM)))
}

/// Whether every byte of `range` of the old text is under one of the
/// ranges `steps` retains.
pub fn covered(steps: &[Step], range: Range<usize>) -> bool {
    range.is_empty()
        || retained(steps)
            .iter()
            .any(|kept| kept.start <= range.start && range.end <= kept.end)
}

/// The longest common prefix of `old` and `new` that ends on a character
/// boundary of both, and then the longest common suffix of what it leaves
/// that does: their lengths in bytes.
pub fn affixes(old: &str, new: &str) -> (usize, usize) {
    let (a, b) = (old.as_bytes(), new.as_bytes());
    let mut prefix = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    while !(old.is_char_boundary(prefix) && new.is_char_boundary(prefix)) {
        prefix -= 1;
    }
    let mut suffix = a[prefix..]
        .iter()
        .rev()
        .zip(b[prefix..].iter().rev())
        .take_while(|(x, y)| x == y)
        .count();
    while !(old.is_char_boundary(old.len() - suffix) && new.is_char_boundary(new.len() - suffix)) {
        suffix -= 1;
    }
    (prefix, suffix)
}

fn affix(engine: &mut impl LineDiff) -> bool {
    PAIRS.iter().all(|(old, new)| {
        let steps = script(engine, old, new, ROOM);
        let (prefix, suffix) = affixes(old, new);
        covered(&steps, 0..prefix) && covered(&steps, old.len() - suffix..old.len())
    })
}

fn kept(engine: &mut impl LineDiff) -> bool {
    KEPT_CASES
        .iter()
        .all(|(old, new, block)| covered(&script(engine, old, new, ROOM), block.clone()))
}

/// How many runs of changes `steps` has: runs of deletes and inserts
/// between two retains.
pub fn changed_runs(steps: &[Step]) -> usize {
    let mut runs = 0;
    let mut in_run = false;
    for step in steps {
        let change = !matches!(step, Step::Retain(_));
        if change && !in_run {
            runs += 1;
        }
        in_run = change;
    }
    runs
}

fn limit(engine: &mut impl LineDiff) -> bool {
    let (old, new) = ("h\na\nk\nb\nt\n", "h\nA\nk\nB\nt\n");
    let over = script(engine, old, new, 2);
    run(old, new, &over).as_deref() == Some(new) && changed_runs(&over) == 1
}

/// Whether `found` is a hunk list for `old` and `new` by the port's rule.
fn hunk_list(found: &[Hunk], old: &[&[u8]], new: &[&[u8]]) -> bool {
    let (mut at_old, mut at_new) = (0, 0);
    for hunk in found {
        if !(at_old <= hunk.old.start
            && hunk.old.start <= hunk.old.end
            && hunk.old.end <= old.len()
            && at_new <= hunk.new.start
            && hunk.new.start <= hunk.new.end
            && hunk.new.end <= new.len()
            && hunk.old.start - at_old == hunk.new.start - at_new
            && old[at_old..hunk.old.start] == new[at_new..hunk.new.start])
        {
            return false;
        }
        (at_old, at_new) = (hunk.old.end, hunk.new.end);
    }
    old.len() - at_old == new.len() - at_new && old[at_old..] == new[at_new..]
}

fn hunks(engine: &mut impl LineDiff) -> bool {
    PAIRS.iter().all(|(old, new)| {
        let (old, new) = (crate::lines(old), crate::lines(new));
        hunk_list(&engine.hunks(&old, &new), &old, &new)
    })
}

/// The lines generated texts are made of: one- to four-byte characters,
/// an escape among them, and one line with no line feed.
const LINES: [&str; 8] = [
    "a\n",
    "b\n",
    "é\n",
    "è\n",
    "日\n",
    "时\n",
    "\u{10DC80}\n",
    "zz",
];

/// A text of up to seven lines from `LINES`, from the state `seed`.
fn generated(seed: &mut u64) -> String {
    let mut next = || {
        *seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        (*seed >> 33) as usize
    };
    let count = next() % 8;
    (0..count).map(|_| LINES[next() % LINES.len()]).collect()
}

fn sweep(engine: &mut impl LineDiff) -> bool {
    let mut seed = 0x5eed;
    (0..300).all(|_| {
        let old = generated(&mut seed);
        let new = generated(&mut seed);
        let steps = script(engine, &old, &new, ROOM);
        run(&old, &new, &steps).as_deref() == Some(new.as_str())
            && on_boundaries(&old, &new, &steps)
    })
}
