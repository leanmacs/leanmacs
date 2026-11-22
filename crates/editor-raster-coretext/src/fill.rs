//! The grey a glyph is drawn in: its luminance bucket's.
//!
//! Core Text's smoothing dilates an outline more for lighter text, in five
//! levels of the text's luminance (`editor_raster::SMOOTHING_LEVELS`), so
//! a mask is drawn with a fill in the level the run's colour is in. The
//! five buckets (`editor_raster::luminance_bucket`) are drawn in five
//! greys, black, white, and one well inside each level between. The mask
//! is the drawing's alpha whatever the grey.

/// The fill grey of each bucket.
const GREYS: [f64; 5] = [0.0, 0.5, 0.75, 0.875, 1.0];

/// The fill grey of `bucket`, from 0 (black) to 1 (white); white past the
/// last.
pub fn fill_grey(bucket: u8) -> f64 {
    GREYS[usize::from(bucket).min(GREYS.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::fill_grey;

    #[test]
    fn each_bucket_is_drawn_in_a_grey_inside_its_level() {
        // Black and white, and a grey between each two of Core Text's
        // smoothing levels (0.3886, 0.6460, 0.8124, 0.9428), well inside.
        let greys: Vec<f64> = (0..=4).map(fill_grey).collect();
        assert_eq!(greys, vec![0.0, 0.5, 0.75, 0.875, 1.0]);
        // Past the last bucket, white.
        assert_eq!(fill_grey(9), 1.0);
    }
}
