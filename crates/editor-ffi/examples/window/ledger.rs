//! The frame ledger, and the renderers that wrap the window's: one enters
//! each draw in the ledger as it begins and as it ends, and one reads back
//! what the window presents and compares it with the headless renderer's
//! picture of the same frame.

use std::sync::{Arc, Mutex};

use editor_ffi::render::target;
use editor_ffi::window::{Rasteriser, window_rasteriser};
use editor_layout::frame::Frame;
use editor_platform::{Canvas, Drawer, NativeWindow};
use editor_render::clock::Clock;
use editor_render::port::{DrawRequest, Drawn, Renderer, Target};
use editor_render_wgpu::{
    Antialiasing, Blending, HeadlessRenderer, Image, Masks, Settings, WgpuRenderer,
};

use crate::judge::{Picture, uncompared};
use crate::tally::{Happened, Record, Tally};
use crate::{Shared, locked};

/// What `canvas`, a thing the window tells its drawer, is to the ledger.
///
/// Three things a window tells bear on what is drawn: the size it opened
/// at, a new size, and damage. A fourth bears on whether anybody can see
/// what is drawn: hidden or shown. Whatever else it tells asks for no
/// draw by itself (a refresh rate, closing) and is kept as it prints, so
/// the match names those four and no more. A thing a window comes to tell
/// that does ask for a draw would show here as a draw for nothing, which
/// fails the run: that is when to name it.
fn happened(canvas: &Canvas) -> Happened {
    match canvas {
        Canvas::Opened {
            size,
            refresh_millihertz,
            ..
        } => Happened::Opened {
            size: target(*size),
            refresh: *refresh_millihertz,
        },
        Canvas::Resized(size) => Happened::Resized(target(*size)),
        Canvas::Damaged => Happened::Damaged,
        Canvas::Hidden(hidden) => Happened::Hidden(*hidden),
        other => Happened::Told(format!("{other:?}")),
    }
}

/// What the ledger keeps.
#[derive(Default)]
struct Kept {
    /// Everything that happened, in order.
    records: Vec<Record>,
    /// What it comes to.
    tally: Tally,
    /// Each frame published that is equal to none before it: frame `n` is
    /// at `n - 1`.
    frames: Vec<Arc<Frame>>,
    /// The window each of those frames was laid out for, as it was first
    /// published: its size and its scale.
    laid: Vec<Target>,
}

/// The ledger: everything that asked for a draw and every draw, in the
/// order they happened, each stamped on one clock.
///
/// What asks is entered before its word is left with the render loop, and
/// a draw as the renderer is entered, so no draw is entered before what
/// asked for it.
pub struct Ledger {
    /// The clock that stamps.
    clock: Arc<dyn Clock>,
    /// What it keeps.
    kept: Mutex<Kept>,
}

impl Ledger {
    /// A ledger nothing is entered in, stamping by `clock`.
    pub fn new(clock: Arc<dyn Clock>) -> Self {
        Self {
            clock,
            kept: Mutex::new(Kept::default()),
        }
    }

    /// Enters one thing that happened, now.
    pub fn note(&self, happened: Happened) {
        let mut kept = locked(&self.kept);
        // Read under the lock: the order of the records is the order of
        // their stamps.
        let at_ns = self.clock.now_ns();
        kept.tally.note(at_ns, &happened);
        kept.records.push((at_ns, happened));
    }

    /// Enters that `frame`, laid out for the window `window`, is
    /// published, and gives its number.
    pub fn published(&self, frame: &Arc<Frame>, window: Target) -> usize {
        let number = {
            let mut kept = locked(&self.kept);
            number_of(&kept.frames, frame).unwrap_or_else(|| {
                kept.frames.push(Arc::clone(frame));
                kept.laid.push(window);
                kept.frames.len()
            })
        };
        self.note(Happened::Published(number));
        number
    }

    /// The window each frame published was laid out for: frame `n`'s is
    /// at `n - 1`.
    pub fn laid(&self) -> Vec<Target> {
        locked(&self.kept).laid.clone()
    }

