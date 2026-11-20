//! Where a glyph's bitmap goes: its pixels around the glyph's bounds, and
//! where the pen is in it.
//!
//! Core Text gives a glyph's bounds as a rectangle in pixels from the pen,
//! y up (`CTFontGetBoundingRectsForGlyphs`). Its smoothing moves each edge
//! out by up to 0.3 pixels and a bin moves the glyph right by up to three
//! quarters of one, so the bitmap is the rectangle on whole pixels,
//! expanded by a pixel on each side, and by a column more on the right
//! when the glyph is drawn past a whole pixel.

/// A glyph's bitmap.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Frame {
    /// How far right of the glyph's whole-pixel place its left edge is.
    pub left: i32,
    /// How far above the baseline its top edge is.
    pub top: i32,
    /// How far across it is, in pixels.
    pub width: u32,
    /// How far down.
    pub height: u32,
    /// Where the pen goes, in pixels from the bitmap's bottom left, y up:
    /// what the glyph is drawn at.
    pub origin: (f64, f64),
}

impl Frame {
    /// The bitmap of a glyph whose bounds are `rect` (its least x and y
    /// and its greatest, in pixels from the pen, y up), drawn `offset`
    /// pixels right of a whole pixel. A rectangle with no area, a space's,
    /// is a bitmap of no size.
    pub fn of(rect: [f64; 4], offset: f64) -> Frame {
        let [min_x, min_y, max_x, max_y] = rect;
        if max_x <= min_x || max_y <= min_y || rect.iter().any(|edge| !edge.is_finite()) {
            return Frame {
                left: 0,
                top: 0,
                width: 0,
                height: 0,
                origin: (0.0, 0.0),
            };
        }
        let left = min_x.floor() as i32 - 1;
        let right = max_x.ceil() as i32 + 1 + i32::from(offset > 0.0);
        let bottom = min_y.floor() as i32 - 1;
        let top = max_y.ceil() as i32 + 1;
        Frame {
            left,
            top,
            width: (right - left) as u32,
            height: (top - bottom) as u32,
            origin: (f64::from(-left) + offset, f64::from(-bottom)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Frame;

    /// An `H`: upright, from 1.5 to 9.5 across and 20 up.
    const H: [f64; 4] = [1.5, 0.0, 9.5, 20.0];

    #[test]
    fn a_glyph_is_on_whole_pixels_a_pixel_out_on_each_side() {
        assert_eq!(
            Frame::of(H, 0.0),
            Frame {
                left: 0,
                top: 21,
                width: 11,
                height: 22,
                origin: (0.0, 1.0),
            }
        );
    }

    #[test]
    fn a_rectangle_with_no_area_is_a_bitmap_of_no_size() {
        for rect in [
            [0.0, 0.0, 0.0, 0.0],
            [3.0, 1.0, 3.0, 5.0],
            [f64::INFINITY, f64::INFINITY, 0.0, 0.0],
        ] {
            let frame = Frame::of(rect, 0.5);
            assert_eq!((frame.width, frame.height), (0, 0), "{rect:?}");
        }
    }

    #[test]
    fn a_negative_left_bearing_moves_the_left_edge_left_of_the_pen() {
        let frame = Frame::of([-2.3, -4.2, 6.0, 12.5], 0.0);
        assert_eq!((frame.left, frame.top), (-4, 14));
        assert_eq!((frame.width, frame.height), (11, 20));
        assert_eq!(frame.origin, (4.0, 6.0));
    }

    #[test]
    fn a_glyph_past_a_whole_pixel_is_one_column_wider_and_its_pen_moves_with_it() {
        let at = Frame::of(H, 0.0);
        for offset in [0.25, 0.5, 0.75] {
            let moved = Frame::of(H, offset);
            assert_eq!(moved.width, at.width + 1, "{offset}");
            assert_eq!(
                (moved.left, moved.top, moved.height),
                (at.left, at.top, at.height)
            );
            assert_eq!(moved.origin, (at.origin.0 + offset, at.origin.1));
        }
    }

    #[test]
    fn the_pen_and_the_dilated_glyph_stay_inside_the_bitmap() {
        for rect in [H, [-2.3, -4.2, 6.0, 12.5], [0.1, 0.1, 0.2, 0.2]] {
            for offset in [0.0, 0.25, 0.5, 0.75] {
                let frame = Frame::of(rect, offset);
                let (x, y) = frame.origin;
                let (width, height) = (f64::from(frame.width), f64::from(frame.height));
                assert!((0.0..=width).contains(&x) && (0.0..=height).contains(&y));
                // The glyph's bounds, moved out 0.3 pixels on each side,
                // are inside the bitmap.
                let [min_x, min_y, max_x, max_y] = rect;
                assert!(
                    x + min_x - 0.3 >= 0.0 && x + max_x + 0.3 <= width,
                    "{rect:?} {offset}"
                );
                assert!(
                    y + min_y - 0.3 >= 0.0 && y + max_y + 0.3 <= height,
                    "{rect:?} {offset}"
                );
            }
        }
    }
}
