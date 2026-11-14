//! The glyph cache: each glyph image rasterised once and kept.
//!
//! A glyph is drawn from an image of it, and making that image is the
//! costly part of drawing text. The cache makes each image once, through
//! the [`Rasterize`] trait, and hands the same one back whenever it is
//! asked for again.
//!
//! # What an image is kept by
//!
//! Its [`GlyphKey`]: the resolved font's id, the glyph's id in that font,
//! the subpixel bin it is drawn at, and the kind that was asked for. A
//! resolved font's size, variation coordinates and synthesis are fixed for
//! a generation of the frame's fonts, so the font's id stands for them.
//!
//! # Positions
//!
//! A glyph's place across a row is a fraction of a pixel, and its image
//! depends on that fraction. Keeping an image for every fraction would
//! keep nothing, so a place is rounded to a quarter of a pixel
//! ([`SUBPIXEL_BINS`], [`bin_of`]): a glyph is drawn at most an eighth of
//! a pixel from where it was shaped, and has at most four images. There
//! are no bins down the page: a baseline is a whole pixel.
//!
//! # Kinds
//!
//! An image is one of three [`Kind`]s, each drawn by its own rule: a mask
//! (one coverage a pixel), a subpixel mask (a coverage for each of red,
//! green and blue) or a colour image. What is asked for is a mask or a
//! subpixel mask; a colour glyph comes back in colour whichever was asked,
//! and is kept under the key it was asked by. The images of a kind are in
//! pages of that kind's format ([`atlas`](crate::atlas)).
//!
//! # In use is never evicted
//!
//! An image is pinned once for each time it is given out
//! ([`GlyphCache::get`]) and unpinned when whoever took it lets it go
//! ([`GlyphCache::unpin`]). The painter takes an image for each row it
//! builds and lets it go when the row is dropped, and it keeps the rows of
//! the frame last drawn: so an image a row on screen draws is always
//! pinned. Only an image with no pin is ever let go to make room, the one
//! unused for longest first.
//!
//! # The bound
//!
//! The pages may come to a budget of bytes. When an image needs a page
//! that would pass it, unpinned images are let go first: those of its own
//! kind until it fits where one was, then those of the other kinds and
//! the pages that empties. If what is pinned alone needs more, the page is
//! added all the same and counted ([`Stats::over_budget`]): in use wins.
//! The excess is given back at the start of a draw ([`GlyphCache::trim`]),
//! page by page, as soon as a page has no pinned image.
//!
//! # Generations
//!
//! A key means one glyph image for one generation of the frame's fonts.
//! When a frame of another generation arrives the painter empties the
//! cache ([`GlyphCache::clear`]).
//!
//! # What is not drawn
//!
//! A glyph with no image (its font has no bytes, as layout's fake
//! shaper's, or the rasteriser has none for it) and one larger than a
//! page are not kept, and are counted ([`Stats::skipped`]). A glyph that
//! draws nothing, a space, is kept and takes no room.

use std::collections::HashMap;

use editor_layout::shaper::{ResolvedFont, ResolvedFontId};

use crate::atlas::{Atlas, Slot};

/// How many places across a pixel a glyph is rasterised at.
pub const SUBPIXEL_BINS: u8 = 4;

/// What a glyph image holds for each pixel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    /// One byte: how much of the pixel the glyph covers.
    Mask,
    /// Four bytes: how much of the pixel's red, green and blue stripes
    /// the glyph covers, and their mean.
    Subpixel,
    /// Four bytes: red, green, blue and alpha, the colours multiplied by
    /// the alpha.
    Color,
}

impl Kind {
    /// How many bytes a pixel of this kind takes.
    pub const fn bytes(self) -> u32 {
        match self {
            Self::Mask => 1,
            Self::Subpixel | Self::Color => 4,
        }
    }
}

/// What a glyph image is kept by.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GlyphKey {
    /// The font it is drawn in.
    pub font: ResolvedFontId,
    /// The glyph's id in that font.
    pub glyph: u32,
    /// Which quarter of a pixel it is drawn at, from 0.
    pub bin: u8,
    /// Whether a subpixel mask was asked for, and not a plain one.
    pub subpixel: bool,
}

