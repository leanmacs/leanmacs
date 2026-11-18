//! A window's surface: everything that is decided about one, with no call
//! of wgpu's.
//!
//! The calls that make a surface, configure it, take its next texture and
//! present it are the device's (`gpu`), and need a window: no test in the
//! gate reaches them. What those calls are told, and what is done with
//! their answers, is decided here, on plain values a test builds.
//!
//! # What is known of a surface
//!
//! [`State`] is what a device keeps of one surface, and the one place
//! anything about it is decided. It is made from what the surface offers
//! ([`State::new`]): the formats and the present mode chosen as below,
//! whether its texture may be copied from, or the reason nothing can be
//! drawn on it, where it offers no format or no present mode. It says
//! what format the pipeline is made for ([`State::target`]). It gets the
//! texture of each draw ([`State::acquire`]): it configures the surface
//! before the first draw, before a draw of another size, and before the
//! draw after a texture that no longer fitted or after its picture began
//! to be kept, and acts on each answer as [`next`] says. And it says how
//! the picture of a draw is taken ([`State::keep_picture`],
//! [`State::picture`]).
//!
//! The two calls it makes are a port, [`Calls`]: configure the surface,
//! and ask it for its next texture. The device implements it with wgpu's
//! (`gpu`, `OnSurface`). The tests here implement it with a surface that
//! is a script: it records what it was configured with and when it was
//! asked, and answers what the test says. So the rules are run in the
//! gate, with every answer a surface can give, and wgpu's calls are run
//! on a real window, on demand.
//!
//! # The handles
//!
//! A window reaches this crate as the window port's own data
//! (`editor_platform::NativeWindow`), which names no library. [`handles`]
//! turns it back into the handles wgpu takes, through wgpu's re-export of
//! `raw-window-handle` (`wgpu::rwh`): this crate does not depend on that
//! crate, and `deny.toml` lets no crate of the workspace.
//!
//! # The format
//!
//! The pipeline blends in linear light, so what it draws on is an sRGB
//! format: the GPU turns each value linear to blend and back to store.
//! [`choose_format`] takes the first sRGB format a surface offers,
//! wherever it is in the offer: Metal offers a format that is not sRGB
//! first. A surface that offers none is configured with the first format
//! it offers and drawn on through that format's sRGB form, as a view; a
//! format with no sRGB form is drawn on as it is. A surface that offers
//! nothing has no format, and no renderer is made on it.
//!
//! # The present mode
//!
//! [`present::choose`] decides, from the modes a
//! surface offers. [`mode_of`] and [`wgpu_mode`] are that module's names
//! for wgpu's modes and back. wgpu's own default is not taken: on a
//! surface that offers a mode that tears, it is that mode. A run that asks
//! for another mode or latency, or both, is given them as that function
//! says, and [`State::presentation`] answers what the surface offered,
//! only what was asked and what it was configured with, once it has been
//! configured.
//!
//! # What a surface answers when asked for a texture
//!
//! [`next`] says what to do with each answer:
//!
//! | Answer | What is done |
//! |---|---|
//! | A texture | Draw on it and present it |
//! | A texture that no longer fits the surface | Draw on it and present it, then configure the surface again for the next draw |
//! | The configuration is outdated, or the surface is lost | Configure the surface again and ask once more; the same answer again is no texture |
//! | The window is occluded, the wait timed out, or wgpu refused the call | No texture: the draw is not presented |
//!
//! A draw that is not presented is the render loop's to try again, and a
//! window the loop has been told is hidden is not drawn on at all
//! (`editor-render`'s `render_loop`). A window is not always said to be
//! hidden: one that opens on macOS is occluded until it is on the screen,
//! and says only that it is shown. So a surface whose last answer was
//! that its window is occluded is hidden ([`State::hidden`]), the draw
//! says so in what it answers, and the loop tries it again when it is
//! told more, not a refresh later.
//!
//! # The picture
//!
//! A check wants the picture of what was drawn in a window; the editor
//! does not. Once it is asked for ([`State::keep_picture`]) the surface
//! is configured so that its texture may be copied from, where the
//! surface offers that, and [`State::picture`] says how each draw's is
//! read: in the order the surface's own format holds the bytes of a
//! pixel ([`order_of`]), which [`Order::rgba`] turns into a picture's,
//! red first. A surface that does not let its texture be copied from has
//! no picture, and neither has one of a format that is not four bytes a
//! pixel, one for each channel: each says so, in words of its own.

use editor_platform::NativeWindow;
use wgpu::rwh::{RawDisplayHandle, RawWindowHandle};

use crate::Image;
use crate::present::{self, Asked, Mode, Offered, Presentation};

/// The handles wgpu takes for `window`: its window's, and its display's.
///
/// The match on the port's windows is exhaustive on purpose. This crate
/// must give every one of them a surface: a window the port can name and
/// this crate cannot draw in would open and stay blank, so a new variant
/// has to be given its handles here before the crate builds.
pub(crate) fn handles(window: &NativeWindow) -> (RawWindowHandle, RawDisplayHandle) {
    use wgpu::rwh;
    match *window {
        NativeWindow::AppKit { view } => (
            RawWindowHandle::AppKit(rwh::AppKitWindowHandle::new(view)),
            RawDisplayHandle::AppKit(rwh::AppKitDisplayHandle::new()),
        ),
        NativeWindow::Xlib {
            display,
            screen,
            window,
            visual,
        } => {
            let mut handle = rwh::XlibWindowHandle::new(window);
            handle.visual_id = visual;
            (
                RawWindowHandle::Xlib(handle),
                RawDisplayHandle::Xlib(rwh::XlibDisplayHandle::new(display, screen)),
            )
        }
        NativeWindow::Wayland { display, surface } => (
            RawWindowHandle::Wayland(rwh::WaylandWindowHandle::new(surface)),
            RawDisplayHandle::Wayland(rwh::WaylandDisplayHandle::new(display)),
        ),
    }
}

