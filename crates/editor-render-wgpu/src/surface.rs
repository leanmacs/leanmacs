//! A window's surface: what is decided about one, as pure functions.
//!
//! The calls that make a surface, configure it, take its next texture and
//! present it are the device's (`gpu`), and need a window: no test in the
//! gate reaches them. What those calls are told, and what is done with
//! their answers, is decided here, on plain values a test builds.
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
//! [`present::choose`](crate::present::choose) decides, from the modes a
//! surface offers. [`mode_of`] and [`wgpu_mode`] are that module's names
//! for wgpu's modes and back. wgpu's own default is not taken: on a
//! surface that offers a mode that tears, it is that mode.
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
//! (`editor-render`'s `render_loop`).

use editor_platform::NativeWindow;
use wgpu::rwh::{RawDisplayHandle, RawWindowHandle};

use crate::present::Mode;

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

#[cfg(test)]
mod tests {
    use std::ffi::c_void;
    use std::ptr::NonNull;

    use editor_platform::NativeWindow;
    use wgpu::TextureFormat::{
        Bgra8Unorm, Bgra8UnormSrgb, Rgba8Unorm, Rgba8UnormSrgb, Rgba16Float,
    };
    use wgpu::rwh::{RawDisplayHandle, RawWindowHandle};

    use super::{Answer, Formats, Next, choose_format, handles, mode_of, next, wgpu_mode};
    use crate::present::{self, Mode};

    /// A pointer to something of the test's own, never read through: a
    /// handle is only carried.
    fn pointer(to: &mut u8) -> NonNull<c_void> {
        NonNull::from(to).cast()
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
        let chosen = present::choose(&offered, 0..=u32::MAX);
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
