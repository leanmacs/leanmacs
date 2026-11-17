//! The display: layout behind a handle, which Lean publishes scenes to and
//! asks the layout queries of.
//!
//! A [`Display`] holds an [`editor_layout::Layout`] behind a private trait,
//! so one handle serves either shaper:
//!
//! - the published fake shaper, [`CellShaper`], whose every glyph has one
//!   size: what the display interface's contract is run at
//!   (`lean/Editor/Display/Contract.lean`), what the headless editor lays
//!   out with, and what the gate draws; made by
//!   [`editor_ffi_display_new_cells`];
//! - the real shaper over the fonts of this machine, for Lean's window
//!   mode; made by [`editor_ffi_display_new_system`], which no test calls;
//! - the real shaper over one font file it is given, the default family of
//!   a set with no font of the machine, for tests ([`Display::font`]; made
//!   by [`editor_ffi_display_new_font`]): what Lean's `ffi-test` lays the
//!   shipped themes' pictures out with, so they are the same on every
//!   machine.
//!
//! Each is counted live and freed by [`editor_ffi_display_free`].
//!
//! **A picture** of the latest frame ([`Display::picture`],
//! [`editor_ffi_display_picture`]) is the frame drawn by the CPU renderer,
//! synchronously, with no render session, no thread and no clock: how a
//! theme written in Lean reaches the renderer in a test. It crosses as a
//! [`RawPicture`], and a picture is read from and written to a PNG file
//! by [`editor_ffi_picture_from_png`] and [`editor_ffi_picture_to_png`],
//! which forward to the renderer's crate ([`Image::from_png`],
//! [`Image::to_png`]). All three are for tests.
//!
//! **The scale.** A display lays out at the scale it was last told
//! ([`Display::set_scale`], which is [`Layout::set_scale`]), and at 1
//! until it is told one. Every frame, every query and every heights answer
//! is at it.
//!
//! **The heights** of a text row, a window's status row and the frame's
//! bottom row ([`editor_ffi_display_heights`]) are layout's
//! ([`Layout::heights`]): Lean sizes its views and the minibuffer's place
//! by them, so that a view's rows asked at its height less its bottom row
//! are the rows the frame shows. They are in the faces layout has, so
//! faces Lean is about to publish are defined first, with no frame laid
//! out ([`editor_ffi_display_define`], which is [`Layout::define`]): the
//! heights and the queries Lean sizes a scene by are then in the faces
//! that scene's frame is laid out in.
//!
//! **A text crosses as a snapshot handle.** Each query names the snapshot it
//! is about by its handle, and layout keeps what it laid out per key of the
//! text ([`crate::snapshot`]): a document's snapshots share their
//! document's key, and layout pulls the document's patches through the
//! snapshot's source, which is its changes port
//! ([`Source`](crate::snapshot::Source)), to move what it kept. A snapshot
//! with no source is never moved, only laid out again.
//!
//! **The queries** answer in words ([`crate::log::RawWords`]), with a status
//! ([`DisplayStatus`]):
//!
//! - the rows a view shows ([`editor_ffi_display_rows`]): their count, and
//!   a start and a stop for each;
//! - where a move goes ([`editor_ffi_display_move`]): the position, and the
//!   goal to pass to the next move, in whole pixels.
//!
//! Each question carries the view's padding in whole points (across, down
//! and top for the rows, across for a move), because it is the view's and
//! not the display's: the scale is one for the display and set by the
//! presenter, while a window and the minibuffer's view are padded
//! differently. Layout takes the points off at the scale the display lays
//! out at, by the rule its frames take them off by ([`Layout::rows_shown`],
//! `editor_layout::frame`, "The padding"), so no scale crosses.
//!
//! **A scene is published** as words, one string and the list of snapshot
//! handles its views show ([`editor_ffi_display_publish`]; the layout is
//! [`WireScene`]'s). The definitions of the faces it names are in the same
//! words and string when the binding has new ones, and absent otherwise,
//! which keeps the ones last published. The display resolves it (each
//! view's snapshot by its index; its scroll and selection markers by their
//! numbers, in the document of that snapshot as it is now, each on its
//! own), lays it out in those faces with the same layout the queries use,
//! and keeps its frame as the latest: an `Arc<Frame>` behind a lock of its
//! own, which a reader on any thread clones without waiting for layout
//! ([`Display::latest`]). Words that spell no scene, or no face, change
//! nothing: the frame, the scene and the faces published before stay. The
//! scene is kept as it crossed, and comes back as the same words and string
//! ([`editor_ffi_display_scene`]); the latest frame comes back as text
//! ([`editor_ffi_display_frame_text`]) and as each view's rows
//! ([`editor_ffi_display_frame_rows`]), for tests.
//!
//! Pixels cross as whole numbers, as Lean's are; a goal x is passed back
//! rounded down. What the answers are is layout's rule, pinned by
//! `editor-layout`'s tests; this module converts and forwards.
//!
//! One lock is held for a call. Lean calls the display from the editor
//! thread only, so it is never contended there; it is a lock because a
//! handle is `Send + Sync` with `&self` methods (the crate's conventions).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use editor_layout::Layout;
use editor_layout::face::FaceDef;
use editor_layout::frame::{Frame, Heights};
use editor_layout::query::{Moved, QueryError, RowRange};
use editor_layout::scene::{Changes, Padding, Scene, TextKey, TextRef};
use editor_layout::shaper::Shaper;
use editor_layout::shaper::fake::CellShaper;
use editor_render::port::{DrawRequest, Renderer, Target};
use editor_render_wgpu::{Antialiasing, HeadlessRenderer, Image, Settings};
use editor_shape_parley::{FontSet, ParleyShaper};
use editor_text::{Patch, Revision};

