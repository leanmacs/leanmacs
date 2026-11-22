//! The window's title bar: how the window is opened for the options'
//! [`TitleBar`], and how far down the title bar covers the drawable area,
//! as the port's `Resize::top_inset` says it.
//!
//! **How the window is opened** is [`attributes`], a pure function of the
//! options. On macOS a [`TitleBar::Themed`] window opens with a
//! transparent title bar and a full-size content view (winit's
//! `WindowAttributesMacOS::with_titlebar_transparent` and
//! `with_fullsize_content_view`), so what is drawn in the window shows
//! under the title bar, which still shows the window's title and its
//! buttons, in the appearance the window was last asked. A
//! [`TitleBar::Standard`] window opens with winit's own defaults. Off
//! macOS no platform attributes are given, so every window opens with the
//! system's own title bar. winit has no way to change either under an
//! open window, and restores its saved style on fullscreen transitions,
//! so the title bar is chosen when the window opens and kept for the run.
//!
//! **How far down the title bar covers the window** is [`top_inset`], a
//! pure function of the window's [`Shape`]:
//!
//! - **in fullscreen, 0**: no title bar covers the content;
//! - **off macOS, or with the standard title bar, 0**: the title bar is
//!   above the drawable area;
//! - **on macOS, themed, outside fullscreen, the system's reading rounded
//!   up** when it is a finite number above 0, and [`FALLBACK_POINTS`] when
//!   it is not.
//!
//! The reading is winit's public `Window::safe_area`, whose top inset
//! winit-appkit reads from `-[NSView safeAreaInsets]`: for a full-size
//! content view that includes the title bar. The handler divides it by the
//! scale factor (`title_reading` in `lib.rs`), with no decision in it. So
//! this module names winit only, and `corner`, `delegate`, `menu_bar` and
//! `background` stay the only modules that name AppKit.

use editor_platform::{TitleBar, WindowOptions};
use winit::window::WindowAttributes;

use crate::WinitPlatform;
use crate::corner::Shape;

/// How far down the title bar covers a themed window's content on macOS
/// when the system gives no reading above 0, in logical points.
///
/// Measured, not chosen: the system's own reading of winit's window with
/// the themed title bar (title bar only, no toolbar), taken on 2026-11-16
/// on a Mac17,7 (arm64) running macOS 27.2 (26B123) by `mise run
/// window-contract` with this constant set to 0 for the run. The content
/// view's `safeAreaInsets` read top 32 (left, right and bottom 0), and
/// every resize the run printed said `fullscreen false corner 16 top 32`.
/// `docs/dev-practices/on-demand-checks.md`, "The title bar's top inset,
/// measured", says how to measure it again.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) const FALLBACK_POINTS: u32 = 32;

/// The attributes a window is opened with for `options`: the platform's
/// title, and on macOS the title bar the options ask for.
pub(crate) fn attributes(options: WindowOptions) -> WindowAttributes {
    let attributes = WindowAttributes::default().with_title(WinitPlatform::TITLE);
    #[cfg(target_os = "macos")]
    let attributes = attributes.with_platform_attributes(Box::new(macos(options.title_bar)));
    #[cfg(not(target_os = "macos"))]
    let _ = options;
    attributes
}

/// winit's macOS attributes for `title_bar`: a transparent title bar over
/// a full-size content view when it is themed, and winit's defaults when
/// it is standard.
#[cfg(target_os = "macos")]
pub(crate) fn macos(title_bar: TitleBar) -> winit::platform::macos::WindowAttributesMacOS {
    use winit::platform::macos::WindowAttributesMacOS;
    match title_bar {
        TitleBar::Themed => WindowAttributesMacOS::default()
            .with_titlebar_transparent(true)
            .with_fullsize_content_view(true),
        TitleBar::Standard => WindowAttributesMacOS::default(),
    }
}

