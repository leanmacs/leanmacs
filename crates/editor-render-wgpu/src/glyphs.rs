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
//! the subpixel bin it is drawn at, the kind that was asked for, and the
//! luminance bucket of its run's colour, which is 0 unless the rasteriser
//! says its images depend on it ([`Rasterize::by_luminance`]). A
//! resolved font's size, variation coordinates and synthesis are fixed for
//! a generation of the frame's fonts, so the font's id stands for them.
//!
//! The key, the request, the image and the [`Rasterize`] trait are the
//! rasteriser port's, owned by `editor-raster` and re-exported here; the
//! rounding of a place to a bin ([`bin_of`]) is the painter's, and stays.
//!
//! # Positions
//!
//! A glyph's place across a row is a fraction of a pixel, and its image
//! depends on that fraction. Keeping an image for every fraction would
//! keep nothing, so a place is floored to Core Text's own grid
//! ([`bin_of`], [`places_per_pixel`]): thirds of a pixel at scale 1,
//! halves at scale 2 and whole pixels from scale 3. That is where macOS's
//! own text puts a glyph (`CTLineDraw` with the context's default flags,
//! and TextEdit), and it is the rule on every platform here. The bins are
//! twelfths of a pixel ([`SUBPIXEL_BINS`]), which hold each grid, so a
//! glyph has at most three images at scale 1, two at scale 2 and one from
//! scale 3. There are no bins down the page: a baseline is a whole pixel.
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

use editor_raster::ResolvedFont;
pub use editor_raster::{GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize, SUBPIXEL_BINS};

use crate::atlas::{Atlas, Slot};

/// How far under a line of the grid a place may be and still be on it, in
/// pixels: more than the error of an f32 sum of a row's advances, and far
/// less than any step of the grid.
const ON_THE_LINE: f64 = 1.0 / 1024.0;

/// How many places across a pixel Core Text puts a glyph at on a target
/// of `scale`, drawn as native apps draw (the context's default subpixel
/// flags): `4 - scale`, and never fewer than one. Thirds of a pixel at
/// scale 1, halves at scale 2 and whole pixels from scale 3, measured on
/// macOS 27.2.1 (2026-11-20) by drawing one glyph across a pixel in steps
/// of 1/400. A scale that is not whole is taken as the nearest whole
/// scale, and one below 1, or none, as 1.
pub fn places_per_pixel(scale: f32) -> u8 {
    let scale = scale.round().max(1.0);
    (4.0 - scale).max(1.0) as u8
}

