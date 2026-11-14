//! Quads: everything a frame comes to, as rectangles of whole pixels.
//!
//! A [`Quad`] is a rectangle on the target that is either filled with one
//! colour or takes its coverage or its colour from a rectangle of the same
//! size in a page of the glyph atlas. It is plain data: the painter makes
//! the list, and whatever draws it, on the CPU or on a GPU, blends each
//! quad over what is already there, in the list's order.
//!
//! Positions are whole pixels. An area of a frame, which is in fractions
//! of a pixel, is rounded edge by edge ([`Quad::over`]), so two areas that
//! share an edge share it after rounding too, with no gap and no overlap.

use editor_layout::face::Color;

/// What a quad takes its pixels from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum QuadKind {
    /// Its colour, everywhere.
    Fill,
    /// Its colour, through a coverage read from a mask page: one byte a
    /// pixel.
    Mask,
    /// Its colour, through a coverage for each of red, green and blue
    /// read from a subpixel page.
    Subpixel,
    /// The colours of a colour page; its own colour is not used.
    Color,
}

/// One rectangle to draw.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Quad {
    /// Its left edge on the target, in pixels.
    pub x: i32,
    /// Its top edge.
    pub y: i32,
    /// How far across it is.
    pub width: u32,
    /// How far down.
    pub height: u32,
    /// What it takes its pixels from.
    pub kind: QuadKind,
    /// Its colour.
    pub color: Color,
    /// The atlas page it reads; 0 for a fill.
    pub page: u32,
    /// The left edge, in the page, of the rectangle it reads.
    pub u: u32,
    /// The top edge of that rectangle.
    pub v: u32,
}

/// A rectangle of the target that drawing is kept to: from `x0` and `y0`
/// up to and not including `x1` and `y1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Clip {
    /// The left edge.
    pub x0: i32,
    /// The top edge.
    pub y0: i32,
    /// One past the right edge.
    pub x1: i32,
    /// One past the bottom edge.
    pub y1: i32,
}

/// `value` rounded to a whole pixel.
pub fn pixel(value: f32) -> i32 {
    value.round() as i32
}

impl Clip {
    /// The rectangle at `x` and `y`, `width` across and `height` down.
    pub fn of(x: i32, y: i32, width: u32, height: u32) -> Self {
        Self {
            x0: x,
            y0: y,
            x1: x.saturating_add_unsigned(width),
            y1: y.saturating_add_unsigned(height),
        }
    }

    /// What this rectangle and `other` both hold.
    #[must_use]
    pub fn and(self, other: Self) -> Self {
        Self {
            x0: self.x0.max(other.x0),
            y0: self.y0.max(other.y0),
            x1: self.x1.min(other.x1),
            y1: self.y1.min(other.y1),
        }
    }
}

impl Quad {
    /// A fill of `color` at `x` and `y`, `width` across and `height` down.
    pub fn fill(x: i32, y: i32, width: u32, height: u32, color: Color) -> Self {
        Self {
            x,
            y,
            width,
            height,
            kind: QuadKind::Fill,
            color,
            page: 0,
            u: 0,
            v: 0,
        }
    }

    /// A fill of `color` over an area in fractions of a pixel: each of its
    /// four edges is rounded to a whole pixel.
    pub fn over(x: f32, y: f32, width: f32, height: f32, color: Color) -> Self {
        let (left, top) = (pixel(x), pixel(y));
        let (right, bottom) = (pixel(x + width), pixel(y + height));
        Self::fill(
            left,
            top,
            (right - left).max(0) as u32,
            (bottom - top).max(0) as u32,
            color,
        )
    }

    /// This quad, `dx` pixels to the right and `dy` down.
    #[must_use]
    pub fn moved(self, dx: i32, dy: i32) -> Self {
        Self {
            x: self.x + dx,
            y: self.y + dy,
            ..self
        }
    }

    /// The part of this quad inside `clip`, reading the part of its atlas
    /// rectangle that goes with it; `None` when no pixel of it is inside.
    #[must_use]
    pub fn clipped(self, clip: Clip) -> Option<Self> {
        let own = Clip::of(self.x, self.y, self.width, self.height);
        let kept = own.and(clip);
        if kept.x1 <= kept.x0 || kept.y1 <= kept.y0 {
            return None;
        }
        // How far in from this quad's left and top edges the part kept
        // begins: the atlas rectangle begins as far in.
        let (cut_x, cut_y) = ((kept.x0 - self.x) as u32, (kept.y0 - self.y) as u32);
        Some(Self {
            x: kept.x0,
            y: kept.y0,
            width: (kept.x1 - kept.x0) as u32,
            height: (kept.y1 - kept.y0) as u32,
            u: self.u + cut_x,
            v: self.v + cut_y,
            ..self
        })
    }
}

