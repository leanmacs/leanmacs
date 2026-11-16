//! A published scene as it crosses: words, one string, and a list of
//! snapshot handles; and the scene they spell before anything in it is
//! resolved ([`WireScene`]).
//!
//! The words, in order (a presence is 0 or 1, and an absent value is
//! written as 0):
//!
//! | Part | Words |
//! |---|---|
//! | The scene | its width and height; the focus's presence and view id; the echo's length; the pending prefix's length; the preedit's presence and length; the title's length; the count of views; each view |
//! | A view | its id; its rectangle's x, y, width and height; its snapshot's presence and index in the list of handles; its scroll marker's presence and number; the count of its selection markers and each one's number; its cursor's shape (0 block, 1 bar, 2 underline, 3 hollow) and its face's length; the count of its decorations and each one's start, stop and face's length; the count of its status fields and each one's text's length and face's length |
//! | The faces, after the last view | their presence (0: as last published); when present, the count of definitions and each definition |
//! | A definition | its name's length; then, for each attribute in this order, a presence and its value, an absent value written as 0: the family's length; the size in 64ths of a point; the weight (1 to 1000); the slant (0 upright, 1 italic, 2 oblique); the foreground as `0xRRGGBBAA`; the background; the underline's style (0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed) followed by its colour's presence and colour; strike-through (0 or 1); the line height's kind (0 a multiple of the font's own in 64ths, 1 a length in 64ths of a point) followed by its value |
//!
//! A definition is 22 words.
//!
//! A point is a logical one: a physical pixel at scale 1. A face's two
//! lengths cross as the theme states them, in points, and no scale
//! crosses with them: layout multiplies them by the scale it has
//! (`editor_layout::face`, "Units"). Every other length of a scene, its
//! size and each view's rectangle, is in physical pixels.
//!
//! The string is every text of the scene one after another, in the order
//! the words give their lengths: the echo, the pending prefix, the preedit
//! if present, the title, then for each view its cursor's face, its decorations' faces
//! and its status fields' texts and faces, then for each definition its
//! name and its family when present. A length that does not end on a
//! character boundary, and text left over, are refusals.
//!
//! **The faces cross with the scene, and only when they changed.** Lean's
//! scene names faces and never says what one looks like, so the binding
//! sends the definitions in the same words and string: a scene and its
//! faces reach layout in one call, under one lock, and no frame is built
//! between the two. Absent faces are "as last published" (layout keeps
//! the ones it has, `editor_layout::scene::Scene::faces`), so a publish
//! costs the definitions only when the binding has new ones; present with
//! a count of 0 is "no definitions", which undefines every face.
//!
//! **The definitions also cross by themselves**, ahead of the scene that
//! will carry them ([`decode_definitions`], [`encode_definitions`]): the
//! words and the string that follow the faces' presence in a scene, the
//! count of definitions and each definition, with nothing before or
//! after. The binding sends them so when it asks the heights its next
//! scene is sized by, so that they are the heights of that scene's frame
//! (`super::editor_ffi_display_define`).
//!
//! Refused, with what was published before kept: a presence that is
//! neither 0 nor 1; a slant, an underline style or a line height's kind
//! that is none of those listed; a weight outside 1 to 1000; a
//! strike-through that is neither 0 nor 1; and a colour, a size or a line
//! height no `u32` holds, which is refused, not cut down. The words of an
//! absent attribute are not looked at. What the attributes mean and how
//! definitions merge are layout's rules (`editor_layout::face`); this
//! module only carries them.
//!
//! A size or a line height of 0 is a length like any other and crosses as
//! it is. Lines of no height are layout's to bound, whatever made them so
//! (`editor_layout::query`, "The rows that fit"); refusing 0 here would
//! bound nothing, since a size of a 64th of a point is as flat.
//!
//! A marker's number is its document's number for it: the display resolves
//! it against the document of the view's snapshot
//! ([`crate::snapshot::Snapshot::marker`]). [`WireScene`] keeps the scene
//! as it crossed, so it is written back as the same words and string
//! ([`WireScene::encode`]), which is the round trip Lean checks.

use editor_layout::face::{Color, Face, FaceDef, Underline, UnderlineStyle};
use editor_layout::scene::{
    Cursor, CursorShape, Decoration, Rect, Scene, Size, StatusField, View, ViewId,
};
use editor_layout::shaper::{Length, LineHeight, Slant, Weight};
use editor_text::Marker;

use super::text_ref;
use crate::snapshot::Snapshot;
use crate::words::{Reader, Writer};

/// A view as it crossed: the numbers and texts Lean sent.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WireView {
    /// Its id.
    pub id: u64,
    /// Its rectangle: x, y, width and height.
    pub rect: [u64; 4],
    /// The index of its snapshot in the list of handles, if it has one.
    pub snapshot: Option<u64>,
    /// Its scroll marker's number, if it has one.
    pub scroll: Option<u64>,
    /// Its selection markers' numbers.
    pub selections: Vec<u64>,
    /// Its cursor's shape, as its tag.
    pub cursor_shape: u64,
    /// Its cursor's face.
    pub cursor_face: String,
    /// Its decorations: start, stop and face.
    pub decorations: Vec<(u64, u64, String)>,
    /// Its status fields: text and face.
    pub status: Vec<(String, String)>,
}

