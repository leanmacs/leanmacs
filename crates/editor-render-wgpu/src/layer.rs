//! The Metal layer a window's renderer draws on, read as plain data, and
//! the rules it is held to: whether the system shows the drawable as it
//! was drawn, pixel for pixel.
//!
//! # What wgpu and raw-window-metal do to the layer (read 2026-11-20)
//!
//! wgpu-hal 30.0.2 (`src/metal/surface.rs`) makes a `CAMetalLayer` through
//! raw-window-metal 1.1.0, as a sublayer of the view's layer. Its
//! `observer.rs` copies the view layer's `bounds` (by `setFrame`) and its
//! `contentsScale` by key-value observation, with `Initial | New`, not by
//! an autoresizing mask; AppKit sets the view layer's `contentsScale` to
//! the window's backing scale. The layer's `contentsGravity` is left at
//! the default, `kCAGravityResize`. wgpu-hal's `configure` then sets:
//!
//! - `drawableSize` to the configuration's width and height, which are the
//!   target's (`surface::State::acquire`);
//! - `opaque` from the alpha mode: `Opaque` sets it true, which is what the
//!   surface is configured with on Metal (`surface`, "The alpha mode");
//! - `pixelFormat` from the configuration's format, by its `map_format`;
//! - `colorspace` from the configuration's colour space, which wgpu-core
//!   resolves from `Auto` to sRGB for an 8-bit format, tagging the layer
//!   `kCGColorSpaceSRGB`. So the pin has what wgpu PR #10286 added: the
//!   layer is not left with a nil colour space.
//!
//! Under the default gravity, whenever `drawableSize` is not exactly
//! `bounds × contentsScale` the system scales the drawable to the layer's
//! bounds, which blurs every glyph. In a steady window that happens only
//! when `bounds × contentsScale` is not a whole number, or `contentsScale`
//! is not the backing scale.
//!
//! # The reading and its rules
//!
//! [`LayerReading`] is what the renderer reads of the layer
//! (`WgpuRenderer::layer`, on macOS only, on demand): its bounds in points,
//! its `contentsScale`, its `drawableSize`, `opaque`, whether it has a
//! colour space at all, its pixel format as Metal's number, and its
//! gravity. Which colour space it has is not read: its name needs Core
//! Graphics, which `deny.toml` keeps out of this crate; the source above
//! says it is sRGB. [`misses`] holds a [`Layer`] (the reading, and the
//! format the surface was configured with) to the target the renderer
//! drew on. A reading passes when:
//!
//! - the drawable is the target's size ([`Miss::Drawable`]: the surface
//!   was not configured at the size the loop drew on);
//! - `contentsScale` is the target's scale ([`Miss::Scale`]: the layer
//!   missed the view layer's change of scale);
//! - `bounds × contentsScale` is exactly the drawable ([`Miss::Scaled`]:
//!   the system scales the contents, and the text is blurred);
//! - it is opaque ([`Miss::NotOpaque`]);
//! - it has a colour space ([`Miss::NoColorspace`]: the nil space of
//!   before PR #10286);
//! - its pixel format is the configured one ([`Miss::Format`]).
//!
//! The gravity is printed and never a miss: changing it is a task of its
//! own. This module calls nothing of wgpu's; its rules run in the gate on
//! readings built in code.
//!
//! # Following a change of scale
//!
//! A change of the window's backing scale reaches the layer only through
//! raw-window-metal's observation of the view layer's `contentsScale`. A
//! machine with one display cannot change the backing scale, but the
//! observation itself can be seen: `WgpuRenderer::follow_scale` sets the
//! view layer's `contentsScale` to another value, reads the Metal layer's,
//! and sets it back and reads again ([`Followed`]). That shows a change
//! of the view layer's scale arrives, not that AppKit makes one when the
//! window moves to a display of another scale.

use std::fmt;

use editor_render::port::Target;

