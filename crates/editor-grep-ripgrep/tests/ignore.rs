//! Criterion 1 of project search: every match under the workspace root,
//! honouring ignore files, on real files in a temporary directory the test
//! owns. The rule runs over the adapter and the search engine's fake, so
//! the needle is a literal; the expectation is a naive scan of the files
//! the test wrote that no ignore rule leaves out.

use std::path::{Path, PathBuf};

use editor_grep::{Files, Flow, Limits, Request, search};
use editor_grep_ripgrep::RipgrepFiles;
use editor_search::Literal;

/// A file's path and its matches, as (row, start, stop).
type Answered = Vec<(PathBuf, Vec<(usize, usize, usize)>)>;

/// The text's word class.
fn word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || u32::from(c) >= 0x80
}

/// Writes `bytes` at `relative` under `root`.
fn write(root: &Path, relative: &str, bytes: &[u8]) {
    let path = root.join(relative);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).expect("a directory");
    }
    std::fs::write(path, bytes).expect("a file");
}

/// Every match of `needle` in `bytes`, as (row, start, stop), by a naive
/// scan of its rows.
fn naive(bytes: &[u8], needle: &str) -> Vec<(usize, usize, usize)> {
    let mut found = Vec::new();
    let mut offset = 0;
    for (row, line) in bytes.split(|&byte| byte == b'\n').enumerate() {
        let text = String::from_utf8_lossy(line);
        let mut from = 0;
        while let Some(at) = text[from..].find(needle) {
            found.push((row, offset + from + at, offset + from + at + needle.len()));
            from += at + needle.len();
        }
        offset += line.len() + 1;
    }
    found
}

#[test]
fn every_match_under_the_root_honouring_ignore_files() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let root = dir.path();
    let searched: [(&str, &[u8]); 6] = [
        ("a.rs", b"needle\nno\nx needle needle\n"),
        ("crlf.txt", b"one\r\nneedle\r\n"),
        ("latin1.txt", b"caf\xe9 needle\n"),
        ("sub/deep/z.rs", b"needle"),
        ("sub/keep.rs", b"a\nb needle\n"),
        ("zz/no-match.txt", b"nothing here\n"),
    ];
    for (path, bytes) in searched {
        write(root, path, bytes);
    }
    let left_out: [(&str, &[u8]); 9] = [
        ("target/debug/out.rs", b"needle"),
        ("run.log", b"needle"),
        ("sub/gen.rs", b"needle"),
        ("notes.txt", b"needle"),
        ("excluded.rs", b"needle"),
        (".git/config", b"needle"),
        (".hidden.rs", b"needle"),
        (".hidden-dir/a.rs", b"needle"),
        ("binary.dat", b"needle\0needle\n"),
    ];
    for (path, bytes) in left_out {
        write(root, path, bytes);
    }
    write(root, ".gitignore", b"target/\n*.log\n");
    write(root, "sub/.gitignore", b"gen.rs\n");
    write(root, ".ignore", b"notes.txt\n");
    write(root, ".git/info/exclude", b"excluded.rs\n");

    let request = Request {
        root: root.to_path_buf(),
        pattern: "needle".to_owned(),
        overlays: Vec::new(),
        limits: Limits {
            files: 100,
            matches: 1_000,
        },
    };
    let mut found = Vec::new();
    let summary = search(
        &RipgrepFiles::new(),
        &mut Literal,
        &word,
        &request,
        &|| false,
        &mut |file| found.push(file),
    )
    .expect("searched");

    let answered: Answered = found
        .into_iter()
        .map(|file| {
            let matches = file
                .matches
                .iter()
                .map(|m| (m.row, m.start, m.stop))
                .collect();
            (file.path, matches)
        })
        .collect();
    let expected: Answered = searched
        .iter()
        .map(|(path, bytes)| (root.join(path), naive(bytes, "needle")))
        .filter(|(_, matches)| !matches.is_empty())
        .collect();
    assert_eq!(answered, expected);
    assert!(!summary.truncated);
}

#[test]
fn the_walk_goes_by_name_not_by_the_spelling_of_the_path() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    for path in ["a-c", "a/b", "a0", "B"] {
        write(dir.path(), path, b"x");
    }
    let mut walked = Vec::new();

    RipgrepFiles::new()
        .walk(dir.path(), &mut |path| {
            walked.push(path.to_path_buf());
            Flow::Go
        })
        .expect("walked");

    assert_eq!(
        walked,
        ["B", "a/b", "a-c", "a0"].map(PathBuf::from).to_vec()
    );
}

#[test]
fn holds_is_asked_once_a_row_across_the_readers_blocks() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    // Far more than one block of the reader's buffer.
    let rows = 50_000;
    let text: String = (0..rows).map(|row| format!("row {row}\n")).collect();
    write(dir.path(), "big.txt", text.as_bytes());
    let mut asked = 0;
    let mut visited = Vec::new();

    RipgrepFiles::new()
        .rows(
            &dir.path().join("big.txt"),
            &mut |text| {
                asked += 1;
                text.ends_with("999")
            },
            &mut |row| {
                visited.push((row.number, row.offset));
                Flow::Go
            },
        )
        .expect("read");

    assert_eq!(asked, rows);
    assert_eq!(visited.len(), rows / 1000);
    let offset_of = |row: usize| text.find(&format!("row {row}\n")).expect("there");
    assert_eq!(visited[0], (999, offset_of(999)));
    assert_eq!(visited[49], (49_999, offset_of(49_999)));
}

#[test]
fn a_file_with_a_nul_past_the_first_block_is_binary_and_none_of_its_rows_is_visited() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let mut bytes = "needle\n".repeat(100_000).into_bytes();
    bytes.extend_from_slice(b"\0\n");
    write(dir.path(), "late.bin", &bytes);
    let mut visited = 0;

    let read = RipgrepFiles::new()
        .rows(&dir.path().join("late.bin"), &mut |_| true, &mut |_| {
            visited += 1;
            Flow::Go
        })
        .expect("read");

    assert_eq!(read, editor_grep::Read::Binary);
    assert_eq!(visited, 0);
}
