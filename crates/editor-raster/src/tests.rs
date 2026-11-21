//! The port's own rules: the luminance bucket, what a bin means, a boxed
//! rasteriser, and the fallback; on the published fake.

use crate::fake::{FakeRasterizer, font};
use crate::{
    Color, Fallback, GlyphKey, GlyphRequest, Rasterize, ResolvedFontId, SUBPIXEL_BINS,
    luminance_bucket,
};

#[test]
fn black_is_the_first_bucket_and_white_the_last() {
    assert_eq!(luminance_bucket(Color::rgb(0, 0, 0)), 0);
    assert_eq!(luminance_bucket(Color::rgb(0xff, 0xff, 0xff)), 4);
}

#[test]
fn a_colour_is_bucketed_by_its_encoded_luminance() {
    // The default theme's text (0.869) and ground (0.202), and mid-grey:
    // mid-grey (0.502) is 1 by its encoded value, where its linear light
    // (0.216) would be 0.
    assert_eq!(luminance_bucket(Color::rgb(0xd8, 0xde, 0xe9)), 3);
    assert_eq!(luminance_bucket(Color::rgb(0x80, 0x80, 0x80)), 1);
    assert_eq!(luminance_bucket(Color::rgb(0x2e, 0x34, 0x40)), 0);
    // Green weighs most and blue least.
    assert!(luminance_bucket(Color::rgb(0, 0xff, 0)) > luminance_bucket(Color::rgb(0, 0, 0xff)));
}

#[test]
fn the_buckets_change_where_core_texts_smoothing_does() {
    // A grey just below and just above each of Core Text's thresholds, in
    // 8-bit steps: 99 and 100 (0.388, 0.392), 164 and 165 (0.643, 0.647),
    // 207 and 208 (0.812, 0.816), 240 and 241 (0.941, 0.945).
    for (below, above, bucket) in [(99, 100, 1), (164, 165, 2), (207, 208, 3), (240, 241, 4)] {
        let grey = |value: u8| luminance_bucket(Color::rgb(value, value, value));
        assert_eq!(grey(below), bucket - 1, "{below}");
        assert_eq!(grey(above), bucket, "{above}");
    }
}

#[test]
fn alpha_does_not_change_the_bucket() {
    for alpha in [0, 0x40, 0x80, 0xff] {
        assert_eq!(luminance_bucket(Color::rgba(0xd8, 0xde, 0xe9, alpha)), 3);
        assert_eq!(luminance_bucket(Color::rgba(0, 0, 0, alpha)), 0);
    }
}

#[test]
fn the_bucket_is_never_above_four() {
    for value in (0..=255).step_by(5) {
        for (red, green, blue) in [
            (value, value, value),
            (value, 0xff, value),
            (0xff, 0xff, value),
        ] {
            assert!(luminance_bucket(Color::rgb(red, green, blue)) <= 4);
        }
    }
}

/// The key of the plain mask of `glyph` of font 0 at `bin`, black.
fn key(glyph: u32, bin: u8) -> GlyphKey {
    GlyphKey {
        font: ResolvedFontId(0),
        glyph,
        bin,
        subpixel: false,
        bucket: 0,
    }
}

#[test]
fn a_bin_is_its_twelfth_of_a_pixel() {
    assert_eq!(SUBPIXEL_BINS, 12);
    let offsets: Vec<f32> = (0..SUBPIXEL_BINS).map(|bin| key(1, bin).offset()).collect();
    let twelfths: Vec<f32> = (0..12_u8).map(|bin| f32::from(bin) / 12.0).collect();
    assert_eq!(offsets, twelfths);
    // Core Text's grids are whole numbers of bins: thirds, halves and
    // whole pixels.
    assert_eq!(key(1, 4).offset(), 1.0 / 3.0);
    assert_eq!(key(1, 6).offset(), 0.5);
    assert_eq!(key(1, 8).offset(), 2.0 / 3.0);
}

#[test]
fn a_boxed_rasteriser_is_the_rasteriser() {
    let font = font(16.0);
    let request = GlyphRequest {
        font: &font,
        key: key(7, 1),
        hint: true,
    };
    let tinted = FakeRasterizer {
        tinted: true,
        ..FakeRasterizer::new()
    };
    let mut boxed: Box<dyn Rasterize> = Box::new(tinted);
    assert!(boxed.by_luminance());
    assert_eq!(
        boxed.rasterize(&request),
        FakeRasterizer::new().image(key(7, 1))
    );
    let plain: Box<dyn Rasterize> = Box::new(FakeRasterizer::new());
    assert!(!plain.by_luminance());
}

/// A fallback of two fakes: the first has no image of `missing`, and the
/// second's images are `size` across and down, so that each one's images
/// are told apart.
fn fallback(missing: &[u32], size: (u32, u32)) -> Fallback<FakeRasterizer, FakeRasterizer> {
    let mut first = FakeRasterizer::new();
    first.missing.extend(missing);
    let second = FakeRasterizer {
        size: Some(size),
        ..FakeRasterizer::new()
    };
    Fallback::new(first, second)
}

#[test]
fn a_fallback_gives_the_first_image_and_does_not_ask_the_second() {
    let font = font(16.0);
    let mut both = fallback(&[], (3, 3));
    let request = GlyphRequest {
        font: &font,
        key: key(7, 0),
        hint: false,
    };
    assert_eq!(
        both.rasterize(&request),
        FakeRasterizer::new().image(key(7, 0))
    );
    assert_eq!(both.first().asked, vec![(key(7, 0), 16.0, false)]);
    assert!(both.fallback().asked.is_empty());
}

#[test]
fn a_fallback_asks_the_second_for_what_the_first_declines() {
    let font = font(16.0);
    let mut both = fallback(&[9], (3, 3));
    let request = GlyphRequest {
        font: &font,
        key: key(9, 2),
        hint: true,
    };
    let made = both.rasterize(&request).expect("the second's image");
    assert_eq!(Some(made), both.fallback().image(key(9, 2)));
    assert_eq!(both.first().asked.len(), 1);
    assert_eq!(both.fallback().asked, vec![(key(9, 2), 16.0, true)]);
}

#[test]
fn a_fallback_reads_luminance_as_its_first_does() {
    let tinted = FakeRasterizer {
        tinted: true,
        ..FakeRasterizer::new()
    };
    assert!(Fallback::new(tinted, FakeRasterizer::new()).by_luminance());
    let tinted = FakeRasterizer {
        tinted: true,
        ..FakeRasterizer::new()
    };
    assert!(!Fallback::new(FakeRasterizer::new(), tinted).by_luminance());
}

#[test]
fn a_glyph_both_decline_has_no_image() {
    let font = font(16.0);
    let mut first = FakeRasterizer::new();
    first.missing.insert(9);
    let mut second = FakeRasterizer::new();
    second.missing.insert(9);
    let mut both = Fallback::new(first, second);
    let request = GlyphRequest {
        font: &font,
        key: key(9, 0),
        hint: true,
    };
    assert_eq!(both.rasterize(&request), None);
}
