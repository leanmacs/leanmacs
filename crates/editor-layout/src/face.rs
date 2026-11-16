//! Faces: what a run of text looks like, as a set of optional attributes,
//! and how the faces over a run merge into one font and one paint.
//!
//! A [`Face`] sets any of ten attributes and leaves the rest unset: a
//! family, a size, a weight, a slant, a foreground, a background, an
//! underline (a style and a colour), strike-through, a line height and a
//! vertical padding.
//! Faces are named. What a name means is a list of definitions
//! ([`FaceDef`]) sent with a scene ([`Scene::faces`]), and layout holds the
//! list last sent ([`Faces`]).
//!
//! # The precedence
//!
//! Attributes merge one by one. The value of an attribute of a run is that
//! of the highest layer over the run that sets it:
//!
//! 1. (highest) the selection, drawn in the face [`SELECTION_FACE`];
//! 2. the decorations of the view, a later one in the view's list over an
//!    earlier one;
//! 3. (lowest) the face [`DEFAULT_FACE`]; and where that leaves an
//!    attribute unset, the base value: no family, 16 points, weight 400,
//!    upright, black on white, no underline, no strike-through, and lines
//!    of the font's own height ([`FontSpec::default`], [`BASE_FOREGROUND`],
//!    [`BASE_BACKGROUND`]).
//!
//! The same rule orders definitions: where the list defines a name more
//! than once, a later definition's set attributes are over an earlier
//! one's. A status field's face is over the view's status face (an
//! unselected window's `mode-line.inactive`, when the scene names one),
//! over [`MODE_LINE_FACE`], over the default face; and a cursor's face is
//! over the default face. A name
//! nothing defines sets nothing. A source of decorations added later
//! (syntax highlighting) says where it is in this order when it is added.
//!
//! [`Faces::resolve`] is that rule for a stack of faces given lowest
//! first, under the default face. The frame builds a run's stack in the
//! order above ([`frame`](crate::frame)), and so does a query, from the
//! selections and decorations of the last frame that showed its text.
//!
//! # What is font and what is paint
//!
//! The family, the size, the weight, the slant and the line height are the
//! font a run is shaped in ([`FontSpec`]): a change of one shapes the run
//! again. The line height is among them because it changes how tall a row
//! is. The foreground, the background, the underline and strike-through
//! are [`Paint`]: they never reach the shaper, and a change of one shapes
//! and breaks nothing. An underline with no colour of its own takes the
//! run's foreground.
//!
//! The vertical padding is neither: it shapes and paints nothing, and is
//! read only where layout sizes a status row ([`Layout::heights`]), from
//! the face of the row itself, [`MODE_LINE_FACE`] or [`ECHO_AREA_FACE`]. A
//! field's face or a view's status face may set it, and it is ignored
//! there.
//!
//! # Units
//!
//! A colour is one word, `0xRRGGBBAA` ([`Color`]).
//!
//! **A length a face states is in points.** A size, a line height stated
//! as a length, and the base size where no face sets one are whole 64ths
//! of a logical point ([`Length`]). A point is one physical pixel at
//! scale 1: what a window system calls a logical pixel, and not the
//! typographic point of a 72nd of an inch. Layout multiplies each by the
//! scale it was last told ([`Layout::set_scale`], the scale factor of the
//! target the frame is drawn on) once the faces over a run are merged and
//! before it asks the shaper for the font
//! ([`Styles::style`](crate::decoration::Styles::style)), so `size := 14`
//! is 14 physical pixels at scale 1 and 28 at scale 2. A line height that
//! is a multiple of the font's own is not a length, and follows the size.
//! A vertical padding is a length too, in points, and is multiplied where
//! these are ([`Styles::style`](crate::decoration::Styles::style)). No
//! other attribute is a length: a face has no horizontal padding and no
//! margin (a status field's horizontal padding is the field's own, in
//! points, [`StatusField::padding`](crate::scene::StatusField::padding)).
//! One added later is in points, and is multiplied where these are.
//!
//! The names do not say so: [`Length::pixels`] and [`LineHeight::Pixels`]
//! keep the names they had when a theme stated physical pixels. In a
//! face they are points; in the [`FontSpec`] a shaper is handed they are
//! physical pixels, which is all a shaper ever sees.
//!
//! Everything layout gives back is in physical pixels, as a scene's
//! rectangles are: a frame's geometry and the answers of the queries.
//!
//! A size or a line height of 0 is a value like any other: no face is
//! refused or changed for it. The font it resolves to has lines of no
//! height, and how many of those a view shows is the rows query's rule
//! ([`query`](crate::query), "The rows that fit").
//!
//! # Where an addition goes
//!
//! A new attribute is a field of [`Face`], merged in [`Face::over`], and
//! then a field of [`FontSpec`] if it changes shaping or of [`Paint`] if it
//! paints a run. One that does neither, as the vertical padding, is a field
//! of [`Resolved`] of its own, read where layout uses it. Face inheritance
//! (a face naming another as its base) is not built.