    /// Enters that a draw of `frame` on `target` begins.
    fn began(&self, frame: &Arc<Frame>, target: Target) {
        let frame = number_of(&locked(&self.kept).frames, frame);
        self.note(Happened::Began { frame, target });
    }

    /// Whether a frame is shown and nothing more is asked for or being
    /// drawn.
    pub fn settled(&self) -> bool {
        locked(&self.kept).tally.settled()
    }

    /// Everything entered so far and what it comes to, as copies.
    pub fn read(&self) -> (Vec<Record>, Tally) {
        let kept = locked(&self.kept);
        (kept.records.clone(), kept.tally.clone())
    }
}

/// The number of `frame` among `frames`, the frames published: one more
/// than where the first that is it, or equal to it, is.
fn number_of(frames: &[Arc<Frame>], frame: &Arc<Frame>) -> Option<usize> {
    frames
        .iter()
        .position(|published| Arc::ptr_eq(published, frame) || published == frame)
        .map(|at| at + 1)
}

/// A renderer whose every draw is entered in the ledger: as it begins,
/// and as it ends with whether it presented and the kind of mask it says
/// it drew its glyphs with.
pub struct Entered<R> {
    /// The renderer.
    pub inner: R,
    /// Where its draws are entered.
    pub ledger: Arc<Ledger>,
    /// The kind of mask the renderer says its last draw used, asked as
    /// each draw ends; `None` of a renderer that does not say.
    pub masks: fn(&R) -> Option<Masks>,
}

impl<R: Renderer> Renderer for Entered<R> {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        self.ledger.began(request.frame, request.target);
        let drawn = self.inner.draw(request);
        self.ledger.note(Happened::Ended {
            presented: drawn.presented,
            masks: (self.masks)(&self.inner),
        });
        drawn
    }
}

/// What draws in the example's window: the checked renderer, each of its
/// draws entered in the ledger.
pub type Watched = Entered<Checked>;

/// `drawer`, with each thing the window tells entered in `ledger` before
/// `drawer` hears it.
pub fn entering(drawer: Drawer, ledger: Arc<Ledger>) -> Drawer {
    Arc::new(move |canvas| {
        ledger.note(happened(&canvas));
        drawer(canvas);
    })
}

/// The wgpu renderer on the window, with each frame it presents read back
/// and compared with the headless renderer's picture of the same frame.
pub struct Checked {
    /// The renderer on the window.
    gpu: WgpuRenderer,
    /// Whether each frame presented is read back and compared: not in a
    /// run a person watches (`--no-picture`), where the half second a
    /// comparison takes would make every resize look stalled.
    read: bool,
    /// Whether the window's surface lets its texture be copied from: what
    /// the renderer answered when it was asked to keep its pictures.
    copies: bool,
    /// The renderer it is compared with.
    headless: HeadlessRenderer,
    /// Where what it finds goes.
    shared: Arc<Shared>,
}

impl Checked {
    /// The kind of mask the renderer on the window says its last draw
    /// asked its glyph images in.
    pub fn masks(&self) -> Option<Masks> {
        self.gpu.masks()
    }
}

impl Renderer for Checked {
    fn draw(&mut self, request: &DrawRequest<'_>) -> Drawn {
        let drawn = self.gpu.draw(request);
        if !drawn.presented {
            let reason = self.gpu.refused().unwrap_or("no reason given").to_owned();
            locked(&self.shared.refusals).push(reason);
            return drawn;
        }
        if !self.read {
            return drawn;
        }
        let picture = self.gpu.read_back();
        let found = uncompared(self.copies, self.gpu.refused()).unwrap_or_else(|| {
            self.headless.draw(request);
            compare(&picture, self.headless.image(), request.target)
        });
        locked(&self.shared.pictures).push(found);
        drawn
    }
}

