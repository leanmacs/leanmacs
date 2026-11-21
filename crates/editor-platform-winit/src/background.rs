//! The window's background: the colour the window shows wherever nothing
//! drew, as the port's `Request::Background` asks.
//!
//! On macOS it is the `NSWindow`'s `backgroundColor`, which shows behind
//! the content view: during a live resize, wherever the Metal layer the
//! renderer draws on has not yet grown to the view's new size, and before
//! the first frame. winit sets none for an opaque window, so it is
//! `windowBackgroundColor` until it is asked, a dark grey under the dark
//! appearance. It is set with `colorWithSRGBRed:green:blue:alpha:` at
//! alpha 1, so the bytes asked are sRGB values, as the renderer's are.
//! This is what Zed does with its own colour behind its layer.
//!
//! Off macOS it does nothing: winit has no setter for it, and the
//! renderer's clear, the frame's ground, covers the drawable.
//!
//! [`set`] is one call into AppKit with no decision in it; whether to set
//! it is `asked`'s (`Asked::act`), and what the bytes come to is
//! [`components`], which is pure.

use editor_platform::Rgb;
use winit::window::Window;

/// The components AppKit is given for `rgb`: red, green and blue over 255,
/// and alpha 1.
pub(crate) fn components(rgb: Rgb) -> [f64; 4] {
    let over = |byte: u8| f64::from(byte) / 255.0;
    [over(rgb.red), over(rgb.green), over(rgb.blue), 1.0]
}

/// Sets `window`'s background to `rgb`: on macOS, over the `NSWindow` of
/// the AppKit view its raw handle gives; nothing elsewhere, or for a
/// window with no such view.
pub(crate) fn set(window: &dyn Window, rgb: Rgb) {
    #[cfg(target_os = "macos")]
    if let Some(editor_platform::NativeWindow::AppKit { view }) = crate::native_window(window) {
        set_on(view, rgb);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (window, rgb);
}

/// Sets the background of the window whose AppKit content view is `view`.
///
/// It is called on the main thread only, with the view of a window that is
/// still open, which is what the window's raw handle gives while the loop
/// runs.
#[cfg(target_os = "macos")]
fn set_on(view: std::ptr::NonNull<std::ffi::c_void>, rgb: Rgb) {
    use objc2_app_kit::{NSColor, NSView};

    // SAFETY: winit's AppKit window handle gives its `NSView`, which lives
    // as long as the window, and this is called on the main thread while
    // the window is open.
    let view: &NSView = unsafe { view.cast::<NSView>().as_ref() };
    let Some(window) = view.window() else {
        return;
    };
    let [red, green, blue, alpha] = components(rgb);
    let color = NSColor::colorWithSRGBRed_green_blue_alpha(red, green, blue, alpha);
    window.setBackgroundColor(Some(&color));
}

#[cfg(test)]
mod tests {
    use super::components;
    use editor_platform::Rgb;

    #[test]
    fn a_colour_is_given_to_appkit_as_its_bytes_over_255_and_opaque() {
        let paper = Rgb {
            red: 0x2e,
            green: 0x34,
            blue: 0x40,
        };
        assert_eq!(
            components(paper),
            [
                f64::from(0x2e_u8) / 255.0,
                f64::from(0x34_u8) / 255.0,
                f64::from(0x40_u8) / 255.0,
                1.0
            ]
        );
        let white = Rgb {
            red: 255,
            green: 255,
            blue: 255,
        };
        assert_eq!(components(white), [1.0; 4]);
    }
}
