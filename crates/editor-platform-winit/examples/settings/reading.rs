//! What the settings example reads back of the window, as plain data, and
//! what it holds the reading to. Pure: it names no AppKit type and opens
//! nothing, so its tests run in the gate on every platform.

use std::fmt;

use editor_platform::Rgb;

/// The appearance the example asks for, as AppKit names it.
pub const DARK_AQUA: &str = "NSAppearanceNameDarkAqua";

/// How far each component of the background read may be from the one
/// asked: one level of 255, for AppKit's conversion to sRGB and back.
pub const TOLERANCE: f64 = 1.0 / 255.0;

/// The edge of a layer: what would draw a line around it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Edge {
    /// Its `borderWidth`, in points.
    pub border_width: f64,
    /// Its `cornerRadius`, in points.
    pub corner_radius: f64,
}

/// What was read of the window.
#[derive(Debug, Clone, PartialEq)]
pub struct Reading {
    /// The window's `backgroundColor` in sRGB, red, green and blue from 0
    /// to 1; `None` when it has no sRGB form.
    pub background: Option<[f64; 3]>,
    /// The name of the window's appearance; `None` when it has none of
    /// its own.
    pub appearance: Option<String>,
    /// Whether the window is opaque.
    pub opaque: bool,
    /// Whether it has a shadow.
    pub shadow: bool,
    /// Whether its style mask is titled.
    pub titled: bool,
    /// Whether it is resizable.
    pub resizable: bool,
    /// Whether its content view is full size, under the title bar.
    pub full_size_content: bool,
    /// Whether its title bar draws no background of its own.
    pub titlebar_transparent: bool,
    /// The edge of the content view's layer; `None` when it has none.
    pub content_layer: Option<Edge>,
    /// The edge of winit's view's layer; `None` when it has none.
    pub view_layer: Option<Edge>,
}

/// One thing the reading misses.
#[derive(Debug, Clone, PartialEq)]
pub enum Miss {
    /// The background is not the one asked, within [`TOLERANCE`].
    Background {
        /// What was read.
        read: Option<[f64; 3]>,
        /// What was asked, over 255.
        asked: [f64; 3],
    },
    /// The appearance is not [`DARK_AQUA`].
    Appearance(Option<String>),
    /// The window is not opaque.
    NotOpaque,
    /// A layer of ours draws a border.
    Border {
        /// Which layer.
        layer: &'static str,
        /// Its width.
        width: f64,
    },
}

impl fmt::Display for Miss {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Background { read, asked } => {
                write!(f, "the background is {read:?}, not {asked:?} within 1/255")
            }
            Self::Appearance(read) => write!(f, "the appearance is {read:?}, not {DARK_AQUA}"),
            Self::NotOpaque => write!(f, "the window is not opaque"),
            Self::Border { layer, width } => {
                write!(f, "the {layer}'s layer draws a border {width} points wide")
            }
        }
    }
}

/// `rgb`'s components over 255.
pub fn components(rgb: Rgb) -> [f64; 3] {
    let over = |byte: u8| f64::from(byte) / 255.0;
    [over(rgb.red), over(rgb.green), over(rgb.blue)]
}

/// What `reading` misses of what the example set: the background `asked`,
/// the dark appearance, an opaque window and no border on a layer of ours.
/// The shadow, the style mask, the transparent title bar and the corner
/// radii are printed and not judged.
pub fn misses(reading: &Reading, asked: Rgb) -> Vec<Miss> {
    let mut missed = Vec::new();
    let wanted = components(asked);
    let near = reading.background.is_some_and(|read| {
        read.iter()
            .zip(wanted)
            .all(|(read, wanted)| (read - wanted).abs() <= TOLERANCE + 1e-9)
    });
    if !near {
        missed.push(Miss::Background {
            read: reading.background,
            asked: wanted,
        });
    }
    if reading.appearance.as_deref() != Some(DARK_AQUA) {
        missed.push(Miss::Appearance(reading.appearance.clone()));
    }
    if !reading.opaque {
        missed.push(Miss::NotOpaque);
    }
    for (layer, edge) in [
        ("content view", reading.content_layer),
        ("winit view", reading.view_layer),
    ] {
        if let Some(edge) = edge
            && edge.border_width != 0.0
        {
            missed.push(Miss::Border {
                layer,
                width: edge.border_width,
            });
        }
    }
    missed
}

