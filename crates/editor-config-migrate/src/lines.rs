//! The rules the conversion reads from a file's text, a line at a time,
//! with no Lean, kept as the shell tool before this crate had them in
//! `grep -E` and `awk` patterns.
//!
//! Each is a fixed prefix grammar (attributes, modifiers, a keyword, a name
//! with an ASCII boundary), so it is matched by hand here: the `regex`
//! crate is kept behind `editor-search`'s port by `deny.toml`, and these
//! need none of it. A line is the text between newlines, and a space is
//! one of POSIX's `[[:space:]]`.
//!
//! - [`defines_setup`]: a line starts, after any `@[…]` attributes and the
//!   modifiers `private`, `protected`, `noncomputable`, `partial`,
//!   `unsafe` and `nonrec`, with `def`, `abbrev`, `opaque`, `instance`,
//!   `theorem` or `axiom`, then `setup` followed by a character outside
//!   `[A-Za-z0-9_.!?']` or the end of the line.
//! - [`declares_private`]: a line starts, after any attributes, with
//!   `private` and a space.
//! - [`starts_with_header`]: the first line that is not blank, not a `--`
//!   comment and not in or opening a block comment starts with `import`,
//!   `prelude` or `module` at column 0, then a character that is not a
//!   word's.
//! - [`left_open`]: the lines that start with `namespace`, `section` or
//!   `mutual` (optionally after `noncomputable`, `public` or `private`)
//!   counted against the lines that start with `end`, each at a word
//!   boundary.
//! - [`module_name`]: the file name without `.lean` and its leading
//!   digits, `-` and `_`, each `-`/`_`-separated part with its first
//!   letter upper-cased; it must start with an ASCII letter and hold only
//!   ASCII letters and digits.

/// Why a file's name gives no module name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoModule {
    /// After its leading digits and separators it does not start with a
    /// letter.
    NoLetterFirst,
    /// It holds a character other than an ASCII letter or digit.
    OtherCharacter,
}

/// The modifiers a declaration of `setup` may follow.
const MODIFIERS: [&str; 6] = [
    "private",
    "protected",
    "noncomputable",
    "partial",
    "unsafe",
    "nonrec",
];

/// The keywords that declare a name.
const DECLARATIONS: [&str; 6] = ["def", "abbrev", "opaque", "instance", "theorem", "axiom"];

/// POSIX's `[[:space:]]`.
fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\x0B' | '\x0C' | '\r')
}

/// Whether `c` belongs to a word: `[A-Za-z0-9_]`.
fn is_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// The text after `word` at the start of `rest` when the next character
/// passes `boundary`, or the line ends.
fn after_word<'a>(rest: &'a str, word: &str, boundary: impl Fn(char) -> bool) -> Option<&'a str> {
    let after = rest.strip_prefix(word)?;
    match after.chars().next() {
        None => Some(after),
        Some(c) if boundary(c) => Some(after),
        Some(_) => None,
    }
}

/// `rest` past one or more spaces, when it starts with one.
fn past_spaces(rest: &str) -> Option<&str> {
    rest.starts_with(is_space)
        .then(|| rest.trim_start_matches(is_space))
}

/// The line past its leading `@[…]` attributes, each with the spaces after
/// it.
fn past_attributes(mut line: &str) -> &str {
    while let Some(inside) = line.strip_prefix("@[") {
        let Some(end) = inside.find(']') else {
            break;
        };
        line = inside[end + 1..].trim_start_matches(is_space);
    }
    line
}

fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split('\n')
}

fn line_defines_setup(line: &str) -> bool {
    let mut rest = past_attributes(line);
    'modifiers: loop {
        for modifier in MODIFIERS {
            if let Some(after) = rest.strip_prefix(modifier).and_then(past_spaces) {
                rest = after;
                continue 'modifiers;
            }
        }
        break;
    }
    DECLARATIONS.iter().any(|keyword| {
        rest.strip_prefix(keyword)
            .and_then(past_spaces)
            .and_then(|name| {
                after_word(name, "setup", |c| {
                    !(c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '!' | '?' | '\''))
                })
            })
            .is_some()
    })
}