use crate::document::RawText;
use crate::log::RawWords;
use crate::render::{PRESENTER, Presenter};
use crate::snapshot::{Snapshot, Source};
use crate::syntax::syntaxes;
use crate::text;
use crate::words::Writer;

mod wire;

pub use wire::{WireFace, WireField, WireScene, WireView, decode_definitions, encode_definitions};

/// How a display call ended, as it crosses the boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DisplayStatus {
    /// Answered.
    Done = 0,
    /// Refused: an offset is not a position of the text.
    BadPosition = 1,
}

/// A snapshot's source is the [`Changes`] of its text: what its document's
/// log says changed ([`Source::changes_since`]).
impl Changes for Source {
    fn since(&self, revision: Revision) -> Option<Patch> {
        self.changes_since(revision)
    }
}

/// The text a snapshot handle stands for, as layout takes it: its key, its
/// text, its document's changes, and, when its document is attached to the
/// syntax service, its highlights as its own spans
/// ([`crate::syntax::Syntaxes::spans`]). A scene's views and the rows and
/// move queries all make their text here, so a frame and a query of one
/// snapshot see the same spans.
pub fn text_ref(snapshot: &Snapshot) -> TextRef {
    let text = TextRef::fixed(TextKey(snapshot.key()), snapshot.text().clone())
        .with_changes(Arc::new(snapshot.source().clone()));
    match syntaxes().spans(snapshot.key()) {
        Some(spans) => text.with_spans(spans),
        None => text,
    }
}

/// What a display asks of its layout, whatever shaper it measures with:
/// [`Layout`] over any shaper, so that one handle serves the fake shaper
/// and the real one.
trait Lays: Send {
    /// [`Layout::frame`].
    fn frame(&mut self, scene: &Scene) -> Frame;
    /// [`Layout::rows_shown`].
    fn rows_shown(
        &mut self,
        text: &TextRef,
        width: f32,
        height: f32,
        padding: Padding,
        anchor: usize,
    ) -> Result<Vec<RowRange>, QueryError>;
    /// [`Layout::lines_from`].
    fn lines_from(
        &mut self,
        text: &TextRef,
        width: f32,
        across: u32,
        position: usize,
        lines: i64,
        goal: Option<f32>,
    ) -> Result<Moved, QueryError>;
    /// [`Layout::heights`].
    fn heights(&mut self) -> Heights;
    /// [`Layout::define`].
    fn define(&mut self, definitions: &[FaceDef]);
    /// [`Layout::set_scale`].
    fn set_scale(&mut self, scale: f32);
    /// [`Layout::scale`].
    fn scale(&self) -> f32;
}

impl<S: Shaper> Lays for Layout<S>
where
    Layout<S>: Send,
{
    fn frame(&mut self, scene: &Scene) -> Frame {
        Layout::frame(self, scene)
    }

    fn rows_shown(
        &mut self,
        text: &TextRef,
        width: f32,
        height: f32,
        padding: Padding,
        anchor: usize,
    ) -> Result<Vec<RowRange>, QueryError> {
        Layout::rows_shown(self, text, width, height, padding, anchor)
    }

    fn lines_from(
        &mut self,
        text: &TextRef,
        width: f32,
        across: u32,
        position: usize,
        lines: i64,
        goal: Option<f32>,
    ) -> Result<Moved, QueryError> {
        Layout::lines_from(self, text, width, across, position, lines, goal)
    }

    fn heights(&mut self) -> Heights {
        Layout::heights(self)
    }

    fn define(&mut self, definitions: &[FaceDef]) {
        Layout::define(self, definitions);
    }

    fn set_scale(&mut self, scale: f32) {
        Layout::set_scale(self, scale);
    }

    fn scale(&self) -> f32 {
        Layout::scale(self)
    }
}

/// Layout behind a handle, with the last scene published and its frame.
pub struct Display {
    /// The layout.
    layout: Mutex<Box<dyn Lays>>,
    /// The last scene published, as it crossed.
    scene: Mutex<Option<WireScene>>,
    /// The frame of the last scene published: an empty frame before the
    /// first. It is behind a lock of its own, held only to swap or clone
    /// the `Arc`, so whoever takes it never waits for layout.
    frame: Mutex<Arc<Frame>>,
    /// Where its frames are presented, once it is bound
    /// ([`Display::present_to`]).
    presenter: Mutex<Option<Arc<Presenter>>>,
}

impl Display {
    /// A display whose every glyph is `advance` pixels across and every
    /// line `line_height` down.
    pub fn cells(advance: u64, line_height: u64) -> Self {
        Self::over(Layout::new(CellShaper::new(
            advance as f32,
            line_height as f32,
        )))
    }

