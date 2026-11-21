//! How a composited picture of the sentence is compared with Core Text's:
//! two RGB pictures of one size, of text in one colour over one ground.
//!
//! It is pure, and its tests run in the gate on pictures made in code.
//! The measure is phase 1's mask measure (`editor_raster_coretext::
//! compare`) read through the colours: the ink is how far the pixels are
//! from the ground, and a pixel is dark when it is more than half of the
//! way from the ground to the text.

use editor_raster_coretext::compare::UNDECIDED;
use editor_render_wgpu::Image;

/// The colours a picture was drawn in: its ground and its text, as sRGB
/// values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Colours {
    /// What is under the text.
    pub ground: [u8; 3],
    /// The text's colour.
    pub text: [u8; 3],
}

impl Colours {
    /// How far from the ground to the text the pixel `rgb` is, from 0 to
    /// 1 and past, as the mean over the channels in which the text and the
    /// ground differ.
    fn along(&self, rgb: [u8; 3]) -> f32 {
        let mut sum = 0.0;
        let mut count = 0.0;
        for ((value, ground), text) in rgb.iter().zip(self.ground).zip(self.text) {
            if ground != text {
                sum +=
                    (f32::from(*value) - f32::from(ground)) / (f32::from(text) - f32::from(ground));
                count += 1.0;
            }
        }
        if count > 0.0 { sum / count } else { 0.0 }
    }
}

/// How one composited picture compares with another of the same size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Composited {
    /// The first's ink as a part of the second's: the sum over pixels and
    /// channels of how far each value is from the ground's.
    pub ink: f64,
    /// The first's dark pixels as a part of the second's: those more than
    /// half of the way from the ground to the text, counted only where
    /// both pictures are more than one 255th from half of the way
    /// ([`UNDECIDED`]).
    pub dark: f64,
    /// The largest difference of any channel of any pixel, of 255.
    pub worst: u8,
}

/// Which way a picture misses another: by its ink.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// More ink than the other.
    Heavier,
    /// Less.
    Lighter,
    /// As much.
    Alike,
}

/// How far a comparison may go and still pass.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Tolerance {
    /// The least and the most the ink may be, as a part.
    pub ink: (f64, f64),
    /// The least and the most the dark pixels may be, as a part.
    pub dark: (f64, f64),
    /// The largest difference allowed of any channel of any pixel, of 255.
    pub worst: u8,
}

/// The thresholds at scale 2: the ink and the dark pixels within half a
/// percent, phase 1's bounds, and no channel more than 3 of 255 off: the
/// mask check's 2 of 255 and one for rounding.
pub const AT_SCALE_TWO: Tolerance = Tolerance {
    ink: (0.995, 1.005),
    dark: (0.995, 1.005),
    worst: 3,
};

/// The thresholds at scale 1: as at scale 2, but no channel more than 21
/// of 255 off: the mask check's 0.08 of coverage over a full range, and
/// one for rounding.
pub const AT_SCALE_ONE: Tolerance = Tolerance {
    worst: 21,
    ..AT_SCALE_TWO
};

/// The thresholds a picture drawn at `scale` is held to.
pub fn thresholds(scale: u32) -> Tolerance {
    if scale <= 1 {
        AT_SCALE_ONE
    } else {
        AT_SCALE_TWO
    }
}

/// How `ours` compares with `theirs`, both drawn in `colours`; `None`
/// when they are not the same size.
pub fn compare(ours: &Image, theirs: &Image, colours: Colours) -> Option<Composited> {
    if (ours.width, ours.height) != (theirs.width, theirs.height) {
        return None;
    }
    let pixels = |image: &Image| -> Vec<[u8; 3]> {
        image
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .map(|pixel| [pixel[0], pixel[1], pixel[2]])
            .collect()
    };
    let (one, other) = (pixels(ours), pixels(theirs));
    let ink = |picture: &[[u8; 3]]| -> f64 {
        picture
            .iter()
            .flat_map(|rgb| {
                (0..3).map(move |channel| rgb[channel].abs_diff(colours.ground[channel]))
            })
            .map(f64::from)
            .sum()
    };
    let decided = |along: f32| (along - 0.5).abs() > UNDECIDED;
    let (mut dark_ours, mut dark_theirs) = (0_u64, 0_u64);
    for (a, b) in one.iter().zip(&other) {
        let (a, b) = (colours.along(*a), colours.along(*b));
        if decided(a) && decided(b) {
            dark_ours += u64::from(a > 0.5);
            dark_theirs += u64::from(b > 0.5);
        }
    }
    let worst = one
        .iter()
        .zip(&other)
        .flat_map(|(a, b)| (0..3).map(move |channel| a[channel].abs_diff(b[channel])))
        .max()
        .unwrap_or(0);
    Some(Composited {
        ink: ink(&one) / ink(&other),
        dark: dark_ours as f64 / dark_theirs as f64,
        worst,
    })
}

impl Composited {
    /// Whether it is within `tolerance`: a sentence that says what is not.
    pub fn within(&self, tolerance: Tolerance) -> Result<(), String> {
        let mut misses = Vec::new();
        if !(tolerance.ink.0..=tolerance.ink.1).contains(&self.ink) {
            misses.push(format!("ink x{:.4}", self.ink));
        }
        if !(tolerance.dark.0..=tolerance.dark.1).contains(&self.dark) {
            misses.push(format!("dark pixels x{:.4}", self.dark));
        }
        if self.worst > tolerance.worst {
            misses.push(format!("a channel {} of 255 off", self.worst));
        }
        if misses.is_empty() {
            Ok(())
        } else {
            Err(misses.join(", "))
        }
    }