/// The formats a surface is used with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Formats {
    /// The format the surface is configured with: one it offers.
    pub surface: wgpu::TextureFormat,
    /// The format its texture is drawn on through: `surface`, or its sRGB
    /// form.
    pub target: wgpu::TextureFormat,
}

/// The formats to use a surface with, from those it offers in the order it
/// offers them; `None` when it offers none.
pub(crate) fn choose_format(offered: &[wgpu::TextureFormat]) -> Option<Formats> {
    let srgb = offered.iter().copied().find(wgpu::TextureFormat::is_srgb);
    let surface = srgb.or_else(|| offered.first().copied())?;
    Some(Formats {
        surface,
        target: surface.add_srgb_suffix(),
    })
}

impl Formats {
    /// The formats the surface's texture may be seen through besides its
    /// own, which the surface is told when it is configured: `target`,
    /// when it is another than `surface`.
    pub(crate) fn views(self) -> Vec<wgpu::TextureFormat> {
        if self.target == self.surface {
            Vec::new()
        } else {
            vec![self.target]
        }
    }
}

/// wgpu's present mode by this crate's name, if it has one.
pub(crate) fn mode_of(mode: wgpu::PresentMode) -> Option<Mode> {
    match mode {
        wgpu::PresentMode::Fifo => Some(Mode::Fifo),
        wgpu::PresentMode::FifoRelaxed => Some(Mode::FifoRelaxed),
        wgpu::PresentMode::Immediate => Some(Mode::Immediate),
        wgpu::PresentMode::Mailbox => Some(Mode::Mailbox),
        _ => None,
    }
}

/// This crate's present mode as wgpu's.
pub(crate) fn wgpu_mode(mode: Mode) -> wgpu::PresentMode {
    match mode {
        Mode::Fifo => wgpu::PresentMode::Fifo,
        Mode::FifoRelaxed => wgpu::PresentMode::FifoRelaxed,
        Mode::Immediate => wgpu::PresentMode::Immediate,
        Mode::Mailbox => wgpu::PresentMode::Mailbox,
    }
}

/// What a surface answered when it was asked for its next texture, by
/// wgpu's names, without the texture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Answer {
    /// A texture.
    Success,
    /// A texture that no longer matches the surface.
    Suboptimal,
    /// No texture in time.
    Timeout,
    /// The window is occluded.
    Occluded,
    /// The surface's configuration is outdated.
    Outdated,
    /// The surface is lost.
    Lost,
    /// wgpu refused the call.
    Validation,
}

/// What to do with a surface's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Next {
    /// Draw on the texture and present it.
    Draw,
    /// Draw on the texture and present it, then configure the surface
    /// again.
    DrawThenConfigure,
    /// Configure the surface again and ask once more.
    ConfigureAndAskAgain,
    /// There is no texture: the draw is not presented.
    NotPresented,
}

/// What to do with `answer`: the table in the module docs. `asked_again`
/// says the surface was already configured again for this draw, and this
/// is its second answer.
pub(crate) fn next(answer: Answer, asked_again: bool) -> Next {
    match answer {
        Answer::Success => Next::Draw,
        Answer::Suboptimal => Next::DrawThenConfigure,
        Answer::Outdated | Answer::Lost if !asked_again => Next::ConfigureAndAskAgain,
        Answer::Outdated
        | Answer::Lost
        | Answer::Timeout
        | Answer::Occluded
        | Answer::Validation => Next::NotPresented,
    }
}

/// The calls on a surface that need a window, as [`State::acquire`] makes
/// them. The device's are wgpu's (`gpu`); a test's record what they were
/// told and answer from a script.
pub(crate) trait Calls {
    /// A texture of the surface.
    type Texture;

    /// Configures the surface as `config` says.
    fn configure(&mut self, config: &wgpu::SurfaceConfiguration);

    /// Asks the surface for its next texture: what it answered, and the
    /// texture, when the answer comes with one.
    fn next_texture(&mut self) -> (Answer, Option<Self::Texture>);
}

/// What a device knows of one window's surface: how it is to be
/// configured, whether it is, and whether its pictures are kept.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct State {
    /// How the surface is configured, or is to be: the format, the present
    /// mode and the frame latency chosen from what it offers, and the size
    /// of the last draw.
    config: wgpu::SurfaceConfiguration,
    /// The format its texture is drawn on through.
    target: wgpu::TextureFormat,
    /// Whether it is configured as `config` says. It is not before the
    /// first draw, nor after a texture that no longer fitted it.
    configured: bool,
    /// Whether its texture may be copied from, so that a picture of it can
    /// be kept.
    copies: bool,
    /// Whether the picture of each draw is kept.
    keep: bool,
    /// Whether the surface, when it was last asked for a texture, gave
    /// none because its window is occluded.
    hidden: bool,
    /// The modes it offered that this crate has a name for, in its order.
    modes: Vec<Mode>,
    /// What the run asked for: each half, if it asked for it.
    asked: Asked,
    /// Whether it has been configured once.
    configured_once: bool,
}

/// The order a surface's texture holds the bytes of a pixel in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Order {
    /// Red, green, blue, alpha: a picture's own.
    Rgba,
    /// Blue, green, red, alpha.
    Bgra,
}

impl Order {
    /// `image`, whose pixels are in this order, as a picture: red first.
    pub(crate) fn rgba(self, mut image: Image) -> Image {
        if self == Self::Bgra {
            for pixel in image.rgba.as_chunks_mut::<4>().0 {
                pixel.swap(0, 2);
            }
        }
        image
    }
}

