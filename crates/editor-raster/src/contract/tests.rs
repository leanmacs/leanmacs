//! The contract on the published fake, plain and tinted, and on
//! rasterisers written to break each property: each must fail by that
//! property's name, or the property could not see what it claims to.

use std::collections::HashSet;

use super::{BASELINE, BIN, Failure, Fixture, KINDS, LUMINANCE, PROPERTIES, SAME, SHAPE, check};
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

/// The names of the properties `failures` holds.
fn names(failures: &[Failure]) -> Vec<&'static str> {
    failures.iter().map(|failure| failure.property).collect()
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
    /// One byte more than its size.
    WrongLength,
    /// A subpixel mask where a mask was asked for.
    SubpixelForMask,
    /// A counter of its requests in its first byte.
    Counter,
    /// Every bin drawn as bin 0.
    Still,
    /// Every image's top on the baseline.
    TopAtZero,
    /// Says it reads the luminance, and draws every bucket alike.
    TintedNoChange,
    /// Says it does not, and draws each bucket differently.
    UntintedChange,
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
            inner: fake(fault == Fault::UntintedChange),
            fault,
            count: 0,
        }
    }
}

impl Rasterize for Broken {
    fn rasterize(&mut self, request: &GlyphRequest<'_>) -> Option<GlyphImage> {
        self.count = self.count.wrapping_add(1);
        let asked = if self.fault == Fault::Still {
            GlyphRequest {
                key: GlyphKey {
                    bin: 0,
                    ..request.key
                },
                ..*request
            }
        } else {
            *request
        };
        let mut image = self.inner.rasterize(&asked)?;
        match self.fault {
            Fault::WrongLength => image.data.push(1),
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

#[test]
fn a_rasteriser_written_to_break_each_property_fails_by_its_name() {
    for (fault, property) in [
        (Fault::WrongLength, SHAPE),
        (Fault::SubpixelForMask, KINDS),
        (Fault::Counter, SAME),
        (Fault::Still, BIN),
        (Fault::TopAtZero, BASELINE),
        (Fault::TintedNoChange, LUMINANCE),
        (Fault::UntintedChange, LUMINANCE),
    ] {
        let failures = check(&mut || Box::new(Broken::new(fault)), &fixture());
        assert!(
            names(&failures).contains(&property),
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
    for property in [SHAPE, BIN, BASELINE] {
        assert!(names(&failures).contains(&property), "{failures:#?}");
    }
}

#[test]
fn a_failure_says_its_property_and_what_was_seen() {
    let failure = Failure {
        property: SHAPE,
        detail: "the space has no image".to_owned(),
    };
    assert_eq!(
        failure.to_string(),
        format!("{SHAPE}: the space has no image")
    );
}
