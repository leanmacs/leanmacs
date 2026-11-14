//! The `Renderer` port: a frame and a target in, what drawing it cost out.
//!
//! A renderer draws one frame of `editor-layout` on its target, presents
//! it, and answers with plain data ([`Drawn`]). It is one method. What it
//! draws with stays behind it: no type of a drawing library, a GPU or a
//! font rasteriser is named here or by anything above the port.
//!
//! A frame reaches a renderer through the render loop
//! ([`render_loop`](crate::render_loop)), which takes it from a mailbox
//! where a newer frame replaces one not yet drawn. The frame journal and
//! the counters ([`journal`](crate::journal)) are filled by that loop from
//! what [`Renderer::draw`] returns, so every back end reports the same
//! way and none keeps a journal of its own.
//!
//! # Where an addition goes
//!
//! The port grows by data, not by methods.
//!
//! | Addition | Where | Pinned by |
//! |---|---|---|
//! | Something more a draw is given: a setting that may change from one draw to the next | A field of [`DrawRequest`] | The adapter's tests |
//! | Something more a draw says it did | A field of [`Drawn`], and of [`Counters`](crate::journal::Counters) when it is summed | [`journal`](crate::journal)'s tests, and the adapter's |
//! | Something more to draw | Nothing here: it is a field of layout's frame, which a renderer reads | Layout's tests, and the adapter's |
//! | Another reason to draw | A method of [`RenderHandle`](crate::render_loop::RenderHandle) that leaves word, and a field of [`Demands`](crate::schedule::Demands) | [`schedule`](crate::schedule)'s tests and [`render_loop`](crate::render_loop)'s, on the fake |
//! | Which rows are built again | [`rows`](crate::rows), which every back end keeps its rows through | Its own tests |
//! | A rule every renderer keeps | [`contract`](crate::contract) | Its own tests, on a renderer written to break it |
//! | Reading back what was drawn | Not on the port: a method of the adapter that can | The adapter's tests |
//!
//! # The published fake and the contract
//!
//! [`RecordingRenderer`](crate::fake::RecordingRenderer) draws nothing and
//! keeps every request; everything above the port is tested on it.
//! [`contract::check`](crate::contract::check) is the list of rules it and
//! every real adapter are held to. Each real adapter runs the check in its
//! own crate's tests: the adapters are `editor-render-wgpu`'s, one that
//! composites on the CPU and one that draws with wgpu.
//!
//! # Where the loop is run over a real adapter
//!
//! The loop's rules, the scheduler's and the journal's are pinned in this
//! crate, on the fakes. A test that runs the loop, or layout, over a real
//! adapter covers wiring only, and lives in the adapter's crate
//! (`crates/editor-render-wgpu/tests`). It may read this crate's counters
//! and journal ([`RenderHandle::counters`], [`RenderHandle::journal`]) and
//! what [`Renderer::draw`] returned, and compare them: that a frame
//! submitted twice was drawn once, that the rows a draw built are the rows
//! the counters gained, that each presented draw has its entry. It states
//! no decision of the scheduler, no size of the journal and no row, width
//! or hash of layout's.
//!
//! Two of those tests may lay real text out with a real shaper, because a
//! picture of text needs glyphs and only a shaper places them:
//! `tests/reference.rs`, which compares one frame with the reference
//! image, and `tests/reuse.rs`, which moves a cursor over real text. No
//! other test of an adapter runs a real shaper: they draw frames of
//! layout's fake, `CellShaper`, or frames they build by hand from the
//! frame's public data.
//!
//! [`RenderHandle::counters`]: crate::render_loop::RenderHandle::counters
//! [`RenderHandle::journal`]: crate::render_loop::RenderHandle::journal

use std::sync::Arc;

use editor_layout::frame::Frame;

/// What a renderer draws on: a size in physical pixels, and how many of
/// them make one logical pixel.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Target {
    /// Across, in physical pixels.
    pub width: u32,
    /// Down, in physical pixels.
    pub height: u32,
    /// Physical pixels for each logical pixel: 1 on a low-resolution
    /// display, 2 on most high-resolution ones.
    pub scale: f32,
}

/// What a renderer is asked to draw.
#[derive(Debug, Clone, Copy)]
pub struct DrawRequest<'a> {
    /// The frame.
    pub frame: &'a Arc<Frame>,
    /// What to draw it on.
    pub target: Target,
}

/// What a draw did and what it cost, counted and never timed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Drawn {
    /// Whether the frame was presented; `false` when the target could not
    /// be drawn on this time, and the draw is to be tried again. Only a
    /// draw that presented is counted
    /// ([`Counters::count`](crate::journal::Counters::count)), so a
    /// renderer that built rows or glyph images for a draw it then could
    /// not present answers for them in the next draw it presents.
    pub presented: bool,
    /// Whether the frame was not presented because nobody can see the
    /// target: a window that is covered, or not yet on the screen. Such a
    /// draw is tried again when the loop is next told anything, which
    /// being shown is, and not a refresh later
    /// ([`render_loop`](crate::render_loop), "A hidden target"). `false`
    /// for a draw that presented.
    pub hidden: bool,
    /// The rows it built draw data for: those of the frame whose content
    /// hash it did not hold, once for each distinct hash.
    pub rows_rebuilt: u64,
    /// The rows it drew from what it held, once for each distinct hash.
    pub rows_reused: u64,
    /// The glyph images it rasterised.
    pub glyphs_rasterised: u64,
    /// The glyph images it was asked for and already held.
    pub glyphs_reused: u64,
    /// The glyph images it dropped to make room.
    pub glyphs_evicted: u64,
    /// The glyphs it could not draw: of a font with no bytes, or with no
    /// image.
    pub glyphs_skipped: u64,
    /// The bytes its glyph images take up now.
    pub atlas_bytes: u64,
}

/// The port: draws a frame.
pub trait Renderer {
    /// Draws `request.frame` on the renderer's target at `request.target`'s
    /// size and scale, presents it, and says what that cost.
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn;
}