/// The whole pixel and the bin of a place `x` pixels across: `x` rounded
/// to the nearest quarter of a pixel, as the pixel it falls in and how
/// many quarters past that pixel's left edge.
pub fn bin_of(x: f32) -> (i32, u8) {
    let bins = i32::from(SUBPIXEL_BINS);
    let quarters = (x * f32::from(SUBPIXEL_BINS)).round() as i32;
    (quarters.div_euclid(bins), quarters.rem_euclid(bins) as u8)
}

/// One glyph to rasterise.
#[derive(Debug, Clone, Copy)]
pub struct GlyphRequest<'a> {
    /// The font: its bytes, its face, its size and its synthesis.
    pub font: &'a ResolvedFont,
    /// What the image will be kept by: the glyph, the bin and the kind
    /// asked for.
    pub key: GlyphKey,
    /// Whether the outline is fitted to the pixel grid.
    pub hint: bool,
}

/// A rasterised glyph.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GlyphImage {
    /// What it holds for each pixel.
    pub kind: Kind,
    /// How far across it is, in pixels; 0 for a glyph that draws nothing.
    pub width: u32,
    /// How far down.
    pub height: u32,
    /// How far right of the glyph's whole-pixel place its left edge is.
    pub left: i32,
    /// How far above the baseline its top edge is.
    pub top: i32,
    /// Its pixels, row by row from the top: `width * height` times the
    /// kind's bytes.
    pub data: Vec<u8>,
}

/// What makes a glyph's image. The real one is over a font rasteriser;
/// the cache's and the painter's tests run on a fake.
pub trait Rasterize {
    /// The image of the glyph `request` names; `None` when there is none
    /// to make: the font has no bytes, or no such glyph.
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage>;
}

/// A glyph image the cache holds, as what draws it needs it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placed {
    /// What the image holds for each pixel.
    pub kind: Kind,
    /// How far right of the glyph's whole-pixel place its left edge is.
    pub left: i32,
    /// How far above the baseline its top edge is.
    pub top: i32,
    /// Where it is in the atlas; `None` for a glyph that draws nothing,
    /// which takes no room.
    pub slot: Option<Slot>,
}

/// What a cache has done since it was made, counted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    /// The images it had made.
    pub rasterised: u64,
    /// The images it was asked for and held.
    pub reused: u64,
    /// The images it let go to make room.
    pub evicted: u64,
    /// The glyphs it was asked for that have no image, or one larger than
    /// a page.
    pub skipped: u64,
    /// The pages it added past its budget, because what was in use left
    /// no room within it.
    pub over_budget: u64,
}

/// One image held.
#[derive(Debug, Clone, Copy)]
struct Held {
    /// The image.
    placed: Placed,
    /// How many kept rows draw it.
    pins: u32,
    /// When it was last asked for: the cache's count of requests then.
    used: u64,
}

/// The glyph images kept, by key, in the pages of an atlas.
pub struct GlyphCache {
    /// The images.
    entries: HashMap<GlyphKey, Held>,
    /// The pages they are in.
    atlas: Atlas,
    /// How many bytes the pages may come to.
    budget: u64,
    /// How many requests it has had.
    requests: u64,
    /// What it has done.
    stats: Stats,
}

impl GlyphCache {
    /// A cache that holds nothing, whose pages are `page_size` pixels
    /// across and down and may come to `budget` bytes in all.
    pub fn new(page_size: u32, budget: u64) -> Self {
        Self {
            entries: HashMap::new(),
            atlas: Atlas::new(page_size),
            budget,
            requests: 0,
            stats: Stats::default(),
        }
    }