/// A definition of a face as it crossed: the name, and what it sets, in
/// layout's terms. Every value was checked as it was read, so it is one
/// layout takes as it is.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WireFace {
    /// The face's name.
    pub name: String,
    /// What it sets.
    pub face: Face,
}

/// A scene as it crossed, before its handles and markers are resolved.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WireScene {
    /// The frame's width and height.
    pub size: [u64; 2],
    /// The focused view's id, if one has the focus.
    pub focused: Option<u64>,
    /// The echo area's text.
    pub echo: String,
    /// The pending key prefix.
    pub pending: String,
    /// The preedit text, if any.
    pub preedit: Option<String>,
    /// The window's title. Layout draws no title: [`WireScene::resolve`]
    /// leaves it out, and the display hands it to its presenter.
    pub title: String,
    /// The views, in drawing order.
    pub views: Vec<WireView>,
    /// The definitions of the faces, in the order they were made; `None`
    /// when the scene carried none, which is "as last published".
    pub faces: Option<Vec<WireFace>>,
}

/// The cursor shape `tag` stands for.
fn shape(tag: u64) -> Option<CursorShape> {
    match tag {
        0 => Some(CursorShape::Block),
        1 => Some(CursorShape::Bar),
        2 => Some(CursorShape::Underline),
        3 => Some(CursorShape::Hollow),
        _ => None,
    }
}

/// Texts being read, by length, from the string a scene crossed with.
struct Texts<'a> {
    /// The string not yet read.
    rest: &'a str,
}

impl Texts<'_> {
    /// The next `len` bytes, as text. `None` when there are fewer, or they
    /// do not end on a character boundary.
    fn take(&mut self, len: usize) -> Option<String> {
        if !self.rest.is_char_boundary(len) {
            return None;
        }
        let (text, rest) = self.rest.split_at(len);
        self.rest = rest;
        Some(text.to_owned())
    }
}

/// An optional value: its presence word, then its value word. `None` when
/// the words run out or the presence is neither 0 nor 1.
fn optional(words: &mut Reader<'_>) -> Option<Option<u64>> {
    match (words.word()?, words.word()?) {
        (0, _) => Some(None),
        (1, value) => Some(Some(value)),
        _ => None,
    }
}

/// Writes `value` as its presence word and its value word.
fn write_optional(words: &mut Writer, value: Option<u64>) {
    words.word(u64::from(value.is_some()));
    words.word(value.unwrap_or(0));
}

/// How many words a definition of a face is.
const FACE_WORDS: usize = 22;

/// A presence word: whether what follows is there. `None` when the words
/// run out or it is neither 0 nor 1.
fn presence(words: &mut Reader<'_>) -> Option<bool> {
    match words.word()? {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    }
}

/// The `u32` of a colour, a size or a line height. `None` when no `u32`
/// holds `word`: it is refused, never cut down to another value.
fn narrow(word: u64) -> Option<u32> {
    u32::try_from(word).ok()
}

/// An optional colour, a size or a line height's value: `optional`, with
/// a present value narrowed.
fn optional_u32(words: &mut Reader<'_>) -> Option<Option<u32>> {
    match optional(words)? {
        Some(word) => Some(Some(narrow(word)?)),
        None => Some(None),
    }
}

/// The tag of each slant. The wire must give every slant a tag, so this
/// names each one: a slant layout adds needs a tag here, a row in the
/// module's table and a constructor in Lean.
const SLANTS: [(u64, Slant); 3] = [(0, Slant::Upright), (1, Slant::Italic), (2, Slant::Oblique)];

/// The tag of each underline style; as [`SLANTS`].
const UNDERLINES: [(u64, UnderlineStyle); 6] = [
    (0, UnderlineStyle::None),
    (1, UnderlineStyle::Single),
    (2, UnderlineStyle::Double),
    (3, UnderlineStyle::Curly),
    (4, UnderlineStyle::Dotted),
    (5, UnderlineStyle::Dashed),
];

/// The value `tag` stands for in `tags`, if it stands for one.
fn tagged<T: Copy>(tags: &[(u64, T)], tag: u64) -> Option<T> {
    tags.iter()
        .find(|(known, _)| *known == tag)
        .map(|(_, value)| *value)
}

/// The tag of `value` in `tags`: 0 for a value the table does not hold,
/// which no value of today is.
fn tag_of<T: Copy + PartialEq>(tags: &[(u64, T)], value: T) -> u64 {
    tags.iter()
        .find(|(_, known)| *known == value)
        .map_or(0, |(tag, _)| *tag)
}