    /// A display that lays out with `layout`.
    fn over(layout: impl Lays + 'static) -> Self {
        Self {
            layout: Mutex::new(Box::new(layout)),
            scene: Mutex::new(None),
            frame: Mutex::new(Arc::new(Frame::default())),
            presenter: Mutex::new(None),
        }
    }

    /// A display over the real shaper and one font file, `bytes`, whose
    /// family `family` is the default family of a font set with no font of
    /// the machine ([`FontSet::only`]): a face naming any other family is
    /// drawn in it. Refused, with a sentence, when the bytes are not a font
    /// or hold no such family.
    pub fn font(bytes: Vec<u8>, family: &str) -> Result<Self, String> {
        let fonts = FontSet::only(family, &[], [bytes]).map_err(|error| error.to_string())?;
        Ok(Self::over(Layout::new(ParleyShaper::new(fonts))))
    }

    /// Binds the display to `presenter`: from now on every scene it
    /// publishes is laid out at the presenter's scale and its frame
    /// presented ([`Presenter::present`]), and every query and heights
    /// answer is at that scale too. A display never bound presents
    /// nothing and lays out at the scale it was told.
    pub fn present_to(&self, presenter: Arc<Presenter>) {
        *self
            .presenter
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(presenter);
    }

    /// The presenter the display is bound to, if it is.
    fn presenter(&self) -> Option<Arc<Presenter>> {
        self.presenter
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// Tells the display the scale to lay out at from now on
    /// ([`Layout::set_scale`]): every later frame, query and heights answer
    /// is at it.
    pub fn set_scale(&self, scale: f32) {
        self.layout().set_scale(scale);
    }

    /// The latest frame ([`Display::latest`]) drawn by the CPU renderer
    /// ([`HeadlessRenderer`]), synchronously, at the last published scene's
    /// size and at the display's scale: its presenter's when it is bound,
    /// and otherwise the scale it was told. Glyphs are drawn with one
    /// coverage a pixel (grayscale antialiasing) and hinting, so a glyph's
    /// partial pixels are blends of its ink and the paper in every channel
    /// alike. Before any scene it is 0 by 0. For tests: it draws a
    /// display's frame to a picture with no render session, no thread and
    /// no clock.
    pub fn picture(&self) -> Image {
        let Some(scene) = self.scene() else {
            return Image {
                width: 0,
                height: 0,
                rgba: Vec::new(),
            };
        };
        // The scale the frame was laid out at: the layout's, which
        // `layout` sets to the presenter's when the display is bound.
        let scale = self.layout().scale();
        let size = |pixels: u64| u32::try_from(pixels).unwrap_or(u32::MAX);
        let mut renderer = HeadlessRenderer::new(Settings {
            antialiasing: Antialiasing::Grayscale,
            hinting: true,
            ..Settings::default()
        });
        renderer.draw(&DrawRequest {
            frame: &self.latest(),
            target: Target {
                width: size(scene.size[0]),
                height: size(scene.size[1]),
                scale,
            },
        });
        renderer.image().clone()
    }

    /// The heights of a text row, a status row and the frame's bottom row
    /// ([`Layout::heights`]).
    pub fn heights(&self) -> Heights {
        self.layout().heights()
    }

    /// Defines the faces `words` and `strings` spell by themselves
    /// ([`decode_definitions`]) as what the faces look like from now on,
    /// with no frame laid out ([`Layout::define`]): every later heights
    /// answer, query and frame is in them, until a scene carries others.
    /// False, changing nothing, when they spell none.
    pub fn define(&self, words: &[u8], strings: &str) -> bool {
        let Some(definitions) = decode_definitions(words, strings) else {
            return false;
        };
        self.layout().define(&wire::face_defs(&definitions));
        true
    }

    /// Publishes the scene `words` and `strings` spell ([`WireScene`]),
    /// whose views' snapshots are `snapshots`, by their index: lays it out
    /// and keeps its frame as the latest. A display bound to a presenter
    /// presents the frame and names the scene's title to it
    /// ([`Presenter::name`]), and its menu bar when it names one
    /// ([`Presenter::menu`]). False, keeping what was published before,
    /// when they spell no scene.
    pub fn publish(&self, words: &[u8], strings: &str, snapshots: &[&Snapshot]) -> bool {
        let Some(wire) = WireScene::decode(words, strings) else {
            return false;
        };
        let scene = wire.resolve(snapshots);
        let title = wire.title.clone();
        let menu = wire.menu.clone();
        let frame = Arc::new(self.layout().frame(&scene));
        *self.frame.lock().unwrap_or_else(PoisonError::into_inner) = Arc::clone(&frame);
        *self.scene.lock().unwrap_or_else(PoisonError::into_inner) = Some(wire);
        if let Some(presenter) = self.presenter() {
            presenter.present(frame, (scene.size.width, scene.size.height));
            presenter.name(&title);
            if let Some(menu) = &menu {
                presenter.menu(menu);
            }
        }
        true
    }

    /// The frame of the last scene published.
    pub fn latest(&self) -> Arc<Frame> {
        Arc::clone(&self.frame.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// The last scene published, as it crossed.
    pub fn scene(&self) -> Option<WireScene> {
        self.scene
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
    }

    /// The layout, locked, at the scale of the presenter the display is
    /// bound to when it is. A poisoned lock is used as it is: what layout
    /// keeps is a cache, which a later call checks or lays out again.
    fn layout(&self) -> MutexGuard<'_, Box<dyn Lays>> {
        let scale = self.presenter().map(|presenter| presenter.scale());
        let mut layout = self.layout.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(scale) = scale {
            layout.set_scale(scale);
        }
        layout
    }

    /// The rows of `snapshot` a view `width` pixels wide and `height` tall,
    /// padded `padding` points, shows from `anchor`
    /// ([`Layout::rows_shown`]): the padding is taken off at the scale the
    /// display lays out at, as its frames take it off.
    pub fn rows(
        &self,
        snapshot: &Snapshot,
        width: u64,
        height: u64,
        padding: Padding,
        anchor: usize,
    ) -> Result<Vec<RowRange>, QueryError> {
        self.layout().rows_shown(
            &text_ref(snapshot),
            width as f32,
            height as f32,
            padding,
            anchor,
        )
    }

    /// Where `position` of `snapshot` goes `lines` visual lines away in a
    /// view `width` pixels wide padded `across` points each side, aiming
    /// for `goal` ([`Layout::lines_from`]).
    pub fn lines_from(
        &self,
        snapshot: &Snapshot,
        width: u64,
        across: u32,
        position: usize,
        lines: i64,
        goal: Option<u64>,
    ) -> Result<Moved, QueryError> {
        self.layout().lines_from(
            &text_ref(snapshot),
            width as f32,
            across,
            position,
            lines,
            goal.map(|goal| goal as f32),
        )
    }
}

/// The `u32` of a padding in points, the largest for one no `u32` holds.
fn points(count: u64) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

/// The record for `answer`: its words, or the status of its refusal.
fn answered<T>(answer: Result<T, QueryError>, write: impl FnOnce(T, &mut Writer)) -> RawWords {
    match answer {
        Ok(value) => {
            let mut writer = Writer::with_capacity(4);
            write(value, &mut writer);
            RawWords::with_status(DisplayStatus::Done as u64, writer.finish())
        }
        Err(QueryError::BadPosition) => {
            RawWords::with_status(DisplayStatus::BadPosition as u64, Vec::new())
        }
    }
}

/// How many display handles this library has handed out
/// ([`editor_ffi_display_new_cells`], [`editor_ffi_display_new_system`],
/// [`editor_ffi_display_new_font`]) that [`editor_ffi_display_free`] has
/// not taken back.
static LIVE: AtomicU64 = AtomicU64::new(0);

/// A new display over the fake shaper, its glyphs `advance` pixels across
/// and its lines `line_height` down, owned by the caller, who must hand it
/// to [`editor_ffi_display_free`] exactly once.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_display_new_cells(advance: u64, line_height: u64) -> *mut Display {
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(Display::cells(advance, line_height)))
}