    /// The image for `key`, a glyph of `font`: the one held, or one
    /// `rasterizer` makes now and the cache keeps. `None` when the glyph
    /// has no image, or one larger than a page: that is counted and not
    /// kept.
    ///
    /// The image is pinned once for each time it is given: it stays where
    /// it is until [`GlyphCache::unpin`] has been called as many times.
    pub fn get<Z: Rasterize>(
        &mut self,
        key: GlyphKey,
        font: &ResolvedFont,
        hint: bool,
        rasterizer: &mut Z,
    ) -> Option<Placed> {
        self.requests += 1;
        if let Some(held) = self.entries.get_mut(&key) {
            held.pins += 1;
            held.used = self.requests;
            self.stats.reused += 1;
            return Some(held.placed);
        }
        let Some(image) = rasterizer.rasterize(&GlyphRequest { font, key, hint }) else {
            self.stats.skipped += 1;
            return None;
        };
        let slot = if image.width == 0 || image.height == 0 {
            None
        } else if let Some(slot) = self.store(&image) {
            Some(slot)
        } else {
            self.stats.skipped += 1;
            return None;
        };
        self.stats.rasterised += 1;
        let placed = Placed {
            kind: image.kind,
            left: image.left,
            top: image.top,
            slot,
        };
        self.entries.insert(
            key,
            Held {
                placed,
                pins: 1,
                used: self.requests,
            },
        );
        Some(placed)
    }

    /// Puts `image` in the atlas, making room if it must: where it went,
    /// or `None` when it is larger than a page.
    fn store(&mut self, image: &GlyphImage) -> Option<Slot> {
        let (kind, width, height) = (image.kind, image.width, image.height);
        if !self.atlas.fits(width, height) {
            return None;
        }
        if let Some(slot) = self.atlas.place(kind, width, height, &image.data) {
            return Some(slot);
        }
        let page = self.atlas.page_bytes(kind);
        if self.atlas.bytes() + page > self.budget {
            // No room for another page within the budget. Let go of the
            // images of this kind that no kept row draws, the one unused
            // for longest first, until the new one fits where one was.
            for key in self.unpinned(Some(kind)) {
                self.evict(key);
                if let Some(slot) = self.atlas.place(kind, width, height, &image.data) {
                    return Some(slot);
                }
            }
            // Every page of this kind is held by an image in use. Let go
            // of the unused images of the other kinds, and of the pages
            // that empties, until a page of this kind is within the budget.
            for key in self.unpinned(None) {
                self.evict(key);
                self.atlas.drop_empty();
                if self.atlas.bytes() + page <= self.budget {
                    break;
                }
            }
            self.atlas.drop_empty();
        }
        if self.atlas.bytes() + page > self.budget {
            // What is in use leaves no room: in use wins, and the excess
            // is counted.
            self.stats.over_budget += 1;
        }
        self.atlas.add_page(kind);
        self.atlas.place(kind, width, height, &image.data)
    }

    /// The keys of the images no kept row draws, of `kind` or of every
    /// kind, the one unused for longest first.
    fn unpinned(&self, kind: Option<Kind>) -> Vec<GlyphKey> {
        let mut keys: Vec<(u64, GlyphKey)> = self
            .entries
            .iter()
            .filter(|(_, held)| held.pins == 0 && held.placed.slot.is_some())
            .filter(|(_, held)| kind.is_none_or(|kind| held.placed.kind == kind))
            .map(|(key, held)| (held.used, *key))
            .collect();
        keys.sort_unstable_by_key(|(used, _)| *used);
        keys.into_iter().map(|(_, key)| key).collect()
    }

    /// Lets the image for `key` go to make room, and counts it.
    fn evict(&mut self, key: GlyphKey) {
        if let Some(held) = self.entries.remove(&key) {
            if let Some(slot) = held.placed.slot {
                self.atlas.free(slot);
            }
            self.stats.evicted += 1;
        }
    }

    /// Takes one pin off the image for `key`: one kept row fewer draws
    /// it.
    pub fn unpin(&mut self, key: GlyphKey) {
        if let Some(held) = self.entries.get_mut(&key) {
            held.pins = held.pins.saturating_sub(1);
        }
    }

