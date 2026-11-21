//! The CPU compositor: the painter's quads laid over a pixel buffer.
//!
//! It is the device of the headless adapter, and it is all of it: clear
//! the buffer, then for each quad in order, for each of its pixels that
//! is on the target, lay the quad's pixel over the one there
//! ([`blend`](crate::blend)). A glyph quad reads its coverage or its
//! colour from the atlas page it names, at the pixel of its atlas
//! rectangle that goes with the target's pixel. Nothing is filtered or
//! scaled: a quad and its atlas rectangle are the same size in whole
//! pixels.
//!
//! It needs no GPU, no thread and no clock, and gives the same bytes for
//! the same quads wherever it runs, which is what lets one reference
//! image be compared in the gate on any machine.

use crate::atlas::Atlas;
use crate::blend::{blend, source_with};
use crate::glyphs::Kind;
use crate::quads::{Clip, Quad, QuadKind};
use crate::{Blending, Image};

/// What the target is cleared to before a frame is drawn: opaque black.
pub const CLEAR: [u8; 4] = [0, 0, 0, 255];

/// An image `width` across and `height` down, every pixel [`CLEAR`].
pub fn cleared(width: u32, height: u32) -> Image {
    let pixels = width as usize * height as usize;
    Image {
        width,
        height,
        rgba: CLEAR.repeat(pixels),
    }
}