/// What `picture` is found to be against `expected`, both of `target`.
fn compare(picture: &Image, expected: &Image, target: Target) -> Picture {
    let size = (picture.width, picture.height);
    if size != (expected.width, expected.height) || size != (target.width, target.height) {
        return Picture::WrongSize(picture.width, picture.height);
    }
    let (mut differing, mut worst) = (0, 0);
    for (got, wanted) in picture
        .rgba
        .as_chunks::<4>()
        .0
        .iter()
        .zip(expected.rgba.as_chunks::<4>().0)
    {
        let difference = got
            .iter()
            .zip(wanted)
            .map(|(a, b)| a.abs_diff(*b))
            .max()
            .unwrap_or(0);
        if difference > 0 {
            differing += 1;
        }
        worst = worst.max(difference);
    }
    Picture::Compared {
        pixels: picture.rgba.len() / 4,
        differing,
        worst,
    }
}

/// The renderer's settings for this window, as the platform draws text.
///
/// Where the platform draws with Core Text (`matches_core_text`, which
/// the caller sets on macOS), text is drawn as Core Text draws it
/// ([`Settings::core_text`]: blended in sRGB-encoded values, at the swash
/// fallback's weight); everywhere else it keeps the default, linear light
/// and the outlines as they are. This is the one place the target system
/// is asked: whatever later makes the editor's own renderer applies the
/// same rule.
fn platform(matches_core_text: bool) -> Settings {
    if matches_core_text {
        Settings::core_text()
    } else {
        Settings::default()
    }
}

/// The settings of the picture the window's is compared with: the
/// platform's ([`platform`]), blended as the renderer on the window says
/// it blends (`blending`: a surface that cannot blend encoded blends in
/// linear light), and in plain masks where its adapter cannot blend by a
/// coverage for each channel (`per_channel`).
fn settings(per_channel: bool, blending: Blending, matches_core_text: bool) -> Settings {
    let platform = Settings {
        blending,
        ..platform(matches_core_text)
    };
    if per_channel {
        platform
    } else {
        Settings {
            antialiasing: Antialiasing::Grayscale,
            ..platform
        }
    }
}

/// A renderer that can be handed what draws its glyphs: the renderer on
/// the window, and the headless one it is compared with.
trait Handed: Sized {
    /// The renderer, drawing its glyphs with what `rasteriser` names, and
    /// with swash for what that declines.
    fn handed(self, rasteriser: Rasteriser) -> Self;
}

impl Handed for WgpuRenderer {
    fn handed(self, rasteriser: Rasteriser) -> Self {
        handed(
            self,
            rasteriser,
            #[cfg(target_os = "macos")]
            WgpuRenderer::rasterizing_with,
        )
    }
}

impl Handed for HeadlessRenderer {
    fn handed(self, rasteriser: Rasteriser) -> Self {
        handed(
            self,
            rasteriser,
            #[cfg(target_os = "macos")]
            HeadlessRenderer::rasterizing_with,
        )
    }
}

/// The renderer on the window, `window`, and the headless renderer whose
/// picture it is compared with, made by `picture` from the window's once
/// it is handed: each handed the one `rasteriser`, so the pictures
/// compared have their glyphs drawn alike.
fn alike<W: Handed, P: Handed>(
    rasteriser: Rasteriser,
    window: W,
    picture: impl FnOnce(&W) -> P,
) -> (W, P) {
    let window = window.handed(rasteriser);
    let picture = picture(&window).handed(rasteriser);
    (window, picture)
}

/// `renderer`, handed the rasteriser `rasteriser` names through
/// `handing`, the renderer's own `rasterizing_with`.
#[cfg(target_os = "macos")]
fn handed<R>(
    renderer: R,
    rasteriser: Rasteriser,
    handing: fn(R, editor_raster_coretext::CoreTextRasterizer) -> R,
) -> R {
    match editor_ffi::window::core_text(rasteriser) {
        Some(core_text) => handing(renderer, core_text),
        None => renderer,
    }
}

/// `renderer` as it is: off macOS no rasteriser but swash is chosen.
///
/// It is handed no `rasterizing_with`, and its callers name none here:
/// that function takes any rasteriser, and off macOS there is none to
/// name it with (the Core Text one is macOS's alone), so a renderer's
/// `rasterizing_with` handed on would leave its type unknown.
#[cfg(not(target_os = "macos"))]
fn handed<R>(renderer: R, _: Rasteriser) -> R {
    renderer
}