    /// Lets every image go, pinned or not, with every page: for when the
    /// frame's fonts are of another generation and no key means what it
    /// did.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.atlas = Atlas::new(self.atlas.page_size());
    }

    /// Gives back what is not needed, at the start of a draw: every page
    /// that holds no image, and, while the pages come to more than the
    /// budget, every page none of whose images is pinned, the oldest
    /// first.
    pub fn trim(&mut self) {
        self.atlas.drop_empty();
        let pages: Vec<u32> = self.atlas.pages().map(|page| page.number).collect();
        for page in pages {
            if self.atlas.bytes() <= self.budget {
                break;
            }
            let on_page = |held: &Held| held.placed.slot.is_some_and(|slot| slot.page == page);
            if self
                .entries
                .values()
                .any(|held| on_page(held) && held.pins > 0)
            {
                continue;
            }
            let keys: Vec<GlyphKey> = self
                .entries
                .iter()
                .filter(|(_, held)| on_page(held))
                .map(|(key, _)| *key)
                .collect();
            for key in keys {
                self.evict(key);
            }
            self.atlas.drop_empty();
        }
    }

    /// Whether an image is held for `key`.
    pub fn holds(&self, key: GlyphKey) -> bool {
        self.entries.contains_key(&key)
    }

    /// How many images are held.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether no image is held.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// What the cache has done since it was made.
    pub fn stats(&self) -> Stats {
        self.stats
    }

    /// The pages the images are in.
    pub fn atlas(&self) -> &Atlas {
        &self.atlas
    }
}

#[cfg(test)]
pub(crate) mod fake;

#[cfg(test)]
mod tests {
    use editor_layout::shaper::ResolvedFontId;

    use super::fake::{FakeRasterizer, font};
    use super::{GlyphCache, GlyphKey, Kind, Placed, SUBPIXEL_BINS, Stats, bin_of};

    /// A page size for the tests: small, so a page fills quickly.
    const PAGE: u32 = 32;

    /// The bytes of one page of masks of that size.
    const MASK_PAGE: u64 = (PAGE * PAGE) as u64;

    /// A cache whose budget is never reached.
    fn roomy() -> GlyphCache {
        GlyphCache::new(PAGE, u64::MAX)
    }

    /// A cache whose budget is one page of masks.
    fn one_page() -> GlyphCache {
        GlyphCache::new(PAGE, MASK_PAGE)
    }

    /// The key of the glyph `glyph` of font 0 at bin 0, as a plain mask.
    fn key(glyph: u32) -> GlyphKey {
        GlyphKey {
            font: ResolvedFontId(0),
            glyph,
            bin: 0,
            subpixel: false,
        }
    }

    /// Asks `cache` for the mask of `glyph` and lets it go at once: an
    /// image no kept row draws.
    fn touch(cache: &mut GlyphCache, rasterizer: &mut FakeRasterizer, glyph: u32) {
        cache.get(key(glyph), &font(16.0), true, rasterizer);
        cache.unpin(key(glyph));
    }