/// What was read of a window's Metal layer.
#[derive(Debug, Clone, PartialEq)]
pub struct LayerReading {
    /// Its bounds' width and height, in points.
    pub bounds: (f64, f64),
    /// Its `contentsScale`: pixels for each point.
    pub contents_scale: f64,
    /// Its `drawableSize`, in pixels.
    pub drawable: (f64, f64),
    /// Whether it is opaque.
    pub opaque: bool,
    /// Whether it has a colour space; `false` for a nil one.
    pub colorspace: bool,
    /// Its `pixelFormat`, as Metal's number.
    pub format: u64,
    /// Its `contentsGravity`, as AppKit names it.
    pub gravity: String,
}

/// A layer as it is held to its surface: the reading, and the format the
/// surface was configured with, as Metal's pixel-format number.
#[derive(Debug, Clone, PartialEq)]
pub struct Layer {
    /// What was read.
    pub reading: LayerReading,
    /// The format the surface was configured with.
    pub configured: u64,
}

/// One rule a reading misses, with what was read and what was wanted.
#[derive(Debug, Clone, PartialEq)]
pub enum Miss {
    /// The drawable is not the target's size.
    Drawable {
        /// The drawable read.
        read: (f64, f64),
        /// The target's size.
        wanted: (u32, u32),
    },
    /// `contentsScale` is not the target's scale.
    Scale {
        /// The scale read.
        read: f64,
        /// The target's.
        wanted: f64,
    },
    /// `bounds × contentsScale` is not exactly the drawable: the system
    /// scales the contents.
    Scaled {
        /// The bounds, in points.
        bounds: (f64, f64),
        /// The `contentsScale`.
        scale: f64,
        /// The drawable.
        drawable: (f64, f64),
    },
    /// The layer is not opaque.
    NotOpaque,
    /// The layer has no colour space.
    NoColorspace,
    /// The layer's pixel format is not the configured one.
    Format {
        /// The layer's.
        read: u64,
        /// The surface's.
        wanted: u64,
    },
}

impl fmt::Display for Miss {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Drawable { read, wanted } => write!(
                f,
                "the drawable is {} by {} pixels, not the target's {} by {}",
                read.0, read.1, wanted.0, wanted.1
            ),
            Self::Scale { read, wanted } => write!(
                f,
                "contentsScale is {read}, not the target's scale {wanted}"
            ),
            Self::Scaled {
                bounds,
                scale,
                drawable,
            } => write!(
                f,
                "bounds {} by {} points at scale {scale} are {} by {} pixels, not the drawable's {} by {}: the system scales the contents",
                bounds.0,
                bounds.1,
                bounds.0 * scale,
                bounds.1 * scale,
                drawable.0,
                drawable.1
            ),
            Self::NotOpaque => write!(f, "the layer is not opaque"),
            Self::NoColorspace => write!(f, "the layer has no colour space"),
            Self::Format { read, wanted } => write!(
                f,
                "the layer's pixel format is {read}, not the configured {wanted}"
            ),
        }
    }
}

/// What the Metal layer read when the view layer it follows was set to
/// another scale and then back.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Followed {
    /// The view layer's `contentsScale` before.
    pub before: f64,
    /// The scale the view layer was set to.
    pub asked: f64,
    /// The Metal layer's `contentsScale` right after.
    pub read: f64,
    /// The Metal layer's `contentsScale` once the view layer was set back.
    pub back: f64,
}

impl Followed {
    /// Whether the layer followed the view layer both ways: to the scale
    /// asked, which must be another than the one before, and back.
    pub fn holds(&self) -> bool {
        self.asked != self.before && self.read == self.asked && self.back == self.before
    }
}

/// Metal's pixel-format number for `format`, as wgpu-hal 30.0.2's
/// `map_format` gives it, for the formats a window's surface is configured
/// with; `None` for any other.
pub(crate) fn metal_format(format: wgpu::TextureFormat) -> Option<u64> {
    match format {
        wgpu::TextureFormat::Rgba8Unorm => Some(70),
        wgpu::TextureFormat::Rgba8UnormSrgb => Some(71),
        wgpu::TextureFormat::Bgra8Unorm => Some(80),
        wgpu::TextureFormat::Bgra8UnormSrgb => Some(81),
        _ => None,
    }
}