use std::collections::HashMap;

#[cfg(doc)]
use crate::Layout;
#[cfg(doc)]
use crate::scene::Scene;
use crate::shaper::{FontSpec, Length, LineHeight, Slant, Weight};

/// The name of the face under every other: what a run no span covers is
/// drawn in.
pub const DEFAULT_FACE: &str = "default";
/// The name of the face the selections are drawn in.
pub const SELECTION_FACE: &str = "selection";
/// The name of the face a view's status row is drawn in, under each of its
/// fields' faces.
pub const MODE_LINE_FACE: &str = "mode-line";
/// The name of the face the scene's echo text is drawn in, over the
/// default face ([`frame`](crate::frame), "The bottom row").
pub const ECHO_AREA_FACE: &str = "echo-area";

/// A colour: `0xRRGGBBAA`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Color(pub u32);

impl Color {
    /// The opaque colour of `red`, `green` and `blue`.
    pub const fn rgb(red: u8, green: u8, blue: u8) -> Self {
        Self::rgba(red, green, blue, 0xff)
    }

    /// The colour of `red`, `green`, `blue` and `alpha`.
    pub const fn rgba(red: u8, green: u8, blue: u8, alpha: u8) -> Self {
        Self(u32::from_be_bytes([red, green, blue, alpha]))
    }
}

/// The foreground where no face sets one: opaque black.
pub const BASE_FOREGROUND: Color = Color::rgb(0, 0, 0);
/// The background where no face sets one: opaque white.
pub const BASE_BACKGROUND: Color = Color::rgb(0xff, 0xff, 0xff);

/// How an underline is drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum UnderlineStyle {
    /// No underline: a face sets this to take away the underline of a
    /// face under it.
    #[default]
    None,
    /// One line.
    Single,
    /// Two lines.
    Double,
    /// A wavy line.
    Curly,
    /// A dotted line.
    Dotted,
    /// A dashed line.
    Dashed,
}

/// An underline, as a face sets it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct Underline {
    /// Its style.
    pub style: UnderlineStyle,
    /// Its colour; `None` is the foreground of the run it is under.
    pub color: Option<Color>,
}

/// A face: each attribute set or left unset.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct Face {
    /// The font family's name.
    pub family: Option<String>,
    /// The font's size.
    pub size: Option<Length>,
    /// The font's weight.
    pub weight: Option<Weight>,
    /// The font's slant.
    pub slant: Option<Slant>,
    /// The colour of the glyphs.
    pub foreground: Option<Color>,
    /// The colour behind them.
    pub background: Option<Color>,
    /// The underline.
    pub underline: Option<Underline>,
    /// Whether a line is drawn through the glyphs.
    pub strike_through: Option<bool>,
    /// The line height.
    pub line_height: Option<LineHeight>,
    /// The space above and below the line of a row drawn in it: read only
    /// from the face of a status row, `mode-line` or `echo-area`
    /// ([`frame`](crate::frame), "The mode line"), and ignored in every
    /// other face. A length, in points.
    pub vertical_padding: Option<Length>,
}

