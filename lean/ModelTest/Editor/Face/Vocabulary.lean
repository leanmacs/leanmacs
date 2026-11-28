import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Face
import Editor.Face.Vocabulary
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Loop
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.TabBar
import Editor.Test.Completion
import Editor.Test.Config
import Editor.Text
import Editor.Theme.Check
import ModelTest.Check

/-!
# Model tests: `Editor/Face/Vocabulary.lean`

The model tests of `Editor/Face/Vocabulary.lean`: `faceVocabularyChecks`. The
root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- A scheme written here that draws its cursor in two faces of its own:
the test scheme, except that it reports a cursor in `cursor.normal` at
rest and in `cursor.insert` while keys are pending, and lists both, and
`cursor` itself, which the check lists once. -/
def twoCursors : InputScheme :=
  { TestScheme.scheme with
    report := fun state _ =>
      {
        cursor :=
          { shape := .bar
            face := if state.pending.isEmpty then ⟨"cursor.normal"⟩ else ⟨"cursor.insert"⟩ } }
    cursorFaces := [⟨"cursor.normal"⟩, ⟨"cursor"⟩, ⟨"cursor.insert"⟩] }

/-- The faces the core draws, read from the values that draw them, not from
their text: the cursor of a scheme that names no face, the status fields
the loop gives a modified buffer and a prompt with candidates listed, one
of them chosen, and the faces of a status row and of a divider. The faces a
scheme draws are held to the vocabulary by that scheme's tests (the Vim
scheme's by `vimDefaultChecks`), and the shipped
minibuffer display's faces are checked with it
(`CompletionTest.minibufferDisplayChecks`, the `completion` package's). -/
def drawnFaces : Array FaceName :=
  let context : ModeLine.Context :=
    { loopContext with
      cursor := some ⟨4, 2⟩, lines := 10 }
  let asked : Prompt :=
    { label := "Theme: ", view := ⟨1⟩, asker := ⟨0⟩, continuation := { command := "load-theme" }
      candidates :=
        { all := offered #["a", "b"], listedFor := some ""
          listed := (offered #["a", "b"]).map Completion.Listed.of, chosen := some 0 } }
  #[({} : InputScheme.Report).cursor.face] ++ (ModeLine.standard.fields context).map (·.face) ++
    (ModeLine.standard.fields { context with selected := false }).map (·.face) ++
    (Loop.promptStatus asked).map (·.face) ++
    #[ModeLine.activeFace, ModeLine.inactiveFace, Loop.dividerFace]

/-- The checks of the face vocabulary (`Editor/Face/Vocabulary.lean`), of a
theme written from a palette (`Palette.theme`, `Editor/Face.lean`) and of
the completeness check (`Themes.problems`, `Editor/Theme/Check.lean`), on
themes, palettes and a scheme written here. -/
def faceVocabularyChecks : List Check :=
  [{  name := "the vocabulary names each face once, and says what each is"
      run :=
        let names := Face.vocabularyNames
        pure
          (!names.isEmpty &&
            (List.range names.size).all
              (fun later =>
                (List.range later).all fun earlier => names[later]? != names[earlier]?) &&
            Face.vocabulary.all (!·.meaning.isEmpty)) },
    { name :=
        "the vocabulary lists every face the mode line, the loop and a scheme that names no cursor face draw, and the mode line's, the prompt's, the selected window's row and the divider among them"
      run :=
        pure
          (drawnFaces.all Face.vocabularyNames.contains &&
            [ModeLine.bufferFace, ModeLine.modifiedFace, ModeLine.secondaryFace,
                  ModeLine.inactiveFace, ModeLine.activeFace, Loop.promptFace, Loop.dividerFace].all
              drawnFaces.contains) },
    { name :=
        "the vocabulary holds a badge face and a cursor face for each state a theme written from a palette colours, and no status. face"
      run :=
        pure
          (!Theme.cursorStates.isEmpty &&
            Theme.cursorStates.all
              (fun state =>
                Face.vocabularyNames.contains ⟨s!"mode-line.state.{state}"⟩ &&
                  Face.cursorNames.contains ⟨s!"cursor.{state}"⟩) &&
            ["status.state", "status.name", "status.modified"].all fun name =>
              !Face.vocabularyNames.contains ⟨name⟩) },
    { name :=
        "the built-in theme pads the mode line and the echo area 3 points above and below, and its default face sets no padding"
      run :=
        let padded (theme : Theme) :=
          (theme.merged ⟨"mode-line"⟩).verticalPadding == some 3 &&
            (theme.merged ⟨"echo-area"⟩).verticalPadding == some 3 &&
            (theme.merged ⟨"default"⟩).verticalPadding == some 0
        pure (padded Theme.builtin) },
    { name :=
        "the vocabulary lists the tab bar's faces, the chips' and the selected chip's, and the built-in theme defines them"
      run :=
        pure
          ([TabBar.face, TabBar.selectedFace].all Face.vocabularyNames.contains &&
            TabBar.face != TabBar.selectedFace &&
            [TabBar.face, TabBar.selectedFace].all fun name =>
              Theme.builtin.any (·.name == name)) },
    { name :=
        "the vocabulary lists the markup faces: a heading face for each level 1 to 6, emphasis, strong, code span, code block, link, quote, list marker, table header, and the prose face"
      run :=
        let headings := (List.range 6).map fun level => s!"text.heading.{level + 1}"
        let markup :=
          headings ++
            ["text.emphasis", "text.strong", "text.code-span", "text.code-block", "text.link",
              "text.quote", "text.list-marker", "text.table-header", "text.prose"]
        pure (markup.all fun name => Face.vocabularyNames.contains ⟨name⟩) },
    { name := "the vocabulary lists the four names layout reads by itself"
      run :=
        pure
          (["default", "selection", "mode-line", "echo-area"].all fun name =>
            Face.vocabularyNames.contains ⟨name⟩) },
    { name :=
        "the vocabulary lists the faces declared ahead of the features that draw them: syntax captures, diff, gutter, search, review, an inactive mode line and a block header"
      run :=
        let captures :=
          ["keyword", "string", "comment", "function", "type", "constant", "variable",
                "punctuation"].map
            ("syntax." ++ ·)
        let ahead :=
          ["diff.added", "diff.removed", "diff.changed", "gutter", "search-match",
            "review-unexamined", "mode-line.inactive", "block-header"]
        pure ((captures ++ ahead).all fun name => Face.vocabularyNames.contains ⟨name⟩) },
    { name :=
        "the vocabulary's cursor faces are faces of the vocabulary: cursor first, then every face named cursor. and a state, and no other"
      run :=
        let named :=
          Face.vocabularyNames.filter fun face =>
            face == ⟨"cursor"⟩ || face.name.startsWith "cursor."
        pure
          (Face.cursorNames.all Face.vocabularyNames.contains &&
            Face.cursorNames[0]? == some ⟨"cursor"⟩ &&
            Face.cursorNames.size > 1 &&
            Face.cursorNames == named) },
    { name :=
        "the check's cursor faces of a scheme are cursor and the faces the scheme lists, cursor once, and of a scheme that lists none cursor alone"
      run :=
        pure
          (Themes.cursorFaces twoCursors == #[⟨"cursor"⟩, ⟨"cursor.normal"⟩, ⟨"cursor.insert"⟩] &&
            Themes.cursorFaces TestScheme.scheme == #[⟨"cursor"⟩]) },
    { name :=
        "a theme is held to the vocabulary's cursor faces, or to the ones the caller names: one that defines cursor alone has no cursor problem over a scheme that lists none, and lacks each face the two-cursor scheme draws"
      run :=
        let bare :=
          Theme.builtin.filter fun definition => !(definition.name.name.startsWith "cursor.")
        -- What the check says of the cursors: the faces `bare` leaves out
        -- are faces of the vocabulary, so each is also undefined.
        let ofCursors (problems : Array Themes.Problem) :=
          problems.filter fun problem =>
            match problem with
            | .undefined _ => false
            | _ => true
        pure
          (ofCursors (Themes.problems bare (Themes.cursorFaces TestScheme.scheme)) == #[] &&
            ofCursors (Themes.problems bare (Themes.cursorFaces twoCursors)) ==
              #[.noCursor ⟨"cursor.normal"⟩, .noCursor ⟨"cursor.insert"⟩] &&
            (Themes.problems bare).contains (.noCursor ⟨"cursor.visual"⟩)) },
    { name :=
        "the compilation faces are in the vocabulary, each with a meaning, and the built-in theme defines each once, bold, in its palette's red, orange and green"
      run :=
        let palette := Palette.placeholder
        let faces :=
          [("compilation.error", palette.red), ("compilation.warning", palette.orange),
            ("compilation.note", palette.green)]
        pure
          (faces.all fun (name, colour) =>
            (Face.vocabulary.find? (·.name == ⟨name⟩)).any (!·.meaning.isEmpty) &&
              (Theme.builtin.filter (·.name == ⟨name⟩)).size == 1 &&
              (Theme.builtin.merged ⟨name⟩).foreground == some colour &&
              (Theme.builtin.merged ⟨name⟩).weight == some 700) },
    { name := "the built-in theme has no problem the check finds"
      run := pure (Themes.problems Theme.builtin == #[]) },
    { name :=
        "a theme that leaves a vocabulary face undefined has that problem, for each face of the vocabulary; one with no default has no paper and no ink"
      run :=
        let without (name : FaceName) : Theme := Theme.builtin.filter (·.name != name)
        pure
          (Face.vocabulary.all
              (fun entry =>
                (Themes.problems (without entry.name)).contains (.undefined entry.name)) &&
            [Themes.Problem.noPaper, .noInk].all
              (Themes.problems (without ⟨"default"⟩)).contains) },
    { name :=
        "a theme that leaves a cursor face of the vocabulary undefined has no such cursor, for each of them"
      run :=
        pure
          (Face.cursorNames.all fun face =>
            (Themes.problems (Theme.builtin.filter (·.name != face))).contains (.noCursor face)) },
    { name :=
        "a cursor whose foreground is its own background has that problem and no other, set so or with no foreground set over a background that is the ink, for each cursor face of the vocabulary"
      run :=
        let theme := Theme.builtin
        let paper := (theme.merged ⟨"default"⟩).background
        let ink := (theme.merged ⟨"default"⟩).foreground
        let odd := Color.rgb 1 2 3
        pure
          (some odd != paper && ink != paper &&
            Face.cursorNames.all fun face =>
              Themes.problems
                    (theme.push
                      { name := face,
                        face := { foreground := some odd, background := some odd } }) ==
                  #[.cursorInkOnItself face] &&
                Themes.problems
                    ((theme.filter (·.name != face)).push
                      { name := face, face := { background := ink } }) ==
                  #[.cursorInkOnItself face]) },
    { name :=
        "a cursor whose background is the paper has that problem: set so, with no background set, and when a later default moves the paper to the cursors' background, for each cursor face of the vocabulary"
      run :=
        let theme := Theme.builtin
        let paper := (theme.merged ⟨"default"⟩).background
        let odd := Color.rgb 1 2 3
        let cursors := (Themes.effective theme ⟨"cursor"⟩).2
        let moved := theme.push { name := ⟨"default"⟩, face := { background := cursors } }
        pure
          (some odd != paper && cursors.isSome &&
            Face.cursorNames.all fun face =>
              (Themes.problems
                      (theme.push { name := face, face := { background := paper } })).contains
                  (.cursorOnPaper face) &&
                Themes.problems
                    ((theme.filter (·.name != face)).push
                      { name := face, face := { foreground := some odd } }) ==
                  #[.cursorOnPaper face] &&
                (Themes.problems moved).contains (.cursorOnPaper face)) },
    { name :=
        "a theme whose default sets no background has no paper: the check takes no base colour"
      run :=
        let unpapered :=
          Theme.builtin.map fun definition =>
            if definition.name == ⟨"default"⟩ then
              { definition with face := { definition.face with background := none } }
            else definition
        pure ((Themes.problems unpapered).contains .noPaper) },
    { name :=
        "a theme whose selected window's mode line has the background of the others' has mode lines alike, and that problem alone; set over mode-line, the background each takes is its own or mode-line's"
      run :=
        let theme := Theme.builtin
        let inactive := (Themes.effectiveOver theme ⟨"mode-line.inactive"⟩ ⟨"mode-line"⟩).2
        let unset :=
          theme.map fun definition =>
            if
                definition.name == ⟨"mode-line.active"⟩ ||
                  definition.name == ⟨"mode-line.inactive"⟩ then
              { definition with face := { definition.face with background := none } }
            else definition
        pure
          (inactive.isSome &&
            Themes.problems
                (theme.push { name := ⟨"mode-line.active"⟩, face := { background := inactive } }) ==
              #[.modeLinesAlike] &&
            Themes.problems unset == #[.modeLinesAlike]) },
    { name :=
        "a theme whose window divider is drawn in the paper has the divider on the paper, and that problem alone: set so, or with no foreground over a default whose ink is the paper"
      run :=
        let theme := Theme.builtin
        let paper := (theme.merged ⟨"default"⟩).background
        pure
          (paper.isSome &&
            Themes.problems
                (theme.push { name := ⟨"window-divider"⟩, face := { foreground := paper } }) ==
              #[.dividerOnPaper] &&
            (Themes.problems
                  (((theme.filter (·.name != ⟨"window-divider"⟩)).push
                        { name := ⟨"window-divider"⟩, face := { background := paper } }).push
                    { name := ⟨"default"⟩, face := { foreground := paper } })).contains
              .dividerOnPaper) },
    { name := "each problem's sentence names the face it is about"
      run :=
        let names (problem : Themes.Problem) (face : String) : Bool :=
          (problem.describe.splitOn face).length > 1
        pure
          (names (.undefined ⟨"gutter"⟩) "gutter" &&
            names (.noCursor ⟨"cursor.visual"⟩) "cursor.visual" &&
            names (.cursorOnPaper ⟨"cursor.insert"⟩) "cursor.insert" &&
            names (.cursorInkOnItself ⟨"cursor.normal"⟩) "cursor.normal" &&
            names .modeLinesAlike "mode-line.active" &&
            names .modeLinesAlike "mode-line.inactive" &&
            names .dividerOnPaper "window-divider") },
    { name :=
        "one palette mapping applied to two palettes gives two themes that define the same names in the same order, and each has no problem the check finds"
      run :=
        let light : Palette :=
          { paper := Color.rgb 250 250 245, ink := Color.rgb 30 30 40,
            raised := Color.rgb 225 225 220
            selected := Color.rgb 200 215 235, faint := Color.rgb 140 140 140
            strong := Color.rgb 10 10 20, red := Color.rgb 180 30 30, orange := Color.rgb 190 100 20
            yellow := Color.rgb 160 130 0, green := Color.rgb 40 130 40, cyan := Color.rgb 0 130 140
            blue := Color.rgb 30 80 180, violet := Color.rgb 110 60 170
            magenta := Color.rgb 170 40 130 }
        let dark := Palette.placeholder.theme
        let pale := light.theme
        pure
          (dark != pale && dark.map (·.name) == pale.map (·.name) && Themes.problems dark == #[] &&
            Themes.problems pale == #[]) },
    { name := "the built-in theme has no problem the check finds"
      run := pure (Themes.problems Theme.builtin == #[]) }]

end ModelTest