/// Whether a line of `text` starts a declaration of `setup`, after any
/// attributes and modifiers on the line.
pub fn defines_setup(text: &str) -> bool {
    lines(text).any(line_defines_setup)
}

/// Whether a line of `text` starts with `private`, after any attributes on
/// the line.
pub fn declares_private(text: &str) -> bool {
    lines(text).any(|line| {
        past_attributes(line)
            .strip_prefix("private")
            .and_then(past_spaces)
            .is_some()
    })
}

/// Whether `text` starts with a header: whether its first line that is not
/// blank, a line comment or in a block comment starts with `import`,
/// `prelude` or `module`.
pub fn starts_with_header(text: &str) -> bool {
    let mut in_comment = false;
    for line in lines(text) {
        if in_comment {
            if line.contains("-/") {
                in_comment = false;
            }
            continue;
        }
        let trimmed = line.trim_start_matches(is_space);
        if trimmed.is_empty() || trimmed.starts_with("--") {
            continue;
        }
        if let Some(after) = trimmed.strip_prefix("/-") {
            in_comment = !after.contains("-/");
            continue;
        }
        return ["import", "prelude", "module"]
            .iter()
            .any(|word| after_word(line, word, |c| !is_word(c)).is_some());
    }
    false
}

/// How many more lines of `text` start with `namespace`, `section` or
/// `mutual` than start with `end`: 0 when it leaves nothing open, below 0
/// when it closes what it did not open.
pub fn left_open(text: &str) -> i64 {
    let opens = |line: &str| {
        let unprefixed = ["noncomputable", "public", "private"]
            .iter()
            .find_map(|prefix| {
                let after = line.strip_prefix(prefix)?;
                after
                    .starts_with([' ', '\t'])
                    .then(|| after.trim_start_matches([' ', '\t']))
            })
            .unwrap_or(line);
        ["namespace", "section", "mutual"]
            .iter()
            .any(|word| after_word(unprefixed, word, |c| !is_word(c)).is_some())
    };
    lines(text)
        .map(|line| {
            if opens(line) {
                1
            } else if after_word(line, "end", |c| !is_word(c)).is_some() {
                -1
            } else {
                0
            }
        })
        .sum()
}