/// The order a texture of `format` holds the bytes of a pixel in; an error
/// for a format that is not four bytes a pixel, one for each channel,
/// which is not read back as a picture.
pub(crate) fn order_of(format: wgpu::TextureFormat) -> Result<Order, String> {
    match format {
        wgpu::TextureFormat::Bgra8Unorm | wgpu::TextureFormat::Bgra8UnormSrgb => Ok(Order::Bgra),
        wgpu::TextureFormat::Rgba8Unorm | wgpu::TextureFormat::Rgba8UnormSrgb => Ok(Order::Rgba),
        other => Err(format!(
            "a surface of the format {other:?} is not read back as a picture"
        )),
    }
}

impl State {
    /// What is known of a surface that offers `offered`, before anything
    /// is drawn on it, for a run that asked for the presentation `asked`
    /// ([`present::choose`]). The error says why nothing can be.
    pub(crate) fn new(offered: &wgpu::SurfaceCapabilities, asked: Asked) -> Result<Self, String> {
        let formats = choose_format(&offered.formats)
            .ok_or("the window's surface offers no format on this adapter")?;
        if offered.present_modes.is_empty() {
            return Err("the window's surface offers no present mode on this adapter".to_owned());
        }
        let modes: Vec<Mode> = offered
            .present_modes
            .iter()
            .copied()
            .filter_map(mode_of)
            .collect();
        // A surface does not say what frame latencies it takes: wgpu holds
        // the one asked for to what the back end allows.
        let presentation = present::choose(&modes, 0..=u32::MAX, asked);
        Ok(Self {
            config: wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format: formats.surface,
                color_space: wgpu::SurfaceColorSpace::Auto,
                // The size is the first draw's: 1 by 1 stands for "not
                // yet".
                width: 1,
                height: 1,
                present_mode: wgpu_mode(presentation.mode),
                desired_maximum_frame_latency: presentation.frame_latency,
                alpha_mode: wgpu::CompositeAlphaMode::Auto,
                view_formats: formats.views(),
            },
            target: formats.target,
            configured: false,
            copies: offered.usages.contains(wgpu::TextureUsages::COPY_SRC),
            keep: false,
            hidden: false,
            modes,
            asked,
            configured_once: false,
        })
    }

    /// What the surface offered, what the run asked for and what the
    /// surface was configured with; `None` until it is first configured.
    pub(crate) fn presentation(&self) -> Option<Offered> {
        let mode = mode_of(self.config.present_mode)?;
        self.configured_once.then(|| Offered {
            modes: self.modes.clone(),
            asked: self.asked,
            configured: Presentation {
                mode,
                frame_latency: self.config.desired_maximum_frame_latency,
            },
        })
    }

    /// Whether the surface, when it was last asked for a texture, gave
    /// none because its window is occluded: nobody can see it, and a draw
    /// on it is not to be tried again until the window says more.
    pub(crate) fn hidden(&self) -> bool {
        self.hidden
    }

    /// Keeps the picture of each draw from here on: the surface is
    /// configured again before the next draw, so that its texture can be
    /// copied from, where the surface offers that. It answers whether the
    /// surface does. Where it does not there is no picture, and that is
    /// what the surface is, not a read that failed: whoever asked can tell
    /// the two apart by this answer, since [`State::picture`]'s error is
    /// words for a person.
    pub(crate) fn keep_picture(&mut self) -> bool {
        self.keep = true;
        if self.copies {
            self.config.usage |= wgpu::TextureUsages::COPY_SRC;
            self.configured = false;
        }
        self.copies
    }

    /// How the picture of a draw is taken: by copying the texture out and
    /// reading its pixels in this order. `None` when no picture is kept;
    /// an error where the surface does not let its texture be copied
    /// from, or is of a format that is not read back.
    pub(crate) fn picture(&self) -> Option<Result<Order, String>> {
        if !self.keep {
            return None;
        }
        if !self.copies {
            return Some(Err(
                "the window's surface does not let its texture be copied from".to_owned(),
            ));
        }
        Some(order_of(self.config.format))
    }

    /// The format the surface's texture is drawn on through: what the
    /// pipeline is made for.
    pub(crate) fn target(&self) -> wgpu::TextureFormat {
        self.target
    }

    /// The surface's next texture, `width` by `height`: the surface is
    /// configured first when it is not, or is of another size, and what it
    /// answers is acted on as [`next`] says. The error says why there is
    /// no texture, and the draw is then not presented.
    pub(crate) fn acquire<C: Calls>(
        &mut self,
        calls: &mut C,
        width: u32,
        height: u32,
    ) -> Result<C::Texture, String> {
        if !self.configured || (self.config.width, self.config.height) != (width, height) {
            self.config.width = width;
            self.config.height = height;
            calls.configure(&self.config);
            self.configured = true;
            self.configured_once = true;
        }
        let mut asked_again = false;
        loop {
            let (answer, texture) = calls.next_texture();
            self.hidden = answer == Answer::Occluded;
            match (next(answer, asked_again), texture) {
                (Next::Draw, Some(texture)) => return Ok(texture),
                (Next::DrawThenConfigure, Some(texture)) => {
                    // The next draw configures the surface again.
                    self.configured = false;
                    return Ok(texture);
                }
                (Next::ConfigureAndAskAgain, _) => {
                    calls.configure(&self.config);
                    asked_again = true;
                }
                _ => return Err(format!("the window's surface gave no texture: {answer:?}")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::ffi::c_void;
    use std::ptr::NonNull;

    use editor_platform::NativeWindow;
    use wgpu::TextureFormat::{
        Bgra8Unorm, Bgra8UnormSrgb, Rgba8Unorm, Rgba8UnormSrgb, Rgba16Float,
    };
    use wgpu::rwh::{RawDisplayHandle, RawWindowHandle};

    use super::{
        Answer, Calls, Formats, Next, Order, State, choose_format, handles, mode_of, next,
        order_of, wgpu_mode,
    };
    use crate::Image;
    use crate::present::{self, Asked, Mode, Offered, Presentation};

    /// A pointer to something of the test's own, never read through: a
    /// handle is only carried.
    fn pointer(to: &mut u8) -> NonNull<c_void> {
        NonNull::from(to).cast()
    }

    /// What a surface offers: `formats` and `modes`, in those orders, and
    /// that its texture may be copied from when `copies` says so.
    fn offer(
        formats: &[wgpu::TextureFormat],
        modes: &[wgpu::PresentMode],
        copies: bool,
    ) -> wgpu::SurfaceCapabilities {
        let mut usages = wgpu::TextureUsages::RENDER_ATTACHMENT;
        if copies {
            usages |= wgpu::TextureUsages::COPY_SRC;
        }
        wgpu::SurfaceCapabilities {
            formats: formats.to_vec(),
            present_modes: modes.to_vec(),
            usages,
            ..Default::default()
        }
    }

    /// What llvmpipe's surface offered under Xvfb (seen).
    fn llvmpipe() -> wgpu::SurfaceCapabilities {
        offer(
            &[Bgra8UnormSrgb, Bgra8Unorm],
            &[
                wgpu::PresentMode::Immediate,
                wgpu::PresentMode::Mailbox,
                wgpu::PresentMode::Fifo,
                wgpu::PresentMode::FifoRelaxed,
            ],
            true,
        )
    }

    /// What is known of a surface that offers `formats`, and `Fifo`.
    fn state_of(formats: &[wgpu::TextureFormat]) -> State {
        State::new(
            &offer(formats, &[wgpu::PresentMode::Fifo], true),
            Asked::NOTHING,
        )
        .expect("an offer with a format and a present mode")
    }

    /// One call made on a surface.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Call {
        /// It was configured, this far across and down.
        Configured(u32, u32),
        /// It was asked for its next texture.
        Asked,
    }

    /// A surface that is no window's: it records the calls made on it and
    /// answers each time it is asked from a script. A texture of it is a
    /// number, counted from 1.
    struct Scripted {
        /// What it answers, in order.
        answers: VecDeque<Answer>,
        /// The calls made on it, in order.
        calls: Vec<Call>,
        /// What it was configured with, each time.
        configs: Vec<wgpu::SurfaceConfiguration>,
        /// How many textures it has given.
        textures: u32,
    }

    impl Scripted {
        /// A surface that answers `answers`, in order.
        fn answering(answers: &[Answer]) -> Self {
            Self {
                answers: answers.iter().copied().collect(),
                calls: Vec::new(),
                configs: Vec::new(),
                textures: 0,
            }
        }
    }

    impl Calls for Scripted {
        type Texture = u32;

        fn configure(&mut self, config: &wgpu::SurfaceConfiguration) {
            self.calls
                .push(Call::Configured(config.width, config.height));
            self.configs.push(config.clone());
        }

        fn next_texture(&mut self) -> (Answer, Option<u32>) {
            self.calls.push(Call::Asked);
            let answer = self
                .answers
                .pop_front()
                .expect("the script has an answer for each time it is asked");
            let texture = matches!(answer, Answer::Success | Answer::Suboptimal).then(|| {
                self.textures += 1;
                self.textures
            });
            (answer, texture)
        }
    }

    #[test]
    fn a_surface_is_told_of_the_format_it_is_drawn_on_through_when_that_is_not_its_own() {
        let through_a_view = Formats {
            surface: Bgra8Unorm,
            target: Bgra8UnormSrgb,
        };
        assert_eq!(through_a_view.views(), [Bgra8UnormSrgb]);
        let as_it_is = Formats {
            surface: Bgra8UnormSrgb,
            target: Bgra8UnormSrgb,
        };
        assert_eq!(as_it_is.views(), []);
    }

    #[test]
    fn the_first_draw_configures_the_surface_at_its_size_with_what_was_chosen_from_the_offer() {
        let mut state =
            State::new(&llvmpipe(), Asked::NOTHING).expect("an offer with a format and a mode");
        let mut surface = Scripted::answering(&[Answer::Success]);
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1));
        assert_eq!(surface.calls, [Call::Configured(800, 600), Call::Asked]);
        // All a surface is told: drawn on and nothing else, the sRGB format
        // with no view, without tearing, one frame waiting.
        assert_eq!(
            surface.configs,
            [wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                format: Bgra8UnormSrgb,
                color_space: wgpu::SurfaceColorSpace::Auto,
                width: 800,
                height: 600,
                present_mode: wgpu::PresentMode::Fifo,
                desired_maximum_frame_latency: present::FRAME_LATENCY,
                alpha_mode: wgpu::CompositeAlphaMode::Auto,
                view_formats: Vec::new(),
            }]
        );
        // The pipeline is made for the format the surface has.
        assert_eq!(state.target(), Bgra8UnormSrgb);
    }

    #[test]
    fn a_mode_and_a_latency_asked_for_are_what_the_surface_is_configured_with_when_offered() {
        let asked = Asked {
            mode: Some(Mode::Immediate),
            frame_latency: Some(2),
        };
        let mut state = State::new(&llvmpipe(), asked).expect("an offer with a format");
        // Nothing is said of a surface not yet configured.
        assert_eq!(state.presentation(), None);
        let mut surface = Scripted::answering(&[Answer::Success]);
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1));
        let [config] = surface.configs.as_slice() else {
            panic!("configured once: {:?}", surface.calls);
        };
        assert_eq!(config.present_mode, wgpu::PresentMode::Immediate);
        assert_eq!(config.desired_maximum_frame_latency, 2);
        // What it offered, in its order, what was asked, and what it was
        // configured with.
        assert_eq!(
            state.presentation(),
            Some(Offered {
                modes: vec![
                    Mode::Immediate,
                    Mode::Mailbox,
                    Mode::Fifo,
                    Mode::FifoRelaxed
                ],
                asked,
                configured: Presentation {
                    mode: Mode::Immediate,
                    frame_latency: 2,
                },
            })
        );
    }

    #[test]
    fn a_mode_asked_for_that_the_surface_does_not_offer_is_not_what_it_is_configured_with() {
        let asked = Asked {
            mode: Some(Mode::Mailbox),
            frame_latency: Some(1),
        };
        let offered = offer(&[Bgra8UnormSrgb], &[wgpu::PresentMode::Fifo], false);
        let mut state = State::new(&offered, asked).expect("an offer with a format");
        let mut surface = Scripted::answering(&[Answer::Success]);
        assert_eq!(state.acquire(&mut surface, 40, 30), Ok(1));
        assert_eq!(surface.configs[0].present_mode, wgpu::PresentMode::Fifo);
        let presentation = state.presentation().expect("configured");
        assert_eq!(presentation.asked, asked);
        assert_eq!(presentation.configured.mode, Mode::Fifo);
        assert_eq!(presentation.modes, vec![Mode::Fifo]);
    }

    #[test]
    fn a_latency_asked_for_alone_is_all_that_is_said_to_have_been_asked() {
        let asked = Asked {
            mode: None,
            frame_latency: Some(2),
        };
        let mut state = State::new(&llvmpipe(), asked).expect("an offer with a format");
        let mut surface = Scripted::answering(&[Answer::Success]);
        assert_eq!(state.acquire(&mut surface, 40, 30), Ok(1));
        // The decided mode, at the latency asked.
        assert_eq!(surface.configs[0].present_mode, wgpu::PresentMode::Fifo);
        assert_eq!(surface.configs[0].desired_maximum_frame_latency, 2);
        let presentation = state.presentation().expect("configured");
        assert_eq!(presentation.asked, asked);
        assert_eq!(
            presentation.configured,
            Presentation {
                mode: Mode::Fifo,
                frame_latency: 2,
            }
        );
        // Nothing asked is said as nothing asked.
        let mut state = State::new(&llvmpipe(), Asked::NOTHING).expect("an offer with a format");
        let mut surface = Scripted::answering(&[Answer::Success]);
        assert_eq!(state.acquire(&mut surface, 40, 30), Ok(1));
        assert_eq!(
            state.presentation().map(|offered| offered.asked),
            Some(Asked::NOTHING)
        );
    }

    #[test]
    fn a_surface_with_no_srgb_format_is_drawn_on_through_a_view_of_its_srgb_form() {
        let mut state = state_of(&[Bgra8Unorm, Rgba8Unorm]);
        let mut surface = Scripted::answering(&[Answer::Success]);
        assert_eq!(state.acquire(&mut surface, 40, 30), Ok(1));
        let [config] = surface.configs.as_slice() else {
            panic!("configured once: {:?}", surface.calls);
        };
        assert_eq!(config.format, Bgra8Unorm);
        assert_eq!(config.view_formats, [Bgra8UnormSrgb]);
        // The pipeline is made for the view's format, not the surface's.
        assert_eq!(state.target(), Bgra8UnormSrgb);
    }

    #[test]
    fn a_surface_of_a_format_with_no_srgb_form_is_drawn_on_as_it_is_with_no_view() {
        let mut state = state_of(&[Rgba16Float]);
        let mut surface = Scripted::answering(&[Answer::Success]);
        assert_eq!(state.acquire(&mut surface, 40, 30), Ok(1));
        let [config] = surface.configs.as_slice() else {
            panic!("configured once: {:?}", surface.calls);
        };
        assert_eq!(config.format, Rgba16Float);
        assert_eq!(config.view_formats, []);
        assert_eq!(state.target(), Rgba16Float);
    }

    #[test]
    fn a_surface_that_offers_no_format_or_no_present_mode_is_refused_and_says_which() {
        let fifo = [wgpu::PresentMode::Fifo];
        assert_eq!(
            State::new(&offer(&[], &fifo, true), Asked::NOTHING),
            Err("the window's surface offers no format on this adapter".to_owned())
        );
        assert_eq!(
            State::new(&offer(&[Bgra8UnormSrgb], &[], true), Asked::NOTHING),
            Err("the window's surface offers no present mode on this adapter".to_owned())
        );
        // What wgpu gives for a surface its adapter cannot present to:
        // nothing of either.
        assert_eq!(
            State::new(&wgpu::SurfaceCapabilities::default(), Asked::NOTHING),
            Err("the window's surface offers no format on this adapter".to_owned())
        );
    }

    #[test]
    fn a_surface_is_configured_again_only_for_a_draw_of_another_size() {
        let mut state = state_of(&[Bgra8UnormSrgb]);
        let mut surface = Scripted::answering(&[Answer::Success; 4]);
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1));
        // The same size: it is as it was configured.
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(2));
        // Another, and that one again.
        assert_eq!(state.acquire(&mut surface, 300, 120), Ok(3));
        assert_eq!(state.acquire(&mut surface, 300, 120), Ok(4));
        assert_eq!(
            surface.calls,
            [
                Call::Configured(800, 600),
                Call::Asked,
                Call::Asked,
                Call::Configured(300, 120),
                Call::Asked,
                Call::Asked,
            ]
        );
        // Only the size is another.
        let [first, second] = surface.configs.as_slice() else {
            panic!("configured twice: {:?}", surface.calls);
        };
        assert_eq!(
            *second,
            wgpu::SurfaceConfiguration {
                width: 300,
                height: 120,
                ..first.clone()
            }
        );
    }

    #[test]
    fn a_texture_that_no_longer_fits_is_drawn_on_and_the_next_draw_configures_the_surface_first() {
        let mut state = state_of(&[Bgra8UnormSrgb]);
        let mut surface =
            Scripted::answering(&[Answer::Suboptimal, Answer::Success, Answer::Success]);
        // The texture is given all the same, and nothing is configured
        // while it is held.
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1));
        assert_eq!(surface.calls, [Call::Configured(800, 600), Call::Asked]);
        // The next draw, of the same size, configures first; the one after
        // does not.
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(2));
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(3));
        assert_eq!(
            surface.calls[2..],
            [Call::Configured(800, 600), Call::Asked, Call::Asked]
        );
    }

    #[test]
    fn an_outdated_or_lost_surface_is_configured_again_at_the_same_size_and_asked_once_more() {
        for answer in [Answer::Outdated, Answer::Lost] {
            let mut state = state_of(&[Bgra8UnormSrgb]);
            let mut surface = Scripted::answering(&[Answer::Success, answer, Answer::Success]);
            assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1));
            assert_eq!(state.acquire(&mut surface, 800, 600), Ok(2), "{answer:?}");
            assert_eq!(
                surface.calls[2..],
                [Call::Asked, Call::Configured(800, 600), Call::Asked],
                "{answer:?}"
            );
            // With what it was configured with before.
            assert_eq!(surface.configs[1], surface.configs[0], "{answer:?}");
        }
    }

    #[test]
    fn a_surface_still_outdated_or_lost_once_configured_again_gives_no_texture_and_says_why() {
        for (answer, name) in [(Answer::Outdated, "Outdated"), (Answer::Lost, "Lost")] {
            let mut state = state_of(&[Bgra8UnormSrgb]);
            let mut surface = Scripted::answering(&[answer, answer, answer, Answer::Success]);
            assert_eq!(
                state.acquire(&mut surface, 800, 600),
                Err(format!("the window's surface gave no texture: {name}"))
            );
            // Asked twice, and no more: the script's third answer is left.
            assert_eq!(
                surface.calls,
                [
                    Call::Configured(800, 600),
                    Call::Asked,
                    Call::Configured(800, 600),
                    Call::Asked,
                ]
            );
            // The next draw tries as a first one does: asked, configured
            // again, asked once more.
            assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1), "{name}");
            assert_eq!(
                surface.calls[4..],
                [Call::Asked, Call::Configured(800, 600), Call::Asked]
            );
        }
    }

    #[test]
    fn a_surface_that_is_occluded_times_out_or_is_refused_is_asked_once_and_says_which() {
        for (answer, name) in [
            (Answer::Occluded, "Occluded"),
            (Answer::Timeout, "Timeout"),
            (Answer::Validation, "Validation"),
        ] {
            let mut state = state_of(&[Bgra8UnormSrgb]);
            let mut surface = Scripted::answering(&[answer, Answer::Success]);
            assert_eq!(
                state.acquire(&mut surface, 800, 600),
                Err(format!("the window's surface gave no texture: {name}"))
            );
            assert_eq!(surface.calls, [Call::Configured(800, 600), Call::Asked]);
            // It stays configured: the next draw only asks.
            assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1), "{name}");
            assert_eq!(surface.calls[2..], [Call::Asked]);
        }
    }

    #[test]
    fn a_surface_whose_last_answer_was_that_its_window_is_occluded_is_hidden() {
        let mut state = state_of(&[Bgra8UnormSrgb]);
        // Nothing is known of a surface nobody has asked.
        assert!(!state.hidden());
        let mut surface = Scripted::answering(&[
            Answer::Occluded,
            Answer::Occluded,
            Answer::Success,
            Answer::Occluded,
            Answer::Timeout,
            Answer::Occluded,
            Answer::Validation,
            // Outdated, and occluded once it is configured again.
            Answer::Outdated,
            Answer::Occluded,
            // Outdated, and still outdated.
            Answer::Outdated,
            Answer::Outdated,
        ]);
        let mut hidden_after = |surface: &mut Scripted| {
            let _ = state.acquire(surface, 800, 600);
            state.hidden()
        };
        // Occluded, and still occluded when it is asked again.
        assert!(hidden_after(&mut surface));
        assert!(hidden_after(&mut surface));
        // It gives a texture: it is seen.
        assert!(!hidden_after(&mut surface));
        // No other reason for no texture says the window is hidden.
        assert!(hidden_after(&mut surface));
        assert!(!hidden_after(&mut surface), "Timeout");
        assert!(hidden_after(&mut surface));
        assert!(!hidden_after(&mut surface), "Validation");
        assert!(hidden_after(&mut surface), "Outdated, then Occluded");
        assert!(!hidden_after(&mut surface), "Outdated twice");
    }

    #[test]
    fn no_picture_is_taken_of_a_surface_until_one_is_asked_for() {
        let state =
            State::new(&llvmpipe(), Asked::NOTHING).expect("an offer with a format and a mode");
        assert_eq!(state.picture(), None);
    }

    #[test]
    fn keeping_the_picture_configures_the_surface_again_so_that_its_texture_is_copied_from() {
        let mut state =
            State::new(&llvmpipe(), Asked::NOTHING).expect("an offer with a format and a mode");
        let mut surface = Scripted::answering(&[Answer::Success; 3]);
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1));
        state.keep_picture();
        // The next draw, of the same size, configures first; the one after
        // does not.
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(2));
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(3));
        assert_eq!(
            surface.calls,
            [
                Call::Configured(800, 600),
                Call::Asked,
                Call::Configured(800, 600),
                Call::Asked,
                Call::Asked,
            ]
        );
        // Drawn on and copied from, and nothing else is another.
        assert_eq!(
            surface.configs[1],
            wgpu::SurfaceConfiguration {
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
                ..surface.configs[0].clone()
            }
        );
        assert_eq!(state.picture(), Some(Ok(Order::Bgra)));
    }

    #[test]
    fn a_surface_whose_texture_cannot_be_copied_from_is_left_as_it_is_and_its_picture_says_so() {
        let offered = offer(&[Bgra8UnormSrgb], &[wgpu::PresentMode::Fifo], false);
        let mut state =
            State::new(&offered, Asked::NOTHING).expect("an offer with a format and a mode");
        let mut surface = Scripted::answering(&[Answer::Success; 2]);
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(1));
        state.keep_picture();
        assert_eq!(state.acquire(&mut surface, 800, 600), Ok(2));
        // It is not configured for a use it does not offer.
        assert_eq!(
            surface.calls,
            [Call::Configured(800, 600), Call::Asked, Call::Asked]
        );
        assert_eq!(
            state.picture(),
            Some(Err(
                "the window's surface does not let its texture be copied from".to_owned()
            ))
        );
    }

    #[test]
    fn keeping_the_picture_says_whether_the_surface_lets_its_texture_be_copied_from() {
        let mut copied_from =
            State::new(&llvmpipe(), Asked::NOTHING).expect("an offer with a format and a mode");
        assert!(copied_from.keep_picture());
        let offered = offer(&[Bgra8UnormSrgb], &[wgpu::PresentMode::Fifo], false);
        let mut not_copied_from =
            State::new(&offered, Asked::NOTHING).expect("an offer with a format and a mode");
        assert!(!not_copied_from.keep_picture());
        // Asked again, the same.
        assert!(copied_from.keep_picture());
        assert!(!not_copied_from.keep_picture());
        // It says nothing of the format: a surface that is copied from and
        // is of a format that is not read back answers yes, and it is its
        // picture that says why there is none.
        let mut not_read_back = state_of(&[Rgba16Float]);
        assert!(not_read_back.keep_picture());
        assert!(matches!(not_read_back.picture(), Some(Err(_))));
    }

    #[test]
    fn a_picture_is_read_in_the_order_the_surfaces_format_holds_a_pixel_in() {
        for (format, order) in [
            (Bgra8Unorm, Order::Bgra),
            (Bgra8UnormSrgb, Order::Bgra),
            (Rgba8Unorm, Order::Rgba),
            (Rgba8UnormSrgb, Order::Rgba),
        ] {
            assert_eq!(order_of(format), Ok(order), "{format:?}");
            let mut state = state_of(&[format]);
            state.keep_picture();
            assert_eq!(state.picture(), Some(Ok(order)), "{format:?}");
        }
        // The surface's own format says, not the view it is drawn on
        // through: this one is `Bgra8Unorm` seen as `Bgra8UnormSrgb`.
        let mut through_a_view = state_of(&[Bgra8Unorm, Rgba8Unorm]);
        through_a_view.keep_picture();
        assert_eq!(through_a_view.picture(), Some(Ok(Order::Bgra)));
    }

    #[test]
    fn a_surface_of_a_format_that_is_not_four_bytes_a_pixel_is_not_read_back_and_says_so() {
        let refusal = "a surface of the format Rgba16Float is not read back as a picture";
        assert_eq!(order_of(Rgba16Float), Err(refusal.to_owned()));
        let mut state = state_of(&[Rgba16Float]);
        state.keep_picture();
        assert_eq!(state.picture(), Some(Err(refusal.to_owned())));
    }

    #[test]
    fn a_picture_held_blue_first_has_red_and_blue_changed_over_and_one_held_red_first_is_left() {
        let held = Image {
            width: 2,
            height: 1,
            rgba: vec![1, 2, 3, 4, 5, 6, 7, 8],
        };
        assert_eq!(
            Order::Bgra.rgba(held.clone()),
            Image {
                width: 2,
                height: 1,
                rgba: vec![3, 2, 1, 4, 7, 6, 5, 8],
            }
        );
        assert_eq!(Order::Rgba.rgba(held.clone()), held);
    }

    #[test]
    fn an_appkit_window_is_handed_to_wgpu_as_its_view() {
        let mut view = 0;
        let view = pointer(&mut view);
        let (window, display) = handles(&NativeWindow::AppKit { view });
        let RawWindowHandle::AppKit(window) = window else {
            panic!("not an AppKit window: {window:?}");
        };
        assert_eq!(window.ns_view, view);
        assert!(matches!(display, RawDisplayHandle::AppKit(_)));
    }

    #[test]
    fn an_xlib_window_is_handed_to_wgpu_with_its_display_its_screen_and_its_visual() {
        let mut display = 0;
        let display = pointer(&mut display);
        let (window, given) = handles(&NativeWindow::Xlib {
            display: Some(display),
            screen: 2,
            window: 4_194_306,
            visual: 33,
        });
        let RawWindowHandle::Xlib(window) = window else {
            panic!("not an Xlib window: {window:?}");
        };
        assert_eq!((window.window, window.visual_id), (4_194_306, 33));
        let RawDisplayHandle::Xlib(given) = given else {
            panic!("not an Xlib display: {given:?}");
        };
        assert_eq!((given.display, given.screen), (Some(display), 2));
    }

    #[test]
    fn a_wayland_window_is_handed_to_wgpu_as_its_surface_and_its_display() {
        let (mut display, mut surface) = (0, 0);
        let (display, surface) = (pointer(&mut display), pointer(&mut surface));
        let (window, given) = handles(&NativeWindow::Wayland { display, surface });
        let RawWindowHandle::Wayland(window) = window else {
            panic!("not a Wayland window: {window:?}");
        };
        assert_eq!(window.surface, surface);
        let RawDisplayHandle::Wayland(given) = given else {
            panic!("not a Wayland display: {given:?}");
        };
        assert_eq!(given.display, display);
    }

    #[test]
    fn an_srgb_format_is_chosen_wherever_it_is_in_the_offer() {
        // What wgpu's Metal back end offers, in its order (read in wgpu's
        // source): the first is not sRGB.
        assert_eq!(
            choose_format(&[Bgra8Unorm, Bgra8UnormSrgb, Rgba16Float]),
            Some(Formats {
                surface: Bgra8UnormSrgb,
                target: Bgra8UnormSrgb,
            })
        );
        // What llvmpipe's surface offered under Xvfb (seen).
        assert_eq!(
            choose_format(&[Bgra8UnormSrgb, Bgra8Unorm]),
            Some(Formats {
                surface: Bgra8UnormSrgb,
                target: Bgra8UnormSrgb,
            })
        );
        // The first of two sRGB formats, and one that is last of all.
        assert_eq!(
            choose_format(&[Rgba8Unorm, Rgba8UnormSrgb, Bgra8UnormSrgb]),
            Some(Formats {
                surface: Rgba8UnormSrgb,
                target: Rgba8UnormSrgb,
            })
        );
        assert_eq!(
            choose_format(&[Rgba16Float, Bgra8Unorm, Rgba8UnormSrgb]),
            Some(Formats {
                surface: Rgba8UnormSrgb,
                target: Rgba8UnormSrgb,
            })
        );
    }

    #[test]
    fn with_no_srgb_format_the_first_is_taken_with_its_srgb_view() {
        assert_eq!(
            choose_format(&[Bgra8Unorm, Rgba8Unorm]),
            Some(Formats {
                surface: Bgra8Unorm,
                target: Bgra8UnormSrgb,
            })
        );
        assert_eq!(
            choose_format(&[Rgba8Unorm]),
            Some(Formats {
                surface: Rgba8Unorm,
                target: Rgba8UnormSrgb,
            })
        );
        // A format with no sRGB form is drawn on as it is.
        assert_eq!(
            choose_format(&[Rgba16Float, Bgra8Unorm]),
            Some(Formats {
                surface: Rgba16Float,
                target: Rgba16Float,
            })
        );
    }

    #[test]
    fn a_surface_that_offers_no_format_has_none() {
        assert_eq!(choose_format(&[]), None);
    }

    #[test]
    fn each_present_mode_is_wgpus_of_the_same_name_and_back() {
        for (mode, wgpu) in [
            (Mode::Fifo, wgpu::PresentMode::Fifo),
            (Mode::FifoRelaxed, wgpu::PresentMode::FifoRelaxed),
            (Mode::Immediate, wgpu::PresentMode::Immediate),
            (Mode::Mailbox, wgpu::PresentMode::Mailbox),
        ] {
            assert_eq!(mode_of(wgpu), Some(mode));
            assert_eq!(wgpu_mode(mode), wgpu);
        }
        // wgpu's two modes that stand for "whichever", which a surface does
        // not offer, have no name here.
        assert_eq!(mode_of(wgpu::PresentMode::AutoVsync), None);
        assert_eq!(mode_of(wgpu::PresentMode::AutoNoVsync), None);
    }

    #[test]
    fn what_llvmpipes_surface_offered_is_presented_fifo_and_not_wgpus_default() {
        // The modes llvmpipe's surface offered under Xvfb, in its order
        // (seen); wgpu's default configuration there was the first.
        let offered: Vec<Mode> = [
            wgpu::PresentMode::Immediate,
            wgpu::PresentMode::Mailbox,
            wgpu::PresentMode::Fifo,
            wgpu::PresentMode::FifoRelaxed,
        ]
        .into_iter()
        .filter_map(mode_of)
        .collect();
        assert_eq!(offered.len(), 4);
        let chosen = present::choose(&offered, 0..=u32::MAX, Asked::NOTHING);
        assert_eq!(wgpu_mode(chosen.mode), wgpu::PresentMode::Fifo);
    }

    #[test]
    fn a_texture_is_drawn_on_and_one_that_no_longer_fits_is_drawn_on_and_the_surface_configured() {
        for asked_again in [false, true] {
            assert_eq!(next(Answer::Success, asked_again), Next::Draw);
            assert_eq!(
                next(Answer::Suboptimal, asked_again),
                Next::DrawThenConfigure
            );
        }
    }

    #[test]
    fn an_outdated_or_lost_surface_is_configured_again_and_tried_once() {
        for answer in [Answer::Outdated, Answer::Lost] {
            assert_eq!(next(answer, false), Next::ConfigureAndAskAgain);
            // The same answer from the surface configured again: once is
            // all it is tried.
            assert_eq!(next(answer, true), Next::NotPresented);
        }
    }

    #[test]
    fn an_occluded_surface_is_not_presented_to() {
        for asked_again in [false, true] {
            assert_eq!(next(Answer::Occluded, asked_again), Next::NotPresented);
            // Nor one that timed out, nor one wgpu refused to ask.
            assert_eq!(next(Answer::Timeout, asked_again), Next::NotPresented);
            assert_eq!(next(Answer::Validation, asked_again), Next::NotPresented);
        }
    }
}
