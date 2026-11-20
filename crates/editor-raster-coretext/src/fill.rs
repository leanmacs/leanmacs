//! The grey a glyph is drawn in: its luminance bucket's.
//!
//! Core Text's smoothing dilates an outline more for lighter text
//! (`docs/design/text-and-display.md`), so a mask is drawn with the fill
//! the run's colour comes to. Its five buckets
//! (`editor_raster::luminance_bucket`) are drawn in five greys, from black
//! to white, as Zed draws them. The mask is the drawing's alpha whatever
//! the grey.

/// The fill grey of `bucket`, from 0 (black) to 1 (white).
pub fn fill_grey(bucket: u8) -> f64 {
    f64::from(bucket.min(4)) / 4.0
}

#[cfg(test)]
mod tests {
    use super::fill_grey;

    #[test]
    fn each_bucket_is_drawn_in_its_quarter_of_grey() {
        assert_eq!(fill_grey(0), 0.0);
        assert_eq!(fill_grey(2), 0.5);
        assert_eq!(fill_grey(4), 1.0);
    }
}
