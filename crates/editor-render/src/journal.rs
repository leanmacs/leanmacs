//! The frame journal and the counters: what the render loop did, for
//! whoever measures it.
//!
//! The journal has one [`Entry`] for each frame that was presented, with
//! three times read from the loop's clock: of the input the frame answers,
//! of the start of its draw, and of its presentation. A draw that did not
//! present has no entry, and neither has any stretch of time in which
//! nothing was drawn: an idle loop writes nothing. It is a ring of the last
//! [`JOURNAL_CAPACITY`] entries, and counts those it let go.
//!
//! The [`Counters`] count work, never time: draws, frames, rows and glyph
//! images. They only grow, but for the one gauge among them
//! ([`Counters::atlas_bytes`]).

use std::collections::VecDeque;

use crate::port::Drawn;

/// How many entries the journal keeps: the last this many frames.
pub const JOURNAL_CAPACITY: usize = 4096;

/// One presented frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Entry {
    /// Which presented frame it is, from 1.
    pub serial: u64,
    /// When the earliest input it answers was stamped: the oldest of the
    /// demands the draw served.
    pub input_ns: u64,
    /// When its draw began.
    pub draw_ns: u64,
    /// When the renderer returned, having presented it.
    pub present_ns: u64,
    /// The rows the draw built.
    pub rows_rebuilt: u64,
    /// The rows the draw took from what was kept.
    pub rows_reused: u64,
}

/// The last [`JOURNAL_CAPACITY`] entries, oldest first.
#[derive(Debug, Default)]
pub struct Journal {
    /// The entries kept.
    entries: VecDeque<Entry>,
    /// How many were let go to make room.
    dropped: u64,
}

impl Journal {
    /// An empty journal.
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds `entry`, letting the oldest go when the journal is full.
    pub fn record(&mut self, entry: Entry) {
        if self.entries.len() == JOURNAL_CAPACITY {
            self.entries.pop_front();
            self.dropped += 1;
        }
        self.entries.push_back(entry);
    }

    /// The entries kept, oldest first.
    pub fn entries(&self) -> Vec<Entry> {
        self.entries.iter().copied().collect()
    }

    /// How many entries were let go to make room.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }
}

/// What the render loop has done since it began, counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counters {
    /// The draws that presented a frame.
    pub draws: u64,
    /// The draws that did not: the target could not be drawn on.
    pub draws_failed: u64,
    /// The frames submitted.
    pub frames_submitted: u64,
    /// The frames a newer one replaced before they were drawn.
    pub frames_replaced: u64,
    /// The rows built, over every presented draw.
    pub rows_rebuilt: u64,
    /// The rows drawn from what was kept, over every presented draw.
    pub rows_reused: u64,
    /// The glyph images rasterised.
    pub glyphs_rasterised: u64,
    /// The glyph images asked for and already held.
    pub glyphs_reused: u64,
    /// The glyph images dropped to make room.
    pub glyphs_evicted: u64,
    /// The glyphs that could not be drawn.
    pub glyphs_skipped: u64,
    /// The bytes the glyph images took up at the last draw: a gauge, not a
    /// sum.
    pub atlas_bytes: u64,
    /// The journal entries let go to make room.
    pub journal_dropped: u64,
}

impl Counters {
    /// Counts one draw that answered `drawn`: a presented draw with what
    /// it cost, and one that did not present as failed and nothing more.
    /// Work a renderer did for a draw it could not present is not lost
    /// that way: the renderer answers for it in the next draw it presents
    /// ([`Drawn::presented`]), and it is counted then, once.
    pub fn count(&mut self, drawn: &Drawn) {
        if !drawn.presented {
            self.draws_failed += 1;
            return;
        }
        self.draws += 1;
        self.rows_rebuilt += drawn.rows_rebuilt;
        self.rows_reused += drawn.rows_reused;
        self.glyphs_rasterised += drawn.glyphs_rasterised;
        self.glyphs_reused += drawn.glyphs_reused;
        self.glyphs_evicted += drawn.glyphs_evicted;
        self.glyphs_skipped += drawn.glyphs_skipped;
        self.atlas_bytes = drawn.atlas_bytes;
    }
}

#[cfg(test)]
mod tests {
    use super::{Counters, Entry, JOURNAL_CAPACITY, Journal};
    use crate::port::Drawn;

    /// The entry of the presented frame `serial`, with times made from it.
    fn entry(serial: u64) -> Entry {
        Entry {
            serial,
            input_ns: serial * 100,
            draw_ns: serial * 100 + 10,
            present_ns: serial * 100 + 30,
            rows_rebuilt: serial % 3,
            rows_reused: serial % 5,
        }
    }

    #[test]
    fn an_entry_is_kept_as_it_was_recorded() {
        let mut journal = Journal::new();
        assert!(journal.entries().is_empty());
        journal.record(entry(1));
        journal.record(entry(2));
        assert_eq!(journal.entries(), vec![entry(1), entry(2)]);
        assert_eq!(
            journal.entries()[1],
            Entry {
                serial: 2,
                input_ns: 200,
                draw_ns: 210,
                present_ns: 230,
                rows_rebuilt: 2,
                rows_reused: 2,
            }
        );
        assert_eq!(journal.dropped(), 0);
    }

    #[test]
    fn the_journal_keeps_the_last_entries_and_counts_the_rest() {
        let mut journal = Journal::new();
        let capacity = JOURNAL_CAPACITY as u64;
        for serial in 1..=capacity {
            journal.record(entry(serial));
        }
        assert_eq!(journal.entries().len(), JOURNAL_CAPACITY);
        assert_eq!(journal.dropped(), 0);
        for serial in capacity + 1..=capacity + 10 {
            journal.record(entry(serial));
        }
        let kept = journal.entries();
        assert_eq!(kept.len(), JOURNAL_CAPACITY);
        assert_eq!(kept.first(), Some(&entry(11)));
        assert_eq!(kept.last(), Some(&entry(capacity + 10)));
        assert!(
            kept.windows(2)
                .all(|pair| pair[1].serial == pair[0].serial + 1)
        );
        assert_eq!(journal.dropped(), 10);
    }

    #[test]
    fn a_presented_draw_is_counted_with_what_it_cost() {
        let mut counters = Counters::default();
        let drawn = Drawn {
            presented: true,
            hidden: false,
            rows_rebuilt: 3,
            rows_reused: 4,
            glyphs_rasterised: 5,
            glyphs_reused: 6,
            glyphs_evicted: 7,
            glyphs_skipped: 8,
            atlas_bytes: 900,
        };
        counters.count(&drawn);
        counters.count(&Drawn {
            atlas_bytes: 500,
            ..drawn
        });
        assert_eq!(
            counters,
            Counters {
                draws: 2,
                rows_rebuilt: 6,
                rows_reused: 8,
                glyphs_rasterised: 10,
                glyphs_reused: 12,
                glyphs_evicted: 14,
                glyphs_skipped: 16,
                // The bytes are those of the last draw.
                atlas_bytes: 500,
                ..Counters::default()
            }
        );
    }

    #[test]
    fn a_draw_that_did_not_present_is_counted_as_failed_and_costs_nothing() {
        let mut counters = Counters::default();
        counters.count(&Drawn {
            presented: true,
            rows_rebuilt: 3,
            atlas_bytes: 900,
            ..Drawn::default()
        });
        let before = counters;
        counters.count(&Drawn {
            presented: false,
            rows_rebuilt: 99,
            atlas_bytes: 1,
            ..Drawn::default()
        });
        assert_eq!(
            counters,
            Counters {
                draws_failed: 1,
                ..before
            }
        );
    }
}
