//! The window's settings read back from AppKit, on the main thread: one
//! reading of each, and no decision (macOS only).
//!
//! The layers' edges are read with `msg_send!` on the views' `layer`, and
//! not through objc2-app-kit's `NSView::layer`, which is compiled only
//! with its `objc2-quartz-core` feature: enabling it would add the edge
//! objc2-app-kit to objc2-quartz-core to the resolved graph for one
//! example's two readings.

use std::ffi::c_void;
use std::ptr::NonNull;

use objc2::msg_send;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{NSAppearanceCustomization, NSColorSpace, NSView, NSWindow, NSWindowStyleMask};

use crate::reading::{Edge, Reading};

/// The edge of `view`'s layer, if it has one.
fn edge(view: &NSView) -> Option<Edge> {
    // SAFETY: `layer` is an `NSView` property that returns a `CALayer` or
    // nil, and takes no argument.
    let layer: Option<Retained<AnyObject>> = unsafe { msg_send![view, layer] };
    let layer = layer?;
    // SAFETY: `borderWidth` and `cornerRadius` are `CALayer` properties of
    // type `CGFloat`, an `f64` here, and take no argument.
    let (border_width, corner_radius): (f64, f64) = unsafe {
        (
            msg_send![&layer, borderWidth],
            msg_send![&layer, cornerRadius],
        )
    };
    Some(Edge {
        border_width,
        corner_radius,
    })
}

/// The window's background in sRGB, if it has an sRGB form.
fn background(window: &NSWindow) -> Option<[f64; 3]> {
    let srgb = window
        .backgroundColor()
        .colorUsingColorSpace(&NSColorSpace::sRGBColorSpace())?;
    Some([
        srgb.redComponent(),
        srgb.greenComponent(),
        srgb.blueComponent(),
    ])
}

/// What the window of winit's view `view` reads as; `None` when the view
/// has no window.
///
/// It is called on the main thread only, with the view the window told
/// its drawer at `Opened`, while the window is open.
pub fn read(view: NonNull<c_void>) -> Option<Reading> {
    // SAFETY: winit's AppKit window handle gives its `NSView`, which lives
    // as long as the window, and this is called on the main thread while
    // the window is open.
    let view: &NSView = unsafe { view.cast::<NSView>().as_ref() };
    let window = view.window()?;
    let mask = window.styleMask();
    Some(Reading {
        background: background(&window),
        appearance: window
            .appearance()
            .map(|appearance| appearance.name().to_string()),
        opaque: window.isOpaque(),
        shadow: window.hasShadow(),
        titled: mask.contains(NSWindowStyleMask::Titled),
        resizable: mask.contains(NSWindowStyleMask::Resizable),
        full_size_content: mask.contains(NSWindowStyleMask::FullSizeContentView),
        titlebar_transparent: window.titlebarAppearsTransparent(),
        content_layer: window.contentView().and_then(|content| edge(&content)),
        view_layer: edge(view),
    })
}