/// The whole pixel and the bin of a place `x` pixels across on a target of
/// `scale`: `x` floored to Core Text's grid ([`places_per_pixel`]), as the
/// pixel it falls in and the bin of the grid's line it is floored to, in
/// twelfths of a pixel ([`SUBPIXEL_BINS`]). A place within
/// [`ON_THE_LINE`] under a line is on it.
pub fn bin_of(x: f32, scale: f32) -> (i32, u8) {
    let places = places_per_pixel(scale);
    let lines = ((f64::from(x) + ON_THE_LINE) * f64::from(places)).floor() as i64;
    let per = i64::from(places);
    let bin = lines.rem_euclid(per) as u8 * (SUBPIXEL_BINS / places);
    (lines.div_euclid(per) as i32, bin)
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
    /// did. The atlas stays the one it was, so a page added from here on
    /// has a number no page had before ([`Slot::page`]): what keeps a
    /// copy of a page by its number never takes a new page for an old one.
    pub fn clear(&mut self) {
        for (_, held) in self.entries.drain() {
            if let Some(slot) = held.placed.slot {
                self.atlas.free(slot);
            }
        }
        self.atlas.drop_empty();
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

    /// Whether an image is held for `key`: for tests.
    #[cfg(test)]
    pub fn holds(&self, key: GlyphKey) -> bool {
        self.entries.contains_key(&key)
    }

    /// How many images are held: for tests.
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether no image is held: for tests.
    #[cfg(test)]
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
mod tests {
    use editor_raster::ResolvedFontId;
    use editor_raster::fake::{FakeRasterizer, font};

    use super::{
        GlyphCache, GlyphKey, Kind, Placed, SUBPIXEL_BINS, Stats, bin_of, places_per_pixel,
    };

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
            bucket: 0,
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

    /// The bytes of one page of four bytes a pixel of that size.
    const WIDE_PAGE: u64 = MASK_PAGE * 4;

    /// The key of the glyph `glyph` of font 0 at bin 0, as a subpixel
    /// mask.
    fn subpixel(glyph: u32) -> GlyphKey {
        GlyphKey {
            subpixel: true,
            ..key(glyph)
        }
    }

    /// The kind of each page of `cache`, in the order they were added.
    fn kinds(cache: &GlyphCache) -> Vec<Kind> {
        cache.atlas().pages().map(|page| page.kind).collect()
    }

    #[test]
    fn unpinned_images_of_another_kind_and_their_pages_make_room_at_the_budget() {
        // A budget of one page of four bytes a pixel.
        let mut cache = GlyphCache::new(PAGE, WIDE_PAGE);
        let mut rasterizer = FakeRasterizer::new();
        rasterizer.colour.insert(40);
        let font = font(16.0);
        // A page of masks that nothing keeps.
        for glyph in 0..5 {
            touch(&mut cache, &mut rasterizer, glyph);
        }
        assert_eq!(kinds(&cache), vec![Kind::Mask]);
        // A subpixel mask needs a page that, with the masks', would pass
        // the budget: the masks are let go, and their page with them.
        let placed = cache.get(subpixel(7), &font, true, &mut rasterizer);
        let slot = placed.and_then(|placed| placed.slot).expect("a slot");
        for glyph in 0..5 {
            assert!(!cache.holds(key(glyph)), "glyph {glyph}");
        }
        assert_eq!(cache.stats().evicted, 5);
        assert_eq!(kinds(&cache), vec![Kind::Subpixel]);
        assert!(cache.atlas().bytes() <= WIDE_PAGE);
        assert_eq!(cache.stats().over_budget, 0);
        let made = rasterizer.image(subpixel(7)).expect("an image");
        assert_eq!(cache.atlas().read(slot), made.data);
        // So does a subpixel mask nothing keeps for a colour glyph, and
        // that one for a mask.
        cache.unpin(subpixel(7));
        touch(&mut cache, &mut rasterizer, 40);
        assert!(!cache.holds(subpixel(7)));
        assert_eq!(kinds(&cache), vec![Kind::Color]);
        touch(&mut cache, &mut rasterizer, 8);
        assert!(!cache.holds(key(40)) && cache.holds(key(8)));
        assert_eq!(kinds(&cache), vec![Kind::Mask]);
        assert_eq!(cache.stats().over_budget, 0);
    }

    #[test]
    fn no_more_of_another_kind_is_let_go_than_makes_room() {
        // Room for a page of four bytes a pixel and one of masks.
        let mut cache = GlyphCache::new(PAGE, WIDE_PAGE + MASK_PAGE);
        let mut rasterizer = FakeRasterizer::new();
        // Masks that nothing keeps, until the first is on a second page.
        let mut next = 0;
        while cache.atlas().pages().count() < 2 {
            touch(&mut cache, &mut rasterizer, next);
            next += 1;
        }
        let newest = next - 1;
        // The masks unused for longest go, those of the first page, until
        // that page is empty: then there is room, and the rest stay.
        let placed = cache.get(subpixel(7), &font(16.0), true, &mut rasterizer);
        assert!(placed.is_some_and(|placed| placed.slot.is_some()));
        for glyph in 0..newest {
            assert!(!cache.holds(key(glyph)), "glyph {glyph}");
        }
        assert!(cache.holds(key(newest)));
        assert_eq!(cache.stats().evicted, u64::from(newest));
        assert_eq!(kinds(&cache), vec![Kind::Mask, Kind::Subpixel]);
        assert!(cache.atlas().bytes() <= WIDE_PAGE + MASK_PAGE);
        assert_eq!(cache.stats().over_budget, 0);
    }

    #[test]
    fn an_image_in_use_keeps_its_page_when_another_kind_needs_the_room() {
        let mut cache = GlyphCache::new(PAGE, WIDE_PAGE);
        let mut rasterizer = FakeRasterizer::new();
        let font = font(16.0);
        // A page of masks, one of them in use.
        let pinned = cache.get(key(0), &font, true, &mut rasterizer);
        let pinned = pinned.and_then(|placed| placed.slot).expect("a slot");
        for glyph in 1..5 {
            touch(&mut cache, &mut rasterizer, glyph);
        }
        // In use wins: the subpixel mask's page is added past the budget,
        // and counted.
        let placed = cache.get(subpixel(7), &font, true, &mut rasterizer);
        assert!(placed.is_some_and(|placed| placed.slot.is_some()));
        assert!(cache.holds(key(0)));
        let made = rasterizer.image(key(0)).expect("an image");
        assert_eq!(cache.atlas().read(pinned), made.data);
        assert_eq!(kinds(&cache), vec![Kind::Mask, Kind::Subpixel]);
        assert!(cache.atlas().bytes() > WIDE_PAGE);
        assert_eq!(cache.stats().over_budget, 1);
        // Once nothing uses the mask, the next draw gives its page back.
        cache.unpin(key(0));
        cache.trim();
        assert_eq!(kinds(&cache), vec![Kind::Subpixel]);
        assert!(cache.holds(subpixel(7)));
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
    fn a_page_of_another_generation_has_a_number_no_page_had_before() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        let font = font(16.0);
        let subpixel = GlyphKey {
            subpixel: true,
            ..key(7)
        };
        let numbers = |cache: &GlyphCache| -> Vec<u32> {
            cache.atlas().pages().map(|page| page.number).collect()
        };
        cache.get(key(7), &font, true, &mut rasterizer);
        cache.get(subpixel, &font, true, &mut rasterizer);
        let earlier = numbers(&cache);
        assert_eq!(earlier.len(), 2);
        // The same glyphs again under the generation after: whatever keeps
        // a copy of a page by its number must not take a new page for one
        // it holds.
        cache.clear();
        cache.get(key(7), &font, true, &mut rasterizer);
        cache.get(subpixel, &font, true, &mut rasterizer);
        let later = numbers(&cache);
        assert_eq!(later.len(), 2);
        for number in &later {
            assert!(!earlier.contains(number), "{number} of {earlier:?}");
        }
        // And an image placed says the page it is in by that number.
        let placed = cache.get(key(7), &font, true, &mut rasterizer);
        let page = placed.and_then(|placed| placed.slot).map(|slot| slot.page);
        assert_eq!(page, Some(later[0]));
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
            bucket: 0,
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
    fn core_texts_grid_is_thirds_at_scale_one_halves_at_two_and_whole_pixels_from_three() {
        assert_eq!(SUBPIXEL_BINS, 12);
        let grids: Vec<u8> = [1.0, 2.0, 3.0, 4.0, 1.4, 1.5, 0.0, f32::NAN]
            .into_iter()
            .map(places_per_pixel)
            .collect();
        // 1.4 is drawn as scale 1 and 1.5 as 2; a scale that is no scale
        // as 1.
        assert_eq!(grids, vec![3, 2, 1, 1, 3, 2, 3, 3]);
    }

    #[test]
    fn at_scale_one_a_place_is_floored_to_a_third_of_a_pixel() {
        let places = [
            (10.0, (10, 0)),
            (10.3, (10, 0)),
            (10.34, (10, 4)),
            (10.5, (10, 4)),
            (10.67, (10, 8)),
            // Short of the next pixel by any amount: still this one.
            (10.9, (10, 8)),
            (11.0, (11, 0)),
            (0.0, (0, 0)),
            // Left of the row's start.
            (-0.1, (-1, 8)),
            (-0.5, (-1, 4)),
            (-1.5, (-2, 4)),
        ];
        for (x, expected) in places {
            assert_eq!(bin_of(x, 1.0), expected, "at {x}");
        }
    }

    #[test]
    fn at_scale_two_a_place_is_floored_to_half_a_pixel() {
        let places = [
            (16.0, (16, 0)),
            (16.3, (16, 0)),
            (16.5, (16, 6)),
            (16.8, (16, 6)),
            (33.4, (33, 0)),
            (-0.2, (-1, 6)),
        ];
        for (x, expected) in places {
            assert_eq!(bin_of(x, 2.0), expected, "at {x}");
        }
        for tenth in 0..100 {
            let (_, bin) = bin_of(tenth as f32 / 10.0, 2.0);
            assert!(bin == 0 || bin == 6, "at {tenth} tenths: bin {bin}");
        }
    }

    #[test]
    fn at_scale_three_and_above_a_place_is_floored_to_a_whole_pixel() {
        for scale in [3.0, 4.0] {
            assert_eq!(bin_of(10.9, scale), (10, 0));
            assert_eq!(bin_of(-0.1, scale), (-1, 0));
        }
    }

    #[test]
    fn a_place_a_hair_under_a_grid_line_is_on_it() {
        // A place that is on a line in exact arithmetic can come out of
        // f32 sums just under it: within 1/1024 of a pixel it is on the
        // line, and further under it is not.
        let under = |x: f32| f32::from_bits(x.to_bits() - 1);
        assert_eq!(bin_of(under(11.0), 1.0), (11, 0));
        assert_eq!(bin_of(under(16.5), 2.0), (16, 6));
        assert_eq!(bin_of(under(10.0 + 1.0 / 3.0), 1.0), (10, 4));
        assert_eq!(bin_of(10.0 + 1.0 / 3.0 - 1.0 / 2048.0, 1.0), (10, 4));
        assert_eq!(bin_of(10.0 + 1.0 / 3.0 - 1.0 / 512.0, 1.0), (10, 0));
        assert_eq!(bin_of(16.5 - 1.0 / 512.0, 2.0), (16, 0));
    }

    #[test]
    fn positions_within_a_third_of_a_pixel_share_an_entry_at_scale_one_and_others_do_not() {
        let (mut cache, mut rasterizer) = (roomy(), FakeRasterizer::new());
        let font = font(16.0);
        let mut image = |x: f32| {
            let (_, bin) = bin_of(x, 1.0);
            cache.get(GlyphKey { bin, ..key(7) }, &font, true, &mut rasterizer)
        };
        let at = image(3.0);
        // The same bin, at another pixel and a little off it.
        assert_eq!(image(8.0), at);
        assert_eq!(image(8.3), at);
        // Each other third is an image of its own.
        let third = image(8.4);
        let two = image(8.7);
        assert_eq!(image(20.5), third);
        assert_ne!(at, third);
        assert_ne!(at, two);
        assert_ne!(third, two);
        assert_eq!(rasterizer.asked.len(), 3);
        assert_eq!(cache.len(), 3);
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
