import Editor.Completion.Candidate
import Editor.Completion.Style
import Editor.Completion.Styles
import Editor.Config.Owner
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.Program
import Editor.Test.Completion
import ModelTest.Check

/-!
# Model tests: `Editor/Completion/Style.lean`

The model tests of `Editor/Completion/Style.lean`: `styleChecks`, which also
check the shipped styles (`Editor/Completion/Styles.lean`). The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- Every list of length at most `length` of `letters`, the empty list
first. -/
def wordsOver (letters : List Char) : Nat → List (List Char)
  | 0 => [[]]
  | length + 1 =>
    [] :: (letters.flatMap fun letter => (wordsOver letters length).map (letter :: ·)) |>.eraseDups

/-- `text` split at each space, the empty pieces dropped: the orderless
style's components, written apart from the style. -/
def spaceSplit (text : List Char) : List (List Char) :=
  let (pieces, last) :=
    text.foldl
      (fun (pieces, piece) char =>
        if char == ' ' then (pieces ++ [piece], []) else (pieces, piece ++ [char]))
      (([] : List (List Char)), ([] : List Char))
  (pieces ++ [last]).filter (!·.isEmpty)

/-- Whether `part` occurs in `whole` as a run of adjacent characters. -/
def isInfixOf (part whole : List Char) : Bool :=
  (List.range (whole.length + 1)).any fun start => part.isPrefixOf (whole.drop start)

/-- The characters of `text` whose bytes lie within `span`. -/
def charsWithin (text : String) (span : Completion.Span) : List Char :=
  let (kept, _) :=
    text.toList.foldl
      (fun (kept, offset) char =>
          let next := offset + char.utf8Size
          (if span.start ≤ offset && next ≤ span.stop then kept ++ [char] else kept, next))
      (([] : List Char), 0)
  kept