    /// Which way the first picture misses the second, by its ink.
    pub fn direction(&self) -> Direction {
        if self.ink > 1.0 {
            Direction::Heavier
        } else if self.ink < 1.0 {
            Direction::Lighter
        } else {
            Direction::Alike
        }
    }
}

impl std::fmt::Display for Composited {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "ink x{:.4}, dark pixels x{:.4}, worst channel {} of 255",
            self.ink, self.dark, self.worst
        )
    }
}

#[cfg(test)]
mod tests {
    use editor_render_wgpu::Image;

    use super::{AT_SCALE_ONE, AT_SCALE_TWO, Colours, Direction, compare, thresholds};

    const BLACK_ON_WHITE: Colours = Colours {
        ground: [255, 255, 255],
        text: [0, 0, 0],
    };

    const LIGHT_ON_DARK: Colours = Colours {
        ground: [0x2e, 0x34, 0x40],
        text: [0xd8, 0xde, 0xe9],
    };

    /// A picture 40 by 20 of `colours`' ground, with a block of its text
    /// 20 across and 10 down, half covered along its left column, and
    /// each extra column of `wider` drawn in the text too.
    fn block(colours: Colours, wider: u32) -> Image {
        let (width, height) = (40_u32, 20_u32);
        let mut rgba = Vec::new();
        for y in 0..height {
            for x in 0..width {
                let inside = (5..15).contains(&y) && (10..30 + wider).contains(&x);
                let half = inside && x == 10;
                let rgb: [u8; 3] = std::array::from_fn(|channel| {
                    let (ground, text) = (colours.ground[channel], colours.text[channel]);
                    if half {
                        ((u16::from(ground) + u16::from(text)) / 2) as u8
                    } else if inside {
                        text
                    } else {
                        ground
                    }
                });
                rgba.extend_from_slice(&[rgb[0], rgb[1], rgb[2], 255]);
            }
        }
        Image {
            width,
            height,
            rgba,
        }
    }

    #[test]
    fn identical_pictures_pass_at_either_scale() {
        for colours in [BLACK_ON_WHITE, LIGHT_ON_DARK] {
            let picture = block(colours, 0);
            let compared = compare(&picture, &picture, colours).expect("one size");
            assert_eq!((compared.ink, compared.dark, compared.worst), (1.0, 1.0, 0));
            assert_eq!(compared.within(thresholds(2)), Ok(()));
            assert_eq!(compared.within(thresholds(1)), Ok(()));
            assert_eq!(compared.direction(), Direction::Alike);
        }
    }

    #[test]
    fn a_column_more_ink_fails_on_the_ink_and_is_heavier() {
        for colours in [BLACK_ON_WHITE, LIGHT_ON_DARK] {
            let (theirs, ours) = (block(colours, 0), block(colours, 1));
            let compared = compare(&ours, &theirs, colours).expect("one size");
            assert!(compared.ink > 1.005, "{compared}");
            let missed = compared.within(AT_SCALE_ONE).expect_err("past the ink");
            assert!(missed.contains("ink"), "{missed}");
            assert_eq!(compared.direction(), Direction::Heavier);
            // And the other way about it is lighter.
            let back = compare(&theirs, &ours, colours).expect("one size");
            assert_eq!(back.direction(), Direction::Lighter);
        }
    }

    #[test]
    fn one_channel_four_off_fails_at_scale_two_and_passes_at_scale_one() {
        let colours = BLACK_ON_WHITE;
        let theirs = block(colours, 0);
        let mut ours = theirs.clone();
        // A pixel of the block's inside, its red channel 4 lighter.
        let at = ((8 * 40 + 20) * 4) as usize;
        ours.rgba[at] += 4;
        let compared = compare(&ours, &theirs, colours).expect("one size");
        assert_eq!(compared.worst, 4);
        let missed = compared.within(AT_SCALE_TWO).expect_err("past 3 of 255");
        assert!(missed.contains("4 of 255"), "{missed}");
        assert_eq!(compared.within(AT_SCALE_ONE), Ok(()));
    }

    #[test]
    fn a_pixel_is_dark_past_half_of_the_way_to_the_text_and_counted_only_when_decided() {
        let colours = BLACK_ON_WHITE;
        let theirs = block(colours, 0);
        // The half-covered column, made a little more than half in ours:
        // still undecided in theirs, so not counted.
        let mut ours = theirs.clone();
        for y in 5..15 {
            let at = ((y * 40 + 10) * 4) as usize;
            for channel in 0..3 {
                ours.rgba[at + channel] -= 1;
            }
        }
        let compared = compare(&ours, &theirs, colours).expect("one size");
        assert_eq!(compared.dark, 1.0);
        // A column of ground made text in ours is ten more dark pixels.
        let wider = block(colours, 1);
        let compared = compare(&wider, &theirs, colours).expect("one size");
        assert!((compared.dark - 200.0 / 190.0).abs() < 1e-9, "{compared}");
    }

    #[test]
    fn pictures_of_other_sizes_are_not_compared() {
        let colours = BLACK_ON_WHITE;
        let one = block(colours, 0);
        let other = Image {
            width: 1,
            height: 1,
            rgba: vec![255; 4],
        };
        assert_eq!(compare(&one, &other, colours), None);
    }
}