/// A renderer on `window`, checked: each frame it presents is read back
/// and compared when `read` says so. The error is why there is none.
pub fn renderer(
    window: Option<&NativeWindow>,
    shared: &Arc<Shared>,
    read: bool,
) -> Result<Checked, String> {
    let window = window.ok_or("the platform named no native window to draw in")?;
    // Its antialiasing is the device's to settle: one that cannot blend
    // by a coverage for each channel draws plain masks whatever it is
    // told. What it is told that matters is the weight and the hinting.
    let macos = cfg!(target_os = "macos");
    // SAFETY: the window port tells of `window` when it opens, on this
    // thread, and it stays live until the drawer returns from being told
    // the window is closing. The session drops this renderer, on this
    // thread, while it is being told so.
    #[expect(
        clippy::disallowed_methods,
        reason = "this example is the one place a renderer is made on a window: it is the window's check, run on demand"
    )]
    let made = unsafe { WgpuRenderer::on_window(window, platform(macos)) };
    let (mut gpu, headless) = alike(
        window_rasteriser(macos),
        made.map_err(|error| error.to_string())?,
        // An adapter that cannot blend by a coverage for each channel
        // draws plain masks whatever it is asked, and a surface that
        // cannot blend encoded blends in linear light: so must what it is
        // compared with, at the same weight.
        |gpu: &WgpuRenderer| {
            HeadlessRenderer::new(settings(gpu.per_channel(), gpu.blending(), macos))
        },
    );
    // A run that reads no picture asks the renderer to keep none: a draw
    // then costs what the editor's own would, and not a read-back more.
    let copies = read && gpu.keep_picture();
    *locked(&shared.adapter) = Some(format!(
        "{}, blending by a coverage for each channel: {}; it blends in {}, and the picture it is compared with in {}",
        gpu.adapter(),
        gpu.per_channel(),
        gpu.blending(),
        headless.blending()
    ));
    *locked(&shared.rasterizing) = Some(format!(
        "{} on the window, and {} for the picture it is compared with",
        gpu.rasterizing(),
        headless.rasterizing()
    ));
    Ok(Checked {
        gpu,
        read,
        copies,
        headless,
        shared: Arc::clone(shared),
    })
}

