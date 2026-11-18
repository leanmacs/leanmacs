//! The download page: one self-contained `index.html` that names the
//! nightly's build and links its image.
//!
//! It is pure: [`page_from`] reads a [`BUILD_JSON`](crate::nightly::BUILD_JSON)
//! text ([`nightly::parse_build_json`]), the release's [`Target`] and the
//! minimum macOS into a [`Page`], and [`render`] turns that into the page's
//! text. `leanmacs-release site` (`editor-release-std`) reads the file and
//! `MACOSX_DEPLOYMENT_TARGET`, and writes [`INDEX`]; CI's `release /
//! publish` job runs it on the `build.json` it is about to publish, and
//! `release / pages` deploys the result (`.github/workflows/release.yml`).
//!
//! The page loads nothing: no script, no stylesheet, no font, no image,
//! from this origin or any other. Its one style sheet is inline, and its
//! only links are navigation (`<a href>`): the image, its checksum, the
//! commit and the source. The tests hold every fixture's page to that.
//!
//! The first-launch steps and the version command are [`install`](crate::install)'s, the
//! words `packaging/macos/README.txt` and the release notes use too; this
//! module adds only their HTML.

use std::error::Error;
use std::fmt;

use crate::install::{
    FIRST_LAUNCH, FIRST_LAUNCH_WHY, QUARANTINE_FIX, QUARANTINE_WHY, VERSION_COMMAND, VERSION_PRINTS,
};
use crate::nightly::{self, Build, BuildJsonError, FIXED, SHA256, Target};

/// The page's file name.
pub const INDEX: &str = "index.html";

/// The one-line summary, as the README's.
pub const SUMMARY: &str = "A text editor whose config and extensions are written in Lean.";

/// A macOS version: one to three dot-separated numbers, as
/// `MACOSX_DEPLOYMENT_TARGET` holds it (`26.0`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacosVersion(String);

impl MacosVersion {
    /// Reads a version: `N`, `N.N` or `N.N.N`, each `N` one or more ASCII
    /// digits.
    ///
    /// # Errors
    ///
    /// The text, for anything else: empty, a trailing dot, a prefix, a
    /// space.
    pub fn parse(text: &str) -> Result<Self, String> {
        let parts: Vec<&str> = text.split('.').collect();
        let number = |p: &&str| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit());
        if parts.len() <= 3 && parts.iter().all(number) {
            Ok(Self(text.to_owned()))
        } else {
            Err(text.to_owned())
        }
    }

    /// The version as given.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for MacosVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// What the page shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Page {
    /// The build the nightly holds.
    pub build: Build,
    /// Where the release lives, for the links.
    pub target: Target,
    /// The oldest macOS the app runs on.
    pub minimum_macos: MacosVersion,
}

/// Why a page could not be made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SiteError {
    /// The `build.json` is not one `build_json` wrote.
    BuildJson(BuildJsonError),
    /// The minimum macOS is not a version: the text.
    Minimum(String),
}

impl fmt::Display for SiteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BuildJson(error) => error.fmt(f),
            Self::Minimum(text) => write!(
                f,
                "the minimum macOS `{text}` is not a version (N, N.N or N.N.N)"
            ),
        }
    }
}

impl Error for SiteError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::BuildJson(error) => Some(error),
            Self::Minimum(_) => None,
        }
    }
}

/// The page for the build `build_json` describes, linking into `target`'s
/// nightly, for an app that runs on `minimum_macos` and later.
///
/// # Errors
///
/// A `build_json` that [`nightly::parse_build_json`] refuses, or a minimum
/// that is not a [`MacosVersion`].
pub fn page_from(build_json: &str, target: Target, minimum_macos: &str) -> Result<Page, SiteError> {
    let build = nightly::parse_build_json(build_json).map_err(SiteError::BuildJson)?;
    let minimum_macos = MacosVersion::parse(minimum_macos).map_err(SiteError::Minimum)?;
    Ok(Page {
        build,
        target,
        minimum_macos,
    })
}

/// `text` safe inside an element or a quoted attribute.
#[must_use]
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
    }
    out
}

/// The image's size in decimal megabytes to one place, rounded half up,
/// and in bytes: `182.4 MB (182431744 bytes)`.
fn size(bytes: u64) -> String {
    let tenths = bytes.saturating_add(50_000) / 100_000;
    format!("{}.{} MB ({bytes} bytes)", tenths / 10, tenths % 10)
}

/// The build's time, the commit's, from its ID: `YYYY-MM-DD HH:MM:SS UTC`.
fn date(build: &Build) -> String {
    format!("{} {} UTC", build.id.date(), build.id.time())
}

