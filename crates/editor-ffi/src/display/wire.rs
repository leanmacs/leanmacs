//! A published scene as it crosses: words, one string, and a list of
//! snapshot handles; and the scene they spell before anything in it is
//! resolved ([`WireScene`]).
//!
//! The words, in order (a presence is 0 or 1, and an absent value is
//! written as 0):
//!
//! | Part | Words |
//! |---|---|
//! | The scene | its width and height; the focus's presence and view id; the echo's length; the pending prefix's length; the preedit's presence and length; the count of views; each view |
//! | A view | its id; its rectangle's x, y, width and height; its snapshot's presence and index in the list of handles; its scroll marker's presence and number; the count of its selection markers and each one's number; its cursor's shape (0 block, 1 bar, 2 underline, 3 hollow) and its face's length; the count of its decorations and each one's start, stop and face's length; the count of its status fields and each one's text's length and face's length |
//!
//! The string is every text of the scene one after another, in the order
//! the words give their lengths: the echo, the pending prefix, the preedit
//! if present, then for each view its cursor's face, its decorations' faces
//! and its status fields' texts and faces. A length that does not end on a
//! character boundary, and text left over, are refusals.
//!
//! A marker's number is its document's number for it: the display resolves
//! it against the document of the view's snapshot
//! ([`crate::snapshot::Snapshot::marker`]). [`WireScene`] keeps the scene
//! as it crossed, so it is written back as the same words and string
//! ([`WireScene::encode`]), which is the round trip Lean checks.

use editor_layout::scene::{
    Cursor, CursorShape, Decoration, Rect, Scene, Size, StatusField, View, ViewId,
};
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
    /// The views, in drawing order.
    pub views: Vec<WireView>,
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
        // A view is at least fourteen words.
        let count = words.count(14)?;
        let views = (0..count)
            .map(|_| view(&mut words, &mut texts))
            .collect::<Option<_>>()?;
        words.finish()?;
        texts.rest.is_empty().then_some(Self {
            size,
            focused,
            echo,
            pending,
            preedit,
            views,
        })
    }

    /// The words and the string that spell this scene.
    pub fn encode(&self) -> (Vec<u8>, String) {
        let mut words = Writer::with_capacity(9 + 20 * self.views.len());
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
                        })
                        .collect(),
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
        }
    }
}

/// The `u32` of a pixel count, the largest for one no `u32` holds.
fn pixels(count: u64) -> u32 {
    u32::try_from(count).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use editor_layout::scene::CursorShape;
    use editor_text::{Anchor, Bias, Marker, Selection, SelectionRange};

    use super::{WireScene, WireView, pixels};
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
        }
    }

    #[test]
    fn a_scene_crosses_as_the_words_and_the_string_of_the_module_docs() {
        let (words, strings) = full().encode();
        assert_eq!(
            words,
            buffer(&[
                96, 112, 1, 1, 7, 1, 1, 2, 1, // the scene
                1, 0, 0, 96, 80, 1, 0, 1, 0, 2, 1, 2, 2, 13, // the view
                1, 0, 2, 7, 1, 6, 4, // its decorations and status
            ])
        );
        assert_eq!(strings, "fixturegécursor.normalkeywordNORMALmode");
        assert_eq!(WireScene::decode(&words, &strings), Some(full()));
    }

    #[test]
    fn absent_parts_are_written_as_zero_and_read_back_absent() {
        let empty = WireScene::default();
        let (words, strings) = empty.encode();
        assert_eq!(words, buffer(&[0, 0, 0, 0, 0, 0, 0, 0, 0]));
        assert_eq!(WireScene::decode(&words, &strings), Some(empty));
        // A view with nothing in it is its fourteen words.
        let bare = WireScene {
            views: vec![WireView::default()],
            ..WireScene::default()
        };
        let (words, strings) = bare.encode();
        assert_eq!(words.len(), (9 + 14) * 8);
        assert_eq!(WireScene::decode(&words, &strings), Some(bare));
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