/// Reads one definition of a face: its 22 words, and its name and its
/// family from `texts`. The words of an attribute that is absent are read
/// and not looked at.
fn face(words: &mut Reader<'_>, texts: &mut Texts<'_>) -> Option<WireFace> {
    let name = texts.take(words.size()?)?;
    let family = match optional(words)? {
        Some(len) => Some(texts.take(crate::words::size(len))?),
        None => None,
    };
    let size = optional_u32(words)?.map(Length);
    let weight = match optional(words)? {
        Some(weight @ 1..=1000) => Some(Weight(u16::try_from(weight).ok()?)),
        Some(_) => return None,
        None => None,
    };
    let slant = match optional(words)? {
        Some(tag) => Some(tagged(&SLANTS, tag)?),
        None => None,
    };
    let foreground = optional_u32(words)?.map(Color);
    let background = optional_u32(words)?.map(Color);
    let underline = if presence(words)? {
        Some(Underline {
            style: tagged(&UNDERLINES, words.word()?)?,
            color: optional_u32(words)?.map(Color),
        })
    } else {
        let _unread = (words.word()?, words.word()?, words.word()?);
        None
    };
    let strike_through = match optional(words)? {
        Some(0) => Some(false),
        Some(1) => Some(true),
        Some(_) => return None,
        None => None,
    };
    let line_height = if presence(words)? {
        let (kind, value) = (words.word()?, narrow(words.word()?)?);
        Some(match kind {
            0 => LineHeight::Multiple(value),
            1 => LineHeight::Pixels(Length(value)),
            _ => return None,
        })
    } else {
        let _unread = (words.word()?, words.word()?);
        None
    };
    Some(WireFace {
        name,
        face: Face {
            family,
            size,
            weight,
            slant,
            foreground,
            background,
            underline,
            strike_through,
            line_height,
            vertical_padding: None,
        },
    })
}

/// Writes one definition of a face: its 22 words, and its name and its
/// family to `strings`.
fn write_face(words: &mut Writer, strings: &mut String, definition: &WireFace) {
    let face = &definition.face;
    words.size(definition.name.len());
    strings.push_str(&definition.name);
    let family = face.family.as_deref();
    words.word(u64::from(family.is_some()));
    words.size(family.map_or(0, str::len));
    strings.push_str(family.unwrap_or(""));
    write_optional(words, face.size.map(|size| u64::from(size.0)));
    write_optional(words, face.weight.map(|weight| u64::from(weight.0)));
    write_optional(words, face.slant.map(|slant| tag_of(&SLANTS, slant)));
    write_optional(words, face.foreground.map(|color| u64::from(color.0)));
    write_optional(words, face.background.map(|color| u64::from(color.0)));
    words.word(u64::from(face.underline.is_some()));
    let underline = face.underline.unwrap_or_default();
    words.word(tag_of(&UNDERLINES, underline.style));
    write_optional(words, underline.color.map(|color| u64::from(color.0)));
    write_optional(words, face.strike_through.map(u64::from));
    // A line height's kind is its tag: the wire must tell every kind
    // apart, so a kind layout adds needs a tag here and in `face`.
    let (kind, value) = match face.line_height {
        Some(LineHeight::Multiple(multiple)) => (0, multiple),
        Some(LineHeight::Pixels(pixels)) => (1, pixels.0),
        None => (0, 0),
    };
    words.word(u64::from(face.line_height.is_some()));
    words.word(kind);
    words.word(u64::from(value));
}

/// Reads the count of definitions and each definition.
fn definitions(words: &mut Reader<'_>, texts: &mut Texts<'_>) -> Option<Vec<WireFace>> {
    let count = words.count(FACE_WORDS)?;
    (0..count).map(|_| face(words, texts)).collect()
}

/// Writes the count of `definitions` and each definition.
fn write_definitions(words: &mut Writer, strings: &mut String, definitions: &[WireFace]) {
    words.size(definitions.len());
    for definition in definitions {
        write_face(words, strings, definition);
    }
}

/// The definitions `words` and `strings` spell when they cross by
/// themselves, to be defined with no scene
/// ([`editor_ffi_display_define`](super::editor_ffi_display_define)): the
/// count of definitions and each definition, the words and the string
/// that follow the faces' presence in a scene, and nothing left over.
/// `None` when they spell none.
pub fn decode_definitions(words: &[u8], strings: &str) -> Option<Vec<WireFace>> {
    let mut words = Reader::new(words)?;
    let mut texts = Texts { rest: strings };
    let faces = definitions(&mut words, &mut texts)?;
    words.finish()?;
    texts.rest.is_empty().then_some(faces)
}

/// The words and the string that spell `definitions` by themselves
/// ([`decode_definitions`]).
pub fn encode_definitions(definitions: &[WireFace]) -> (Vec<u8>, String) {
    let mut words = Writer::with_capacity(1 + FACE_WORDS * definitions.len());
    let mut strings = String::new();
    write_definitions(&mut words, &mut strings, definitions);
    (words.finish(), strings)
}

/// The definitions as layout takes them.
pub fn face_defs(definitions: &[WireFace]) -> Vec<FaceDef> {
    definitions
        .iter()
        .map(|definition| FaceDef {
            name: definition.name.clone(),
            face: definition.face.clone(),
        })
        .collect()
}