/// The page's one style sheet: the system's fonts, one narrow column, and
/// the system's light or dark scheme. It names no other resource.
const STYLE: &str = r#":root {
  color-scheme: light dark;
  --fg: #1b1b1b;
  --bg: #ffffff;
  --muted: #5c5c5c;
  --accent: #0b57d0;
  --on-accent: #ffffff;
  --code: #f1f1f1;
}
@media (prefers-color-scheme: dark) {
  :root {
    --fg: #e8e8e8;
    --bg: #161616;
    --muted: #a6a6a6;
    --accent: #8ab4f8;
    --on-accent: #0b1a33;
    --code: #262626;
  }
}
body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
}
main {
  max-width: 42rem;
  margin: 0 auto;
  padding: 2rem 1rem;
}
a {
  color: var(--accent);
}
a.download {
  display: inline-block;
  padding: 0.75rem 1.25rem;
  border-radius: 0.5rem;
  background: var(--accent);
  color: var(--on-accent);
  font-weight: 600;
  text-decoration: none;
}
dl {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: 0.25rem 1rem;
}
dt {
  color: var(--muted);
}
dd {
  margin: 0;
  min-width: 0;
  overflow-wrap: anywhere;
}
code,
pre {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.875rem;
  background: var(--code);
  border-radius: 0.25rem;
}
code {
  padding: 0.1rem 0.25rem;
  overflow-wrap: anywhere;
}
pre {
  padding: 0.75rem;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
footer {
  margin-top: 3rem;
  color: var(--muted);
  font-size: 0.875rem;
}
"#;

/// The page's text: a complete HTML document, every value escaped.
#[must_use]
pub fn render(page: &Page) -> String {
    let Page {
        build,
        target,
        minimum_macos,
    } = page;
    let e = |text: &str| escape(text);
    let steps: String = FIRST_LAUNCH
        .iter()
        .map(|step| format!("<li>{}</li>\n", e(step)))
        .collect();
    format!(
        r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Leanmacs nightly</title>
<style>
{STYLE}</style>
</head>
<body>
<main>
<h1>Leanmacs</h1>
<p>{summary}</p>
<p>The nightly: the newest build of <code>main</code>, unreleased, made on every push that passes CI.</p>
<p><a class="download" href="{download}">Download {fixed}</a></p>
<h2>This build</h2>
<dl>
<dt>Build ID</dt>
<dd id="build-id">{id}</dd>
<dt>Commit</dt>
<dd id="commit"><a href="{commit_url}"><code>{commit}</code></a></dd>
<dt>Date</dt>
<dd id="date">{date}</dd>
<dt>Size</dt>
<dd id="size">{size}</dd>
<dt>SHA-256</dt>
<dd id="sha256"><code>{sha256}</code></dd>
</dl>
<p>To check the download, put <a href="{checksum_url}">{checksum}</a> beside it and run <code>shasum -a 256 -c {checksum}</code>.</p>
<h2>Requirements</h2>
<p>macOS {minimum} or later, on Apple silicon (arm64) only.</p>
<h2>Install</h2>
<ol>
<li>Download <code>{fixed}</code> and open it.</li>
<li>Drag Leanmacs.app onto Applications.</li>
<li>Open it, and on first launch follow the steps below.</li>
</ol>
<h2>First launch</h2>
<p>{why}</p>
<ol>
{steps}</ol>
<p>{quarantine_why}</p>
<pre><code>{quarantine_fix}</code></pre>
<h2>Which build is installed</h2>
<pre><code>{version_command}</code></pre>
<p>{version_prints}</p>
<footer>
<p><a href="{source}">Source, issues and licence</a></p>
</footer>
</main>
</body>
</html>
"#,
        summary = e(SUMMARY),
        download = e(&target.download_url(FIXED)),
        fixed = e(FIXED),
        id = e(build.id.as_str()),
        commit_url = e(&target.commit_url(&build.commit)),
        commit = e(build.commit.as_str()),
        date = e(&date(build)),
        size = e(&size(build.size)),
        sha256 = e(build.sha256.as_str()),
        checksum_url = e(&target.download_url(SHA256)),
        checksum = e(SHA256),
        minimum = e(minimum_macos.as_str()),
        why = e(FIRST_LAUNCH_WHY),
        quarantine_why = e(QUARANTINE_WHY),
        quarantine_fix = e(QUARANTINE_FIX),
        version_command = e(VERSION_COMMAND),
        version_prints = e(VERSION_PRINTS),
        source = e(&target.source_url()),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nightly::{Repo, Server};

    /// A fixture case: its `build.json`, its minimum and its page.
    struct Case {
        name: &'static str,
        build_json: &'static str,
        minimum: &'static str,
        index: &'static str,
    }

    const CASES: [Case; 2] = [
        Case {
            name: "nightly-26.0",
            build_json: include_str!("../../../tests/site/nightly-26.0/build.json"),
            minimum: include_str!("../../../tests/site/nightly-26.0/minimum"),
            index: include_str!("../../../tests/site/nightly-26.0/index.html"),
        },
        Case {
            name: "nightly-27.1",
            build_json: include_str!("../../../tests/site/nightly-27.1/build.json"),
            minimum: include_str!("../../../tests/site/nightly-27.1/minimum"),
            index: include_str!("../../../tests/site/nightly-27.1/index.html"),
        },
    ];

    const README: &str = include_str!("../../../packaging/macos/README.txt");

    fn leanmacs() -> Target {
        Target {
            server: Server::parse("https://github.com").expect("a server"),
            repo: Repo::parse("leanmacs/leanmacs").expect("a repo"),
        }
    }

    fn page(case: &Case) -> Page {
        page_from(case.build_json, leanmacs(), case.minimum.trim_end())
            .unwrap_or_else(|e| panic!("{}: {e}", case.name))
    }

    fn rendered(minimum: &str) -> String {
        render(&page_from(CASES[0].build_json, leanmacs(), minimum).expect("a page"))
    }

    #[test]
    fn each_fixture_renders_to_its_golden_page() {
        for case in &CASES {
            assert_eq!(render(&page(case)), case.index, "{}", case.name);
        }
    }

    #[test]
    fn the_page_shows_the_build_and_links_the_nightly() {
        let html = rendered("26.0");
        for part in [
            r#"<dd id="build-id">20261117140322</dd>"#,
            r#"<a href="https://github.com/leanmacs/leanmacs/commit/4f1c2a9e8b7d6c5a4f3e2d1c0b9a8f7e6d5c4b3a"><code>4f1c2a9e8b7d6c5a4f3e2d1c0b9a8f7e6d5c4b3a</code></a>"#,
            r#"<dd id="date">2026-11-17 14:03:22 UTC</dd>"#,
            r#"<dd id="size">182.4 MB (182431744 bytes)</dd>"#,
            r#"<code>9e0c4b1d7a2f5e8c3b6a9d0f1e4c7b2a5d8e1f4c7a0b3d6e9f2c5a8b1e4d7f0a</code>"#,
            r#"<a class="download" href="https://github.com/leanmacs/leanmacs/releases/download/nightly/Leanmacs.dmg">"#,
            r#"href="https://github.com/leanmacs/leanmacs/releases/download/nightly/Leanmacs.dmg.sha256""#,
            "shasum -a 256 -c Leanmacs.dmg.sha256",
            "macOS 26.0 or later",
            "(arm64)",
            r#"<a href="https://github.com/leanmacs/leanmacs">"#,
        ] {
            assert!(html.contains(part), "missing {part}");
        }
    }

    #[test]
    fn the_size_is_megabytes_to_one_place_and_bytes() {
        assert_eq!(size(0), "0.0 MB (0 bytes)");
        assert_eq!(size(49_999), "0.0 MB (49999 bytes)");
        assert_eq!(size(50_000), "0.1 MB (50000 bytes)");
        assert_eq!(size(912_384), "0.9 MB (912384 bytes)");
        assert_eq!(size(182_431_744), "182.4 MB (182431744 bytes)");
    }

    #[test]
    fn the_minimum_is_data() {
        let (old, new) = (rendered("26.0"), rendered("27.1"));
        assert_ne!(old, new);
        assert_eq!(old.replace("26.0", "27.1"), new);
    }

    #[test]
    fn a_macos_version_is_one_to_three_numbers() {
        for good in ["26", "26.0", "26.0.1", "10.15"] {
            assert!(MacosVersion::parse(good).is_ok(), "{good}");
        }
        for bad in [
            "", "26.", ".26", "v26", "26.0 ", " 26.0", "26..0", "26.0.0.0", "26.x",
        ] {
            assert_eq!(MacosVersion::parse(bad), Err(bad.to_owned()), "{bad:?}");
        }
    }

    #[test]
    fn escape_escapes_markup_and_both_quotes() {
        assert_eq!(
            escape(r#"<a href="x">&'"#),
            "&lt;a href=&quot;x&quot;&gt;&amp;&#39;"
        );
        assert_eq!(escape("plain 26.0"), "plain 26.0");
    }

    #[test]
    fn the_page_fits_a_phone_and_follows_the_scheme() {
        let html = rendered("26.0");
        for part in [
            "<!doctype html>\n<html lang=\"en\">",
            r#"<meta charset="utf-8">"#,
            r#"<meta name="viewport" content="width=device-width, initial-scale=1">"#,
            r#"<meta name="color-scheme" content="light dark">"#,
            "@media (prefers-color-scheme: dark)",
            "max-width: 42rem",
        ] {
            assert!(html.contains(part), "missing {part}");
        }
    }

    /// `text` with every run of whitespace made one space.
    fn collapsed(text: &str) -> String {
        text.split_whitespace().collect::<Vec<_>>().join(" ")
    }

    #[test]
    fn the_summary_is_the_readmes() {
        assert!(
            collapsed(README).contains(SUMMARY),
            "README.txt lacks {SUMMARY}"
        );
    }

    /// The install text is `install`'s, held to the README there; here the
    /// page must show every piece of it.
    #[test]
    fn the_page_shows_the_install_text() {
        let html = rendered("26.0");
        for step in FIRST_LAUNCH {
            assert!(
                html.contains(&format!("<li>{}</li>", escape(step))),
                "{step}"
            );
        }
        for line in [FIRST_LAUNCH_WHY, QUARANTINE_WHY, VERSION_PRINTS] {
            assert!(html.contains(&format!("<p>{}</p>", escape(line))), "{line}");
        }
        for command in [QUARANTINE_FIX, VERSION_COMMAND] {
            assert!(
                html.contains(&format!("<pre><code>{}</code></pre>", escape(command))),
                "{command}"
            );
        }
    }

    #[test]
    fn page_from_refuses_a_bad_build_json_or_minimum() {
        let json = CASES[0].build_json;
        match page_from("{}\n", leanmacs(), "26.0") {
            Err(SiteError::BuildJson(BuildJsonError::Missing("build_id"))) => {}
            other => panic!("{other:?}"),
        }
        assert_eq!(
            page_from(json, leanmacs(), "26.0 "),
            Err(SiteError::Minimum("26.0 ".into()))
        );
        assert_eq!(
            SiteError::Minimum("v26".into()).to_string(),
            "the minimum macOS `v26` is not a version (N, N.N or N.N.N)"
        );
        assert_eq!(
            SiteError::BuildJson(BuildJsonError::Missing("size")).to_string(),
            "build.json has no \"size\" line"
        );
    }

    // ---- No other origin.

    /// Each thing in `html` that would make a browser load a resource, from
    /// this origin or another: a loading element, a loading attribute,
    /// `href` anywhere but on `<a>`, a meta refresh, and `url(`, `@import`
    /// or `@font-face` in a style sheet or a `style` attribute. Comments
    /// and the doctype are skipped.
    fn foreign_loads(html: &str) -> Vec<String> {
        const ELEMENTS: [&str; 17] = [
            "script", "link", "img", "iframe", "frame", "embed", "object", "video", "audio",
            "source", "track", "picture", "form", "base", "applet", "portal", "image",
        ];
        const ATTRIBUTES: [&str; 8] = [
            "src",
            "srcset",
            "data",
            "poster",
            "background",
            "ping",
            "action",
            "formaction",
        ];
        let css = |text: &str, at: &str, found: &mut Vec<String>| {
            let lower = text.to_ascii_lowercase();
            for bad in ["url(", "@import", "@font-face"] {
                if lower.contains(bad) {
                    found.push(format!("{bad} in {at}"));
                }
            }
        };
        let mut found = Vec::new();
        let mut rest = html;
        while let Some(open) = rest.find('<') {
            rest = &rest[open + 1..];
            if let Some(after) = rest.strip_prefix("!--") {
                rest = after.find("-->").map_or("", |end| &after[end + 3..]);
                continue;
            }
            let (tag, attrs, after) = parse_tag(rest);
            rest = after;
            if tag.is_empty() || tag.starts_with('/') || tag.starts_with('!') {
                continue;
            }
            if ELEMENTS.contains(&tag.as_str()) {
                found.push(format!("<{tag}>"));
            }
            for (name, value) in &attrs {
                if ATTRIBUTES.contains(&name.as_str()) || (name == "href" && tag != "a") {
                    found.push(format!("{name}= on <{tag}>"));
                }
                if name == "style" {
                    css(value, &format!("<{tag} style>"), &mut found);
                }
            }
            let refresh = attrs
                .iter()
                .any(|(n, v)| n == "http-equiv" && v.eq_ignore_ascii_case("refresh"));
            if tag == "meta" && refresh {
                found.push("<meta http-equiv=refresh>".to_owned());
            }
            if tag == "style" {
                let lower = rest.to_ascii_lowercase();
                let end = lower.find("</style").unwrap_or(rest.len());
                css(&rest[..end], "<style>", &mut found);
                rest = &rest[end..];
            }
        }
        found
    }

    /// The tag starting `text` (just past its `<`): its name and its
    /// attributes, both lowercased but for the values, and the text after
    /// its `>`.
    fn parse_tag(text: &str) -> (String, Vec<(String, String)>, &str) {
        let bytes = text.as_bytes();
        let mut i = 0;
        let word = |i: &mut usize| {
            let start = *i;
            while *i < bytes.len() && !b" \t\n\r\x0c/>=".contains(&bytes[*i]) {
                *i += 1;
            }
            text[start..*i].to_ascii_lowercase()
        };
        let skip = |i: &mut usize| {
            while *i < bytes.len() && b" \t\n\r\x0c/".contains(&bytes[*i]) {
                *i += 1;
            }
        };
        let mut tag = word(&mut i);
        if tag.is_empty() && bytes.first() == Some(&b'/') {
            i += 1;
            tag = format!("/{}", word(&mut i));
        }
        let mut attrs = Vec::new();
        loop {
            skip(&mut i);
            if i >= bytes.len() || bytes[i] == b'>' {
                break;
            }
            let name = word(&mut i);
            let mut value = String::new();
            if bytes.get(i) == Some(&b'=') {
                i += 1;
                match bytes.get(i) {
                    Some(&q) if q == b'"' || q == b'\'' => {
                        let start = i + 1;
                        let end = text[start..]
                            .find(q as char)
                            .map_or(text.len(), |e| start + e);
                        value = text[start..end].to_owned();
                        i = (end + 1).min(text.len());
                    }
                    _ => {
                        let start = i;
                        while i < bytes.len() && !b" \t\n\r\x0c>".contains(&bytes[i]) {
                            i += 1;
                        }
                        value = text[start..i].to_owned();
                    }
                }
            }
            if name.is_empty() {
                i += 1;
            } else {
                attrs.push((name, value));
            }
        }
        (tag, attrs, &text[(i + 1).min(text.len())..])
    }

    #[test]
    fn no_fixture_page_loads_any_resource() {
        for case in &CASES {
            assert_eq!(
                foreign_loads(&render(&page(case))),
                Vec::<String>::new(),
                "{}",
                case.name
            );
        }
    }

    #[test]
    fn the_scan_finds_each_kind_of_load() {
        let clean = rendered("26.0");
        assert!(foreign_loads(&clean).is_empty());
        for injected in [
            "<img src=https://x.example/a.png>",
            r#"<script src="https://x.example/a.js"></script>"#,
            "<script>1</script>",
            r#"<link rel="stylesheet" href="https://x.example/a.css">"#,
            r#"<link rel=icon href=/favicon.ico>"#,
            r#"<p style="background:url(https://x.example/a.png)">x</p>"#,
            r#"<style>@import "https://x.example/a.css";</style>"#,
            "<style>@font-face { font-family: x; }</style>",
            "<style>p { background: URL(a.png) }</style>",
            r#"<iframe src="https://x.example/"></iframe>"#,
            r#"<p srcset="a.png 1x">x</p>"#,
            r#"<meta http-equiv="refresh" content="0; url=https://x.example/">"#,
            r#"<form action="https://x.example/"></form>"#,
            r#"<button formaction="https://x.example/">x</button>"#,
            r#"<a href="https://x.example/" ping="https://x.example/p">x</a>"#,
            r#"<div background="a.png">x</div>"#,
            r#"<video poster="a.png"></video>"#,
            r#"<object data="a.swf"></object>"#,
            "<embed src=a.swf>",
            "<audio src=a.mp3></audio>",
            "<picture></picture>",
            "<IMG SRC='a.png'>",
        ] {
            // Injected near the end, after everything the scan walks first.
            let page = clean.replacen("</main>", &format!("{injected}\n</main>"), 1);
            assert!(!foreign_loads(&page).is_empty(), "missed {injected}");
        }
    }

    #[test]
    fn the_scan_allows_navigation_and_skips_comments() {
        let page = "<!doctype html><a href=\"https://x.example/\">x</a><!-- <img src=x> --><p>url( in text</p>";
        assert_eq!(foreign_loads(page), Vec::<String>::new());
    }
}