/// A new display over the real shaper and the fonts of this machine
/// ([`FontSet::system`]), owned by the caller, who must hand it to
/// [`editor_ffi_display_free`] exactly once. Lean's window mode makes it,
/// to draw in the window; no test calls it, since what it lays out
/// depends on the machine's fonts.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_display_new_system() -> *mut Display {
    #[expect(
        clippy::disallowed_methods,
        reason = "the process's display, made for Lean's window mode, is drawn in the machine's fonts"
    )]
    let fonts = FontSet::system();
    LIVE.fetch_add(1, Ordering::Relaxed);
    Box::into_raw(Box::new(Display::over(Layout::new(ParleyShaper::new(
        fonts,
    )))))
}

/// A new display over the real shaper and the one font file of the `len`
/// bytes at `bytes`, whose family is the `family_len` bytes of text at
/// `family` ([`Display::font`]), owned by the caller, who must hand it to
/// [`editor_ffi_display_free`] exactly once; or null when it is refused.
/// `out_reason` is filled either way: empty, or the refusal's sentence.
/// For tests: it lays out with no font of the machine, so what it draws
/// is the same on every machine (`ffi-test theme-pictures`).
///
/// # Safety
///
/// `bytes` points to `len` readable bytes, `family` to `family_len`, and
/// `out_reason` to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_new_font(
    bytes: *const u8,
    len: usize,
    family: *const u8,
    family_len: usize,
    out_reason: *mut RawText,
) -> *mut Display {
    // SAFETY: the caller guarantees the pointers and lengths.
    let (bytes, family) = unsafe {
        (
            crate::words::borrow(bytes, len).to_vec(),
            text::borrow(family, family_len),
        )
    };
    let (display, reason) = match Display::font(bytes, &family) {
        Ok(display) => {
            LIVE.fetch_add(1, Ordering::Relaxed);
            (Box::into_raw(Box::new(display)), String::new())
        }
        Err(reason) => (std::ptr::null_mut(), reason),
    };
    let (text, text_len) = text::lend(reason);
    // SAFETY: the caller guarantees `out_reason` is writable.
    unsafe { out_reason.write(RawText { text, text_len }) };
    display
}

