import Editor.File.Model
import Editor.Grep
import Editor.Grep.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Grep/Model.lean`

The model tests of `Editor/Grep/Model.lean`: `grepModelChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The root the search model's checks search. -/
def grepRoot : System.FilePath :=
  "/grep"

/-- A file model with `files` under `grepRoot`, each a path under it and its
text, and the directories they are in. -/
def grepFiles (files : List (String × String)) : FileModel :=
  files.foldl
    (fun model (name, text) =>
      let path := grepRoot / name
      let model :=
        match path.parent with
        | some parent => model.withDirectory parent
        | none => model
      model.withFile path text.toUTF8)
    (({} : FileModel).withDirectory grepRoot)

/-- Every delivery of a search of `pattern` over `files`, with `bound`, read
to its end; `none` when the start or a read is refused. -/
def grepDeliveries (files : FileModel) (pattern : String) (bound : Nat := 64)
    (limits : Grep.Limits := { files := 100, found := 1000 }) : Option (Array Grep.Delivery) :=
  Id.run do
    let (started, model) :=
      (({} : GrepModel).handle files (.start grepRoot pattern #[] limits bound))
    let .ok search := started | return none
    let mut model := model
    let mut deliveries := #[]
    for _ in [0:100] do
      let (read, after) := model.read search.number
      model := after
      let .ok delivery := read | return none
      deliveries := deliveries.push delivery
      if delivery.ended.isSome then
        return some deliveries
    return none

/-- The paths of every file `deliveries` hold, under `grepRoot`. -/
def grepPaths (deliveries : Array Grep.Delivery) : List String :=
  (deliveries.toList.flatMap fun delivery => delivery.found.toList).map fun found =>
    (found.path.toString.drop (grepRoot.toString.length + 1)).toString

/-- The checks of the search model (`Editor/Grep/Model.lean`), exactly: the
walk's order at depth, an ignored directory, a binary file, the order of the
refusals, how deliveries are cut, a search forgotten after its last
delivery, and the searches ended with their job. -/
def grepModelChecks : List Check :=
  [{  name :=
        "the search model walks depth first, each directory's entries by name, so a/b comes before a-c"
      run := do
        let files := grepFiles [("b", "x"), ("a-c", "x"), ("a/b", "x"), ("a/a/z", "x")]
        return (grepDeliveries files "x").map grepPaths == some ["a/a/z", "a/b", "a-c", "b"] },
    { name :=
        "the search model leaves out a directory the root's .ignore names, and a binary file, and everything hidden"
      run := do
        let files :=
          grepFiles
            [(".ignore", "gen\n"), ("gen/a", "x"), ("sub/gen", "x"), ("bin", "x\x00"),
              (".h/a", "x"), ("keep", "x")]
        return (grepDeliveries files "x").map grepPaths == some ["keep"] },
    { name :=
        "the search model refuses a start in order: not absolute, then a bound of 0, then a pattern that is not literal, then an overlay with no snapshot"
      run := do
        let files := grepFiles [("a", "x")]
        let start (root : System.FilePath) (pattern : String) (bound : Nat)
          (overlays : Array (System.FilePath × File.Source) := #[]) :=
          (({} : GrepModel).handle files
              (.start root pattern overlays { files := 1, found := 1 } bound)).1
        let kind : Except GrepError Grep.Id → String
          | .error (.notAbsolute _) => "notAbsolute"
          | .error (.failed _) => "failed"
          | .error (.invalid _) => "invalid"
          | .error .noSuchSnapshot => "noSuchSnapshot"
          | _ => "other"
        let missing := #[(grepRoot / "a", File.Source.snapshot ⟨7⟩)]
        return kind (start "rel" "a.b" 0 missing) == "notAbsolute" &&
            kind (start grepRoot "a.b" 0 missing) == "failed" &&
            kind (start grepRoot "a.b" 1 missing) == "invalid" &&
            kind (start grepRoot "x" 1 missing) == "noSuchSnapshot" },
    { name :=
        "the search model cuts a file with more matches than the bound across deliveries, and only the last holds the end"
      run := do
        let files := grepFiles [("a", "x x x"), ("b", "x")]
        let some deliveries := grepDeliveries files "x" 2 | return false
        let sizes := deliveries.toList.map fun delivery => delivery.found.map (·.found.size)
        let ends := deliveries.toList.map (·.ended.isSome)
        return sizes == [#[2], #[1, 1]] && ends == [false, true] },
    { name :=
        "the search model forgets a search after its last delivery, and a later read is noSuchSearch"
      run := do
        let files := grepFiles [("a", "x")]
        let (_, model) :=
          ({} : GrepModel).handle files (.start grepRoot "x" #[] { files := 9, found := 9 } 9)
        let (first, model) := model.read 1
        let (second, _) := model.read 1
        let ended :=
          match first with
          | .ok delivery => delivery.ended == some (.complete 1 1)
          | .error _ => false
        return ended && second == .error .noSuchSearch },
    { name := "the search model records the searches a job held as ended with it, and forgets them"
      run := do
        let files := grepFiles [("a", "x")]
        let (_, model) :=
          ({} : GrepModel).handle files (.start grepRoot "x" #[] { files := 9, found := 9 } 9)
        let (_, model) := model.handle files (.start grepRoot "x" #[] { files := 9, found := 9 } 9)
        let model := model.endAll
        return model.ended == #[1, 2] && model.searches.isEmpty }]

end ModelTest