impl Face {
    /// This face over `under`: each attribute this face's where it sets
    /// it, and `under`'s where it does not.
    #[must_use]
    pub fn over(&self, under: &Self) -> Self {
        Self {
            family: self.family.clone().or_else(|| under.family.clone()),
            size: self.size.or(under.size),
            weight: self.weight.or(under.weight),
            slant: self.slant.or(under.slant),
            foreground: self.foreground.or(under.foreground),
            background: self.background.or(under.background),
            underline: self.underline.or(under.underline),
            strike_through: self.strike_through.or(under.strike_through),
            line_height: self.line_height.or(under.line_height),
            vertical_padding: self.vertical_padding.or(under.vertical_padding),
        }
    }

    /// Whether it sets an attribute of the font: a family, a size, a
    /// weight, a slant or a line height.
    pub fn sets_font(&self) -> bool {
        self.family.is_some()
            || self.size.is_some()
            || self.weight.is_some()
            || self.slant.is_some()
            || self.line_height.is_some()
    }
}

/// A definition: the attributes a name sets.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct FaceDef {
    /// The face's name.
    pub name: String,
    /// What it sets.
    pub face: Face,
}

/// What a run is painted with: every attribute resolved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Paint {
    /// The colour of the glyphs.
    pub foreground: Color,
    /// The colour behind them.
    pub background: Color,
    /// The underline's style, never [`UnderlineStyle::None`], and its
    /// colour; `None` when there is no underline.
    pub underline: Option<(UnderlineStyle, Color)>,
    /// Whether a line is drawn through the glyphs.
    pub strike_through: bool,
}

/// The base paint: black on white, no underline and no strike-through.
impl Default for Paint {
    fn default() -> Self {
        Self {
            foreground: BASE_FOREGROUND,
            background: BASE_BACKGROUND,
            underline: None,
            strike_through: false,
        }
    }
}

/// A stack of faces resolved: the font a run is shaped in, what it is
/// painted with, and the vertical padding of a row drawn in it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct Resolved {
    /// The font.
    pub font: FontSpec,
    /// The paint.
    pub paint: Paint,
    /// The vertical padding, in points: 0 where no face sets one.
    pub vertical_padding: Length,
}

/// Which face: a number [`Faces`] gave a face's name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FaceId(pub u32);

/// The faces by name: an id for each name a scene has used, and the
/// definitions last sent.
#[derive(Debug, Clone, Default)]
pub struct Faces {
    /// The id of each name interned.
    ids: HashMap<String, FaceId>,
    /// The name of each id, by id.
    names: Vec<String>,
    /// The definitions, in the order sent.
    definitions: Vec<FaceDef>,
    /// What each name interned sets, by id: its definitions merged, a
    /// later one over an earlier one.
    merged: Vec<Face>,
    /// What the default face sets.
    default: Face,
}

impl Faces {
    /// The id of the face `name`, given it the first time it is asked.
    pub fn intern(&mut self, name: &str) -> FaceId {
        if let Some(&id) = self.ids.get(name) {
            return id;
        }
        let id = FaceId(u32::try_from(self.names.len()).unwrap_or(u32::MAX));
        self.names.push(name.to_owned());
        self.ids.insert(name.to_owned(), id);
        self.merged.push(self.merged_of(name));
        id
    }

    /// The name of the face `id`.
    pub fn name(&self, id: FaceId) -> Option<&str> {
        self.names
            .get(usize::try_from(id.0).ok()?)
            .map(String::as_str)
    }

    /// The definitions, in the order sent.
    pub fn definitions(&self) -> &[FaceDef] {
        &self.definitions
    }

    /// Takes `definitions` in place of the definitions it had, and says
    /// whether they differ. A name's id stays its id.
    pub fn define(&mut self, definitions: &[FaceDef]) -> bool {
        if self.definitions == definitions {
            return false;
        }
        self.definitions = definitions.to_vec();
        self.merged = self.names.iter().map(|name| self.merged_of(name)).collect();
        self.default = self.merged_of(DEFAULT_FACE);
        true
    }

    /// What the definitions of `name` set together: each attribute from
    /// the last definition of the name that sets it.
    fn merged_of(&self, name: &str) -> Face {
        self.definitions
            .iter()
            .filter(|definition| definition.name == name)
            .fold(Face::default(), |under, definition| {
                definition.face.over(&under)
            })
    }

