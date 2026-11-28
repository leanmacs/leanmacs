import Editor.Link
import ModelTest.Check

/-!
# Model tests: `Editor/Link.lean`

The model tests of `Editor/Link.lean`: `linkChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A link over the bytes `start` to `stop` whose target is the command
`name`. -/
def linkOver (start stop : Nat) (name : String) : Link :=
  { start, stop, target := .command { command := name } }

/-- Three links: `a` over 2 to 5, `b` over 4 to 8, which overlaps the end of
`a`, and `c` over 12 to 14. -/
def linkRow : Array Link :=
  #[linkOver 2 5 "a", linkOver 4 8 "b", linkOver 12 14 "c"]

/-- The name of the command a link's target runs, for reading a lookup
back; `none` for no link or another kind of target. -/
def linkName : Option Link → Option String
  | some { target := .command invocation, .. } => some invocation.command
  | _ => none

/-- The checks of the link lookups and the URL check (`Editor/Link.lean`). -/
def linkChecks : List Check :=
  [{  name :=
        "the link at an offset is the last in order that holds it, its stop not included, and none off every link"
      run :=
        pure <|
          linkName (Link.at? linkRow 2) == some "a" && linkName (Link.at? linkRow 4) == some "b" &&
            linkName (Link.at? linkRow 5) == some "b" &&
            linkName (Link.at? linkRow 8) == none &&
            linkName (Link.at? linkRow 1) == none &&
            linkName (Link.at? linkRow 13) == some "c" &&
            linkName (Link.at? linkRow 14) == none &&
            linkName (Link.at? #[] 0) == none },
    { name :=
        "the next link starts after the offset, from before, at or inside a link, and there is none past the last start"
      run :=
        pure <|
          linkName (Link.after linkRow 0) == some "a" &&
            linkName (Link.after linkRow 2) == some "b" &&
            linkName (Link.after linkRow 3) == some "b" &&
            linkName (Link.after linkRow 4) == some "c" &&
            linkName (Link.after linkRow 9) == some "c" &&
            linkName (Link.after linkRow 12) == none &&
            linkName (Link.after linkRow 20) == none },
    { name :=
        "the previous link starts before the offset, from inside, at or after a link, and there is none before the first start"
      run :=
        pure <|
          linkName (Link.before linkRow 20) == some "c" &&
            linkName (Link.before linkRow 13) == some "c" &&
            linkName (Link.before linkRow 12) == some "b" &&
            linkName (Link.before linkRow 4) == some "a" &&
            linkName (Link.before linkRow 3) == some "a" &&
            linkName (Link.before linkRow 2) == none &&
            linkName (Link.before linkRow 0) == none },
    { name :=
        "a URL starts with a scheme of a letter then letters, digits, plus, minus or dots, and a colon, and holds no control character"
      run :=
        pure <|
          Link.urlScheme? "https://example.com/a b" == some "https" &&
            Link.urlScheme? "rdm:task/x" == some "rdm" &&
            Link.urlScheme? "svn+ssh.1-x://h" == some "svn+ssh.1-x" &&
            Link.urlScheme? "example.com" == none &&
            Link.urlScheme? ":x" == none &&
            Link.urlScheme? "1http://x" == none &&
            Link.urlScheme? "ht_tp://x" == none &&
            Link.urlScheme? "https://a\nb" == none &&
            Link.urlScheme? "https://a\x00b" == none &&
            Link.urlScheme? "https://a\x7fb" == none &&
            Link.urlScheme? "" == none },
    { name := "a link is drawn in the face text.link"
      run := pure <| Link.face == ⟨"text.link"⟩ }]

end ModelTest