/// The reading, one line for each thing read, for a person.
pub fn lines(reading: &Reading) -> Vec<String> {
    let edge = |edge: Option<Edge>| match edge {
        Some(edge) => format!(
            "border {} corner radius {}",
            edge.border_width, edge.corner_radius
        ),
        None => "no layer".to_owned(),
    };
    let background = match reading.background {
        Some([red, green, blue]) => format!(
            "{red:.6} {green:.6} {blue:.6} ({:.2} {:.2} {:.2} of 255)",
            red * 255.0,
            green * 255.0,
            blue * 255.0
        ),
        None => "no sRGB form".to_owned(),
    };
    vec![
        format!("background {background}"),
        format!("appearance {:?}", reading.appearance),
        format!("opaque {}", reading.opaque),
        format!("shadow {}", reading.shadow),
        format!(
            "style mask titled {} resizable {} full-size content {}",
            reading.titled, reading.resizable, reading.full_size_content
        ),
        format!("title bar transparent {}", reading.titlebar_transparent),
        format!("content view's layer {}", edge(reading.content_layer)),
        format!("winit view's layer {}", edge(reading.view_layer)),
    ]
}

#[cfg(test)]
mod tests {
    use editor_platform::Rgb;

    use super::{DARK_AQUA, Edge, Miss, Reading, components, lines, misses};

    /// The paper the example asks for.
    const PAPER: Rgb = Rgb {
        red: 0x2e,
        green: 0x34,
        blue: 0x40,
    };

    /// A reading that passes for [`PAPER`].
    fn passing() -> Reading {
        Reading {
            background: Some(components(PAPER)),
            appearance: Some(DARK_AQUA.to_owned()),
            opaque: true,
            shadow: true,
            titled: true,
            resizable: true,
            full_size_content: true,
            titlebar_transparent: true,
            content_layer: Some(Edge {
                border_width: 0.0,
                corner_radius: 0.0,
            }),
            view_layer: None,
        }
    }

    #[test]
    fn a_reading_of_what_was_set_misses_nothing() {
        assert_eq!(misses(&passing(), PAPER), []);
        // What is printed and not judged moves nothing.
        let other = Reading {
            shadow: false,
            titled: false,
            resizable: false,
            full_size_content: false,
            titlebar_transparent: false,
            content_layer: Some(Edge {
                border_width: 0.0,
                corner_radius: 10.0,
            }),
            ..passing()
        };
        assert_eq!(misses(&other, PAPER), []);
    }

    #[test]
    fn a_background_one_level_off_passes_and_two_levels_off_misses() {
        let off = |levels: f64| Reading {
            background: Some([
                (f64::from(PAPER.red) + levels) / 255.0,
                f64::from(PAPER.green) / 255.0,
                f64::from(PAPER.blue) / 255.0,
            ]),
            ..passing()
        };
        assert_eq!(misses(&off(1.0), PAPER), []);
        assert_eq!(misses(&off(-1.0), PAPER), []);
        assert!(matches!(
            misses(&off(2.0), PAPER).as_slice(),
            [Miss::Background { .. }]
        ));
        let none = Reading {
            background: None,
            ..passing()
        };
        assert!(matches!(
            misses(&none, PAPER).as_slice(),
            [Miss::Background { read: None, .. }]
        ));
    }

    #[test]
    fn each_other_miss_alone() {
        let light = Reading {
            appearance: Some("NSAppearanceNameAqua".to_owned()),
            ..passing()
        };
        assert_eq!(
            misses(&light, PAPER),
            [Miss::Appearance(Some("NSAppearanceNameAqua".to_owned()))]
        );
        let clear = Reading {
            opaque: false,
            ..passing()
        };
        assert_eq!(misses(&clear, PAPER), [Miss::NotOpaque]);
        let bordered = Reading {
            view_layer: Some(Edge {
                border_width: 1.0,
                corner_radius: 0.0,
            }),
            ..passing()
        };
        assert_eq!(
            misses(&bordered, PAPER),
            [Miss::Border {
                layer: "winit view",
                width: 1.0
            }]
        );
        assert!(
            misses(&bordered, PAPER)[0]
                .to_string()
                .contains("winit view")
        );
    }

    #[test]
    fn every_reading_is_printed() {
        let printed = lines(&passing()).join("\n");
        for part in [
            "background 0.180392 0.203922 0.250980",
            "appearance Some(\"NSAppearanceNameDarkAqua\")",
            "opaque true",
            "shadow true",
            "full-size content true",
            "title bar transparent true",
            "content view's layer border 0",
            "winit view's layer no layer",
        ] {
            assert!(printed.contains(part), "{part} in {printed}");
        }
    }
}
