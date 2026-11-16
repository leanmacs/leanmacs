//! The window's corner clearance: how far in from its left and right edges
//! its rounded bottom corners reach, in whole logical points, as the port's
//! `Resize::corner_clearance` says it.
//!
//! What the window reads as is a [`Shape`]: whether it is in fullscreen,
//! and the system's own reading of its corners, if it gave one. The
//! decision is [`clearance`], a pure function of it:
//!
//! - **in fullscreen, 0**: a window that fills the display has square
//!   corners;
//! - **on macOS, outside fullscreen, the system's reading rounded up**
//!   when it is a finite number above 0, and [`FALLBACK_POINTS`] when it
//!   is not;
//! - **elsewhere, 0**: the other systems winit runs on draw no rounded
//!   corners over the content, or say nothing of them.
//!
//! The reading is [`system`], on macOS only: one call into AppKit with no
//! decision in it. It asks the window's content view for its insets in the
//! safe-area layout region adapted to the corners horizontally
//! (`-[NSView edgeInsetsForLayoutRegion:]` with
//! `+[NSViewLayoutRegion safeAreaLayoutRegionWithCornerAdaptation:]` and
//! `NSViewLayoutRegionAdaptivityAxisHorizontal`, macOS 26 and later:
//! <https://developer.apple.com/documentation/appkit/nsviewlayoutregion>,
//! and WWDC25 session 310, "Build an AppKit app with the new design",
//! "Avoiding window corners"). That is the system's own answer to how far
//! content keeps clear of the corners, so no radius is written down here.
//! `NSWindow` has no public corner radius, and the private `_cornerRadius`
//! is not used.
//!
//! The fallback is there because the system may give no reading: a window
//! with no AppKit view yet, or one that reads 0 while it is being built.
//! It is measured, not chosen ([`FALLBACK_POINTS`] says how). So outside
//! fullscreen on macOS the clearance is above 0 whatever the system reads,
//! which a hermetic test pins; that AppKit itself answers above 0 only a
//! real window shows (`mise run window-contract`).
//!
//! This module and `delegate` are the only code in the workspace that name
//! AppKit.

/// What the window reads as, for its corner clearance: whether it is in
/// the system's fullscreen, and the system's reading of how far in its
/// corners reach, in logical points, when it gave one.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub(crate) struct Shape {
    /// Whether the window is in the system's fullscreen.
    pub fullscreen: bool,
    /// The system's reading, in logical points; `None` when it gave none,
    /// as it does off macOS and for a window with no AppKit view.
    pub corner: Option<f64>,
}

/// The corner clearance on macOS when the system gives no reading above
/// 0, in logical points.
///
/// Measured, not chosen: the system's own reading of winit's window
/// (titlebar only, no toolbar), taken on 2026-11-16 on a Mac17,7 (arm64)
/// running macOS 27.2 (26B123) by `mise run window-contract` with this
/// constant set to 0 for the run. [`system`] read the insets left 16,
/// right 16, top 0 and bottom 0, and every resize the run printed said
/// `fullscreen false corner 16`. A window with a toolbar has larger
/// corners (WWDC25 session 310); winit's has none.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) const FALLBACK_POINTS: u32 = 16;

/// The corner clearance of a window that reads as `shape`, in whole
/// logical points, as the module docs decide it.
pub(crate) fn clearance(shape: Shape) -> u32 {
    if shape.fullscreen {
        return 0;
    }
    if cfg!(target_os = "macos") {
        return shape
            .corner
            .filter(|points| points.is_finite() && *points > 0.0)
            .map_or(FALLBACK_POINTS, points_up);
    }
    0
}

/// `points` rounded up to a whole number of points, saturating at the
/// largest a `u32` holds. Only a finite reading above 0 is given here.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn points_up(points: f64) -> u32 {
    // A reading is a few tens of points; one past `u32::MAX` is held to it.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let whole = points.ceil().min(f64::from(u32::MAX)) as u32;
    whole
}

/// The system's reading of how far in the corners of the window whose
/// AppKit content view is `view` reach, in logical points: the larger of
/// the left and right insets of its safe-area layout region adapted to the
/// corners horizontally. `None` when the system says nothing finite.
///
/// It is called on the main thread only, with the view of a window that is
/// still open, which is what the window's raw handle gives while the loop
/// runs.
#[cfg(target_os = "macos")]
pub(crate) fn system(view: std::ptr::NonNull<std::ffi::c_void>) -> Option<f64> {
    use objc2_app_kit::{NSView, NSViewLayoutRegion, NSViewLayoutRegionAdaptivityAxis};

    // SAFETY: winit's AppKit window handle gives its `NSView`, which lives
    // as long as the window, and this is called on the main thread while
    // the window is open.
    let view: &NSView = unsafe { view.cast::<NSView>().as_ref() };
    let region = NSViewLayoutRegion::safeAreaLayoutRegionWithCornerAdaptation(
        NSViewLayoutRegionAdaptivityAxis::Horizontal,
    );
    let insets = view.edgeInsetsForLayoutRegion(&region);
    let reach = insets.left.max(insets.right);
    reach.is_finite().then_some(reach)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the system may read, including what it should never give.
    const READINGS: [Option<f64>; 5] = [None, Some(0.0), Some(-1.0), Some(14.2), Some(f64::NAN)];

    #[test]
    fn in_fullscreen_the_clearance_is_0() {
        for corner in READINGS {
            assert_eq!(
                clearance(Shape {
                    fullscreen: true,
                    corner,
                }),
                0,
                "read {corner:?}"
            );
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn outside_fullscreen_on_macos_the_clearance_is_above_0_whatever_the_system_reads() {
        for corner in [
            None,
            Some(0.0),
            Some(-1.0),
            Some(f64::NAN),
            Some(f64::INFINITY),
        ] {
            let given = clearance(Shape {
                fullscreen: false,
                corner,
            });
            assert!(given > 0, "read {corner:?}, the clearance is {given}");
            assert_eq!(given, FALLBACK_POINTS, "read {corner:?}");
        }
        // A reading is rounded up to a whole point.
        assert_eq!(
            clearance(Shape {
                fullscreen: false,
                corner: Some(14.2),
            }),
            15
        );
        assert_eq!(
            clearance(Shape {
                fullscreen: false,
                corner: Some(16.0),
            }),
            16
        );
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn off_macos_the_clearance_is_0() {
        for corner in READINGS {
            assert_eq!(
                clearance(Shape {
                    fullscreen: false,
                    corner,
                }),
                0,
                "read {corner:?}"
            );
        }
    }
}
