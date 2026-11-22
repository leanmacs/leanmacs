//! The contract on the published fake, plain and tinted, and on
//! rasterisers written to break its rules: each must fail by exactly the
//! rules it breaks, under their properties' names, so that every rule is
//! seen to fail and deleting any rule from [`check`] fails a test. Which
//! rules a fault breaks alone, and which only with others, is in
//! `a_rasteriser_written_to_break_a_rule_fails_by_that_rule`.

use std::collections::HashSet;

use super::{
    BASELINE, BIN, Failure, Fixture, KINDS, LUMINANCE, PROPERTIES, Rule, SAME, SHAPE, check,
};
use crate::fake::{FakeRasterizer, font};
use crate::{GlyphImage, GlyphKey, GlyphRequest, Kind, Rasterize};

/// The fake's fixture: no font, and three glyph ids, the third a space.
fn fixture() -> Fixture {
    Fixture {
        font: font(16.0),
        h: 1,
        i: 2,
        space: 3,
        hint: true,
    }
}

/// A fake that draws the fixture's space as nothing, tinted or not.
fn fake(tinted: bool) -> FakeRasterizer {
    FakeRasterizer {
        blank: HashSet::from([3]),
        tinted,
        ..FakeRasterizer::new()
    }
}

#[test]
fn every_property_is_named_once() {
    for (index, one) in PROPERTIES.iter().enumerate() {
        assert!(!PROPERTIES[index + 1..].contains(one), "{one}");
    }
}

#[test]
fn the_fake_holds_to_the_contract_plain_and_tinted() {
    for tinted in [false, true] {
        let failures = check(&mut || Box::new(fake(tinted)), &fixture());
        assert!(failures.is_empty(), "tinted {tinted}: {failures:#?}");
    }
}

/// What a rasteriser written to break a property does wrong.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Fault {
    /// One byte more than its size, but a space's nothing.
    WrongLength,
    /// A subpixel mask where a mask was asked for.
    SubpixelForMask,
    /// A counter of its requests in its first byte.
    Counter,
    /// Every bin drawn as bin 0.
    Still,
    /// Each bin drawn a quarter of a pixel on from the last, as the bins
    /// once were, and not at its own fraction of a pixel.
    Quarters,
    /// Every image's top on the baseline.
    TopAtZero,
    /// Says it reads the luminance, and draws every bucket alike.
    TintedNoChange,
    /// Says it does not, and draws each bucket differently.
    UntintedChange,
    /// Reads the luminance, and draws lighter text thinner: bucket 4 as
    /// a tinted fake draws bucket 0, so black and white still differ.
    Thinning,
    /// Moves each bin as it should, and draws every bin but 0 with a
    /// tenth less ink.
    Fading,
    /// Draws a subpixel mask asked for in colour.
    ColourForSubpixel,
    /// Draws a pixel of ink for the space.
    InkedSpace,
    /// Reads the luminance, and has no image in bucket 2.
    NoMiddleBucket,
    /// Draws `I` two pixels right of where `H` is centred.
    OffCentre,
}

/// The fake, with one fault.
struct Broken {
    /// The fake.
    inner: FakeRasterizer,
    /// What it does wrong.
    fault: Fault,
    /// How many requests it has had.
    count: u8,
}

impl Broken {
    /// A rasteriser with `fault`.
    fn new(fault: Fault) -> Self {
        Self {
            inner: fake(matches!(
                fault,
                Fault::UntintedChange | Fault::Thinning | Fault::NoMiddleBucket
            )),
            fault,
            count: 0,
        }
    }
}

impl Rasterize for Broken {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        self.count = self.count.wrapping_add(1);
        let asked = match self.fault {
            Fault::Still | Fault::Quarters => GlyphRequest {
                key: GlyphKey {
                    bin: if self.fault == Fault::Still {
                        0
                    } else {
                        (request.key.bin * 3).min(crate::SUBPIXEL_BINS - 1)
                    },
                    ..request.key
                },
                ..*request
            },
            Fault::Thinning => GlyphRequest {
                key: GlyphKey {
                    bucket: 4 - request.key.bucket,
                    ..request.key
                },
                ..*request
            },
            Fault::NoMiddleBucket if request.key.bucket == 2 => return None,
            _ => *request,
        };
        let mut image = self.inner.rasterize(&asked)?;
        match self.fault {
            Fault::WrongLength if !image.data.is_empty() => image.data.push(1),
            Fault::SubpixelForMask if !request.key.subpixel => {
                image.kind = Kind::Subpixel;
                image.data = image.data.iter().flat_map(|byte| [*byte; 4]).collect();
            }
            Fault::Counter => {
                if let Some(first) = image.data.first_mut() {
                    *first = first.wrapping_add(self.count);
                }
            }
            Fault::TopAtZero => image.top = 0,
            // Every byte scaled alike keeps where the ink is centred.
            Fault::Fading if request.key.bin > 0 => {
                for byte in &mut image.data {
                    *byte = (f64::from(*byte) * 0.9).round() as u8;
                }
            }
            // A subpixel mask's four bytes a pixel are a colour image's.
            Fault::ColourForSubpixel if request.key.subpixel => image.kind = Kind::Color,
            Fault::InkedSpace if image.data.is_empty() => {
                image.width = 1;
                image.height = 1;
                image.top = 1;
                image.data = vec![255; image.kind.bytes() as usize];
            }
            Fault::OffCentre if request.key.glyph == fixture().i => image.left += 2,
            _ => {}
        }
        Some(image)
    }

    fn by_luminance(&self) -> bool {
        match self.fault {
            Fault::TintedNoChange => true,
            Fault::UntintedChange => false,
            _ => self.inner.by_luminance(),
        }
    }
}

