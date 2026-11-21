import Editor.Fuzzy.Model
import WorkingSet.Refind
import WorkingSetTest.Check

/-!
# Model tests: `WorkingSet/Refind.lean`

The model tests of `WorkingSet/Refind.lean`: `workingSetRefindChecks`. The
test driver's root, `WorkingSetTest/Model.lean`, runs them; its module doc
says what each shows.
-/

namespace WorkingSetTest

open Editor

/-- Where `text` places `stored`, the ladder run against the fuzzy model. -/
def refoundIn (text : String) (stored : WorkingSet.Stored) : WorkingSet.Placement :=
  (Program.run (port := fuzzyPort) FuzzyModel.handle (WorkingSet.refind text stored) ()).1

/-- Lines of filler, each different from the others and from every quote
below by far more than a quarter of its bytes. -/
def fillerLines (count : Nat) (from_ : Nat := 0) : String :=
  String.join
    ((List.range count).map fun index => s!"filler {from_ + index} of the file, with some words\n")

/-- The byte offset where `part` starts in `text`, the first time. -/
def offsetOf (text part : String) : Nat :=
  ((text.splitOn part).headD "").utf8ByteSize

/-- The range of `text` that is `part`, the first time, captured. -/
def capturedPart (text part : String) : WorkingSet.Stored :=
  let start := offsetOf text part
  WorkingSet.capture text start (start + part.utf8ByteSize) "a.txt"

/-- A quote of about 1,800 bytes: forty lines alike but for their numbers,
then four lines of words found nowhere else, about 190 bytes. -/
def longQuote : String :=
  String.join ((List.range 40).map fun index => s!"block line {index} holds words {index * 7}\n") ++
    "zebra quantum fjord kettle umbrella\n" ++
    "violin marmalade orbit cactus lantern\n" ++
    "pebble hurricane saffron typewriter\n" ++
    "glacier waffle compass nebula ending"

/-- The checks of the re-find ladder (`WorkingSet/Refind.lean`), run
against the fuzzy model: each step, the order among occurrences, the short
and the long quote, text that is not ASCII, and a point past the end. -/
def workingSetRefindChecks : List Check :=
  let quote := "let configuration = load_settings(path);"
  let text := fillerLines 10 ++ quote ++ "\n" ++ fillerLines 10 10
  let stored := capturedPart text quote
  let start := offsetOf text quote
  let stop := start + quote.utf8ByteSize
  [{  name := "a range in a text that did not change is found exact, where it was"
      run := return refoundIn text stored == .exact start stop },
    { name := "a range with lines inserted above it is found moved, at its new place"
      run :=
        let inserted := "new one\nnew two\nnew three\n"
        return refoundIn (inserted ++ text) stored ==
            .moved (start + inserted.utf8ByteSize) (stop + inserted.utf8ByteSize) },
    { name :=
        "of two copies of a quote, the one whose context matches the stored context is found, though the other is nearer where it was expected"
      run :=
        let original := "alpha: start\nbeta: return value; :beta\n"
        let held := capturedPart original "return value;"
        let now := "zz\nalpha: return value; :alpha\n" ++ fillerLines 5 ++ "beta: return value; :beta\n"
        let far := offsetOf now "beta: return value;" + "beta: ".utf8ByteSize
        return held.start == ⟨2, 7⟩ && refoundIn now held == .moved far (far + 13) },
    { name := "of two copies of a quote with the same context, the nearer is found"
      run :=
        let held := capturedPart "a\nkey = 1\nb\n" "key = 1"
        let now := "c\na\nkey = 1\nb\nmiddle\nmiddle\nmiddle\na\nkey = 1\nb\n"
        return refoundIn now held == .moved 4 11 },
    { name :=
        "a 40-byte quote with one character changed is found changed, at its span"
      run :=
        let edited := text.replace "load_settings" "load_setting5"
        return quote.utf8ByteSize == 40 && refoundIn edited stored == .changed start stop },
    { name := "a quote deleted is drifted"
      run :=
        let deleted := text.replace (quote ++ "\n") ""
        return refoundIn deleted stored == .drifted },
    { name := "a quote under eight characters that was edited is drifted, not looked for with errors"
      run :=
        let short := fillerLines 3 ++ "foo(x)\n" ++ fillerLines 3 3
        let held := capturedPart short "foo(x)"
        return refoundIn (short.replace "foo(x)" "foo(y)") held == .drifted },
    { name :=
        "a long quote whose middle was rewritten is found changed, from where its first bytes are to where its last bytes end"
      run :=
        let long := fillerLines 4 ++ longQuote ++ "\n" ++ fillerLines 4 4
        let held := capturedPart long longQuote
        let rewritten :=
          long.replace "block line 18 holds words 126\nblock line 19 holds words 133\n"
            "something else entirely, of another length and other words\n"
        let first := offsetOf rewritten "block line 0 "
        let last := offsetOf rewritten "nebula ending" + "nebula ending".utf8ByteSize
        return longQuote.utf8ByteSize > WorkingSet.fuzzyWhole &&
            refoundIn rewritten held == .changed first last },
    { name := "a long quote whose last lines were deleted is drifted"
      run :=
        let long := fillerLines 4 ++ longQuote ++ "\n" ++ fillerLines 4 4
        let held := capturedPart long longQuote
        let cut :=
          long.replace
            ("zebra quantum fjord kettle umbrella\n" ++ "violin marmalade orbit cactus lantern\n" ++
                "pebble hurricane saffron typewriter\n" ++ "glacier waffle compass nebula ending\n")
            ""
        return refoundIn cut held == .drifted },
    { name := "a quote in text that is not ASCII, changed, is found on character boundaries"
      run :=
        let line := "une recette de crème brûlée au café"
        let original := fillerLines 3 ++ line ++ "\n" ++ fillerLines 3 3
        let held := capturedPart original line
        let changed := original.replace "brûlée" "brulée"
        let begin := offsetOf changed "une recette"
        let finish := begin + "une recette de crème brulée au café".utf8ByteSize
        return refoundIn changed held == .changed begin finish },
    { name :=
        "a stored point past the end of the text is clamped: an unchanged quote is found moved, and a changed one changed"
      run :=
        let past := { stored with start := ⟨999, 1⟩, stop := ⟨999, 9⟩ }
        let edited := text.replace "load_settings" "load_setting5"
        return refoundIn text past == .moved start stop && refoundIn edited past == .changed start stop }]

end WorkingSetTest