/// The rules `layer` misses, read after a draw on `target`: none for a
/// layer whose drawable the system shows pixel for pixel.
pub fn misses(layer: &Layer, target: Target) -> Vec<Miss> {
    let reading = &layer.reading;
    let mut missed = Vec::new();
    let wanted = (target.width, target.height);
    if reading.drawable != (f64::from(wanted.0), f64::from(wanted.1)) {
        missed.push(Miss::Drawable {
            read: reading.drawable,
            wanted,
        });
    }
    let scale = f64::from(target.scale);
    if reading.contents_scale != scale {
        missed.push(Miss::Scale {
            read: reading.contents_scale,
            wanted: scale,
        });
    }
    let shown = (
        reading.bounds.0 * reading.contents_scale,
        reading.bounds.1 * reading.contents_scale,
    );
    if shown != reading.drawable {
        missed.push(Miss::Scaled {
            bounds: reading.bounds,
            scale: reading.contents_scale,
            drawable: reading.drawable,
        });
    }
    if !reading.opaque {
        missed.push(Miss::NotOpaque);
    }
    if !reading.colorspace {
        missed.push(Miss::NoColorspace);
    }
    if reading.format != layer.configured {
        missed.push(Miss::Format {
            read: reading.format,
            wanted: layer.configured,
        });
    }
    missed
}

#[cfg(test)]
mod tests {
    use editor_render::port::Target;

    use super::{Followed, Layer, LayerReading, Miss, metal_format, misses};

    /// 800 by 600 pixels at scale 2.
    const TARGET: Target = Target {
        width: 800,
        height: 600,
        scale: 2.0,
    };

    /// A layer that passes on [`TARGET`]: 400 by 300 points at scale 2, a
    /// drawable of 800 by 600, opaque, with a colour space, of the format
    /// 80, configured 80.
    fn passing() -> Layer {
        Layer {
            reading: LayerReading {
                bounds: (400.0, 300.0),
                contents_scale: 2.0,
                drawable: (800.0, 600.0),
                opaque: true,
                colorspace: true,
                format: 80,
                gravity: "resize".to_owned(),
            },
            configured: 80,
        }
    }

    /// [`passing`] with its reading changed by `change`.
    fn with(change: impl FnOnce(&mut LayerReading)) -> Layer {
        let mut layer = passing();
        change(&mut layer.reading);
        layer
    }

    #[test]
    fn a_layer_drawn_pixel_for_pixel_misses_nothing() {
        assert_eq!(misses(&passing(), TARGET), []);
    }

    #[test]
    fn the_four_surface_formats_are_metals_numbers_and_no_other_is() {
        assert_eq!(metal_format(wgpu::TextureFormat::Rgba8Unorm), Some(70));
        assert_eq!(metal_format(wgpu::TextureFormat::Rgba8UnormSrgb), Some(71));
        assert_eq!(metal_format(wgpu::TextureFormat::Bgra8Unorm), Some(80));
        assert_eq!(metal_format(wgpu::TextureFormat::Bgra8UnormSrgb), Some(81));
        assert_eq!(metal_format(wgpu::TextureFormat::Rgba16Float), None);
    }