/// Reads one view.
fn view(words: &mut Reader<'_>, texts: &mut Texts<'_>) -> Option<WireView> {
    let id = words.word()?;
    let rect = [words.word()?, words.word()?, words.word()?, words.word()?];
    let snapshot = optional(words)?;
    let scroll = optional(words)?;
    let count = words.count(1)?;
    let selections = (0..count).map(|_| words.word()).collect::<Option<_>>()?;
    let cursor_shape = words.word()?;
    shape(cursor_shape)?;
    let cursor_face = texts.take(words.size()?)?;
    let count = words.count(3)?;
    let mut decorations = Vec::with_capacity(count);
    for _ in 0..count {
        let (start, stop) = (words.word()?, words.word()?);
        decorations.push((start, stop, texts.take(words.size()?)?));
    }
    let count = words.count(2)?;
    let mut status = Vec::with_capacity(count);
    for _ in 0..count {
        let (text, face) = (words.size()?, words.size()?);
        status.push((texts.take(text)?, texts.take(face)?));
    }
    Some(WireView {
        id,
        rect,
        snapshot,
        scroll,
        selections,
        cursor_shape,
        cursor_face,
        decorations,
        status,
    })
}

impl WireScene {
    /// The scene `words` and `strings` spell, in the layout of the module
    /// docs. `None` when they do not spell one.
    pub fn decode(words: &[u8], strings: &str) -> Option<Self> {
        let mut words = Reader::new(words)?;
        let mut texts = Texts { rest: strings };
        let size = [words.word()?, words.word()?];
        let focused = optional(&mut words)?;
        let echo = texts.take(words.size()?)?;
        let pending = texts.take(words.size()?)?;
        let preedit = match optional(&mut words)? {
            Some(len) => Some(texts.take(crate::words::size(len))?),
            None => None,
        };
        let title = texts.take(words.size()?)?;
        // A view is at least fourteen words.
        let count = words.count(14)?;
        let views = (0..count)
            .map(|_| view(&mut words, &mut texts))
            .collect::<Option<_>>()?;
        let faces = if presence(&mut words)? {
            Some(definitions(&mut words, &mut texts)?)
        } else {
            None
        };
        words.finish()?;
        texts.rest.is_empty().then_some(Self {
            size,
            focused,
            echo,
            pending,
            preedit,
            title,
            views,
            faces,
        })
    }

    /// The words and the string that spell this scene.
    pub fn encode(&self) -> (Vec<u8>, String) {
        let mut words = Writer::with_capacity(10 + 20 * self.views.len());
        let mut strings = String::new();
        /// Writes `text`'s length and adds it to the string.
        fn text(words: &mut Writer, strings: &mut String, text: &str) {
            words.size(text.len());
            strings.push_str(text);
        }
        words.word(self.size[0]);
        words.word(self.size[1]);
        write_optional(&mut words, self.focused);
        text(&mut words, &mut strings, &self.echo);
        text(&mut words, &mut strings, &self.pending);
        words.word(u64::from(self.preedit.is_some()));
        text(
            &mut words,
            &mut strings,
            self.preedit.as_deref().unwrap_or(""),
        );
        text(&mut words, &mut strings, &self.title);
        words.size(self.views.len());
        for view in &self.views {
            words.word(view.id);
            for value in view.rect {
                words.word(value);
            }
            write_optional(&mut words, view.snapshot);
            write_optional(&mut words, view.scroll);
            words.size(view.selections.len());
            for &number in &view.selections {
                words.word(number);
            }
            words.word(view.cursor_shape);
            text(&mut words, &mut strings, &view.cursor_face);
            words.size(view.decorations.len());
            for (start, stop, face) in &view.decorations {
                words.word(*start);
                words.word(*stop);
                text(&mut words, &mut strings, face);
            }
            words.size(view.status.len());
            for (field, face) in &view.status {
                words.size(field.len());
                words.size(face.len());
                strings.push_str(field);
                strings.push_str(face);
            }
        }
        words.word(u64::from(self.faces.is_some()));
        if let Some(faces) = &self.faces {
            write_definitions(&mut words, &mut strings, faces);
        }
        (words.finish(), strings)
    }

