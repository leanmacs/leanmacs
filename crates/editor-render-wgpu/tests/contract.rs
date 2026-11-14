//! The headless adapter, held to the contract of the `Renderer` port.
//!
//! The contract's frames are of layout's fake shaper, whose fonts have no
//! bytes: the adapter builds their rows and draws no glyph of them, which
//! is all the contract asks about.

use editor_render::contract;
use editor_render_wgpu::{HeadlessRenderer, Settings};

#[test]
fn the_headless_adapter_holds_the_renderer_contract() {
    assert_eq!(
        contract::check(|| HeadlessRenderer::new(Settings::default())),
        Vec::<&str>::new(),
        "the properties that fail"
    );
}
