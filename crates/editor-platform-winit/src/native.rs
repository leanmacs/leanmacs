//! The window as the system knows it: winit's raw handles as the port's
//! [`NativeWindow`].
//!
//! winit hands out a window's handles as values of the `raw-window-handle`
//! crate, which it re-exports. The port names no library, so they cross as
//! its own plain data: the same pointers and numbers, by the system that
//! defines them. The renderer turns them back into the handles its own
//! library takes, through that library's re-export, so this crate and that
//! one each reach `raw-window-handle` through the library it already has,
//! and neither depends on it (`deny.toml`).
//!
//! A handle the port has no variant for is no native window: the window
//! runs and reports as before, and nothing can draw in it. The kinds of
//! handle are not matched exhaustively: the crate adds kinds, and one it
//! adds is no native window until the port has a variant for it.

use editor_platform::NativeWindow;
use winit::raw_window_handle::{RawDisplayHandle, RawWindowHandle};

/// The window with these handles as the port names it, if it can.
pub(crate) fn native(window: RawWindowHandle, display: RawDisplayHandle) -> Option<NativeWindow> {
    match (window, display) {
        (RawWindowHandle::AppKit(window), RawDisplayHandle::AppKit(_)) => {
            Some(NativeWindow::AppKit {
                view: window.ns_view,
            })
        }
        (RawWindowHandle::Xlib(window), RawDisplayHandle::Xlib(display)) => {
            Some(NativeWindow::Xlib {
                display: display.display,
                screen: display.screen,
                window: window.window,
                visual: window.visual_id,
            })
        }
        (RawWindowHandle::Wayland(window), RawDisplayHandle::Wayland(display)) => {
            Some(NativeWindow::Wayland {
                display: display.display,
                surface: window.surface,
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::native;
    use editor_platform::NativeWindow;
    use std::ffi::c_void;
    use std::num::NonZeroU32;
    use std::ptr::NonNull;
    use winit::raw_window_handle::{
        AppKitDisplayHandle, AppKitWindowHandle, RawDisplayHandle, RawWindowHandle,
        WaylandDisplayHandle, WaylandWindowHandle, XcbDisplayHandle, XcbWindowHandle,
        XlibDisplayHandle, XlibWindowHandle,
    };

    /// A pointer to something of the test's own, never read through: a
    /// handle is only carried.
    fn pointer(to: &mut u8) -> NonNull<c_void> {
        NonNull::from(to).cast()
    }

    #[test]
    fn an_appkit_window_is_its_view() {
        let mut view = 0;
        let view = pointer(&mut view);
        assert_eq!(
            native(
                RawWindowHandle::AppKit(AppKitWindowHandle::new(view)),
                RawDisplayHandle::AppKit(AppKitDisplayHandle::new()),
            ),
            Some(NativeWindow::AppKit { view })
        );
    }

    #[test]
    fn an_xlib_window_is_its_display_its_screen_its_id_and_its_visual() {
        let mut display = 0;
        let display = pointer(&mut display);
        let mut window = XlibWindowHandle::new(4_194_306);
        window.visual_id = 33;
        assert_eq!(
            native(
                RawWindowHandle::Xlib(window),
                RawDisplayHandle::Xlib(XlibDisplayHandle::new(Some(display), 2)),
            ),
            Some(NativeWindow::Xlib {
                display: Some(display),
                screen: 2,
                window: 4_194_306,
                visual: 33,
            })
        );
        // A display the platform does not name stays unnamed, and a visual
        // it does not know stays 0.
        assert_eq!(
            native(
                RawWindowHandle::Xlib(XlibWindowHandle::new(7)),
                RawDisplayHandle::Xlib(XlibDisplayHandle::new(None, 0)),
            ),
            Some(NativeWindow::Xlib {
                display: None,
                screen: 0,
                window: 7,
                visual: 0,
            })
        );
    }

    #[test]
    fn a_wayland_window_is_its_display_and_its_surface() {
        let (mut display, mut surface) = (0, 0);
        let (display, surface) = (pointer(&mut display), pointer(&mut surface));
        assert_eq!(
            native(
                RawWindowHandle::Wayland(WaylandWindowHandle::new(surface)),
                RawDisplayHandle::Wayland(WaylandDisplayHandle::new(display)),
            ),
            Some(NativeWindow::Wayland { display, surface })
        );
    }

    #[test]
    fn a_handle_the_port_has_no_variant_for_is_no_native_window() {
        let window = NonZeroU32::new(9).expect("9 is not 0");
        assert_eq!(
            native(
                RawWindowHandle::Xcb(XcbWindowHandle::new(window)),
                RawDisplayHandle::Xcb(XcbDisplayHandle::new(None, 0)),
            ),
            None
        );
    }

    #[test]
    fn a_window_and_a_display_of_two_systems_are_no_native_window() {
        let mut surface = 0;
        assert_eq!(
            native(
                RawWindowHandle::Wayland(WaylandWindowHandle::new(pointer(&mut surface))),
                RawDisplayHandle::Xlib(XlibDisplayHandle::new(None, 0)),
            ),
            None
        );
        assert_eq!(
            native(
                RawWindowHandle::Xlib(XlibWindowHandle::new(7)),
                RawDisplayHandle::AppKit(AppKitDisplayHandle::new()),
            ),
            None
        );
    }
}