/// The module name the file name `file` gives: without `.lean` and its
/// leading digits and separators, each part after a `-` or `_` capitalised
/// (`05-leader.lean` gives `Leader`, `20-evil-keys.lean` `EvilKeys`).
///
/// # Errors
///
/// [`NoModule`], when the name does not then start with an ASCII letter or
/// holds a character other than an ASCII letter or digit.
pub fn module_name(file: &str) -> Result<String, NoModule> {
    let stem = file.strip_suffix(".lean").unwrap_or(file);
    let stem = stem.trim_start_matches(|c: char| c.is_ascii_digit() || c == '-' || c == '_');
    let name: String = stem
        .split(['-', '_'])
        .map(|part| {
            let mut chars = part.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_ascii_uppercase().to_string() + chars.as_str()
            })
        })
        .collect();
    if !name.starts_with(|c: char| c.is_ascii_alphabetic()) {
        return Err(NoModule::NoLetterFirst);
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric()) {
        return Err(NoModule::OtherCharacter);
    }
    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setup_is_defined_by_each_declaration_keyword_after_attributes_and_modifiers() {
        for line in [
            "def setup : SetupM Unit := pure ()",
            "abbrev setup := pure ()",
            "opaque setup : SetupM Unit",
            "instance setup : Inhabited Nat := ⟨0⟩",
            "theorem setup : True := trivial",
            "axiom setup : SetupM Unit",
            "@[inline] def setup := pure ()",
            "@[inline] @[simp]private def setup := pure ()",
            "private noncomputable partial def setup := pure ()",
            "protected unsafe nonrec def\tsetup := pure ()",
            "def setup",
            "def setup: SetupM Unit",
            "def setup(x : Nat)",
        ] {
            assert!(defines_setup(line), "{line:?}");
            assert!(
                defines_setup(&format!("-- a comment\n{line}\nmore\n")),
                "{line:?}"
            );
        }
    }

    #[test]
    fn setup_is_not_defined_by_a_longer_name_a_dotted_name_an_indented_line_or_a_comment() {
        for line in [
            "def setupKeys := pure ()",
            "def setup_ := pure ()",
            "def setup' := pure ()",
            "def setup! := pure ()",
            "def setup? := pure ()",
            "def setup.more := pure ()",
            "def Config.setup := pure ()",
            "  def setup := pure ()",
            "-- def setup := pure ()",
            "/-- The setup. -/ def setup := pure ()",
            "@[inline def setup := pure ()",
            "privatedef setup := pure ()",
            "example setup := pure ()",
        ] {
            assert!(!defines_setup(line), "{line:?}");
        }
    }

    #[test]
    fn private_is_declared_by_a_line_starting_with_it_after_attributes() {
        assert!(declares_private("def a := 1\nprivate def secret := 1\n"));
        assert!(declares_private(
            "@[simp] private theorem t : True := trivial"
        ));
        assert!(declares_private("private\tdef secret := 1"));
        assert!(!declares_private("  private def secret := 1"));
        assert!(!declares_private("privately := 1"));
        assert!(!declares_private("private"));
        assert!(!declares_private("def a := 1 -- private x"));
    }

    #[test]
    fn a_header_is_the_first_line_past_blanks_and_comments_starting_with_import_prelude_or_module()
    {
        assert!(starts_with_header("import Editor\n"));
        assert!(starts_with_header("prelude\n"));
        assert!(starts_with_header("module\n"));
        assert!(starts_with_header(
            "\n  \n-- The setup.\n  -- more\nimport Editor\nopen Editor\n"
        ));
        assert!(starts_with_header(
            "/- A block\n   comment -/\nimport Editor\n"
        ));
        assert!(starts_with_header("/-- One line. -/\nimport Editor\n"));
        assert!(starts_with_header("import\tEditor"));
        assert!(!starts_with_header("def a := 1\nimport Editor\n"));
        assert!(!starts_with_header("/- import Editor\n-/\ndef a := 1\n"));
        assert!(!starts_with_header(""));
        assert!(!starts_with_header("-- only a comment\n"));
    }

    #[test]
    fn an_indented_import_or_a_longer_word_is_not_a_header() {
        assert!(!starts_with_header("  import Editor\n"));
        assert!(!starts_with_header("imported := 1\n"));
        assert!(!starts_with_header("modules := 1\n"));
        assert!(!starts_with_header("import_x := 1\n"));
    }

    #[test]
    fn open_blocks_count_namespace_section_and_mutual_against_end() {
        assert_eq!(left_open("namespace A\ndef a := 1\nend A\n"), 0);
        assert_eq!(left_open("namespace A\n"), 1);
        assert_eq!(left_open("section\nmutual\n"), 2);
        assert_eq!(
            left_open("noncomputable section\npublic section\nprivate\tsection\n"),
            3
        );
        assert_eq!(left_open("end Stray\n"), -1);
        assert_eq!(left_open("end\n"), -1);
        assert_eq!(
            left_open("  namespace A\nnamespaced := 1\nsections\nending := 1\nendless\n"),
            0
        );
        assert_eq!(left_open("namespace A\n\nend A"), 0);
    }

    #[test]
    fn a_module_name_drops_leading_digits_and_separators_and_capitalises_each_part() {
        assert_eq!(module_name("05-leader.lean"), Ok("Leader".to_owned()));
        assert_eq!(module_name("20-evil-keys.lean"), Ok("EvilKeys".to_owned()));
        assert_eq!(module_name("10_my_theme.lean"), Ok("MyTheme".to_owned()));
        assert_eq!(
            module_name("1-2_3-keys2--more.lean"),
            Ok("Keys2More".to_owned())
        );
        assert_eq!(module_name("Keys.lean"), Ok("Keys".to_owned()));
    }

    #[test]
    fn a_name_with_no_letter_first_or_another_character_gives_no_module() {
        assert_eq!(module_name("10.lean"), Err(NoModule::NoLetterFirst));
        assert_eq!(module_name("10-.lean"), Err(NoModule::NoLetterFirst));
        assert_eq!(module_name("10-é.lean"), Err(NoModule::NoLetterFirst));
        assert_eq!(module_name("10-a.b.lean"), Err(NoModule::OtherCharacter));
        assert_eq!(module_name("10-a b.lean"), Err(NoModule::OtherCharacter));
    }
}
