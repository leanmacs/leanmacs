//! The published fake, held to the contract of the `Renderer` port.

use editor_render::contract;
use editor_render::fake::RecordingRenderer;

#[test]
fn the_recording_renderer_holds_the_renderer_contract() {
    assert_eq!(
        contract::check(RecordingRenderer::new),
        Vec::<&str>::new(),
        "the properties that fail"
    );
}
