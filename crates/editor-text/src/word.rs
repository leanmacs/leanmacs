//! What a character is to the motions: the one place that says so.
//!
//! A *blank* is a space or a tab. A *word character* is an ASCII letter, an
//! ASCII digit, an underscore, or any character from U+0080 up. Every other
//! character is *punctuation*: the rest of ASCII, its control characters
//! and NUL included, and so a carriage return.
//!
//! The rule is this short so that the editor's pure model of a text, which
//! has no Unicode tables, can state the same one. It is Vim's on ASCII, and
//! not Vim's beyond it: Vim has a table of classes for other scripts,
//! punctuation and emoji. Such a table would replace this module and
//! nothing else.
//!
//! A line break separates words as a blank does, but it is a cell and not
//! a character, so it is the motions' to tell (the private module
//! `motion`).

/// Which words a motion goes by.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WordKind {
    /// Words: a word is a longest run of word characters, or of
    /// punctuation.
    Word,
    /// WORDs: a WORD is a longest run of characters that are not blank.
    BigWord,
}

/// What a character that is not a blank is to a word motion. Neighbours of
/// one class are in one word.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Class {
    /// A word character; for a WORD, any character that is not a blank.
    Word,
    /// Any other character. A WORD has none.
    Punctuation,
}

/// Whether `character` is a blank: a space (U+0020) or a tab (U+0009), and
/// nothing else. A no-break space and the other spaces of Unicode are not.
pub(crate) fn is_blank(character: char) -> bool {
    matches!(character, ' ' | '\t')
}

/// The class of `character` for words of `kind`; `None` for a blank.
pub(crate) fn class(kind: WordKind, character: char) -> Option<Class> {
    if is_blank(character) {
        return None;
    }
    let word = match kind {
        WordKind::Word => {
            character.is_ascii_alphanumeric() || character == '_' || !character.is_ascii()
        }
        WordKind::BigWord => true,
    };
    Some(if word {
        Class::Word
    } else {
        Class::Punctuation
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blank_is_a_space_or_a_tab_and_nothing_else() {
        assert!(is_blank(' '));
        assert!(is_blank('\t'));
        // Neither a line ending, another control character, a no-break
        // space nor an ideographic space.
        for character in ['\n', '\r', '\0', '\u{B}', '\u{A0}', '\u{3000}', 'a', '_'] {
            assert!(!is_blank(character), "{character:?}");
        }
    }

    #[test]
    fn a_letter_a_digit_an_underscore_and_every_character_outside_ascii_is_a_word_character() {
        // "é", the combining acute, "😀", a no-break space, an em dash and
        // the character the byte 0xFF is kept as.
        for character in [
            'a',
            'Z',
            '0',
            '9',
            '_',
            'é',
            '\u{301}',
            '😀',
            '\u{A0}',
            '—',
            '\u{10DCFF}',
            '\u{80}',
        ] {
            assert_eq!(
                class(WordKind::Word, character),
                Some(Class::Word),
                "{character:?}"
            );
        }
    }

    #[test]
    fn the_rest_of_ascii_is_punctuation_its_control_characters_included() {
        for character in ['.', '!', '-', '(', '/', '@', '`', '~', '\0', '\r', '\u{7F}'] {
            assert_eq!(
                class(WordKind::Word, character),
                Some(Class::Punctuation),
                "{character:?}"
            );
        }
    }

    #[test]
    fn a_blank_has_no_class_for_either_kind() {
        for kind in [WordKind::Word, WordKind::BigWord] {
            assert_eq!(class(kind, ' '), None, "{kind:?}");
            assert_eq!(class(kind, '\t'), None, "{kind:?}");
        }
    }

    #[test]
    fn for_a_big_word_every_character_that_is_not_a_blank_is_of_one_class() {
        for character in ['a', '0', '_', '.', '!', '\0', '\r', 'é', '\u{301}', '😀'] {
            assert_eq!(
                class(WordKind::BigWord, character),
                Some(Class::Word),
                "{character:?}"
            );
        }
    }
}