/// What the example decides of what it saw, with no window: these run in
/// the gate.
#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use editor_layout::Layout;
    use editor_layout::frame::Frame;
    use editor_layout::scene::{Rect, Scene};
    use editor_layout::shaper::fake::CellShaper;
    use editor_platform::{Canvas, Drawer, Resize};
    use editor_render::clock::FakeClock;
    use editor_render::fake::RecordingRenderer;
    use editor_render::port::{DrawRequest, Renderer};
    use editor_render_wgpu::{Antialiasing, Blending, Masks, Settings, SubpixelOrder};

    use editor_ffi::window::Rasteriser;

    use super::{Entered, Handed, Ledger, alike, entering, happened, platform, settings};
    use crate::tally::Happened;
    use crate::testing::{LARGE, MS, SMALL, began, presented_as};

    #[test]
    fn the_window_draws_with_core_texts_settings_where_it_matches_core_text_and_the_default_elsewhere()
     {
        let plain = |settings: Settings| Settings {
            antialiasing: Antialiasing::Grayscale,
            ..settings
        };
        // The platform's settings are editor-render-wgpu's own: what
        // either holds is that crate's to pin.
        assert_eq!(platform(true), Settings::core_text());
        assert_eq!(platform(false), Settings::default());
        // A renderer on the window that blends as it was asked gives the
        // platform's settings back.
        let default = Settings::default();
        assert_eq!(settings(true, default.blending, false), default);
        assert_eq!(settings(false, default.blending, false), plain(default));
        let core_text = Settings::core_text();
        assert_eq!(settings(true, core_text.blending, true), core_text);
        assert_eq!(settings(false, core_text.blending, true), plain(core_text));
    }

    #[test]
    fn the_picture_is_blended_as_the_renderer_on_the_window_says_it_blends() {
        // Whatever the renderer on the window says it blends in, as a
        // surface that could not blend encoded fell back to linear light,
        // what the window's picture is compared with blends in too, and
        // is otherwise the platform's.
        for blending in [Blending::Linear, Blending::Encoded] {
            for matches_core_text in [true, false] {
                let compared = settings(true, blending, matches_core_text);
                assert_eq!(compared.blending, blending);
                assert_eq!(
                    compared,
                    Settings {
                        blending,
                        ..platform(matches_core_text)
                    }
                );
            }
        }
    }

    /// A renderer that keeps what it is handed to draw its glyphs with,
    /// and what it was made from.
    #[derive(Debug, Default, PartialEq)]
    struct Holding {
        /// Each rasteriser it was handed, in order.
        handed: Vec<Rasteriser>,
        /// What the renderer it was made from held when it was made;
        /// `None` of one made from nothing.
        made_from: Option<Vec<Rasteriser>>,
    }

    impl Handed for Holding {
        fn handed(mut self, rasteriser: Rasteriser) -> Self {
            self.handed.push(rasteriser);
            self
        }
    }

    /// Both renderers are handed the one rasteriser, and the headless one
    /// is made from the window's once it is handed: so a headless renderer
    /// made at the window's settings draws its glyphs as the window does.
    ///
    /// Seen to bite on 2026-11-20: with `alike` handing the headless
    /// renderer nothing, it failed, the picture's renderer holding `[]`
    /// where the window's held `[CoreText]`.
    #[test]
    fn the_window_and_the_picture_it_is_compared_with_draw_glyphs_alike() {
        for rasteriser in [Rasteriser::CoreText, Rasteriser::Swash] {
            let (window, picture) =
                alike(rasteriser, Holding::default(), |window: &Holding| Holding {
                    handed: Vec::new(),
                    made_from: Some(window.handed.clone()),
                });
            assert_eq!(window.handed, [rasteriser]);
            assert_eq!(
                picture,
                Holding {
                    handed: vec![rasteriser],
                    made_from: Some(vec![rasteriser]),
                }
            );
        }
    }

    #[test]
    fn what_a_window_tells_its_drawer_is_what_the_ledger_takes_it_for() {
        let size = Resize {
            width: 800,
            height: 600,
            scale: 2.0,
            fullscreen: false,
            corner_clearance: 0,
            top_inset: 0,
        };
        assert_eq!(
            happened(&Canvas::Opened {
                window: None,
                size,
                refresh_millihertz: Some(60_000),
            }),
            Happened::Opened {
                size: LARGE,
                refresh: Some(60_000),
            }
        );
        assert_eq!(happened(&Canvas::Resized(size)), Happened::Resized(LARGE));
        assert_eq!(happened(&Canvas::Damaged), Happened::Damaged);
        // Hidden and shown ask for no draw, and say whether a window left
        // alone is one anybody can see.
        for hidden in [true, false] {
            assert_eq!(happened(&Canvas::Hidden(hidden)), Happened::Hidden(hidden));
        }
        // What else asks for no draw is kept as it prints.
        for (canvas, said) in [
            (Canvas::Refresh(Some(50_000)), "Refresh(Some(50000))"),
            (Canvas::Closing, "Closing"),
        ] {
            assert_eq!(happened(&canvas), Happened::Told(said.to_owned()));
        }
    }

    /// The frame of `text` in one view, laid out on the fake shaper.
    fn frame_of(text: &str) -> Arc<Frame> {
        let rect = Rect {
            x: 0,
            y: 0,
            width: 400,
            height: 300,
        };
        Arc::new(Layout::new(CellShaper::new(10.0, 16.0)).frame(&Scene::of_text(text, rect)))
    }

    /// A ledger on a clock that moves on a millisecond at every reading.
    fn ledger() -> Arc<Ledger> {
        Arc::new(Ledger::new(Arc::new(FakeClock::stepping(MS))))
    }

    /// What was entered in `ledger`, without the times.
    fn entered(ledger: &Ledger) -> Vec<Happened> {
        let (records, _) = ledger.read();
        records.into_iter().map(|(_, happened)| happened).collect()
    }

    #[test]
    fn frames_published_are_numbered_from_one_and_equal_frames_are_one_frame() {
        let ledger = ledger();
        let one = frame_of("one");
        assert_eq!(ledger.laid(), []);
        assert_eq!(ledger.published(&one, SMALL), 1);
        // The same value again, and another that is equal to it.
        assert_eq!(ledger.published(&one, SMALL), 1);
        assert_eq!(ledger.published(&frame_of("one"), SMALL), 1);
        assert_eq!(ledger.published(&frame_of("two"), LARGE), 2);
        // The first again, after another: still the first.
        assert_eq!(ledger.published(&frame_of("one"), SMALL), 1);
        assert_eq!(entered(&ledger), [1, 1, 1, 2, 1].map(Happened::Published));
        // Each frame is kept with the window it was laid out for, once.
        assert_eq!(ledger.laid(), [SMALL, LARGE]);
        // Each is stamped as it is entered, on the ledger's clock.
        let (records, tally) = ledger.read();
        let stamps: Vec<u64> = records.iter().map(|(at_ns, _)| *at_ns).collect();
        assert_eq!(stamps, [1, 2, 3, 4, 5].map(|at| at * MS + 1));
        // And taken in by the tally.
        assert_eq!(tally.asked, 5);
    }

    #[test]
    fn a_draw_is_entered_as_it_begins_and_as_it_ends_with_whether_it_presented() {
        let ledger = ledger();
        // A renderer that says its masks by how many draws it was asked
        // for: plain ones for the first, and from then on subpixel ones.
        let mut renderer = Entered {
            inner: RecordingRenderer::new(),
            ledger: Arc::clone(&ledger),
            masks: |inner| {
                Some(match inner.requests().len() {
                    1 => Masks::Plain,
                    _ => Masks::Subpixel(SubpixelOrder::Rgb),
                })
            },
        };
        let (one, two) = (frame_of("one"), frame_of("two"));
        ledger.published(&one, SMALL);
        ledger.published(&two, SMALL);

        let drawn = renderer.draw(&DrawRequest {
            frame: &two,
            target: SMALL,
        });
        assert!(drawn.presented);
        // A draw that does not present, of a frame equal to one published.
        renderer.inner.fail_next_present();
        let again = frame_of("one");
        let refused = renderer.draw(&DrawRequest {
            frame: &again,
            target: LARGE,
        });
        assert!(!refused.presented);
        // And of a frame nobody published.
        renderer.draw(&DrawRequest {
            frame: &frame_of("three"),
            target: LARGE,
        });

        // Each ends with what the renderer says of its masks once it has
        // drawn, whether or not it presented.
        let stripes = Masks::Subpixel(SubpixelOrder::Rgb);
        assert_eq!(
            entered(&ledger)[2..],
            [
                began(2, SMALL),
                presented_as(Masks::Plain),
                began(1, LARGE),
                Happened::Ended {
                    presented: false,
                    masks: Some(stripes),
                },
                Happened::Began {
                    frame: None,
                    target: LARGE,
                },
                presented_as(stripes),
            ]
        );
        // The renderer was asked for each.
        assert_eq!(renderer.inner.requests().len(), 3);
        assert!(!ledger.settled());
    }

    #[test]
    fn what_the_window_tells_is_entered_before_the_drawer_hears_it() {
        let ledger = ledger();
        // What the drawer heard, and how much was entered when it did.
        let heard = Arc::new(Mutex::new(Vec::new()));
        let drawer: Drawer = {
            let (heard, ledger) = (Arc::clone(&heard), Arc::clone(&ledger));
            Arc::new(move |canvas| {
                let entered = ledger.read().0.len();
                heard
                    .lock()
                    .expect("nothing panics holding it")
                    .push((format!("{canvas:?}"), entered));
            })
        };
        let drawer = entering(drawer, Arc::clone(&ledger));

        drawer(Canvas::Damaged);
        drawer(Canvas::Hidden(true));

        assert_eq!(
            *heard.lock().expect("nothing panics holding it"),
            [("Damaged".to_owned(), 1), ("Hidden(true)".to_owned(), 2)]
        );
        assert_eq!(
            entered(&ledger),
            [Happened::Damaged, Happened::Hidden(true)]
        );
    }
}