    #[test]
    fn each_field_changed_alone_gives_exactly_its_miss() {
        // A drawable of another size than the target is scaled too.
        assert_eq!(
            misses(
                &with(|reading| {
                    reading.drawable = (802.0, 600.0);
                    reading.bounds = (401.0, 300.0);
                }),
                TARGET
            ),
            [Miss::Drawable {
                read: (802.0, 600.0),
                wanted: (800, 600)
            }]
        );
        assert_eq!(
            misses(&with(|reading| reading.opaque = false), TARGET),
            [Miss::NotOpaque]
        );
        assert_eq!(
            misses(&with(|reading| reading.colorspace = false), TARGET),
            [Miss::NoColorspace]
        );
        assert_eq!(
            misses(&with(|reading| reading.format = 81), TARGET),
            [Miss::Format {
                read: 81,
                wanted: 80
            }]
        );
        let unconfigured = Layer {
            configured: 81,
            ..passing()
        };
        assert_eq!(
            misses(&unconfigured, TARGET),
            [Miss::Format {
                read: 80,
                wanted: 81
            }]
        );
    }

    #[test]
    fn bounds_that_are_not_a_whole_number_of_pixels_are_scaled() {
        let layer = with(|reading| {
            reading.bounds = (800.5, 600.0);
            reading.contents_scale = 1.0;
            reading.drawable = (801.0, 600.0);
        });
        let target = Target {
            width: 801,
            height: 600,
            scale: 1.0,
        };
        let missed = misses(&layer, target);
        assert_eq!(
            missed,
            [Miss::Scaled {
                bounds: (800.5, 600.0),
                scale: 1.0,
                drawable: (801.0, 600.0)
            }]
        );
        let said = missed[0].to_string();
        assert!(said.contains("800.5") && said.contains("801"), "{said}");
    }

    #[test]
    fn the_gravity_is_never_a_miss() {
        let anchored = with(|reading| reading.gravity = "topLeft".to_owned());
        assert_eq!(misses(&anchored, TARGET), []);
    }

    /// The criterion "contentsScale equals the backing scale after a
    /// scale change", held in the gate with no display: what a layer read
    /// across a change from scale 1 to 2 would show.
    #[test]
    fn a_layer_read_across_a_change_of_scale_misses_what_it_has_not_followed() {
        // The layer still at the old scale: a missed update of
        // contentsScale.
        let stale = with(|reading| reading.contents_scale = 1.0);
        assert_eq!(
            misses(&stale, TARGET),
            [
                Miss::Scale {
                    read: 1.0,
                    wanted: 2.0
                },
                Miss::Scaled {
                    bounds: (400.0, 300.0),
                    scale: 1.0,
                    drawable: (800.0, 600.0)
                }
            ]
        );
        // At the new scale, with the drawable not yet configured for it.
        let unconfigured = with(|reading| reading.drawable = (400.0, 300.0));
        assert_eq!(
            misses(&unconfigured, TARGET),
            [
                Miss::Drawable {
                    read: (400.0, 300.0),
                    wanted: (800, 600)
                },
                Miss::Scaled {
                    bounds: (400.0, 300.0),
                    scale: 2.0,
                    drawable: (400.0, 300.0)
                }
            ]
        );
        // All at the new scale.
        assert_eq!(misses(&passing(), TARGET), []);
    }

    #[test]
    fn a_layer_follows_a_change_of_scale_only_when_it_reads_it_both_ways() {
        let followed = Followed {
            before: 2.0,
            asked: 1.0,
            read: 1.0,
            back: 2.0,
        };
        assert!(followed.holds());
        // A layer that missed the change, or the change back.
        assert!(
            !Followed {
                read: 2.0,
                ..followed
            }
            .holds()
        );
        assert!(
            !Followed {
                back: 1.0,
                ..followed
            }
            .holds()
        );
        // A change to the scale it had already shows nothing.
        assert!(
            !Followed {
                asked: 2.0,
                read: 2.0,
                ..followed
            }
            .holds()
        );
    }

    #[test]
    fn every_miss_says_what_was_read_and_wanted() {
        let said = misses(
            &with(|reading| {
                reading.contents_scale = 1.0;
                reading.format = 70;
            }),
            TARGET,
        )
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("; ");
        assert!(
            said.contains("contentsScale is 1, not the target's scale 2"),
            "{said}"
        );
        assert!(
            said.contains("pixel format is 70, not the configured 80"),
            "{said}"
        );
    }
}