/// Lays `quads` over `image`, in order, reading glyph quads from `atlas`,
/// with the coverage of dark text raised by `contrast` (`Weight::contrast`).
pub fn composite(image: &mut Image, quads: &[Quad], atlas: &Atlas, contrast: f32) {
    let whole = Clip::of(0, 0, image.width, image.height);
    for quad in quads {
        let Some(shown) = quad.clipped(whole) else {
            continue;
        };
        // The page the quad reads, with how many bytes a pixel of it
        // takes; a fill reads none.
        let page = match shown.kind {
            QuadKind::Fill => None,
            QuadKind::Mask => Some(Kind::Mask),
            QuadKind::Subpixel => Some(Kind::Subpixel),
            QuadKind::Color => Some(Kind::Color),
        };
        let page = match page {
            None => None,
            Some(kind) => {
                // A quad that names no page, a page of another kind, or
                // a rectangle past the page's edge draws nothing.
                let Some(page) = atlas.page(shown.page).filter(|page| page.kind == kind) else {
                    continue;
                };
                if shown.u + shown.width > page.size || shown.v + shown.height > page.size {
                    continue;
                }
                Some(page)
            }
        };
        for down in 0..shown.height {
            for across in 0..shown.width {
                let texel = page.map_or([0; 4], |page| {
                    let bytes = page.kind.bytes() as usize;
                    let (u, v) = ((shown.u + across) as usize, (shown.v + down) as usize);
                    let start = (v * page.size as usize + u) * bytes;
                    let mut texel = [0; 4];
                    texel[..bytes].copy_from_slice(&page.pixels[start..start + bytes]);
                    texel
                });
                // Inside the target: the quad was clipped to it.
                let (x, y) = (
                    shown.x as usize + across as usize,
                    shown.y as usize + down as usize,
                );
                let start = (y * image.width as usize + x) * 4;
                let Some(under) = image.rgba.get_mut(start..start + 4) else {
                    continue;
                };
                let over = blend(
                    [under[0], under[1], under[2], under[3]],
                    &source_with(shown.kind, shown.color, texel, contrast, Blending::Linear),
                    Blending::Linear,
                );
                under.copy_from_slice(&over);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use editor_layout::face::Color;

    use super::{CLEAR, cleared, composite};
    use crate::Image;
    use crate::atlas::{Atlas, Slot};
    use crate::blend::CONTRAST;
    use crate::glyphs::Kind;
    use crate::quads::{Quad, QuadKind};

    const WHITE: Color = Color::rgb(0xff, 0xff, 0xff);
    const BLACK: Color = Color::rgb(0, 0, 0);
    const RED: Color = Color::rgb(0xff, 0, 0);

    /// An atlas with no page: for quads that only fill.
    fn no_pages() -> Atlas {
        Atlas::new(16)
    }

    /// Puts an image of `kind`, `width` by `height`, in a page of its own
    /// of `atlas`.
    fn put(atlas: &mut Atlas, kind: Kind, width: u32, height: u32, data: &[u8]) -> Slot {
        atlas.add_page(kind);
        atlas
            .place(kind, width, height, data)
            .expect("an empty page has room")
    }

    /// The quad that draws the image at `slot` at `x` and `y`, as `kind`,
    /// in `color`.
    fn glyph(slot: Slot, kind: QuadKind, x: i32, y: i32, color: Color) -> Quad {
        Quad {
            x,
            y,
            width: slot.width,
            height: slot.height,
            kind,
            color,
            page: slot.page,
            u: slot.x,
            v: slot.y,
        }
    }

    /// The pixel of `image` at `x` and `y`.
    fn at(image: &Image, x: u32, y: u32) -> [u8; 4] {
        image.pixel(x, y).expect("a pixel of the image")
    }

    #[test]
    fn a_cleared_image_is_opaque_black() {
        let image = cleared(3, 2);
        assert_eq!((image.width, image.height), (3, 2));
        assert_eq!(image.rgba, [0, 0, 0, 255].repeat(6));
        assert_eq!(at(&image, 2, 1), CLEAR);
        // Outside it there is no pixel.
        assert_eq!(image.pixel(3, 0), None);
        assert_eq!(image.pixel(0, 2), None);
    }

    #[test]
    fn a_rectangle_fills_its_pixels_and_no_other() {
        let mut image = cleared(8, 6);
        composite(
            &mut image,
            &[Quad::fill(2, 1, 3, 2, RED)],
            &no_pages(),
            CONTRAST,
        );
        for y in 0..6 {
            for x in 0..8 {
                let inside = (2..5).contains(&x) && (1..3).contains(&y);
                let expected = if inside { [255, 0, 0, 255] } else { CLEAR };
                assert_eq!(at(&image, x, y), expected, "at {x}, {y}");
            }
        }
    }

    #[test]
    fn a_mask_a_subpixel_and_a_colour_quad_each_blend_by_its_rule() {
        let mut atlas = no_pages();
        // A mask of two pixels, covered wholly and by half; a subpixel
        // mask of one, its red stripe covered wholly, its green by half
        // and its blue not at all; a colour image of one, red at half
        // alpha.
        let mask = put(&mut atlas, Kind::Mask, 2, 1, &[255, 128]);
        let subpixel = put(&mut atlas, Kind::Subpixel, 1, 1, &[255, 128, 0, 0]);
        let colour = put(&mut atlas, Kind::Color, 1, 1, &[128, 0, 0, 128]);
        let mut image = cleared(8, 3);
        let quads = [
            glyph(mask, QuadKind::Mask, 1, 0, WHITE),
            glyph(subpixel, QuadKind::Subpixel, 1, 1, WHITE),
            glyph(colour, QuadKind::Color, 1, 2, WHITE),
        ];
        composite(&mut image, &quads, &atlas, CONTRAST);
        assert_eq!(at(&image, 1, 0), [255, 255, 255, 255]);
        assert_eq!(at(&image, 2, 0), [188, 188, 188, 255]);
        assert_eq!(at(&image, 1, 1), [255, 188, 0, 255]);
        assert_eq!(at(&image, 1, 2), [188, 0, 0, 255]);
        // And nothing else was touched.
        let touched = image
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .filter(|pixel| **pixel != CLEAR)
            .count();
        assert_eq!(touched, 4);
    }

    #[test]
    fn text_is_blended_over_what_is_under_it() {
        // The left half of the target white and the right half red, and a
        // glyph of black text at half coverage across the two.
        let mut atlas = no_pages();
        let mask = put(&mut atlas, Kind::Mask, 2, 1, &[128, 128]);
        let mut image = cleared(4, 1);
        let quads = [
            Quad::fill(0, 0, 2, 1, WHITE),
            Quad::fill(2, 0, 2, 1, RED),
            glyph(mask, QuadKind::Mask, 1, 0, BLACK),
        ];
        composite(&mut image, &quads, &atlas, CONTRAST);
        // Each pixel of the glyph is the blend with its own background.
        assert_eq!(at(&image, 1, 0), [187, 187, 187, 255]);
        assert_eq!(at(&image, 2, 0), [187, 0, 0, 255]);
        assert_eq!(at(&image, 0, 0), [255, 255, 255, 255]);
        assert_eq!(at(&image, 3, 0), [255, 0, 0, 255]);
    }

    #[test]
    fn quads_are_laid_over_each_other_in_order() {
        let mut image = cleared(3, 1);
        let quads = [Quad::fill(0, 0, 2, 1, RED), Quad::fill(1, 0, 2, 1, WHITE)];
        composite(&mut image, &quads, &no_pages(), CONTRAST);
        assert_eq!(at(&image, 0, 0), [255, 0, 0, 255]);
        assert_eq!(at(&image, 1, 0), [255, 255, 255, 255]);
        assert_eq!(at(&image, 2, 0), [255, 255, 255, 255]);
    }

    #[test]
    fn quads_are_clipped_to_the_target() {
        // A fill that reaches past every edge covers the target and
        // nothing breaks.
        let mut image = cleared(4, 3);
        composite(
            &mut image,
            &[Quad::fill(-5, -5, 100, 100, RED)],
            &no_pages(),
            CONTRAST,
        );
        assert_eq!(image.rgba, [255, 0, 0, 255].repeat(12));
        // A glyph two pixels left of the target shows its right part: the
        // pixels of its atlas rectangle that go with the pixels shown.
        let mut atlas = no_pages();
        let mask = put(&mut atlas, Kind::Mask, 4, 1, &[10, 20, 255, 128]);
        let mut image = cleared(4, 1);
        composite(
            &mut image,
            &[glyph(mask, QuadKind::Mask, -2, 0, WHITE)],
            &atlas,
            CONTRAST,
        );
        assert_eq!(at(&image, 0, 0), [255, 255, 255, 255]);
        assert_eq!(at(&image, 1, 0), [188, 188, 188, 255]);
        assert_eq!(at(&image, 2, 0), CLEAR);
        // One wholly outside draws nothing.
        let mut image = cleared(4, 1);
        composite(
            &mut image,
            &[glyph(mask, QuadKind::Mask, 4, 0, WHITE)],
            &atlas,
            CONTRAST,
        );
        assert_eq!(image.rgba, CLEAR.repeat(4));
    }

    #[test]
    fn a_quad_that_reads_a_page_that_is_not_there_draws_nothing() {
        let mut atlas = no_pages();
        let mask = put(&mut atlas, Kind::Mask, 2, 1, &[255, 255]);
        let mut image = cleared(4, 1);
        // No such page.
        let stray = Quad {
            page: mask.page + 7,
            ..glyph(mask, QuadKind::Mask, 0, 0, WHITE)
        };
        // A page of another kind than the quad's.
        let wrong = glyph(mask, QuadKind::Subpixel, 0, 0, WHITE);
        // A rectangle that reaches past the page's edge.
        let past = Quad {
            u: 15,
            ..glyph(mask, QuadKind::Mask, 0, 0, WHITE)
        };
        composite(&mut image, &[stray, wrong, past], &atlas, CONTRAST);
        assert_eq!(image.rgba, CLEAR.repeat(4));
    }

    #[test]
    fn a_contrast_darkens_black_text_on_white() {
        let mut atlas = no_pages();
        let mask = put(&mut atlas, Kind::Mask, 1, 1, &[128]);
        let at_contrast = |contrast: f32| {
            let mut image = cleared(1, 1);
            let quads = [
                Quad::fill(0, 0, 1, 1, WHITE),
                glyph(mask, QuadKind::Mask, 0, 0, BLACK),
            ];
            composite(&mut image, &quads, &atlas, contrast);
            at(&image, 0, 0)
        };
        assert_eq!(at_contrast(0.0), [187, 187, 187, 255]);
        assert!(at_contrast(1.0)[0] < at_contrast(0.0)[0]);
    }
}
