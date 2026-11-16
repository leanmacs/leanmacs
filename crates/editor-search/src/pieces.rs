//! The haystack: a text as the pieces it is held in, searched where it
//! lies.

/// A text as the pieces it is held in, end to end: the chunks of a rope's
/// snapshot, borrowed and never copied.
///
/// Offsets are byte offsets into the whole text. A piece is a `&str`, so no
/// character is split between two pieces. Empty pieces are dropped when the
/// haystack is made, so [`pieces`](Pieces::pieces) holds none.
#[derive(Debug, Clone)]
pub struct Pieces<'a> {
    /// The pieces, none empty.
    pieces: Vec<&'a str>,
    /// The offset each piece starts at, one for each.
    starts: Vec<usize>,
    /// The text's length in bytes.
    len: usize,
}

impl<'a> Pieces<'a> {
    /// The text made of `pieces`, end to end.
    pub fn new(pieces: &[&'a str]) -> Self {
        let pieces: Vec<&'a str> = pieces
            .iter()
            .copied()
            .filter(|piece| !piece.is_empty())
            .collect();
        let mut starts = Vec::with_capacity(pieces.len());
        let mut len = 0;
        for piece in &pieces {
            starts.push(len);
            len += piece.len();
        }
        Self {
            pieces,
            starts,
            len,
        }
    }

    /// The text's length in bytes.
    pub fn len(&self) -> usize {
        self.len
    }

    /// Whether the text is empty.
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// The pieces, in order, none empty.
    pub fn pieces(&self) -> &[&'a str] {
        &self.pieces
    }

    /// The offset the piece at `index` starts at.
    ///
    /// # Panics
    ///
    /// When `index` is not the index of a piece.
    pub fn start_of(&self, index: usize) -> usize {
        self.starts[index]
    }

    /// The index of the piece that holds the byte at `offset`; the last
    /// piece for the text's end and past it; 0 for an empty text.
    pub fn piece_holding(&self, offset: usize) -> usize {
        self.starts
            .partition_point(|&start| start <= offset)
            .saturating_sub(1)
    }

    /// Whether `offset` is a position in the text: at most its length, and
    /// not inside a character.
    pub fn is_position(&self, offset: usize) -> bool {
        if offset >= self.len {
            return offset == self.len;
        }
        let index = self.piece_holding(offset);
        self.pieces[index].is_char_boundary(offset - self.starts[index])
    }

    /// The character that starts at `offset`; none at the text's end, or
    /// where `offset` is not a position.
    pub fn char_at(&self, offset: usize) -> Option<char> {
        if offset >= self.len {
            return None;
        }
        let index = self.piece_holding(offset);
        self.pieces[index]
            .get(offset - self.starts[index]..)?
            .chars()
            .next()
    }

    /// The character that ends at `offset`; none at the text's start, or
    /// where `offset` is not a position.
    pub fn char_before(&self, offset: usize) -> Option<char> {
        if offset == 0 || offset > self.len {
            return None;
        }
        // The character ends at `offset`, so it is in the piece that holds
        // the byte before: no character is split between pieces.
        let index = self.piece_holding(offset - 1);
        self.pieces[index]
            .get(..offset - self.starts[index])?
            .chars()
            .next_back()
    }

    /// The characters from the one at `offset` to the text's end, each with
    /// its offset.
    pub fn chars_from(&self, offset: usize) -> impl Iterator<Item = (usize, char)> + '_ {
        let first = self.piece_holding(offset);
        self.pieces
            .iter()
            .zip(&self.starts)
            .skip(first)
            .flat_map(move |(piece, &start)| {
                let within = offset.saturating_sub(start);
                piece
                    .get(within..)
                    .unwrap_or("")
                    .char_indices()
                    .map(move |(at, c)| (start + within + at, c))
            })
    }

    /// The start of the row that holds `offset`: just after the last line
    /// feed before it, or the text's start.
    pub fn row_start(&self, offset: usize) -> usize {
        let offset = offset.min(self.len);
        let mut index = self.piece_holding(offset);
        let mut before = offset;
        while let Some(piece) = self.pieces.get(index) {
            let start = self.starts[index];
            let within = piece.as_bytes().get(..before - start).unwrap_or(&[]);
            if let Some(at) = within.iter().rposition(|&byte| byte == b'\n') {
                return start + at + 1;
            }
            if index == 0 {
                break;
            }
            index -= 1;
            before = start;
        }
        0
    }