    /// Whether a face other than the default face sets an attribute of the
    /// font: when none does, every run is in the default face's font.
    pub fn any_sets_font(&self) -> bool {
        self.definitions
            .iter()
            .any(|definition| definition.name != DEFAULT_FACE && definition.face.sets_font())
    }

    /// The font and the paint of a run under the faces `stack`, given
    /// lowest first, over the default face: each attribute from the
    /// highest face that sets it, and the base value where none does.
    pub fn resolve(&self, stack: &[FaceId]) -> Resolved {
        let face = stack
            .iter()
            .filter_map(|id| self.merged.get(usize::try_from(id.0).ok()?))
            .fold(self.default.clone(), |under, face| face.over(&under));
        let base = Resolved::default();
        let foreground = face.foreground.unwrap_or(base.paint.foreground);
        Resolved {
            font: FontSpec {
                family: face.family,
                size: face.size.unwrap_or(base.font.size),
                weight: face.weight.unwrap_or(base.font.weight),
                slant: face.slant.unwrap_or(base.font.slant),
                line_height: face.line_height.unwrap_or(base.font.line_height),
            },
            paint: Paint {
                foreground,
                background: face.background.unwrap_or(base.paint.background),
                underline: face
                    .underline
                    .filter(|underline| underline.style != UnderlineStyle::None)
                    .map(|underline| (underline.style, underline.color.unwrap_or(foreground))),
                strike_through: face.strike_through.unwrap_or(base.paint.strike_through),
            },
            vertical_padding: face.vertical_padding.unwrap_or(base.vertical_padding),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fmt::Debug;

    use proptest::collection::vec;
    use proptest::option::of;
    use proptest::prelude::*;
    use proptest::sample::select;
    use proptest::test_runner::{Config, RngAlgorithm, TestCaseError, TestRng, TestRunner};

    use super::{
        BASE_BACKGROUND, BASE_FOREGROUND, Color, DEFAULT_FACE, Face, FaceDef, FaceId, Faces, Paint,
        Resolved, Underline, UnderlineStyle,
    };
    use crate::shaper::{BASE_SIZE, FontSpec, Length, LineHeight, Slant, Weight};

    const RED: Color = Color::rgb(0xff, 0, 0);
    const GREEN: Color = Color::rgb(0, 0xff, 0);
    const BLUE: Color = Color::rgb(0, 0, 0xff);

    /// The definition of `name` as `face`.
    fn def(name: &str, face: Face) -> FaceDef {
        FaceDef {
            name: name.to_owned(),
            face,
        }
    }

    /// Faces holding `definitions`.
    fn faces(definitions: &[FaceDef]) -> Faces {
        let mut faces = Faces::default();
        faces.define(definitions);
        faces
    }

    /// The font and the paint of a run under the faces named `stack`,
    /// lowest first.
    fn resolved(faces: &mut Faces, stack: &[&str]) -> Resolved {
        let ids: Vec<FaceId> = stack.iter().map(|name| faces.intern(name)).collect();
        faces.resolve(&ids)
    }

    /// A face that sets every attribute, to values that are none of the
    /// base's.
    fn full() -> Face {
        Face {
            family: Some("serif".to_owned()),
            size: Some(Length::pixels(20)),
            weight: Some(Weight::BOLD),
            slant: Some(Slant::Italic),
            foreground: Some(RED),
            background: Some(BLUE),
            underline: Some(Underline {
                style: UnderlineStyle::Curly,
                color: Some(GREEN),
            }),
            strike_through: Some(true),
            line_height: Some(LineHeight::Pixels(Length::pixels(30))),
            vertical_padding: Some(Length::pixels(3)),
        }
    }

    /// What [`full`] resolves to.
    fn full_resolved() -> Resolved {
        Resolved {
            font: FontSpec {
                family: Some("serif".to_owned()),
                size: Length::pixels(20),
                weight: Weight::BOLD,
                slant: Slant::Italic,
                line_height: LineHeight::Pixels(Length::pixels(30)),
            },
            paint: Paint {
                foreground: RED,
                background: BLUE,
                underline: Some((UnderlineStyle::Curly, GREEN)),
                strike_through: true,
            },
            vertical_padding: Length::pixels(3),
        }
    }

    #[test]
    fn a_colour_is_its_four_bytes_red_first() {
        assert_eq!(Color::rgba(0x12, 0x34, 0x56, 0x78), Color(0x1234_5678));
        assert_eq!(Color::rgb(0x12, 0x34, 0x56), Color(0x1234_56ff));
    }

    #[test]
    fn a_face_over_another_keeps_what_it_sets_and_takes_the_rest() {
        let over = Face {
            foreground: Some(RED),
            weight: Some(Weight::BOLD),
            ..Face::default()
        };
        let under = Face {
            foreground: Some(BLUE),
            background: Some(GREEN),
            ..Face::default()
        };
        assert_eq!(
            over.over(&under),
            Face {
                foreground: Some(RED),
                background: Some(GREEN),
                weight: Some(Weight::BOLD),
                ..Face::default()
            }
        );
        // A face that sets nothing is the face under it, and a face that
        // sets everything is itself.
        assert_eq!(Face::default().over(&full()), full());
        assert_eq!(full().over(&under), full());
    }

    #[test]
    fn the_family_size_weight_slant_and_line_height_are_the_font_and_the_rest_is_paint() {
        let font = [
            Face {
                family: Some("serif".to_owned()),
                ..Face::default()
            },
            Face {
                size: Some(Length::pixels(20)),
                ..Face::default()
            },
            Face {
                weight: Some(Weight::BOLD),
                ..Face::default()
            },
            Face {
                slant: Some(Slant::Oblique),
                ..Face::default()
            },
            Face {
                line_height: Some(LineHeight::Multiple(96)),
                ..Face::default()
            },
        ];
        for face in font {
            assert!(face.sets_font(), "{face:?}");
            let mut faces = faces(&[def("x", face.clone())]);
            let run = resolved(&mut faces, &["x"]);
            assert_ne!(run.font, FontSpec::default(), "{face:?}");
            assert_eq!(run.paint, Paint::default(), "{face:?}");
        }
        let paint = [
            Face {
                foreground: Some(RED),
                ..Face::default()
            },
            Face {
                background: Some(RED),
                ..Face::default()
            },
            Face {
                underline: Some(Underline {
                    style: UnderlineStyle::Single,
                    color: None,
                }),
                ..Face::default()
            },
            Face {
                strike_through: Some(true),
                ..Face::default()
            },
        ];
        for face in paint {
            assert!(!face.sets_font(), "{face:?}");
            let mut faces = faces(&[def("x", face.clone())]);
            let run = resolved(&mut faces, &["x"]);
            assert_eq!(run.font, FontSpec::default(), "{face:?}");
            assert_ne!(run.paint, Paint::default(), "{face:?}");
        }
    }

    #[test]
    fn a_vertical_padding_merges_like_every_attribute_and_is_neither_font_nor_paint() {
        let padded = |points: u32| Face {
            vertical_padding: Some(Length::pixels(points)),
            ..Face::default()
        };
        // Set over unset, and the higher of two that set it.
        assert_eq!(padded(3).over(&Face::default()), padded(3));
        assert_eq!(Face::default().over(&padded(3)), padded(3));
        assert_eq!(padded(5).over(&padded(3)), padded(5));
        // It shapes nothing and paints nothing.
        assert!(!padded(3).sets_font());
        let mut faces = faces(&[def("x", padded(3)), def(DEFAULT_FACE, padded(1))]);
        let run = resolved(&mut faces, &["x"]);
        assert_eq!(run.font, FontSpec::default());
        assert_eq!(run.paint, Paint::default());
        assert_eq!(run.vertical_padding, Length::pixels(3));
        // The default face's where the stack sets none, and none where
        // nothing sets one.
        assert_eq!(
            resolved(&mut faces, &[]).vertical_padding,
            Length::pixels(1)
        );
        assert_eq!(
            resolved(&mut Faces::default(), &[]).vertical_padding,
            Length(0)
        );
    }

    #[test]
    fn a_later_face_of_a_stack_sets_an_attribute_over_an_earlier_one() {
        let mut faces = faces(&[
            def(
                "low",
                Face {
                    foreground: Some(RED),
                    background: Some(GREEN),
                    size: Some(Length::pixels(20)),
                    ..Face::default()
                },
            ),
            def(
                "high",
                Face {
                    foreground: Some(BLUE),
                    size: Some(Length::pixels(32)),
                    ..Face::default()
                },
            ),
        ]);
        let run = resolved(&mut faces, &["low", "high"]);
        assert_eq!(run.paint.foreground, BLUE);
        assert_eq!(run.font.size, Length::pixels(32));
        // What the later one leaves unset is the earlier one's.
        assert_eq!(run.paint.background, GREEN);
        // The stack's order decides, not the definitions'.
        let run = resolved(&mut faces, &["high", "low"]);
        assert_eq!(run.paint.foreground, RED);
        assert_eq!(run.font.size, Length::pixels(20));
    }

    #[test]
    fn an_attribute_no_face_of_a_stack_sets_is_the_default_faces() {
        let mut faces = faces(&[
            def(DEFAULT_FACE, full()),
            def(
                "keyword",
                Face {
                    foreground: Some(GREEN),
                    ..Face::default()
                },
            ),
        ]);
        // No face at all: the default face's.
        assert_eq!(resolved(&mut faces, &[]), full_resolved());
        // A face that sets one attribute: that one, and the default
        // face's for every other.
        let mut expected = full_resolved();
        expected.paint.foreground = GREEN;
        assert_eq!(resolved(&mut faces, &["keyword"]), expected);
        // The default face named in a stack is a face of the stack too,
        // over the faces before it.
        assert_eq!(
            resolved(&mut faces, &["keyword", DEFAULT_FACE]),
            full_resolved()
        );
    }

    #[test]
    fn an_attribute_the_default_face_leaves_unset_is_the_base_value() {
        let base = Resolved {
            font: FontSpec {
                family: None,
                size: BASE_SIZE,
                weight: Weight(400),
                slant: Slant::Upright,
                line_height: LineHeight::Multiple(64),
            },
            paint: Paint {
                foreground: BASE_FOREGROUND,
                background: BASE_BACKGROUND,
                underline: None,
                strike_through: false,
            },
            vertical_padding: Length(0),
        };
        assert_eq!(BASE_SIZE, Length::pixels(16));
        assert_eq!(
            (BASE_FOREGROUND, BASE_BACKGROUND),
            (Color(0xff), Color(u32::MAX))
        );
        // No definition at all.
        assert_eq!(resolved(&mut Faces::default(), &[]), base);
        // A default face that sets a background: the base for the rest.
        let mut faces = faces(&[def(
            DEFAULT_FACE,
            Face {
                background: Some(BLUE),
                ..Face::default()
            },
        )]);
        let mut expected = base.clone();
        expected.paint.background = BLUE;
        assert_eq!(resolved(&mut faces, &[]), expected);
        assert_eq!(resolved(&mut faces, &["undefined"]), expected);
    }

    #[test]
    fn a_name_nothing_defines_sets_nothing() {
        let mut faces = faces(&[def("defined", full())]);
        assert_eq!(resolved(&mut faces, &["undefined"]), Resolved::default());
        assert_eq!(
            resolved(&mut faces, &["defined", "undefined"]),
            full_resolved()
        );
    }

    #[test]
    fn a_name_defined_twice_takes_the_later_definitions_set_attributes() {
        let mut faces = faces(&[
            def(
                "keyword",
                Face {
                    foreground: Some(RED),
                    background: Some(GREEN),
                    ..Face::default()
                },
            ),
            def("other", full()),
            def(
                "keyword",
                Face {
                    foreground: Some(BLUE),
                    weight: Some(Weight::BOLD),
                    ..Face::default()
                },
            ),
        ]);
        let run = resolved(&mut faces, &["keyword"]);
        assert_eq!(run.paint.foreground, BLUE);
        assert_eq!(run.paint.background, GREEN);
        assert_eq!(run.font.weight, Weight::BOLD);
        // The default face likewise.
        let mut faces = self::faces(&[
            def(DEFAULT_FACE, full()),
            def(
                DEFAULT_FACE,
                Face {
                    background: Some(GREEN),
                    ..Face::default()
                },
            ),
        ]);
        let mut expected = full_resolved();
        expected.paint.background = GREEN;
        assert_eq!(resolved(&mut faces, &[]), expected);
    }

    #[test]
    fn an_underline_with_no_colour_takes_the_foreground() {
        let underlined = |color: Option<Color>| Face {
            underline: Some(Underline {
                style: UnderlineStyle::Double,
                color,
            }),
            ..Face::default()
        };
        let mut faces = faces(&[
            def("plain", underlined(None)),
            def("coloured", underlined(Some(GREEN))),
            def(
                "red",
                Face {
                    foreground: Some(RED),
                    ..Face::default()
                },
            ),
            def(
                "none",
                Face {
                    underline: Some(Underline {
                        style: UnderlineStyle::None,
                        color: Some(GREEN),
                    }),
                    ..Face::default()
                },
            ),
        ]);
        let underline = |faces: &mut Faces, stack: &[&str]| resolved(faces, stack).paint.underline;
        assert_eq!(
            underline(&mut faces, &["plain"]),
            Some((UnderlineStyle::Double, BASE_FOREGROUND))
        );
        // The foreground of the run, whichever face of the stack set it.
        assert_eq!(
            underline(&mut faces, &["plain", "red"]),
            Some((UnderlineStyle::Double, RED))
        );
        assert_eq!(
            underline(&mut faces, &["red", "plain"]),
            Some((UnderlineStyle::Double, RED))
        );
        assert_eq!(
            underline(&mut faces, &["red", "coloured"]),
            Some((UnderlineStyle::Double, GREEN))
        );
        // A face that sets the style none takes the underline away.
        assert_eq!(underline(&mut faces, &["coloured", "none"]), None);
        assert_eq!(
            underline(&mut faces, &["none", "coloured"]),
            Some((UnderlineStyle::Double, GREEN))
        );
    }

    #[test]
    fn a_face_name_is_interned_once_and_keeps_its_id_when_the_definitions_change() {
        let mut faces = Faces::default();
        let keyword = faces.intern("keyword");
        assert_eq!(faces.intern("keyword"), keyword);
        assert_ne!(faces.intern("string"), keyword);
        assert_eq!(faces.name(keyword), Some("keyword"));
        assert_eq!(faces.resolve(&[keyword]), Resolved::default());
        // Defined after it was interned, it resolves as defined.
        assert!(faces.define(&[def("keyword", full())]));
        assert_eq!(faces.intern("keyword"), keyword);
        assert_eq!(faces.resolve(&[keyword]), full_resolved());
        assert_eq!(faces.definitions(), [def("keyword", full())]);
        // The same definitions again are no change, and none are one.
        assert!(!faces.define(&[def("keyword", full())]));
        assert!(faces.define(&[]));
        assert_eq!(faces.resolve(&[keyword]), Resolved::default());
    }

    #[test]
    fn only_a_face_that_is_not_the_default_face_makes_a_run_another_font() {
        let bold = Face {
            weight: Some(Weight::BOLD),
            ..Face::default()
        };
        let red = Face {
            foreground: Some(RED),
            ..Face::default()
        };
        assert!(!Faces::default().any_sets_font());
        assert!(!faces(&[def(DEFAULT_FACE, full()), def("red", red.clone())]).any_sets_font());
        assert!(faces(&[def("red", red), def("bold", bold)]).any_sets_font());
    }

    /// Runs `property` on `cases` values of `strategy`, from a fixed seed,
    /// with failure persistence off so no file is written beside the
    /// sources.
    fn check<S>(cases: u32, strategy: S, property: impl Fn(S::Value) -> Result<(), TestCaseError>)
    where
        S: Strategy,
        S::Value: Debug,
    {
        let config = Config {
            cases,
            failure_persistence: None,
            ..Config::default()
        };
        let mut runner =
            TestRunner::new_with_rng(config, TestRng::deterministic_rng(RngAlgorithm::ChaCha));
        if let Err(failure) = runner.run(&strategy, property) {
            panic!("{failure}");
        }
    }

    /// A face with each attribute set or not.
    fn any_face() -> impl Strategy<Value = Face> {
        let colors = || of(select(vec![RED, GREEN, BLUE, BASE_FOREGROUND]));
        let font = (
            of(select(vec!["serif", "mono"])),
            of(select(vec![
                Length::pixels(12),
                Length::pixels(20),
                BASE_SIZE,
            ])),
            of(select(vec![Weight(300), Weight::NORMAL, Weight::BOLD])),
            of(select(vec![Slant::Upright, Slant::Italic, Slant::Oblique])),
            of(select(vec![
                LineHeight::OWN,
                LineHeight::Multiple(96),
                LineHeight::Pixels(Length::pixels(30)),
            ])),
        );
        let styles = select(vec![
            UnderlineStyle::None,
            UnderlineStyle::Single,
            UnderlineStyle::Dashed,
        ]);
        let paint = (
            colors(),
            colors(),
            of((styles, colors())),
            of(any::<bool>()),
        );
        let padding = of(select(vec![Length(0), Length::pixels(3), Length(1)]));
        (font, paint, padding).prop_map(
            |(
                (family, size, weight, slant, line_height),
                (foreground, background, underline, strike_through),
                vertical_padding,
            )| Face {
                family: family.map(str::to_owned),
                size,
                weight,
                slant,
                foreground,
                background,
                underline: underline.map(|(style, color)| Underline { style, color }),
                strike_through,
                line_height,
                vertical_padding,
            },
        )
    }

    /// The value of an attribute under `layers`, given lowest first: that
    /// of the last layer that sets it, or `base`.
    fn highest<T: Clone>(layers: &[Face], get: impl Fn(&Face) -> Option<T>, base: T) -> T {
        layers.iter().rev().find_map(get).unwrap_or(base)
    }

    #[test]
    fn every_attribute_is_the_highest_face_that_sets_it() {
        // A default face, set or not, and a stack of up to five faces.
        let cases = (of(any_face()), vec(any_face(), 0..6));
        check(512, cases, |(default, stack)| {
            let mut definitions: Vec<FaceDef> = default
                .iter()
                .map(|face| def(DEFAULT_FACE, face.clone()))
                .collect();
            let names: Vec<String> = (0..stack.len()).map(|index| format!("f{index}")).collect();
            for (name, face) in names.iter().zip(&stack) {
                definitions.push(def(name, face.clone()));
            }
            let mut faces = faces(&definitions);
            let names: Vec<&str> = names.iter().map(String::as_str).collect();
            let run = resolved(&mut faces, &names);
            // The default face is the lowest layer.
            let layers: Vec<Face> = default.into_iter().chain(stack).collect();
            let base = FontSpec::default();
            prop_assert_eq!(
                run.font.family,
                highest(&layers, |face| face.family.clone().map(Some), None)
            );
            prop_assert_eq!(run.font.size, highest(&layers, |face| face.size, base.size));
            prop_assert_eq!(
                run.font.weight,
                highest(&layers, |face| face.weight, base.weight)
            );
            prop_assert_eq!(
                run.font.slant,
                highest(&layers, |face| face.slant, base.slant)
            );
            prop_assert_eq!(
                run.font.line_height,
                highest(&layers, |face| face.line_height, base.line_height)
            );
            let foreground = highest(&layers, |face| face.foreground, BASE_FOREGROUND);
            prop_assert_eq!(run.paint.foreground, foreground);
            prop_assert_eq!(
                run.paint.background,
                highest(&layers, |face| face.background, BASE_BACKGROUND)
            );
            prop_assert_eq!(
                run.paint.strike_through,
                highest(&layers, |face| face.strike_through, false)
            );
            let underline = highest(&layers, |face| face.underline, Underline::default());
            let expected = (underline.style != UnderlineStyle::None)
                .then(|| (underline.style, underline.color.unwrap_or(foreground)));
            prop_assert_eq!(run.paint.underline, expected);
            prop_assert_eq!(
                run.vertical_padding,
                highest(&layers, |face| face.vertical_padding, Length(0))
            );
            Ok(())
        });
    }
}