/// The rules `failures` breaks.
fn rules(failures: &[Failure]) -> HashSet<Rule> {
    failures.iter().map(|failure| failure.rule).collect()
}

/// Each fault breaks the rule it is written to break, under that rule's
/// property, and exactly the rules listed with it. With the rasteriser
/// with no images below, every [`Rule`] is in some exact set, so deleting
/// any rule's branch from [`check`] fails a test.
///
/// Eleven rules are each broken alone, by one fault: `Misshaped`,
/// `SpaceDraws`, `SubpixelInColour`, `BinStep`, `BinInk`,
/// `BelowBaseline`, `CentresApart`, `BucketMissing`, `InkFalls`,
/// `BlackIsWhite` and `UnreadBucketsDiffer`. The other seven are broken
/// only with others, because their faults cannot help it: `MaskNotMask`
/// with `BinNoInk`, `BelowBaseline` and `CentresApart` (a mask drawn in
/// another kind has no coverage for the rules that read a mask's),
/// `SameTwice` with `SameFresh` and `UnreadBucketsDiffer` (a counter of
/// requests changes every image), and `GlyphMissing`, `SpaceMissing`,
/// `BinNoInk` and `CapitalMissing` together, by the rasteriser with no
/// images.
///
/// Each of `Thinning`, `Fading`, `ColourForSubpixel`, `InkedSpace`,
/// `NoMiddleBucket` and `OffCentre` was seen to fail this test with its
/// rule's branch deleted from [`check`], and to pass it once the branch
/// was put back.
#[test]
fn a_rasteriser_written_to_break_a_rule_fails_by_that_rule() {
    for (fault, rule, property, also) in [
        (Fault::WrongLength, Rule::Misshaped, SHAPE, &[][..]),
        (
            Fault::SubpixelForMask,
            Rule::MaskNotMask,
            KINDS,
            &[Rule::BinNoInk, Rule::BelowBaseline, Rule::CentresApart],
        ),
        (
            Fault::Counter,
            Rule::SameTwice,
            SAME,
            &[Rule::SameFresh, Rule::UnreadBucketsDiffer],
        ),
        (Fault::Still, Rule::BinStep, BIN, &[]),
        (Fault::Quarters, Rule::BinStep, BIN, &[]),
        (Fault::Fading, Rule::BinInk, BIN, &[]),
        (Fault::TopAtZero, Rule::BelowBaseline, BASELINE, &[]),
        (Fault::TintedNoChange, Rule::BlackIsWhite, LUMINANCE, &[]),
        (Fault::Thinning, Rule::InkFalls, LUMINANCE, &[]),
        (
            Fault::UntintedChange,
            Rule::UnreadBucketsDiffer,
            LUMINANCE,
            &[],
        ),
        (Fault::ColourForSubpixel, Rule::SubpixelInColour, KINDS, &[]),
        (Fault::InkedSpace, Rule::SpaceDraws, SHAPE, &[]),
        (Fault::NoMiddleBucket, Rule::BucketMissing, LUMINANCE, &[]),
        (Fault::OffCentre, Rule::CentresApart, BASELINE, &[]),
    ] {
        let failures = check(&mut || Box::new(Broken::new(fault)), &fixture());
        let broken: HashSet<Rule> = also.iter().copied().chain([rule]).collect();
        assert_eq!(rules(&failures), broken, "{fault:?}: {failures:#?}");
        assert!(
            failures
                .iter()
                .filter(|failure| failure.rule == rule)
                .all(|failure| failure.property == property),
            "{fault:?}: {failures:#?}"
        );
    }
}

#[test]
fn a_rasteriser_with_no_images_fails_where_it_has_none() {
    let failures = check(
        &mut || {
            let mut none = fake(false);
            none.missing.extend([1, 2, 3]);
            Box::new(none)
        },
        &fixture(),
    );
    let broken = [
        (Rule::GlyphMissing, SHAPE),
        (Rule::SpaceMissing, SHAPE),
        (Rule::BinNoInk, BIN),
        (Rule::CapitalMissing, BASELINE),
    ];
    assert_eq!(
        rules(&failures),
        broken.iter().map(|(rule, _)| *rule).collect(),
        "{failures:#?}"
    );
    for failure in &failures {
        assert!(
            broken.contains(&(failure.rule, failure.property)),
            "{failure:#?}"
        );
    }
}

#[test]
fn a_failure_says_its_property_and_what_was_seen() {
    let failure = Failure {
        property: SHAPE,
        rule: Rule::SpaceMissing,
        detail: "the space has no image".to_owned(),
    };
    assert_eq!(
        failure.to_string(),
        format!("{SHAPE}: the space has no image")
    );
}