    #[test]
    fn a_glyph_is_rasterised_once_and_reused() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        let font = font(16.0);
        let first = cache.get(key(7), &font, true, &mut rasterizer);
        let again = cache.get(key(7), &font, true, &mut rasterizer);
        assert!(first.is_some());
        assert_eq!(again, first);
        assert_eq!(rasterizer.asked.len(), 1);
        // Another glyph is another image, elsewhere.
        let other = cache.get(key(8), &font, true, &mut rasterizer);
        assert_ne!(other, first);
        assert_eq!(rasterizer.asked.len(), 2);
        assert_eq!(
            cache.stats(),
            Stats {
                rasterised: 2,
                reused: 1,
                ..Stats::default()
            }
        );
        assert_eq!(cache.len(), 2);
        // Each is in the atlas as the rasteriser made it.
        for (glyph, placed) in [(7, first), (8, other)] {
            let slot = placed.and_then(|placed| placed.slot).expect("a slot");
            let made = rasterizer.image(key(glyph)).expect("an image");
            assert_eq!(cache.atlas().read(slot), made.data);
        }
    }

    #[test]
    fn a_glyph_a_kept_row_draws_is_never_evicted() {
        let (mut cache, mut rasterizer) = (one_page(), FakeRasterizer::new());
        let font = font(16.0);
        // Glyphs asked for and kept, as the rows on screen keep theirs:
        // more of them than the one page of the budget holds.
        let pinned: Vec<(GlyphKey, Placed)> = (0..60)
            .map(|glyph| {
                let placed = cache.get(key(glyph), &font, true, &mut rasterizer);
                (key(glyph), placed.expect("an image"))
            })
            .collect();
        assert!(cache.atlas().pages().count() > 1);
        // Then many more that nothing keeps.
        for glyph in 100..300 {
            touch(&mut cache, &mut rasterizer, glyph);
        }
        // Every one in use is still held, where it was, with its bytes.
        for (key, placed) in &pinned {
            assert!(cache.holds(*key), "{key:?}");
            let slot = placed.slot.expect("a slot");
            let made = rasterizer.image(*key).expect("an image");
            assert_eq!(cache.atlas().read(slot), made.data, "{key:?}");
        }
        // And asking for one again makes no new image.
        let asked = rasterizer.asked.len();
        let (first, placed) = pinned[0];
        assert_eq!(cache.get(first, &font, true, &mut rasterizer), Some(placed));
        assert_eq!(rasterizer.asked.len(), asked);
    }

    #[test]
    fn unpinned_glyphs_are_evicted_oldest_first_at_the_budget() {
        let (mut cache, mut rasterizer) = (one_page(), FakeRasterizer::new());
        for glyph in [0, 1, 2] {
            touch(&mut cache, &mut rasterizer, glyph);
        }
        // The first is asked for again: the second is now the one unused
        // for longest.
        touch(&mut cache, &mut rasterizer, 0);
        let mut next = 3;
        while cache.stats().evicted == 0 {
            touch(&mut cache, &mut rasterizer, next);
            next += 1;
            assert!(cache.atlas().bytes() <= MASK_PAGE, "at glyph {next}");
        }
        // One image was let go to make room for the last: the second.
        assert_eq!(cache.stats().evicted, 1);
        assert!(!cache.holds(key(1)));
        for glyph in [0, 2, next - 1] {
            assert!(cache.holds(key(glyph)), "glyph {glyph}");
        }
        // The next to go is the third, then the first.
        touch(&mut cache, &mut rasterizer, next);
        assert!(!cache.holds(key(2)) && cache.holds(key(0)));
        touch(&mut cache, &mut rasterizer, next + 1);
        assert!(!cache.holds(key(0)));
        // And so on: the pages never pass the budget, and none is added.
        for glyph in next + 2..next + 200 {
            touch(&mut cache, &mut rasterizer, glyph);
            assert!(cache.atlas().bytes() <= MASK_PAGE, "at glyph {glyph}");
        }
        assert_eq!(cache.atlas().pages().count(), 1);
        assert_eq!(cache.stats().over_budget, 0);
    }

    #[test]
    fn more_in_use_than_the_budget_is_kept_counted_and_given_back() {
        let (mut cache, mut rasterizer) = (one_page(), FakeRasterizer::new());
        let font = font(16.0);
        let keys: Vec<GlyphKey> = (0..60).map(key).collect();
        for key in &keys {
            cache.get(*key, &font, true, &mut rasterizer);
        }
        // In use wins: pages are added past the budget, and counted.
        let pages = cache.atlas().pages().count();
        assert!(pages > 1);
        assert_eq!(cache.stats().over_budget, pages as u64 - 1);
        assert_eq!(cache.stats().evicted, 0);
        assert!(cache.atlas().bytes() > MASK_PAGE);
        assert_eq!(cache.len(), 60);
        // While they are in use, a draw gives nothing back.
        cache.trim();
        assert_eq!(cache.atlas().pages().count(), pages);
        assert_eq!(cache.len(), 60);
        // Once nothing uses them, the next draw gives the excess back.
        for key in &keys {
            cache.unpin(*key);
        }
        cache.trim();
        assert_eq!(cache.atlas().pages().count(), 1);
        assert!(cache.atlas().bytes() <= MASK_PAGE);
        // What was on the pages given back is gone and counted; what is
        // on the page that stays is still held.
        assert!(!cache.is_empty());
        assert_eq!(cache.len() as u64 + cache.stats().evicted, 60);
    }

    #[test]
    fn a_page_with_one_image_in_use_is_not_given_back() {
        let (mut cache, mut rasterizer) = (one_page(), FakeRasterizer::new());
        let font = font(16.0);
        let keys: Vec<GlyphKey> = (0..60).map(key).collect();
        let placed: Vec<Placed> = keys
            .iter()
            .filter_map(|key| cache.get(*key, &font, true, &mut rasterizer))
            .collect();
        let pages = cache.atlas().pages().count();
        // All but the last are let go: its page stays, past the budget.
        let last = placed[59].slot.expect("a slot").page;
        for key in &keys[..59] {
            cache.unpin(*key);
        }
        cache.trim();
        assert!(cache.holds(keys[59]));
        assert!(cache.atlas().page(last).is_some());
        assert!(cache.atlas().pages().count() < pages);
    }

    #[test]
    fn an_image_is_pinned_once_for_each_time_it_is_given() {
        let (mut cache, mut rasterizer) = (one_page(), FakeRasterizer::new());
        let font = font(16.0);
        // Two rows draw it.
        cache.get(key(0), &font, true, &mut rasterizer);
        cache.get(key(0), &font, true, &mut rasterizer);
        cache.unpin(key(0));
        for glyph in 100..300 {
            touch(&mut cache, &mut rasterizer, glyph);
        }
        assert!(cache.holds(key(0)));
        // The second row lets it go too, and it goes like any other.
        cache.unpin(key(0));
        for glyph in 300..500 {
            touch(&mut cache, &mut rasterizer, glyph);
        }
        assert!(!cache.holds(key(0)));
        // Letting go of what is not held, or not pinned, does nothing.
        cache.unpin(key(0));
        cache.unpin(key(499));
        cache.unpin(key(499));
        assert!(cache.holds(key(499)));
    }

    #[test]
    fn another_generation_empties_the_cache() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        let font = font(16.0);
        cache.get(key(7), &font, true, &mut rasterizer);
        touch(&mut cache, &mut rasterizer, 8);
        let subpixel = GlyphKey {
            subpixel: true,
            ..key(7)
        };
        cache.get(subpixel, &font, true, &mut rasterizer);
        assert_eq!(cache.atlas().pages().count(), 2);
        cache.clear();
        // Everything goes, in use or not, with its pages; none of it was
        // let go to make room.
        assert!(cache.is_empty());
        assert!(!cache.holds(key(7)));
        assert_eq!(cache.atlas().pages().count(), 0);
        assert_eq!(cache.atlas().bytes(), 0);
        assert_eq!(cache.stats().evicted, 0);
        // Asked for again, a glyph is rasterised again.
        let asked = rasterizer.asked.len();
        assert!(cache.get(key(7), &font, true, &mut rasterizer).is_some());
        assert_eq!(rasterizer.asked.len(), asked + 1);
    }

    #[test]
    fn a_glyph_larger_than_a_page_is_counted_and_not_kept() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        rasterizer.size = Some((PAGE + 1, 4));
        assert_eq!(cache.get(key(7), &font(16.0), true, &mut rasterizer), None);
        assert!(cache.is_empty());
        assert_eq!(cache.atlas().pages().count(), 0);
        assert_eq!(
            cache.stats(),
            Stats {
                skipped: 1,
                ..Stats::default()
            }
        );
    }

    #[test]
    fn a_glyph_that_draws_nothing_is_kept_and_takes_no_room() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        rasterizer.size = Some((0, 0));
        let font = font(16.0);
        let space = cache.get(key(32), &font, true, &mut rasterizer);
        assert_eq!(space.map(|placed| placed.slot), Some(None));
        assert_eq!(cache.get(key(32), &font, true, &mut rasterizer), space);
        assert_eq!(rasterizer.asked.len(), 1);
        assert_eq!(cache.atlas().bytes(), 0);
        assert_eq!(
            cache.stats(),
            Stats {
                rasterised: 1,
                reused: 1,
                ..Stats::default()
            }
        );
    }

    #[test]
    fn the_rasteriser_is_asked_for_the_glyph_as_it_is_kept() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        let font = font(24.0);
        let asked = GlyphKey {
            font: ResolvedFontId(3),
            glyph: 9,
            bin: 2,
            subpixel: true,
        };
        cache.get(asked, &font, false, &mut rasterizer);
        assert_eq!(rasterizer.asked, vec![(asked, 24.0, false)]);
    }

    #[test]
    fn a_mask_a_subpixel_and_a_colour_glyph_each_keep_their_kind() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        rasterizer.colour.insert(40);
        let font = font(16.0);
        let subpixel = |glyph| GlyphKey {
            subpixel: true,
            ..key(glyph)
        };
        let mut kind = |key: GlyphKey| {
            let placed = cache.get(key, &font, true, &mut rasterizer)?;
            let bytes = cache.atlas().read(placed.slot?).len() as u32;
            Some((placed.kind, bytes))
        };
        // Each has as many bytes a pixel as its kind says.
        let pixels = FakeRasterizer::WIDTH * FakeRasterizer::HEIGHT;
        assert_eq!(kind(key(7)), Some((Kind::Mask, pixels)));
        assert_eq!(kind(subpixel(7)), Some((Kind::Subpixel, pixels * 4)));
        // A colour glyph is in colour whichever was asked.
        assert_eq!(kind(key(40)), Some((Kind::Color, pixels * 4)));
        assert_eq!(kind(subpixel(40)), Some((Kind::Color, pixels * 4)));
        // The mask and the subpixel mask of one glyph are two images, and
        // asking for one again does not give the other.
        assert_eq!(kind(key(7)), Some((Kind::Mask, pixels)));
        assert_eq!(kind(subpixel(7)), Some((Kind::Subpixel, pixels * 4)));
        assert_eq!(rasterizer.asked.len(), 4);
        assert_eq!(cache.len(), 4);
        // Each kind is in a page of its own, of its own format.
        let pages: Vec<(Kind, usize)> = cache
            .atlas()
            .pages()
            .map(|page| (page.kind, page.pixels.len()))
            .collect();
        let pixels = (PAGE * PAGE) as usize;
        assert_eq!(
            pages,
            vec![
                (Kind::Mask, pixels),
                (Kind::Subpixel, pixels * 4),
                (Kind::Color, pixels * 4)
            ]
        );
    }

    #[test]
    fn a_place_is_rounded_to_the_nearest_quarter_of_a_pixel() {
        assert_eq!(SUBPIXEL_BINS, 4);
        let places = [
            (10.0, (10, 0)),
            (10.1, (10, 0)),
            (10.2, (10, 1)),
            (10.25, (10, 1)),
            (10.5, (10, 2)),
            (10.7, (10, 3)),
            // Within an eighth of the next pixel: that pixel, bin 0.
            (10.9, (11, 0)),
            (0.0, (0, 0)),
            // Left of the row's start.
            (-0.1, (0, 0)),
            (-0.25, (-1, 3)),
            (-1.5, (-2, 2)),
        ];
        for (x, expected) in places {
            assert_eq!(bin_of(x), expected, "at {x}");
        }
    }

    #[test]
    fn positions_within_a_quarter_pixel_share_an_entry_and_others_do_not() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        let font = font(16.0);
        let mut image = |x: f32| {
            let (_, bin) = bin_of(x);
            cache.get(GlyphKey { bin, ..key(7) }, &font, true, &mut rasterizer)
        };
        let at = image(3.0);
        // The same bin, at another pixel and a little off it.
        assert_eq!(image(8.0), at);
        assert_eq!(image(8.1), at);
        // Each other quarter is an image of its own.
        let quarter = image(8.25);
        let half = image(8.5);
        let three = image(8.75);
        assert_eq!(image(20.3), quarter);
        for (index, one) in [&at, &quarter, &half, &three].iter().enumerate() {
            for other in [&at, &quarter, &half, &three].iter().skip(index + 1) {
                assert_ne!(one, other);
            }
        }
        assert_eq!(rasterizer.asked.len(), 4);
        assert_eq!(cache.len(), 4);
    }

    #[test]
    fn the_same_glyph_of_another_font_is_another_entry() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        let (small, large) = (font(16.0), font(32.0));
        let first = cache.get(key(7), &small, true, &mut rasterizer);
        let other = GlyphKey {
            font: ResolvedFontId(1),
            ..key(7)
        };
        let second = cache.get(other, &large, true, &mut rasterizer);
        assert_ne!(first, second);
        assert_eq!(cache.len(), 2);
    }

    #[test]
    fn a_glyph_with_no_image_is_counted_and_not_kept() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        rasterizer.missing.insert(99);
        let font = font(16.0);
        assert_eq!(cache.get(key(99), &font, true, &mut rasterizer), None);
        assert_eq!(cache.get(key(99), &font, true, &mut rasterizer), None);
        assert!(cache.is_empty());
        assert_eq!(
            cache.stats(),
            Stats {
                skipped: 2,
                ..Stats::default()
            }
        );
    }
}