/-- The checks of the completion style interface (`Editor/Completion/Style.lean`)
and the shipped styles (`Editor/Completion/Styles.lean`), over the fuzzy
model. -/
def styleChecks : List Check :=
  [{  name :=
        "the path style ranks by the last component alone, in the fuzzy model's order, its spans within the last component; a pattern that ends in / lists every candidate in order; a directory candidate notes/ is first for notes"
      run :=
        pure <|
          let candidates := #["~/src/main.lean", "~/src/makefile", "~/src/", "~/a/ma"]
          let hits := styled Completion.Styles.path "~/src/ma" candidates
          let lasts := candidates.map fun candidate => (Completion.Styles.lastComponent candidate)
          hits.map (·.index) == FuzzyModel.rank "ma" (lasts.map (·.2)) &&
                        hits.all
                          (fun hit =>
                            let (offset, last) := (lasts[hit.index]?).getD (0, "")
                            hit.ranges.all fun range =>
                              offset ≤ range.start && range.stop ≤ offset + last.utf8ByteSize) &&
                      (styled Completion.Styles.path "~/src/" candidates).map (·.index) ==
                        #[0, 1, 2, 3] &&
                    ((styled Completion.Styles.path "notes" #["nothing", "notes/", "notes.md"]).map
                          (·.index))[0]? ==
                      some 1 &&
                  Completion.Styles.lastComponent "notes/" == (0, "notes") &&
                Completion.Styles.lastComponent "~/src/main.lean" == (6, "main.lean") &&
              Completion.Styles.path.name == "path" &&
            Completion.Styles.shipped.map (·.name) == #["fuzzy", "orderless", "path"] },
    { name :=
        "the fuzzy style answers, for each text and candidates of a table, the indices the fuzzy model ranks, in that order, each with its leftmost in-order spans; adjacent characters make one span, a character's span is its bytes, and the empty text has none"
      run :=
        pure <|
          let table : List (String × Array String) :=
            [("", #["wq", "edit", "w"]), ("w", #["wq", "edit", "rewrite", "w", "xw"]),
              ("wq", #["wq", "w", "qw", "wxq"]), ("é", #["aéé", "e", "é"]), ("ew", #["rewrite"]),
              ("z", #["a", "b"])]
          table.all
                          (fun (text, candidates) =>
                            let hits := styled Completion.Styles.fuzzy text candidates
                            hits.map (·.index) == FuzzyModel.rank text candidates &&
                              hits.all fun hit =>
                                hit.ranges ==
                                  Completion.Styles.inOrderSpans text
                                    ((candidates[hit.index]?).getD "")) &&
                        Completion.Styles.fuzzy.name == "fuzzy" &&
                      Completion.Styles.inOrderSpans "rt" "rewrite" == #[⟨0, 1⟩, ⟨5, 6⟩] &&
                    Completion.Styles.inOrderSpans "ew" "rewrite" == #[⟨1, 3⟩] &&
                  Completion.Styles.inOrderSpans "wq" "rewrite" == #[] &&
                Completion.Styles.inOrderSpans "é" "aéé" == #[⟨1, 3⟩] &&
              Completion.Styles.inOrderSpans "éb" "xébb" == #[⟨1, 4⟩] &&
            Completion.Styles.inOrderSpans "" "rewrite" == #[] },
    { name :=
        "the orderless style matches exactly the candidates that contain every space-separated component of the text, in any order, in the candidates' order; the text with its components in another order matches the same, and each component lies within one of the hit's ranges"
      run :=
        pure <|
          let candidates := (wordsOver ['a', 'b', 'é'] 3).toArray.map String.ofList
          let texts := wordsOver ['a', 'b', 'é', ' '] 3
          texts.all fun text =>
            let parts := spaceSplit text
            let hits := styled Completion.Styles.orderless (String.ofList text) candidates
            let expected :=
              (Array.range candidates.size).filter fun index =>
                parts.all fun part => isInfixOf part ((candidates[index]?).getD "").toList
            let reversed := String.ofList (" ".toList.intercalate parts.reverse)
            hits.map (·.index) == expected &&
              (styled Completion.Styles.orderless reversed candidates).map (·.index) == expected &&
              hits.all fun hit =>
                parts.all fun part =>
                  hit.ranges.any fun span =>
                    isInfixOf part (charsWithin ((candidates[hit.index]?).getD "") span) },
    { name :=
        "the orderless style's ranges are each component's first occurrence, sorted, with overlapping or touching ones merged, and a text of spaces alone matches every candidate with none"
      run :=
        pure <|
          styled Completion.Styles.orderless "it re" #["rewrite", "tire", "write"] ==
              #[{ index := 0, ranges := #[⟨0, 2⟩, ⟨4, 6⟩] }] &&
            styled Completion.Styles.orderless "ew wr" #["rewrite"] ==
              #[{ index := 0, ranges := #[⟨1, 4⟩] }] &&
            styled Completion.Styles.orderless "  " #["a", ""] ==
              #[{ index := 0 }, { index := 1 }] &&
            Completion.Styles.orderless.name == "orderless" &&
            Completion.Styles.components " a  b " == ["a", "b"] &&
            Completion.Styles.occurrence? "é" "aéé" == some ⟨1, 3⟩ &&
            Completion.Styles.occurrence? "x" "aéé" == none },
    { name :=
        "a style that keeps what its predicate says answers the candidates it holds of, in their order, with no ranges, and asks the matcher nothing"
      run :=
        pure <|
          let starts :=
            Completion.Style.keeping "starts" fun text candidate => candidate.startsWith text
          let (hits, asked) :=
            Program.run (port := fuzzyPort)
              (fun request count => (FuzzyModel.handle request ()).1 |> (·, count + 1))
              (starts.hits "w" #["wq", "edit", "w", "aw"]) 0
          starts.name == "starts" && hits == #[.ofIndex 0, .ofIndex 2] && asked == 0 },
    { name :=
        "matching picks a category's style when it has one and the default otherwise, and with no category the default; the standard matching is the fuzzy style for every category; the shipped styles are fuzzy, orderless and path"
      run :=
        pure <|
          let matching : Completion.Matching :=
            { default := Completion.Styles.fuzzy
              byCategory := fun category =>
                if category == "pick" then some Completion.Styles.orderless else none }
          (matching.styleFor (some "pick")).name == "orderless" &&
            (matching.styleFor (some "other")).name == "fuzzy" &&
            (matching.styleFor none).name == "fuzzy" &&
            (Completion.Matching.standard.styleFor (some "pick")).name == "fuzzy" &&
            Completion.Styles.shipped.map (·.name) == #["fuzzy", "orderless", "path"] &&
            Completion.Styles.unknown "nope" == "no completion style is registered under `nope`" }]

end ModelTest
