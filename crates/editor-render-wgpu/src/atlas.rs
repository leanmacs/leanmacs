//! The atlas: the pages glyph images are packed into.
//!
//! A page is a square of pixels of one [`Kind`], so of one format: masks
//! in pages of one byte a pixel, subpixel masks and colour images each in
//! pages of four. An image is copied into a free rectangle of a page of
//! its kind ([`Atlas::place`]) and stays there, at the [`Slot`] it was
//! given, until it is freed ([`Atlas::free`]); the rectangle is then used
//! again. Where a rectangle goes is the packing library's business
//! (`etagere`, behind this type): nothing here or above says how many
//! images a page holds.
//!
//! The atlas decides nothing about what is kept: it adds a page when it
//! is told to, and drops a page that holds no image when it is told to.
//! Which images stay, and how many bytes the pages may come to, is the
//! glyph cache's ([`glyphs`](crate::glyphs)).
//!
//! A page's pixels are kept here, on the CPU, whatever draws them: the
//! compositor reads them as they are, and a GPU is sent the same bytes.

use etagere::{AllocId, AtlasAllocator, size2};

use crate::glyphs::Kind;

/// Where an image is in the atlas.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slot {
    /// The page's number: never used again once the page is dropped.
    pub page: u32,
    /// The left edge of the image in the page.
    pub x: u32,
    /// Its top edge.
    pub y: u32,
    /// How far across it is.
    pub width: u32,
    /// How far down.
    pub height: u32,
    /// The packing library's name for the rectangle.
    id: AllocId,
}

/// One page.
struct Page {
    /// Its number.
    number: u32,
    /// What its pixels hold.
    kind: Kind,
    /// Which of its rectangles are taken.
    allocator: AtlasAllocator,
    /// Its pixels, row by row.
    pixels: Vec<u8>,
    /// How many images it holds.
    images: u32,
    /// How many images have been written to it.
    written: u64,
}

/// A page, as what draws from it reads it.
#[derive(Debug, Clone, Copy)]
pub struct PageView<'a> {
    /// Its number.
    pub number: u32,
    /// What its pixels hold.
    pub kind: Kind,
    /// How far across and down it is.
    pub size: u32,
    /// Its pixels, row by row: `size * size` times the kind's bytes.
    pub pixels: &'a [u8],
    /// How many images have been written to it since it was added: a
    /// device that keeps a copy of the page sends it again when this has
    /// moved on.
    pub written: u64,
}

/// The pages.
pub struct Atlas {
    /// How far across and down every page is.
    page_size: u32,
    /// The pages, in the order they were added.
    pages: Vec<Page>,
    /// The number the next page gets.
    next: u32,
}

impl Atlas {
    /// An atlas with no page, whose pages will be `page_size` pixels
    /// across and down.
    pub fn new(page_size: u32) -> Self {
        Self {
            page_size,
            pages: Vec::new(),
            next: 1,
        }
    }

    /// How far across and down every page is.
    pub fn page_size(&self) -> u32 {
        self.page_size
    }

    /// How many bytes a page of `kind` takes.
    pub fn page_bytes(&self, kind: Kind) -> u64 {
        u64::from(self.page_size) * u64::from(self.page_size) * u64::from(kind.bytes())
    }

    /// How many bytes the pages take in all.
    pub fn bytes(&self) -> u64 {
        self.pages
            .iter()
            .map(|page| self.page_bytes(page.kind))
            .sum()
    }

    /// Whether an image `width` across and `height` down fits a page at
    /// all.
    pub fn fits(&self, width: u32, height: u32) -> bool {
        width <= self.page_size && height <= self.page_size
    }

    /// Adds an empty page of `kind`, and gives its number.
    pub fn add_page(&mut self, kind: Kind) -> u32 {
        let number = self.next;
        self.next += 1;
        let size = i32::try_from(self.page_size).unwrap_or(i32::MAX);
        self.pages.push(Page {
            number,
            kind,
            allocator: AtlasAllocator::new(size2(size, size)),
            pixels: vec![0; self.page_bytes(kind) as usize],
            images: 0,
            written: 0,
        });
        number
    }

    /// Copies an image of `kind`, `width` across and `height` down, into
    /// a free rectangle of a page of that kind: where it now is, or
    /// `None` when no page of the kind has room. `data` is the image row
    /// by row.
    pub fn place(&mut self, kind: Kind, width: u32, height: u32, data: &[u8]) -> Option<Slot> {
        let (Ok(across), Ok(down)) = (i32::try_from(width), i32::try_from(height)) else {
            return None;
        };
        let page_size = self.page_size;
        for page in self.pages.iter_mut().filter(|page| page.kind == kind) {
            let Some(allocation) = page.allocator.allocate(size2(across, down)) else {
                continue;
            };
            let corner = allocation.rectangle.min;
            let slot = Slot {
                page: page.number,
                x: corner.x as u32,
                y: corner.y as u32,
                width,
                height,
                id: allocation.id,
            };
            page.images += 1;
            page.written += 1;
            let bytes = kind.bytes() as usize;
            let (stride, row) = (page_size as usize * bytes, width as usize * bytes);
            for (index, line) in data.chunks_exact(row.max(1)).enumerate() {
                let start = (slot.y as usize + index) * stride + slot.x as usize * bytes;
                page.pixels[start..start + row].copy_from_slice(line);
            }
            return Some(slot);
        }
        None
    }

