import Editor.Api
import Editor.Clipboard
import Editor.Clipboard.Model
import Editor.Command
import Editor.Command.Model
import Editor.Display
import Editor.Display.Model
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Watch
import Editor.Watch.Model
import ModelTest.Check
import ModelTest.Support.Display
import ModelTest.Support.Models

/-!
# Model tests: `Editor/Command.lean`

The model tests of `Editor/Command.lean`: `commandPortChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

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

end ModelTest