#[cfg(test)]
mod tests {
    use editor_layout::face::Color;

    use super::{Clip, Quad, QuadKind, pixel};

    /// A colour for the tests.
    const RED: Color = Color::rgb(0xff, 0, 0);

    /// A glyph quad at `x` and `y`, 10 by 8, reading the page 3 at 100
    /// and 200.
    fn glyph(x: i32, y: i32) -> Quad {
        Quad {
            x,
            y,
            width: 10,
            height: 8,
            kind: QuadKind::Mask,
            color: RED,
            page: 3,
            u: 100,
            v: 200,
        }
    }

    #[test]
    fn a_value_is_rounded_to_the_nearest_pixel() {
        assert_eq!(
            [pixel(0.0), pixel(0.4), pixel(0.5), pixel(1.6), pixel(-0.4)],
            [0, 0, 1, 2, 0]
        );
    }

    #[test]
    fn an_area_is_rounded_edge_by_edge() {
        // From 10.4 to 20.6 across, and from 0.5 to 16.5 down.
        let quad = Quad::over(10.4, 0.5, 10.2, 16.0, RED);
        assert_eq!(quad, Quad::fill(10, 1, 11, 16, RED));
        // Two areas that share an edge share it after rounding: the first
        // ends where the second begins.
        let left = Quad::over(0.0, 0.0, 10.6, 4.0, RED);
        let right = Quad::over(10.6, 0.0, 9.4, 4.0, RED);
        assert_eq!(left.x + left.width as i32, right.x);
        assert_eq!(right.x + right.width as i32, 20);
        // An area narrower than half a pixel between two pixel edges is
        // nothing.
        assert_eq!(Quad::over(3.6, 0.0, 0.3, 4.0, RED).width, 0);
    }

    #[test]
    fn a_moved_quad_reads_the_same_atlas_rectangle() {
        let moved = glyph(5, 6).moved(100, -2);
        assert_eq!(moved, glyph(105, 4));
    }

    #[test]
    fn two_clips_hold_what_both_hold() {
        let both = Clip::of(0, 0, 100, 50).and(Clip::of(40, 10, 100, 100));
        assert_eq!(both, Clip::of(40, 10, 60, 40));
        // Two that share nothing hold nothing, of whatever size.
        let none = Clip::of(0, 0, 10, 10).and(Clip::of(20, 20, 5, 5));
        assert_eq!(glyph(0, 0).clipped(none), None);
        assert_eq!(glyph(20, 20).clipped(none), None);
    }

    #[test]
    fn a_quad_inside_the_clip_is_left_as_it_is() {
        let clip = Clip::of(0, 0, 100, 100);
        assert_eq!(glyph(5, 6).clipped(clip), Some(glyph(5, 6)));
        assert_eq!(glyph(90, 92).clipped(clip), Some(glyph(90, 92)));
    }

    #[test]
    fn a_quad_across_the_clips_edge_keeps_the_part_inside_and_its_part_of_the_atlas() {
        let clip = Clip::of(10, 10, 20, 20);
        // Three columns and two rows of it are left of and above the clip.
        let cut = glyph(7, 8).clipped(clip);
        assert_eq!(
            cut,
            Some(Quad {
                x: 10,
                y: 10,
                width: 7,
                height: 6,
                u: 103,
                v: 202,
                ..glyph(7, 8)
            })
        );
        // Across the right and the bottom edges nothing of the atlas
        // moves: only the size shrinks.
        let cut = glyph(25, 26).clipped(clip);
        assert_eq!(
            cut,
            Some(Quad {
                width: 5,
                height: 4,
                ..glyph(25, 26)
            })
        );
    }

    #[test]
    fn a_quad_outside_the_clip_is_nothing() {
        let clip = Clip::of(10, 10, 20, 20);
        for (x, y) in [(0, 12), (30, 12), (12, 2), (12, 30), (-50, -50)] {
            assert_eq!(glyph(x, y).clipped(clip), None, "at {x}, {y}");
        }
        // And a quad of no size is nothing wherever it is.
        assert_eq!(Quad::fill(15, 15, 0, 5, RED).clipped(clip), None);
    }
}
