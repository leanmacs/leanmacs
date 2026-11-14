//! What a character is to the motions: the one place that says so.
//!
//! A *blank* is a space or a tab. A line break separates words as a blank
//! does, but it is a cell and not a character, so it is the motions' to
//! tell (the private module `motion`).

/// Whether `character` is a blank: a space (U+0020) or a tab (U+0009), and
/// nothing else. A no-break space and the other spaces of Unicode are not.
pub(crate) fn is_blank(character: char) -> bool {
    matches!(character, ' ' | '\t')
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
}