    /// The scene layout takes: each view's snapshot the handle at its
    /// index in `snapshots` (none when there is no such handle), its scroll
    /// anchor the offset of the anchor marker its number names in the
    /// snapshot's document as it is now (0 when it names none), and its
    /// selections those of the selection markers its numbers name (each
    /// on its own: one that names none is left out).
    pub fn resolve(&self, snapshots: &[&Snapshot]) -> Scene {
        let views = self
            .views
            .iter()
            .map(|view| {
                let snapshot = view
                    .snapshot
                    .and_then(|index| snapshots.get(usize::try_from(index).ok()?).copied());
                let marker = |number: u64| snapshot.and_then(|snapshot| snapshot.marker(number));
                let scroll = match view.scroll.and_then(marker) {
                    Some(Marker::Anchor(anchor)) => anchor.offset,
                    _ => 0,
                };
                let selections = view
                    .selections
                    .iter()
                    .filter_map(|&number| match marker(number) {
                        Some(Marker::Selection(selection)) => Some(selection),
                        _ => None,
                    })
                    .collect();
                View {
                    id: ViewId(view.id),
                    rect: Rect {
                        x: pixels(view.rect[0]),
                        y: pixels(view.rect[1]),
                        width: pixels(view.rect[2]),
                        height: pixels(view.rect[3]),
                    },
                    text: snapshot.map(text_ref),
                    scroll,
                    selections,
                    cursor: Cursor {
                        shape: shape(view.cursor_shape).unwrap_or_default(),
                        face: view.cursor_face.clone(),
                    },
                    decorations: view
                        .decorations
                        .iter()
                        .map(|(start, stop, face)| Decoration {
                            start: crate::words::size(*start),
                            stop: crate::words::size(*stop),
                            face: face.clone(),
                        })
                        .collect(),
                    status: view
                        .status
                        .iter()
                        .map(|(text, face)| StatusField {
                            text: text.clone(),
                            face: face.clone(),
                            ..StatusField::default()
                        })
                        .collect(),
                    status_face: None,
                }
            })
            .collect();
        Scene {
            size: Size {
                width: pixels(self.size[0]),
                height: pixels(self.size[1]),
            },
            views,
            focused: self.focused.map(ViewId),
            echo: self.echo.clone(),
            pending: self.pending.clone(),
            preedit: self.preedit.clone(),
            faces: self.faces.as_deref().map(face_defs),
        }
    }
}