    /// The end of the row that holds `offset`: the first line feed at or
    /// after it, or the text's end.
    pub fn row_end(&self, offset: usize) -> usize {
        let mut from = offset.min(self.len);
        for index in self.piece_holding(from)..self.pieces.len() {
            let start = self.starts[index];
            let within = self.pieces[index]
                .as_bytes()
                .get(from - start..)
                .unwrap_or(&[]);
            if let Some(at) = within.iter().position(|&byte| byte == b'\n') {
                return from + at;
            }
            from = start + self.pieces[index].len();
        }
        self.len
    }
}

#[cfg(test)]
mod tests {
    use super::Pieces;

    #[test]
    fn empty_pieces_are_dropped_and_the_rest_kept_in_order() {
        let pieces = Pieces::new(&["", "ab", "", "c", ""]);
        assert_eq!(pieces.pieces(), ["ab", "c"]);
        assert_eq!(pieces.len(), 3);
        assert_eq!((pieces.start_of(0), pieces.start_of(1)), (0, 2));
        assert!(Pieces::new(&["", ""]).is_empty());
        assert!(Pieces::new(&[]).pieces().is_empty());
    }

    #[test]
    fn the_piece_holding_an_offset() {
        let pieces = Pieces::new(&["ab", "c", "de"]);
        let holding: Vec<usize> = (0..=5).map(|at| pieces.piece_holding(at)).collect();
        assert_eq!(holding, [0, 0, 1, 2, 2, 2]);
        assert_eq!(Pieces::new(&[]).piece_holding(0), 0);
    }

    #[test]
    fn positions_are_char_boundaries_up_to_the_end() {
        let pieces = Pieces::new(&["aé", "b"]);
        let positions: Vec<bool> = (0..=5).map(|at| pieces.is_position(at)).collect();
        assert_eq!(positions, [true, true, false, true, true, false]);
        assert!(Pieces::new(&[]).is_position(0));
    }

    #[test]
    fn characters_at_and_before_an_offset_across_pieces() {
        let pieces = Pieces::new(&["aé", "🙂b"]);
        assert_eq!(pieces.char_at(0), Some('a'));
        assert_eq!(pieces.char_at(3), Some('🙂'));
        assert_eq!(pieces.char_at(7), Some('b'));
        assert_eq!(pieces.char_at(8), None);
        assert_eq!(pieces.char_at(2), None);
        assert_eq!(pieces.char_before(0), None);
        assert_eq!(pieces.char_before(3), Some('é'));
        assert_eq!(pieces.char_before(7), Some('🙂'));
        assert_eq!(pieces.char_before(8), Some('b'));
        assert_eq!(pieces.char_before(2), None);
    }

    #[test]
    fn the_characters_from_an_offset() {
        let pieces = Pieces::new(&["ab", "", "é", "c"]);
        let from: Vec<(usize, char)> = pieces.chars_from(1).collect();
        assert_eq!(from, [(1, 'b'), (2, 'é'), (4, 'c')]);
        assert_eq!(pieces.chars_from(5).count(), 0);
    }

    #[test]
    fn rows_end_at_line_feeds_and_a_carriage_return_is_a_character_of_its_row() {
        let pieces = Pieces::new(&["ab\r", "\ncd\n", "\nef"]);
        // Rows: "ab\r" 0..3, "cd" 4..6, "" 7..7, "ef" 8..10.
        let starts: Vec<usize> = (0..=10).map(|at| pieces.row_start(at)).collect();
        assert_eq!(starts, [0, 0, 0, 0, 4, 4, 4, 7, 8, 8, 8]);
        let ends: Vec<usize> = (0..=10).map(|at| pieces.row_end(at)).collect();
        assert_eq!(ends, [3, 3, 3, 3, 6, 6, 6, 7, 10, 10, 10]);
        let empty = Pieces::new(&[]);
        assert_eq!((empty.row_start(0), empty.row_end(0)), (0, 0));
    }
}
