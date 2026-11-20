//! The unit twin of `tests/rasterizer.rs`: what a renderer's rasteriser is
//! made of, read through the painter, which is private.

use editor_raster::fake::FakeRasterizer;

use crate::{HeadlessRenderer, Settings, Weight};

#[test]
fn a_headless_renderer_falls_back_to_swash_at_its_settings_dilation() {
    // Two dilations, so that no one dilation put in place of the
    // settings' (none, or Core Text's) passes for both.
    for dilation in [0.3, Weight::CORE_TEXT.dilation] {
        let settings = Settings {
            weight: Weight {
                contrast: 0.0,
                dilation,
            },
            ..Settings::default()
        };
        let renderer = HeadlessRenderer::new(settings);
        assert_eq!(
            renderer.painter.rasterizer().fallback().dilation(),
            dilation
        );
        // And handed a rasteriser, its fallback is still made at it.
        let handed = renderer.rasterizing_with(FakeRasterizer::new());
        assert_eq!(handed.painter.rasterizer().fallback().dilation(), dilation);
    }
}
