The fixtures of the download page (`crates/editor-release/src/site.rs`'s
golden tests and `crates/editor-release-std/tests/site.rs`, which runs
`leanmacs-release site` itself). Each case is a directory:

- `build.json`: a build's description, exactly as `nightly::build_json`
  writes it.
- `minimum`: the minimum macOS the case renders for, in place of
  `MACOSX_DEPLOYMENT_TARGET`, so the page's minimum is visibly fixture data.
- `index.html`: the page `leanmacs-release site` must write for them, with
  the links on github.com's leanmacs/leanmacs.

The cases:

- `nightly-26.0`: a build of 182431744 bytes (182.4 MB), for macOS 26.0.
- `nightly-27.1`: another build ID, commit and digest, a build under 1 MB
  (912384 bytes, 0.9 MB) to pin the size's formatting, for macOS 27.1.

When the page changes on purpose, regenerate each case's `index.html` and
review the diff before committing it:

    env -u GITHUB_SERVER_URL -u GITHUB_REPOSITORY \
      MACOSX_DEPLOYMENT_TARGET=<case minimum> cargo run -p editor-release-std --bin leanmacs-release -- \
      site tests/site/<case>/build.json tests/site/<case>