/// A picture as it crosses: its width and height in pixels, and its
/// pixels, row by row from the top, red, green, blue and alpha for each,
/// as sRGB values: a buffer of `len` bytes, owned by the caller until it is
/// handed back with [`editor_ffi_text_free`](crate::text::editor_ffi_text_free).
#[repr(C)]
pub struct RawPicture {
    /// How far across it is.
    pub width: u64,
    /// How far down.
    pub height: u64,
    /// Its pixels.
    pub rgba: *mut u8,
    /// The length of `rgba` in bytes.
    pub len: usize,
}

impl RawPicture {
    /// The record of `image`.
    fn of(image: Image) -> Self {
        let (rgba, len) = crate::words::lend(image.rgba);
        Self {
            width: u64::from(image.width),
            height: u64::from(image.height),
            rgba,
            len,
        }
    }
}

/// Fills `out` with the picture of `display`'s latest frame
/// ([`Display::picture`]): 0 by 0 before any scene. For tests.
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, and `out` points to a writable [`RawPicture`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_picture(display: *const Display, out: *mut RawPicture) {
    // SAFETY: the caller guarantees the handle.
    let image = unsafe { &*display }.picture();
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawPicture::of(image)) };
}

/// Fills `out` with the picture the PNG file of the `len` bytes at `bytes`
/// holds ([`Image::from_png`]), and `out_reason` with nothing; or, refused,
/// `out` with a picture 0 by 0 and `out_reason` with the refusal's
/// sentence, and answers false. For tests.
///
/// # Safety
///
/// `bytes` points to `len` readable bytes, `out` to a writable
/// [`RawPicture`] and `out_reason` to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_picture_from_png(
    bytes: *const u8,
    len: usize,
    out: *mut RawPicture,
    out_reason: *mut RawText,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let bytes = unsafe { crate::words::borrow(bytes, len) };
    let (image, reason, read) = match Image::from_png(bytes) {
        Ok(image) => (image, String::new(), true),
        Err(reason) => (
            Image {
                width: 0,
                height: 0,
                rgba: Vec::new(),
            },
            reason,
            false,
        ),
    };
    let (text, text_len) = text::lend(reason);
    // SAFETY: the caller guarantees both are writable.
    unsafe {
        out.write(RawPicture::of(image));
        out_reason.write(RawText { text, text_len });
    }
    read
}

/// Fills `out` with the bytes of a PNG file of the picture `width` pixels
/// across and `height` down whose pixels are the `len` bytes at `rgba`
/// ([`Image::to_png`]), with the status 0, and `out_reason` with nothing.
/// False, with `out` empty and `out_reason` the refusal's sentence, when
/// the pixels are not that size or the picture is one no PNG file can
/// hold, such as one 0 by 0. For tests.
///
/// # Safety
///
/// `rgba` points to `len` readable bytes, `out` to a writable
/// [`RawWords`] and `out_reason` to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_picture_to_png(
    width: u64,
    height: u64,
    rgba: *const u8,
    len: usize,
    out: *mut RawWords,
    out_reason: *mut RawText,
) -> bool {
    // SAFETY: the caller guarantees the pointer and the length.
    let rgba = unsafe { crate::words::borrow(rgba, len) };
    let sized = u32::try_from(width).ok().zip(u32::try_from(height).ok());
    let image = sized
        .and_then(|(width, height)| {
            // Checked: two sides of `u32::MAX` are past any `u64` of bytes.
            let bytes = u64::from(width)
                .checked_mul(u64::from(height))?
                .checked_mul(4)?;
            let pixels = usize::try_from(bytes).ok()?;
            (pixels == rgba.len()).then(|| Image {
                width,
                height,
                rgba: rgba.to_vec(),
            })
        })
        .ok_or_else(|| String::from("the picture's pixels are not its width by its height"));
    let (bytes, reason, written) = match image.and_then(|image| image.to_png()) {
        Ok(bytes) => (bytes, String::new(), true),
        Err(reason) => (Vec::new(), reason, false),
    };
    let (text, text_len) = text::lend(reason);
    // SAFETY: the caller guarantees both are writable.
    unsafe {
        out.write(RawWords::with_status(DisplayStatus::Done as u64, bytes));
        out_reason.write(RawText { text, text_len });
    }
    written
}

/// Binds `display` to the process's presenter ([`Display::present_to`]):
/// every scene it publishes from now on is laid out at the scale the
/// process's window said and its frame reaches the process's render
/// session, when one runs.
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_present(display: *const Display) {
    // SAFETY: the caller guarantees the handle.
    unsafe { &*display }.present_to(Arc::clone(&PRESENTER));
}

