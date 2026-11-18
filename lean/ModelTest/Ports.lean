import Editor.Clipboard.Contract
import Editor.Clipboard.Model
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Display.Model
import Editor.Ex.Line
import Editor.Face
import Editor.Face.Vocabulary
import Editor.File.Model
import Editor.Fuzzy.Contract
import Editor.Fuzzy.Model
import Editor.InputScheme.Vim.Default
import Editor.Language
import Editor.Mode
import Editor.ModeLine
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree.Contract
import Editor.SyntaxTree.Model
import Editor.TabBar
import Editor.Themes.Check
import Editor.Themes.Compiled
import Editor.Themes.FairyFloss
import Editor.Themes.Solarized
import Editor.Watch.Model
import ModelTest.Config

/-!
# Model tests: ports and their models

The checks of the scene, the mode line and faces and themes as data, the
display model, the text model's steps and the undo tree, the file model, the
command port, the watch, clipboard, fuzzy matching and syntax tree
interfaces, and scrolling.

Its lists of checks: `sceneChecks`, `modeLineChecks`, `faceChecks`,
`faceVocabularyChecks`, `solarizedChecks`, `fairyFlossChecks`,
`displayChecks`, `textModelStepChecks`, `undoTreeChecks`, `fileModelChecks`,
`commandPortChecks`, `watchChecks`, `clipboardChecks`, `fuzzyChecks`,
`syntaxTreeChecks`, `guardChecks`, `blockedScrollChecks`, `scrollChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- A scene of two views, with every field of a scene and of a view set: the
first view focused, with two selections, a decoration and two status fields;
the second with none of those. Its content is named by handles only. -/
def twoViews : Scene where
  size := { width := 1600, height := 1200 }
  views :=
    #[{ id := ⟨0⟩, rect := { x := 0, y := 0, width := 800, height := 1160 }, snapshot := ⟨3⟩
        scroll := { text := ⟨1⟩, index := 0 }
        selections := #[{ text := ⟨1⟩, index := 1 }, { text := ⟨1⟩, index := 2 }]
        cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
        decorations := #[{ start := 4, stop := 9, face := ⟨"search.match"⟩ }]
        status :=
          #[{ text := "notes.txt", face := ⟨"mode-line.buffer"⟩, padding := 4 },
            { text := "1:1", face := ⟨"mode-line.secondary"⟩, side := .right, padding := 4 }] },
      { id := ⟨1⟩, rect := { x := 800, y := 0, width := 800, height := 1160 }, snapshot := ⟨4⟩
        scroll := { text := ⟨2⟩, index := 0 }, selections := #[]
        cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }, decorations := #[], status := #[] }]
  focused := some ⟨0⟩
  echo := "2 lines yanked"
  pending := "d2"
  preedit := some "´"

/-- The checks of the scene, which is plain data (`Editor/Scene.lean`). -/
def sceneChecks : List Check :=
  [{ name := "a scene of two views reads back every field it was built with",
     run :=
       pure
         (twoViews.size == { width := 1600, height := 1200 } && twoViews.views.size == 2 &&
           (twoViews.views[0]?.map (·.selections.size)) == some 2 &&
           (twoViews.views[0]?.map (·.decorations)) ==
             some #[{ start := 4, stop := 9, face := ⟨"search.match"⟩ }] &&
           (twoViews.views[0]?.map (·.status.map (·.text))) == some #["notes.txt", "1:1"] &&
           (twoViews.views[0]?.map (·.status.map (·.side))) == some #[.left, .right] &&
           (twoViews.views[1]?.map (·.cursor)) ==
             some { shape := .bar, face := ⟨"cursor.insert"⟩ } &&
           (twoViews.views[1]?.map (·.rect.x)) == some 800 &&
           (twoViews.views[1]?.map (·.snapshot)) == some ⟨4⟩ &&
           (twoViews.views[1]?.map (·.scroll)) == some { text := ⟨2⟩, index := 0 } &&
           twoViews.focused == some ⟨0⟩ &&
           twoViews.echo == "2 lines yanked" &&
           twoViews.pending == "d2" &&
           twoViews.preedit == some "´") },
    { name := "two scenes are equal exactly when their fields are"
      run :=
        pure
          (twoViews == twoViews && twoViews != { twoViews with pending := "" } &&
            twoViews != { twoViews with views := twoViews.views.pop }) },
    { name :=
        "a status field is on the left with no padding and a view has no status face, unless they say so"
      run :=
        let field : StatusField := { text := "x", face := ⟨"mode-line.buffer"⟩ }
        let right : StatusField :=
          { field with
            side := .right, padding := 4 }
        match twoViews.views[1]? with
        | some view =>
          pure
            (field.side == .left && field.padding == 0 && right.side == .right &&
              right.padding == 4 &&
              field != right &&
              view.statusFace == none &&
              { view with statusFace := some ⟨"mode-line.inactive"⟩ } != view)
        | none => pure false },
    { name :=
        "a scene has no divider unless it says so, and one with a divider reads back its rectangle and its face"
      run :=
        let divider : Divider :=
          { rect := { x := 798, y := 0, width := 2, height := 1200 }, face := ⟨"window-divider"⟩ }
        let divided := { twoViews with dividers := #[divider] }
        pure
          (twoViews.dividers.isEmpty && divided != twoViews &&
            divided.dividers.map (·.rect.x) == #[798] &&
            divided.dividers.map (·.face) == #[⟨"window-divider"⟩]) }]

/-- The texts of `fields`, each with its face's name. -/
def textsAndFaces (fields : Array StatusField) : Array (String × String) :=
  fields.map fun field => (field.text, field.face.name)

/-- The checks of the mode line (`Editor/ModeLine.lean`): the shipped
segments' fields, in the order a listing gives, for a selected and an
unselected window. -/
def modeLineChecks : List Check :=
  let secondary (text : String) : StatusField :=
    { text, face := ⟨"mode-line.secondary"⟩, side := .right, padding := 4 }
  let positionOf (row lines : Nat) : Array String :=
    let fields :=
      ModeLine.standard.fields
        { loopContext with
          cursor := some ⟨row, 0⟩, lines }
    (fields.filter (·.side == .right)).map (·.text) |>.toList.getLast?.toArray
  [{  name :=
        "the shipped mode line of a selected window on a modified file in normal state is the badge, the name, the mark and the directory on the left, and the mode, line:col and position on the right"
      run :=
        pure
          (ModeLine.standard.fields loopContext ==
            #[{ text := "NORMAL", face := ⟨"mode-line.state.normal"⟩, padding := 8 },
              { text := "Loop.lean", face := ⟨"mode-line.buffer"⟩, padding := 4 },
              { text := "●", face := ⟨"mode-line.modified"⟩, padding := 4 },
              { text := "lean/Editor", face := ⟨"mode-line.secondary"⟩, padding := 4 },
              secondary "lean", secondary "959:5", secondary "41%"]) },
    { name :=
        "an unselected window on the same buffer has no badge, and every field in mode-line.inactive with the same texts, sides and paddings"
      run :=
        let selected := ModeLine.standard.fields loopContext
        let unselected := ModeLine.standard.fields (loopContext (selected := false))
        pure
          (unselected == (selected.extract 1).map ({ · with face := ModeLine.inactiveFace }) &&
            ModeLine.inactiveFace == ⟨"mode-line.inactive"⟩ &&
            ModeLine.activeFace == ⟨"mode-line.active"⟩) },
    { name :=
        "a segment with nothing to say gives no field: no directory with no file or a bare name, no mode with none, no line:col or position with no cursor, no mark unmodified"
      run :=
        let texts (context : ModeLine.Context) := (ModeLine.standard.fields context).map (·.text)
        let bare := loopContext (loopLean (path := "Loop.lean"))
        let dotted := loopContext (loopLean (path := "./Loop.lean"))
        let noFile := loopContext { loopLean with file := none }
        let noMode := loopContext { loopLean with major := none }
        let noCursor := { loopContext with cursor := none }
        let unmodified := loopContext (loopLean (modified := false))
        pure
          (texts bare == #["NORMAL", "Loop.lean", "●", "lean", "959:5", "41%"] &&
            texts dotted == #["NORMAL", "Loop.lean", "●", "lean", "959:5", "41%"] &&
            texts noFile == #["NORMAL", "Loop.lean", "●", "lean", "959:5", "41%"] &&
            texts noMode == #["NORMAL", "Loop.lean", "●", "lean/Editor", "959:5", "41%"] &&
            texts noCursor == #["NORMAL", "Loop.lean", "●", "lean/Editor", "lean"] &&
            texts unmodified == #["NORMAL", "Loop.lean", "lean/Editor", "lean", "959:5", "41%"]) },
    { name :=
        "the position is All in a buffer of one row, Top on the first row, Bot on the last or past it, and otherwise the cursor's row as a whole percentage of the rows"
      run :=
        pure
          (positionOf 0 1 == #["All"] && positionOf 0 0 == #["All"] &&
            positionOf 0 10 == #["Top"] &&
            positionOf 9 10 == #["Bot"] &&
            positionOf 12 10 == #["Bot"] &&
            positionOf 4 10 == #["50%"] &&
            positionOf 1 3 == #["66%"]) },
    { name := "the line:col is the cursor's row and column counted from 1"
      run :=
        let fields :=
          ModeLine.standard.fields
            { loopContext with
              cursor := some ⟨0, 0⟩, lines := 1 }
        pure ((fields.map (·.text)).contains "1:1") },
    { name := "a listing's order and side win over the segment's own place"
      run :=
        let line :=
          ModeLine.resolve { left := #["position"], right := #["buffer"] } ModeLine.shipped?
        let fields := line.1.fields loopContext
        pure
          (line.2.isEmpty &&
            fields.map (fun field => (field.text, field.side)) ==
              #[("41%", .left), ("Loop.lean", .right)]) },
    { name :=
        "a listing that names a segment nobody registered keeps the rest, in order, and names the unknown ones once each, in order"
      run :=
        let (line, unknown) :=
          ModeLine.resolve { left := #["state", "nope", "buffer", "nope"], right := #["gone"] }
            ModeLine.shipped?
        pure
          (textsAndFaces (line.fields loopContext) ==
              #[("NORMAL", "mode-line.state.normal"), ("Loop.lean", "mode-line.buffer")] &&
            unknown == #["nope", "gone"] &&
            ModeLine.unknown "nope" == "no segment is registered as `nope`") },
    { name :=
        "the default order is the badge, buffer, modified mark, changed mark and directory on the left, and major mode, line:col and position on the right"
      run :=
        pure
          (ModeLine.Order.standard ==
              { left := #["state", "buffer", "modified", "changed", "directory"]
                right := #["major-mode", "line-column", "position"] } &&
            ModeLine.shipped.map (·.name) ==
              #["state", "buffer", "modified", "changed", "directory", "major-mode", "line-column",
                "position"] &&
            ModeLine.standard.left.map (·.name) == ModeLine.Order.standard.left &&
            ModeLine.standard.right.map (·.name) == ModeLine.Order.standard.right) }]

/-- The checks of faces and of the built-in theme, which are plain data
(`Editor/Face.lean`). What a face looks like in a frame is layout's rule,
pinned in `crates/editor-layout`; these pin what Lean itself defines. -/
def faceChecks : List Check :=
  [{
      name :=
        "the built-in theme defines default first, then each other face of the vocabulary, each once and nothing else",
      run :=
        let names := Theme.builtin.map (·.name)
        pure
          (names[0]? == some ⟨"default"⟩ && names.size == Face.vocabularyNames.size &&
            Face.vocabularyNames.all names.contains) },
    { name :=
        "the built-in search-match face sets a background that is not the default face's, and a foreground"
      run :=
        let face := (Theme.builtin.find? (·.name == ⟨"search-match"⟩)).map (·.face)
        let paper := (Theme.builtin.find? (·.name == ⟨"default"⟩)).bind (·.face.background)
        pure
          (match face with
          | some face =>
            face.background.isSome && face.background != paper && face.foreground.isSome
          | none => false) },
    { name := "the built-in default face sets every attribute, and no other built-in face does"
      run :=
        let complete (face : Face) : Bool :=
          face.family.isSome && face.size.isSome && face.weight.isSome && face.slant.isSome &&
            face.foreground.isSome &&
            face.background.isSome &&
            face.underline.isSome &&
            face.strikeThrough.isSome &&
            face.lineHeight.isSome &&
            face.verticalPadding.isSome
        pure ((Theme.builtin.filter (complete ·.face)).map (·.name.name) == #["default"]) },
    { name :=
        "a face over another takes each attribute from the upper where it sets it and from the lower where it does not"
      run :=
        let upper : Face := { foreground := some (Color.rgb 1 0 0), weight := some 700 }
        let lower : Face :=
          { foreground := some (Color.rgb 2 0 0), background := some (Color.rgb 3 0 0)
            size := some 12 }
        pure
          (upper.over lower ==
              { foreground := some (Color.rgb 1 0 0), weight := some 700
                background := some (Color.rgb 3 0 0), size := some 12 } &&
            ({} : Face).over lower == lower &&
            upper.over {} == upper &&
            ({ verticalPadding := some 3 } : Face).over { verticalPadding := some 5 } ==
              { verticalPadding := some 3 } &&
            ({} : Face).over { verticalPadding := some 5 } == { verticalPadding := some 5 }) },
    { name :=
        "a theme's merged face of a name defined twice is the later definition's set attributes over the earlier's, ignores other names, and is the empty face for a name it does not define"
      run :=
        let theme : Theme :=
          #[{ name := ⟨"a"⟩, face := { foreground := some (Color.rgb 1 0 0), size := some 10 } },
            { name := ⟨"b"⟩, face := { background := some (Color.rgb 9 9 9) } },
            { name := ⟨"a"⟩, face := { foreground := some (Color.rgb 2 0 0) } }]
        pure
          (theme.merged ⟨"a"⟩ == { foreground := some (Color.rgb 2 0 0), size := some 10 } &&
            theme.merged ⟨"b"⟩ == { background := some (Color.rgb 9 9 9) } &&
            theme.merged ⟨"c"⟩ == {}) },
    { name := "a theme defines a name it gives an empty definition, and not a name it gives none"
      run :=
        let theme : Theme := #[{ name := ⟨"plain"⟩, face := {} }]
        pure (theme.defines ⟨"plain"⟩ && !theme.defines ⟨"other"⟩) },
    { name := "a colour is its four bytes, red first, and one made of three is opaque"
      run :=
        pure
          (Color.rgba 0x12 0x34 0x56 0x78 == { word := 0x12345678 } &&
            Color.rgb 0x12 0x34 0x56 == { word := 0x123456ff }) },
    { name :=
        "a length's literal is whole pixels, in 64ths, and one longer than a length holds is the longest"
      run :=
        pure
          ((14 : Pixels) == { sixtyFourths := 896 } && (0 : Pixels) == { sixtyFourths := 0 } &&
            Pixels.whole (2 ^ 40) == { sixtyFourths := 0xffffffff }) },
    { name :=
        "a face sets nothing it was not told to, and two faces are equal exactly when their attributes are"
      run :=
        let plain : Face := {}
        let red : Face := { foreground := some (Color.rgb 200 0 0) }
        pure
          (plain.family.isNone && plain.size.isNone && plain.weight.isNone && plain.slant.isNone &&
            plain.foreground.isNone &&
            plain.background.isNone &&
            plain.underline.isNone &&
            plain.strikeThrough.isNone &&
            plain.lineHeight.isNone &&
            red != plain &&
            red == { foreground := some (Color.rgb 200 0 0) }) }]

/-- The faces the code on this branch draws, read from the values that draw
them, not from their text: the cursors and status fields the shipped Vim
scheme reports in each of its states, its cursor face of each default
state, the cursor of a scheme that names no face, and the status fields the
loop gives a modified buffer and a prompt with candidates listed, one of
them chosen, and the faces of a status row and of a divider. -/
def drawnFaces : Array FaceName :=
  let scheme := Vim.Default.scheme
  let fed (text : String) : Vim.State := (scheme.feed (fun _ => []) ⟨0⟩ scheme.init (keys text)).1
  let told : Vim.State := scheme.openMinibuffer ⟨0⟩ scheme.init
  let reports := #[scheme.init, fed "i", fed "v", fed "V", told].map (scheme.report · ⟨0⟩)
  let states := Vim.Default.states.initial :: Vim.Default.states.others
  let context : ModeLine.Context :=
    { loopContext with
      reported := (reports[0]?.map (·.status)).getD #[], cursor := some ⟨4, 2⟩, lines := 10 }
  let asked : Prompt :=
    { label := "Theme: ", view := ⟨1⟩, asker := ⟨0⟩, continuation := { command := "load-theme" }
      candidates :=
        { all := #["a", "b"], listedFor := some "", listed := #["a", "b"], chosen := some 0 } }
  reports.map (·.cursor.face) ++ reports.flatMap (·.status.map (·.face)) ++
    states.toArray.map (Vim.cursorFace ·.name) ++
    #[({} : InputScheme.Report).cursor.face] ++
    (ModeLine.standard.fields context).map (·.face) ++
    (ModeLine.standard.fields { context with selected := false }).map (·.face) ++
    (Loop.promptStatus asked).map (·.face) ++
    #[ModeLine.activeFace, ModeLine.inactiveFace, Loop.dividerFace]

/-- The checks of the face vocabulary (`Editor/Face/Vocabulary.lean`), of a
theme written from a palette (`Palette.theme`, `Editor/Face.lean`) and of
the completeness check (`Themes.problems`, `Editor/Themes/Check.lean`), on
themes and palettes written here. -/
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
        "the vocabulary lists every face the shipped Vim scheme, the mode line, the loop and a scheme that names no cursor face draw, and the mode line's, the three minibuffer faces, the selected window's row and the divider among them"
      run :=
        pure
          (drawnFaces.all Face.vocabularyNames.contains &&
            [ModeLine.bufferFace, ModeLine.modifiedFace, ModeLine.secondaryFace,
                  ModeLine.inactiveFace, ModeLine.activeFace, Loop.promptFace, Loop.candidateFace,
                  Loop.chosenFace, Loop.dividerFace].all
              drawnFaces.contains) },
    { name :=
        "the vocabulary holds the badge face of every state of the shipped Vim scheme, read from the scheme, and no status. face"
      run :=
        let states := Vim.Default.states.initial :: Vim.Default.states.others
        pure
          (states.all (fun state => Face.vocabularyNames.contains (Vim.stateFace state.name)) &&
            states.length == Theme.cursorStates.size &&
            ["status.state", "status.name", "status.modified"].all fun name =>
              !Face.vocabularyNames.contains ⟨name⟩) },
    { name :=
        "every shipped theme pads the mode line and the echo area 3 points above and below, and its default face sets no padding"
      run :=
        let padded (theme : Theme) :=
          (theme.merged ⟨"mode-line"⟩).verticalPadding == some 3 &&
            (theme.merged ⟨"echo-area"⟩).verticalPadding == some 3 &&
            (theme.merged ⟨"default"⟩).verticalPadding == some 0
        pure (padded Theme.builtin && Themes.shipped.all (padded ·.theme)) },
    { name :=
        "the vocabulary lists the tab bar's faces, the chips' and the selected chip's, and every shipped theme defines them"
      run :=
        pure
          ([TabBar.face, TabBar.selectedFace].all Face.vocabularyNames.contains &&
            TabBar.face != TabBar.selectedFace &&
            Themes.shipped.all fun shipped =>
              [TabBar.face, TabBar.selectedFace].all fun name =>
                shipped.theme.any (·.name == name)) },
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
        "the cursor faces the check holds are cursor and the shipped Vim scheme's face of each of its states"
      run :=
        let states := Vim.Default.states.initial :: Vim.Default.states.others
        pure (Themes.cursorFaces == #[⟨"cursor"⟩] ++ states.toArray.map (Vim.cursorFace ·.name)) },
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
        "a theme that leaves the cursor face of a shipped Vim state undefined has no such cursor, for each of them"
      run :=
        pure
          (Themes.cursorFaces.all fun face =>
            (Themes.problems (Theme.builtin.filter (·.name != face))).contains (.noCursor face)) },
    { name :=
        "a cursor whose foreground is its own background has that problem and no other, set so or with no foreground set over a background that is the ink, for each shipped cursor face"
      run :=
        let theme := Theme.builtin
        let paper := (theme.merged ⟨"default"⟩).background
        let ink := (theme.merged ⟨"default"⟩).foreground
        let odd := Color.rgb 1 2 3
        pure
          (some odd != paper && ink != paper &&
            Themes.cursorFaces.all fun face =>
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
        "a cursor whose background is the paper has that problem: set so, with no background set, and when a later default moves the paper to the cursors' background, for each shipped cursor face"
      run :=
        let theme := Theme.builtin
        let paper := (theme.merged ⟨"default"⟩).background
        let odd := Color.rgb 1 2 3
        let cursors := (Themes.effective theme ⟨"cursor"⟩).2
        let moved := theme.push { name := ⟨"default"⟩, face := { background := cursors } }
        pure
          (some odd != paper && cursors.isSome &&
            Themes.cursorFaces.all fun face =>
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
    { name := "every shipped theme has no problem the check finds"
      run :=
        pure (!Themes.shipped.isEmpty && Themes.shipped.all (Themes.problems ·.theme == #[])) }]

/-- The badge faces of the shipped Vim scheme's states, each bold in every
shipped theme. -/
def badgeFaces : List String :=
  Theme.cursorStates.toList.map (s!"mode-line.state.{·}")

/-- The faces whose colours the Solarized module's table of choices records
(`Editor/Themes/Solarized.lean`), in dark names: each face's foreground and
background as the table gives them, read from `c`, so that the same list
read from the light colours is the light theme's. -/
def solarizedChoices (c : Themes.Solarized.Colours) : List (String × Option Color × Option Color) :=
  let cursors :=
    ["cursor", "cursor.normal", "cursor.insert", "cursor.visual", "cursor.visual-line",
      "cursor.minibuffer"]
  [("default", some c.base0, some c.base03), ("selection", none, some c.base02)] ++
    cursors.map (·, some c.base03, some c.base0) ++
    [("mode-line", some c.base1, some c.base02), ("mode-line.active", some c.base1, some c.base02),
      ("mode-line.inactive", some c.base0, some c.base03), ("window-divider", some c.base01, none),
      ("echo-area", some c.base0, none), ("mode-line.state.normal", some c.base03, some c.blue),
      ("mode-line.state.insert", some c.base03, some c.green),
      ("mode-line.state.visual", some c.base03, some c.magenta),
      ("mode-line.state.visual-line", some c.base03, some c.magenta),
      ("mode-line.state.minibuffer", some c.base03, some c.cyan),
      ("mode-line.buffer", some c.base1, none), ("mode-line.modified", some c.orange, none),
      ("mode-line.secondary", some c.base01, none), ("minibuffer.prompt", some c.blue, none),
      ("minibuffer.candidate", some c.base1, none),
      ("minibuffer.chosen", some c.base02, some c.base2), ("syntax.attribute", some c.orange, none),
      ("syntax.comment", some c.base01, none), ("syntax.constant", some c.cyan, none),
      ("syntax.constructor", some c.yellow, none), ("syntax.embedded", some c.base0, none),
      ("syntax.function", some c.blue, none), ("syntax.keyword", some c.green, none),
      ("syntax.module", some c.orange, none), ("syntax.number", some c.cyan, none),
      ("syntax.operator", some c.green, none), ("syntax.property", some c.blue, none),
      ("syntax.punctuation", some c.red, none), ("syntax.string", some c.cyan, none),
      ("syntax.tag", some c.red, none), ("syntax.type", some c.yellow, none),
      ("syntax.variable", some c.blue, none), ("diff.added", some c.green, some c.base02),
      ("diff.removed", some c.red, some c.base02), ("diff.changed", some c.yellow, some c.base02),
      ("gutter", some c.base01, some c.base02), ("search-match", some c.base03, some c.yellow),
      ("review-unexamined", none, none), ("block-header", some c.base1, some c.base02),
      ("compilation.error", some c.red, none), ("compilation.warning", some c.orange, none),
      ("compilation.note", some c.green, none)]

/-- Whether `theme` gives each face of `solarizedChoices c` the colours
listed, and keeps the weight, slant and underline the table keeps. -/
def solarizedChosen (theme : Theme) (c : Themes.Solarized.Colours) : Bool :=
  let face (name : String) : Face := theme.merged ⟨name⟩
  (solarizedChoices c).all
      (fun (name, foreground, background) =>
        (face name).foreground == foreground && (face name).background == background) &&
    (badgeFaces ++
          ["mode-line.buffer", "minibuffer.prompt", "block-header", "compilation.error",
            "compilation.warning", "compilation.note"]).all
      (fun name => (face name).weight == some 700) &&
    (face "syntax.comment").slant == some .italic &&
    (face "review-unexamined").underline == some { style := .single, color := some c.orange }

/-- The checks of the Solarized themes (`Editor/Themes/Solarized.lean`):
the sixteen colours are Solarized's published values, the light colours
swap the four base pairs, each variant's faces are the choices the module's
table records, and both variants are shipped. That they pass the
completeness check is `faceVocabularyChecks`'s last check, over every
shipped theme. -/
def solarizedChecks : List Check :=
  let c := Themes.Solarized.published
  [{  name := "each of Solarized's sixteen colours is its published value"
      run :=
        pure
          ([c.base03, c.base02, c.base01, c.base00, c.base0, c.base1, c.base2, c.base3, c.yellow,
                  c.orange, c.red, c.magenta, c.violet, c.blue, c.cyan, c.green].map
              (·.word) ==
            [0x002b36ff, 0x073642ff, 0x586e75ff, 0x657b83ff, 0x839496ff, 0x93a1a1ff, 0xeee8d5ff,
              0xfdf6e3ff, 0xb58900ff, 0xcb4b16ff, 0xdc322fff, 0xd33682ff, 0x6c71c4ff, 0x268bd2ff,
              0x2aa198ff, 0x859900ff]) },
    { name := "light swaps the four base pairs and keeps the accents"
      run :=
        let l := c.light
        pure
          (l.base03 == c.base3 && l.base3 == c.base03 && l.base02 == c.base2 &&
            l.base2 == c.base02 &&
            l.base01 == c.base1 &&
            l.base1 == c.base01 &&
            l.base00 == c.base0 &&
            l.base0 == c.base00 &&
            [l.yellow, l.orange, l.red, l.magenta, l.violet, l.blue, l.cyan, l.green] ==
              [c.yellow, c.orange, c.red, c.magenta, c.violet, c.blue, c.cyan, c.green] &&
            l.light == c &&
            l != c) },
    { name := "each variant's faces are the choices recorded in the module's table"
      run :=
        pure
          (solarizedChosen Themes.Solarized.dark.theme c &&
            solarizedChosen Themes.Solarized.light.theme c.light) },
    { name := "each variant's default is the specification's pair: base0 on base03, base00 on base3"
      run :=
        let dark := Themes.Solarized.dark.theme.merged ⟨"default"⟩
        let light := Themes.Solarized.light.theme.merged ⟨"default"⟩
        pure
          (dark.background == some c.base03 && dark.foreground == some c.base0 &&
            light.background == some c.base3 &&
            light.foreground == some c.base00) },
    { name := "the two variants define the same names in the same order, and are not the same theme"
      run :=
        let dark := Themes.Solarized.dark.theme
        let light := Themes.Solarized.light.theme
        pure (dark.map (·.name) == light.map (·.name) && dark != light) },
    { name := "solarized-dark and solarized-light are shipped"
      run :=
        pure
          ([Themes.Solarized.dark, Themes.Solarized.light].all Themes.shipped.contains &&
            Themes.Solarized.dark.name == "solarized-dark" &&
            Themes.Solarized.light.name == "solarized-light") }]

/-- The faces whose colours the Fairy Floss module's table of choices
records (`Editor/Themes/FairyFloss.lean`): each face's foreground and
background as the table gives them, read from `c`. -/
def fairyFlossChoices (c : Themes.FairyFloss.Colours) :
    List (String × Option Color × Option Color) :=
  let cursors :=
    ["cursor", "cursor.normal", "cursor.insert", "cursor.visual", "cursor.visual-line",
      "cursor.minibuffer"]
  [("default", some c.foreground, some c.background), ("selection", none, some c.selection)] ++
    cursors.map (·, some c.background, some c.caret) ++
    [("mode-line", some c.foreground, some c.lineHighlight),
      ("mode-line.active", some c.foreground, some c.selection),
      ("mode-line.inactive", some c.lavender, some c.background),
      ("window-divider", some c.lavender, none), ("echo-area", some c.foreground, none),
      ("mode-line.state.normal", some c.background, some c.pink),
      ("mode-line.state.insert", some c.background, some c.added),
      ("mode-line.state.visual", some c.background, some c.lavender),
      ("mode-line.state.visual-line", some c.background, some c.lavender),
      ("mode-line.state.minibuffer", some c.background, some c.mint),
      ("mode-line.buffer", some c.foreground, none), ("mode-line.modified", some c.peach, none),
      ("mode-line.secondary", some c.lavender, none), ("minibuffer.prompt", some c.mint, none),
      ("minibuffer.candidate", some c.lavender, none),
      ("minibuffer.chosen", some c.background, some c.mint),
      ("syntax.attribute", some c.lemon, none), ("syntax.comment", some c.gold, none),
      ("syntax.constant", some c.lavender, none), ("syntax.constructor", some c.lemon, none),
      ("syntax.embedded", some c.foreground, none), ("syntax.function", some c.lemon, none),
      ("syntax.keyword", some c.pink, none), ("syntax.module", some c.lemon, none),
      ("syntax.number", some c.lavender, none), ("syntax.operator", some c.pink, none),
      ("syntax.property", some c.foreground, none), ("syntax.punctuation", some c.foreground, none),
      ("syntax.string", some c.yellow, none), ("syntax.tag", some c.pink, none),
      ("syntax.type", some c.mint, none), ("syntax.variable", some c.foreground, none),
      ("diff.added", some c.added, none), ("diff.removed", some c.removed, none),
      ("diff.changed", some c.modified, none), ("gutter", some c.foreground, some c.background),
      ("search-match", some c.background, some c.lemon), ("review-unexamined", none, none),
      ("block-header", some c.foreground, some c.lineHighlight),
      ("compilation.error", some c.removed, none), ("compilation.warning", some c.peach, none),
      ("compilation.note", some c.added, none)]

/-- Whether `theme` gives each face of `fairyFlossChoices c` the colours
listed, and the weight, slant and underline the table records. -/
def fairyFlossChosen (theme : Theme) (c : Themes.FairyFloss.Colours) : Bool :=
  let face (name : String) : Face := theme.merged ⟨name⟩
  (fairyFlossChoices c).all
      (fun (name, foreground, background) =>
        (face name).foreground == foreground && (face name).background == background) &&
    (badgeFaces ++
          ["mode-line.buffer", "minibuffer.prompt", "block-header", "compilation.error",
            "compilation.warning", "compilation.note"]).all
      (fun name => (face name).weight == some 700) &&
    (face "syntax.comment").slant == some .upright &&
    (face "syntax.type").slant == some .italic &&
    (face "review-unexamined").underline == some { style := .single, color := some c.peach }

/-- The checks of the Fairy Floss theme (`Editor/Themes/FairyFloss.lean`):
the nineteen colours are sailorhg's published values, the source's commit
is recorded, the faces are the choices the module's table records, and the
theme is shipped. That it passes the completeness check is
`faceVocabularyChecks`'s last check, over every shipped theme. -/
def fairyFlossChecks : List Check :=
  let c := Themes.FairyFloss.published
  [{  name := "each of Fairy Floss's nineteen colours is its published value"
      run :=
        pure
          ([c.background, c.foreground, c.caret, c.invisibles, c.lineHighlight, c.selection, c.gold,
                  c.yellow, c.lavender, c.pink, c.mint, c.lemon, c.peach, c.invalid, c.deprecated,
                  c.renamed, c.added, c.modified, c.removed].map
              (·.word) ==
            [0x5a5475ff, 0xf8f8f2ff, 0xf8f8f0ff, 0x3b3a32ff, 0x3e3d32ff, 0x49483eff, 0xe6c000ff,
              0xffea00ff, 0xc5a3ffff, 0xffb8d1ff, 0xc2ffdfff, 0xfff352ff, 0xff857fff, 0xf92672ff,
              0xae81ffff, 0x96cbfeff, 0xa8ff60ff, 0xe9c062ff, 0xcc6666ff]) },
    { name := "the source's commit is recorded"
      run := pure (Themes.FairyFloss.commit == "982e64a9e36160350125c0a82a7981dca6200150") },
    { name := "the faces are the choices recorded in the module's table"
      run := pure (fairyFlossChosen Themes.FairyFloss.fairyFloss.theme c) },
    { name := "the default is foreground on background"
      run :=
        let face := Themes.FairyFloss.fairyFloss.theme.merged ⟨"default"⟩
        pure (face.foreground == some c.foreground && face.background == some c.background) },
    { name := "fairy-floss is shipped"
      run :=
        pure
          (Themes.shipped.contains Themes.FairyFloss.fairyFloss &&
            Themes.FairyFloss.fairyFloss.name == "fairy-floss") }]

/-- A display model whose cells are one pixel each way, holding `texts` as
the snapshots 0, 1, 2 and so on, with nothing published. -/
def displayOver (texts : List String) (cells : Display.Cells := { advance := 1, lineHeight := 1 }) :
    DisplayModel :=
  { cells, texts := (texts.toArray.mapIdx fun index text => (⟨index⟩, text)) }

/-- A display program's answer, or the refusal it failed with on the left, as
a value with equality. -/
def answered {α : Type} : Except DisplayError α → DisplayError ⊕ α
  | .ok answer => .inr answer
  | .error refusal => .inl refusal

/-- The rows the display model over `texts` answers to `query`. -/
def shownBy (texts : List String) (query : Display.RowsQuery)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) :
    DisplayError ⊕ Array Display.Row :=
  answered ((Display.rowsShown query).runModel (displayOver texts cells)).1

/-- Lines of 6, 2, 10 and 3 characters. Four characters wide, the first takes
two rows and the third three: rows 0 to 6 start at 0, 4, 7, 10, 14, 18 and
21. -/
def wrapping : String :=
  "abcdef\nab\nabcdefghij\nxyz"

/-- Where the display model over `texts` moves `position` of the first of
them, in a view `width` pixels wide, by `lines` rows aiming for `goal`. -/
def movedBy (texts : List String) (width position : Nat) (lines : Int) (goal : Option Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : DisplayError ⊕ Display.Moved :=
  answered
    ((Display.linesFrom { snapshot := ⟨0⟩, width, position, lines, goal }).runModel
        (displayOver texts cells)).1

/-- The checks of the display model that only it shows: what it recorded of
the scenes published to it. What it answers to the queries is the display
interface's contract (`displayFailures`). -/
def displayChecks : List Check :=
  [{
      name :=
        "the scenes published to the display model read back equal, in the order they were published",
      run := do
        let first := twoViews
        let second :=
          { twoViews with
            pending := "", echo := "" }
        let third :=
          { twoViews with
            views := #[], focused := none }
        let program : DisplayM Unit := do
          Display.publish first
          Display.publish second
          Display.publish third
        let (result, model) := program.runModel (displayOver [])
        return result matches .ok () && model.scenes == #[first, second, third] },
    { name := "a display model that nothing was published to has no scene"
      run := pure ((displayOver ["a"]).scenes == #[]) },
    { name :=
        "the layout rule in cells of 8 by 16: a width is cut down to whole cells, a height to whole rows, and a carriage return before a line feed is part of the break"
      run :=
        pure
          (shownBy ["abcdef\r\nxy"] { snapshot := ⟨0⟩, width := 39, height := 47, anchor := 0 }
                (cells := { advance := 8, lineHeight := 16 }) ==
              .inr #[⟨0, 4⟩, ⟨4, 6⟩] &&
            shownBy ["abcdef\r\nxy"] { snapshot := ⟨0⟩, width := 39, height := 48, anchor := 0 }
                (cells := { advance := 8, lineHeight := 16 }) ==
              .inr #[⟨0, 4⟩, ⟨4, 6⟩, ⟨8, 10⟩]) },
    { name := "a view narrower than a cell still shows one character a row"
      run :=
        pure
          (shownBy ["abc"] { snapshot := ⟨0⟩, width := 3, height := 32, anchor := 0 } (cells :=
              { advance := 8, lineHeight := 16 }) ==
            .inr #[⟨0, 1⟩, ⟨1, 2⟩]) },
    { name := "a carriage return that is not before a line feed is a character of its own"
      run :=
        pure
          (shownBy ["a\rb"] { snapshot := ⟨0⟩, width := 2, height := 2, anchor := 0 } ==
            .inr #[⟨0, 2⟩, ⟨2, 3⟩]) },
    { name :=
        "across a shorter line the position stops at its end, and the goal passed back brings it to the start's column again"
      run :=
        pure
          (movedBy [wrapping] 4 3 2 none == .inr ⟨9, 3⟩ &&
            movedBy [wrapping] 4 9 (-2) (some 3) == .inr ⟨3, 3⟩ &&
            movedBy [wrapping] 4 9 (-2) none == .inr ⟨2, 2⟩) },
    { name :=
        "a row a line wraps after holds no end-of-line position: aiming past it lands on its last character"
      run := pure (movedBy [wrapping] 4 9 1 (some 6) == .inr ⟨13, 6⟩) },
    { name := "the goal is in pixels: a column times the cells' advance"
      run :=
        pure
          (movedBy [wrapping] 32 3 2 none (cells := { advance := 8, lineHeight := 16 }) ==
            .inr ⟨9, 24⟩) },
    { name :=
        "a wide character is two cells: the position after 世 is two cells in, and a move that aims for either of its cells lands on it; 😀 is one cell"
      run :=
        pure
          (movedBy ["世b"] 10 3 0 none == .inr ⟨3, 2⟩ &&
            movedBy ["世b"] 10 3 0 (some 0) == .inr ⟨0, 0⟩ &&
            movedBy ["世b"] 10 3 0 (some 1) == .inr ⟨0, 1⟩ &&
            movedBy ["世b"] 10 0 0 (some 2) == .inr ⟨3, 2⟩ &&
            movedBy ["😀b"] 10 4 0 none == .inr ⟨4, 1⟩) },
    { name :=
        "a tab stops at a multiple of eight cells from its line's start, also after a wide character and on a later line"
      run :=
        pure
          (movedBy ["世\tb"] 20 4 0 none == .inr ⟨4, 8⟩ &&
            movedBy ["xyz\nabcdefghi\tb"] 20 14 0 none == .inr ⟨14, 16⟩ &&
            movedBy ["a\tb"] 160 2 0 none (cells := { advance := 8, lineHeight := 16 }) ==
              .inr ⟨2, 64⟩) },
    { name :=
        "a character is of the row its first cell is in, also when its second cell is past the width"
      run :=
        pure
          (shownBy ["ab世cd"] { snapshot := ⟨0⟩, width := 4, height := 3, anchor := 0 } ==
              .inr #[⟨0, 5⟩, ⟨5, 7⟩] &&
            shownBy ["abc世d"] { snapshot := ⟨0⟩, width := 4, height := 3, anchor := 0 } ==
              .inr #[⟨0, 6⟩, ⟨6, 7⟩]) }]

/-- Whether every live text of `model` is in step (`TextModel.InStep`) at
the revision it is at. -/
def allInStep (model : TextModel) : Bool :=
  (List.range model.texts.size).all fun index =>
    match model.texts[index]? with
    | some (some content) => decide (model.InStep ⟨index⟩ content.revision)
    | _ => true

/-- The check of the premise the theorems about undo take of the text model
(`TextModel.InStep`), for the requests no lemma covers. -/
def textModelStepChecks : List Check :=
  [{  name :=
        "every live text of the text model is in step after each request of a sequence, each of which is accepted: a text made, an insertion, a deletion, a transaction with selections, an applied inverse, a drop of inverses, a forgotten revision, a marker, a copy, and the release of another text; and a model whose log is short a revision is not in step"
      run :=
        pure <|
          let text : TextId := ⟨0⟩
          let steps : List (TextM Unit) :=
            [discard <| createText "héllo", text.insert 6 " wörld", text.delete 0 1,
              discard <|
                text.apply
                  { Transaction.replacing 12 0 0 "X" with
                    before := some { ranges := #[⟨0, 0⟩] }, after := some { ranges := #[⟨1, 1⟩] } }
                  Origin.user,
              discard <| text.applyInverse 3 3 Origin.user, text.dropInverses 1 2, text.forget 1,
              discard <| text.mark (.anchor { offset := 0, bias := .before }), discard <| text.copy,
              discard <| createText "other", (⟨2⟩ : TextId).release]
          let (held, model) :=
            steps.foldl
              (fun (held, model) step =>
                let (result, model) := step.runModel model
                (held && result.isOk && allInStep model, model))
              (true, ({} : TextModel))
          held && model.texts.size == 3 &&
            !allInStep { model with logs := model.logs.map fun log => { log with past := #[] } } }]

/-- The checks of the undo tree's pure operations alone, which ask nothing of
a text: being told a revision, and the boundary. What the tree does to a
text is in `UndoTreeCases.cases`, run against the text model below. -/
def undoTreeChecks : List Check :=
  [{
      name :=
        "an undo tree told a revision has it in its open group, and told one that is not after the last it knew it is unchanged",
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let told := tree.record 5
        return !tree.pending && told.pending && told.head == 5 && told.base == 3 &&
            told.record 5 == told &&
            told.record 4 == told &&
            tree.record 3 == tree &&
            tree.record 0 == tree },
    { name :=
        "a boundary with nothing pending makes no node, and with something pending makes one whose parent is where the text was"
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let closed := (tree.record 5).close
        let made : UndoTree.NodeId := ⟨1⟩
        return tree.close == tree && closed.nodes.size == 2 && closed.current == made &&
            !closed.pending &&
            closed.node? made ==
              some { parent := some UndoTree.root, cross := some ⟨4, 5⟩, state := ⟨5⟩ } &&
            closed.node? UndoTree.root ==
              some { parent := none, children := #[made], next := some made, state := ⟨3⟩ } &&
            closed.close == closed },
    { name :=
        "an undo tree nobody edited is saved where it is; told an edit it is modified; marked saved it is not, there or at a state named to it; and the state it is in is named by the revision that put it there: the one the tree was made at, or the one it was told"
      run := do
        let tree := UndoTree.new ⟨0⟩ 3
        let told := tree.record 5
        let elsewhere : UndoTree.State := ⟨4⟩
        return !tree.isModified && tree.state == ⟨3⟩ && told.isModified && told.state == ⟨5⟩ &&
            !told.markSaved.isModified &&
            !(told.markSaved told.state).isModified &&
            (tree.markSaved told.state).isModified &&
            (told.markSaved elsewhere).isModified &&
            (told.markSaved.record 6).isModified &&
            !(tree.markSaved.markSaved).isModified },
    { name :=
        "a boundary does not change whether an undo tree is modified: saved where the text is, the saved state is the state of the new node; saved anywhere else, it stays, and is no node's"
      run := do
        let told := (UndoTree.new ⟨0⟩ 3).record 5
        let closed := told.markSaved.close
        let behind := told.markSaved.record 6
        return told.isModified && told.close.isModified && !told.markSaved.isModified &&
            !closed.isModified &&
            closed.saved == some told.state &&
            (closed.node? closed.current).map (·.state) == some told.state &&
            behind.isModified &&
            behind.close.isModified &&
            behind.close.saved == some told.state &&
            behind.close.nodes.all (·.state != told.state) },
    { name :=
        "a state has one name, whether or not a boundary has been set since it was taken: the state taken at the end of an open group is the state of the node a boundary makes of it, so a tree marked saved at it after the boundary is unmodified, and one that was told a further edit before the boundary is not"
      run := do
        let told := (UndoTree.new ⟨0⟩ 3).record 5
        let taken := told.state
        let closed := told.close
        let further := (told.record 6).close
        return closed.state == taken && !(closed.markSaved taken).isModified &&
            further.state != taken &&
            (further.markSaved taken).isModified }]

/-- The escape of `byte`: the character the text model keeps a byte that is
not valid UTF-8 as. It is four bytes of text. -/
def escapeOf (byte : Nat) : Char :=
  Char.ofNat (0x10DC00 + byte)

/-- The escapes of `bytes`, in order. -/
def escapesOf (bytes : List Nat) : String :=
  bytes.foldl (fun text byte => text.push (escapeOf byte)) ""

/-- Byte strings and the text the library keeps each as, written out by
hand: what `FileModel.decode` must make of the bytes, and what
`FileModel.encode` must make the bytes of again. -/
def decodings : List (String × ByteArray × String) :=
  [("Latin-1", ⟨#[0x63, 0x61, 0x66, 0xE9]⟩, "caf".push (escapeOf 0xE9)),
    ("bytes that are never valid", ⟨#[0x61, 0xFF, 0x62, 0xFE]⟩,
      (("a".push (escapeOf 0xFF)).push 'b').push (escapeOf 0xFE)),
    ("a sequence cut short at the end", ⟨#[0x61, 0xE2, 0x82]⟩, "a" ++ escapesOf [0xE2, 0x82]),
    ("a sequence cut short in the middle", ⟨#[0xF0, 0x9F, 0x98, 0x78]⟩,
      (escapesOf [0xF0, 0x9F, 0x98]).push 'x'),
    ("two overlong forms", ⟨#[0xC0, 0xAF, 0xE0, 0x80, 0xAF]⟩,
      escapesOf [0xC0, 0xAF, 0xE0, 0x80, 0xAF]),
    ("an encoded surrogate", ⟨#[0xED, 0xA0, 0x80]⟩, escapesOf [0xED, 0xA0, 0x80]),
    ("a continuation byte alone", ⟨#[0x61, 0x80, 0x62]⟩, ("a".push (escapeOf 0x80)).push 'b'),
    ("the lowest reserved code point, validly encoded", ⟨#[0xF4, 0x8D, 0xB2, 0x80]⟩,
      escapesOf [0xF4, 0x8D, 0xB2, 0x80]),
    ("the highest reserved code point, validly encoded", ⟨#[0xF4, 0x8D, 0xB3, 0xBF]⟩,
      escapesOf [0xF4, 0x8D, 0xB3, 0xBF]),
    ("the code points on either side of the reserved range",
      ⟨#[0xF4, 0x8D, 0xB1, 0xBF, 0xF4, 0x8D, 0xB4, 0x80]⟩,
      ("".push (Char.ofNat 0x10DC7F)).push (Char.ofNat 0x10DD00)),
    ("a code point above the maximum", ⟨#[0xF4, 0x90, 0x80, 0x80]⟩,
      escapesOf [0xF4, 0x90, 0x80, 0x80]),
    ("a lead byte F5", ⟨#[0xF5, 0x80, 0x80, 0x80]⟩, escapesOf [0xF5, 0x80, 0x80, 0x80]),
    ("two- and four-byte characters with a carriage return and a line feed",
      ⟨#[0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0x0D, 0x0A]⟩, "é😀\r\n")]

/-- Whether `reply` is the refusal `error`. -/
def refusedAs {α : Type} (reply : Except FileError α) (error : FileError) : Bool :=
  match reply with
  | .error refusal => refusal == error
  | .ok _ => false

/-- The directory the model's files are in, in the checks below. -/
def modelRoot : System.FilePath :=
  "/model"

/-- A file's bytes: "h", a carriage return and a line feed, "😀", two bytes
that are not UTF-8 and a line feed alone. Ten bytes. -/
def mixedBytes : ByteArray :=
  ⟨#[0x68, 0x0D, 0x0A, 0xF0, 0x9F, 0x98, 0x80, 0xE9, 0xFF, 0x0A]⟩

/-- The text `mixedBytes` loads as, written out by hand. Sixteen bytes. -/
def mixedText : String :=
  ("h\r\n😀" ++ escapesOf [0xE9, 0xFF]).push '\n'

/-- A file of `size` bytes, each "a" but for a NUL byte at `nul`. -/
def withNul (size nul : Nat) : ByteArray :=
  ⟨(Array.replicate size (0x61 : UInt8)).setIfInBounds nul 0⟩

/-- A model with the directory `modelRoot` and, in it, `mixed.txt` holding
`mixedBytes`. The editor has published two snapshots, the second released;
the first holds a text that the job's first load will not. -/
def modelWithFile : FileModel :=
  let model :=
    (({} : FileModel).withDirectory modelRoot).withFile (modelRoot / "mixed.txt") mixedBytes
  { model with
    snapshots := #[some { contents := "pub é".push (escapeOf 0xFF), revision := 4 }, none] }

/-- The checks of the pure model of the files a job reaches
(`Editor/File/Model.lean`) and of the file data (`Editor/File.lean`). They
touch no file. -/
def fileModelChecks : List Check :=
  [{  name :=
        "the file model's stamp of a file is the stamp it was written with, and a write changes it; of nothing it is none"
      run :=
        let (before, model) := modelWithFile.handle (.stamp (modelRoot / "mixed.txt"))
        let (written, _) := model.written (modelRoot / "mixed.txt") mixedBytes
        let (after, _) :=
          (model.withFile (modelRoot / "mixed.txt") mixedBytes).handle
            (.stamp (modelRoot / "mixed.txt"))
        let (nothing, _) := modelWithFile.handle (.stamp (modelRoot / "missing.txt"))
        let stampOf : Except FileError (Option File.Stamp) → Option (Option File.Stamp)
          | .ok stamp => some stamp
          | .error _ => none
        pure
          (stampOf before == some ((modelWithFile.file? (modelRoot / "mixed.txt")).map (·.stamp)) &&
            stampOf after == some (some written) &&
            stampOf before != stampOf after &&
            stampOf nothing == some none) },
    {
      name :=
        "the store's escape rule decodes bytes to the text the library keeps them as, and encodes that text to the bytes again, and the file model uses it: thirteen byte strings, each against a text written out by hand",
      run :=
        pure
          (decodings.all fun (_, bytes, text) =>
            File.decodeBytes bytes == text && File.encodeText text == bytes &&
              FileModel.decode bytes == text &&
              FileModel.encode text == bytes) },
    { name :=
        "the file model's load answers a snapshot under the next id, holding the file's text, with the file's length in bytes as the stamp's size and its line endings"
      run := do
        let (first, model) := modelWithFile.load (modelRoot / "mixed.txt") 10
        let (second, after) := model.load (modelRoot / "mixed.txt") 1000
        let .ok first := first | return false
        let .ok second := second | return false
        return first.snapshot == ⟨0⟩ && second.snapshot == ⟨1⟩ && first.stamp.size == 10 &&
            first.endings == ⟨1, 1⟩ &&
            second.stamp == first.stamp &&
            after.held ==
              #[some { contents := mixedText, revision := 0 },
                some { contents := mixedText, revision := 0 }] &&
            after.files == modelWithFile.files &&
            after.snapshots == modelWithFile.snapshots },
    { name :=
        "the file model counts line endings on the bytes: a line feed alone, one after a carriage return, both, and a carriage return alone as neither"
      run :=
        pure
          (FileModel.lineEndings "a\nb\n".toUTF8 == ⟨2, 0⟩ &&
            FileModel.lineEndings "a\r\nb\r\n".toUTF8 == ⟨0, 2⟩ &&
            FileModel.lineEndings "\na\r\nb\nc\rd\r".toUTF8 == ⟨2, 1⟩ &&
            FileModel.lineEndings "abc".toUTF8 == ⟨0, 0⟩ &&
            FileModel.lineEndings ByteArray.empty == ⟨0, 0⟩) },
    { name :=
        "the file model refuses a load in the library's order, and a refused load changes nothing: a path that is not absolute, nothing there, a directory, a file over the limit, and a NUL byte among the first 8,000 bytes"
      run := do
        let model :=
          ((modelWithFile.withFile (modelRoot / "early") (withNul 8001 7999)).withFile
                (modelRoot / "late") (withNul 8001 8000)).withFile
            (modelRoot / "both") (withNul 20 3)
        let refusals :=
          [(model.load "missing.txt" 1000, FileError.relativePath),
            (model.load (modelRoot / "missing.txt") 1000, .notFound),
            (model.load (modelRoot / "none" / "mixed.txt") 1000, .notFound),
            (model.load modelRoot 1000, .notAFile),
            (model.load (modelRoot / "mixed.txt") 9, .tooLarge 10 9),
            (model.load (modelRoot / "early") 9000, .binary 7999),
            -- Over the limit and binary: the limit is looked at first.
            (model.load (modelRoot / "both") 19, .tooLarge 20 19),
            (model.load (modelRoot / "both") 20, .binary 3)]
        let (late, _) := model.load (modelRoot / "late") 9000
        return refusals.all
              (fun ((reply, after), refusal) => refusedAs reply refusal && after == model) &&
            late.toOption.isSome },
    { name :=
        "the file model refuses a save in the library's order, and a refused save changes nothing: a source that names nothing, a path that is not absolute, a directory, a file that is not what is expected, and a directory that is not there"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let held := File.Source.held loaded.snapshot
        let stale : File.Stamp := { loaded.stamp with seconds := loaded.stamp.seconds + 1 }
        let refusals :=
          [(model.save (.held ⟨1⟩) "relative.txt" .whatever, FileError.noSuchSnapshot),
            (model.save (.snapshot ⟨1⟩) "relative.txt" .whatever, .noSuchSnapshot),
            (model.save (.snapshot ⟨2⟩) (modelRoot / "new.txt") .whatever, .noSuchSnapshot),
            (model.save held "relative.txt" .whatever, .relativePath),
            (model.save held modelRoot .whatever, .notAFile),
            (model.save held (modelRoot / "mixed.txt") .absent, .changed (some loaded.stamp)),
            (model.save held (modelRoot / "mixed.txt") (.unchanged stale),
              .changed (some loaded.stamp)),
            (model.save held (modelRoot / "new.txt") (.unchanged loaded.stamp), .changed none),
            -- The expectation is looked at before the directory.
            (model.save held (modelRoot / "none" / "new.txt") (.unchanged loaded.stamp),
              .changed none),
            (model.save held (modelRoot / "none" / "new.txt") .absent, .notFound),
            (model.save held (modelRoot / "none" / "new.txt") .whatever, .notFound)]
        return refusals.all fun ((reply, after), refusal) =>
            refusedAs reply refusal && after == model },
    { name :=
        "the file model's save writes the file and answers its stamp, which the next save accepts and which every write changes: over the file that is expected, where no file is expected, and over whatever is there"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let held := File.Source.held loaded.snapshot
        let (over, model) := model.save held (modelRoot / "mixed.txt") (.unchanged loaded.stamp)
        let .ok over := over | return false
        let (again, model) := model.save held (modelRoot / "mixed.txt") (.unchanged over)
        let .ok again := again | return false
        let (stale, model) := model.save held (modelRoot / "mixed.txt") (.unchanged over)
        let (fresh, model) := model.save held (modelRoot / "new.txt") .absent
        let .ok fresh := fresh | return false
        let (whatever, model) := model.save held (modelRoot / "new.txt") .whatever
        let .ok whatever := whatever | return false
        return over != loaded.stamp && again != over && refusedAs stale (.changed (some again)) &&
            whatever != fresh &&
            [over, again, fresh, whatever].all (·.size == 10) &&
            model.contents ==
              #[(modelRoot / "mixed.txt", mixedBytes), (modelRoot / "new.txt", mixedBytes)] },
    { name :=
        "a save from what a load made and a save from what the editor published each write the bytes of that snapshot, though the two ids have one number, and neither changes what was published; a released snapshot of the job's is no source"
      run := do
        let (loaded, model) := modelWithFile.load (modelRoot / "mixed.txt") 1000
        let .ok loaded := loaded | return false
        let (held, model) := model.save (.held loaded.snapshot) (modelRoot / "held.txt") .absent
        let (published, model) := model.save (.snapshot ⟨0⟩) (modelRoot / "published.txt") .absent
        let (gone, after) :=
          (model.released loaded.snapshot).save (.held loaded.snapshot) (modelRoot / "gone.txt")
            .absent
        return loaded.snapshot.number == 0 && held.toOption.isSome && published.toOption.isSome &&
            (model.file? (modelRoot / "held.txt")).map (·.bytes) == some mixedBytes &&
            (model.file? (modelRoot / "published.txt")).map (·.bytes) ==
              some ⟨#[0x70, 0x75, 0x62, 0x20, 0xC3, 0xA9, 0xFF]⟩ &&
            model.snapshots == modelWithFile.snapshots &&
            refusedAs gone .noSuchSnapshot &&
            (after.file? (modelRoot / "gone.txt")).isNone &&
            ((after.load (modelRoot / "mixed.txt") 1000).1.toOption.map (·.snapshot)) == some ⟨1⟩ },
    { name :=
        "the dominant line ending is CRLF when there are more of those, LF otherwise when there is any line break, and none for a file with no line break"
      run :=
        pure
          ((File.LineEndings.mk 3 0).dominant == some .lf &&
            (File.LineEndings.mk 0 2).dominant == some .crlf &&
            (File.LineEndings.mk 2 3).dominant == some .crlf &&
            (File.LineEndings.mk 3 2).dominant == some .lf &&
            (File.LineEndings.mk 2 2).dominant == some .lf &&
            (File.LineEndings.mk 0 0).dominant == none) },
    { name :=
        "the text of a line ending is a line feed for LF, and a carriage return and a line feed for CRLF"
      run := pure (File.LineEnding.lf.text == "\n" && File.LineEnding.crlf.text == "\r\n") },
    { name :=
        "each file error describes its own thing: no two say the same, a binary file's says its offset, a file too large its size and its limit, a changed file whether one is there, and a failure its detail"
      run := do
        let errors : List FileError :=
          [.relativePath, .notFound, .notAFile, .denied, .binary 7999, .tooLarge 4321 1234,
            .changed none, .changed (some { seconds := 5, nanoseconds := 6, size := 8765 }),
            .noSuchSnapshot, .noTemporaryName, .failed "the disk is on fire"]
        let said := errors.map FileError.describe
        let says (error : FileError) (part : String) : Bool :=
          (error.describe.splitOn part).length > 1
        return said.eraseDups.length == errors.length && said.all (· != "") &&
            says (.binary 7999) "7999" &&
            says (.tooLarge 4321 1234) "4321" &&
            says (.tooLarge 4321 1234) "1234" &&
            says (.changed (some { seconds := 5, nanoseconds := 6, size := 8765 })) "8765" &&
            says (.failed "the disk is on fire") "the disk is on fire" &&
            says .relativePath "absolute" &&
            says .notFound "nothing" &&
            says .notAFile "not a file" &&
            says .noSuchSnapshot "snapshot" }]

/-- A command's result, or the refusal it failed with on the left, as a
value with equality. -/
def resulted {α : Type} : Except TextError α → TextError ⊕ α
  | .ok value => .inr value
  | .error refusal => .inl refusal

/-- A reply that may be refused, as a sum, which has an equality: the
refusal on the left. -/
def replied {ε α : Type} : Except ε α → ε ⊕ α
  | .ok value => .inr value
  | .error refusal => .inl refusal

/-- The checks of the editor's composite port (`Editor/Command.lean`): what
its model runner does with each sub-port's requests. -/
def commandPortChecks : List Check :=
  [{  name :=
        "a program over the syntax tree port, lifted to a command, is answered by the syntax tree model over the text model's snapshots, each request a pace; its refusal comes back as a value, and the command is not refused"
      run := do
        let program (snapshot : SnapshotId) : SyntaxTreeM (Array String × Nat) := do
          SyntaxTree.attach snapshot "json"
          let query ← SyntaxTree.compile "json" "(number) @number"
          let found ← SyntaxTree.captures snapshot query 0 3
          return (← SyntaxTree.captureNames query, found.size)
        let command :
          EditorM (Except SyntaxTreeError (Array String × Nat) × Except SyntaxTreeError Unit) := do
          let snapshot ← (← createText "[1]").snapshot
          let answered ← SyntaxTree.lift (program snapshot)
          let refused ← SyntaxTree.lift (SyntaxTree.attach snapshot "cobol")
          return (answered, refused)
        let (result, model) := command.runModel { editorModel with watch := { pace := 1 } }
        -- Two text requests, then five syntax tree requests, each a pace.
        return (match result with
            | .ok (answered, refused) =>
              replied answered == .inr (#["number"], 1) && replied refused == .inl .unknownGrammar
            | .error _ => false) &&
            model.watch.clock == 7 &&
            model.syntaxTree.attached.map (·.2) == #["json"] &&
            model.texts.contents == #["[1]"] },
    { name :=
        "a program over the text port, lifted to a command, gives the same result and the same texts on the editor's models as on the text model"
      run := do
        let program : TextM String := do
          let text ← createText "héllo"
          text.insert 6 " wörld"
          discard <| createText "other"
          text.read
        let (onText, texts) := program.runModel {}
        let (onEditor, model) := (TextM.lift program).runModel editorModel
        return resulted onText == resulted onEditor && texts.contents == model.texts.contents &&
            model.display.scenes == #[] },
    { name :=
        "inside a command, the rows a view shows of a snapshot just taken are answered from the text model's text"
      run := do
        let command : EditorM (Array Display.Row) := do
          let text ← createText "ab\ncdef"
          let snapshot ← text.snapshot
          text.insert 0 "xyz"
          Display.rowsShown { snapshot, width := 3, height := 10, anchor := 0 }
        return resulted (command.runModel editorModel).1 == .inr #[⟨0, 2⟩, ⟨3, 6⟩, ⟨6, 7⟩] },
    { name :=
        "a display refusal inside a command is the text port's refusal of the same name, and a text refusal is itself"
      run := do
        let unknown : EditorM (Array Display.Row) :=
          Display.rowsShown { snapshot := ⟨9⟩, width := 3, height := 10, anchor := 0 }
        let inside : EditorM (Array Display.Row) := do
          let snapshot ← (← createText "é").snapshot
          Display.rowsShown { snapshot, width := 3, height := 10, anchor := 1 }
        let moved : EditorM Display.Moved := do
          let snapshot ← (← createText "é").snapshot
          Display.linesFrom { snapshot, width := 3, position := 1, lines := 1, goal := none }
        let text : EditorM Unit := (⟨4⟩ : TextId).insert 0 "x"
        return resulted (unknown.runModel editorModel).1 == .inl .noSuchSnapshot &&
            resulted (inside.runModel editorModel).1 == .inl .badPosition &&
            resulted (moved.runModel editorModel).1 == .inl .badPosition &&
            resulted (text.runModel editorModel).1 == .inl .noSuchText },
    { name := "a scene published inside a command is recorded by the display model, in order"
      run := do
        let command : EditorM Unit := do
          Display.publish twoViews
          discard <| createText "between"
          Display.publish { twoViews with echo := "second" }
        let (result, model) := command.runModel editorModel
        return result matches .ok () &&
            model.display.scenes == #[twoViews, { twoViews with echo := "second" }] },
    { name :=
        "a watch request inside a command is answered by the watch model, and leaves the text model and the display model as they were"
      run := do
        let command : EditorM (Bool × Bool × Nat) := do
          let before ← Watch.interrupted
          Watch.lower
          return (before, ← Watch.interrupted, ← Watch.now)
        let watch : WatchModel := { arrived := 1, clock := 7 }
        let (result, model) := command.runModel { editorModel with watch }
        return resulted result == .inr (true, false, 7) &&
            model.watch == { watch with arrived := 0 } &&
            model.texts.contents == #[] &&
            model.display.scenes == #[] },
    { name :=
        "a program over the clipboard port, lifted to a command, gives the same replies on the editor's models as on the clipboard model and leaves the same clipboard, with the texts and the display as they were; a clipboard that is not available answers unavailable as a value, and the command is not refused"
      run := do
        let program :
          ClipboardM
            (Except ClipboardError (Option String) × Except ClipboardError (Option String)) :=
          do
          let before ← Clipboard.read
          discard <| Clipboard.write "copied"
          return (before, ← Clipboard.read)
        let (alone, clipboard) :=
          Program.run (port := clipboardPort) ClipboardModel.handle program {}
        let (onEditor, model) := (Clipboard.lift program).runModel editorModel
        let away : ClipboardModel := { held := some "kept", available := false }
        let (refused, after) :=
          (Clipboard.lift program).runModel { editorModel with clipboard := away }
        return (match onEditor with
            | .ok (before, written) =>
              replied before == replied alone.1 && replied written == replied alone.2 &&
                replied before == .inr none &&
                replied written == .inr (some "copied")
            | .error _ => false) &&
            model.clipboard == clipboard &&
            model.texts.contents == #[] &&
            model.display.scenes == #[] &&
            (match refused with
            | .ok (before, written) =>
              replied before == .inl .unavailable && replied written == .inl .unavailable
            | .error _ => false) &&
            after.clipboard == away },
    { name :=
        "a clipboard request inside a command moves the watch model's clock on by its pace, as a text request does: a read and then a write take two paces"
      run := do
        let command : EditorM (List Nat) := do
          let start ← Watch.now
          discard <| Clipboard.read
          let afterRead ← Watch.now
          discard <| Clipboard.write "copied"
          return [start, afterRead, ← Watch.now]
        let paced := (command.runModel { editorModel with watch := { clock := 100, pace := 10 } }).1
        return resulted paced == .inr [100, 110, 120] },
    { name :=
        "a fuzzy ranking asked inside a command is answered on the editor's models as the fuzzy model answers it, and moves the watch model's clock on by its pace, as a text request does"
      run := do
        let candidates := #["wq", "edit", "rewrite", "w"]
        let command : EditorM (Array Nat × List Nat) := do
          let start ← Watch.now
          let ranked ← Fuzzy.rank "w" candidates
          return (ranked, [start, ← Watch.now])
        let paced := (command.runModel { editorModel with watch := { clock := 100, pace := 10 } }).1
        return resulted paced == .inr (FuzzyModel.rank "w" candidates, [100, 110]) &&
            !(FuzzyModel.rank "w" candidates).isEmpty },
    { name :=
        "a state request of a command no loop runs is answered as an editor with no buffer and no window answers it, and nothing is kept: a read sees none, a buffer added is not there at the next read, and neither the watch model's clock nor the other models move"
      run := do
        let command :
          EditorM
            (EditorState ×
              Except BufferRefusal BufferId × EditorState × Except LayoutRefusal Unit) :=
          do
          let before ← editorState
          let added ← EditorState.ask (.addBuffer "new" ⟨0⟩ (UndoTree.new ⟨0⟩ 0))
          let after ← editorState
          return (before, added, after, ← EditorState.ask (.focus ⟨0⟩))
        let watch : WatchModel := { clock := 7, pace := 3 }
        let (result, model) := command.runModel { editorModel with watch }
        match result with
        | .ok (before, added, after, focused) =>
          return before == EditorState.none && before.buffers.isEmpty && before.windows.isEmpty &&
              replied added == .inr ⟨0⟩ &&
              after == EditorState.none &&
              replied focused == .inl (.noSuchWindow ⟨0⟩) &&
              model.watch == watch &&
              model.texts.contents == #[] &&
              model.display.scenes == #[]
        | .error _ =>
          return false }]

/-- The watch model after `program`, run from `model`, and what the program
returned. -/
def watched {α : Type} (program : WatchM α) (model : WatchModel := {}) : α × WatchModel :=
  Program.run (port := watchPort) WatchModel.handle program model

/-- The checks of the watch port's model (`Editor/Watch/Model.lean`): what
only the model has, an arrival a test places and a clock a command's
requests move. -/
def watchChecks : List Check :=
  [{  name :=
        "the watch model's interrupt key arrives when the flag is asked for the time after the count it was given, and once: asked four times with a count of two, the flag is down, down, up and up, with one arrived"
      run :=
        let asks : WatchM (List Bool) := do
          return [← Watch.interrupted, ← Watch.interrupted, ← Watch.interrupted,
              ← Watch.interrupted]
        let (answers, model) := watched asks { arrivesAfter := some 2 }
        let (never, _) := watched asks
        pure
          (answers == [false, false, true, true] && model.arrived == 1 &&
            model.arrivesAfter == none &&
            never == [false, false, false, false]) },
    { name := "the watch model's clock reads where it was set, and a watch request does not move it"
      run :=
        let reads : WatchM (List Nat) := do
          let first ← Watch.now
          discard Watch.interrupted
          Watch.lower
          return [first, ← Watch.now]
        pure ((watched reads { clock := 5, pace := 10 }).1 == [5, 5]) },
    { name :=
        "on the editor's models the clock moves on by the watch model's pace at each text request and each display request of a command, and at no watch request"
      run := do
        let command : EditorM (List Nat) := do
          let start ← Watch.now
          let text ← createText "ab"
          let afterText ← Watch.now
          Display.publish twoViews
          let afterDisplay ← Watch.now
          discard Watch.interrupted
          discard <| text.read
          return [start, afterText, afterDisplay, ← Watch.now]
        let paced := (command.runModel { editorModel with watch := { clock := 100, pace := 10 } }).1
        let still := (command.runModel editorModel).1
        return resulted paced == .inr [100, 110, 120, 130] && resulted still == .inr [0, 0, 0, 0] }]

/-- Runs a program over the clipboard port against the clipboard model
`model`: its value and the model after its last request. -/
def clipped {α : Type} (program : ClipboardM α) (model : ClipboardModel := {}) :
    α × ClipboardModel :=
  Program.run (port := clipboardPort) ClipboardModel.handle program model

/-- A clipboard written for the test that breaks the contract: it accepts
every write and keeps none, so a read answers what it held before. -/
def droppingWrites : (request : ClipboardRequest) → ClipboardModel → request.Reply × ClipboardModel
  | .read, model => (.ok model.held, model)
  | .write _, model => (.ok (), model)

/-- The checks of the clipboard interface's model
(`Editor/Clipboard/Model.lean`): what only the model shows, a clipboard
that is not available and one that holds nothing, and the contract
(`Editor/Clipboard/Contract.lean`) seen to report a clipboard that breaks
it. -/
def clipboardChecks : List Check :=
  [{  name :=
        "a clipboard model that is not available refuses a read and a write, each with unavailable, and holds what it held: the refused write replaces nothing, and once it is available again a read answers the text from before"
      run :=
        pure <|
          let away : ClipboardModel := { held := some "kept", available := false }
          let (read, afterRead) := clipped Clipboard.read away
          let (written, afterWrite) := clipped (Clipboard.write "lost") away
          let (back, _) := clipped Clipboard.read { afterWrite with available := true }
          replied read == .inl .unavailable && afterRead == away &&
            replied written == .inl .unavailable &&
            afterWrite == away &&
            replied back == .inr (some "kept") },
    { name :=
        "a clipboard model that holds nothing answers a read with no text, which is another answer than the empty text, and a read changes nothing"
      run :=
        pure <|
          let (read, after) := clipped Clipboard.read
          let (empty, _) :=
            clipped do
              discard <| Clipboard.write ""
              Clipboard.read
          replied read == .inr none && after == {} && replied empty == .inr (some "") &&
            replied read != replied empty },
    { name :=
        "the clipboard contract reports a clipboard that drops every write: its first property, that a text written is the text read, does not hold of it, and every property holds of the model"
      run := do
        let dropped ←
          ClipboardContract.failures
              (fun property =>
                pure (Program.run (port := clipboardPort) droppingWrites property.holds {}).1)
              ClipboardContract.properties
        let held ←
          ClipboardContract.failures (fun property => pure (clipped property.holds).1)
              ClipboardContract.properties
        return (ClipboardContract.properties.head?.map (·.name)).any dropped.contains &&
            held.isEmpty &&
            !ClipboardContract.properties.isEmpty }]

/-- Runs a program over the fuzzy port against the fuzzy model: its
value. The model has no state. -/
def ranked {α : Type} (program : FuzzyM α) : α :=
  (Program.run (port := fuzzyPort) FuzzyModel.handle program ()).1

/-- A matcher written for the tests that break the contract: a candidate
matches when `matched` says so of the pattern and the candidate, and the
candidates that are the pattern come first only with `exactFirst`; the rest
are in the candidates' order. -/
def matcherBy (matched : String → String → Bool) (exactFirst : Bool) :
    (request : FuzzyRequest) → Unit → request.Reply × Unit
  | .rank pattern candidates, state =>
    let indices :=
      (Array.range candidates.size).filter fun index => (candidates[index]?).any (matched pattern)
    if exactFirst then
      (indices.filter (candidates[·]? == some pattern) ++
          indices.filter (candidates[·]? != some pattern),
        state)
    else (indices, state)

/-- The names of the fuzzy contract's properties that do not hold of the
matcher `handle`. -/
def fuzzyBroken (handle : (request : FuzzyRequest) → Unit → request.Reply × Unit) :
    IO (List String) :=
  FuzzyContract.failures
    (fun property => pure (Program.run (port := fuzzyPort) handle property.holds ()).1)
    FuzzyContract.properties

/-- The checks of the fuzzy matching interface's model
(`Editor/Fuzzy/Model.lean`): what only the model shows, its rule of what
matches and its order after the candidates that are the pattern, and the
contract (`Editor/Fuzzy/Contract.lean`) seen to report a matcher that
breaks each of the two things it asks. -/
def fuzzyChecks : List Check :=
  [{  name :=
        "the fuzzy model matches a pattern whose characters are in a candidate in order, together or apart, and not one with a character the candidate lacks or with its characters in another order; the empty pattern matches everything and nothing else matches the empty candidate"
      run :=
        pure <|
          FuzzyModel.matches "ace" "ace" && FuzzyModel.matches "ace" "abcde" &&
            !FuzzyModel.matches "axe" "abcde" &&
            !FuzzyModel.matches "eca" "abcde" &&
            !FuzzyModel.matches "aa" "a" &&
            FuzzyModel.matches "aa" "aba" &&
            FuzzyModel.matches "" "" &&
            FuzzyModel.matches "" "a" &&
            !FuzzyModel.matches "a" "" &&
            !FuzzyModel.matches "a" "A" },
    { name :=
        "the fuzzy model ranks the candidates that are the pattern first and the other matches after them, each group in the order the candidates came in, and a request through the port is answered so"
      run :=
        pure <|
          let candidates := #["wq", "edit", "rewrite", "w", "w", "xw"]
          FuzzyModel.rank "w" candidates == #[3, 4, 0, 2, 5] &&
            ranked (Fuzzy.rank "w" candidates) == #[3, 4, 0, 2, 5] &&
            FuzzyModel.rank "z" candidates == #[] &&
            FuzzyModel.rank "w" #[] == #[] },
    { name :=
        "the fuzzy contract reports a matcher that ignores case, by its properties of which candidates match and by none of an exact match"
      run := do
        let folded (pattern candidate : String) : Bool :=
          FuzzyModel.matches pattern.toLower candidate.toLower
        let broken ← fuzzyBroken (matcherBy folded true)
        return !broken.isEmpty && broken.all (·.startsWith FuzzyContract.whichMatch) },
    { name :=
        "the fuzzy contract reports a matcher that answers the matches in the candidates' order, by its properties of an exact match and by none of which candidates match"
      run := do
        let broken ← fuzzyBroken (matcherBy FuzzyModel.matches false)
        return !broken.isEmpty && broken.all (·.startsWith FuzzyContract.exactFirst) },
    { name :=
        "every property of the fuzzy contract holds of the model and of a matcher written to its rule, and the contract has properties of which candidates match and of an exact match"
      run := do
        let names := FuzzyContract.properties.map (·.name)
        return (← fuzzyBroken FuzzyModel.handle).isEmpty &&
            (← fuzzyBroken (matcherBy FuzzyModel.matches true)).isEmpty &&
            names.any (·.startsWith FuzzyContract.whichMatch) &&
            names.any (·.startsWith FuzzyContract.exactFirst) }]

/-- The syntax tree model knowing `texts`, as the snapshots `0`, `1` and so
on, and the ids of those snapshots. -/
def syntaxTreeModelOf (texts : Array String) : SyntaxTreeModel × Array SnapshotId :=
  let ids := (Array.range texts.size).map (⟨·⟩)
  ({ texts := ids.zip texts }, ids)

/-- The names of the syntax tree contract's properties that do not hold of
`handle`, run from a model knowing each property's texts. -/
def syntaxTreeBroken
    (handle : (request : SyntaxTreeRequest) → SyntaxTreeModel → request.Reply × SyntaxTreeModel) :
    IO (List String) :=
  SyntaxTreeContract.failures
    (fun property =>
      let (model, ids) := syntaxTreeModelOf property.texts
      pure
        ((Program.run (port := syntaxTreePort) handle (property.holds ids).run model).1 matches
          .ok true))
    SyntaxTreeContract.properties

/-- The model, but a question of captures in a range answers the whole
text's: a model that breaks the range rule. -/
def wholeRange : (request : SyntaxTreeRequest) → SyntaxTreeModel → request.Reply × SyntaxTreeModel
  | .captures snapshot query _ _, model =>
    let length := ((model.text? snapshot).map (·.utf8ByteSize)).getD 0
    SyntaxTreeModel.handle (.captures snapshot query 0 length) model
  | request, model => SyntaxTreeModel.handle request model

/-- The flat tree the model parses `text` to, each node as its kind, its
field, its depth and its range. -/
def jsonShape (text : String) : Array (String × Option String × Nat × Nat × Nat) :=
  (SyntaxTreeModel.Json.parse text).flatten.map fun node =>
    (node.kind, node.field, node.depth, node.start, node.stop)

/-- Whether `source` is refused by the model's query subset as unsupported. -/
def unsupportedQuery (source : String) : Bool :=
  match SyntaxTreeModel.Query.compile source with
  | .error (.unsupported, _) => true
  | _ => false

/-- The checks of the syntax tree interface's model
(`Editor/SyntaxTree/Model.lean`): what only the model shows, and the
contract (`Editor/SyntaxTree/Contract.lean`) seen to report a model that
breaks the range rule. -/
def syntaxTreeChecks : List Check :=
  [{  name :=
        "the JSON model parses a small object node by node as the library's grammar does: the root, the object and its braces, a pair with its key and value at their fields, and each string's quotes and content"
      run :=
        pure <|
          jsonShape "{\"k\": \"v\"}" ==
            #[("document", none, 0, 0, 10), ("object", none, 1, 0, 10), ("{", none, 2, 0, 1),
              ("pair", none, 2, 1, 9), ("string", some "key", 3, 1, 4), ("\"", none, 4, 1, 2),
              ("string_content", none, 4, 2, 3), ("\"", none, 4, 3, 4), (":", none, 3, 4, 5),
              ("string", some "value", 3, 6, 9), ("\"", none, 4, 6, 7),
              ("string_content", none, 4, 7, 8), ("\"", none, 4, 8, 9), ("}", none, 2, 9, 10)] },
    { name :=
        "the JSON model's root starts after the blanks that lead the text, and at its end when it has no value"
      run :=
        pure <|
          jsonShape "" == #[("document", none, 0, 0, 0)] &&
            jsonShape "   " == #[("document", none, 0, 3, 3)] &&
            jsonShape " 1 " == #[("document", none, 0, 1, 3), ("number", none, 1, 1, 2)] &&
            jsonShape "-0.5e-3" == #[("document", none, 0, 0, 7), ("number", none, 1, 0, 7)] },
    { name :=
        "a text outside the JSON model's subset parses to the root over one ERROR node, from its first character that is not a blank"
      run :=
        pure <|
          jsonShape "[1,]" == #[("document", none, 0, 0, 4), ("ERROR", none, 1, 0, 4)] &&
            jsonShape " \"a\\nb\"" == #[("document", none, 0, 1, 7), ("ERROR", none, 1, 1, 7)] },
    { name :=
        "the model's query subset refuses a quantifier, an alternation, an anchor, a negated field, a predicate and a grouping as unsupported, and accepts what it implements"
      run :=
        pure <|
          unsupportedQuery "(number)* @n" && unsupportedQuery "(array (number)+ @n)" &&
            unsupportedQuery "[(true) (false)] @b" &&
            unsupportedQuery "(array . (number) @n)" &&
            unsupportedQuery "(pair !key) @p" &&
            unsupportedQuery "((number) @n (#eq? @n \"1\"))" &&
            unsupportedQuery "((number) @n (string) @s)" &&
            (SyntaxTreeModel.Query.compile
                "(pair key: (string) @k value: _ @v) ; c\n\",\" @c").toBool },
    { name :=
        "the syntax tree contract reports a model that answers a range with the whole text's captures, by its properties of ranges and by none of the whole text"
      run := do
        let broken ← syntaxTreeBroken wholeRange
        return broken.any (·.startsWith "a range answers the whole text's rows that are in it") &&
            broken.all (·.startsWith "a range ") },
    { name := "the model records the refresh delay it is handed, and answers nothing else for it"
      run :=
        pure <|
          let (model, ids) := syntaxTreeModelOf #["[1]"]
          let snapshot := ids[0]?.getD ⟨0⟩
          let program : SyntaxTreeM (Array SyntaxTree.Capture) := do
            SyntaxTree.attach snapshot "json"
            SyntaxTree.refreshAfter 250
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTree.captures snapshot query 0 3
          match SyntaxTreeM.runModel program model with
          | (.ok found, after) => after.refreshAfter == some 250 && found.size == 1
          | _ => false },
    { name :=
        "a model whose trees a test says are not delivered refuses captures and capturesOf with notParsed, after the range check, and answers both once they are"
      run :=
        pure <|
          let (model, ids) := syntaxTreeModelOf #["[1]"]
          let snapshot := ids[0]?.getD ⟨0⟩
          let program : SyntaxTreeM Bool := do
            SyntaxTree.attach snapshot "json"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTree.keep snapshot .indents query
            return (←
                  SyntaxTreeContract.refusedWith .notParsed
                      (SyntaxTree.captures snapshot query 0 3)) &&
                (←
                  SyntaxTreeContract.refusedWith .notParsed
                      (SyntaxTree.capturesOf snapshot .indents 0 3)) &&
                (←
                  SyntaxTreeContract.refusedWith .badRange
                      (SyntaxTree.capturesOf snapshot .indents 0 9)) &&
                (←
                  SyntaxTreeContract.refusedWith .noQuery
                      (SyntaxTree.capturesOf snapshot .textObjects 0 3))
          let delivered : SyntaxTreeM Nat := do
            SyntaxTree.attach snapshot "json"
            let query ← SyntaxTree.compile "json" "(number) @n"
            SyntaxTree.keep snapshot .indents query
            return (← SyntaxTree.captures snapshot query 0 3).size +
                (← SyntaxTree.capturesOf snapshot .indents 0 3).captures.size
          (SyntaxTreeM.runModel program { model with delivered := false }).1 matches .ok true &&
            (SyntaxTreeM.runModel delivered model).1 matches .ok 2 },
    { name := "every property of the syntax tree contract holds of the model"
      run := return (← syntaxTreeBroken SyntaxTreeModel.handle).isEmpty }]

/-- The editor's models with a watch model that counts: its clock, at 0,
moves on by 1 at each text request and each display request, so its reading
is how many of them a command made. -/
def countingModel (watch : WatchModel := {}) : EditorModel :=
  { editorModel with
    watch :=
      { watch with
        clock := 0, pace := 1 } }

/-- A command that makes a text of each of `labels`, in order, and returns
how many it made. -/
def makesEach (labels : List String) : EditorM Nat := do
  for label in labels do
    makes label
  return labels.length

/-- `command` as the loop runs one (`EditorM.dispatched`), told nothing of
the registry, from an editor state with nothing in it: how it ended. The
commands of the guard checks make no state request, so the state it left is
not looked at. -/
def guarded {α : Type} (command : EditorM α) : EditorM (Guarded α) :=
  return (← command.dispatched {} EditorState.none).1

/-- The checks of the guard of a dispatched command
(`Editor/Command/Dispatch.lean`, "The guard") on the editor's models: it
stops at its next request once the interrupt flag is up. They run the
transformation the loop runs, on commands that make no state request. -/
def guardChecks : List Check :=
  [{  name :=
        "with the interrupt flag down a guarded command finishes with its value, and leaves the models as the command alone does"
      run := do
        let command := makesEach ["1", "2", "3"]
        let (bare, alone) := command.runModel countingModel
        let (ended, model) := (guarded command).runModel countingModel
        return resulted bare == .inr 3 && resulted ended == .inr (.finished 3) &&
            model.texts.contents == alone.texts.contents &&
            model.display.scenes == alone.display.scenes &&
            model.watch == alone.watch },
    { name :=
        "a guarded command that is refused is not itself refused: the refusal comes back as its outcome, with what the command did before it"
      run := do
        let command : EditorM Nat := do
          makes "1"
          (⟨7⟩ : TextId).insert 0 "x"
          makesEach ["2"]
        let (ended, model) := (guarded command).runModel countingModel
        return resulted ended == .inr (.refused .noSuchText) && model.texts.contents == #["1"] },
    { name :=
        "with the interrupt flag up before it starts, a guarded command makes no request and is interrupted, and the flag stays up"
      run := do
        let (ended, model) :=
          (guarded (makesEach ["1", "2"])).runModel (countingModel { arrived := 1 })
        return resulted ended == .inr .interrupted && model.texts.contents == #[] &&
            model.watch.clock == 0 &&
            model.watch.arrived == 1 },
    { name :=
        "when the interrupt key arrives as a guarded command is about to make its fourth request, the command has made exactly three and makes no more"
      run := do
        let (ended, model) :=
          (guarded (makesEach ["1", "2", "3", "4", "5"])).runModel
            (countingModel { arrivesAfter := some 3 })
        return resulted ended == .inr .interrupted && model.texts.contents == #["1", "2", "3"] &&
            model.watch.clock == 3 },
    { name :=
        "a command that catches every refusal of every request cannot go on past an interrupt: nothing is thrown for it to catch"
      run := do
        let stubborn : EditorM Nat := do
          let mut made := 0
          for label in ["1", "2", "3", "4"] do
            try
              makes label
              made := made + 1
            catch _ =>
              made := made + 100
          return made
        let (ended, model) := (guarded stubborn).runModel (countingModel { arrivesAfter := some 2 })
        return resulted ended == .inr .interrupted && model.texts.contents == #["1", "2"] &&
            model.watch.clock == 2 },
    { name :=
        "a guarded command that makes no request finishes with its value though the interrupt flag is up: there is no request to stop it at"
      run := do
        let (ended, model) :=
          (guarded (pure 7 : EditorM Nat)).runModel (countingModel { arrived := 1 })
        return resulted ended == .inr (.finished 7) && model.watch.arrived == 1 },
    { name :=
        "a clipboard request is guarded like a text request: with the interrupt flag up before a clipboard write the write is not made and the clipboard holds what it held, and with the flag down the same command writes"
      run := do
        let command : EditorM Unit := discard <| Clipboard.write "copied"
        let (ended, model) := (guarded command).runModel (countingModel { arrived := 1 })
        let (finished, wrote) := (guarded command).runModel countingModel
        return resulted ended == .inr .interrupted && model.clipboard.held == none &&
            model.watch.clock == 0 &&
            resulted finished == .inr (.finished ()) &&
            wrote.clipboard.held == some "copied" &&
            wrote.watch.clock == 1 },
    { name :=
        "a fuzzy request is guarded like a text request: with the interrupt flag up before a ranking the request is not made, and with the flag down the same command is answered"
      run := do
        let candidates := #["wq", "edit", "w"]
        let command : EditorM (Array Nat) := Fuzzy.rank "w" candidates
        let (ended, model) := (guarded command).runModel (countingModel { arrived := 1 })
        let (finished, asked) := (guarded command).runModel countingModel
        return resulted ended == .inr .interrupted && model.watch.clock == 0 &&
            resulted finished == .inr (.finished (FuzzyModel.rank "w" candidates)) &&
            asked.watch.clock == 1 }]

/-- A view of the first text of a display model, `width` pixels wide and
`height` tall. -/
def areaOf (width height : Nat) : Scroll.Area :=
  { snapshot := ⟨0⟩, width, height }

/-- What a display program answers on the display model over `text`, or none
where it was refused. -/
def onDisplay {α : Type} (text : String) (program : DisplayM α)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option α :=
  (program.runModel (displayOver [text] cells)).1.toOption

/-- The rows a view of `text`, `width` by `height` pixels, shows from
`anchor`, as the display model answers them; none where it refuses. -/
def rowsFrom (text : String) (width height anchor : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Array Display.Row :=
  (onDisplay text ((areaOf width height).rows anchor) cells).getD #[]

/-- Every row of `text` in a view `width` pixels wide, as the display model
answers them: what a view taller than the text shows from its start. -/
def allRows (text : String) (width : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Array Display.Row :=
  rowsFrom text width (cells.lineHeight * (text.utf8ByteSize + 1)) 0 cells

/-- The row that holds `position`, as the display model answers it. -/
def rowAt (text : String) (width position : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option Display.Row :=
  (rowsFrom text width cells.lineHeight position cells)[0]?

/-- Where row `index` of `rows` starts; past the last of them, an offset no
row starts at. -/
def startOf (rows : Array Display.Row) (index : Nat) : Nat :=
  (rows[index]?.map (·.start)).getD (rows.size + (rows.back?.map (·.stop)).getD 0 + 1)

/-- What the follow policy answers for a view of `text` whose scroll anchor
is at `anchor` and whose cursor is at `head`: the offset to place the anchor
at, or none inside to keep it; none outside where the display refused. -/
def followFrom (text : String) (width height margin anchor head : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option (Option Nat) :=
  onDisplay text (cells := cells) do
    let area := areaOf width height
    Scroll.follow area margin (← area.rows anchor) head

/-- A view after the follow policy. -/
structure Followed where
  /-- Whether the policy placed an anchor. -/
  moved : Bool
  /-- The rows the view shows afterwards. -/
  shown : Array Display.Row
  /-- Where the cursor's row is among them, if it is one of them. -/
  index : Option Nat
  deriving DecidableEq, Repr

/-- The view of `followFrom` after the policy: the rows the display model
answers from the anchor placed, or from `anchor` where it was kept, and
where the cursor's row is among them. -/
def followedFrom (text : String) (width height margin anchor head : Nat)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option Followed := do
  let moved ← followFrom text width height margin anchor head cells
  let row ← rowAt text width head cells
  let shown := rowsFrom text width height (moved.getD anchor) cells
  return { moved := moved.isSome, shown, index := shown.findIdx? (· == row) }

/-- Whether `row` is among `shown` at least `margin` rows from the first and
from the last of them, except where the first is the first of `rows`, the
text's rows, or the last their last. -/
def marginHolds (rows shown : Array Display.Row) (row : Display.Row) (margin : Nat) : Bool :=
  match shown.findIdx? (· == row) with
  | none => false
  | some index =>
    (index ≥ margin || shown[0]? == rows[0]?) &&
      (shown.size - 1 - index ≥ margin || shown.back? == rows.back?)

/-- Whether the follow policy, handed `margin`, holds a margin of `held`
rows, from every row of `text` as the first row shown and every offset of it
as the cursor (the text is ASCII): afterwards the margin holds of the
cursor's row, an anchor is kept when it held already, and a second follow
keeps the anchor. -/
def marginSweep (text : String) (width height margin : Nat) (held : Nat := margin) : Bool :=
  let rows := allRows text width
  !rows.isEmpty &&
    rows.all fun top =>
      (List.range (text.utf8ByteSize + 1)).all fun head =>
        match rowAt text width head, followFrom text width height margin top.start head with
        | some row, some moved =>
          let anchor := moved.getD top.start
          marginHolds rows (rowsFrom text width height anchor) row held &&
            (!marginHolds rows (rowsFrom text width height top.start) row held || moved.isNone) &&
            followFrom text width height margin anchor head == some none
        | _, _ => false

/-- Sixteen lines of one letter each, `a` to `p`, with no line feed after the
last. -/
def sixteen : String :=
  "\n".intercalate ("abcdefghijklmnop".toList.map (·.toString))

/-- Lines of 10, 2, 0, 7, 1, 1, 1, 17 and 1 characters, and a line feed after
the last: four characters wide, the first, the fourth and the eighth wrap. -/
def ragged : String :=
  "abcdefghij\nab\n\nabcdefg\nx\ny\nz\nabcdefghijklmnopq\nq\n"

/-- What the follow policy costs on the counting model, for a view of
`sixteen` ten characters wide and `height` rows tall whose first row shown is
row `top` and whose cursor is on row `cursor`: whether it placed an anchor,
and how many requests it made after the rows shown, which its caller
asked. -/
def followCost (height margin top cursor : Nat) : Option (Bool × Nat) :=
  let rows := allRows sixteen 10
  let program : EditorM (Bool × Nat) := do
    let text ← createText sixteen
    let area : Scroll.Area := { snapshot := ← text.snapshot, width := 10, height }
    let shown ← area.rows (startOf rows top)
    let before ← Watch.now
    let moved ← Scroll.follow area margin shown (startOf rows cursor)
    return (moved.isSome, (← Watch.now) - before)
  (program.runModel countingModel).1.toOption

/-- Where a scroll down by `rows` rows places the anchor of a view of `text`
whose anchor is at `anchor`, handed the rows the view fits as its caller
asks them: none inside to keep it, none outside where the display
refused. -/
def scrolledDown (text : String) (width height anchor rows : Nat) : Option (Option Nat) :=
  onDisplay text do
    let area := areaOf width height
    Scroll.down area anchor rows (← area.fits)

/-- The same for a scroll up. -/
def scrolledUp (text : String) (width height anchor rows : Nat) : Option (Option Nat) :=
  onDisplay text do
    let area := areaOf width height
    Scroll.up area anchor rows (← area.fits)

/-- Whether, from every row of `text` as the first row shown, a scroll by 1,
2, 3, 5 and 100 rows places the anchor the model's rows say: down, the row
that many below, no further than where the text's last row is the last row
shown, and never a row before the one given; up, the row that many above,
no further than the first; none where that is the row it was at. -/
def scrollSweep (text : String) (width height : Nat) : Bool :=
  let rows := allRows text width
  let fits := (rowsFrom text width height 0).size
  let placed (was want : Nat) : Option (Option Nat) :=
    some (if want == was then none else some (startOf rows want))
  fits > 0 &&
    (List.range rows.size).all fun top =>
      [1, 2, 3, 5, 100].all fun count =>
        scrolledDown text width height (startOf rows top) count ==
            placed top (max top (min (top + count) (rows.size - fits))) &&
          scrolledUp text width height (startOf rows top) count == placed top (top - count)

/-- Whether, from every offset of `text` as the cursor (the text is ASCII),
a scroll to the cursor's row places an anchor from which the model shows
that row first, in the middle of the rows the view fits (the upper of two)
and last; or, where the text has fewer rows above the cursor than that
takes, the text's first row first. Where the view shows the whole text from
its start, a scroll to the middle places the text's first row first,
wherever the cursor is. -/
def lineToSweep (text : String) (width height : Nat) : Bool :=
  let rows := allRows text width
  let fits := (rowsFrom text width height 0).size
  -- Whether the rows shown from the text's start are all of its rows.
  let whole := fits == rows.size
  fits > 0 &&
    (List.range (text.utf8ByteSize + 1)).all fun head =>
      match rowAt text width head with
      | none => false
      | some row =>
        let cursor := (rows.findIdx? (· == row)).getD rows.size
        -- The cursor's row is to be `up` rows below the first row shown.
        let placed (place : Scroll.Place) (up : Nat) (kept : Bool := false) : Bool :=
          match onDisplay text (Scroll.lineTo place (areaOf width height) head) with
          | some (some anchor) =>
            let shown := rowsFrom text width height anchor
            if cursor ≥ up && !kept then shown[up]? == some row else shown[0]? == rows[0]?
          | _ => false
        placed .top 0 && placed .middle ((fits - 1) / 2) (kept := whole) &&
          placed .bottom (fits - 1)

/-- Blocks over `sixteen` ten cells wide: a block of one row before rows 3,
6 and 7, and one of two rows before row 12 (its text is twelve cells). -/
def sixteenBlocks : Array Block :=
  #[{ before := 6, text := "H" }, { before := 12, text := "I" }, { before := 14, text := "J" },
    { before := 24, text := "twelve-cells" }]

/-- A view of `sixteen` ten cells wide and `height` rows tall, with
`sixteenBlocks`. -/
def blockedArea (height : Nat) : Scroll.Area :=
  { snapshot := ⟨0⟩, width := 10, height, blocks := sixteenBlocks }

/-- The rows of a view of `sixteen` with blocks (`blockedArea`) from
`anchor`, as the display model answers them; none where it refuses. -/
def blockedRows (height anchor : Nat) : Array Display.Row :=
  (onDisplay sixteen ((blockedArea height).rows anchor)).getD #[]

/-- Whether the cursor's row, that of `head`, is among `shown`, the rows of
a view with blocks `height` rows tall, with `margin` rows after it as far as
the rows shown from the cursor's row reach, which is where the follow's
margin gives way below (`Editor/Scroll.lean`, "The margin"), or it is the
first row shown (`Editor/Scroll.lean`, "Blocks": the settle holds the
margin below). -/
def blockedHolds (height : Nat) (shown : Array Display.Row) (head margin : Nat) : Bool :=
  let below := (blockedRows height head).size - 1
  match shown.findIdx? (·.start == head) with
  | none => false
  | some index => index == 0 || shown.size - 1 - index ≥ min margin below

/-- Where the follow places the anchor of a view of `sixteen` with blocks
`height` rows tall from `anchor`, with its cursor at `head`; none outside
where the display refused. -/
def blockedFollow (height margin anchor head : Nat) : Option (Option Nat) :=
  onDisplay sixteen do
    let area := blockedArea height
    Scroll.follow area margin (← area.rows anchor) head

/-- The anchors a view of `sixteen` with blocks `height` rows tall is left
at, with the margin `margin`, by a cursor on every row from the first to
the last and back, one row at a time, the follow asked after each from the
anchor the one before left, from the text's start; and whether the cursor's
row was shown with the margin in force below it (`blockedHolds`) each time. -/
def blockedSweep (height margin : Nat) : Bool :=
  Id.run do
    let fits := (blockedRows height 0).size
    let held := min margin ((fits - 1) / 2)
    let mut anchor := 0
    for row in List.range 16 ++ (List.range 16).reverse do
      let head := 2 * row
      let some moved := blockedFollow height margin anchor head | return false
      anchor := moved.getD anchor
      unless blockedHolds height (blockedRows height anchor) head held do
        return false
    return true

/-- What the follow costs on the counting model for a view of `sixteen` ten
characters wide and five rows tall whose first row shown is row `top` and
whose cursor is on row `cursor`, with `blocks`: whether it placed an anchor,
and how many requests it made after the rows shown. -/
def blockedFollowCost (blocks : Array Block) (top cursor : Nat) : Option (Bool × Nat) :=
  let program : EditorM (Bool × Nat) := do
    let text ← createText sixteen
    let area : Scroll.Area := { snapshot := ← text.snapshot, width := 10, height := 5, blocks }
    let shown ← area.rows (2 * top)
    let before ← Watch.now
    let moved ← Scroll.follow area 0 shown (2 * cursor)
    return (moved.isSome, (← Watch.now) - before)
  (program.runModel countingModel).1.toOption

/-- The checks of the follow and of the scrolls in a view with blocks
(`Editor/Scroll.lean`, "Blocks"), on the display model alone, over
`sixteen` with `sixteenBlocks`. -/
def blockedScrollChecks : List Check :=
  [{  name :=
        "in a view with blocks, a cursor on every row of the text, reached down a row at a time and back up, is among the rows shown after the follow, with the margin in force below it as far as the rows from it reach, at margins 0, 1 and 2 and in views of 3, 5 and 7 rows"
      run :=
        pure <|
          [3, 5, 7].all fun height => [0, 1, 2].all fun margin => blockedSweep height margin },
    { name :=
        "in a view with blocks, a jump to the text's end and back to its start shows the cursor's row"
      run :=
        pure <|
          [3, 5, 7].all fun height =>
            match blockedFollow height 0 0 30 with
            | some (some down) =>
              blockedHolds height (blockedRows height down) 30 0 &&
                match blockedFollow height 0 down 0 with
                | some (some up) => up == 0 && blockedHolds height (blockedRows height up) 0 0
                | _ => false
            | _ => false },
    { name :=
        "in a view with blocks, a scroll by a row, by half a view and up, and to the top, the middle and the bottom, followed by the follow, shows the cursor's row, from every row shown first and every row as the cursor"
      run :=
        pure <|
          [3, 5, 7].all fun height =>
            let area := blockedArea height
            (List.range 16).all fun top =>
              (List.range 16).all fun row =>
                let head := 2 * row
                let anchor := 2 * top
                let scrolls : List (DisplayM (Option Nat)) :=
                  [do
                    Scroll.down area anchor 1 (← area.fits), do
                    Scroll.down area anchor (Scroll.Amount.half.rows 0 (← area.fits)) (← area.fits),
                    do
                    Scroll.up area anchor 2 (← area.fits), Scroll.lineTo .top area head,
                    Scroll.lineTo .middle area head, Scroll.lineTo .bottom area head]
                scrolls.all fun scroll =>
                  match onDisplay sixteen scroll with
                  | some placed =>
                    let anchor := placed.getD anchor
                    match blockedFollow height 0 anchor head with
                    | some moved =>
                      blockedHolds height (blockedRows height (moved.getD anchor)) head 0
                    | none => false
                  | none => false },
    { name :=
        "a view with blocks shows the rows of the view without them that fit with the block rows above them: from the text's start, the first three rows and the fourth with its block"
      run :=
        pure <|
          blockedRows 5 0 == (rowsFrom sixteen 10 5 0).extract 0 4 &&
            (onDisplay sixteen ((areaOf 10 5).rows 0)) == some (rowsFrom sixteen 10 5 0) },
    { name :=
        "what the follow costs with blocks: one request more where it places an anchor that holds the cursor's row, one more for each row it settles, and nothing more where it keeps the anchor"
      run :=
        pure <|
          -- Row 11 from row 0: the anchor placed, row 8, holds it.
          blockedFollowCost #[] 0 11 == some (true, 2) &&
            blockedFollowCost sixteenBlocks 0 11 == some (true, 3) &&
            -- Row 15 from row 0: the anchor placed, row 12, shows its two
            -- block rows and does not hold it; one step to row 13 does.
            blockedFollowCost sixteenBlocks 0 15 == some (true, 4) &&
            -- A cursor shown asks the rows from it alone.
            blockedFollowCost sixteenBlocks 0 1 == some (false, 1) &&
            blockedFollowCost #[] 0 1 == some (false, 1) }]

/-- The checks of the policy by which a view follows its cursor and of the
anchors a scroll places (`Editor/Scroll.lean`), on the display model alone,
with the scroll anchor and the cursor as offsets. A row is one the display model answers
(`allRows`, `rowsFrom`, `rowAt`): no check says where a text wraps. -/
def scrollChecks : List Check :=
  [{  name :=
        "the area of a view asks with the snapshot of its text, its rectangle's width and its rectangle's height less its bottom row"
      run :=
        pure
          (Scroll.Area.ofRect ⟨3⟩ { x := 7, y := 9, width := 40, height := 30 } 16 ==
              { snapshot := ⟨3⟩, width := 40, height := 14 } &&
            (Scroll.Area.ofRect ⟨3⟩ { x := 7, y := 9, width := 40, height := 10 } 16).height ==
              0) },
    { name :=
        "a cursor on the first row a view shows, on the last, and on one between them keeps the scroll anchor"
      run :=
        pure <|
          let rows := allRows sixteen 10
          rows.size == 16 &&
            [3, 5, 7].all fun cursor =>
              followFrom sixteen 10 5 0 (startOf rows 3) (startOf rows cursor) == some none },
    { name :=
        "a cursor one row below the rows shown moves the anchor one row, and one ten rows below them moves it so that the cursor's row is the last row shown"
      run :=
        pure <|
          let rows := allRows sixteen 10
          followFrom sixteen 10 5 0 (startOf rows 3) (startOf rows 8) ==
              some (some (startOf rows 4)) &&
            followedFrom sixteen 10 5 0 (startOf rows 0) (startOf rows 14) ==
              some { moved := true, shown := rows.extract 10 15, index := some 4 } },
    { name :=
        "a cursor one row above the rows shown moves the anchor one row, and one ten rows above them moves it so that the cursor's row is the first row shown"
      run :=
        pure <|
          let rows := allRows sixteen 10
          followFrom sixteen 10 5 0 (startOf rows 8) (startOf rows 7) ==
              some (some (startOf rows 7)) &&
            followedFrom sixteen 10 5 0 (startOf rows 12) (startOf rows 2) ==
              some { moved := true, shown := rows.extract 2 7, index := some 0 } },
    { name :=
        "a cursor on the last visual row of a line wrapped over three rows, below the view, has that row as the last row shown, and the anchor is not the line's first row"
      run :=
        pure <|
          let rows := allRows wrapping 4
          -- The third line is rows 3, 4 and 5: a line break is before the
          -- first of them and after the last, and none is between them.
          let last := startOf rows 5
          (rows[2]?.map (·.stop + 1)) == some (startOf rows 3) &&
            (rows[3]?.map (·.stop)) == some (startOf rows 4) &&
            (rows[4]?.map (·.stop)) == some last &&
            (rows[5]?.map (·.stop + 1)) == some (startOf rows 6) &&
            (rowAt wrapping 4 (last + 1)).map (·.start) == some last &&
            followedFrom wrapping 4 2 0 0 (last + 1) ==
              some { moved := true, shown := rows.extract 4 6, index := some 1 } },
    { name :=
        "a cursor at the end of a text that ends in a line feed, in the empty row after it, is shown, as the last row"
      run :=
        pure <|
          let text := "a\nb\nc\nd\n"
          let rows := allRows text 10
          followedFrom text 10 2 0 0 text.utf8ByteSize ==
              some
                { moved := true, shown := rows.extract (rows.size - 2) rows.size,
                  index := some 1 } &&
            (rows.back?.map fun row => row.start == row.stop) == some true },
    { name := "a view that shows no row keeps its anchor, wherever its anchor and its cursor are"
      run :=
        pure <|
          let rows := allRows sixteen 10
          !rows.isEmpty &&
            rows.all fun top =>
              rows.all fun cursor =>
                followFrom sixteen 10 0 0 top.start cursor.start == some none &&
                  followFrom sixteen 10 0 2 top.start cursor.start == some none },
    { name :=
        "with a margin of two, from every row as the first row shown and every position as the cursor, of sixteen short lines and of a text with wrapped lines, in views of five and of seven rows: afterwards the cursor's row is among the rows shown, at least two rows from the first unless the first is the text's first row and at least two from the last unless the last is the text's last; an anchor is kept when that held already; and a second follow keeps the anchor"
      run :=
        pure
          (marginSweep sixteen 10 5 2 && marginSweep sixteen 10 7 2 && marginSweep ragged 4 5 2 &&
            marginSweep ragged 4 7 2) },
    { name :=
        "with no margin, the same sweep: the cursor's row is among the rows shown afterwards, an anchor that showed it is kept, and a second follow keeps the anchor"
      run :=
        pure
          (marginSweep sixteen 10 5 0 && marginSweep ragged 4 3 0 && marginSweep ragged 4 1 0 &&
            marginSweep "" 4 3 0) },
    { name :=
        "a margin larger than a view can keep is half the rows the view fits: with a margin of 99 a view of five rows keeps two rows each side of the cursor's row, and keeps its anchor while it does"
      run :=
        pure <|
          let rows := allRows sixteen 10
          followedFrom sixteen 10 5 99 (startOf rows 0) (startOf rows 10) ==
              some { moved := true, shown := rows.extract 8 13, index := some 2 } &&
            followedFrom sixteen 10 5 99 (startOf rows 8) (startOf rows 11) ==
              some { moved := true, shown := rows.extract 9 14, index := some 2 } &&
            followFrom sixteen 10 5 99 (startOf rows 8) (startOf rows 10) == some none &&
            marginSweep sixteen 10 5 99 (held := 2) },
    { name :=
        "the policy counts no pixels: in cells of 8 by 16, in a view 48 pixels tall, a cursor below the rows shown becomes the last of three rows shown and one above them the first"
      run :=
        pure <|
          let cells : Display.Cells := { advance := 8, lineHeight := 16 }
          let rows := allRows sixteen 80 cells
          rows.size == 16 &&
            followedFrom sixteen 80 48 0 (startOf rows 0) (startOf rows 9) cells ==
              some { moved := true, shown := rows.extract 7 10, index := some 2 } &&
            followedFrom sixteen 80 48 0 (startOf rows 9) (startOf rows 4) cells ==
              some { moved := true, shown := rows.extract 4 7, index := some 0 } },
    { name :=
        "what the policy costs, counted on the watch model's clock, after the rows shown, which its caller asked: one request where the anchor is kept and the margin as set holds, with a margin and with none; one for a cursor above with no margin; two for a cursor below with no margin, and one in a view of one row; with a margin that does not hold as set, two where the anchor is kept and three where it moves"
      run :=
        pure
          (followCost 5 0 3 5 == some (false, 1) && followCost 5 2 3 5 == some (false, 1) &&
            followCost 5 0 8 2 == some (true, 1) &&
            followCost 5 0 0 10 == some (true, 2) &&
            followCost 1 0 0 10 == some (true, 1) &&
            followCost 5 2 0 1 == some (false, 2) &&
            followCost 5 2 3 7 == some (true, 3)) },
    { name :=
        "the rows a view fits are the rows it shows from the text's start: its own rows where the text has more, and the text's rows where the text is shorter than the view"
      run :=
        pure
          (onDisplay sixteen (areaOf 10 5).fits == some 5 &&
            onDisplay "a\nb\nc" (areaOf 10 9).fits == some (allRows "a\nb\nc" 10).size &&
            (allRows "a\nb\nc" 10).size < 9 &&
            onDisplay sixteen (areaOf 10 0).fits == some 0) },
    { name :=
        "how many rows a scroll is: half the rows the view fits and at least one, or the count when one was typed; and the rows the view fits, times the count when one was typed"
      run :=
        pure
          (Scroll.Amount.half.rows 0 6 == 3 && Scroll.Amount.half.rows 0 7 == 3 &&
            Scroll.Amount.half.rows 0 1 == 1 &&
            Scroll.Amount.half.rows 5 6 == 5 &&
            Scroll.Amount.page.rows 0 6 == 6 &&
            Scroll.Amount.page.rows 1 6 == 6 &&
            Scroll.Amount.page.rows 2 6 == 12) },
    { name :=
        "a scroll down moves the anchor the rows asked; near the text's end it stops where the text's last row is the last row shown; and from there, and from an anchor past it, it places none"
      run :=
        pure <|
          let rows := allRows sixteen 10
          scrolledDown sixteen 10 5 (startOf rows 3) 2 == some (some (startOf rows 5)) &&
            scrolledDown sixteen 10 5 (startOf rows 9) 5 == some (some (startOf rows 11)) &&
            rowsFrom sixteen 10 5 (startOf rows 11) == rows.extract 11 16 &&
            scrolledDown sixteen 10 5 (startOf rows 11) 1 == some none &&
            scrolledDown sixteen 10 5 (startOf rows 13) 1 == some none },
    { name :=
        "a scroll up moves the anchor the rows asked, and no further than the text's first row, where it places none"
      run :=
        pure <|
          let rows := allRows sixteen 10
          scrolledUp sixteen 10 5 (startOf rows 9) 2 == some (some (startOf rows 7)) &&
            scrolledUp sixteen 10 5 (startOf rows 3) 5 == some (some (startOf rows 0)) &&
            scrolledUp sixteen 10 5 (startOf rows 0) 1 == some none },
    { name :=
        "from every row as the first row shown, of sixteen short lines, of a text with wrapped lines and of a text shorter than its view, by 1, 2, 3, 5 and 100 rows: a scroll down places the row that many below, no further than where the text's last row is the last row shown, and never a row before the one it was given; a scroll up the row that many above, no further than the first; and each places none where that is the row it was at"
      run :=
        pure
          (scrollSweep sixteen 10 5 && scrollSweep sixteen 10 1 && scrollSweep ragged 4 3 &&
            scrollSweep ragged 4 7 &&
            scrollSweep "a\nb\nc" 10 9 &&
            scrollSweep "" 4 3) },
    { name :=
        "a scroll to the cursor's row, from every position as the cursor: to the top, the cursor's row is the first row then shown; to the middle, the middle row of those the view fits, the upper of two; to the bottom, the last; and where the text has too few rows above the cursor for that, the first row shown is the text's first"
      run :=
        pure
          (lineToSweep sixteen 10 5 && lineToSweep sixteen 10 6 && lineToSweep ragged 4 3 &&
            lineToSweep ragged 4 4 &&
            lineToSweep "" 4 3) },
    { name :=
        "a scroll to the middle never hides a row of a text its view shows whole: in a view taller than its text and in one the text fills exactly, of short lines and of wrapped ones, from every position as the cursor, it places the text's first row, while a scroll to the top still puts the cursor's row first; and in a view one row shorter than its text it puts the cursor's row in the middle"
      run :=
        pure <|
          let rows := allRows sixteen 10
          lineToSweep "a\nb\nc" 10 9 && lineToSweep "a\nb\nc\n" 10 9 &&
            lineToSweep "a\nb\nc" 10 3 &&
            lineToSweep sixteen 10 16 &&
            lineToSweep ragged 4 (allRows ragged 4).size &&
            lineToSweep ragged 4 40 &&
            onDisplay "a\nb\nc\n" (Scroll.lineTo .middle (areaOf 10 10) 4) == some (some 0) &&
            onDisplay sixteen (Scroll.lineTo .middle (areaOf 10 16) (startOf rows 15)) ==
              some (some 0) &&
            onDisplay sixteen (Scroll.lineTo .middle (areaOf 10 15) (startOf rows 15)) ==
              some (some (startOf rows 8)) },
    { name :=
        "with a margin, in a view that shows its whole text, the follow keeps as many rows above the cursor's row as the margin asks and the text has, and is not capped by the text's rows: a sweep with a margin of two and one of 99, in a view taller than four lines and in one they fill exactly; and from the last of four rows as the first row shown, with the cursor on it, a margin of two shows from the second row"
      run :=
        pure <|
          let four := "a\nb\nc\nd"
          let rows := allRows four 10
          marginSweep four 10 9 2 && marginSweep four 10 9 99 && marginSweep four 10 4 2 &&
            marginSweep four 10 4 99 &&
            followedFrom four 10 9 2 (startOf rows 3) (startOf rows 3) ==
              some { moved := true, shown := rows.extract 1 4, index := some 2 } },
    { name :=
        "on the text's last line a scroll to the top leaves the view showing one row, and a scroll to the bottom from there shows as many rows as the view fits, the cursor's row the last"
      run :=
        pure <|
          let rows := allRows sixteen 10
          let last := startOf rows 15
          let top := onDisplay sixteen (Scroll.lineTo .top (areaOf 10 5) last)
          let bottom := onDisplay sixteen (Scroll.lineTo .bottom (areaOf 10 5) last)
          top == some (some last) && rowsFrom sixteen 10 5 last == rows.extract 15 16 &&
            bottom == some (some (startOf rows 11)) },
    { name :=
        "in a view that shows no row a scroll down, a scroll up and a scroll to the cursor's row each place none"
      run :=
        pure <|
          let rows := allRows sixteen 10
          let area := areaOf 10 0
          scrolledDown sixteen 10 0 (startOf rows 3) 2 == some none &&
            scrolledUp sixteen 10 0 (startOf rows 3) 2 == some none &&
            [Scroll.Place.top, .middle, .bottom].all fun place =>
              onDisplay sixteen (Scroll.lineTo place area (startOf rows 8)) == some none }]

end ModelTest
