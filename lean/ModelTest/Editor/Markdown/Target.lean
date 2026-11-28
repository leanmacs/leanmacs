import Editor.Link
import Editor.Markdown.Target
import ModelTest.Check

/-!
# Model tests: `Editor/Markdown/Target.lean`

The model tests of `Editor/Markdown/Target.lean`: `markdownTargetChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Markdown

/-- The root the target checks resolve relative paths against. -/
def targetRoot : System.FilePath :=
  "/work"

/-- The checks of what a Markdown destination and a bare reference name
(`Editor/Markdown/Target.lean`). -/
def markdownTargetChecks : List Check :=
  [{  name := "a destination in each web scheme, in any case, is a URL as it is"
      run :=
        pure <|
          ["https://x.y/a", "http://x.y", "mailto:me@x.y", "ftp://x.y/f", "file:///etc/hosts",
                "HTTPS://X.Y"].all
            fun url => targetOf none url == some (.url url) },
    { name := "a destination in any other scheme is a reference in it, for its resolver"
      run :=
        pure <|
          targetOf none "rdm:task/x" == some (.reference "rdm" "task/x") &&
            targetOf none "a:1" == some (.reference "a" "1") },
    { name :=
        "an absolute path is a location as it is, with or without a root, its line and column made rows and columns from 0"
      run :=
        pure <|
          targetOf none "/etc/hosts" == some (.location "/etc/hosts" 0 0) &&
            targetOf (some targetRoot) "/etc/hosts:3" == some (.location "/etc/hosts" 2 0) &&
            targetOf none "/a/b.rs:12:5" == some (.location "/a/b.rs" 11 4) },
    { name := "a relative path is resolved against the root, and with no root is not linked"
      run :=
        pure <|
          targetOf (some targetRoot) "src/main.rs:12:5" ==
              some (.location (targetRoot / "src/main.rs") 11 4) &&
            targetOf (some targetRoot) "images/logo.png" ==
              some (.location (targetRoot / "images/logo.png") 0 0) &&
            targetOf none "src/main.rs:12:5" == none &&
            targetOf none "images/logo.png" == none },
    { name := "a path whose name holds a dot and a line is a location, not a scheme"
      run :=
        pure <|
          targetOf (some targetRoot) "README.md:4" ==
            some (.location (targetRoot / "README.md") 3 0) },
    { name :=
        "a destination in angle brackets is read without them: a path with a blank is a location, and a URL a URL"
      run :=
        pure <|
          targetOf (some targetRoot) "<a b.md>" == some (.location (targetRoot / "a b.md") 0 0) &&
            targetOf (some targetRoot) "<https://x>" == some (.url "https://x") &&
            targetOf (some targetRoot) "<src/a.rs:3>" ==
              some (.location (targetRoot / "src/a.rs") 2 0) },
    { name :=
        "a path's fragment or query is left out before its line is read, and a reference's and a URL's are kept"
      run :=
        pure <|
          targetOf (some targetRoot) "x.md#sec" == some (.location (targetRoot / "x.md") 0 0) &&
            targetOf (some targetRoot) "x.md:3#sec" == some (.location (targetRoot / "x.md") 2 0) &&
            targetOf (some targetRoot) "docs/a.md?raw=1" ==
              some (.location (targetRoot / "docs/a.md") 0 0) &&
            targetOf (some targetRoot) "/a/b.md:2:4#x" == some (.location "/a/b.md" 1 3) &&
            targetOf none "rdm:src/a.lean@abc#L3" == some (.reference "rdm" "src/a.lean@abc#L3") &&
            targetOf none "https://x.y/a#b" == some (.url "https://x.y/a#b") &&
            targetOf (some targetRoot) "?q" == none },
    { name := "a backslash escape in a destination is its character"
      run :=
        pure <|
          targetOf (some targetRoot) "a\\_b\\(1\\).md" ==
              some (.location (targetRoot / "a_b(1).md") 0 0) &&
            targetOf (some targetRoot) "a\\b.md" == some (.location (targetRoot / "a\\b.md") 0 0) },
    { name := "an empty destination and one to a heading of the same document are not linked"
      run :=
        pure <|
          targetOf (some targetRoot) "" == none && targetOf (some targetRoot) "#top" == none },
    { name :=
        "a bare http or https token in text is a URL, its trailing punctuation dropped, and a scheme alone is not"
      run :=
        pure <|
          references none "see https://x.y/a. and (http://b.c)!" ==
              #[(4, 17, .url "https://x.y/a"), (24, 34, .url "http://b.c")] &&
            references none "https:// alone" == #[] },
    { name :=
        "a path:line token is a location, a path:line:column one too, and its trailing punctuation is dropped"
      run :=
        pure <|
          references (some targetRoot) "at src/a.rs:12, and /b/c.lean:3:9." ==
            #[(3, 14, .location (targetRoot / "src/a.rs") 11 0),
              (20, 33, .location "/b/c.lean" 2 8)] },
    { name :=
        "a token whose path holds no slash or dot, or a colon, or whose line or column is not a whole number of at least 1, is not a location"
      run :=
        pure <|
          references (some targetRoot) "a:1 https://x:80 x/y:0 x/y:3:0 x/y:z a:b:c.rs:1 x.rs:-1" ==
            #[(4, 16, .url "https://x:80")] },
    { name := "a relative path:line token with no root is not linked"
      run := pure <| references none "src/a.rs:12" == #[] },
    { name := "a reference after multibyte text is at its byte offset"
      run :=
        pure <|
          references (some targetRoot) "é漢 src/a.rs:2" ==
            #[(6, 16, .location (targetRoot / "src/a.rs") 1 0)] }]

end ModelTest