/// How far down the title bar of a window that reads as `shape` covers its
/// content, in whole logical points, as the module docs decide it.
pub(crate) fn top_inset(shape: Shape) -> u32 {
    if shape.fullscreen || shape.title_bar == TitleBar::Standard {
        return 0;
    }
    if cfg!(target_os = "macos") {
        return shape
            .top
            .filter(|points| points.is_finite() && *points > 0.0)
            .map_or(FALLBACK_POINTS, crate::corner::points_up);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the system may read, including what it should never give.
    const READINGS: [Option<f64>; 6] = [
        None,
        Some(0.0),
        Some(-1.0),
        Some(27.5),
        Some(f64::NAN),
        Some(f64::INFINITY),
    ];

    /// A window that reads as `fullscreen` or not, with `title_bar`, whose
    /// title bar the system reads as covering `top` points.
    fn shape(fullscreen: bool, title_bar: TitleBar, top: Option<f64>) -> Shape {
        Shape {
            fullscreen,
            corner: None,
            top,
            title_bar,
        }
    }

    #[test]
    fn the_window_opens_with_the_platform_title() {
        for title_bar in [TitleBar::Themed, TitleBar::Standard] {
            let options = WindowOptions {
                title_bar,
                ..WindowOptions::default()
            };
            assert_eq!(attributes(options).title, WinitPlatform::TITLE);
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_themed_title_bar_opens_transparent_with_a_full_size_content_view_on_macos() {
        use winit::platform::macos::WindowAttributesMacOS;
        let attributes = attributes(WindowOptions::default());
        let given = attributes
            .platform
            .as_deref()
            .and_then(|platform| platform.cast_ref::<WindowAttributesMacOS>());
        assert_eq!(
            given,
            Some(
                &WindowAttributesMacOS::default()
                    .with_titlebar_transparent(true)
                    .with_fullsize_content_view(true)
            )
        );
        assert_ne!(given, Some(&WindowAttributesMacOS::default()));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_standard_title_bar_opens_with_winits_default_macos_attributes() {
        use winit::platform::macos::WindowAttributesMacOS;
        let attributes = attributes(WindowOptions {
            title_bar: TitleBar::Standard,
            ..WindowOptions::default()
        });
        let given = attributes
            .platform
            .as_deref()
            .and_then(|platform| platform.cast_ref::<WindowAttributesMacOS>());
        assert_eq!(given, Some(&WindowAttributesMacOS::default()));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn off_macos_no_platform_attributes_are_given() {
        for title_bar in [TitleBar::Themed, TitleBar::Standard] {
            let attributes = attributes(WindowOptions {
                title_bar,
                ..WindowOptions::default()
            });
            assert!(attributes.platform.is_none(), "{title_bar:?}");
        }
    }

    #[test]
    fn in_fullscreen_the_top_inset_is_0() {
        for title_bar in [TitleBar::Themed, TitleBar::Standard] {
            for top in READINGS {
                assert_eq!(
                    top_inset(shape(true, title_bar, top)),
                    0,
                    "{title_bar:?} read {top:?}"
                );
            }
        }
    }

    #[test]
    fn a_standard_title_bar_has_a_top_inset_of_0() {
        for top in READINGS {
            assert_eq!(
                top_inset(shape(false, TitleBar::Standard, top)),
                0,
                "read {top:?}"
            );
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn a_themed_title_bar_on_macos_reads_the_system_rounded_up_and_falls_back_when_it_reads_nothing()
     {
        for top in [
            None,
            Some(0.0),
            Some(-1.0),
            Some(f64::NAN),
            Some(f64::INFINITY),
        ] {
            let given = top_inset(shape(false, TitleBar::Themed, top));
            assert!(given > 0, "read {top:?}, the top inset is {given}");
            assert_eq!(given, FALLBACK_POINTS, "read {top:?}");
        }
        assert_eq!(top_inset(shape(false, TitleBar::Themed, Some(27.5))), 28);
        assert_eq!(top_inset(shape(false, TitleBar::Themed, Some(32.0))), 32);
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn off_macos_the_top_inset_is_0() {
        for top in READINGS {
            assert_eq!(
                top_inset(shape(false, TitleBar::Themed, top)),
                0,
                "read {top:?}"
            );
        }
    }
}