    /// Gives the rectangle of `slot` back, to be used again.
    pub fn free(&mut self, slot: Slot) {
        if let Some(page) = self.pages.iter_mut().find(|page| page.number == slot.page) {
            page.allocator.deallocate(slot.id);
            page.images = page.images.saturating_sub(1);
        }
    }

    /// Drops every page that holds no image, and says how many.
    pub fn drop_empty(&mut self) -> usize {
        let before = self.pages.len();
        self.pages.retain(|page| page.images > 0);
        before - self.pages.len()
    }

    /// The pages, in the order they were added.
    pub fn pages(&self) -> impl Iterator<Item = PageView<'_>> {
        self.pages.iter().map(|page| PageView {
            number: page.number,
            kind: page.kind,
            size: self.page_size,
            pixels: &page.pixels,
            written: page.written,
        })
    }

    /// The page numbered `number`.
    pub fn page(&self, number: u32) -> Option<PageView<'_>> {
        self.pages().find(|page| page.number == number)
    }

    /// The bytes of the image at `slot`, row by row; none when its page
    /// is gone. For tests.
    #[cfg(test)]
    pub fn read(&self, slot: Slot) -> Vec<u8> {
        self.region(slot.page, (slot.x, slot.y), (slot.width, slot.height))
    }

    /// The bytes of the rectangle of the page numbered `page` whose top
    /// left is `corner` and whose width and height are `size`, row by
    /// row; none when there is no such page. For tests.
    #[cfg(test)]
    pub fn region(&self, page: u32, corner: (u32, u32), size: (u32, u32)) -> Vec<u8> {
        let Some(page) = self.page(page) else {
            return Vec::new();
        };
        let bytes = page.kind.bytes() as usize;
        let stride = page.size as usize * bytes;
        (corner.1..corner.1 + size.1)
            .flat_map(|row| {
                let start = row as usize * stride + corner.0 as usize * bytes;
                page.pixels[start..start + size.0 as usize * bytes]
                    .iter()
                    .copied()
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::{Atlas, Slot};
    use crate::glyphs::Kind;

    /// A page size for the tests: small, so a page fills quickly.
    const PAGE: u32 = 32;

    /// An image of `kind`, `width` by `height`, every byte of it `byte`.
    fn image(kind: Kind, width: u32, height: u32, byte: u8) -> Vec<u8> {
        vec![byte; (width * height * kind.bytes()) as usize]
    }

    /// Places 6 by 10 masks of the byte `byte` in `atlas` until no page
    /// has room: where each went.
    fn fill(atlas: &mut Atlas, byte: u8) -> Vec<Slot> {
        let data = image(Kind::Mask, 6, 10, byte);
        std::iter::from_fn(|| atlas.place(Kind::Mask, 6, 10, &data)).collect()
    }

    /// Whether `one` and `other` share a pixel.
    fn overlap(one: &Slot, other: &Slot) -> bool {
        one.page == other.page
            && one.x < other.x + other.width
            && other.x < one.x + one.width
            && one.y < other.y + other.height
            && other.y < one.y + one.height
    }

    #[test]
    fn an_atlas_with_no_page_has_no_room_and_takes_no_bytes() {
        let mut atlas = Atlas::new(PAGE);
        assert_eq!(atlas.bytes(), 0);
        assert_eq!(
            atlas.place(Kind::Mask, 6, 10, &image(Kind::Mask, 6, 10, 1)),
            None
        );
        assert_eq!(atlas.pages().count(), 0);
    }

    #[test]
    fn an_image_is_read_back_from_where_it_was_placed() {
        let mut atlas = Atlas::new(PAGE);
        let page = atlas.add_page(Kind::Subpixel);
        let data: Vec<u8> = (1..=6 * 10 * 4).map(|byte| (byte % 251) as u8).collect();
        let slot = atlas
            .place(Kind::Subpixel, 6, 10, &data)
            .expect("an empty page has room");
        assert_eq!((slot.page, slot.width, slot.height), (page, 6, 10));
        assert!(slot.x + slot.width <= PAGE && slot.y + slot.height <= PAGE);
        assert_eq!(atlas.read(slot), data);
        // A second image is elsewhere, and leaves the first as it was.
        let other = image(Kind::Subpixel, 6, 10, 0xee);
        let second = atlas
            .place(Kind::Subpixel, 6, 10, &other)
            .expect("the page has room for two");
        assert!(!overlap(&slot, &second));
        assert_eq!(atlas.read(second), other);
        assert_eq!(atlas.read(slot), data);
    }

    #[test]
    fn the_images_of_a_full_page_share_no_pixel() {
        let mut atlas = Atlas::new(PAGE);
        atlas.add_page(Kind::Mask);
        let slots = fill(&mut atlas, 7);
        // More than one fits, and fewer than the page has pixels for.
        assert!(slots.len() > 1);
        assert!(slots.len() as u32 <= PAGE * PAGE / 60);
        for (index, one) in slots.iter().enumerate() {
            for other in &slots[index + 1..] {
                assert!(!overlap(one, other), "{one:?} and {other:?}");
            }
        }
    }

    #[test]
    fn a_freed_rectangle_is_used_again() {
        let mut atlas = Atlas::new(PAGE);
        atlas.add_page(Kind::Mask);
        let slots = fill(&mut atlas, 7);
        let data = image(Kind::Mask, 6, 10, 9);
        assert_eq!(atlas.place(Kind::Mask, 6, 10, &data), None);
        atlas.free(slots[0]);
        let again = atlas
            .place(Kind::Mask, 6, 10, &data)
            .expect("a freed rectangle has room");
        assert_eq!(atlas.read(again), data);
        // The others are as they were.
        for slot in &slots[1..] {
            assert_eq!(atlas.read(*slot), image(Kind::Mask, 6, 10, 7));
        }
    }

    #[test]
    fn a_page_holds_images_of_its_own_kind_alone() {
        let mut atlas = Atlas::new(PAGE);
        atlas.add_page(Kind::Mask);
        let colour = image(Kind::Color, 6, 10, 5);
        assert_eq!(atlas.place(Kind::Color, 6, 10, &colour), None);
        let page = atlas.add_page(Kind::Color);
        let slot = atlas.place(Kind::Color, 6, 10, &colour);
        assert_eq!(slot.map(|slot| slot.page), Some(page));
        // Each page takes its own kind's bytes.
        let pixels = u64::from(PAGE * PAGE);
        assert_eq!(atlas.page_bytes(Kind::Mask), pixels);
        assert_eq!(atlas.page_bytes(Kind::Subpixel), pixels * 4);
        assert_eq!(atlas.bytes(), pixels + pixels * 4);
        let kinds: Vec<(Kind, usize)> = atlas
            .pages()
            .map(|page| (page.kind, page.pixels.len()))
            .collect();
        assert_eq!(
            kinds,
            vec![
                (Kind::Mask, pixels as usize),
                (Kind::Color, pixels as usize * 4)
            ]
        );
    }

    #[test]
    fn a_page_counts_the_images_written_to_it() {
        let mut atlas = Atlas::new(PAGE);
        let page = atlas.add_page(Kind::Mask);
        let written = |atlas: &Atlas| atlas.page(page).map(|page| page.written);
        assert_eq!(written(&atlas), Some(0));
        let data = image(Kind::Mask, 6, 10, 7);
        let first = atlas.place(Kind::Mask, 6, 10, &data).expect("room");
        assert_eq!(written(&atlas), Some(1));
        atlas.place(Kind::Mask, 6, 10, &data);
        assert_eq!(written(&atlas), Some(2));
        // Freeing a rectangle writes nothing; using it again does. A page
        // of another kind counts its own.
        atlas.free(first);
        assert_eq!(written(&atlas), Some(2));
        atlas.place(Kind::Mask, 6, 10, &data);
        assert_eq!(written(&atlas), Some(3));
        let other = atlas.add_page(Kind::Color);
        assert_eq!(atlas.page(other).map(|page| page.written), Some(0));
    }

    #[test]
    fn an_image_larger_than_a_page_fits_none() {
        let mut atlas = Atlas::new(PAGE);
        atlas.add_page(Kind::Mask);
        assert!(atlas.fits(PAGE, PAGE));
        assert!(!atlas.fits(PAGE + 1, 4));
        assert!(!atlas.fits(4, PAGE + 1));
        let wide = image(Kind::Mask, PAGE + 1, 4, 1);
        assert_eq!(atlas.place(Kind::Mask, PAGE + 1, 4, &wide), None);
    }

    #[test]
    fn pages_that_hold_no_image_are_dropped_and_their_bytes_given_back() {
        let mut atlas = Atlas::new(PAGE);
        let first = atlas.add_page(Kind::Mask);
        let slots = fill(&mut atlas, 7);
        let second = atlas.add_page(Kind::Mask);
        let data = image(Kind::Mask, 6, 10, 9);
        let kept = atlas
            .place(Kind::Mask, 6, 10, &data)
            .expect("the second page has room");
        assert_eq!(kept.page, second);
        // Nothing is dropped while each page holds an image.
        assert_eq!(atlas.drop_empty(), 0);
        for slot in slots {
            atlas.free(slot);
        }
        assert_eq!(atlas.drop_empty(), 1);
        assert_eq!(atlas.bytes(), atlas.page_bytes(Kind::Mask));
        assert!(atlas.page(first).is_none());
        // What is on the page that stays is where it was.
        assert_eq!(atlas.read(kept), data);
        // A page added later has a number of its own.
        let third = atlas.add_page(Kind::Mask);
        assert!(third != first && third != second);
    }
}