/// The `u32` of a pixel count, the largest for one no `u32` holds.
fn pixels(count: u64) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use editor_layout::face::{Color, Face, Underline, UnderlineStyle};
    use editor_layout::scene::CursorShape;
    use editor_layout::shaper::{Length, LineHeight, Slant, Weight};
    use editor_text::{Anchor, Bias, Marker, Selection, SelectionRange};

    use super::{WireFace, WireScene, WireView, decode_definitions, encode_definitions, pixels};
    use crate::document::Document;
    use crate::snapshot::Snapshot;
    use crate::words::tests::buffer;

    /// A scene with every part present.
    fn full() -> WireScene {
        WireScene {
            size: [96, 112],
            focused: Some(1),
            echo: "fixture".to_owned(),
            pending: "g".to_owned(),
            preedit: Some("é".to_owned()),
            title: "notes.txt".to_owned(),
            views: vec![WireView {
                id: 1,
                rect: [0, 0, 96, 80],
                snapshot: Some(0),
                scroll: Some(0),
                selections: vec![1, 2],
                cursor_shape: 2,
                cursor_face: "cursor.normal".to_owned(),
                decorations: vec![(0, 2, "keyword".to_owned())],
                status: vec![("NORMAL".to_owned(), "mode".to_owned())],
            }],
            faces: None,
        }
    }

    #[test]
    fn a_scene_crosses_as_the_words_and_the_string_of_the_module_docs() {
        let (words, strings) = full().encode();
        assert_eq!(
            words,
            buffer(&[
                96, 112, 1, 1, 7, 1, 1, 2, 9, 1, // the scene
                1, 0, 0, 96, 80, 1, 0, 1, 0, 2, 1, 2, 2, 13, // the view
                1, 0, 2, 7, 1, 6, 4, // its decorations and status
                0, // no faces
            ])
        );
        assert_eq!(strings, "fixturegénotes.txtcursor.normalkeywordNORMALmode");
        assert_eq!(WireScene::decode(&words, &strings), Some(full()));
    }

    #[test]
    fn a_scenes_title_crosses_after_the_preedit_and_comes_back_as_sent() {
        let titled = WireScene {
            preedit: Some("é".to_owned()),
            title: "todo.txt".to_owned(),
            ..WireScene::default()
        };
        let (words, strings) = titled.encode();
        // The preedit's presence and length, then the title's length, then
        // no view and no faces.
        assert_eq!(words, buffer(&[0, 0, 0, 0, 0, 0, 1, 2, 8, 0, 0]));
        assert_eq!(strings, "étodo.txt");
        assert_eq!(WireScene::decode(&words, &strings), Some(titled));
    }

    #[test]
    fn a_title_that_ends_inside_a_character_is_refused() {
        let titled = WireScene {
            title: "é".to_owned(),
            ..WireScene::default()
        };
        let (mut words, strings) = titled.encode();
        assert_eq!(WireScene::decode(&words, &strings), Some(titled));
        // The title's length, 2, made 1: it ends inside "é", and the byte
        // left over is no text.
        words[8 * 8] = 1;
        assert_eq!(WireScene::decode(&words, &strings), None);
    }

    #[test]
    fn absent_parts_are_written_as_zero_and_read_back_absent() {
        let empty = WireScene::default();
        let (words, strings) = empty.encode();
        assert_eq!(words, buffer(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
        assert_eq!(WireScene::decode(&words, &strings), Some(empty));
        // A view with nothing in it is its fourteen words, between the
        // scene's ten and the faces' presence.
        let bare = WireScene {
            views: vec![WireView::default()],
            ..WireScene::default()
        };
        let (words, strings) = bare.encode();
        assert_eq!(words.len(), (10 + 14 + 1) * 8);
        assert_eq!(WireScene::decode(&words, &strings), Some(bare));
    }

    /// A definition that sets every attribute, and its 22 words.
    fn every() -> (WireFace, [u64; 22]) {
        let face = WireFace {
            name: "kw".to_owned(),
            face: Face {
                family: Some("mono".to_owned()),
                size: Some(Length(1312)),
                weight: Some(Weight(700)),
                slant: Some(Slant::Italic),
                foreground: Some(Color(0x1122_3344)),
                background: Some(Color(0xaabb_ccdd)),
                underline: Some(Underline {
                    style: UnderlineStyle::Curly,
                    color: Some(Color(0xff00_00ff)),
                }),
                strike_through: Some(true),
                line_height: Some(LineHeight::Pixels(Length(1536))),
                vertical_padding: None,
            },
        };
        let words = [
            2, // the name's length
            1,
            4, // the family's length
            1,
            1312, // the size
            1,
            700, // the weight
            1,
            1, // the slant: italic
            1,
            0x1122_3344, // the foreground
            1,
            0xaabb_ccdd, // the background
            1,
            3,
            1,
            0xff00_00ff, // the underline: curly, with a colour
            1,
            1, // struck through
            1,
            1,
            1536, // the line height: pixels
        ];
        (face, words)
    }

    /// A scene of no view with the definitions `faces`.
    fn with_faces(faces: Vec<WireFace>) -> WireScene {
        WireScene {
            faces: Some(faces),
            ..WireScene::default()
        }
    }

    #[test]
    fn a_scene_with_faces_crosses_as_the_words_and_the_string_of_the_module_docs() {
        let (every, every_words) = every();
        let unset = WireFace {
            name: "x".to_owned(),
            face: Face::default(),
        };
        let scene = with_faces(vec![every, unset]);
        let (words, strings) = scene.encode();
        let mut expected = vec![0; 10];
        // Present, and two definitions.
        expected.extend([1, 2]);
        expected.extend(every_words);
        // A definition that sets nothing: its name's length and 21 zeros.
        expected.push(1);
        expected.extend([0; 21]);
        assert_eq!(words, buffer(&expected));
        // Each definition's name, then its family when it has one.
        assert_eq!(strings, "kwmonox");
        assert_eq!(WireScene::decode(&words, &strings), Some(scene));
        // After the views' texts.
        let mut full = full();
        full.faces = Some(vec![self::every().0]);
        let (words, strings) = full.encode();
        assert_eq!(
            strings,
            "fixturegénotes.txtcursor.normalkeywordNORMALmodekwmono"
        );
        assert_eq!(WireScene::decode(&words, &strings), Some(full));
    }

    #[test]
    fn faces_that_are_absent_are_one_word_and_no_definitions_are_two() {
        let absent = WireScene::default();
        let none = with_faces(vec![]);
        assert_eq!(absent.encode().0, buffer(&[0; 11]));
        let (words, strings) = none.encode();
        let mut expected = vec![0; 10];
        expected.extend([1, 0]);
        assert_eq!(words, buffer(&expected));
        // They read back apart: absent is "as last published", and no
        // definitions is every face undefined.
        assert_eq!(WireScene::decode(&words, &strings), Some(none));
        assert_ne!(
            WireScene::decode(&words, &strings),
            WireScene::decode(&buffer(&[0; 11]), "")
        );
    }

    #[test]
    fn every_tag_of_a_face_crosses() {
        let face = |face: Face| WireFace {
            name: String::new(),
            face,
        };
        // The words of a definition from its slant's presence on.
        let tail = |definition: WireFace| -> Vec<u64> {
            let (words, strings) = with_faces(vec![definition.clone()]).encode();
            assert_eq!(
                WireScene::decode(&words, &strings),
                Some(with_faces(vec![definition]))
            );
            crate::words::tests::words_of(&words)[19..].to_vec()
        };
        let slants = [Slant::Upright, Slant::Italic, Slant::Oblique];
        for (tag, slant) in (0..).zip(slants) {
            let words = tail(face(Face {
                slant: Some(slant),
                ..Face::default()
            }));
            assert_eq!(words[..2], [1, tag], "{slant:?}");
        }
        let styles = [
            UnderlineStyle::None,
            UnderlineStyle::Single,
            UnderlineStyle::Double,
            UnderlineStyle::Curly,
            UnderlineStyle::Dotted,
            UnderlineStyle::Dashed,
        ];
        for (tag, style) in (0..).zip(styles) {
            // With no colour of its own.
            let words = tail(face(Face {
                underline: Some(Underline { style, color: None }),
                ..Face::default()
            }));
            assert_eq!(words[6..10], [1, tag, 0, 0], "{style:?}");
        }
        let heights = [
            (LineHeight::Multiple(96), [1, 0, 96]),
            (LineHeight::Pixels(Length(1280)), [1, 1, 1280]),
        ];
        for (height, expected) in heights {
            let words = tail(face(Face {
                line_height: Some(height),
                ..Face::default()
            }));
            assert_eq!(words[12..], expected, "{height:?}");
        }
        // Not struck through is set, and is not unset.
        let words = tail(face(Face {
            strike_through: Some(false),
            ..Face::default()
        }));
        assert_eq!(words[10..12], [1, 0]);
    }

    #[test]
    fn words_that_spell_no_face_are_refused() {
        let (every, _) = every();
        let (bytes, strings) = with_faces(vec![every]).encode();
        let words = crate::words::tests::words_of(&bytes);
        assert_eq!(words.len(), 10 + 2 + 22);
        // The scene's words with the word at `index` made `value`.
        let with = |index: usize, value: u64| {
            let mut words = words.clone();
            words[index] = value;
            WireScene::decode(&buffer(&words), &strings)
        };
        // As they are, they spell it.
        assert!(with(10, 1).is_some());
        let too_big = u64::from(u32::MAX) + 1;
        let refused = [
            (10, 2, "a presence of the faces that is neither 0 nor 1"),
            (11, 2, "more definitions than there are words for"),
            (13, 2, "a presence of an attribute that is neither 0 nor 1"),
            (15, 2, "the size's presence"),
            (16, too_big, "a size no u32 holds"),
            (17, 2, "the weight's presence"),
            (18, 0, "a weight under 1"),
            (18, 1001, "a weight over 1000"),
            (19, 2, "the slant's presence"),
            (20, 3, "a slant that is none"),
            (21, 2, "the foreground's presence"),
            (22, too_big, "a foreground no u32 holds"),
            (23, 2, "the background's presence"),
            (24, too_big, "a background no u32 holds"),
            (25, 2, "the underline's presence"),
            (26, 6, "an underline style that is none"),
            (27, 2, "the underline's colour's presence"),
            (28, too_big, "an underline colour no u32 holds"),
            (29, 2, "strike-through's presence"),
            (30, 2, "a strike-through that is neither 0 nor 1"),
            (31, 2, "the line height's presence"),
            (32, 2, "a line height's kind that is none"),
            (33, too_big, "a line height no u32 holds"),
            (12, 3, "a name that takes the family's text"),
            (14, 5, "a family longer than the text left"),
        ];
        for (index, value, what) in refused {
            assert_eq!(with(index, value), None, "{what}");
        }
        // The largest values are taken.
        let largest = u64::from(u32::MAX);
        for (index, value) in [
            (16, largest),
            (18, 1),
            (18, 1000),
            (22, largest),
            (33, largest),
        ] {
            assert!(with(index, value).is_some(), "word {index} as {value}");
        }
        // And the smallest: a size and a line height of 0 are lengths
        // like any other and cross as they are, neither refused nor made
        // another length.
        let face_with = |index: usize| with(index, 0)?.faces?.pop().map(|flat| flat.face);
        assert_eq!(
            face_with(16).map(|face| face.size),
            Some(Some(Length(0))),
            "a size of 0"
        );
        assert_eq!(
            face_with(33).map(|face| face.line_height),
            Some(Some(LineHeight::Pixels(Length(0)))),
            "a line height of 0"
        );
        // A name's length ending inside a character, the string as long
        // as ever: `k`, then `é` across where the name ends.
        let inside = strings.replacen("wm", "é", 1);
        assert_eq!(inside.len(), strings.len());
        assert_eq!(WireScene::decode(&bytes, &inside), None);
        // A word short, a word over, and text over.
        assert_eq!(WireScene::decode(&bytes[..bytes.len() - 8], &strings), None);
        let mut longer = bytes.clone();
        longer.extend_from_slice(&[0; 8]);
        assert_eq!(WireScene::decode(&longer, &strings), None);
        assert_eq!(WireScene::decode(&bytes, &format!("{strings}x")), None);
        // Words that stop where the faces' presence would be.
        assert_eq!(WireScene::decode(&buffer(&[0; 10]), ""), None);
    }

    #[test]
    fn definitions_cross_by_themselves_as_they_follow_the_faces_presence_in_a_scene() {
        let (every, every_words) = every();
        let unset = WireFace {
            name: "x".to_owned(),
            face: Face::default(),
        };
        let definitions = vec![every, unset];
        let (words, strings) = encode_definitions(&definitions);
        let mut expected = vec![2];
        expected.extend(every_words);
        expected.push(1);
        expected.extend([0; 21]);
        assert_eq!(words, buffer(&expected));
        assert_eq!(strings, "kwmonox");
        assert_eq!(
            decode_definitions(&words, &strings),
            Some(definitions.clone())
        );
        // The words and the string a scene of no view carries them in,
        // after its ten words and the faces' presence.
        let (scene_words, scene_strings) = with_faces(definitions).encode();
        assert_eq!(scene_words[11 * 8..], words[..]);
        assert_eq!(scene_strings, strings);
        // No definitions is a count of 0, and undefines every face.
        let (none, none_strings) = encode_definitions(&[]);
        assert_eq!((none.clone(), none_strings.as_str()), (buffer(&[0]), ""));
        assert_eq!(decode_definitions(&none, ""), Some(vec![]));
        // A word short, a word over, text over and no words at all are
        // refused.
        assert_eq!(
            decode_definitions(&words[..words.len() - 8], &strings),
            None
        );
        let mut longer = words.clone();
        longer.extend_from_slice(&[0; 8]);
        assert_eq!(decode_definitions(&longer, &strings), None);
        assert_eq!(decode_definitions(&words, &format!("{strings}y")), None);
        assert_eq!(decode_definitions(&[], ""), None);
    }

    #[test]
    fn the_definitions_reach_layout_in_the_order_they_crossed() {
        let named = |name: &str, weight: u16| WireFace {
            name: name.to_owned(),
            face: Face {
                weight: Some(Weight(weight)),
                ..Face::default()
            },
        };
        let wire = with_faces(vec![
            named("default", 300),
            named("keyword", 700),
            named("default", 500),
        ]);
        let definitions = wire.resolve(&[]).faces.expect("the definitions");
        let crossed: Vec<(&str, Option<Weight>)> = definitions
            .iter()
            .map(|definition| (definition.name.as_str(), definition.face.weight))
            .collect();
        assert_eq!(
            crossed,
            vec![
                ("default", Some(Weight(300))),
                ("keyword", Some(Weight(700))),
                ("default", Some(Weight(500)))
            ]
        );
        // A scene that carried none gives layout none, which keeps what
        // it has; one that carried an empty list gives it that.
        assert!(WireScene::default().resolve(&[]).faces.is_none());
        assert_eq!(with_faces(vec![]).resolve(&[]).faces, Some(vec![]));
    }

    #[test]
    fn words_that_spell_no_scene_are_refused() {
        let (words, strings) = full().encode();
        // Short a word, a word over, text short, text over.
        assert_eq!(WireScene::decode(&words[..words.len() - 8], &strings), None);
        let mut longer = words.clone();
        longer.extend_from_slice(&[0; 8]);
        assert_eq!(WireScene::decode(&longer, &strings), None);
        assert_eq!(
            WireScene::decode(&words, &strings[..strings.len() - 1]),
            None
        );
        assert_eq!(WireScene::decode(&words, &format!("{strings}x")), None);
        // The echo's length ending inside "é", the string as long as ever.
        let inside = strings.replacen("eg", "é", 1);
        assert_eq!(inside.len(), strings.len());
        assert_eq!(WireScene::decode(&words, &inside), None);
        // A shape that is none.
        let mut shapeless = full();
        shapeless.views[0].cursor_shape = 4;
        let (words, strings) = shapeless.encode();
        assert_eq!(WireScene::decode(&words, &strings), None);
    }

    #[test]
    fn markers_are_resolved_each_on_its_own_against_the_snapshots_document() {
        let document = Document::new("abcdef");
        let (anchor, first, second) = {
            let mut text = document.lock();
            let anchor = text
                .mark(Marker::Anchor(Anchor {
                    offset: 2,
                    bias: Bias::Before,
                }))
                .unwrap();
            let first = Selection::new(vec![SelectionRange::new(1, 3)], 0).unwrap();
            let second = Selection::new(vec![SelectionRange::new(5, 5)], 0).unwrap();
            let one = text.mark(Marker::Selection(first)).unwrap();
            let two = text.mark(Marker::Selection(second)).unwrap();
            (anchor.get(), one.get(), two.get())
        };
        let snapshot = Snapshot::of(&document);
        let mut wire = full();
        wire.views[0].scroll = Some(anchor);
        // One that names nothing, and the anchor, which is not a selection.
        wire.views[0].selections = vec![first, 99, anchor, second];
        let scene = wire.resolve(&[&snapshot]);
        let view = &scene.views[0];
        assert_eq!(view.scroll, 2);
        let heads: Vec<usize> = view
            .selections
            .iter()
            .map(|selection| selection.ranges()[0].head)
            .collect();
        assert_eq!(heads, vec![3, 5]);
        assert_eq!(view.cursor.shape, CursorShape::Underline);
        assert_eq!(view.rect.width, 96);
        assert_eq!(view.decorations[0].face, "keyword");
        assert_eq!(scene.echo, "fixture");
        assert_eq!(scene.focused.map(|id| id.0), Some(1));
        // A handle that is not there: no text, and nothing resolved.
        let unseen = wire.resolve(&[]);
        assert!(unseen.views[0].text.is_none());
        assert_eq!(unseen.views[0].scroll, 0);
        assert!(unseen.views[0].selections.is_empty());
    }

    #[test]
    fn a_pixel_count_no_u32_holds_is_the_largest() {
        assert_eq!(pixels(7), 7);
        assert_eq!(pixels(u64::MAX), u32::MAX);
    }
}