/// Fills `out` with the heights of a text row, a status row and the
/// frame's bottom row, in whole pixels at the display's scale
/// ([`Layout::heights`]): three words, with the status
/// [`DisplayStatus::Done`].
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, and `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_heights(display: *const Display, out: *mut RawWords) {
    // SAFETY: the caller guarantees the handle.
    let heights = unsafe { &*display }.heights();
    let mut writer = Writer::with_capacity(3);
    for height in [heights.text, heights.status, heights.message] {
        writer.word(u64::from(height));
    }
    let raw = RawWords::with_status(DisplayStatus::Done as u64, writer.finish());
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Defines the faces the `words_len` bytes of words at `words` and the
/// `strings_len` bytes of text at `strings` spell, the count of
/// definitions and each definition in the layout of [`WireScene`]'s faces,
/// as what the faces look like from now on, with no frame laid out
/// ([`Display::define`]). False, changing nothing, when they spell none.
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, `words` points to `words_len` readable bytes and `strings` to
/// `strings_len`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_define(
    display: *const Display,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
) -> bool {
    // SAFETY: the caller guarantees every pointer, length and the handle.
    unsafe {
        let words = crate::words::borrow(words, words_len);
        let strings = text::borrow(strings, strings_len);
        (*display).define(words, &strings)
    }
}

/// Fills `out` with the rows of `snapshot` a view `width` pixels wide and
/// `height` tall, its content inset `across` and `down` points and its
/// rows a further `top` points from its top (taken off at the display's
/// scale; [`Display::rows`]), shows from `anchor`: their
/// count, then a start and a stop for each; or with
/// [`DisplayStatus::BadPosition`]. A padding no `u32` holds is the
/// largest.
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, `snapshot` a snapshot handle likewise ([`crate::snapshot`]), and
/// `out` points to a writable [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_rows(
    display: *const Display,
    snapshot: *const Snapshot,
    width: u64,
    height: u64,
    across: u64,
    down: u64,
    top: u64,
    anchor: usize,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees both handles are live.
    let (display, snapshot) = unsafe { (&*display, &*snapshot) };
    let padding = Padding {
        across: points(across),
        down: points(down),
        top: points(top),
    };
    let raw = answered(
        display.rows(snapshot, width, height, padding, anchor),
        |rows, writer| {
            writer.size(rows.len());
            for row in rows {
                writer.size(row.start);
                writer.size(row.stop);
            }
        },
    );
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Fills `out` with where `position` of `snapshot` goes `lines` visual
/// lines down (up when negative) in a view `width` pixels wide whose text
/// is inset `across` points each side, aiming for `goal` when
/// `goal_present`: the position reached and the goal to pass on; or with
/// [`DisplayStatus::BadPosition`]. A move only wraps, so it takes no
/// padding down.
///
/// # Safety
///
/// As [`editor_ffi_display_rows`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_move(
    display: *const Display,
    snapshot: *const Snapshot,
    width: u64,
    across: u64,
    position: usize,
    lines: i64,
    goal_present: bool,
    goal: u64,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees both handles are live.
    let (display, snapshot) = unsafe { (&*display, &*snapshot) };
    let goal = goal_present.then_some(goal);
    let raw = answered(
        display.lines_from(snapshot, width, points(across), position, lines, goal),
        |moved, writer| {
            writer.size(moved.position);
            writer.word(moved.goal.max(0.0) as u64);
        },
    );
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Publishes the scene the `words_len` bytes of words at `words` and the
/// `strings_len` bytes of text at `strings` spell, in the layout of
/// [`WireScene`], whose views' snapshots are the `count` handles at
/// `snapshots`, by their index: lays it out and keeps its frame. False,
/// with what was published before kept, when they spell no scene.
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back; `words` points to `words_len` readable bytes and `strings` to
/// `strings_len`; and `snapshots` to `count` snapshot handles this library
/// handed out and has not taken back (any pointer when `count` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_publish(
    display: *const Display,
    words: *const u8,
    words_len: usize,
    strings: *const u8,
    strings_len: usize,
    snapshots: *const *const Snapshot,
    count: usize,
) -> bool {
    // SAFETY: the caller guarantees every pointer, length and handle.
    unsafe {
        let words = crate::words::borrow(words, words_len);
        let strings = text::borrow(strings, strings_len);
        let handles: Vec<&Snapshot> = if count == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(snapshots, count)
                .iter()
                .map(|&handle| &*handle)
                .collect()
        };
        (*display).publish(words, &strings, &handles)
    }
}

/// Fills `out` with the latest frame as text ([`Frame::describe`]).
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, and `out` points to a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_frame_text(display: *const Display, out: *mut RawText) {
    // SAFETY: the caller guarantees the handle.
    let described = unsafe { &*display }.latest().describe();
    let (text, text_len) = text::lend(described);
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(RawText { text, text_len }) };
}

/// Fills `out` with the rows the view with the id `view` shows in the
/// latest frame: their count, then a start and a stop for each; or with the
/// status 1 when the frame has no such view.
///
/// # Safety
///
/// As [`editor_ffi_display_frame_text`], with `out` a writable
/// [`RawWords`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_frame_rows(
    display: *const Display,
    view: u64,
    out: *mut RawWords,
) {
    // SAFETY: the caller guarantees the handle.
    let frame = unsafe { &*display }.latest();
    let raw = match frame.views.iter().find(|shown| shown.id.0 == view) {
        Some(shown) => {
            let mut writer = Writer::with_capacity(1 + 2 * shown.rows.len());
            writer.size(shown.rows.len());
            for row in &shown.rows {
                writer.size(row.bytes.start);
                writer.size(row.bytes.end);
            }
            RawWords::with_status(DisplayStatus::Done as u64, writer.finish())
        }
        None => RawWords::with_status(1, Vec::new()),
    };
    // SAFETY: the caller guarantees `out` is writable.
    unsafe { out.write(raw) };
}

/// Fills `words` and `strings` with the last scene published as it crossed
/// ([`WireScene::encode`]), with the status 0; or, before any, `words`
/// with the status 1 and both empty.
///
/// # Safety
///
/// As [`editor_ffi_display_frame_text`], with `words` a writable
/// [`RawWords`] and `strings` a writable [`RawText`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_scene(
    display: *const Display,
    words: *mut RawWords,
    strings: *mut RawText,
) {
    // SAFETY: the caller guarantees the handle.
    let scene = unsafe { &*display }.scene();
    let (status, encoded, text) = match scene {
        Some(scene) => {
            let (encoded, text) = scene.encode();
            (0, encoded, text)
        }
        None => (1, Vec::new(), String::new()),
    };
    let (text, text_len) = text::lend(text);
    // SAFETY: the caller guarantees both are writable.
    unsafe {
        words.write(RawWords::with_status(status, encoded));
        strings.write(RawText { text, text_len });
    }
}

/// Frees `display`.
///
/// # Safety
///
/// `display` is a display handle this library handed out and has not taken
/// back, and it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn editor_ffi_display_free(display: *mut Display) {
    // SAFETY: the caller guarantees `display` is a box
    // `editor_ffi_display_new_cells` gave up, taken back this once.
    drop(unsafe { Box::from_raw(display) });
    LIVE.fetch_sub(1, Ordering::Relaxed);
}

/// How many display handles this library has handed out that have not been
/// freed.
#[unsafe(no_mangle)]
pub extern "C" fn editor_ffi_display_live() -> u64 {
    LIVE.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use editor_render::clock::FakeClock;
    use editor_render::fake::RecordingRenderer;
    use editor_render::port::Target;
    use editor_render::render_loop::{RecordingPark, RenderHandle, RenderLoop, Step};

    use editor_layout::face::{Color, Face, Underline, UnderlineStyle};

    use super::{Display, WireFace, WireScene, WireView, text_ref};
    use crate::document::Document;
    use crate::render::{Follows, Presenter};
    use crate::snapshot::Snapshot;

    /// A loop stepped by hand over the recording renderer, and its handle.
    fn stepped() -> (RenderLoop<RecordingRenderer>, RenderHandle) {
        RenderLoop::new(
            RecordingRenderer::new(),
            Arc::new(FakeClock::new()),
            Arc::new(RecordingPark::new()),
            Target {
                width: 80,
                height: 32,
                scale: 1.0,
            },
        )
    }

    /// Publishes to `display` a scene of one view, 80 by 32, of `snapshot`.
    fn publish_one(display: &Display, snapshot: &Snapshot) {
        let wire = WireScene {
            size: [80, 32],
            views: vec![WireView {
                id: 1,
                rect: [0, 0, 80, 32],
                snapshot: Some(0),
                ..WireView::default()
            }],
            ..WireScene::default()
        };
        let (words, strings) = wire.encode();
        assert!(display.publish(&words, &strings, &[snapshot]));
    }

    #[test]
    fn a_bound_display_presents_each_frame_it_publishes_with_the_stamp_it_answers() {
        let (mut render, handle) = stepped();
        let presenter = Presenter::new();
        presenter.start(handle.clone(), Follows::Window);
        let display = Display::cells(8, 16);
        display.present_to(Arc::clone(&presenter));
        let snapshot = Snapshot::of(&Document::new("ab\ncd"));
        presenter.answering().note(42);
        publish_one(&display, &snapshot);
        assert_eq!(handle.counters().frames_submitted, 1);
        assert_eq!(presenter.answering().take(), None);
        let Step::Drew(entry) = render.step() else {
            panic!("the frame is drawn");
        };
        assert_eq!(entry.input_ns, 42);
        // The frame drawn is the display's latest.
        let requests = render.renderer().requests();
        assert!(Arc::ptr_eq(&requests[0].frame, &display.latest()));
    }

    #[test]
    fn a_display_that_was_never_bound_presents_nothing() {
        let (_render, handle) = stepped();
        let presenter = Presenter::new();
        presenter.start(handle.clone(), Follows::Window);
        let display = Display::cells(8, 16);
        presenter.answering().note(42);
        publish_one(&display, &Snapshot::of(&Document::new("ab")));
        assert_eq!(handle.counters().frames_submitted, 0);
        // The stamp is still the next bound frame's to answer.
        assert_eq!(presenter.answering().take(), Some(42));
    }

    #[test]
    fn a_bound_display_with_no_target_lays_its_frame_out_and_spends_the_stamp() {
        let presenter = Presenter::new();
        let display = Display::cells(8, 16);
        display.present_to(Arc::clone(&presenter));
        presenter.answering().note(42);
        publish_one(&display, &Snapshot::of(&Document::new("ab\ncd")));
        assert_eq!(display.latest().views[0].rows.len(), 2);
        assert_eq!(presenter.answering().take(), None);
    }

    #[test]
    fn a_bound_display_lays_out_at_the_presenters_scale() {
        let presenter = Presenter::new();
        let display = Display::cells(8, 16);
        display.present_to(Arc::clone(&presenter));
        assert_eq!(display.heights().text, 16);
        presenter.set_scale(2.0);
        let heights = display.heights();
        assert_eq!(
            (heights.text, heights.status, heights.message),
            (32, 32, 32)
        );
        // A display that is not bound is at its own scale.
        assert_eq!(Display::cells(8, 16).heights().text, 16);
    }

    #[test]
    fn a_display_over_bytes_that_are_not_a_font_is_refused() {
        let refused = Display::font(b"not a font".to_vec(), "Noto Sans Mono");
        assert!(refused.is_err_and(|reason| !reason.is_empty()));
    }

    #[test]
    fn a_picture_before_any_scene_is_empty() {
        let picture = Display::cells(8, 16).picture();
        assert_eq!((picture.width, picture.height), (0, 0));
        assert!(picture.rgba.is_empty());
    }

    #[test]
    fn a_picture_is_the_scenes_size_in_its_faces() {
        // Cells draw no glyphs, so a view of text is its default face's
        // background everywhere: this pins the wiring, the size and that
        // the faces published are the ones drawn.
        let display = Display::cells(8, 16);
        let snapshot = Snapshot::of(&Document::new("ab\ncd"));
        let paper = Color::rgb(0x12, 0x34, 0x56);
        let wire = WireScene {
            size: [80, 32],
            views: vec![WireView {
                id: 1,
                rect: [0, 0, 80, 32],
                snapshot: Some(0),
                ..WireView::default()
            }],
            faces: Some(vec![WireFace {
                name: "default".to_owned(),
                face: Face {
                    background: Some(paper),
                    ..Face::default()
                },
            }]),
            ..WireScene::default()
        };
        let (words, strings) = wire.encode();
        assert!(display.publish(&words, &strings, &[&snapshot]));
        let picture = display.picture();
        assert_eq!((picture.width, picture.height), (80, 32));
        assert_eq!(picture.rgba.len(), 80 * 32 * 4);
        assert!(
            picture
                .rgba
                .as_chunks::<4>()
                .0
                .iter()
                .all(|pixel| *pixel == [0x12, 0x34, 0x56, 0xff])
        );
    }

    /// How many pixels of the column 4 pixels in of `display`'s picture
    /// are ink, once it has published a scene, 80 by 64, of one view of
    /// "ab" in a face of paper and ink, underlined: the underline's
    /// thickness, which the renderer draws at the scale it is given.
    fn underline_thickness(display: &Display) -> usize {
        let (paper, ink) = (Color::rgb(0xff, 0xff, 0xff), Color::rgb(0, 0, 0));
        let snapshot = Snapshot::of(&Document::new("ab"));
        let wire = WireScene {
            size: [80, 64],
            views: vec![WireView {
                id: 1,
                rect: [0, 0, 80, 64],
                snapshot: Some(0),
                ..WireView::default()
            }],
            faces: Some(vec![WireFace {
                name: "default".to_owned(),
                face: Face {
                    foreground: Some(ink),
                    background: Some(paper),
                    underline: Some(Underline {
                        style: UnderlineStyle::Single,
                        color: None,
                    }),
                    ..Face::default()
                },
            }]),
            ..WireScene::default()
        };
        let (words, strings) = wire.encode();
        assert!(display.publish(&words, &strings, &[&snapshot]));
        let picture = display.picture();
        assert_eq!((picture.width, picture.height), (80, 64));
        (0..picture.height)
            .filter(|&y| picture.pixel(4, y) == Some([0, 0, 0, 0xff]))
            .count()
    }

    #[test]
    fn a_picture_of_a_display_not_bound_is_drawn_at_the_scale_it_was_told() {
        assert_eq!(underline_thickness(&Display::cells(8, 16)), 1);
        let display = Display::cells(8, 16);
        display.set_scale(2.0);
        assert_eq!(underline_thickness(&display), 2);
    }

    #[test]
    fn a_picture_of_a_bound_display_is_drawn_at_its_presenters_scale() {
        // The presenter's scale wins over the one the display was told.
        let presenter = Presenter::new();
        presenter.set_scale(2.0);
        let display = Display::cells(8, 16);
        display.set_scale(3.0);
        display.present_to(Arc::clone(&presenter));
        assert_eq!(underline_thickness(&display), 2);
    }

    #[test]
    fn a_documents_snapshot_is_a_text_whose_changes_are_its_documents() {
        let document = Document::new("ab");
        let snapshot = Snapshot::of(&document);
        let text = text_ref(&snapshot);
        assert_eq!(text.key.0, document.key());
        assert!(document.replace(1, 1, "x"));
        let patch = text.changes.since(snapshot.text().revision()).unwrap();
        assert_eq!((patch.edits[0].new.start, patch.edits[0].new.end), (1, 2));
        drop(document);
        assert!(text.changes.since(snapshot.text().revision()).is_none());
    }

    #[test]
    fn a_snapshot_no_document_holds_has_no_changes() {
        let snapshot = Snapshot::loaded(Document::new("ab").snapshot());
        let text = text_ref(&snapshot);
        assert_eq!(text.key.0, snapshot.key());
        assert!(text.changes.since(snapshot.text().revision()).is_none());
    }
}
