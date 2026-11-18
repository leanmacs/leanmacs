import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Diff.Script
import Editor.Display
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Evil.Motions
import Editor.Ex
import Editor.Ex.Line
import Editor.Face
import Editor.File
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Files
import Editor.Floating
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Job.Contract
import Editor.Job.Model
import Editor.Key.Notation
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Role
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Vocabulary
import Editor.Watch
import Editor.Watch.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Config
import ModelTest.Support.Display
import ModelTest.Support.Driver
import ModelTest.Support.Evil
import ModelTest.Support.Files
import ModelTest.Support.Geometry
import ModelTest.Support.Jobs
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.Modes
import ModelTest.Support.Prompts
import ModelTest.Support.States
import ModelTest.Support.Views
import ModelTest.Support.Vim

/-!
# Model tests: `Editor/Loop.lean`

The model tests of `Editor/Loop.lean`: `loopChecks`, `commitChecks`,
`dispatchKeyChecks`, `dispatchRollbackChecks`, `dispatchInterruptChecks`,
`dispatchSlowChecks`, `twoWindowChecks`, `dispatchStateChecks`,
`dispatchGiveUpChecks`, `dispatchCloseViewChecks`,
`dispatchMinibufferNoticeChecks`, `dispatchUndoChecks`, `dispatchReportChecks`,
`dispatchCommandGivesUpChecks`, `dispatchCommandBreaksOffChecks`,
`dispatchRunCommandChecks`, `dispatchChecks`, `modeDispatchChecks`,
`candidateChecks`, `openFilesChecks`, `dispatchQuitChecks`, `systemQuitChecks`,
`stalenessChecks`, `autoReloadChecks`, `searchDecorationChecks`, `viewChecks`
and `floatViewChecks`. `searchDecorationChecks` are of the loop's decorations
under the Vim scheme, and `modeDispatchChecks` of modes in the loop. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- A report of the scheme `switching`, unlike the default in every field
the scene shows: a block in a face of its own, one status field, an
inclusive selection, and selecting. -/
def markedReport : InputScheme.Report :=
  { cursor := { shape := .block, face := ⟨"cursor.marked"⟩ }
    status := #[{ text := "marked", face := ⟨"mode-line.state.marked"⟩ }]
    shape := .inclusive
    selecting := true }

/-- What the scheme `switching` reports of a view it was told is the
minibuffer's: an underline in a face of its own, and one status field. -/
def askedReport : InputScheme.Report :=
  { cursor := { shape := .underline, face := ⟨"cursor.asked"⟩ }
    status := #[{ text := "asked", face := ⟨"mode-line.state.asked"⟩ }] }

/-- The reports the scheme `switching` switches a view between: a command's
name, the key string a loop over it binds to that command, and what the
scheme reports of a view once a key for the view has yielded an invocation
of the command. The keys print nothing. -/
def switchingTable : List (String × String × InputScheme.Report) :=
  [("mark", "C-m", markedReport), ("plain", "C-p", {}), ("begin", "C-b", { session := true }),
    ("end", "C-e", {}), ("deafen", "C-d", { takesText := false })]

/-- A scheme written for the loop's checks, so that none of them names a
shipped scheme's states or keys: the test scheme, with a report of each
view that an invocation it yields switches (`switchingTable`). A view
starts with the default report, a view told to be the minibuffer's has
`askedReport`, and a closed view's is forgotten. Its state is the test
scheme's, and the report of each view that has one. -/
def switching : InputScheme :=
  { State := TestScheme.State × List (ViewId × InputScheme.Report)
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      match yielded.bind fun invocation => switchingTable.find? (·.1 == invocation.command) with
      | some (_, _, report) => ((next, (view, report) :: state.2.filter (·.1 != view)), yielded)
      | none => ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    roles := TestScheme.roles
    leader := TestScheme.leader
    closeView := fun view state => (state.1, state.2.filter (·.1 != view))
    openMinibuffer := fun view state => (state.1, (view, askedReport) :: state.2)
    report := fun state view => ((state.2.find? (·.1 == view)).map (·.2)).getD {} }

/-- What a step of a loop over `switching` is handed: one keymap, the same
for every view, that binds each key of `switchingTable` to its command and
each key string of `bindings` to the invocation beside it; and commands,
one that does nothing under each name of `switchingTable`, and
`commands`. -/
def switchingKeys (bindings : List (String × Invocation) := [])
    (commands : List (String × (Call → EditorM (Option Config.Write))) := []) :
    Loop.Keys switching :=
  { maps := fun _ _ =>
      [Keymap.ofList
          ((switchingTable.map fun (name, text, _) => (keys text, invoke name)) ++
            bindings.map fun (text, invocation) => (keys text, invocation))]
    command? := fun name =>
      match commands.find? (·.1 == name) with
      | some (_, command) => some command
      | none => if switchingTable.any (·.1 == name) then some fun _ => pure none else none }

/-- A loop over `switching` started from the state `start` makes and fed the
presses of the keys `text` names and then `events`, each step handed
`handed`, on the editor's models: the loop after them, the scenes the
display recorded, and the models. `none` when it was refused. -/
def switched (start : TextM EditorState) (text : String) (events : List Event := [])
    (handed : Loop.Keys switching := switchingKeys) :
    Option (Loop switching × Array Scene × EditorModel) :=
  let program : EditorM (Loop switching) := do
    let mut loop : Loop switching := { state := ← start }
    for event in (keys text).map (Event.key · true "") ++ events do
      loop := (← loop.step handed event).loop
    return loop
  match program.runModel editorModel with
  | (.ok loop, model) => some (loop, model.display.scenes, model)
  | (.error _, _) => none

/-- The checks of the loop (`Editor/Loop.lean`) on the editor's models: what
each event does to the state, and the scene it publishes. -/
def loopChecks : List Check :=
  [{  name :=
        "a resize to 641 by 479 of a frame of three windows publishes a scene whose views' rectangles and dividers tile 641 by 479 above its bottom row"
      run :=
        pure <|
          match looped threeWindows [.resize { width := 641, height := 479, scale := 2.0 }] with
          | some ((loop, nexts), scenes, _) =>
            nexts == #[.continue] && loop.state.frame.size == ⟨641, 479⟩ &&
              match scenes with
              | #[scene] =>
                -- The display model's bottom row is a pixel tall.
                scene.size == ⟨641, 479⟩ && scene.views.map (·.id) == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
                  scene.dividers.size == 2 &&
                  tiles (frameRect ⟨641, 478⟩)
                    (scene.views.map (·.rect) ++ scene.dividers.map (·.rect))
              | _ => false
          | none => false },
    { name :=
        "the scene of two tiled windows side by side has one divider, in window-divider, between the two views; of two stacked windows one divider between them"
      run :=
        pure <|
          let rect (x y width height : Nat) : Rect := { x, y, width, height }
          let stacked := Layout.splits (.split .rows 1 1 .tile .tile)
          match looped (windowsUnder 2 Layout.default) [pressF5],
            looped (windowsUnder 2 stacked) [pressF5] with
          | some ((beside, _), #[across], _), some ((above, _), #[down], _) =>
            let height := beside.state.tiled.height
            let half := above.state.tiled.height / 2
            Loop.dividerFace == ⟨"window-divider"⟩ &&
              across.views.map (·.rect) == #[rect 0 0 318 height, rect 320 0 320 height] &&
              across.dividers == #[{ rect := rect 318 0 2 height, face := Loop.dividerFace }] &&
              down.views.map (·.rect) ==
                #[rect 0 0 640 (half - 2), rect 0 half 640 (above.state.tiled.height - half)] &&
              down.dividers == #[{ rect := rect 0 (half - 2) 640 2, face := Loop.dividerFace }]
          | _, _ => false },
    { name :=
        "a scene with one window, with monocle's one view, or with a float over a single tile has no divider: none along the frame's edges and none around a float"
      run :=
        pure <|
          let monocle : TextM EditorState := windowsUnder 3 .monocle
          let floated : TextM EditorState := do
            withFloats (← windowsUnder 1 Layout.default) [(.frame, true)]
          [EditorState.initial ⟨640, 480⟩, monocle, floated].all fun start =>
            match looped start [pressF5] with
            | some (_, #[scene], _) => !scene.views.isEmpty && scene.dividers.isEmpty
            | _ => false },
    { name :=
        "a preedit publishes a scene that carries it for the focused view, and leaves the buffer's text and revision as they were"
      run :=
        pure <|
          let start : TextM EditorState := do
            let state ← threeWindows
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
            buffer.text.insert 0 "hello"
            return (state.focusWindow ⟨1⟩).2
          match looped start [.preedit "ka"] with
          | some ((loop, _), scenes, model) =>
            loop.state.preedit == some "ka" &&
              (match scenes with
              | #[scene] =>
                scene.preedit == some "ka" && scene.focused == some ⟨1⟩ &&
                  scene.views.all fun view => shownText model view == some "hello"
              | _ => false) &&
              match loop.state.buffer? ⟨0⟩ with
              | some buffer =>
                model.texts.contents == #["hello"] &&
                  (model.texts.texts[buffer.text.index]?).join.map (·.revision) == some 1
              | none => false
          | none => false },
    { name :=
        "an empty preedit and the input method going away each clear the preedit; enabling it changes nothing"
      run :=
        pure <|
          match
            looped (EditorState.initial ⟨640, 480⟩)
              [.preedit "k", .preedit "", .preedit "ka", .compositionDisabled, .preedit "s",
                .compositionEnabled] with
          | some (_, scenes, _) =>
            scenes.map (·.preedit) == #[some "k", none, some "ka", none, some "s", some "s"]
          | none => false },
    { name :=
        "while the frame does not have the keyboard focus its scene names no focused view, and once it has it again the focused one"
      run :=
        pure <|
          match looped threeWindows [.focus false, .focus true] with
          | some (_, scenes, _) => scenes.map (·.focused) == #[none, some ⟨0⟩]
          | none => false },
    { name :=
        "a press of a key that is bound to nothing and prints nothing, a pointer and the window opening leave the state as it was, but for the heights the display answered, and each publishes one scene"
      run :=
        pure <|
          let events : List Event :=
            [pressF5, .pointer { action := .press, x := 3.0, y := 4.0, button := some .primary },
              .windowOpened "headless"]
          let start : EditorM (EditorState × TestLoop × Array Loop.Next) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let (loop, nexts) ← stepsFrom (pure state) events
            return (state, loop, nexts)
          match (start.runModel editorModel) with
          | (.ok (state, loop, nexts), model) =>
            loop.state == { state with heights := editorModel.display.cells.heights } &&
              nexts == #[.continue, .continue, .continue] &&
              model.display.scenes.size == 3
          | (.error _, _) => false },
    { name :=
        "a parse delivered leaves the state as it was, but for the heights the display answered, and publishes one scene"
      run :=
        pure <|
          let start : EditorM (EditorState × TestLoop × Array Loop.Next) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let (loop, nexts) ← stepsFrom (pure state) [.parsed]
            return (state, loop, nexts)
          match (start.runModel editorModel) with
          | (.ok (state, loop, nexts), model) =>
            loop.state == { state with heights := editorModel.display.cells.heights } &&
              nexts == #[.continue] &&
              model.display.scenes.size == 1
          | (.error _, _) => false },
    { name :=
        "a queue's quit says stop and publishes nothing; a close request on a state with nothing unsaved publishes one scene and says stop"
      run :=
        pure <|
          (match looped threeWindows [.closeRequested] with
            | some ((_, nexts), scenes, _) => nexts == #[.stop] && scenes.size == 1
            | none => false) &&
            match looped threeWindows [.quit] with
            | some ((_, nexts), scenes, _) => nexts == #[.stop] && scenes.isEmpty
            | none => false },
    { name :=
        "a view whose text has not changed keeps its snapshot from one scene to the next, and two views of one buffer share it"
      run :=
        pure <|
          match looped threeWindows [pressF5, pressF5] with
          | some (_, #[first, second], model) =>
            first.views.map (·.snapshot) == second.views.map (·.snapshot) &&
              (first.views.map (·.snapshot)).toList.eraseDups.length == 1 &&
              second.views.all fun view => shownText model view == some ""
          | _ => false },
    { name :=
        "a view shows its window's scroll anchor and selection marker, a bar cursor in the face cursor, no decorations, and the shipped mode line of its window: the focused one's row in mode-line.active, and each other one's fields and row in mode-line.inactive"
      run :=
        pure <|
          match looped threeWindows [pressF5] with
          | some ((loop, _), #[scene], _) =>
            scene.views.map (·.scroll) == loop.state.windows.map (·.scroll) &&
              scene.views.map (·.selections) == loop.state.windows.map (#[·.selection]) &&
              (scene.views.all fun view =>
                view.cursor == { shape := .bar, face := ⟨"cursor"⟩ } && view.decorations.isEmpty) &&
              scene.views.map (·.status) ==
                #[modeLineOf, modeLineOf (selected := false), modeLineOf (selected := false)] &&
              scene.views.map (·.statusFace) ==
                #[some ModeLine.activeFace, some ModeLine.inactiveFace, some ModeLine.inactiveFace]
          | _ => false },
    { name :=
        "two windows on one buffer under the Vim scheme: the focused one's mode line has the NORMAL badge and its row in mode-line.active, and the other's has no badge, every field and its row in mode-line.inactive"
      run :=
        pure <|
          let program : EditorM (Loop Vim.Default.scheme) := do
            let loop : Loop Vim.Default.scheme := { state := ← threeWindows }
            return (← loop.step {} pressF5).loop
          match program.runModel editorModel with
          | (.ok _, model) =>
            let badge := #[{ text := "NORMAL", face := Vim.stateFace "normal" }]
            match model.display.scenes with
            | #[scene] =>
              scene.views.map (·.status) ==
                  #[modeLineOf (reported := badge), modeLineOf (selected := false),
                    modeLineOf (selected := false)] &&
                scene.views.map (·.statusFace) ==
                  #[some ModeLine.activeFace, some ModeLine.inactiveFace,
                    some ModeLine.inactiveFace] &&
                (modeLineOf (reported := badge))[0]? ==
                  some { text := "NORMAL", face := ⟨"mode-line.state.normal"⟩, padding := 8 }
            | _ => false
          | (.error _, _) => false },
    { name :=
        "the scene's status lines are drawn by the mode line the step's keys carry, in its order and on its sides"
      run :=
        pure <|
          let handed : Loop.Keys TestScheme.scheme :=
            { modeLine := { left := #[ModeLine.position], right := #[ModeLine.buffer] } }
          let program : EditorM TestLoop := do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            return (← loop.step handed (.commit "ab\ncd")).loop
          match program.runModel editorModel with
          | (.ok _, model) =>
            model.display.scenes.map (·.views.map (·.status)) ==
              #[#[#[{ text := "Bot", face := ModeLine.secondaryFace, padding := 4 },
                    { text := "scratch", face := ModeLine.bufferFace, side := .right,
                      padding := 4 }]]]
          | (.error _, _) => false },
    { name :=
        "a view's mode line reads its cursor from its selection in the view's snapshot, as a row and a column in the text port's cells, and its rows less an empty last row after a final line break"
      run :=
        pure <|
          let program : EditorM TestLoop := do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            let loop := (← loop.step {} (.commit "ab\ncd")).loop
            return (← loop.step {} (.commit "\n")).loop
          match program.runModel editorModel with
          | (.ok _, model) =>
            model.display.scenes.map (·.views.map (·.status)) ==
                #[#[modeLineOf (modified := true) (cursor := some ⟨1, 2⟩) (lines := 2)],
                  #[modeLineOf (modified := true) (cursor := some ⟨2, 0⟩) (lines := 2)]] &&
              (modeLineOf (cursor := some ⟨1, 2⟩) (lines := 2)).map (·.text) ==
                #["scratch", "2:3", "Bot"]
          | (.error _, _) => false },
    { name :=
        "a view's status line carries the modified mark while its buffer is modified, and not otherwise: the first scene's views have the name alone on the left, after a commit each view of the buffer has the name and then the modified mark, in the modified face in the focused view, and after a key whose command undoes the commit each has the name alone again"
      run :=
        pure <|
          let undoKeys : Loop.Keys TestScheme.scheme :=
            { maps := fun _ _ => [Keymap.ofList [(keys "C-z", invoke "undo")]]
              command? := fun name =>
                if name == "undo" then
                  some fun call => do
                    discard <| call.target.window.buffer.undo
                    return none
                else none }
          let program : EditorM TestLoop := do
            let mut loop : TestLoop := { state := ← threeWindows }
            for event in [pressF5, .commit "x"] ++ (keys "C-z").map (Event.key · true "") do
              loop := (← loop.step undoKeys event).loop
            return loop
          match program.runModel editorModel with
          | (.ok loop, model) =>
            match loop.state.buffer? ⟨0⟩ with
            | none => false
            | some buffer =>
              let texts (status : Array StatusField) := (leftOf status).map (·.text)
              model.texts.contents == #[""] &&
                model.display.scenes.map (fun scene => scene.views.map (texts ·.status)) ==
                  #[.replicate 3 #[buffer.name], .replicate 3 #[buffer.name, ModeLine.modifiedMark],
                    .replicate 3 #[buffer.name]] &&
                (model.display.scenes[1]?.bind (·.views[0]?)).map (leftOf ·.status) ==
                  some
                    #[ModeLine.field buffer.name ModeLine.bufferFace,
                      ModeLine.field ModeLine.modifiedMark ModeLine.modifiedFace]
          | (.error _, _) => false },
    { name :=
        "a commit once the focused buffer's text was released is not refused: it publishes a scene with the refusal in its echo and no view of that buffer, and the loop keeps the state as it was, well formed, with that echo"
      run :=
        pure <|
          let program : EditorM (EditorState × TestLoop × Loop.Next) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchMarker
            target.buffer.text.release
            let (loop, next) ← stepped { state } (.commit "x")
            return (state, loop, next)
          match program.runModel editorModel with
          | (.ok (state, loop, next), model) =>
            next == .continue &&
              loop.state ==
                { state with
                  echo := "refused: no such text", heights := editorModel.display.cells.heights } &&
              loop.state.wellFormed &&
              loop.shown.isEmpty &&
              match model.display.scenes with
              | #[scene] =>
                scene.echo == "refused: no such text" && scene.views.isEmpty &&
                  scene.size == ⟨640, 480⟩ &&
                  scene.focused == some ⟨0⟩
              | _ => false
          | (.error _, _) => false },
    { name :=
        "an event that changes nothing, once one buffer's text was released, publishes a scene with the refusal in its echo and the other buffer's view, and the other buffer's history is still recorded"
      run :=
        pure <|
          let program : EditorM (EditorState × TestLoop × String) := do
            let state ← twoBuffers
            let some gone := state.buffer? ⟨0⟩ | throw .noSuchMarker
            let some other := state.buffer? ⟨1⟩ | throw .noSuchMarker
            gone.text.release
            other.text.insert 5 "!"
            let (loop, _) ← stepped { state } pressF5
            -- The loop recorded the insertion in the other buffer's history:
            -- one undo of it takes the insertion back.
            let some kept := loop.state.buffer? ⟨1⟩ | throw .noSuchMarker
            let some _ ← kept.history.undo | throw .noInverse
            return (state, loop, ← other.text.read)
          match program.runModel editorModel with
          | (.ok (state, loop, undone), model) =>
            undone == "other" && loop.state.wellFormed &&
              loop.state.echo == "refused: no such text" &&
              loop.state.buffers[0]? == state.buffers[0]? &&
              loop.state.windows == state.windows &&
              loop.state.frame == state.frame &&
              match model.display.scenes with
              | #[scene] =>
                scene.echo == "refused: no such text" && scene.views.map (·.id) == #[⟨1⟩] &&
                  scene.views.all fun view => shownText model view == some "other!"
              | _ => false
          | (.error _, _) => false },
    { name :=
        "a released text no window shows still puts its refusal in the scene's echo, with every view shown; so does a view's text that refuses when no history did, and that view is left out"
      run :=
        pure <|
          let hidden : EditorM TestLoop := do
            let state ← EditorState.initial ⟨640, 480⟩
            let text ← createText "hidden"
            let history ← UndoTree.over text
            text.release
            let state :=
              { state with
                buffers := state.buffers.push (some { name := "hidden", text, history }) }
            return (← stepped { state } pressF5).1
          -- A buffer whose history is over another text than its own: the
          -- history is recorded, and only the view is refused.
          let astray : EditorM TestLoop := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchMarker
            let history ← UndoTree.over (← createText "elsewhere")
            buffer.text.release
            let state := { state with buffers := #[some { buffer with history }] }
            return (← stepped { state } pressF5).1
          (match hidden.runModel editorModel with
            | (.ok loop, model) =>
              loop.state.echo == "refused: no such text" &&
                match model.display.scenes with
                | #[scene] =>
                  scene.echo == "refused: no such text" && scene.views.map (·.id) == #[⟨0⟩]
                | _ => false
            | (.error _, _) => false) &&
            match astray.runModel editorModel with
            | (.ok loop, model) =>
              loop.state.echo == "refused: no such text" && loop.shown.isEmpty &&
                match model.display.scenes with
                | #[scene] => scene.echo == "refused: no such text" && scene.views.isEmpty
                | _ => false
            | (.error _, _) => false },
    { name :=
        "when a snapshot the last scene named was released behind the loop, the next scene is still published and the loop keeps the new snapshot; the refusal of its release is in the state's echo, and in the scene after"
      run :=
        pure <|
          let program : EditorM (TestLoop × String × Bool) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "a")).1
            let some first := loop.shown[0]? | throw .noSuchMarker
            first.snapshot.release
            loop := (← stepped loop (.commit "b")).1
            let some second := loop.shown[0]? | throw .noSuchMarker
            let shown ← second.snapshot.read
            let echoed := loop.state.echo == "refused: no such snapshot"
            loop := (← stepped loop pressF5).1
            return (loop, shown, echoed && first.snapshot != second.snapshot)
          match program.runModel editorModel with
          | (.ok (loop, shown, echoed), model) =>
            echoed && shown == "ab" && loop.state.wellFormed && loop.shown.size == 1 &&
              model.display.scenes.map (·.echo) == #["", "", "refused: no such snapshot"]
          | (.error _, _) => false },
    { name :=
        "a message from a key's command is in the echo area of the scene published after it, the last of two when the command sent two; a key that yields nothing leaves it, and the next invocation clears it"
      run :=
        pure <|
          let say (texts : List String) (_ : Call) : EditorM (Option Config.Write) := do
            for text in texts do
              message text
            return none
          let handed : Loop.Keys TestScheme.scheme :=
            { maps := fun _ _ =>
                [Keymap.ofList
                    [(keys "C-c m", invoke "say"), (keys "C-c t", invoke "twice"),
                      (keys "C-c q", invoke "quiet")]]
              command? := fun name =>
                ([("say", say ["hi"]), ("twice", say ["first", "second"]), ("quiet", say [])].find?
                      (·.1 == name)).map
                  (·.2) }
          let program : EditorM TestLoop := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            let pressed (text : String) : List Event := (keys text).map (.key · true "")
            for event in pressed "C-c m" ++ [pressF5] ++ pressed "C-c t C-c q" do
              loop := (← loop.step handed event).loop
            return loop
          match program.runModel editorModel with
          | (.ok loop, model) =>
            loop.state.echo == "" &&
              model.display.scenes.map (·.echo) == #["", "hi", "hi", "hi", "second", "second", ""]
          | (.error _, _) => false },
    { name :=
        "with a prompt open the scene has the minibuffer's view after the window's, in the rectangles the tree gives with that view: its snapshot is the minibuffer's text, its scroll anchor and selection are its window's markers, its status line is one field, the label in the prompt's face, with no status face, and it is the focused view; the window's status line is still its buffer's name, its row in mode-line.active, since it asked"
      run :=
        pure <|
          match looped (promptedOver "ab") [pressF5] with
          | some ((loop, _), #[scene], model) =>
            let state := loop.state
            match scene.views, state.window? ⟨1⟩ with
            | #[window, minibuffer], some held =>
              window.id == ⟨0⟩ && minibuffer.id == ⟨1⟩ && shownText model minibuffer == some "ab" &&
                shownText model window == some "" &&
                minibuffer.scroll == held.scroll &&
                minibuffer.selections == #[held.selection] &&
                minibuffer.status == #[{ text := "Name: ", face := Loop.promptFace }] &&
                window.status == modeLineOf &&
                window.statusFace == some ModeLine.activeFace &&
                minibuffer.statusFace == none &&
                Loop.promptFace != ModeLine.bufferFace &&
                scene.focused == some ⟨1⟩ &&
                scene.views.map (fun view => (view.id, view.rect)) == state.rects &&
                (scene.views.all fun view => state.rect? view.id == some view.rect) &&
                tiles (frameRect state.frame.size) (scene.views.map (·.rect))
            | _, _ => false
          | _ => false },
    { name :=
        "a text committed while a prompt is open is inserted in the minibuffer: its view shows the text so far, and the window's text is as it was"
      run :=
        pure <|
          match looped (promptedOver "ab") [.commit "c"] with
          | some (_, #[scene], model) => scene.views.map (shownText model) == #[some "", some "abc"]
          | _ => false },
    { name :=
        "once the prompt is closed the next scene has one view, the window's, which has the frame above its bottom row"
      run :=
        pure <|
          let program : EditorM TestLoop := do
            let (loop, _) ← stepsFrom (promptedOver "ab") [pressF5]
            let (_, closed) := loop.state.closePrompt none
            return (← stepped { loop with state := closed } pressF5).1
          -- The display model's rows are a pixel tall: the prompt's place is
          -- two, and the bottom row one.
          match program.runModel editorModel with
          | (.ok _, model) =>
            model.display.scenes.map (·.views.map fun view => (view.id, view.rect)) ==
              #[#[(⟨0⟩, frameRect ⟨640, 478⟩),
                  (⟨1⟩, { x := 0, y := 478, width := 640, height := 2 })],
                #[(⟨0⟩, frameRect ⟨640, 479⟩)]]
          | (.error _, _) => false },
    { name :=
        "each view's cursor in the scene is what the scheme reports of that view: the default before a key, and, in the scene published after the key whose invocation switches the focused view's report, the switched one for that view and the default still for the others; a key that switches it back is followed by the default again"
      run :=
        pure <|
          match switched threeWindows "<F5> C-m C-p" with
          | some (_, #[first, marked, plain], _) =>
            let plainCursor : Cursor := ({} : InputScheme.Report).cursor
            first.views.map (·.cursor) == #[plainCursor, plainCursor, plainCursor] &&
              marked.views.map (·.cursor) == #[markedReport.cursor, plainCursor, plainCursor] &&
              plain.views.map (·.cursor) == #[plainCursor, plainCursor, plainCursor] &&
              markedReport.cursor != plainCursor
          | _ => false },
    { name :=
        "the focused view's status line is the shipped mode line with the fields the scheme reports of it as its badge, and the modified mark while the buffer is modified; the other views have no badge, whatever the scheme reports of them"
      run :=
        pure <|
          match switched threeWindows "C-m" [.commit "x"] with
          | some (_, #[marked, modified], _) =>
            let other := modeLineOf (selected := false)
            marked.views.map (·.status) ==
                #[modeLineOf (reported := markedReport.status), other, other] &&
              (modified.views[0]?.map (·.status)) ==
                some
                  (modeLineOf (modified := true) (cursor := some ⟨0, 1⟩) (reported :=
                    markedReport.status)) &&
              (modified.views.extract 1).map (leftOf ·.status) ==
                .replicate 2 (leftOf (modeLineOf (modified := true) (selected := false))) &&
              markedReport.status.size == 1
          | _ => false },
    { name :=
        "while a prompt is open the minibuffer's view has the cursor the scheme reports of it, and its status line is the prompt's label alone, with none of the scheme's fields; the asking view keeps its own report"
      run :=
        pure <|
          let ask : Call → EditorM (Option Config.Write) := fun _ => do
            discard <| prompt "Name: " asked
            return none
          match
            switched (EditorState.initial ⟨640, 480⟩) "C-m C-a" (handed :=
              switchingKeys [("C-a", invoke "ask")] [("ask", ask)]) with
          | some (_, #[_, scene], _) =>
            scene.views.map (·.cursor) == #[markedReport.cursor, askedReport.cursor] &&
              scene.views.map (·.status) ==
                #[modeLineOf (reported := markedReport.status),
                  #[{ text := "Name: ", face := Loop.promptFace }]] &&
              scene.views.map (·.statusFace) == #[some ModeLine.activeFace, none] &&
              !askedReport.status.isEmpty
          | _ => false },
    { name :=
        "a loop is started with its first window's selection of the shape its scheme reports of the first view before any key: an inclusive cursor under a scheme that reports one, and an exclusive one under a scheme that says nothing"
      run :=
        pure <|
          let inclusive : InputScheme :=
            { TestScheme.scheme with
              report := fun _ view => if view == ⟨0⟩ then { shape := .inclusive } else {} }
          let cursor (scheme : InputScheme) : Option Marker :=
            onTextModel do
              let loop ← Loop.start scheme ⟨640, 480⟩
              let some target := loop.state.focusedTarget? | throw .noSuchText
              target.buffer.text.marker target.window.selection
          cursor inclusive == some (.selection { ranges := #[⟨0, 0⟩], shape := .inclusive }) &&
            cursor TestScheme.scheme ==
              some (.selection { ranges := #[⟨0, 0⟩], shape := .exclusive }) }]

/-- The ranges of the focused window's selection marker in `loop`'s state. -/
def cursorsOf (loop : TestLoop) : EditorM (Array SelectionRange) := do
  let target ← focusedOf loop
  let .selection selection ← target.buffer.text.marker target.window.selection | throw .noSuchMarker
  return selection.ranges

/-- A scheme written for the commit checks: the test scheme, which keeps
what it is told was committed, the newest first, and says of every view
that it takes text or that it takes none, as `takesText` says. -/
def telling (takesText : Bool) : InputScheme :=
  { State := TestScheme.State × List (ViewId × String)
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    committed := fun view text state => (state.1, (view, text) :: state.2)
    report := fun _ _ => { takesText } }

/-- The checks of a text commit in the loop, on the editor's models. -/
def commitChecks : List Check :=
  [{  name :=
        "commits of a, b and c publish one scene each, whose focused view shows the text so far, with the window's cursor just after what was committed"
      run :=
        pure <|
          let program : EditorM (Array (SnapshotId × String × Array SelectionRange)) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            let mut seen := #[]
            for text in ["a", "b", "c"] do
              loop := (← stepped loop (.commit text)).1
              let some shown := loop.shown[0]? | throw .noSuchSnapshot
              seen := seen.push (shown.snapshot, ← shown.snapshot.read, ← cursorsOf loop)
            return seen
          match program.runModel editorModel with
          | (.ok seen, model) =>
            let scenes := model.display.scenes
            seen.map (·.2) == #[("a", #[⟨1, 1⟩]), ("ab", #[⟨2, 2⟩]), ("abc", #[⟨3, 3⟩])] &&
              scenes.size == 3 &&
              (scenes.zip seen).all fun (scene, (snapshot, _)) =>
                scene.focused == some ⟨0⟩ &&
                  (scene.views.find? (·.id == ⟨0⟩)).map (·.snapshot) == some snapshot
          | (.error _, _) => false },
    { name :=
        "after a commit, one undo of the buffer's history, as the loop left it, restores the text from before the commit, and the commit was the user's"
      run :=
        pure <|
          let program : EditorM (String × String × String × Array Attribution) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "hello")).1
            loop := (← stepped loop (.commit " world")).1
            let target ← focusedOf loop
            let before ← target.buffer.text.read
            let some moved ← target.buffer.history.undo | throw .noInverse
            let once ← target.buffer.text.read
            let trace ← target.buffer.text.trace 0 5
            let some _ ← moved.tree.undo | throw .noInverse
            return (before, once, ← target.buffer.text.read, trace)
          match (program.runModel editorModel).1 with
          | .ok (before, once, twice, trace) =>
            before == "hello world" && once == "hello" && twice == "" &&
              trace == #[{ start := 0, stop := 5, author := .entry 1 Origin.user }]
          | .error _ => false },
    { name :=
        "a commit replaces what each range of the selection covers, and leaves a cursor after each insertion"
      run :=
        pure <|
          let program : EditorM (String × Array SelectionRange) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨0, 1⟩, ⟨3, 3⟩] }
            let (loop, _) ← stepped loop (.commit "xy")
            return (← (← focusedOf loop).buffer.text.read, ← cursorsOf loop)
          match (program.runModel editorModel).1 with
          | .ok (text, cursors) => text == "xybcxyd" && cursors == #[⟨2, 2⟩, ⟨6, 6⟩]
          | .error _ => false },
    { name :=
        "a commit whose selection marker was given up leaves the state as it was, with the refusal in the echo area"
      run :=
        pure <|
          let program : EditorM (EditorState × TestLoop × Option String) := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchText
            target.buffer.text.unmark target.window.selection
            let (loop, _) ← stepped { state } (.commit "x")
            return (state, loop, ← target.buffer.text.read)
          match program.runModel editorModel with
          | (.ok (state, loop, text), model) =>
            loop.state ==
                { state with
                  echo := "refused: no such marker",
                  heights := editorModel.display.cells.heights } &&
              text == "" &&
              (model.display.scenes.map (·.echo)) == #["refused: no such marker"]
          | (.error _, _) => false },
    { name :=
        "after a commit the snapshot the previous scene named is released, and asking it is refused with noSuchSnapshot"
      run :=
        pure <|
          let program : EditorM (SnapshotId × SnapshotId × Bool) := do
            let mut loop ← Loop.start TestScheme.scheme ⟨640, 480⟩
            loop := (← stepped loop (.commit "a")).1
            let some first := loop.shown[0]? | throw .noSuchSnapshot
            loop := (← stepped loop (.commit "b")).1
            let some second := loop.shown[0]? | throw .noSuchSnapshot
            let refused ←
              try
                discard first.snapshot.read
                pure false
              catch refusal =>
                pure (refusal == .noSuchSnapshot)
            return (first.snapshot, second.snapshot, refused)
          match (program.runModel editorModel).1 with
          | .ok (first, second, refused) => first != second && refused
          | .error _ => false },
    { name := "a commit clears the preedit"
      run :=
        pure <|
          match looped (EditorState.initial ⟨640, 480⟩) [.preedit "k", .commit "か"] with
          | some ((loop, _), scenes, _) =>
            scenes.map (·.preedit) == #[some "k", none] && loop.state.preedit == none
          | none => false },
    { name :=
        "a text committed where the scheme reports that the focused view takes no text is not inserted: the text and the selection are as they were, and the preedit is cleared all the same"
      run :=
        pure <|
          match switched (holding "abcd" #[⟨1, 3⟩]) "C-d" [.preedit "ka", .commit "x"] with
          | some (loop, scenes, model) =>
            let selection :=
              loop.state.focusedTarget?.bind fun target =>
                (target.selection.runModel model.texts).1.toOption
            model.texts.contents == #["abcd"] && selection.map (·.ranges) == some #[⟨1, 3⟩] &&
              loop.state.preedit == none &&
              scenes.map (·.preedit) == #[none, some "ka", none]
          | none => false },
    { name :=
        "once the scheme reports that the focused view takes text again, a committed text replaces what the selection covers, as under a scheme that says nothing"
      run :=
        pure <|
          let events : List Event :=
            [.commit "x"] ++ (keys "C-p").map (Event.key · true "") ++ [.commit "y"]
          match switched (holding "abcd" #[⟨1, 3⟩]) "C-d" events with
          | some (_, _, model) => model.texts.contents == #["ayd"]
          | none => false },
    { name :=
        "the loop tells the scheme of a committed text it inserted, for the focused view, in both states of the scheme it keeps; a commit that is dropped, where the scheme says the view takes no text, is not told; and the test scheme's notice changes nothing"
      run :=
        pure <|
          let told (takesText : Bool) :
            Option (List (ViewId × String) × List (ViewId × String) × Array String) :=
            let program : EditorM (Loop (telling takesText)) := do
              let mut loop ← Loop.start (telling takesText) ⟨640, 480⟩
              for event in [Event.commit "ab", .preedit "k", .commit "c"] do
                loop := (← loop.step {} event).loop
              return loop
            match program.runModel editorModel with
            | (.ok loop, model) =>
              let input : TestScheme.State × List (ViewId × String) := loop.input
              let atRest : TestScheme.State × List (ViewId × String) := loop.atRest
              some (input.2, atRest.2, model.texts.contents)
            | (.error _, _) => none
          told true == some ([(⟨0⟩, "c"), (⟨0⟩, "ab")], [(⟨0⟩, "c"), (⟨0⟩, "ab")], #["abc"]) &&
            told false == some ([], [], #[""]) &&
            (TestScheme.scheme.pending
                (TestScheme.scheme.committed ⟨0⟩ "x" TestScheme.scheme.init)).isEmpty }]

/-- The pending keys each scene of a run showed; none of them when the run
was refused. -/
def pendingShown (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) : Array String :=
  match dispatched keys events start with
  | some (_, scenes, _) => scenes.map (·.pending)
  | none => #[]

/-- What the last scene of a run showed: its echo, its pending keys, and the
text of each of its views. `none` when the run was refused or published
nothing. -/
def lastScene (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩)
    (model : EditorModel := editorModel) : Option (String × String × Array (Option String)) :=
  match dispatched keys events start model with
  | some (_, scenes, model) =>
    scenes.back?.map fun scene => (scene.echo, scene.pending, scene.views.map (shownText model))
  | none => none

/-- The checks of keys in the loop (`Editor/Loop.lean`), on the editor's
models and the test scheme, with keymaps written here: which keys are
stepped through the scheme, the pending keys the scene shows, and the
command a completed sequence runs. -/
def dispatchKeyChecks : List Check :=
  let saves := dispatchKeys [("C-x C-s", invoke "save"), ("C-x r t", invoke "rectangle")]
  [{  name :=
        "after the first key of a bound sequence the scene shows it as pending, after each further key of a longer one the keys so far, and after the key that completes the sequence none"
      run :=
        pure
          (pendingShown saves (presses "C-x C-s") == #["C-x", ""] &&
            pendingShown saves (presses "C-x r t") == #["C-x", "C-x r", ""]) },
    { name :=
        "after a prefix and then a key that goes on with no binding, the scene shows no pending keys, and the sequence typed next is pending from its first key again"
      run :=
        pure
          (pendingShown saves (presses "C-x" ++ [pressF5] ++ presses "C-x") ==
            #["C-x", "", "C-x"]) },
    { name :=
        "a key release, and a press and a release of a modifier key by itself, between two keys of a sequence are not stepped: the prefix is still pending after each"
      run :=
        let shift : Key :=
          { logical := .named ⟨"Shift"⟩, physical := .code "ShiftLeft",
            modifiers := { shift := true } }
        let between : List Event :=
          [.key (controlKey "x") false "", press shift,
            .key { shift with modifiers := {} } false ""]
        pure
          (pendingShown saves (presses "C-x" ++ between ++ presses "r") ==
            #["C-x", "C-x", "C-x", "C-x", "C-x r"]) },
    { name :=
        "a press the platform repeated is stepped like any press, and a key from a window is taken by its chord"
      run :=
        let held : Key :=
          { controlKey "x" with
            physical := .code "KeyX", repeated := true }
        pure (pendingShown saves [press held] == #["C-x"]) },
    { name :=
        "a key is for the focused view: it is looked up in that view's keymaps, and in no other's"
      run :=
        let onlyFirst : Loop.Keys TestScheme.scheme :=
          { maps := fun state view => if view == ⟨1⟩ then saves.maps state view else [] }
        let focusedOn (view : ViewId) : TextM EditorState := do
          return ((← threeWindows).focusWindow view).2
        pure
          (pendingShown onlyFirst (presses "C-x") (focusedOn ⟨1⟩) == #["C-x"] &&
            pendingShown onlyFirst (presses "C-x") (focusedOn ⟨0⟩) == #[""]) },
    { name :=
        "a modifier key by itself is each named key of the W3C modifier names, with or without modifiers held, and no other key: not a character with shift held, and not another named key"
      run :=
        pure
          (["Shift", "Control", "Alt", "AltGraph", "Meta", "Super", "Hyper", "CapsLock", "NumLock",
                  "ScrollLock", "Fn", "FnLock", "Symbol", "SymbolLock"].all
              (fun name =>
                (namedKey ⟨name⟩).isModifier &&
                  (namedKey ⟨name⟩ { shift := true, control := true }).isModifier) &&
            !(charKey "A" { shift := true }).isModifier &&
            !(namedKey .escape).isModifier &&
            !(namedKey ⟨"F5"⟩).isModifier &&
            !({ logical := .dead none } : Key).isModifier &&
            !({ logical := .unidentified } : Key).isModifier) },
    { name :=
        "a bound key sequence runs its command once, with the count the binding gives and the keys typed: the scene after the prefix shows the text unchanged, the scene after the last key shows the command's effect, and a further key that is bound to nothing adds nothing"
      run :=
        let keys :=
          dispatchKeys [("C-x i", { command := "stamp", arguments := [.nat 3] })] [("stamp", stamp)]
        pure
          (lastScene keys (presses "C-x") == some ("", "C-x", #[some ""]) &&
            lastScene keys (presses "C-x i") == some ("", "", #[some "3 C-x i"]) &&
            lastScene keys (presses "C-x i" ++ [pressF5]) == some ("", "", #[some "3 C-x i"])) },
    { name :=
        "a command is handed the focused window and its buffer, the arguments of the invocation in order, and every key of the sequence as a chord, though the keys came from a window with their physical codes"
      run :=
        let seen : Dispatched := fun call => do
          let editor := (← call.target.buffer.text.read)
          makes
              s!"{call.target.window.id.index} {call.target.buffer.name} {editor.length} {calledWith call}"
          return none
        let keys :=
          dispatchKeys
            [("C-x r t", { command := "seen", arguments := [.str "w", .int (-2), .bool true] })]
            [("seen", seen)]
        let fromWindow : List Event :=
          (Editor.Key.parse "C-x r t" |>.toOption.getD []).map fun key =>
            press
              { key with
                physical := .code "KeyQ", repeated := true }
        let focusedOn : TextM EditorState := do
          return ((← threeWindows).focusWindow ⟨2⟩).2
        pure <|
          match dispatched keys fromWindow focusedOn with
          | some (_, _, model) => model.texts.contents.back? == some "2 scratch 0 w -2 true C-x r t"
          | none => false },
    { name :=
        "an invocation of a name no command is registered under says so in the echo area, and the next key is handled: a key that yields nothing leaves the echo, and the next command that runs clears it"
      run :=
        let keys :=
          dispatchKeys [("C-c n", invoke "nope"), ("C-c s", invoke "stamp")] [("stamp", stamp)]
        pure
          (lastScene keys (presses "C-c n") == some ("nope: no such command", "", #[some ""]) &&
            lastScene keys (presses "C-c n" ++ [pressF5] ++ presses "C-c") ==
              some ("nope: no such command", "C-c", #[some ""]) &&
            lastScene keys (presses "C-c n C-c s") == some ("", "", #[some "C-c s"])) },
    { name :=
        "a key bound to a registered command, in a state whose focused window is not in the state, says in the echo area that no window is focused: the command makes no request, and nothing is left pending"
      run :=
        let made : Dispatched := fun _ => do
          discard <| createText "made"
          return none
        let keys := dispatchKeys [("C-c m", invoke "made")] [("made", made)]
        let unfocused : TextM EditorState := do
          let state ← EditorState.initial ⟨640, 480⟩
          return { state with frame := { state.frame with focused := ⟨9⟩ } }
        pure <|
          match dispatched keys (presses "C-c m") unfocused with
          | some ((loop, _), scenes, model) =>
            loop.state.echo == "made: no window is focused" &&
              scenes.back?.map (·.echo) == some "made: no window is focused" &&
              model.texts.contents == #[""] &&
              loop.pending == "" &&
              scenes.back?.map (·.pending) == some ""
          | none => false },
    { name :=
        "a command that is refused says so in the echo area, with its name and the refusal, and the step is not refused: the next key runs its command"
      run :=
        let gone : Dispatched := fun _ => do
          (⟨7⟩ : TextId).insert 0 "x"
          return none
        let keys :=
          dispatchKeys [("C-c g", invoke "gone"), ("C-c s", invoke "stamp")]
            [("gone", gone), ("stamp", stamp)]
        pure
          (lastScene keys (presses "C-c g") ==
              some ("gone: refused: no such text", "", #[some ""]) &&
            lastScene keys (presses "C-c g C-c s") == some ("", "", #[some "C-c s"])) },
    { name :=
        "under the test scheme a key that prints and is bound to nothing yields its self-insert, which no command is registered under: the echo area says so"
      run :=
        pure
          (lastScene (dispatchKeys []) (presses "a") ==
            some ("self-insert: no such command", "", #[some ""])) },
    { name :=
        "a step hands back what the command it ran asked to be written, and nothing for a step that ran no command or whose command was refused"
      run :=
        let writes : Dispatched := fun _ =>
          return some { owner := .config, store := "counter", value := .nat 5 }
        let refuses : Dispatched := fun _ => do
          (⟨7⟩ : TextId).insert 0 "x"
          return some { owner := .config, store := "counter", value := .nat 9 }
        let keys :=
          dispatchKeys [("C-c w", invoke "writes"), ("C-c r", invoke "refuses")]
            [("writes", writes), ("refuses", refuses)]
        pure <|
          match dispatched keys (presses "C-c w C-c r" ++ [pressF5, .focus true]) with
          | some ((_, steps), _, _) =>
            steps.map
                (fun step =>
                  step.write.map fun write => (write.owner.name, write.store, write.value)) ==
              #[none, some ("config", "counter", Value.nat 5), none, none, none, none]
          | none => false }]

/-- `hiddenBuffer`'s state with the buffer `hidden`, which no window shows,
holding a file: a buffer a save can be begun for. -/
def savable : TextM EditorState := do
  let (state, _) ← hiddenBuffer
  return (state.attachFile ⟨2⟩ notePath noteStamp .lf).2

/-- The save in flight of the buffer `hidden` of `savable`, in `state`. -/
def savingOf (state : EditorState) : Option Buffer.Saving :=
  ((state.buffer? ⟨2⟩).bind (·.file)).bind (·.saving)

/-- The commands of the checks of a save in flight, on `savable`, bound
under `C-c`. `begin` (`g`) takes a snapshot of the buffer's text and begins
a save of it, with the state the buffer's history is in. `end` (`e`) ends
the save in flight with a stamp, as a save that wrote the file does, and
`unsaved` (`n`) with none, as one that was refused does. `remove` (`r`)
removes the buffer. `fail` (`f`) ends the save with a stamp and is then
refused. `twice` (`t`) releases the save's snapshot itself and then ends
the save. -/
def saveKeys : Loop.Keys TestScheme.scheme :=
  let ends (stamp : Option File.Stamp) (first : SnapshotId → EditorM Unit := fun _ => pure ()) :
    EditorM Unit := do
    let some saving := savingOf (← editorState) | throw .noSuchSnapshot
    first saving.snapshot
    discard <| EditorState.ask (.endSave ⟨2⟩ saving.snapshot stamp)
  let later : File.Stamp :=
    { noteStamp with
      seconds := 9, size := 12 }
  let run (command : EditorM Unit) : Dispatched := fun _ => do
    command
    return none
  dispatchKeys
    [("C-c g", invoke "begin"), ("C-c e", invoke "end"), ("C-c n", invoke "unsaved"),
      ("C-c r", invoke "remove"), ("C-c f", invoke "fail"), ("C-c t", invoke "twice")]
    [("begin",
        run do
          let some buffer := (← editorState).buffer? ⟨2⟩ | throw .noSuchText
          let taken ← buffer.text.snapshot
          discard <| EditorState.ask (.beginSave ⟨2⟩ taken buffer.history.state)),
      ("end", run (ends (some later))), ("unsaved", run (ends none)),
      ("remove", run (discard <| EditorState.ask (.removeBuffer ⟨2⟩))),
      ("fail", failingAfter fun _ => ends (some later)),
      ("twice", run (ends (some later) fun taken => taken.release))]

/-- A scheme written for the rollback checks: the test scheme, with two
counts beside its state that no reset clears, as a scheme's state may hold
what a reset must keep. The first counts the keys that yielded an
invocation, and the second the keys that yielded nothing and left nothing
pending. -/
def tallying : InputScheme :=
  { State := TestScheme.State × Nat × Nat
    Binding := Invocation
    init := ({}, 0, 0)
    step := fun maps view state key =>
      match TestScheme.step maps view state.1 key with
      | (next, some invocation) => ((next, state.2.1 + 1, state.2.2), some invocation)
      | (next, none) =>
        ((next, state.2.1, if next.pending.isEmpty then state.2.2 + 1 else state.2.2), none)
    pending := (·.1.pending)
    command := fun name => { command := name } }

/-- The two counts of `tallying` in a loop's state: the keys that yielded an
invocation, and the keys that yielded nothing and left nothing pending. -/
def tallies (loop : Loop tallying) : Nat × Nat :=
  let state : TestScheme.State × Nat × Nat := loop.input
  state.2

/-- The focused window's scroll anchor in `loop`'s state, as the text holds
it. -/
def scrollOf {scheme : InputScheme} (loop : Loop scheme) : EditorM (Option Anchor) := do
  let some target := loop.state.focusedTarget? | throw .noSuchText
  match ← target.buffer.text.marker target.window.scroll with
  | .anchor anchor =>
    return some anchor
  | .selection _ =>
    return none

/-- The checks of rollback in the loop (`Editor/Loop.lean`), on the editor's
models: what a command that failed leaves, in the text, in the windows'
markers, in the history and in the scheme's state. -/
def dispatchRollbackChecks : List Check :=
  let keys :=
    dispatchKeys [("C-c b", invoke "boom"), ("C-c s", invoke "stamp")]
      [("boom", boom), ("stamp", stamp)]
  [{  name :=
        "a command that fails after editing: the echo area shows its error, the buffer's text and the window's selection are those before the command, the history has no step for it, and the next key runs its command"
      run :=
        pure <|
          let program :
            EditorM ((String × Array SelectionRange × String × Nat) × Nat × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop (presses "C-c")
            let nodes := (← focusedOf loop).buffer.history.nodes.size
            let (loop, _) ← stepsWith keys loop (presses "b")
            let target ← focusedOf loop
            let failed :=
              (← target.buffer.text.read, ← cursorsOf loop, loop.state.echo,
                target.buffer.history.nodes.size)
            let (loop, _) ← stepsWith keys loop (presses "C-c s")
            let target ← focusedOf loop
            let after ← target.buffer.text.read
            let some _ ← target.buffer.history.undo | throw .noInverse
            return (failed, nodes, after, ← target.buffer.text.read)
          match program.runModel editorModel with
          | (.ok (failed, nodes, after, undone), model) =>
            failed == ("abcd", #[⟨1, 3⟩], "boom: refused: bad range", nodes) &&
              after == "aC-c sd" &&
              undone == "abcd" &&
              model.display.scenes.map (·.echo) ==
                #["", "boom: refused: bad range", "boom: refused: bad range", ""]
          | (.error _, _) => false },
    { name :=
        "a command that placed the window's selection and its scroll anchor without editing, and then failed, has both put back where they were"
      run :=
        pure <|
          let wander : Dispatched :=
            failingAfter fun call => do
              let text := call.target.buffer.text
              text.place call.target.window.selection (.selection { ranges := #[⟨0, 0⟩, ⟨4, 4⟩] })
              text.place call.target.window.scroll (.anchor { offset := 2, bias := .after })
          let keys := dispatchKeys [("C-c w", invoke "wander")] [("wander", wander)]
          let program : EditorM (Array SelectionRange × Option Anchor × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop (presses "C-c w")
            return (← cursorsOf loop, ← scrollOf loop, loop.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (cursors, scroll, echo) =>
            cursors == #[⟨1, 3⟩] && scroll == some { offset := 0, bias := .before } &&
              echo == "wander: refused: bad range"
          | .error _ => false },
    { name :=
        "a command that fails after editing two buffers has both texts as they were before it, and one that edited nothing leaves the texts and their revisions as they were"
      run :=
        pure <|
          let both : Dispatched :=
            failingAfter fun call => do
              call.target.buffer.text.insert 0 "x"
              (⟨1⟩ : TextId).insert 5 "!"
              call.target.buffer.text.insert 0 "y"
          let idle : Dispatched := failingAfter fun _ => pure ()
          let keys :=
            dispatchKeys [("C-c 2", invoke "both"), ("C-c 0", invoke "idle")]
              [("both", both), ("idle", idle)]
          let revisions (loop : TestLoop) : EditorM (Array Nat) :=
            loop.state.buffers.filterMap id |>.mapM fun buffer => buffer.text.revision
          let program : EditorM (Array String × Array Nat × Array Nat) := do
            let (loop, _) ← stepsWith keys { state := ← twoBuffers } (presses "C-c 2")
            let texts ← (loop.state.buffers.filterMap id).mapM fun buffer => buffer.text.read
            let before ← revisions loop
            let (loop, _) ← stepsWith keys loop (presses "C-c 0")
            return (texts, before, ← revisions loop)
          match (program.runModel editorModel).1 with
          | .ok (texts, before, after) => texts == #["", "other"] && before == after
          | .error _ => false },
    { name :=
        "a key's command that sets a register and is then refused leaves the register the name had: a register is editor state, and the state is the one from before the command; a command that sets one and runs to its end leaves it set"
      run :=
        pure <|
          let kept : Register := { text := "kept" }
          let lost : Register := { text := "lost\n", linewise := true }
          let keeps : Dispatched := fun _ => do
            setRegister "a" kept
            return none
          let loses : Dispatched :=
            failingAfter fun _ => do
              setRegister "a" lost
              setRegister "b" lost
          let keys :=
            dispatchKeys [("C-c k", invoke "keeps"), ("C-c l", invoke "loses")]
              [("keeps", keeps), ("loses", loses)]
          let program :
            EditorM
              (Option Register × Option Register × Option Register × Option Register × String) :=
            do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (set, _) ← stepsWith keys loop (presses "C-c k")
            let (failed, _) ← stepsWith keys set (presses "C-c l")
            return (loop.state.register? "a", set.state.register? "a", failed.state.register? "a",
                failed.state.register? "b", failed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (none, some kept, some kept, none, "loses: refused: bad range") },
    { name :=
        "after a command that failed the scheme is as it was before the first key of the sequence, with what it keeps across a reset: the key that yielded the failed invocation is not counted, a key that yielded nothing before it still is, and nothing is pending"
      run :=
        pure <|
          let keys : Loop.Keys tallying :=
            { maps := fun _ _ =>
                [Keymap.ofList
                    [(ModelTest.keys "C-c b", invoke "boom"),
                      (ModelTest.keys "C-c s", invoke "stamp")]]
              command? := fun name =>
                ([("boom", boom), ("stamp", stamp)].find? (·.1 == name)).map (·.2) }
          let program : EditorM (List (Nat × Nat) × String) := do
            let loop : Loop tallying := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (ran, _) ← stepsWith keys loop (presses "C-c s")
            let (reset, _) ← stepsWith keys ran [pressF5]
            let (failed, _) ← stepsWith keys reset (presses "C-c b")
            let (again, _) ← stepsWith keys failed (presses "C-c s")
            return ([tallies ran, tallies reset, tallies failed, tallies again], failed.pending)
          match (program.runModel editorModel).1 with
          | .ok (counts, pending) => counts == [(1, 0), (1, 1), (1, 1), (2, 1)] && pending == ""
          | .error _ => false },
    { name :=
        "a command that gave up the window's selection marker and then failed cannot be rolled back whole: the echo area says what was not, after the command's error, the text is still put back, and the step is not refused"
      run :=
        pure <|
          let forget : Dispatched :=
            failingAfter fun call => do
              call.target.buffer.text.insert 0 "x"
              call.target.buffer.text.unmark call.target.window.selection
          let keys := dispatchKeys [("C-c f", invoke "forget")] [("forget", forget)]
          lastScene keys (presses "C-c f") (holding "abcd" #[⟨1, 3⟩]) ==
            some
              ("forget: refused: bad range; not rolled back: no such marker", "", #[some "abcd"]) },
    { name :=
        "a command that released a buffer's text and then failed: running it says what was not rolled back and still rolls back the other buffer, and the step that runs it is not refused"
      run :=
        pure <|
          let release : Dispatched :=
            failingAfter fun call => do
              (⟨1⟩ : TextId).insert 5 "!"
              call.target.buffer.text.release
          let keys := dispatchKeys [("C-c r", invoke "release")] [("release", release)]
          let ran : EditorM (String × String) := do
            let state ← twoBuffers
            let ran ← Loop.run keys state (invoke "release") (ModelTest.keys "C-c r")
            return (ran.state.echo, ← (⟨1⟩ : TextId).read)
          (match (ran.runModel editorModel).1 with
            | .ok (echo, other) =>
              echo == "release: refused: no such text; not rolled back: no such text" &&
                other == "other"
            | .error _ => false) &&
            (dispatched keys (presses "C-c r") twoBuffers).isSome },
    { name :=
        "a rollback after the history moved does not take the move back: it reverts the edits made since the move, leaves the text at the node the move reached, says the command moved in the history, and what was undone can be redone"
      run :=
        pure <|
          let program : EditorM (String × String × String × String) := do
            let state ← holding "one" #[⟨3, 3⟩]
            let (state, _) ← state.recordHistories
            let kept ← Loop.keep state
            -- What a command that moved in the history would have done: an
            -- undo, to the root, and then an edit.
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
            let some moved ← buffer.history.undo Origin.user | throw .noInverse
            buffer.text.insert 0 "x"
            let during := { state with buffers := #[some { buffer with history := moved.tree }] }
            let before ← buffer.text.read
            let (restored, said) ← kept.restore state during
            let after ← buffer.text.read
            let some again := restored.buffer? ⟨0⟩ | throw .noSuchText
            let some _ ← again.history.redo Origin.user | throw .noInverse
            return (before, after, said, ← buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some ("x", "", "; the command moved in the history", "one") },
    { name :=
        "a command that ended a save with a stamp, which marks the buffer's state as saved, and was then refused is rolled back whole: the buffer is modified as it was before the command, its stamp is the one from before, and its save is still in flight"
      run :=
        pure <|
          let program : EditorM (Bool × Bool × Option Buffer × Option Buffer × String) := do
            let state ← savable
            (⟨2⟩ : TextId).insert 0 "x"
            let (edited, _) ← stepsWith saveKeys ({ state } : TestLoop) [pressF5]
            let (begun, _) ← stepsWith saveKeys edited (presses "C-c g")
            let (failed, _) ← stepsWith saveKeys begun (presses "C-c f")
            return (((begun.state.buffer? ⟨2⟩).map (·.isModified)) == some true,
                (savingOf begun.state).isSome, failed.state.buffer? ⟨2⟩, begun.state.buffer? ⟨2⟩,
                failed.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (modified, saving, after, before, echo) =>
            modified && saving && after == before && echo == "fail: refused: bad range"
          | .error _ => false },
    { name :=
        "a command that recorded its buffer's history marked as saved and was then refused leaves the buffer modified as it was: a rollback takes back a mark of the saved state"
      run :=
        pure <|
          let marking : Dispatched :=
            failingAfter fun call => do
              let .ok buffer ← call.target.window.buffer.synced | throw .noSuchText
              discard <|
                  EditorState.ask (.setHistory call.target.window.buffer buffer.history.markSaved)
          let keys := dispatchKeys [("C-c m", invoke "mark")] [("mark", marking)]
          let program : EditorM (Option Buffer × Option Buffer × String) := do
            let (edited, _) ←
              stepsWith keys ({ state := ← EditorState.initial ⟨640, 480⟩ } : TestLoop)
                  [.commit "a"]
            let (failed, _) ← stepsWith keys edited (presses "C-c m")
            return (edited.state.buffer? ⟨0⟩, failed.state.buffer? ⟨0⟩, failed.state.echo)
          match (program.runModel editorModel).1 with
          | .ok (before, after, echo) =>
            (before.map (·.isModified)) == some true && after == before &&
              echo == "mark: refused: bad range"
          | .error _ => false }]

/-- The events of `events` as they arrive, none of them marked as an
interrupt key. -/
def arriving (events : List Event) : List Received :=
  events.map fun event => { event, stamp := 0 }

/-- Feeds `loop` what arrived, in order, as a host does (`Loop.take`), each
step handed `keys`: the loop after them. -/
def takes {scheme : InputScheme} (keys : Loop.Keys scheme) (loop : Loop scheme)
    (received : List Received) : EditorM (Loop scheme) := do
  let mut loop := loop
  for one in received do
    loop := (← loop.take keys one).loop
  return loop

/-- What a run of the loop over the buffer holding `abcd`, its selection
over `bc`, came to when it was fed what arrived, on the editor's models
with the watch model `watch`: the buffer's text, the selection's ranges, the
echo of each scene, and the watch model after. `none` when it was
refused. -/
def tookFrom (keys : Loop.Keys TestScheme.scheme) (received : List Received) (watch : WatchModel) :
    Option (String × Array SelectionRange × Array String × WatchModel) :=
  let program : EditorM (String × Array SelectionRange) := do
    let loop ← takes keys { state := ← holding "abcd" #[⟨1, 3⟩] } received
    return (← (← focusedOf loop).buffer.text.read, ← cursorsOf loop)
  match program.runModel { editorModel with watch } with
  | (.ok (text, cursors), model) =>
    some (text, cursors, model.display.scenes.map (·.echo), model.watch)
  | (.error _, _) => none

/-- The command `spin` of the interrupt checks: it replaces what the
selection covers with `spin`, and then asks the text its revision a thousand
times. -/
def spin : Dispatched := fun call => do
  Loop.insert call.target "spin"
  for _ in [0:1000] do
    discard <| call.target.buffer.text.revision
  return none

/-- The checks of the interrupt in the loop (`Editor/Loop.lean`), on the
editor's models: a command the loop runs stops once the flag is up, and the
flag comes down when the loop takes the interrupt key off the queue. -/
def dispatchInterruptChecks : List Check :=
  let keys :=
    dispatchKeys [("C-c l", invoke "spin"), ("C-c s", invoke "stamp"), ("C-g", invoke "stamp")]
      [("spin", spin), ("stamp", stamp)]
  let unbound := dispatchKeys [("C-c s", invoke "stamp")] [("stamp", stamp)]
  [{  name :=
        "when the interrupt key arrives while a command is looping over requests, the command stops: the buffer's text and the selection are those before it, the echo area says it was interrupted, and the flag is still up"
      run :=
        pure <|
          match tookFrom keys (arriving (presses "C-c l")) { arrivesAfter := some 20 } with
          | some (text, cursors, echoes, watch) =>
            text == "abcd" && cursors == #[⟨1, 3⟩] && echoes == #["", "spin: interrupted"] &&
              watch.arrived == 1
          | none => false },
    { name := "with no interrupt key arriving the same command runs to its end, and its edit stays"
      run :=
        pure <|
          match tookFrom keys (arriving (presses "C-c l")) {} with
          | some (text, _, echoes, _) => text == "aspind" && echoes == #["", ""]
          | none => false },
    { name :=
        "the event the library marked as the interrupt key lowers the flag and is then stepped like any key: the command bound to it runs to its end; the same key unmarked lowers nothing, and its command is interrupted"
      run :=
        pure <|
          (match tookFrom keys [interruptArrives] { arrived := 1 } with
            | some (text, _, echoes, watch) =>
              text == "aC-gd" && echoes == #[""] && watch.arrived == 0
            | none => false) &&
            match tookFrom keys (arriving [press Watch.interruptKey]) { arrived := 1 } with
            | some (text, _, echoes, watch) =>
              text == "abcd" && echoes == #["stamp: interrupted"] && watch.arrived == 1
            | none => false },
    { name :=
        "an interrupt key that arrived while no command was running interrupts nothing: once the loop has taken it off the queue, the next key's command runs to its end"
      run :=
        pure <|
          match
            tookFrom unbound (interruptArrives :: arriving (presses "C-c s")) { arrived := 1 } with
          | some (text, _, echoes, watch) =>
            text == "aC-c sd" && echoes == #["", "", ""] && watch.arrived == 0
          | none => false },
    { name :=
        "a command for a key queued ahead of the interrupt key is interrupted before its first request, and its echo is still there after the interrupt key is stepped and found bound to nothing; the key after it runs its command"
      run :=
        pure <|
          let queued := arriving (presses "C-c s") ++ [interruptArrives]
          (match tookFrom unbound queued { arrived := 1 } with
            | some (text, cursors, echoes, watch) =>
              text == "abcd" && cursors == #[⟨1, 3⟩] &&
                echoes == #["", "stamp: interrupted", "stamp: interrupted"] &&
                watch.arrived == 0
            | none => false) &&
            match tookFrom unbound (queued ++ arriving (presses "C-c s")) { arrived := 1 } with
            | some (text, _, echoes, _) => text == "aC-c sd" && echoes.back? == some ""
            | none => false },
    { name :=
        "with two interrupt keys arrived, the command of a key between them is interrupted, and the one after the second runs to its end"
      run :=
        pure <|
          let between := interruptArrives :: arriving (presses "C-c s") ++ [interruptArrives]
          (match tookFrom unbound between { arrived := 2 } with
            | some (text, _, echoes, watch) =>
              text == "abcd" && echoes.back? == some "stamp: interrupted" && watch.arrived == 0
            | none => false) &&
            match tookFrom unbound (between ++ arriving (presses "C-c s")) { arrived := 2 } with
            | some (text, _, echoes, _) => text == "aC-c sd" && echoes.back? == some ""
            | none => false },
    { name :=
        "for an event taken off the queue with no loop to step it, the flag is lowered once if the library marked the event, and not at all if it did not"
      run :=
        pure
          ((watched (Loop.lowerFor true) { arrived := 2 }).2.arrived == 1 &&
            (watched (Loop.lowerFor false) { arrived := 2 }).2.arrived == 2) }]

/-- A command of the slow-command checks that makes `requests` requests of
the text port, each a question that changes nothing, and is then refused if
`refused`. -/
def asking (requests : Nat) (refused : Bool := false) : Dispatched := fun call => do
  for _ in [0:requests] do
    discard <| call.target.buffer.text.revision
  if refused then
    throw .badRange
  return none

/-- What each step of a run handed back as its log, on the editor's models
with a clock that moves on by 10 milliseconds at each text request and each
display request; nothing when the run was refused. -/
def logged (keys : Loop.Keys TestScheme.scheme) (events : List Event) : Array (Array String) :=
  match
    dispatched keys events (model :=
      { editorModel with watch := { clock := 1000, pace := 10 } }) with
  | some ((_, steps), _, _) => steps.map (·.log)
  | none => #[]

/-- The checks of the slow-command log in the loop (`Editor/Loop.lean`), on
the model's clock: a command that took longer than the threshold is logged
once, with its name and how long it took. -/
def dispatchSlowChecks : List Check :=
  let keys : Loop.Keys TestScheme.scheme :=
    {
      dispatchKeys
        [("C-c 6", invoke "stamp"), ("C-c 5", invoke "five"), ("C-c 2", invoke "two"),
          ("C-c r", invoke "refused"), ("C-c n", invoke "nope")]
        [("stamp", asking 6), ("five", asking 5), ("two", asking 2),
          ("refused", asking 7 true)] with
      slowAfter := 50 }
  [{  name :=
        "a command that takes longer than the threshold produces one log entry with its name and how long it took, in the step that ran it and in no other"
      run :=
        pure
          (logged keys (presses "C-c 6" ++ [pressF5]) ==
            #[#[], #["slow command: stamp took 60 ms"], #[]]) },
    { name :=
        "a command that takes less than the threshold, or exactly as long, produces no log entry"
      run := pure (logged keys (presses "C-c 2 C-c 5") == #[#[], #[], #[], #[]]) },
    { name :=
        "a slow command that was refused is logged like one that finished, with the time the command took and not the time its rollback took"
      run :=
        pure (logged keys (presses "C-c r") == #[#[], #["slow command: refused took 70 ms"]]) },
    { name := "an invocation of a name no command is registered under produces no log entry"
      run := pure (logged keys (presses "C-c n") == #[#[], #[]]) },
    { name :=
        "the threshold a step is handed by default is the loop's, 100 milliseconds: a command of ten requests is not logged and one of eleven is"
      run :=
        let keys :=
          dispatchKeys [("C-c a", invoke "ten"), ("C-c b", invoke "eleven")]
            [("ten", asking 10), ("eleven", asking 11)]
        pure
          (keys.slowAfter == Loop.slowAfter && Loop.slowAfter == 100 &&
            logged keys (presses "C-c a C-c b") ==
              #[#[], #[], #[], #["slow command: eleven took 110 ms"]]) }]

/-- Splits the window a command was called on by the state
request, with markers the command makes on the buffer's text first: the new
view. Refused with `noSuchMarker` if the split is. -/
def splitting (call : Call) : EditorM ViewId := do
  let text := call.target.buffer.text
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  match ← EditorState.ask (.split call.target.window.id scroll selection) with
  | .ok view =>
    return view
  | .error _ =>
    throw .noSuchMarker

/-- The text of the checks of two windows on one buffer: a hundred lines,
`l00` to `l99`, four bytes each with its line feed, so line `n` starts at
`4 * n`: many more rows than a window of a frame 40 pixels tall shows in
the display model's pixel cells. -/
def hundredLines : String :=
  "\n".intercalate ((List.range 100).map fun line => s!"l{line / 10}{line % 10}")

/-- A state of one window, view 0, over `hundredLines` in a buffer called
`scratch`, its scroll anchor and its cursor at the text's start, in a frame
of 640 by 40. -/
def tallState : TextM EditorState := do
  let text ← createText hundredLines
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  let history ← UndoTree.over text
  return {
      buffers := #[some { name := EditorState.scratchName, text, history }]
      windows := #[{ id := ⟨0⟩, buffer := ⟨0⟩, scroll, selection }]
      frame := { size := ⟨640, 40⟩, windows := #[⟨0⟩], focused := ⟨0⟩ }
      recent := #[⟨0⟩] }

/-- The checks of two windows on one buffer (criterion 4 of the window
management's phase 1), on the editor's models: each window keeps a cursor
and a scroll anchor of its own, and an edit in one shows in both. -/
def twoWindowChecks : List Check :=
  -- Line 80 starts at byte 320.
  let deep := 320
  let keys :=
    dispatchKeys [("C-c s", invoke "split"), ("C-c o", invoke "other"), ("C-c g", invoke "deep")]
      [("split", fun call => do
          discard <| call.target.window.id.split
          return none),
        ("other", fun call => do
          let windows := (← editorState).frame.windows
          if let some next := windows.find? (· != call.target.window.id) then
            discard <| next.focus
          return none),
        ("deep", fun call => do
          call.target.select { ranges := #[⟨deep, deep⟩] }
          call.target.scrollTo deep
          return none)]
  [{  name :=
        "criterion 4, on the models: two windows split on one buffer of a hundred lines in a frame of 640 by 40 keep markers of their own; with view 1's cursor and anchor moved to line 80 and an edit typed in view 0 at the top, view 0's anchor and cursor are at the top and view 1's at line 80, moved by the edit; both views show the one snapshot, which holds the edit"
      run :=
        pure <|
          let program : EditorM (Option (Array Marker × String)) := do
            let (loop, _) ←
              stepsWith keys { state := ← tallState }
                  (presses "C-c s C-c o C-c g C-c o" ++ [.commit "X"])
            let some zero := loop.state.target? ⟨0⟩ | return none
            let some one := loop.state.target? ⟨1⟩ | return none
            let text := zero.buffer.text
            let markers ←
              [zero.window.scroll, one.window.scroll, zero.window.selection,
                      one.window.selection].mapM
                  fun marker => (text.marker marker : TextM Marker)
            return some (markers.toArray, ← text.read)
          match program.runModel editorModel with
          | (.ok (some (markers, contents)), model) =>
            let scenes := model.display.scenes
            match scenes.back? with
            | some scene =>
              match scene.views with
              | #[zero, one] =>
                let anchor (offset : Nat) : Marker := .anchor { offset, bias := .before }
                let cursor (at_ : Nat) : Marker := .selection { ranges := #[⟨at_, at_⟩] }
                zero.id == ⟨0⟩ && one.id == ⟨1⟩ && scene.focused == some ⟨0⟩ &&
                  zero.scroll != one.scroll &&
                  zero.selections != one.selections &&
                  markers == #[anchor 0, anchor (deep + 1), cursor 1, cursor (deep + 1)] &&
                  zero.snapshot == one.snapshot &&
                  shownText model zero == some ("X" ++ hundredLines) &&
                  contents == "X" ++ hundredLines &&
                  one.rect == { x := 320, y := 0, width := 320, height := 39 }
              | _ => false
            | none => false
          | _ => false }]

/-- The checks of a command's state requests in the loop
(`Editor/Command/Dispatch.lean`, `Editor/Loop.lean`), on the editor's
models: the loop answers them from the state it holds, keeps the state a
command that ran to its end left, and goes back to the state from before
one that did not. -/
def dispatchStateChecks : List Check :=
  let split : Dispatched := fun call => do
    discard <| splitting call
    return none
  let moving : Dispatched :=
    failingAfter fun call => do
      -- A move in the history, recorded as a command records one: an undo
      -- to the root, the moved tree set as the buffer's, and then an edit.
      let state ← editorState
      let some buffer := state.buffer? call.target.window.buffer | throw .noSuchText
      let some moved ← (← buffer.history.sync).undo Origin.user | throw .noInverse
      discard <| EditorState.ask (.setHistory call.target.window.buffer moved.tree)
      buffer.text.insert 0 "x"
  let keys :=
    dispatchKeys [("C-c s", invoke "split"), ("C-c f", invoke "fail"), ("C-c m", invoke "moving")]
      [("split", split), ("fail", failingAfter fun call => discard <| splitting call),
        ("moving", moving)]
  [{  name :=
        "a dispatched command that asks for the display rules is answered the rules the loop was told of, and the state is as it was"
      run :=
        let rules : Array DisplayRule :=
          #[{ mode := some "notes", target := .edge .left }, { target := .main, focus := false }]
        let program : EditorM (Guarded (Array DisplayRule) × EditorState × EditorState) := do
          let state ← twoBuffers
          let (ended, after) ←
            (EditorState.ask .displayRules).dispatched { displayRules := rules } state
          return (ended, after, state)
        pure <|
          match (program.runModel editorModel).1 with
          | .ok (.finished answer, after, state) => answer == rules && after == state
          | _ => false },
    { name :=
        "criterion 3, on the models: a step handed monocle as its layout shows only the focused window, in the whole tiled area, and focusing the other window shows it in its place; a step handed no layout keeps the frame's; a step handed the default shows both again; no window is lost on the way"
      run :=
        pure <|
          let others : Dispatched := fun call => do
            let windows := (← editorState).frame.windows
            if let some next := windows.find? (· != call.target.window.id) then
              discard <| next.focus
            return none
          let keyed :=
            dispatchKeys [("C-c s", invoke "split"), ("C-c o", invoke "other")]
              [("split", split), ("other", others)]
          let program : EditorM (Array EditorState) := do
            let (split, _) ←
              stepsWith keyed { state := ← EditorState.initial ⟨640, 480⟩ } (presses "C-c s")
            let (alone, _) ← stepsWith { keyed with layout := some .monocle } split [pressF5]
            let (kept, _) ← stepsWith keyed alone [pressF5]
            let (other, _) ← stepsWith { keyed with layout := some .monocle } kept (presses "C-c o")
            let (both, _) ← stepsWith { keyed with layout := some Layout.default } other [pressF5]
            return #[split.state, alone.state, kept.state, other.state, both.state]
          match program.runModel editorModel with
          | (.ok states, model) =>
            let scenes := model.display.scenes
            let laid (scene : Scene) := scene.views.map fun view => (view.id, view.rect)
            -- Every event publishes a scene: `C-c s` and `C-c o` are two
            -- presses each, and the scene after a sequence's last key is the
            -- one its command's step published.
            match states, scenes with
            | #[split, alone, kept, other, both], #[_, first, second, third, _, fourth, fifth] =>
              states.all (·.frame.windows == #[⟨0⟩, ⟨1⟩]) && states.all (·.wellFormed) &&
                split.frame.layout == Layout.default &&
                alone.frame.layout == .monocle &&
                kept.frame.layout == .monocle &&
                both.frame.layout == Layout.default &&
                first.views.map (·.id) == #[⟨0⟩, ⟨1⟩] &&
                laid second == #[(⟨0⟩, alone.tiled)] &&
                second.focused == some ⟨0⟩ &&
                laid third == #[(⟨0⟩, kept.tiled)] &&
                laid fourth == #[(⟨1⟩, other.tiled)] &&
                fourth.focused == some ⟨1⟩ &&
                laid fifth == both.rects &&
                fifth.views.map (·.id) == #[⟨0⟩, ⟨1⟩]
            | _, _ => false
          | (.error _, _) => false },
    { name :=
        "a layout change a command made lasts until config chooses another layout: a zoom survives three steps handed the default layout, and a resized share a step handed it; handing monocle and then the manual split layout rearranges the same windows and leaves the zoom"
      run :=
        pure <|
          let arranging (change : Arrange) : Dispatched := fun call => do
            discard <| call.target.window.id.arrange change
            return none
          let keyed :=
            dispatchKeys
              [("C-c s", invoke "split"), ("C-c z", invoke "zoom"), ("C-c g", invoke "grow")]
              [("split", split), ("zoom", arranging .zoom),
                ("grow", arranging (.resize .columns true 1))]
          let chosen := { keyed with layout := some Layout.default }
          let program : EditorM (Array EditorState) := do
            let (split, _) ←
              stepsWith chosen { state := ← EditorState.initial ⟨640, 480⟩ } (presses "C-c s")
            let (zoomed, _) ← stepsWith chosen split (presses "C-c z")
            let (kept, _) ← stepsWith chosen zoomed [pressF5, pressF5, pressF5]
            let (back, _) ← stepsWith chosen kept (presses "C-c z")
            let (grown, _) ← stepsWith chosen back (presses "C-c g")
            let (still, _) ← stepsWith chosen grown [pressF5]
            let (again, _) ← stepsWith chosen still (presses "C-c z")
            let (monocle, _) ← stepsWith { keyed with layout := some .monocle } again [pressF5]
            let (manual, _) ←
              stepsWith { keyed with layout := some Layout.manual } monocle [pressF5]
            return #[kept.state, back.state, grown.state, still.state, again.state, monocle.state,
                manual.state]
          match program.runModel editorModel with
          | (.ok #[kept, back, grown, still, again, monocle, manual], _) =>
            let grownLayout := Layout.masterStack { share := 55 }
            #[kept, back, grown, still, again, monocle, manual].all
                (fun state => state.wellFormed && state.frame.windows == #[⟨0⟩, ⟨1⟩]) &&
              kept.frame.layout == .monocle &&
              kept.frame.zoomedFrom == some Layout.default &&
              back.frame.layout == Layout.default &&
              grown.frame.layout == grownLayout &&
              still.frame.layout == grownLayout &&
              again.frame.zoomedFrom == some grownLayout &&
              monocle.frame.layout == .monocle &&
              monocle.frame.zoomedFrom == none &&
              manual.frame.layout == .splits (.split .rows 1 1 .tile .tile) &&
              manual.frame.zoomedFrom == none
          | _ => false },
    { name :=
        "a key's command that splits its window by a state request: the loop keeps the new window after the step, well formed, and the scene shows both views"
      run :=
        pure <|
          match dispatched keys (presses "C-c s") with
          | some ((loop, _), scenes, _) =>
            loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩, ⟨1⟩] &&
              loop.state.frame.windows == #[⟨0⟩, ⟨1⟩] &&
              loop.state.echo == "" &&
              scenes.back?.map (·.views.map (·.id)) == some #[⟨0⟩, ⟨1⟩]
          | none => false },
    { name :=
        "a command that splits its window and is then refused leaves the state from before it: one window, the list as it was, and the refusal in the echo"
      run :=
        pure <|
          match dispatched keys (presses "C-c f") with
          | some ((loop, _), scenes, _) =>
            loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩] &&
              loop.state.frame.windows == #[⟨0⟩] &&
              loop.state.echo == "fail: refused: bad range" &&
              scenes.back?.map (·.views.map (·.id)) == some #[⟨0⟩]
          | none => false },
    { name :=
        "the interrupt flag is asked before each request that reaches the models and not before a state request: with the interrupt key arriving at a command's second ask, the state request before it is answered, the text request after it is not made, and the state the command had reached is handed back"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          let ran (arrivesAfter : Nat) :=
            program.runModel { editorModel with watch := { arrivesAfter := some arrivesAfter } }
          (match ran 1 with
            | (.ok (outcome, state), model) =>
              outcome == .interrupted && state.echo == "said" &&
                model.texts.contents == #["", "one"]
            | (.error _, _) => false) &&
            -- Two asks for the four requests: the key placed two asks away
            -- has not arrived when the command ends, and is one ask off.
            match ran 2 with
            | (.ok (outcome, state), model) =>
              outcome == .finished () && state.echo == "late" &&
                model.texts.contents == #["", "one", "two"] &&
                model.watch.arrivesAfter == some 0 &&
                model.watch.arrived == 0
            | (.error _, _) => false },
    { name :=
        "a command that edits, says something, gives up and would edit again ends as having given up, with its reason and the state it had reached: the first edit was made, the second was not, and a try round the call does not go on"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            try
              giveUp "cannot go on"
            catch _ =>
              pure ()
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, state), model) =>
            outcome == .gaveUp "cannot go on" && state.echo == "said" &&
              model.texts.contents == #["", "one"]
          | (.error _, _) => false },
    { name :=
        "a command that gives up where no loop dispatches it is refused with badSelection, and nothing of its reason is kept: the handler of the runners changes nothing"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            giveUp "cannot go on"
          match command.runModel editorModel with
          | (.error refusal, model) => refusal == .badSelection && model.texts.contents == #["one"]
          | (.ok _, _) => false },
    { name :=
        "a command that edits, says something, breaks off and would edit again ends as having broken off, with its reason and the state it had reached: the first edit was made, the second was not, and a try round the call does not go on"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            EditorState.ask (.message "said")
            try
              breakOff "far enough"
            catch _ =>
              pure ()
            discard <| createText "two"
            EditorState.ask (.message "late")
          let program : EditorM (Guarded Unit × EditorState) := do
            command.dispatched {} (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, state), model) =>
            outcome == .brokeOff "far enough" && state.echo == "said" &&
              model.texts.contents == #["", "one"]
          | (.error _, _) => false },
    { name :=
        "a command that breaks off where no loop dispatches it is refused with badSelection, and nothing of its reason is kept: the handler of the runners changes nothing"
      run :=
        pure <|
          let command : EditorM Unit := do
            discard <| createText "one"
            breakOff "far enough"
          match command.runModel editorModel with
          | (.error refusal, model) => refusal == .badSelection && model.texts.contents == #["one"]
          | (.ok _, _) => false },
    { name :=
        "a command that edits, moves in the history and records the move, edits again and is then refused: the rollback reverts the edit made since the move from the tree the command left, leaves the text at the node the move reached, says the command moved in the history, and what was undone can be redone"
      run :=
        pure <|
          let program : EditorM (String × String × Array String × String) := do
            let loop : TestLoop := { state := ← holding "one" #[⟨3, 3⟩] }
            -- The first step records the insertion as a step of the history.
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c m")
            let target ← focusedOf loop
            let text ← target.buffer.text.read
            let some _ ← target.buffer.history.redo Origin.user | throw .noInverse
            return (text, loop.state.echo, loop.state.windows.map fun _ => "window",
                ← target.buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some
              ("", "moving: refused: bad range; the command moved in the history", #["window"],
                "one") },
    { name :=
        "a command that asks which command an ex name is bound to is answered what the loop was told of the registry: the binding of a name it knows, with what it takes, and none for another name; the state is as it was"
      run :=
        pure <|
          let greet : Ex.Binding := { name := "greet", command := "greet-named", takes := .text }
          let registered : Loop.Registered :=
            { ex := fun name => if name == "greet" then some greet else none }
          let command : EditorM (Option Ex.Binding × Option Ex.Binding) := do
            return (← exBinding "greet", ← exBinding "other")
          let program : EditorM (Guarded (Option Ex.Binding × Option Ex.Binding) × Bool) := do
            let start ← EditorState.initial ⟨640, 480⟩
            let (outcome, state) ← command.dispatched registered start
            return (outcome, state == start)
          (program.runModel editorModel).1.toOption == some (.finished (some greet, none), true) },
    { name :=
        "what the loop is told of a registry's ex bindings is the latest entry of each name: config's binding of a name a compiled binding has, the compiled one of a name config does not bind, and none for a name nobody bound"
      run :=
        let registry : Config.Registry :=
          (({} : Config.Registry).replaceEx .compiled
                #[{ name := "w", command := "compiled" },
                  { name := "q", command := "kept" }]).replaceEx
            .config #[{ name := "w", command := "config", takes := .text }]
        let told := registry.registered
        pure
          (told.ex "w" == some { name := "w", command := "config", takes := .text } &&
            told.ex "q" == some { name := "q", command := "kept" } &&
            told.ex "missing" == none) },
    { name :=
        "a command that asks which ex names are bound is answered the names the loop was told of the registry, in their order, and none where it was told none; the state is as it was"
      run :=
        pure <|
          let registered : Loop.Registered := { exNames := #["w", "q", "greet"] }
          let asks (registered : Loop.Registered) : Option (Guarded (Array String) × Bool) :=
            let program : EditorM (Guarded (Array String) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← exNames.dispatched registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          asks registered == some (.finished #["w", "q", "greet"], true) &&
            asks {} == some (.finished #[], true) },
    { name :=
        "a command that asks which themes are registered is answered the names the loop was told, in their order, with the state as it was"
      run :=
        pure <|
          let asks (registered : Loop.Registered) : Option (Guarded (Array String) × Bool) :=
            let program : EditorM (Guarded (Array String) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← themeNames.dispatched registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          asks { themeNames := #["default", "second"] } ==
              some (.finished #["default", "second"], true) &&
            asks {} == some (.finished #[], true) },
    { name :=
        "a command that asks to load a theme the loop was told is registered is answered ok, and the state keeps the name for the loop to take out; one nobody registered is refused with its name, and the state is as it was"
      run :=
        pure <|
          let registered : Loop.Registered := { themeNames := #["default", "second"] }
          let asks (name : String) : Option (Option (ThemeRefusal ⊕ Unit) × Option String × Bool) :=
            let program : EditorM (Option (ThemeRefusal ⊕ Unit) × Option String × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← (loadTheme name).dispatched registered start
              let reply :=
                match outcome with
                | .finished reply => some (replied reply)
                | _ => none
              return (reply, state.theme, { state with theme := none } == start)
            (program.runModel editorModel).1.toOption
          asks "second" == some (some (.inr ()), some "second", true) &&
            asks "nope" == some (some (.inl (.noSuchTheme "nope")), none, true) &&
            ThemeRefusal.describe (.noSuchTheme "nope") == Theme.unknown "nope" },
    { name :=
        "a command that asks for the command of a name to be run inside it: the command the loop was told of under that name runs there, with the call it is handed, before the asking command goes on, and what it said is in the state the asking command then reads; a name the loop was told no command of is answered false, and nothing runs"
      run :=
        pure <|
          let inner (call : Call) : EditorM Unit := do
            discard <| createText "inner"
            message s!"handed {call.arguments.length} arguments"
          let registered : Loop.Registered :=
            { command := fun name => if name == "inner" then some inner else none }
          let command : EditorM (Bool × String × Bool) := do
            let some target := (← editorState).focusedTarget? | throw .noSuchText
            let ran ← runCommand "inner" { target, arguments := [.nat 1, .nat 2] }
            let said := (← editorState).echo
            let missing ← runCommand "other" { target }
            discard <| createText "outer"
            return (ran, said, missing)
          let program : EditorM (Guarded (Bool × String × Bool) × EditorState) := do
            command.dispatched registered (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, _), model) =>
            outcome == .finished (true, "handed 2 arguments", false) &&
              model.texts.contents == #["", "inner", "outer"]
          | (.error _, _) => false },
    { name :=
        "a command run inside another is part of it: one that gives up ends the asking command as having given up, one that is refused refuses it, and one that the interrupt stops at a request ends it as interrupted, each with nothing of the asking command run after it"
      run :=
        pure <|
          let registered : Loop.Registered :=
            {
              command := fun name =>
                match name with
                | "quits" => some fun _ => giveUp "no"
                | "fails" => some fun _ => throw .badRange
                | "works" =>
                  some fun _ => do
                    discard <| createText "one"
                    discard <| createText "two"
                | _ => none }
          let asking (name : String) : EditorM Unit := do
            let some target := (← editorState).focusedTarget? | throw .noSuchText
            discard <| runCommand name { target }
            discard <| createText "late"
          let ended (name : String) (watch : WatchModel := {}) :
            Option (Guarded Unit × Array String) :=
            let program : EditorM (Guarded Unit × EditorState) := do
              (asking name).dispatched registered (← EditorState.initial ⟨640, 480⟩)
            match program.runModel { editorModel with watch } with
            | (.ok (outcome, _), model) => some (outcome, model.texts.contents)
            | (.error _, _) => none
          ended "quits" == some (.gaveUp "no", #[""]) &&
            ended "fails" == some (.refused .badRange, #[""]) &&
            ended "works" == some (.finished (), #["", "one", "two", "late"]) &&
            ended "works" { arrivesAfter := some 1 } == some (.interrupted, #["", "one"]) },
    { name :=
        "a command that asks for another to be run inside it where no loop dispatches it is answered false: the handler of the runners knows no registry"
      run :=
        pure <|
          let command : EditorM Bool := do
            let state ← EditorState.initial ⟨640, 480⟩
            let some target := state.focusedTarget? | throw .noSuchText
            runCommand "inner" { target }
          (command.runModel editorModel).1.toOption == some false }]

/-- The checks of what the loop gives up after a command (`Editor/Loop.lean`,
"What a finished command gave up"), on the editor's models: the markers of
a window a command closed, the text of a buffer it removed and the snapshot
of a save it ended, once the command has run to its end and not before. -/
def dispatchGiveUpChecks : List Check :=
  let asks (requests : List StateRequest) : EditorM Unit := do
    for request in requests do
      discard <| EditorState.ask request
  let bound (run : Dispatched) := dispatchKeys [("C-c g", invoke "go")] [("go", run)]
  let ran (run : EditorM Unit) : Loop.Keys TestScheme.scheme :=
    bound fun _ => do
      run
      return none
  [{  name :=
        "after a command that closed a window has run to its end, the window's two markers are given up: each refuses noSuchMarker, the other windows' markers still answer, and nothing is in the echo"
      run :=
        pure <|
          let program :
            EditorM (List (Option TextError) × List (Option TextError) × String × Bool) := do
            let state ← threeWindows
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let some stays := state.window? ⟨2⟩ | throw .noSuchMarker
            let (loop, _) ←
              stepsWith (ran (asks [.removeWindow ⟨1⟩])) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, ← markerRefusals stays, loop.state.echo,
                loop.state.wellFormed && loop.state.windows.map (·.id) == #[⟨0⟩, ⟨2⟩])
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchMarker, some .noSuchMarker], [none, none], "", true) },
    { name :=
        "after a command that removed a buffer has run to its end, the buffer's text is released: it refuses noSuchText, the other buffers' texts still answer, and nothing is in the echo"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Bool) := do
            let (state, text) ← hiddenBuffer
            let (loop, _) ←
              stepsWith (ran (asks [.removeBuffer ⟨2⟩])) ({ state } : TestLoop) (presses "C-c g")
            return ([← refusalOf text.read, ← refusalOf (⟨0⟩ : TextId).read,
                  ← refusalOf (⟨1⟩ : TextId).read],
                loop.state.echo, loop.state.wellFormed && loop.state.buffer? ⟨2⟩ == none)
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchText, none, none], "", true) },
    { name :=
        "a buffer a command removed keeps its empty slot through the loop's pass over the histories, in the step that removed it and in the next event's: the buffers after it keep their ids, the window on one still shows it, and a buffer added afterwards gets an id no buffer had"
      run :=
        pure <|
          -- `hidden`, which no window shows, is in the slot before `other`,
          -- which view 1 shows.
          let middle : TextM EditorState := do
            let state ← EditorState.initial ⟨640, 480⟩
            let hidden ← createText "hidden"
            let text ← createText "other"
            let scroll ← text.mark (.anchor { offset := 0, bias := .before })
            let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
            return {
                state with
                buffers :=
                  state.buffers ++
                    #[some { name := "hidden", text := hidden, history := ← UndoTree.over hidden },
                      some { name := "other", text, history := ← UndoTree.over text }]
                windows := state.windows.push { id := ⟨1⟩, buffer := ⟨2⟩, scroll, selection }
                frame := { state.frame with windows := #[⟨0⟩, ⟨1⟩] } }
          let removing : Dispatched := fun _ => do
            asks [.removeBuffer ⟨1⟩]
            return none
          let adding : Dispatched := fun _ => do
            let text ← createText "new"
            let .ok id ←
              EditorState.ask (.addBuffer "new" text (← UndoTree.over text)) | throw .noSuchText
            EditorState.ask (.message s!"added {id.index}")
            return none
          let keys :=
            dispatchKeys [("C-c g", invoke "go"), ("C-c a", invoke "add")]
              [("go", removing), ("add", adding)]
          let slots (loop : TestLoop) : Array (Option String) × Option String × Bool :=
            (loop.state.buffers.map (·.map (·.name)), (loop.state.target? ⟨1⟩).map (·.buffer.name),
              loop.state.wellFormed)
          let program : EditorM (List (Array (Option String) × Option String × Bool) × String) := do
            let (removed, _) ← stepsWith keys ({ state := ← middle } : TestLoop) (presses "C-c g")
            let (next, _) ← stepsWith keys removed [pressF5]
            let (added, _) ← stepsWith keys next (presses "C-c a")
            return ([slots removed, slots next, slots added], added.state.echo)
          match program.runModel editorModel with
          | (.ok (seen, echo), model) =>
            let kept := (#[some "scratch", none, some "other"], some "other", true)
            seen ==
                [kept, kept,
                  (#[some "scratch", none, some "other", some "new"], some "other", true)] &&
              echo == "added 3" &&
              (model.display.scenes.back?.map fun scene => scene.views.map (shownText model)) ==
                some #[some "", some "other"]
          | (.error _, _) => false },
    { name :=
        "a command that closes a window and removes the buffer it showed gives up both with nothing refused: the markers before the text, and the scene shows the window that is left"
      run :=
        pure <|
          match
            dispatched (ran (asks [.removeWindow ⟨1⟩, .removeBuffer ⟨1⟩])) (presses "C-c g")
              twoBuffers with
          | some ((loop, _), scenes, model) =>
            loop.state.wellFormed && loop.state.echo == "" && model.texts.contents == #[""] &&
              (scenes.back?.map fun scene => (scene.echo, scene.views.map (·.id))) ==
                some ("", #[⟨0⟩])
          | none => false },
    { name :=
        "a window shown another buffer has the markers it had given up, and keeps the ones it was shown with"
      run :=
        pure <|
          let showing : EditorM Unit := do
            let text : TextId := ⟨1⟩
            let scroll ← text.mark (.anchor { offset := 0, bias := .before })
            let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
            asks [.show ⟨0⟩ ⟨1⟩ scroll selection]
          let program : EditorM (List (Option TextError) × List (Option TextError) × String) := do
            let state ← twoBuffers
            let some was := state.window? ⟨0⟩ | throw .noSuchMarker
            let (loop, _) ← stepsWith (ran showing) ({ state } : TestLoop) (presses "C-c g")
            let some now := loop.state.window? ⟨0⟩ | throw .noSuchMarker
            return (← markerRefusals was, ← markerRefusals now, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchMarker, some .noSuchMarker], [none, none], "") },
    { name :=
        "a command that closed a window and removed its buffer and was then refused gave up nothing: the window and the buffer are back, the window's markers and the buffer's text answer, and the scene shows both views"
      run :=
        pure <|
          let failing : Dispatched :=
            failingAfter fun _ => asks [.removeWindow ⟨1⟩, .removeBuffer ⟨1⟩]
          let program : EditorM (List (Option TextError) × String × Bool × String) := do
            let state ← twoBuffers
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let (loop, _) ← stepsWith (bound failing) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, ← (⟨1⟩ : TextId).read,
                loop.state.wellFormed && loop.state.windows == state.windows &&
                  loop.state.buffer? ⟨1⟩ == state.buffer? ⟨1⟩ &&
                  loop.state.frame == state.frame,
                loop.state.echo)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == ([none, none], "other", true, "go: refused: bad range") &&
              (model.display.scenes.back?.map fun scene => scene.views.map (shownText model)) ==
                some #[some "", some "other"]
          | (.error _, _) => false },
    { name :=
        "a release the store refuses, of a text the command released itself before it removed the buffer, is in the echo area of the scene, and the buffer is still removed"
      run :=
        pure <|
          let twice : EditorM Unit := do
            (⟨2⟩ : TextId).release
            asks [.removeBuffer ⟨2⟩]
          match dispatched (ran twice) (presses "C-c g") ((·.1) <$> hiddenBuffer) with
          | some ((loop, _), scenes, _) =>
            loop.state.echo == "refused: no such text" && loop.state.buffer? ⟨2⟩ == none &&
              loop.state.wellFormed &&
              scenes.back?.map (·.echo) == some "refused: no such text"
          | none => false },
    { name :=
        "the text of a buffer a command removed is not released while a buffer that is left is over the same text: the text still reads, the view of the buffer that is left shows it, and nothing is in the echo"
      run :=
        pure <|
          -- `alias`, which no window shows, is over the text of `other`,
          -- which view 1 shows.
          let shared : TextM EditorState := do
            let state ← twoBuffers
            let text : TextId := ⟨1⟩
            return { state with
                buffers :=
                  state.buffers.push
                    (some { name := "alias", text, history := ← UndoTree.over text }) }
          let program : EditorM (Option TextError × Array (Option String) × String × Bool) := do
            let (loop, _) ←
              stepsWith (ran (asks [.removeBuffer ⟨2⟩])) ({ state := ← shared } : TestLoop)
                  (presses "C-c g")
            return (← refusalOf (⟨1⟩ : TextId).read, loop.state.buffers.map (·.map (·.name)),
                loop.state.echo, loop.state.wellFormed)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == (none, #[some "scratch", some "other", none], "", true) &&
              (model.display.scenes.back?.map fun scene =>
                  (scene.echo, scene.views.map (shownText model))) ==
                some ("", #[some "", some "other"])
          | (.error _, _) => false },
    { name :=
        "a marker the store refuses to give up, the selection marker of a window the command gave up itself before it closed the window, is in the echo area of the scene: the window is still closed, and its other marker is still given up"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Array ViewId × Bool) := do
            let state ← threeWindows
            let some closed := state.window? ⟨1⟩ | throw .noSuchMarker
            let twice : EditorM Unit := do
              closed.selection.text.unmark closed.selection
              asks [.removeWindow ⟨1⟩]
            let (loop, _) ← stepsWith (ran twice) ({ state } : TestLoop) (presses "C-c g")
            return (← markerRefusals closed, loop.state.echo, loop.state.windows.map (·.id),
                loop.state.wellFormed)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result ==
                ([some .noSuchMarker, some .noSuchMarker], "refused: no such marker", #[⟨0⟩, ⟨2⟩],
                  true) &&
              model.display.scenes.back?.map (·.echo) == some "refused: no such marker"
          | (.error _, _) => false },
    { name :=
        "the snapshot of a save is released once a command that ended the save has run to its end, and not before: it still reads after the command that took it and began the save, and refuses noSuchSnapshot after the command that ended it, whether the save wrote the file or was refused, with nothing in the echo"
      run :=
        pure <|
          let program (key : String) :
            EditorM (Option TextError × Option TextError × Option Buffer.Saving × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let held ← refusalOf taken.read
            let (ended, _) ← stepsWith saveKeys begun (presses key)
            return (held, ← refusalOf taken.read, savingOf ended.state, ended.state.echo)
          ["C-c e", "C-c n"].all fun key =>
            ((program key).runModel editorModel).1.toOption ==
              some (none, some .noSuchSnapshot, none, "") },
    { name :=
        "a buffer removed while its save is in flight has the save's snapshot released with its text: each refuses, and nothing is in the echo"
      run :=
        pure <|
          let program : EditorM (Option TextError × Option TextError × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let (removed, _) ← stepsWith saveKeys begun (presses "C-c r")
            return (← refusalOf taken.read, ← refusalOf (⟨2⟩ : TextId).read, removed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (some .noSuchSnapshot, some .noSuchText, "") },
    { name :=
        "a command that ended a save and was then refused released nothing: the snapshot still reads, and the buffer's file is as it was before the command, with the save in flight and its old stamp"
      run :=
        pure <|
          let program : EditorM (Option TextError × Bool × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let some taken := (savingOf begun.state).map (·.snapshot) | throw .noSuchSnapshot
            let (failed, _) ← stepsWith saveKeys begun (presses "C-c f")
            return (← refusalOf taken.read,
                (savingOf failed.state).isSome &&
                  (failed.state.buffer? ⟨2⟩).map (·.file) == (begun.state.buffer? ⟨2⟩).map (·.file),
                failed.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (none, true, "fail: refused: bad range") },
    { name :=
        "a release of a save's snapshot that the store refuses, because the command released the snapshot itself before it ended the save, is in the echo area of the scene, and the save is still ended"
      run :=
        pure <|
          let program : EditorM (Option Buffer.Saving × String) := do
            let (begun, _) ←
              stepsWith saveKeys ({ state := ← savable } : TestLoop) (presses "C-c g")
            let (ended, _) ← stepsWith saveKeys begun (presses "C-c t")
            return (savingOf ended.state, ended.state.echo)
          match program.runModel editorModel with
          | (.ok result, model) =>
            result == (none, "refused: no such snapshot") &&
              model.display.scenes.back?.map (·.echo) == some "refused: no such snapshot"
          | (.error _, _) => false },
    { name :=
        "after a command that cancelled a prompt has run to its end the minibuffer is given up, though the last scene named a snapshot of its text: its text refuses noSuchText and each of its window's markers refuses, the window's text and markers still answer, and nothing is in the echo; the same after a command that accepted it"
      run :=
        pure <|
          [cancelPrompt, acceptPrompt].all fun close =>
            let keys := ran (discard close)
            let program :
              EditorM
                (Option TextError ×
                  Bool × Option TextError × List (Option TextError) × String × Bool) :=
              do
              let state ← promptedOver "ab"
              let some minibuffer := state.window? ⟨1⟩ | throw .noSuchMarker
              let some window := state.window? ⟨0⟩ | throw .noSuchMarker
              -- A scene of the open prompt first, so that the loop holds a
              -- snapshot of the minibuffer's text when the text is released.
              let (shown, _) ← stepsWith keys ({ state } : TestLoop) [pressF5]
              let (loop, _) ← stepsWith keys shown (presses "C-c g")
              return (← refusalOf minibuffer.scroll.text.read,
                  (← markerRefusals minibuffer).all (·.isSome), ← refusalOf window.scroll.text.read,
                  ← markerRefusals window, loop.state.echo,
                  loop.state.wellFormed && loop.state.prompt == none &&
                    loop.state.windows.map (·.id) == #[⟨0⟩])
            (program.runModel editorModel).1.toOption ==
              some (some .noSuchText, true, none, [none, none], "", true) },
    { name :=
        "a command that accepts a prompt and is then refused gives nothing up: the prompt is open again, its text reads what was typed, its window's markers answer, and nothing is answered"
      run :=
        pure <|
          let keys := bound (failingAfter fun _ => discard acceptPrompt)
          let program : EditorM (Option String × List (Option TextError) × String × Bool × Bool) :=
            do
            let state ← promptedOver "ab"
            let some minibuffer := state.window? ⟨1⟩ | throw .noSuchMarker
            let (loop, steps) ←
              stepsWith keys ({ state } : TestLoop) (.commit "c" :: presses "C-c g")
            return ((← observing minibuffer.scroll.text.read).toOption, ← markerRefusals minibuffer,
                loop.state.echo,
                loop.state.prompt == state.prompt && loop.state.frame.focused == ⟨1⟩ &&
                  loop.state.wellFormed,
                loop.state.answered.isEmpty &&
                  steps.back?.map (·.ended) == some (some (.refused .badRange)))
          (program.runModel editorModel).1.toOption ==
            some (some "abc", [none, none], "go: refused: bad range", true, true) }]

/-- A scheme written for the closed-view checks: the test scheme, with the
views it was stepped for kept beside its state, in the order they first
had a key, and a view it is told is closed dropped from them. -/
def remembering : InputScheme :=
  { State := TestScheme.State × List ViewId
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, if state.2.contains view then state.2 else state.2 ++ [view]), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    closeView := fun view state => (state.1, state.2.filter (· != view)) }

/-- The views `remembering` keeps in a loop's two states of the scheme: the
one after the last key, and the one at rest. -/
def remembered (loop : Loop remembering) : List ViewId × List ViewId :=
  let input : TestScheme.State × List ViewId := loop.input
  let atRest : TestScheme.State × List ViewId := loop.atRest
  (input.2, atRest.2)

/-- The checks of the scheme's notice of a closed view in the loop
(`Editor/Loop.lean`), on the editor's models. -/
def dispatchCloseViewChecks : List Check :=
  let focus : Dispatched := fun _ => do
    discard <| EditorState.ask (.focus ⟨1⟩)
    return none
  let close (call : Call) : EditorM Unit :=
    discard <| EditorState.ask (.removeWindow call.target.window.id)
  let keys : Loop.Keys remembering :=
    { maps := fun _ _ =>
        [Keymap.ofList
            [(ModelTest.keys "C-c 1", invoke "focus"), (ModelTest.keys "C-c x", invoke "close"),
              (ModelTest.keys "C-c f", invoke "fail")]]
      command? := fun name =>
        ([("focus", focus),
                  ("close", fun call => do
                    close call
                    return none),
                  ("fail", failingAfter close)].find?
              (·.1 == name)).map
          (·.2) }
  let program (last : String) : EditorM ((List ViewId × List ViewId) × Array ViewId) := do
    let loop : Loop remembering := { state := ← threeWindows }
    -- The key after the focus moved is view 1's, yields nothing and leaves
    -- nothing pending: the scheme then keeps view 1 in both its states.
    let (loop, _) ← stepsWith keys loop (presses "C-c 1" ++ [pressF5] ++ presses last)
    return (remembered loop, loop.state.windows.map (·.id))
  [{  name :=
        "after a command closed a view, the loop has told its scheme: neither state of the scheme it keeps holds anything for the view, and what they hold for the other views is kept"
      run :=
        pure <|
          ((program "C-c").runModel editorModel).1.toOption ==
              some (([⟨0⟩, ⟨1⟩], [⟨0⟩, ⟨1⟩]), #[⟨0⟩, ⟨1⟩, ⟨2⟩]) &&
            ((program "C-c x").runModel editorModel).1.toOption ==
              some (([⟨0⟩], [⟨0⟩]), #[⟨0⟩, ⟨2⟩]) },
    { name :=
        "a command that closed a view and was then refused closed nothing: the scheme is told of no closed view"
      run :=
        pure <|
          ((program "C-c f").runModel editorModel).1.toOption ==
            some (([⟨0⟩, ⟨1⟩], [⟨0⟩, ⟨1⟩]), #[⟨0⟩, ⟨1⟩, ⟨2⟩]) }]

/-- What `noticing` was told of a view. -/
inductive Notice where
  /-- The view is the minibuffer's. -/
  | minibuffer (view : ViewId)
  /-- The view is closed. -/
  | closed (view : ViewId)
  deriving DecidableEq, Repr

/-- A scheme written for the minibuffer-notice checks: the test scheme, with
what it was told kept beside its state, in the order it was told. -/
def noticing : InputScheme :=
  { State := TestScheme.State × List Notice
    Binding := Invocation
    init := ({}, [])
    step := fun maps view state key =>
      let (next, yielded) := TestScheme.step maps view state.1 key
      ((next, state.2), yielded)
    pending := (·.1.pending)
    command := fun name => { command := name }
    closeView := fun view state => (state.1, state.2 ++ [.closed view])
    openMinibuffer := fun view state => (state.1, state.2 ++ [.minibuffer view]) }

/-- What `noticing` was told, in a loop's two states of the scheme: the one
after the last key, and the one at rest. -/
def noticed (loop : Loop noticing) : List Notice × List Notice :=
  let input : TestScheme.State × List Notice := loop.input
  let atRest : TestScheme.State × List Notice := loop.atRest
  (input.2, atRest.2)

/-- The checks of the scheme's notice of the minibuffer's view in the loop
(`Editor/Loop.lean`), on the editor's models. -/
def dispatchMinibufferNoticeChecks : List Check :=
  let asks : EditorM Unit := discard <| prompt "Name: " asked
  let ran (run : EditorM Unit) : Dispatched := fun _ => do
    run
    return none
  let keys : Loop.Keys noticing :=
    { maps := fun _ _ =>
        [Keymap.ofList
            [(ModelTest.keys "C-c a", invoke "ask"), (ModelTest.keys "C-c f", invoke "fail"),
              (ModelTest.keys "C-c y", invoke "accept"), (ModelTest.keys "C-c s", invoke "swap"),
              (ModelTest.keys "C-c n", invoke "idle")]]
      command? := fun name =>
        ([("ask", ran asks), ("fail", failingAfter fun _ => asks), ("idle", ran (pure ())),
                  ("accept", ran (discard acceptPrompt)),
                  ("swap",
                    ran do
                      discard cancelPrompt
                      asks)].find?
              (·.1 == name)).map
          (·.2) }
  let told (typed : String) : Option ((List Notice × List Notice) × Option ViewId) :=
    let program : EditorM ((List Notice × List Notice) × Option ViewId) := do
      let loop : Loop noticing := { state := ← EditorState.initial ⟨640, 480⟩ }
      let (loop, _) ← stepsWith keys loop (presses typed)
      return (noticed loop, loop.state.minibufferView?)
    (program.runModel editorModel).1.toOption
  -- What the scheme was told once a prompt was asked for and `next` then ran
  -- one more command from the loop with the prompt open, with the
  -- minibuffer's view after that command and how it ended.
  let toldAfter (next : Loop noticing → EditorM (Option (Loop.Stepped noticing))) :
    Option ((List Notice × List Notice) × Option ViewId × Option Loop.Ending) :=
    let program :
      EditorM (Option ((List Notice × List Notice) × Option ViewId × Option Loop.Ending)) := do
      let loop : Loop noticing := { state := ← EditorState.initial ⟨640, 480⟩ }
      let (loop, _) ← stepsWith keys loop (presses "C-c a")
      return (← next loop).map fun stepped =>
          (noticed stepped.loop, stepped.loop.state.minibufferView?, stepped.ended)
    (program.runModel editorModel).1.toOption.join
  let typing (typed : String) (loop : Loop noticing) : EditorM (Option (Loop.Stepped noticing)) :=
    (·.2.back?) <$> stepsWith keys loop (presses typed)
  let both (notices : List Notice) := (notices, notices)
  [{  name :=
        "after a command that asked for a prompt, the loop has told its scheme that the new view is the minibuffer's, once, in both states of the scheme it keeps"
      run := pure (told "C-c a" == some (both [.minibuffer ⟨1⟩], some ⟨1⟩)) },
    { name :=
        "a key's command that runs to its end while the prompt stays open opened nothing: the scheme is told of the minibuffer's view by the command that opened it alone, so both its states still hold the one notice after a command that does nothing, and after one that asks again and is refused as a value"
      run :=
        pure <|
          ["C-c n", "C-c a"].all fun typed =>
            toldAfter (typing typed) == some (both [.minibuffer ⟨1⟩], some ⟨1⟩, some .finished) },
    { name :=
        "a job's command that runs to its end while the prompt stays open opened nothing: after its delivery both states of the scheme still hold the one notice"
      run :=
        pure
          (toldAfter (fun loop => return some (← loop.deliver keys "job" (pure ()))) ==
            some (both [.minibuffer ⟨1⟩], some ⟨1⟩, some .finished)) },
    { name :=
        "a command that asked for a prompt and was then refused opened nothing: the scheme is told nothing"
      run := pure (told "C-c f" == some (both [], none)) },
    { name :=
        "after the command that accepted the prompt, the loop has told both states of its scheme that the minibuffer's view is closed"
      run := pure (told "C-c a C-c y" == some (both [.minibuffer ⟨1⟩, .closed ⟨1⟩], none)) },
    { name :=
        "a command that closes one prompt and asks for another tells the scheme the first view is closed and then that the second is the minibuffer's"
      run :=
        pure
          (told "C-c a C-c s" ==
            some (both [.minibuffer ⟨1⟩, .closed ⟨1⟩, .minibuffer ⟨2⟩], some ⟨2⟩)) }]

/-- The history of the buffer `buffer` in `loop`'s state, as the loop keeps
it. -/
def treeOf {scheme : InputScheme} (loop : Loop scheme) (buffer : Nat := 0) : EditorM UndoTree := do
  let some held := loop.state.buffer? ⟨buffer⟩ | throw .noSuchText
  return held.history

/-- The checks of undo from a command in the loop (`Editor/Api.lean`,
`Editor/Loop.lean`), on the editor's models: a move in the history a key's
command made is the loop's after the step, and a boundary set by a command
that does not run to its end is rolled back with its edits; and, with the
scheme `switching`, two of whose keys begin and end an insert session of
the focused view, that what is edited in a session is one step of the
history. -/
def dispatchUndoChecks : List Check :=
  let undo : Dispatched := fun call => do
    discard <| call.target.window.buffer.undo
    return none
  let redo : Dispatched := fun call => do
    discard <| call.target.window.buffer.redo
    return none
  let keys :=
    dispatchKeys [("C-c s", invoke "stamp"), ("C-c u", invoke "undo"), ("C-c r", invoke "redo")]
      [("stamp", stamp), ("undo", undo), ("redo", redo)]
  -- What a step of a loop over `switching` is handed: beside the keys that
  -- begin and end a session, a key that stamps, one whose command edits and
  -- is refused, one that edits the second buffer, and one that focuses the
  -- second window.
  let sessions : Loop.Keys switching :=
    switchingKeys
      [("C-c s", invoke "stamp"), ("C-c f", invoke "fail"), ("C-c o", invoke "elsewhere"),
        ("C-c w", invoke "window")]
      [("stamp", stamp), ("fail", boom),
        ("elsewhere", fun _ => do
          discard <| (⟨1⟩ : BufferId).insertAt 0 "x"
          return none),
        ("window", fun _ => do
          discard <| (⟨1⟩ : ViewId).focus
          return none)]
  [{  name :=
        "a key's command that undoes keeps the move after the step: the text is the one before the last key's edit, the buffer's tree has nothing pending and no node made for the move, and the next key's redo gives the edit back"
      run :=
        pure <|
          let program : EditorM (List String × List Nat × Bool) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history, and the second the stamp.
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c s")
            let stamped ← focusedOf loop
            let (loop, _) ← stepsWith keys loop (presses "C-c u")
            let undone ← focusedOf loop
            let afterUndo ← undone.buffer.text.read
            let (again, _) ← stepsWith keys loop (presses "C-c r")
            let redone ← focusedOf again
            return ([afterUndo, ← redone.buffer.text.read],
                [stamped.buffer.history.nodes.size, undone.buffer.history.nodes.size,
                  redone.buffer.history.nodes.size],
                !undone.buffer.history.pending && loop.state.echo == "" &&
                  undone.buffer.history.current != stamped.buffer.history.current &&
                  redone.buffer.history.current == stamped.buffer.history.current)
          (program.runModel editorModel).1.toOption ==
            some (["abcd", "aC-c sd"], [3, 3, 3], true) },
    { name :=
        "a command that edits, sets a boundary in the history, edits again and then does not run to its end, refused or interrupted, is rolled back whole: the text and the window's selection are those before it, the echo area says how it ended and nothing of a move, the history has no step for it and nothing to redo, and the next key's edit is undone as one step"
      run :=
        pure <|
          -- An edit that moves the selection, the boundary, and an edit in
          -- the group the boundary opened.
          let bounded (call : Call) : EditorM Unit := do
            Loop.insert call.target "boom"
            discard <| call.target.window.buffer.closeGroup
            call.target.buffer.text.insert 0 "x"
          let spun : Dispatched := fun call => do
            bounded call
            for _ in [0:1000] do
              discard <| call.target.buffer.text.revision
            return none
          let keys :=
            dispatchKeys
              [("C-c b", invoke "bounded"), ("C-c l", invoke "spun"), ("C-c s", invoke "stamp")]
              [("bounded", failingAfter bounded), ("spun", spun), ("stamp", stamp)]
          -- `lowering` is what arrives after the command: the interrupt key
          -- that stopped it, taken off the queue, which lowers the flag.
          let program (failing : String) (lowering : List Received) :
            EditorM ((String × Array SelectionRange × String) × Bool × Bool × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history.
            let (loop, _) ← stepsWith keys loop [pressF5]
            let nodes := (← focusedOf loop).buffer.history.nodes.size
            let (loop, _) ← stepsWith keys loop (presses failing)
            let target ← focusedOf loop
            let failed := (← target.buffer.text.read, ← cursorsOf loop, loop.state.echo)
            let stepless :=
              target.buffer.history.nodes.size == nodes && !target.buffer.history.pending
            let redone ← target.buffer.history.redo Origin.user
            let loop ← takes keys loop lowering
            let (loop, _) ← stepsWith keys loop (presses "C-c s")
            let target ← focusedOf loop
            let after ← target.buffer.text.read
            let some _ ← target.buffer.history.undo | throw .noInverse
            return (failed, stepless, redone.isNone, after, ← target.buffer.text.read)
          let rolledBack (failing echo : String) (lowering : List Received) (watch : WatchModel) :
            Bool :=
            ((program failing lowering).runModel { editorModel with watch }).1.toOption ==
              some (("abcd", #[⟨1, 3⟩], echo), true, true, "aC-c sd", "abcd")
          rolledBack "C-c b" "bounded: refused: bad range" [] {} &&
            rolledBack "C-c l" "spun: interrupted" [interruptArrives] { arrivesAfter := some 20 } },
    { name :=
        "a command run while an edit is pending in the open group, which sets a boundary and is then refused, is rolled back to the point of the group it began at: the text is the one before it, no node was made, the edit from before it is still pending, and it is one step at the next boundary, which an undo takes back and a redo gives again"
      run :=
        pure <|
          let bounded : Dispatched :=
            failingAfter fun call => do
              Loop.insert call.target "boom"
              discard <| call.target.window.buffer.closeGroup
              call.target.buffer.text.insert 0 "x"
          let keys := dispatchKeys [] [("bounded", bounded)]
          let program : EditorM ((String × String × Nat × Bool) × Nat × String × String) := do
            -- No scene was published since the buffer was made holding
            -- `abcd`, so that edit is in the open group when the command
            -- starts.
            let ran ← Loop.run keys (← holding "abcd" #[⟨1, 3⟩]) (invoke "bounded") []
            let some left := ran.state.buffer? ⟨0⟩ | throw .noSuchText
            let failed :=
              (← left.text.read, ran.state.echo, left.history.nodes.size, left.history.pending)
            let (state, _) ← ran.state.recordHistories
            let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
            let some undone ← buffer.history.undo Origin.user | throw .noInverse
            let before ← buffer.text.read
            let some _ ← undone.tree.redo Origin.user | throw .noInverse
            return (failed, buffer.history.nodes.size, before, ← buffer.text.read)
          (program.runModel editorModel).1.toOption ==
            some (("abcd", "bounded: refused: bad range", 1, true), 2, "", "abcd") },
    { name :=
        "a command that sets a boundary, moves over the step it closed, there and back, and is then refused moved in the history: the move is not taken back, the echo area says so, and the tree the loop keeps is the one the command left, so the next key's undo takes the step back"
      run :=
        pure <|
          let crossing : Dispatched :=
            failingAfter fun call => do
              let buffer := call.target.window.buffer
              call.target.buffer.text.insert 0 "x"
              discard <| buffer.closeGroup
              discard <| buffer.undo
              discard <| buffer.redo
          let keys :=
            dispatchKeys [("C-c x", invoke "crossing"), ("C-c u", invoke "undo")]
              [("crossing", crossing), ("undo", undo)]
          let program : EditorM (String × String × String × String) := do
            let loop : TestLoop := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith keys loop ([pressF5] ++ presses "C-c x")
            let failed ← (← focusedOf loop).buffer.text.read
            let echo := loop.state.echo
            let (loop, _) ← stepsWith keys loop (presses "C-c u")
            return (failed, echo, ← (← focusedOf loop).buffer.text.read, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some
              ("xabcd", "crossing: refused: bad range; the command moved in the history", "abcd",
                "") },
    { name :=
        "two keys' edits made while the scheme reports the focused view as in an insert session, and then the key that ends the session, are one step of the history: no node is made inside the session, one is made when it ends, one undo gives the text from before the session and one redo the text after it"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool × List String) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- The first step records what the buffer was made holding as a
            -- step of the history.
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c s C-c s")
            let inside ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-e")
            let ended ← treeOf loop
            let typed ← ended.text.read
            let some undone ← ended.undo Origin.user | throw .noInverse
            let back ← ended.text.read
            let some _ ← undone.tree.redo Origin.user | throw .noInverse
            return ([before.nodes.size, inside.nodes.size, ended.nodes.size],
                [before.pending, inside.pending, ended.pending], [typed, back, ← ended.text.read])
          (program.runModel editorModel).1.toOption ==
            some ([2, 2, 3], [false, true, false], ["aC-c sC-c sd", "abcd", "aC-c sC-c sd"]) },
    { name :=
        "the same two keys' edits with no view in an insert session are two steps of the history, each closed after its event"
      run :=
        pure <|
          let program : EditorM (List Nat × Bool) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let between ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let after ← treeOf loop
            return ([before.nodes.size, between.nodes.size, after.nodes.size],
                between.pending || after.pending)
          (program.runModel editorModel).1.toOption == some ([2, 3, 4], false) },
    { name :=
        "a buffer is modified in the scene published after the first edit of an insert session, while its history has gained no node"
      run :=
        pure <|
          let program : EditorM (Nat × Nat) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, _) ← stepsWith sessions loop (presses "C-b")
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            return (before.nodes.size, (← treeOf loop).nodes.size)
          match program.runModel editorModel with
          | (.ok (before, inside), model) =>
            before == inside &&
              -- One scene a key: the key that begins the session, the
              -- prefix of the stamping sequence, and the key that stamps.
              model.display.scenes.map
                  (·.views.map (·.status.any (·.face == ModeLine.modifiedFace))) ==
                #[#[false], #[false], #[true]]
          | (.error _, _) => false },
    { name :=
        "a command that is refused inside an insert session is rolled back to the text from before it, with the session's earlier edit still pending and no node made; a later edit and the end of the session then make one step of both, which one undo takes back"
      run :=
        pure <|
          let program : EditorM ((String × String × Nat × Bool) × Nat × String × String) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop ([pressF5] ++ presses "C-b C-c s C-c f")
            let failed ← treeOf loop
            let rolled := (← failed.text.read, loop.state.echo, failed.nodes.size, failed.pending)
            let (loop, _) ← stepsWith sessions loop (presses "C-c s C-e")
            let ended ← treeOf loop
            let typed ← ended.text.read
            let some _ ← ended.undo Origin.user | throw .noInverse
            return (rolled, ended.nodes.size, typed, ← ended.text.read)
          (program.runModel editorModel).1.toOption ==
            some (("aC-c sd", "fail: refused: bad range", 2, true), 3, "aC-c sC-c sd", "abcd") },
    { name :=
        "an insert session in which nothing was edited makes no step of the history: the tree has no node more and nothing pending"
      run :=
        pure <|
          let program : EditorM (List Nat × Bool) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-b")
            let inside ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-e")
            let ended ← treeOf loop
            return ([before.nodes.size, inside.nodes.size, ended.nodes.size],
                inside.pending || ended.pending)
          (program.runModel editorModel).1.toOption == some ([2, 2, 2], false) },
    { name :=
        "of two buffers, the one shown by a view in an insert session has its group left open, and the one no such view shows has its group closed after each event"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool) := do
            let loop : Loop switching := { state := ← twoBuffers }
            let (loop, _) ← stepsWith sessions loop [pressF5]
            let (held, other) := (← treeOf loop, ← treeOf loop 1)
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c s C-c o")
            let (heldAfter, otherAfter) := (← treeOf loop, ← treeOf loop 1)
            return ([held.nodes.size, other.nodes.size, heldAfter.nodes.size,
                  otherAfter.nodes.size],
                [heldAfter.pending, otherAfter.pending])
          (program.runModel editorModel).1.toOption == some ([1, 1, 1, 2], [true, false]) },
    { name :=
        "of two windows on one buffer, one in an insert session, the buffer's group is left open after an edit made through the other window"
      run :=
        pure <|
          let program : EditorM (List Nat × List Bool × Option ViewId) := do
            let loop : Loop switching := { state := ← threeWindows }
            let (loop, _) ← stepsWith sessions loop (presses "C-b C-c w")
            let before ← treeOf loop
            let (loop, _) ← stepsWith sessions loop (presses "C-c s")
            let after ← treeOf loop
            return ([before.nodes.size, after.nodes.size], [before.pending, after.pending],
                some loop.state.frame.focused)
          (program.runModel editorModel).1.toOption == some ([1, 1], [false, true], some ⟨1⟩) }]

/-- A report as a command of the checks says it in the echo area. -/
def reportText (report : InputScheme.Report) : String :=
  reprStr report

/-- The command `say` of the report checks: it says the report its call
carries in the echo area (`reportText`). -/
def say : Dispatched := fun call => do
  message (reportText call.report)
  return none

/-- The checks of what a command is told of its view
(`Editor/Command/Call.lean`, `Editor/Loop.lean`), on the editor's models,
with the scheme `switching`, whose report a key's invocation switches, and
a command that says the report it was called with. -/
def dispatchReportChecks : List Check :=
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say")] (("say", say) :: commands)
  let echoes (text : String) (commands : List (String × Dispatched) := []) :
    Option (Array String) :=
    (switched (EditorState.initial ⟨640, 480⟩) text (handed := handed commands)).map
      (·.2.1.map (·.echo))
  [{  name :=
        "a command is called with what the scheme reports of its view: the default before any key switched it, and, for the key whose invocation switches the report, the switched report, since the command sees the scheme's state after its key; the next key's command is called with it too"
      run :=
        pure
          (echoes "C-s C-m C-s" [("mark", say)] ==
              some #[reportText {}, reportText markedReport, reportText markedReport] &&
            reportText markedReport != reportText {}) },
    { name :=
        "a command that is refused leaves the scheme at rest: the next key's command is called with the report from before the failed key, and not with the one that key would have switched to"
      run :=
        pure <|
          let failing : Dispatched := fun _ => throw .badRange
          match echoes "C-m C-b C-s" [("begin", failing)], echoes "C-m C-b C-s" with
          | some #[_, failed, after], some #[_, _, begun] =>
            failed == "begin: refused: bad range" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command run by its name, which no key yielded, is called with what the scheme reports of the focused view in the state the scheme is in"
      run :=
        pure <|
          let program : EditorM (String × String) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let fresh := (← loop.runNamed (handed []) "say").loop.state.echo
            let (loop, _) ← stepsWith (handed []) loop (presses "C-m")
            return (fresh, (← loop.runNamed (handed []) "say").loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some (reportText {}, reportText markedReport) },
    { name :=
        "under a scheme that says nothing of a view a command is called with the default report, by a key and by its name"
      run :=
        pure <|
          let keys := dispatchKeys [("C-s", invoke "say")] [("say", say)]
          let program : EditorM (String × String) := do
            let loop : TestLoop := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, _) ← stepsWith keys loop (presses "C-s")
            return (loop.state.echo, (← loop.runNamed keys "say").loop.state.echo)
          (program.runModel editorModel).1.toOption == some (reportText {}, reportText {}) }]

/-- The checks of a command that gives up (`giveUp`, `Editor/Api.lean`;
`Editor/Loop.lean`, "Running an invocation"), on the editor's models, with
the scheme `switching`, whose report a key's invocation switches, and
commands written here: the loop rolls the command back, says its reason in
the echo area with no `refused:`, and puts the scheme back in its state at
rest. -/
def dispatchCommandGivesUpChecks : List Check :=
  let reason := "nothing to do here"
  -- Edits the text, moves the selection, and then gives up.
  let quitter : Dispatched := fun call => do
    Loop.insert call.target "typed"
    giveUp reason
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say"), ("C-g", invoke "quitter")]
      ([("say", say), ("quitter", quitter)] ++ commands)
  [{  name :=
        "a key whose command edits and then gives up: the text and the selection are those before the command, the history has no step for it, the echo area reads the command's name and its reason with no refused, and the step says the command gave up"
      run :=
        pure <|
          let program :
            EditorM (String × Array SelectionRange × String × Bool × Bool × Option Loop.Ending) :=
            do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            -- A key that runs nothing: its publish records the fixture's own
            -- insertion as a step, so the count read here is the one to keep.
            let (loop, _) ← stepsWith (handed []) loop [pressF5]
            let some before := loop.state.focusedTarget? | throw .noSuchText
            let (loop, steps) ← stepsWith (handed []) loop (presses "C-g")
            let some target := loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, (← target.selection).ranges, loop.state.echo,
                target.buffer.history.nodes.size == before.buffer.history.nodes.size,
                target.buffer.history.pending, (steps.back?).bind (·.ended))
          (program.runModel editorModel).1.toOption ==
            some
              ("abcd", #[⟨1, 3⟩], s!"quitter: {reason}", true, false,
                some (Loop.Ending.gaveUp reason)) },
    { name :=
        "a command that gives up leaves the scheme at rest: the next key's command is told the report from before the key that gave up, and not the one that key would have switched to; the same key with a command that runs to its end switches it"
      run :=
        pure <|
          let giving : Dispatched := fun _ => giveUp reason
          let echoes (commands : List (String × Dispatched)) : Option (Array String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-m C-b C-s" (handed :=
                  handed commands)).map
              (·.2.1.map (·.echo))
          match echoes [("begin", giving)], echoes [] with
          | some #[_, gave, after], some #[_, _, begun] =>
            gave == s!"begin: {reason}" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command that has its buffer keep a value and then gives up leaves the editor state as it was: the buffer keeps no value under the name"
      run :=
        pure <|
          let keeping : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            giveUp reason
          let kept : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            return none
          let bound (name : String) : Loop.Keys switching :=
            switchingKeys [("C-k", invoke name)] [("keeping", keeping), ("kept", kept)]
          let after (name : String) : Option (Option Value × String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-k" (handed := bound name)).map
              fun (loop, _, _) => (loop.state.value? ⟨0⟩ "count", loop.state.echo)
          after "keeping" == some (none, s!"keeping: {reason}") &&
            after "kept" == some (some (.nat 7), "") },
    { name :=
        "a command that gives up inside an insert session leaves the session's earlier edit pending in the open group, with the text as the session left it: only what the command itself made is taken back"
      run :=
        pure <|
          let typing : Dispatched := fun call => do
            Loop.insert call.target "one"
            return none
          let program : EditorM (String × Bool × Nat × String) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let handed := handed [("begin", typing)]
            let (loop, _) ← stepsWith handed loop (presses "C-b C-g")
            let some target := loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, target.buffer.history.pending,
                target.buffer.history.nodes.size, loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some ("one", true, 1, s!"quitter: {reason}") },
    { name :=
        "a command that gives up, run by its name, ends the same way: rolled back, with its name and its reason in the echo area, and the step says it gave up"
      run :=
        pure <|
          let program : EditorM (String × String × Option Loop.Ending) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let stepped ← loop.runNamed (handed []) "quitter"
            let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, stepped.loop.state.echo, stepped.ended)
          (program.runModel editorModel).1.toOption ==
            some ("abcd", s!"quitter: {reason}", some (Loop.Ending.gaveUp reason)) }]

/-- The checks of a command that breaks off (`breakOff`, `Editor/Api.lean`;
`Editor/Loop.lean`, "Running an invocation"), on the editor's models, with
the scheme `switching`, whose report a key's invocation switches, and
commands written here: the loop keeps what the command did, says its reason
in the echo area with no `refused:`, and puts the scheme back in its state
at rest. -/
def dispatchCommandBreaksOffChecks : List Check :=
  let reason := "far enough"
  -- Edits the text, which moves the selection, and then breaks off or, with
  -- no reason, runs to its end.
  let editing (reason : Option String) : Dispatched := fun call => do
    Loop.insert call.target "typed"
    match reason with
    | some reason =>
      breakOff reason
    | none =>
      return none
  let handed (commands : List (String × Dispatched) := []) : Loop.Keys switching :=
    switchingKeys [("C-s", invoke "say"), ("C-g", invoke "stopper"), ("C-f", invoke "finisher")]
      ([("say", say), ("stopper", editing (some reason)), ("finisher", editing none)] ++ commands)
  -- What the key `key` leaves from a text with a selection: the text, the
  -- selection, the echo area, the history's nodes and whether an edit is
  -- pending in it, and how the step says the command ended.
  let left (key : String) :
    Option (String × Array SelectionRange × String × Nat × Bool × Option Loop.Ending) :=
    let program :
      EditorM (String × Array SelectionRange × String × Nat × Bool × Option Loop.Ending) := do
      let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
      let (loop, steps) ← stepsWith (handed []) loop (presses key)
      let some target := loop.state.focusedTarget? | throw .noSuchText
      return (← target.buffer.text.read, (← target.selection).ranges, loop.state.echo,
          target.buffer.history.nodes.size, target.buffer.history.pending,
          (steps.back?).bind (·.ended))
    (program.runModel editorModel).1.toOption
  [{  name :=
        "a key whose command edits and then breaks off: the text, the selection and the history are those the same command leaves when it runs to its end, which are not those from before it; the echo area reads the command's name and its reason with no refused, and the step says the command broke off"
      run :=
        pure <|
          match left "C-g", left "C-f" with
          | some (text, ranges, echo, nodes, pending, ended),
            some (finished, placed, said, steps, unclosed, how) =>
            text == finished && text != "abcd" && ranges == placed && ranges != #[⟨1, 3⟩] &&
              nodes == steps &&
              pending == unclosed &&
              echo == s!"stopper: {reason}" &&
              said.isEmpty &&
              ended == some (Loop.Ending.brokeOff reason) &&
              how == some .finished
          | _, _ => false },
    { name :=
        "a command that breaks off leaves the scheme at rest: the next key's command is told the report from before the key that broke off, and not the one that key would have switched to; the same key with a command that runs to its end switches it"
      run :=
        pure <|
          let breaking : Dispatched := fun _ => breakOff reason
          let echoes (commands : List (String × Dispatched)) : Option (Array String) :=
            (switched (EditorState.initial ⟨640, 480⟩) "C-m C-b C-s" (handed :=
                  handed commands)).map
              (·.2.1.map (·.echo))
          match echoes [("begin", breaking)], echoes [] with
          | some #[_, broke, after], some #[_, _, begun] =>
            broke == s!"begin: {reason}" && after == reportText markedReport &&
              begun == reportText { session := true }
          | _, _ => false },
    { name :=
        "a command that has its buffer keep a value, asks for an invocation to be run after it and then breaks off leaves the editor state it reached: the buffer keeps the value, and the step hands the invocation back"
      run :=
        pure <|
          let keeping : Dispatched := fun call => do
            discard <| call.target.window.buffer.setValue "count" (.nat 7)
            Editor.invoke { command := "say" }
            breakOff reason
          let bound : Loop.Keys switching :=
            switchingKeys [("C-k", invoke "keeping")] [("keeping", keeping)]
          let program : EditorM (Option Value × String × Array (Array String)) := do
            let loop : Loop switching := { state := ← EditorState.initial ⟨640, 480⟩ }
            let (loop, steps) ← stepsWith bound loop (presses "C-k")
            return (loop.state.value? ⟨0⟩ "count", loop.state.echo,
                steps.map fun step => step.answered.map (·.command))
          (program.runModel editorModel).1.toOption ==
            some (some (.nat 7), s!"keeping: {reason}", #[#["say"]]) },
    { name :=
        "a command that breaks off, run by its name, ends the same way: what it did stays, its name and its reason are in the echo area, and the step says it broke off"
      run :=
        pure <|
          let program : EditorM (String × String × Option Loop.Ending) := do
            let loop : Loop switching := { state := ← holding "abcd" #[⟨1, 3⟩] }
            let stepped ← loop.runNamed (handed []) "stopper"
            let some target := stepped.loop.state.focusedTarget? | throw .noSuchText
            return (← target.buffer.text.read, stepped.loop.state.echo, stepped.ended)
          match (program.runModel editorModel).1.toOption, left "C-f" with
          | some (text, echo, ended), some (finished, _) =>
            text == finished && echo == s!"stopper: {reason}" &&
              ended == some (Loop.Ending.brokeOff reason)
          | _, _ => false }]

/-- The checks of a command that has another run inside it (`runCommand`,
`Editor/Api.lean`; `Editor/Loop.lean`, "A command run inside another"), on
the editor's models, with commands written here: the command it names is
the one a key's invocation of that name runs, looked up in what the step
was handed. -/
def dispatchRunCommandChecks : List Check :=
  -- Runs the command its first argument names inside itself, with its own
  -- call but for the arguments, and says whether there was one.
  let outer : Dispatched := fun call => do
    let .str name :: arguments := call.arguments | giveUp "no command named"
    let ran ← runCommand name { call with arguments }
    message s!"{name} ran: {ran}"
    return none
  let write : Config.Write := { owner := .config, store := "cell", value := .nat 1 }
  let commands : List (String × Dispatched) :=
    [("outer", outer), ("stamp", stamp), ("writer", fun _ => return some write),
      ("quitter", fun call => do
        Loop.insert call.target "typed"
        giveUp "nothing to do here")]
  let handed : Loop.Keys TestScheme.scheme :=
    dispatchKeys
      [("C-s", { command := "outer", arguments := [.str "stamp", .nat 7] }),
        ("C-m", { command := "outer", arguments := [.str "missing"] }),
        ("C-w", { command := "outer", arguments := [.str "writer"] }),
        ("C-q", { command := "outer", arguments := [.str "quitter"] }), ("C-t", invoke "stamp")]
      commands
  -- What the key `key` leaves from a text with a cursor: the text, the echo
  -- area, the history's nodes, and how the step says the command ended.
  let left (key : String) : Option (String × String × Nat × Option Loop.Ending) :=
    let program : EditorM (String × String × Nat × Option Loop.Ending) := do
      let loop : TestLoop := { state := ← holding "ab" #[⟨2, 2⟩] }
      let (loop, _) ← stepsWith handed loop [pressF5]
      let (loop, steps) ← stepsWith handed loop (presses key)
      let some target := loop.state.focusedTarget? | throw .noSuchText
      return (← target.buffer.text.read, loop.state.echo, target.buffer.history.nodes.size,
          (steps.back?).bind (·.ended))
    (program.runModel editorModel).1.toOption
  [{  name :=
        "a command that has the command of a name run inside it runs the one a key's invocation of that name runs, with the call it hands it, as part of itself: what the two did is one step of the history, and the asking command goes on after it"
      run :=
        pure <|
          match left "C-s", left "C-t" with
          | some (text, echo, nodes, ended), some (alone, _, steps, _) =>
            text == "ab7 C-s" && alone == "abC-t" && echo == "stamp ran: true" && nodes == steps &&
              ended == some .finished
          | _, _ => false },
    { name :=
        "a name no command is registered under is answered false, and nothing runs: the asking command goes on"
      run :=
        pure <|
          (left "C-m").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
            some ("ab", "missing ran: false", some .finished) },
    { name :=
        "a command run inside another that gives up gives the asking command up: both are rolled back, and the reason is said under the asking command's name"
      run :=
        pure <|
          (left "C-q").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
            some ("ab", "outer: nothing to do here", some (.gaveUp "nothing to do here")) },
    { name :=
        "a command run inside another that asks for a store to be written gives the asking command up, with the sentence the loop makes of its name: only a command the loop runs has its write written back"
      run :=
        pure <|
          !(Loop.writesInside "writer").isEmpty &&
            (left "C-w").map (fun (text, echo, _, ended) => (text, echo, ended)) ==
              some
                ("ab", s!"outer: {Loop.writesInside "writer"}",
                  some (.gaveUp (Loop.writesInside "writer"))) }]

/-- The checks of key dispatch in the loop (`Editor/Loop.lean`), on the
editor's models: keys through the scheme and the commands they run,
rollback, the interrupt, the slow-command log, a command's state requests,
what the loop gives up after a command, a command that gives up, a command
that breaks off, a command that has another run inside it, the scheme's
notice of a closed view, undo from a command, and what a command is told of
its view. -/
def dispatchChecks : List Check :=
  dispatchKeyChecks ++ dispatchRollbackChecks ++ dispatchInterruptChecks ++ dispatchSlowChecks ++
    dispatchStateChecks ++
    twoWindowChecks ++
    dispatchGiveUpChecks ++
    dispatchCloseViewChecks ++
    dispatchMinibufferNoticeChecks ++
    dispatchUndoChecks ++
    dispatchReportChecks ++
    dispatchCommandGivesUpChecks ++
    dispatchCommandBreaksOffChecks ++
    dispatchRunCommandChecks

/-- What a step of the mode dispatch checks is handed: the active keymaps
`registry` makes for the test scheme from the loop's state, and, for every
name, a command that inserts its name at the cursors of the window it acts
on. -/
def modeKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { maps := registry.activeMaps TestScheme.scheme
    command? := fun name =>
      some fun call => do
        Loop.insert call.target name
        return none }

/-- The text each view shows after the keys `role` is on are pressed in a
loop over `registry`'s active keymaps, from the state `start` makes with
the focus on `view`; none when the run was refused. -/
def roleTyped (registry : Config.Registry) (start : TextM EditorState) (keys : List Key)
    (view : ViewId := ⟨0⟩) : Option (Array (Option String)) :=
  let focused : TextM EditorState := do
    return ((← start).focusWindow view).2
  (lastScene (modeKeys registry) (keys.map press) focused).map (·.2.2)

/-- The checks of modes in the loop (`Editor/Loop.lean`), on the editor's
models and the test scheme: a key a mode binds runs its command in a view
of a buffer that has the mode, and the global binding elsewhere. Each key
is the test scheme's for a role, or its leader, so no check names a key of
a scheme. -/
def modeDispatchChecks : List Check :=
  [{  name :=
        "a key of a role the buffer's major mode fills runs the mode's command in a view of that buffer, and the global binding of the key in a view of a buffer without the mode"
      run :=
        let start := withModes "major" []
        pure
          (roleTyped modeRegistry start (roleKeys Role.nextItem) ==
              some #[some "major-next-item", some "other"] &&
            roleTyped modeRegistry start (roleKeys Role.nextItem) ⟨1⟩ ==
              some #[some "", some "global-nextother"]) },
    { name :=
        "when a minor mode and the major mode fill the same role, the minor mode's command runs"
      run :=
        pure
          (roleTyped modeRegistry (withModes "major" ["m2"]) (roleKeys Role.nextItem) ==
            some #[some "m2-next-item", some "other"]) },
    { name :=
        "a derived mode runs its parent's command for a role it does not fill, and its own for one it does"
      run :=
        let start := withModes "child" []
        pure
          (roleTyped modeRegistry start (roleKeys Role.refresh) ==
              some #[some "base-refresh", some "other"] &&
            roleTyped modeRegistry start (roleKeys Role.mark) ==
              some #[some "child-mark", some "other"]) },
    { name := "the scheme's leader followed by a mode's suffix runs that mode's local command"
      run :=
        let registry :=
          modeRegistry.replaceModes .config
            #[{ filling "major" [Role.nextItem] with locals := [("C-x", "major-local")] }]
        let typed := TestScheme.scheme.leader ++ keys "C-x"
        pure
          (roleTyped registry (withModes "major" []) typed ==
              some #[some "major-local", some "other"] &&
            roleTyped registry (withModes "major" []) typed ⟨1⟩ == some #[some "", some "other"]) }]

/-- The candidates the prompts of the candidate checks are asked with. The
one a check types whole, `w`, is last, and two before it hold a `w`. -/
def pickCandidates : Array String :=
  #["wq", "edit", "rewrite", "w"]

/-- The continuation the prompts of the candidate checks are asked with:
the command `picked` and an argument of the asker's own. -/
def pickContinuation : Invocation :=
  { command := "picked", arguments := [.nat 7] }

/-- What the command `picked` of the candidate checks says in the echo
area: the arguments it was called with. -/
def picked (arguments : List Argument) : String :=
  s!"picked {arguments.map argumentText}"

/-- The label of the prompts of the candidate checks. -/
def pickLabel : String :=
  "Pick: "

/-- The commands of the candidate checks, by name.

- `ask-pick` asks `Pick: ` with the candidates `pickCandidates`, from a
  function, and the continuation `pickContinuation`; `ask-pick-w` asks the
  same with the initial value `w`; `ask-plain` asks with no candidates.
- `picked` says what it was called with (`picked`).
- `accept` and `cancel` are the API's operations.
- The test scheme's self-insert inserts its argument at its target's
  cursors.
- `still` does nothing, and `edit-then-fail` inserts `x` at its target's
  cursors and is then refused. -/
def candidateCommands : List (String × Dispatched) :=
  let asks (initial : String) (candidates : EditorM (Array String)) : Dispatched := fun _ => do
    discard <| prompt pickLabel pickContinuation initial (candidates := candidates)
    return none
  [("ask-pick", asks "" (pure pickCandidates)), ("ask-pick-w", asks "w" (pure pickCandidates)),
    ("ask-plain", asks "" (pure #[])),
    ("picked", fun call => do
      message (picked call.arguments)
      return none),
    ("accept", fun _ => do
      discard acceptPrompt
      return none),
    ("cancel", fun _ => do
      discard cancelPrompt
      return none),
    ((TestScheme.selfInsert "").command, fun call => do
      let [.str text] := call.arguments | throw .badRange
      call.target.insertAtSelections text
      return none),
    ("still", fun _ => return none),
    ("edit-then-fail", failingAfter fun call => call.target.insertAtSelections "x")]

/-- What a step of the candidate checks is handed: one keymap, the same for
every view, the minibuffer's among them, that binds a key sequence under
`C-c` to each command of `candidateCommands` but the self-insert and
`picked`, which no key runs. No key of it prints, so a key that prints is
a self-insert. -/
def candidateKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-c a", invoke "ask-pick"), ("C-c w", invoke "ask-pick-w"), ("C-c p", invoke "ask-plain"),
      ("C-c y", invoke "accept"), ("C-c n", invoke "cancel"), ("C-c s", invoke "still"),
      ("C-c f", invoke "edit-then-fail")]
    candidateCommands

/-- A driver over the initial state, with the commands of the candidate
checks and the jobs of the driver checks, on the models `model`; `none` if
making the state was refused. -/
def candidateDriver (model : EditorModel := editorModel) : Option TestDriver :=
  (Loop.Driver.over candidateKeys driverJobs (EditorState.initial ⟨640, 480⟩) model).toOption

/-- The registry of the candidate checks that press the minibuffer's keys:
the minibuffer's commands and its mode registered for the owner `compiled`,
as a host registers them, and as config's bindings two that ask and two
that run the commands that move through the list by their names, from any
view. -/
def pickRegistry : Config.Registry :=
  ((({} : Config.Registry).replace .compiled Minibuffer.commands).replaceModes .compiled
        Minibuffer.modes).replaceBindings
    .config
    ([("C-c a", "ask-pick"), ("C-c p", "ask-plain"), ("C-c 3", Minibuffer.nextName),
          ("C-c 4", Minibuffer.previousName)].toArray.map
      fun (text, command) => { keys := keys text, command })

/-- What a step of those checks is handed: the active keymaps `pickRegistry`
makes for the test scheme from the loop's state, so the minibuffer's mode
holds in the minibuffer's view and nowhere else; the registry's commands,
each given its call; and, for any other name, the commands of the candidate
checks. -/
def pickKeys : Loop.Keys TestScheme.scheme :=
  { maps := pickRegistry.activeMaps TestScheme.scheme
    command? := fun name =>
      match pickRegistry.find? name with
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => (candidateCommands.find? (·.1 == name)).map (·.2) }

/-- A driver of those checks over the initial state, with the jobs of the
driver checks; `none` if making the state was refused. -/
def pickDriver : Option TestDriver :=
  (Loop.Driver.over pickKeys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- What a prompt asked with `pickCandidates` holds once they are listed
for `pattern`, with `chosen` as its choice: the listing is what the fuzzy
model answers for the pattern, so no order is written out here. -/
def pickListed (pattern : String) (chosen : Option Nat := none) : Candidates :=
  { all := pickCandidates, listedFor := some pattern
    listed := (FuzzyModel.rank pattern pickCandidates).filterMap (pickCandidates[·]?), chosen }

/-- `driver` with the choice of its open prompt moved by `steps`, through
the state and not by a command. -/
def chose (driver : TestDriver) (steps : List Candidates.Step) : TestDriver :=
  { driver with
    loop :=
      { driver.loop with
        state :=
          steps.foldl (fun state step => (state.chooseCandidate step).2) driver.loop.state } }

/-- The status line of the minibuffer's view of a prompt of the candidate
checks whose minibuffer holds `pattern`: the label, then a field for each
candidate the fuzzy model answers for the pattern, in its order, with the
one at `chosen` of them, if any, in the chosen face. -/
def pickFields (pattern : String) (chosen : Option Nat := none) : Array StatusField :=
  #[{ text := pickLabel, face := Loop.promptFace }] ++
    (pickListed pattern).listed.mapIdx fun index candidate =>
      { text := candidate
        face := if chosen == some index then Loop.chosenFace else Loop.candidateFace }

/-- The editor's models, but that every read of a whole text is refused
with `noSuchText` and changes nothing: a fake written for the one check
that needs the listing's read refused where no history and no view is. A
released text refuses all three, so its check cannot tell whose refusal the
echo holds. -/
def refusingReads : (request : EditorRequest) → EditorModel → request.Reply × EditorModel
  | .text (.read _), model => (.error .noSuchText, model)
  | request, model => EditorModel.handle request model

/-- The checks of a prompt's candidates through the loop
(`Editor/Loop.lean`, "Prompts"), on the loop's driver over the editor's
models and the test scheme, with commands written here: the listing the
loop makes before each scene, and the scene's fields for it, and what the
loop does when the listing's read is refused. What is listed is compared
with what the fuzzy model answers for the same pattern and candidates. -/
def candidateChecks : List Check :=
  [{  name :=
        "after the step that asked for a prompt with candidates the listing is for the initial text, the empty one or one given, and nothing is chosen"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (given, _) := fedTo driver (presses "C-c w")
            candidatesOf asking == some (pickListed "") &&
              (candidatesOf asking).map (·.listed.size) == some pickCandidates.size &&
              candidatesOf given == some (pickListed "w") &&
              minibufferText given == some "w" },
    { name :=
        "after each key typed into a prompt with candidates the listing is for the text typed so far: a candidate that is the text is first though it is last among the candidates, a text one candidate matches lists that one, and a text none matches lists none"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (one, _) := fedTo driver (presses "C-c a w")
            let (two, _) := fedTo one (presses "q")
            let (three, _) := fedTo two (presses "z")
            candidatesOf one == some (pickListed "w") &&
              (candidatesOf one).map (·.listed[0]?) == some (some "w") &&
              (candidatesOf one).map (·.listed.size) == some 3 &&
              pickCandidates.back? == some "w" &&
              candidatesOf two == some (pickListed "wq") &&
              (candidatesOf two).map (·.listed) == some #["wq"] &&
              candidatesOf three == some (pickListed "wqz") &&
              (candidatesOf three).map (·.listed) == some #[] &&
              minibufferText three == some "wqz" },
    { name :=
        "a key whose command leaves the minibuffer's text as it was leaves the listing and a choice as they were, and a key typed after it forgets the choice with the listing it was made in"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let chosen := chose typed [.next, .next]
            let (still, _) := fedTo chosen (presses "C-c s")
            let (more, _) := fedTo still (presses "q")
            candidatesOf chosen == some (pickListed "w" (some 1)) &&
              candidatesOf still == some (pickListed "w" (some 1)) &&
              candidatesOf more == some (pickListed "wq") },
    { name :=
        "a command that edits the minibuffer and is then refused is rolled back to the text, the listing and the choice from before it"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let chosen := chose typed [.next]
            let (failed, _) := fedTo chosen (presses "C-c f")
            minibufferText failed == some "w" &&
              candidatesOf failed == some (pickListed "w" (some 0)) &&
              failed.loop.state.prompt.isSome },
    { name :=
        "what the listing costs, counted on the watch model's clock: a prompt with candidates is published with one request more than one with none, the read of the minibuffer, while its text is as it was, and with two more, the read and the ranking, at the step that asked for it and at each step that changed the text"
      run :=
        pure <|
          match candidateDriver countingModel with
          | none => false
          | some driver =>
            -- How many requests the last of `keys` took.
            let cost (keys : String) : Nat :=
              let events := presses keys
              let (before, _) := fedTo driver events.dropLast
              let (after, _) := fedTo before (events.drop (events.length - 1))
              after.model.watch.clock - before.model.watch.clock
            let plainAsk := cost "C-c p"
            let plainStill := cost "C-c p C-c s"
            let plainTyped := cost "C-c p w"
            plainAsk > 0 && plainStill > 0 && cost "C-c a" == plainAsk + 2 &&
              cost "C-c a C-c s" == plainStill + 1 &&
              cost "C-c a w" == plainTyped + 2 &&
              cost "C-c a w C-c s" == plainStill + 1 },
    { name :=
        "text typed into a prompt with candidates: in the scene, the minibuffer's view's status line is the label, in the prompt's face, and then one field for each candidate the fuzzy model answers for that text, in its order, each in the candidates' face; the other view's status line lists none"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (typed, _) := fedTo asking (presses "e")
            pickStatus asking == some (pickFields "") &&
              (pickStatus asking).map (·.size) == some (1 + pickCandidates.size) &&
              pickStatus typed == some (pickFields "e") &&
              (pickStatus typed).map (·.size) == some 3 &&
              (statusIn typed ⟨0⟩).map (·.any (·.face == Loop.candidateFace)) == some false },
    { name :=
        "where a candidate is the typed text and others match it too, its field is the first after the label, though it is the last of the candidates"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            pickStatus typed == some (pickFields "w") &&
              ((pickStatus typed).map fun fields => (fields.map (·.text)).extract 0 2) ==
                some #[pickLabel, "w"] &&
              (pickStatus typed).map (·.size) == some 4 &&
              pickCandidates.back? == some "w" },
    { name :=
        "a text no candidate matches: the scene lists none, and the minibuffer's status line is the label alone; so is that of a prompt asked with no candidates"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a z")
            let (plain, _) := fedTo driver (presses "C-c p w")
            let label : Array StatusField := #[{ text := pickLabel, face := Loop.promptFace }]
            pickStatus typed == some label && pickStatus plain == some label &&
              minibufferText typed == some "z" },
    { name :=
        "with a candidate chosen, its field of the minibuffer's status line and no other is in the chosen face, and the fields say what they said"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let (second, _) := fedTo (chose typed [.next, .next]) (presses "C-c s")
            let (unchosen, _) := fedTo (chose second [.next, .next]) (presses "C-c s")
            pickStatus second == some (pickFields "w" (some 1)) &&
              ((pickStatus second).map fun fields => fields.map (·.face == Loop.chosenFace)) ==
                some #[false, false, true, false] &&
              Loop.chosenFace != Loop.candidateFace &&
              candidatesOf unchosen == some (pickListed "w") &&
              pickStatus unchosen == some (pickFields "w") },
    { name :=
        "text is typed, the key of the role next-item is pressed and then the accept key: the continuation's command runs with the first listed candidate as its first argument, which is not the typed text, and its own argument after it; the prompt is closed"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a e")
            let (chosen, _) := fedTo typed (rolePresses Role.nextItem)
            let (accepted, _) := fedTo chosen (rolePresses Role.activate)
            let first := (pickListed "e").listed[0]?
            !(rolePresses Role.nextItem).isEmpty && first.isSome && first != some "e" &&
              candidatesOf chosen == some (pickListed "e" (some 0)) &&
              minibufferText chosen == some "e" &&
              first.map (fun candidate => picked [.str candidate, .nat 7]) ==
                some (promptEcho accepted) &&
              accepted.loop.state.prompt == none },
    { name :=
        "the keys of the roles next-item and previous-item move the choice through the listing, and the scene's chosen field follows: next twice is the second, previous then the first, previous again nothing, and previous from nothing the last"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let next := rolePresses Role.nextItem
            let previous := rolePresses Role.previousItem
            let (typed, _) := fedTo driver (presses "C-c a w")
            let (second, _) := fedTo typed (next ++ next)
            let (first, _) := fedTo second previous
            let (unchosen, _) := fedTo first previous
            let (last, _) := fedTo unchosen previous
            !previous.isEmpty && previous != next &&
              candidatesOf second == some (pickListed "w" (some 1)) &&
              pickStatus second == some (pickFields "w" (some 1)) &&
              candidatesOf first == some (pickListed "w" (some 0)) &&
              pickStatus first == some (pickFields "w" (some 0)) &&
              candidatesOf unchosen == some (pickListed "w") &&
              pickStatus unchosen == some (pickFields "w") &&
              candidatesOf last == some (pickListed "w" (some 2)) &&
              pickStatus last == some (pickFields "w" (some 2)) &&
              minibufferText last == some "w" },
    { name :=
        "the next key from the last listed candidate chooses nothing, and the accept key then gives the continuation the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let next := rolePresses Role.nextItem
            let (typed, _) := fedTo driver (presses "C-c a e")
            let (last, _) := fedTo typed (next ++ next)
            let (past, _) := fedTo last next
            let (accepted, _) := fedTo past (rolePresses Role.activate)
            (pickListed "e").listed.size == 2 &&
              candidatesOf last == some (pickListed "e" (some 1)) &&
              candidatesOf past == some (pickListed "e") &&
              promptEcho accepted == picked [.str "e", .nat 7] },
    { name :=
        "a key typed after a choice forgets it: the listing is the one for the new text, with nothing chosen, and the accept key gives the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (chosen, _) := fedTo driver (presses "C-c a e" ++ rolePresses Role.nextItem)
            let (typed, _) := fedTo chosen (presses "d")
            let (accepted, _) := fedTo typed (rolePresses Role.activate)
            candidatesOf chosen == some (pickListed "e" (some 0)) &&
              candidatesOf typed == some (pickListed "ed") &&
              pickStatus typed == some (pickFields "ed") &&
              promptEcho accepted == picked [.str "ed", .nat 7] },
    { name :=
        "a text no candidate matches: the scene lists none, the next key and the previous key change nothing, and the accept key gives the continuation the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a z")
            let (moved, _) :=
              fedTo typed (rolePresses Role.nextItem ++ rolePresses Role.previousItem)
            let (accepted, _) := fedTo moved (rolePresses Role.activate)
            let label : Array StatusField := #[{ text := pickLabel, face := Loop.promptFace }]
            candidatesOf typed == some (pickListed "z") &&
              (candidatesOf typed).map (·.listed) == some #[] &&
              pickStatus typed == some label &&
              candidatesOf moved == candidatesOf typed &&
              pickStatus moved == some label &&
              minibufferText moved == some "z" &&
              promptEcho accepted == picked [.str "z", .nat 7] &&
              accepted.loop.state.prompt == none },
    { name :=
        "in a prompt with no candidates the next key and the previous key change nothing, and the accept key gives the typed text"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c p w")
            let (moved, _) :=
              fedTo typed (rolePresses Role.nextItem ++ rolePresses Role.previousItem)
            let (accepted, _) := fedTo moved (rolePresses Role.activate)
            candidatesOf moved == some {} && minibufferText moved == some "w" &&
              promptEcho accepted == picked [.str "w", .nat 7] },
    { name :=
        "with no prompt open, the command that moves to the next candidate and the one that moves to the previous, each run by its name, say that no prompt is open, and nothing else changes"
      run :=
        pure <|
          match pickDriver with
          | none => false
          | some driver =>
            let (next, _) := fedTo driver (presses "C-c 3")
            let (previous, _) := fedTo driver (presses "C-c 4")
            !Minibuffer.notOpen.isEmpty && promptEcho next == Minibuffer.notOpen &&
              promptEcho previous == Minibuffer.notOpen &&
              next.loop.state.prompt == none &&
              { next.loop.state with echo := "" } == driver.loop.state },
    { name :=
        "an event once the minibuffer's text was released behind a prompt with candidates is not refused: a scene is published with the refusal in its echo, the loop keeps that echo, and the prompt's listing and choice are as they were"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let chosen := chose typed [.next, .next]
            match minibufferTextId chosen with
            | none => false
            | some text =>
              let (released, texts) := text.release.runModel chosen.model.texts
              let (after, steps) :=
                fedTo { chosen with model := { chosen.model with texts } } [pressF5]
              released.toOption.isSome && promptEcho chosen == "" && steps.size == 1 &&
                steps.all (·.isSome) &&
                promptEcho after == "refused: no such text" &&
                after.model.display.scenes.size == chosen.model.display.scenes.size + 1 &&
                after.model.display.scenes.back?.map (·.echo) == some "refused: no such text" &&
                candidatesOf chosen == some (pickListed "w" (some 1)) &&
                candidatesOf after == candidatesOf chosen &&
                after.loop.state.wellFormed },
    { name :=
        "a refusal of the listing's read alone, on models that refuse every read of a text and nothing else: the step is not refused, the scene has the refusal in its echo with every view and the minibuffer's status line as it was, and the listing and the choice are as they were"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let (chosen, _) := fedTo (chose typed [.next, .next]) (presses "C-c s")
            let step := chosen.loop.take chosen.handed { event := pressF5, stamp := 0 }
            match Program.run (port := editorPort) refusingReads step.run chosen.model with
            | (.error _, _) => false
            | (.ok stepped, model) =>
              let after := chosen.took stepped model
              promptEcho chosen == "" && stepped.next == .continue &&
                promptEcho after == "refused: no such text" &&
                model.display.scenes.size == chosen.model.display.scenes.size + 1 &&
                model.display.scenes.back?.map (·.echo) == some "refused: no such text" &&
                (model.display.scenes.back?.map fun scene => scene.views.map (·.id)) ==
                  (chosen.model.display.scenes.back?.map fun scene => scene.views.map (·.id)) &&
                pickStatus chosen == some (pickFields "w" (some 1)) &&
                pickStatus after == pickStatus chosen &&
                candidatesOf after == some (pickListed "w" (some 1)) &&
                after.loop.state.wellFormed }]

/-- The checks of the files a window asks to open (`Event.openFiles`): the
loop runs the open command with them (`Editor/Loop.lean`, "What each event
does"), on the driver of the file command checks. No file is touched. -/
def openFilesChecks : List Check :=
  let note := inFiles "note.txt"
  let crlf := inFiles "crlf.txt"
  let asked (paths : List System.FilePath) : Option TestDriver :=
    filesDriver.map fun driver => (fedTo driver [.openFiles (paths.map (·.toString))]).1
  [{  name :=
        "an open-files input of two paths, once both loads are finished, leaves two new buffers holding those files"
      run :=
        pure <|
          match asked [note, crlf] with
          | none => false
          | some asked =>
            let (both, _) := (asked.finish 1).1.finish 2
            let state := both.loop.state
            state.buffers.size == 3 && state.findFile note == some ⟨1⟩ &&
              state.findFile crlf == some ⟨2⟩ &&
              (state.buffer? ⟨1⟩).map (·.name) == some "note.txt" &&
              (state.buffer? ⟨2⟩).map (·.name) == some "crlf.txt" &&
              both.model.texts.contents[1]? == some FileCases.noteText &&
              state.wellFormed },
    { name :=
        "after an open-files input the focused view shows the buffer of its last path, whichever order its loads would finish in: only one is in flight at a time"
      run :=
        pure <|
          match asked [note, crlf] with
          | none => false
          | some asked =>
            let (first, _) := asked.finish 1
            let (both, _) := first.finish 2
            -- Only the first path's load is in flight after the event: the
            -- second cannot finish before it, since it has not started.
            asked.pending.map (·.name) == #[Files.loadJob] && (asked.finish 2).2.isNone &&
              first.pending.map (·.id) == #[2] &&
              (showing both both.loop.state.frame.focused).map (·.id) ==
                both.loop.state.findFile crlf &&
              (both.loop.state.findFile crlf).isSome },
    { name := "an open-files input of one path selects that path's buffer once its load is finished"
      run :=
        pure <|
          match asked [note] with
          | none => false
          | some asked =>
            let (opened, _) := asked.finish 1
            (showing asked).map (·.id) == some ⟨0⟩ && (showing opened).map (·.id) == some ⟨1⟩ &&
              (showing opened).bind (·.text) == some FileCases.noteText },
    { name := "an open-files input with no path starts nothing and publishes a scene"
      run :=
        pure <|
          match filesDriver with
          | none => false
          | some driver =>
            let (after, steps) := fedTo driver [.openFiles []]
            after.pending.isEmpty && steps.map (·.map (·.next)) == #[some .continue] &&
              after.model.display.scenes.size == driver.model.display.scenes.size + 1 &&
              after.loop.state.buffers.size == 1 },
    { name :=
        "an open-files input is run as `open-file` is: config's command of that name runs in its place"
      run :=
        pure <|
          let keys : Loop.Keys TestScheme.scheme :=
            dispatchKeys []
              [(Files.openName, fun call => do
                  message s!"mine: {call.arguments.length}"
                  return none)]
          match
            (Loop.Driver.over keys fileJobs (EditorState.initial ⟨640, 480⟩)
                editorModel).toOption with
          | none => false
          | some driver =>
            let driver := { driver with jobs := { files := commandFiles } }
            let (after, _) := fedTo driver [.openFiles [note.toString, crlf.toString]]
            echoOf after == some "mine: 2" && after.pending.isEmpty &&
              after.loop.state.buffers.size == 1 }]

/-- What the command `leave` of the quit checks says in the echo area when
it is refused, for a buffer called `name`. -/
def notLeaving (name : String) : String :=
  s!"not leaving: {name}"

/-- What a step of the quit checks is handed: the open command with the
path of `note.txt` (`C-o n`) and the save command (`C-o w`), as the file
command checks have them, and six commands written here, under `C-l`:
`leave` (`l`) asks the editor to quit and says a refusal (`notLeaving`),
`leave-then-fail` (`f`) asks and is then refused, `stamp` (`s`) edits its
buffer, `other` (`o`) says `other`, `hand-leave` (`h`) asks for `leave`
to be run after it, and `hand-leave-other` (`t`) asks for `leave` and then
`other` to be run after it. Two more ask for the config to be reloaded: `again`
(`r`), and `again-then-fail` (`g`), which asks and is then refused; and two
ask for the theme `second` to be loaded, which the loop is told is
registered: `pick` (`p`), and `pick-then-fail` (`k`), which asks and is then
refused. -/
def quitKeys : Loop.Keys TestScheme.scheme :=
  {
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o w", invoke Files.saveName),
        ("C-l l", invoke "leave"), ("C-l f", invoke "leave-then-fail"), ("C-l s", invoke "stamp"),
        ("C-l o", invoke "other"), ("C-l h", invoke "hand-leave"),
        ("C-l t", invoke "hand-leave-other"), ("C-l r", invoke "again"),
        ("C-l g", invoke "again-then-fail"), ("C-l p", invoke "pick"),
        ("C-l k", invoke "pick-then-fail")]
      [(Files.openName, fun call => do
          Files.openCommand call
          return none),
        (Files.saveName, fun call => do
          Files.saveCommand call
          return none),
        ("leave", fun _ => do
          if let .error (.unsaved name)← quit then
            message (notLeaving name)
          return none),
        ("leave-then-fail", failingAfter fun _ => discard quit), ("stamp", stamp),
        ("other", fun _ => do
          message "other"
          return none),
        ("hand-leave", fun _ => do
          Editor.invoke { command := "leave" }
          return none),
        ("hand-leave-other", fun _ => do
          Editor.invoke { command := "leave" }
          Editor.invoke { command := "other" }
          return none),
        ("again", fun _ => do
          reloadConfig
          return none),
        ("again-then-fail", failingAfter fun _ => reloadConfig),
        ("pick", fun _ => do
          discard <| loadTheme "second"
          return none),
        ("pick-then-fail", failingAfter fun _ => discard <| loadTheme "second")] with
    registered := { themeNames := #["second"] } }

/-- A driver of the quit checks over the files `files`, with the file
`note.txt` open in view 0: the open command, and its job finished. The load
is job 1. -/
def quitDriver (files : FileModel := commandFiles) : Option TestDriver :=
  (Loop.Driver.over quitKeys fileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => ((fedTo { driver with jobs := { files } } (presses "C-o n")).1.finish 1).1

/-- The checks of quitting in the loop (`Editor/Loop.lean`, "Quit"), on the
loop's driver over the editor's models and the model of files, with
commands written here: the step says stop once the editor can leave, a quit
waits for a save in flight, and a quit that cannot go ahead is withdrawn.
They name no ex name. -/
def dispatchQuitChecks : List Check :=
  let next (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array (Option Loop.Next) :=
    steps.map (·.map (·.next))
  let path := inFiles "note.txt"
  [{  name :=
        "a key whose command asks the editor to quit: the step publishes a scene, the last, and says stop, and the driver has stopped; a step that ran another command says continue"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (other, went) := fedTo driver (presses "C-l o")
            let (left, steps) := fedTo other (presses "C-l l")
            next went == #[some .continue, some .continue] && !other.stopped &&
              next steps == #[some .continue, some .stop] &&
              left.stopped &&
              left.loop.state.quitting &&
              left.model.display.scenes.size == other.model.display.scenes.size + 2 },
    { name :=
        "a command that asks the editor to quit and is then refused says continue, and the state is not asked to quit"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (failed, steps) := fedTo driver (presses "C-l f")
            next steps == #[some .continue, some .continue] && !failed.stopped &&
              !failed.loop.state.quitting &&
              promptEcho failed == "leave-then-fail: refused: bad range" },
    { name :=
        "asked to quit while a save is in flight, the step says continue and the editor waits: a key fed meanwhile is handled, the delivery of the save's result says stop, and the file then holds the buffer's text"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let text := "x" ++ FileCases.noteText
            let (saving, _) := fedTo driver ([.commit "x"] ++ presses "C-o w")
            let (asked, steps) := fedTo saving (presses "C-l l")
            let (meanwhile, went) := fedTo asked (presses "C-l o")
            let (left, delivered) := meanwhile.finish 2
            next steps == #[some .continue, some .continue] && promptEcho asked == "" &&
              asked.loop.state.quitting &&
              !asked.stopped &&
              next went == #[some .continue, some .continue] &&
              promptEcho meanwhile == "other" &&
              meanwhile.loop.state.quitting &&
              !meanwhile.stopped &&
              delivered.map (·.next) == some .stop &&
              left.stopped &&
              bytesOf left path == some (FileModel.encode text) &&
              (showing left).map (·.buffer.isModified) == some false },
    { name :=
        "asked to quit while a save is in flight that is then refused, the file having changed behind the editor: the delivery says continue, the state is no longer asked to quit, the echo area has the save's refusal, and the buffer is still modified"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let changed := rewritten driver path JobContract.otherFile
            let (asked, _) := fedTo changed ([.commit "x"] ++ presses "C-o w C-l l")
            let (refused, delivered) := asked.finish 2
            asked.loop.state.quitting && delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              (showing refused).map (·.buffer.isModified) == some true &&
              bytesOf refused path == some JobContract.otherFile },
    { name :=
        "asked to quit while a save of a buffer that is not modified is in flight, which is then refused, the file having changed behind the editor: the delivery says continue, the driver has not stopped, the state is no longer asked to quit, and the echo area has the save's refusal"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let changed := rewritten driver path JobContract.otherFile
            let (asked, _) := fedTo changed (presses "C-o w C-l l")
            let (refused, delivered) := asked.finish 2
            asked.loop.state.quitting && !asked.stopped &&
              (showing asked).map (·.buffer.isModified) == some false &&
              delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) &&
              bytesOf refused path == some JobContract.otherFile },
    { name :=
        "an edit made while a quit waits for a save withdraws it: the state is no longer asked to quit after the edit's step, and the delivery of the save's result says continue, with the file written and the buffer still modified"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver ([.commit "x"] ++ presses "C-o w C-l l")
            let (edited, steps) := fedTo asked [.commit "y"]
            let (saved, delivered) := edited.finish 2
            asked.loop.state.quitting && next steps == #[some .continue] &&
              !edited.loop.state.quitting &&
              delivered.map (·.next) == some .continue &&
              !saved.stopped &&
              !saved.loop.state.quitting &&
              bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
              (showing saved).map (·.buffer.isModified) == some true },
    { name :=
        "a command that asks to quit with a file's buffer modified is refused and the editor goes on; once the buffer is saved the same key stops it"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (refused, steps) := fedTo driver ([.commit "x"] ++ presses "C-l l")
            let (saved, _) := fedTo refused (presses "C-o w")
            let (saved, _) := saved.finish 2
            let (left, last) := fedTo saved (presses "C-l l")
            promptEcho refused == notLeaving "note.txt" && !refused.loop.state.quitting &&
              steps.all (·.all (·.next == .continue)) &&
              !saved.stopped &&
              next last == #[some .continue, some .stop] &&
              left.stopped },
    { name :=
        "a close request while a file's buffer has unsaved changes: the step says continue and publishes one scene, whose echo area has the quit command's refusal, the state is not asked to quit, and the next key's command runs"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (edited, _) := fedTo driver [.commit "x"]
            let (refused, steps) := fedTo edited [.closeRequested]
            let (after, _) := fedTo refused (presses "C-l o")
            next steps == #[some .continue] &&
              refused.model.display.scenes.size == edited.model.display.scenes.size + 1 &&
              echoOf refused == some (Ex.notQuitting (.unsaved "note.txt")) &&
              !refused.loop.state.quitting &&
              !refused.stopped &&
              promptEcho after == "other" },
    { name :=
        "a close request with nothing unsaved publishes one scene, the last, and says stop, and the driver has stopped"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (left, steps) := fedTo driver [.closeRequested]
            next steps == #[some .stop] && left.stopped &&
              left.model.display.scenes.size == driver.model.display.scenes.size + 1 },
    { name :=
        "a close request while a save is in flight says continue, and the delivery of the save's result says stop"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (asked, steps) :=
              fedTo driver ([.commit "x"] ++ presses "C-o w" ++ [.closeRequested])
            let (left, delivered) := asked.finish 2
            steps.back?.join.map (·.next) == some .continue && asked.loop.state.quitting &&
              !asked.stopped &&
              delivered.map (·.next) == some .stop &&
              left.stopped },
    { name :=
        "a close request while a save is in flight that is then refused, the file having changed behind the editor: the delivery says continue, the driver has not stopped, and the echo area has the save's refusal"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let path := inFiles "note.txt"
            let changed := rewritten driver path JobContract.otherFile
            let (asked, steps) :=
              fedTo changed ([.commit "x"] ++ presses "C-o w" ++ [.closeRequested])
            let (refused, delivered) := asked.finish 2
            steps.back?.join.map (·.next) == some .continue && asked.loop.state.quitting &&
              delivered.map (·.next) == some .continue &&
              !refused.stopped &&
              !refused.loop.state.quitting &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) },
    { name :=
        "the driver records that a step said stop when the step was one it ran for an invocation a command asked for: the fed step says continue and the driver has stopped"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (left, steps) := fedTo driver (presses "C-l h")
            next steps == #[some .continue, some .continue] && left.stopped &&
              left.loop.state.quitting },
    { name :=
        "once a step said stop the driver runs no further invocation: a command that asks for a quitting command and then another to be run after it stops the driver at the first, whose scene is the last, and the second never runs: no scene says its message; where the first is refused, the second runs"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let echoes (before after : TestDriver) : Array String :=
              (after.model.display.scenes.map (·.echo)).extract before.model.display.scenes.size
            let (left, steps) := fedTo driver (presses "C-l t")
            let (went, _) := fedTo driver ([.commit "x"] ++ presses "C-l t")
            next steps == #[some .continue, some .continue] && left.stopped &&
              left.model.display.scenes.size == driver.model.display.scenes.size + 3 &&
              !(echoes driver left).contains "other" &&
              !went.stopped &&
              promptEcho went == "other" &&
              (echoes driver went).contains (notLeaving "note.txt") },
    { name :=
        "a step whose command asked for the config to be reloaded hands the request back, and the state after it is not asking; a step that ran another command hands back none, and so does one whose command asked and was then refused; the driver counts the reloads asked for"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let asked (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
              steps.map (·.map (·.reload))
            let (once, steps) := fedTo driver (presses "C-l r")
            let (other, went) := fedTo once (presses "C-l o")
            let (failed, lost) := fedTo other (presses "C-l g")
            let (twice, _) := fedTo failed (presses "C-l r")
            asked steps == #[some false, some true] && !once.loop.state.reload &&
              once.reloads == 1 &&
              asked went == #[some false, some false] &&
              asked lost == #[some false, some false] &&
              !failed.loop.state.reload &&
              failed.reloads == 1 &&
              twice.reloads == 2 &&
              driver.reloads == 0 },
    { name :=
        "a step whose command asked for a theme to be loaded hands its name back, and the state after it holds none; a step that ran another command hands back none, and so does one whose command asked and was then refused; the driver records the themes asked for"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let asked (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
              steps.map (·.map (·.theme))
            let (once, steps) := fedTo driver (presses "C-l p")
            let (other, went) := fedTo once (presses "C-l o")
            let (failed, lost) := fedTo other (presses "C-l k")
            asked steps == #[some none, some (some "second")] && once.loop.state.theme == none &&
              once.themes == #["second"] &&
              asked went == #[some none, some none] &&
              asked lost == #[some none, some none] &&
              failed.loop.state.theme == none &&
              failed.themes == #["second"] &&
              driver.themes == #[] }]

/-- The compiled quit command (`Ex.quitCommand`), as the system quit checks
register it. -/
def compiledQuit : Dispatched := fun call => do
  Ex.quitCommand call
  return none

/-- What a step of the system quit checks is handed: the open command with
the path of `note.txt` (`C-o n`) and the save command (`C-o w`), as the
quit checks have them, and `quit` (`Ex.quitName`), bound to `C-l q`, as
`command` does it: the compiled one, or one config registered in its
place. -/
def systemQuitKeys (command : Dispatched := compiledQuit) : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-o n", opens (inFiles "note.txt")), ("C-o w", invoke Files.saveName),
      ("C-l q", invoke Ex.quitName)]
    [(Files.openName, fun call => do
        Files.openCommand call
        return none),
      (Files.saveName, fun call => do
        Files.saveCommand call
        return none),
      (Ex.quitName, command)]

/-- A driver of the system quit checks, with `quit` as `command` does it
and the file `note.txt` open in view 0, as `quitDriver` opens it. -/
def systemQuitDriver (command : Dispatched := compiledQuit) : Option TestDriver :=
  (Loop.Driver.over (systemQuitKeys command) fileJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver =>
    ((fedTo { driver with jobs := { files := commandFiles } } (presses "C-o n")).1.finish 1).1

/-- How many times `driver`'s frame was asked to keep running. -/
def keptRunning (driver : TestDriver) : Nat :=
  (driver.model.display.asked.filter (· == .keepRunning)).size

/-- The checks of the system's quit in the loop (`Editor/Loop.lean`,
"Quit"): `Event.quitRequested` runs `quit` as an invocation no key yielded,
so the editor leaves as it does for `:q`, or keeps running and asks the
frame `keepRunning` once, when `quit` is refused or a quit it asked is
withdrawn. -/
def systemQuitChecks : List Check :=
  let next (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array (Option Loop.Next) :=
    steps.map (·.map (·.next))
  let path := inFiles "note.txt"
  [{  name :=
        "the system asks to quit with nothing unsaved: the step says stop, the driver has stopped, and the frame is not asked to keep running"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (left, steps) := fedTo driver [.quitRequested]
            next steps == #[some .stop] && left.stopped && keptRunning left == 0 },
    { name :=
        "the system asks to quit with a file's buffer that has unsaved changes: the editor goes on, the echo area says why, the frame is asked to keep running once, and the system's quit is no longer pending; a later edit asks nothing more"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (refused, steps) := fedTo driver [.commit "x", .quitRequested]
            let (edited, _) := fedTo refused [.commit "y"]
            next steps == #[some .continue, some .continue] && !refused.stopped &&
              echoOf refused == some (Ex.notQuitting (.unsaved "note.txt")) &&
              echoOf refused == some "quit: note.txt has unsaved changes" &&
              keptRunning refused == 1 &&
              !refused.loop.state.systemQuit &&
              keptRunning edited == 1 },
    { name :=
        "the system asks to quit with a save in flight: the step says continue and asks nothing, and the delivery of the save's result says stop; when that save is refused, the delivery says continue, the frame is asked to keep running once, and the echo area has the save's refusal"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (saving, _) := fedTo driver ([.commit "x"] ++ presses "C-o w")
            let (asked, steps) := fedTo saving [.quitRequested]
            let (left, delivered) := asked.finish 2
            let changed := rewritten driver path JobContract.otherFile
            let (refusing, _) := fedTo changed ([.commit "x"] ++ presses "C-o w")
            let (pending, _) := fedTo refusing [.quitRequested]
            let (refused, undelivered) := pending.finish 2
            next steps == #[some .continue] && !asked.stopped && keptRunning asked == 0 &&
              delivered.map (·.next) == some .stop &&
              left.stopped &&
              keptRunning left == 0 &&
              keptRunning pending == 0 &&
              undelivered.map (·.next) == some .continue &&
              !refused.stopped &&
              keptRunning refused == 1 &&
              !refused.loop.state.systemQuit &&
              echoOf refused == some (Files.notSaved path (.changed (stampOf changed path))) },
    { name :=
        "config's command named quit runs in place of the compiled one on the system's quit: its message is the echo, and since nothing asked to quit the frame is asked to keep running once"
      run :=
        pure <|
          match
            systemQuitDriver fun _ => do
              message "mine"
              return none with
          | none => false
          | some driver =>
            let (ran, steps) := fedTo driver [.commit "x", .quitRequested]
            next steps == #[some .continue, some .continue] && !ran.stopped &&
              echoOf ran == some "mine" &&
              keptRunning ran == 1 &&
              !ran.loop.state.systemQuit },
    { name :=
        "a quit typed, not asked by the system, that is refused asks the frame nothing: it was the editor's own quit"
      run :=
        pure <|
          match systemQuitDriver with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver ([.commit "x"] ++ presses "C-l q")
            !refused.stopped && echoOf refused == some (Ex.notQuitting (.unsaved "note.txt")) &&
              keptRunning refused == 0 }]

/-- The mode line's field that says a buffer's file changed on disk: the
`changed` segment's (`ModeLine.changed`). -/
def changedField : StatusField :=
  ModeLine.field ModeLine.changedMark ModeLine.changedFace

/-- `driver` once the file at `path` is gone. -/
def removed (driver : TestDriver) (path : System.FilePath) : TestDriver :=
  { driver with
    jobs :=
      { driver.jobs with
        files :=
          { driver.jobs.files with files := driver.jobs.files.files.filter (·.path != path) } } }

/-- `driver` after the frame lost the keyboard focus and gained it again, and
the check that started finished. -/
def focusChecked (driver : TestDriver) : TestDriver :=
  finishNamed (fedTo driver [.focus false, .focus true]).1 Files.checkJob

/-- The checks of the staleness check (`Files.checkWork`, `Loop.fileJobs`,
`Editor/Loop.lean`, "Files that changed on disk"), with auto-reload off, on
the loop's driver over the editor's models and the model of files, with the
commands and the jobs compiled code registers. -/
def stalenessChecks : List Check :=
  let textOf (driver : TestDriver) : Option String := (showing driver).bind (·.text)
  let note := inFiles "note.txt"
  [{  name :=
        "criterion 5: the first edit to a buffer whose file changed is refused and the next lands: after a check started by the focus coming back, the first edit leaves the text, says the file changed and names :e, with no modified field, and the second edit lands"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let checked := focusChecked rewritten
            let (refused, _) := fedTo checked (presses "C-o x")
            let (landed, _) := fedTo refused (presses "C-o x")
            textOf refused == some FileCases.noteText &&
              echoOf refused == some (Files.changedOnDisk note) &&
              statusOf refused == some (named "note.txt" ++ #[changedField]) &&
              textOf landed == some ("x" ++ FileCases.noteText) &&
              statusOf landed == some (namedModified "note.txt" ++ #[changedField]) },
    { name :=
        "a committed text after a change on disk is dropped the same way, and the next commit lands"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (refused, _) := fedTo (focusChecked rewritten) [.commit "a"]
            let (landed, _) := fedTo refused [.commit "b"]
            textOf refused == some FileCases.noteText &&
              echoOf refused == some (Files.changedOnDisk note) &&
              textOf landed == some ("b" ++ FileCases.noteText) },
    { name :=
        "the first edit of an unmodified file buffer starts a check: the edit lands, and once the check is finished the buffer is marked and the echo area gives both resolutions"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (edited, _) := fedTo rewritten (presses "C-o x")
            let checked := finishNamed edited Files.checkJob
            textOf edited == some ("x" ++ FileCases.noteText) &&
              (pendingOf edited Files.checkJob).isSome &&
              statusOf checked == some (namedModified "note.txt" ++ #[changedField]) &&
              echoOf checked == some (Files.changedUnderEdits note) },
    { name :=
        "a file that is gone is marked: the first edit is refused saying :w! writes it again, and the next lands"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let checked := focusChecked (removed rewritten note)
            let (refused, _) := fedTo checked (presses "C-o x")
            let (landed, _) := fedTo refused (presses "C-o x")
            ((heldFile checked).bind (·.changed)).map (·.found) == some none &&
              echoOf refused == some (Files.goneFromDisk note) &&
              textOf refused == some FileCases.noteText &&
              textOf landed == some ("x" ++ FileCases.noteText) },
    { name :=
        "criterion 6: switching to a buffer whose file changed marks its status line and leaves its text; switching to one whose file did not change adds no field; and the focus coming back marks every changed buffer"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let (both, _) := fedTo rewritten (presses "C-o l")
            let both := finishNamed both Files.loadJob
            let (switched, _) := fedTo both (exLine "b note.txt")
            let switched := finishNamed switched Files.checkJob
            let (back, _) := fedTo switched (exLine "b lf.txt")
            let back := finishNamed back Files.checkJob
            let focused := focusChecked both
            let noteOf (driver : TestDriver) : Option Bool :=
              (driver.loop.state.buffer? ⟨1⟩).bind (·.file.map (·.changed.isSome))
            let lfOf (driver : TestDriver) : Option Bool :=
              (driver.loop.state.buffer? ⟨2⟩).bind (·.file.map (·.changed.isSome))
            (showing switched).map (·.buffer.name) == some "note.txt" &&
              statusOf switched == some (named "note.txt" ++ #[changedField]) &&
              textOf switched == some FileCases.noteText &&
              statusOf back == some (named "lf.txt") &&
              noteOf focused == some true &&
              lfOf focused == some false },
    { name :=
        "with no check job registered nothing is checked: the focus coming back and a first edit start nothing"
      run :=
        pure <|
          match noteOpen with
          | none => false
          | some opened =>
            let rewritten := rewritten opened (inFiles "note.txt") reloadedBytes
            let (stepped, steps) := fedTo rewritten [.focus false, .focus true, .commit "x"]
            (steps.all fun step => (step.map (·.starts.isEmpty)).getD false) &&
              stepped.pending.isEmpty },
    { name :=
        "the save criterion, with no check run: a save of a buffer whose file changed on disk writes nothing and says so, both with no check job registered and with the check the first edit started still unfinished; the file keeps the other program's bytes"
      run :=
        pure <|
          match noteOpen, noteRewritten with
          | some unchecked, some behind =>
            -- No check job is registered here: the first edit starts none.
            let changed := rewritten unchecked note reloadedBytes
            let (saving, _) := fedTo changed ([.commit "x"] ++ presses "C-o w")
            let refused := finishNamed saving Files.saveJob
            -- The check the first edit starts is left unfinished.
            let (pending, _) := fedTo behind [.commit "x"]
            let (asked, _) := fedTo pending (exLine "w")
            let held := finishNamed asked Files.saveJob
            (pendingOf saving Files.checkJob).isNone && (pendingOf saving Files.saveJob).isSome &&
              bytesOf refused note == some reloadedBytes &&
              echoOf refused == some (Files.notSaved note (.changed (stampOf changed note))) &&
              (pendingOf pending Files.checkJob).isSome &&
              (pendingOf held Files.checkJob).isSome &&
              (heldFile held).bind (·.changed) == none &&
              (pendingOf asked Files.saveJob).isSome &&
              bytesOf held note == some reloadedBytes &&
              echoOf held == some (Files.notSaved note (.changed (stampOf behind note))) &&
              textOf held == some ("x" ++ FileCases.noteText)
          | _, _ => false },
    { name :=
        "the mark's state requests: a result for another stamp changes nothing, one for the buffer's stamp marks it, one that finds that stamp clears it, telling sets told, and a save that wrote the file clears it"
      run :=
        pure <|
          match noteRewritten with
          | none => false
          | some rewritten =>
            let state := rewritten.loop.state
            match (heldFile rewritten) with
            | none => false
            | some file =>
              let other : File.Stamp := { file.stamp with size := file.stamp.size + 1 }
              let changedOf (state : EditorState) :=
                (state.buffer? ⟨1⟩).bind (·.file.bind (·.changed))
              let (_, stale) := state.markChanged ⟨1⟩ other (some other) false
              let (_, marked) := state.markChanged ⟨1⟩ file.stamp (some other) false
              let (_, cleared) := marked.markChanged ⟨1⟩ file.stamp (some file.stamp) false
              let (_, told) := marked.tellChanged ⟨1⟩
              let (_, began) := told.beginSave ⟨1⟩ ⟨0⟩ ⟨0⟩
              let (_, saved) := began.endSave ⟨1⟩ ⟨0⟩ (some other)
              let text := ((state.buffer? ⟨1⟩).map (·.text)).getD ⟨0⟩
              changedOf stale == none &&
                changedOf marked == some { found := some other, told := false } &&
                changedOf cleared == none &&
                changedOf told == some { found := some other, told := true } &&
                (marked.untold? text).isSome &&
                (told.untold? text).isNone &&
                changedOf saved == none }]

/-- `reloadDriver` whose watches may be made in `fileRoot`, with `note.txt`
open in view 0 and its load finished. -/
def watchedNote : Option TestDriver :=
  reloadDriver.map fun driver =>
    let driver :=
      { driver with
        jobs :=
          { driver.jobs with
            fileWatches := { driver.jobs.fileWatches with directories := #[fileRoot] } } }
    finishNamed (fedTo driver (presses "C-o n")).1 Files.loadJob

/-- The starts every step of `steps` handed back, by name. -/
def startNames (steps : Array (Option (Loop.Stepped TestScheme.scheme))) : Array String :=
  steps.flatMap fun step => ((step.map (·.starts)).getD #[]).map (·.name)

/-- The checks of auto-reload (`Editor/Loop.lean`, "Auto-reload"), on the
loop's driver over the editor's models, the model of files and the model of
watches, whose waiting jobs it holds parked (`Loop.Driver.touch`). -/
def autoReloadChecks : List Check :=
  let textOf (driver : TestDriver) : Option String := (showing driver).bind (·.text)
  let note := inFiles "note.txt"
  [{  name :=
        "criterion 7: with auto-reload off no file buffer has a watch open: through opening two files, switching, the focus going and coming, an edit, a reload, closing one and a change on disk, no follow job is started, none is parked, and the watch model started none; with autoread two are open, bd ends one and noautoread the other"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (two, s1) := fedTo opened (presses "C-o l")
            let two := finishNamed two Files.loadJob
            let (switched, s2) := fedTo two (exLine "b note.txt")
            let (focused, s3) :=
              fedTo (finishNamed switched Files.checkJob) [.focus false, .focus true]
            let (edited, s4) := fedTo (finishNamed focused Files.checkJob) (presses "C-o x")
            let (reloading, s5) := fedTo (finishNamed edited Files.checkJob) (presses "C-o R")
            let (closed, s6) := fedTo (finishNamed reloading Files.reloadJob) (exLine "bd lf.txt")
            let touched := (rewritten closed note reloadedBytes).touch #[(note, .written)]
            let steps := s1 ++ s2 ++ s3 ++ s4 ++ s5 ++ s6
            let (on, _) := fedTo two (exLine "autoread")
            let (one, _) := fedTo on (exLine "bd lf.txt")
            let (off, _) := fedTo one (exLine "noautoread")
            !(startNames steps).contains Files.followJob &&
              [two, switched, focused, edited, reloading, closed, touched].all
                (fun driver =>
                  driver.openWatches == 0 && driver.jobs.fileWatches.next == 1 &&
                    driver.jobs.fileWatches.ended.isEmpty) &&
              on.openWatches == 2 &&
              one.openWatches == 1 &&
              off.openWatches == 0 &&
              off.jobs.fileWatches.ended.size == 2 },
    { name :=
        "criterion 8: with auto-reload on, an injected change shows the file's new text: one watch is parked, the change resumes it, its follow finishes and reloads, and the buffer then holds the new text with no modified or changed field, and a watch parked again"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (on, _) := fedTo opened (exLine "autoread")
            let changed := (rewritten on note reloadedBytes).touch #[(note, .written)]
            let followed := finishNamed changed Files.followJob
            let reloaded := finishNamed followed Files.reloadJob
            -- After the reload the follow is on the new stamp: a later
            -- change to the buffer, now edited, marks it.
            let (edited, _) := fedTo reloaded (presses "C-o x")
            let edited := finishNamed edited Files.checkJob
            let again := rewritten edited note ("again\n".toUTF8 ++ reloadedBytes)
            let marked := finishNamed (again.touch #[(note, .written)]) Files.followJob
            on.openWatches == 1 && (pendingOf changed Files.followJob).isSome &&
              (pendingOf followed Files.reloadJob).isSome &&
              textOf reloaded == some reloadedText &&
              statusOf reloaded == some (named "note.txt") &&
              reloaded.openWatches == 1 &&
              statusOf marked == some (namedModified "note.txt" ++ #[changedField]) &&
              marked.openWatches == 1 },
    { name :=
        "a deleted file is marked and waited on: no reload, the text kept, the changed field with nothing found, one watch parked and a further step starts no follow; the file put back is reloaded"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (on, _) := fedTo opened (exLine "autoread")
            let gone := finishNamed ((removed on note).touch #[(note, .removed)]) Files.followJob
            let (later, steps) := fedTo gone [.preedit ""]
            let back :=
              finishNamed ((rewritten later note reloadedBytes).touch #[(note, .created)])
                Files.followJob
            let reloaded := finishNamed back Files.reloadJob
            (pendingOf gone Files.reloadJob).isNone && textOf gone == some FileCases.noteText &&
              statusOf gone == some (named "note.txt" ++ #[changedField]) &&
              ((heldFile gone).bind (·.changed)).map (·.found) == some none &&
              gone.openWatches == 1 &&
              !(startNames steps).contains Files.followJob &&
              textOf reloaded == some reloadedText &&
              statusOf reloaded == some (named "note.txt") },
    { name :=
        "criterion 10 on the model: a modified buffer keeps its text and is marked, the follow armed again on what was found, so a touch with no further change starts nothing; two changes leave one parked watch, the mark on the second stamp"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let (on, _) := fedTo opened (exLine "autoread")
            let (edited, _) := fedTo on (presses "C-o x")
            let edited := finishNamed edited Files.checkJob
            let first := rewritten edited note reloadedBytes
            let marked := finishNamed (first.touch #[(note, .written)]) Files.followJob
            let quiet := marked.touch #[(note, .written)]
            let second := rewritten quiet note ("again\n".toUTF8 ++ reloadedBytes)
            let twice := finishNamed (second.touch #[(note, .written)]) Files.followJob
            let (later, steps) := fedTo twice [.preedit ""]
            textOf marked == some ("x" ++ FileCases.noteText) &&
              (pendingOf marked Files.reloadJob).isNone &&
              statusOf marked == some (namedModified "note.txt" ++ #[changedField]) &&
              (pendingOf quiet Files.followJob).isNone &&
              quiet.openWatches == 1 &&
              ((heldFile twice).bind (·.changed)).map (·.found) == some (stampOf twice note) &&
              twice.openWatches == 1 &&
              (pendingOf twice Files.followJob).isNone &&
              !(startNames steps).contains Files.followJob &&
              later.openWatches == 1 },
    { name :=
        "a refused watch is said in words and says how to retry: the echo area has the refusal's sentence, not its constructor, and that auto-reload is off for the buffer until noautoread then autoread, which starts a follow again"
      run :=
        pure <|
          -- No directory may be watched here, so the follow's watch is
          -- refused.
          match reloadDriver with
          | none => false
          | some fresh =>
            let opened := finishNamed (fedTo fresh (presses "C-o n")).1 Files.loadJob
            let (on, _) := fedTo opened (exLine "autoread")
            let refused := finishNamed on Files.followJob
            let (later, steps) := fedTo refused [.preedit ""]
            let (off, _) := fedTo later (exLine "noautoread")
            let (retried, _) := fedTo off (exLine "autoread")
            let error : FileWatchError := .notFound s!"cannot watch {note}: {fileRoot} is not there"
            (pendingOf on Files.followJob).isSome &&
              echoOf refused == some (Files.notFollowing note error.describe) &&
              (echoOf refused).map (·.endsWith Files.followRetry) == some true &&
              !((echoOf refused).getD "").contains "FileWatchError" &&
              !(startNames steps).contains Files.followJob &&
              (pendingOf retried Files.followJob).isSome },
    { name :=
        "config's setting decides while no command has: under it the next step arms the watches, and noautoread then wins over it"
      run :=
        pure <|
          match watchedNote with
          | none => false
          | some opened =>
            let configured :=
              { opened with
                keys :=
                  { opened.keys with
                    registered := { opened.keys.registered with autoReload := true } } }
            let (armed, _) := fedTo configured [.preedit ""]
            let (off, _) := fedTo armed (exLine "noautoread")
            armed.openWatches == 1 && off.openWatches == 0 }]

/-- The text of the decoration checks: a hundred rows of `foo` and the row's
number, more than a view of the decoration checks' frame shows
(`decorationState`), but for row 10, which holds two matches, and row 50,
whose word is `food`. -/
def decoratedText : String :=
  String.join <|
    (List.range 100).map fun row =>
      if row == 10 then "foo foo 10\n" else if row == 50 then "food 50\n" else s!"foo {row}\n"

/-- A text whose rows are longer than the decoration checks' frame is wide:
sixty rows of `foo` and a blank, fifty times each, two hundred cells, so
every row wraps, and the view shows fewer rows than it is high. -/
def wrappingText : String :=
  String.join
    ((List.range 60).map fun _ => String.join ((List.range 50).map fun _ => "foo ") ++ "\n")

/-- A state of the decoration checks: `evilState` of `contents`, with the
cursor at 0, in a frame of 80 by 40, where a row of the display model is
one high and a cell one wide, so a view shows a few dozen rows. -/
def decorationState (contents : String) : TextM EditorState := do
  let state ← evilState contents 0
  return { state with frame := { state.frame with size := ⟨80, 40⟩ } }

/-- A driver of the decoration checks over `decorationState`. -/
def decorationDriver (contents : String) : Option EvilDriver :=
  (Loop.Driver.over evilHanded (fun _ => none) (decorationState contents) editorModel).toOption

/-- The matches of `needle` in `contents`, found by hand, row by row: from
each row's start, each occurrence, and the walk goes on from its end. With
`whole`, an occurrence that does not start and end a word is passed over
and the walk goes on one character after its start. Byte offsets, with the
row each starts in. -/
def naiveMatches (contents needle : String) (whole : Bool := false) : List (Nat × Nat × Nat) :=
  Id.run do
    let chars := contents.toList.toArray
    let offsets :=
      (chars.foldl (fun (acc : Array Nat × Nat) c => (acc.1.push acc.2, acc.2 + c.utf8Size))
          (#[], 0)).1
    let width := needle.length
    let word (index : Nat) : Bool := (chars[index]?.map wordCharacter).getD false
    let mut found := #[]
    let mut index := 0
    let mut row := 0
    let mut rowAt := #[]
    for char in chars do
      rowAt := rowAt.push row
      if char == '\n' then
        row := row + 1
    while index + width ≤ chars.size do
      let here := (chars.extract index (index + width)).toList == needle.toList
      let bounded :=
        !whole ||
          (word index && (index == 0 || !word (index - 1)) && word (index + width - 1) &&
            !word (index + width))
      if here && bounded then
        found :=
          found.push
            (rowAt[index]!, offsets[index]!, (offsets[index + width]?).getD contents.utf8ByteSize)
        index := index + width
      else
        index := index + 1
    return found.toList

/-- What is wrong, if anything, with the decorations of the view `view` in
the last scene `driver` published, for the matches of `needle` in
`contents`: every match that starts in a row from the view's anchor's
through `height / heights.text` rows on is decorated, and every
decoration is in `search-match` and is a match that starts in a row
through one more, which is what the loop reads (`Loop.decorationsOf`). -/
def decorationsWrong (driver : EvilDriver) (contents needle : String) (whole : Bool := false)
    (view : ViewId := ⟨0⟩) : Option String := do
  let some scene := driver.model.display.scenes.back? | some "no scene"
  let some shown := scene.views.find? (·.id == view) | some "no view"
  let some target := driver.loop.state.target? view | some "no window"
  let anchor :=
    match (target.buffer.text.marker target.window.scroll).runModel driver.model.texts with
    | (.ok (.anchor anchor), _) => some anchor.offset
    | _ => none
  let some anchor := anchor | some "no anchor"
  let rowOf (offset : Nat) : Nat :=
    ((contents.toList.foldl
        (fun (acc : Nat × Nat) c =>
          if acc.1 < offset then (acc.1 + c.utf8Size, acc.2 + if c == '\n' then 1 else 0) else acc)
        (0, 0)).2)
  let first := rowOf anchor
  let rows := shown.rect.height / max 1 driver.loop.state.heights.text
  let all := naiveMatches contents needle whole
  let visible := all.filter fun (row, _, _) => first ≤ row && row ≤ first + rows
  let reachable := all.filter fun (row, _, _) => first ≤ row && row ≤ first + rows + 1
  let drawn := shown.decorations.toList.map fun decoration => (decoration.start, decoration.stop)
  if visible.isEmpty then
    some "no match is visible"
  else if !visible.all fun (_, start, stop) => drawn.contains (start, stop) then
    some s!"a visible match is not decorated: {repr drawn}"
  else if !shown.decorations.all (·.face == Loop.searchMatchFace) then
    some "a decoration is in another face"
  else if
    !drawn.all fun range =>
        (reachable.map fun (_, start, stop) => (start, stop)).contains range then
    some s!"a decoration is no match the loop reads: {repr drawn}"
  else
    none

/-- The decorations of the view `view` in the last scene `driver`
published. -/
def decorationsOfScene (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option (Array Decoration) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map (·.decorations)

/-- A state of the decoration checks: `evilState` of `contents`, with a
second window on the same buffer below the first, whose anchor is at the
byte offset `second`. -/
def twoViewState (contents : String) (second : Nat) : TextM EditorState := do
  let state ← decorationState contents
  let some buffer := state.buffers[0]?.join | throw .noSuchText
  let scroll ← buffer.text.mark (.anchor { offset := second, bias := .before })
  let selection ←
    buffer.text.mark (.selection { ranges := #[⟨second, second⟩], shape := .inclusive })
  return {
      state with
      windows := state.windows.push { id := ⟨1⟩, buffer := ⟨0⟩, scroll, selection }
      nextView := 2
      frame :=
        { state.frame with
          windows := #[⟨0⟩, ⟨1⟩], layout := .masterStack { side := .top } } }

/-- The checks of the decorations of a view (`Editor/Loop.lean`,
"Decorations"): the matches of the last search, in `search-match`, on the
loop's driver over the editor's models and the display recorder, under the
Vim scheme that ships. -/
def searchDecorationChecks : List Check :=
  let fed (fixture typed : String) : Option EvilDriver :=
    (decorationDriver (barred fixture).1).map (evilFed · typed)
  [{  name :=
        "after / f o o RET every match in the rows the view shows is drawn in search-match, and every decoration is a match of the rows the loop reads, food among none"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ f o o RET" with
          | none => false
          | some driver => decorationsWrong driver decoratedText "foo" == none },
    { name := "after C-f the decorations follow the rows the view shows from its new anchor"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ f o o RET C-f",
            fed ("|" ++ decoratedText) "/ f o o RET" with
          | some paged, some first =>
            decorationsWrong paged decoratedText "foo" == none &&
              decorationsOfScene paged != decorationsOfScene first
          | _, _ => false },
    { name :=
        "in rows that wrap, every match the view shows is decorated, and every decoration is a match"
      run :=
        pure <|
          match fed ("|" ++ wrappingText) "/ f o o RET" with
          | none => false
          | some driver => decorationsWrong driver wrappingText "foo" == none },
    { name := "a second view of the buffer has the decorations of its own rows by the same rule"
      run :=
        pure <|
          match
            (Loop.Driver.over evilHanded (fun _ => none) (twoViewState decoratedText 300)
                editorModel).toOption with
          | none => false
          | some driver =>
            let driver := evilFed driver "/ f o o RET"
            decorationsWrong driver decoratedText "foo" == none &&
              decorationsWrong driver decoratedText "foo" (view := ⟨1⟩) == none &&
              decorationsOfScene driver ⟨1⟩ != decorationsOfScene driver ⟨0⟩ },
    { name :=
        "the minibuffer's view has no decorations while the prompt is open, and with no search no view has any"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ f o o RET / f", fed ("|" ++ decoratedText) "l" with
          | some asking, some unsearched =>
            let minibuffer := asking.loop.state.prompt.map (·.view)
            (asking.model.display.scenes.back?.map fun scene =>
                  scene.views.all fun view =>
                    some view.id != minibuffer || view.decorations.isEmpty) ==
                some true &&
              minibuffer.isSome &&
              (unsearched.model.display.scenes.back?.map fun scene =>
                  scene.views.all (·.decorations.isEmpty)) ==
                some true
          | _, _ => false },
    { name := "after * on foo, food is not decorated: the pattern is the whole word"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "*" with
          | none => false
          | some driver => decorationsWrong driver decoratedText "foo" (whole := true) == none },
    { name := "a pattern with no match, and one the syntax refuses, draws nothing"
      run :=
        pure <|
          match fed ("|" ++ decoratedText) "/ x y z RET",
            fed ("|" ++ decoratedText) "/ \\ ( RET" with
          | some missing, some refused =>
            decorationsOfScene missing == some #[] && decorationsOfScene refused == some #[]
          | _, _ => false },
    { name :=
        "a buffer's spans within a covered range are kept, clipped to it, in order, and those outside it and those left empty are dropped"
      run :=
        let span (start stop : Nat) : Decoration := { start, stop, face := ⟨"s"⟩ }
        pure
          (Loop.spansIn #[span 0 5, span 8 12, span 15 20, span 30 40, span 10 10] 10 32 ==
            #[span 10 12, span 15 20, span 30 32]) },
    { name :=
        "a view's decorations are its buffer's spans in the rows it covers, with no search too, and then the last search's matches, which are drawn over them"
      run :=
        let face : FaceName := ⟨"compilation.error"⟩
        let spans : Array Decoration :=
          #[{ start := 0, stop := 3, face }, { start := 30000, stop := 30004, face }]
        let spanned : TextM EditorState := do
          let state ← decorationState decoratedText
          return { state with buffers := state.buffers.modify 0 (·.map ({ · with spans })) }
        let driver := (Loop.Driver.over evilHanded (fun _ => none) spanned editorModel).toOption
        pure <|
          match driver.map (evilFed · "l"), driver.map (evilFed · "/ f o o RET") with
          | some unsearched, some searched =>
            let found := (decorationsOfScene searched).map (·.extract 1 1000)
            decorationsOfScene unsearched == some #[{ start := 0, stop := 3, face }] &&
              (decorationsOfScene searched).bind (·[0]?) == some { start := 0, stop := 3, face } &&
              (found.map fun all => !all.isEmpty && all.all (·.face == Loop.searchMatchFace)) ==
                some true
          | _, _ => false }]

/-- A driver of the view checks over `viewState`, under the Vim scheme that
ships, each step handed `handed`, on `model`; `none` if making the state was
refused. `size` is the window's text area (`frameAround`). -/
def viewDriver (contents : String) (size : Size) (margin : Nat := 0) (head : Nat := 0)
    (handed : Loop.Keys Vim.Default.scheme := evilHanded) (model : EditorModel := editorModel) :
    Option EvilDriver :=
  let frame := frameAround size model.display.cells
  (Loop.Driver.over handed (fun _ => none) (viewState contents frame margin head) model).toOption

/-- What a scene shows of one view, as the view checks read it: where its
markers are, and what the display model answers for it. -/
structure ViewSeen where
  /-- The marker the scene names as the view's scroll anchor. -/
  scroll : MarkerId
  /-- Where that anchor is. -/
  anchor : Nat
  /-- The view's selection. -/
  selection : Selection
  /-- The head of its primary range: the cursor. -/
  head : Nat
  /-- The rows the display model answers for the scene's view, from its
  anchor. -/
  shown : Array Display.Row
  /-- The cursor's row: the first row the display model answers for the
  scene's view from the cursor; none in a view that shows no row. -/
  row : Option Display.Row
  deriving DecidableEq, Repr

/-- Where the cursor's row is among the rows the view shows, if it is one
of them. -/
def ViewSeen.index (seen : ViewSeen) : Option Nat :=
  seen.row.bind fun row => seen.shown.findIdx? (· == row)

/-- What the last scene `model`'s display recorded shows of the view `view`
(`ViewSeen`), asked of `model`: its markers of the text model, and the rows
of the display model for the scene's snapshot and rectangle. `none` when no
scene has the view, or a marker of it refuses. -/
def seenIn (model : EditorModel) (view : ViewId := ⟨0⟩) : Option ViewSeen := do
  let scene ← model.display.scenes.back?
  let shown ← scene.views.find? (·.id == view)
  let #[marker] := shown.selections | none
  let program : EditorM ViewSeen := do
    let .anchor anchor ← shown.scroll.text.marker shown.scroll | throw .noSuchMarker
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let some range := selection.ranges[selection.primary]? | throw .badSelection
    -- A window's view, asked with its height less its status row, which
    -- is the display model's cell.
    let area := Scroll.Area.ofRect shown.snapshot shown.rect model.display.cells.heights.status
    return {
        scroll := shown.scroll, anchor := anchor.offset, selection, head := range.head
        shown := ← area.rows anchor.offset, row := (← area.rows range.head)[0]? }
  (program.runModel model).1.toOption

/-- What the last scene of `driver` shows of the view `view` (`seenIn`). -/
def viewSeen (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option ViewSeen :=
  seenIn driver.model view

/-- `driver` after the command called `name` has run as an invocation no key
yielded, with no arguments. -/
def viewRan (driver : EvilDriver) (name : String) : EvilDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command := name })).1

/-- What the scene shows of view 0 after `invocation` has run, as a step no
key yielded, from the state `start` makes, under the Vim scheme that ships
with evil's commands, on models of their own. -/
def viewInvoked (start : TextM EditorState) (invocation : Invocation) : Option ViewSeen :=
  let program : EditorM Unit := do
    let loop : EvilLoop := { state := ← start }
    discard <| loop.invoke evilHanded invocation
  match program.runModel editorModel with
  | (.ok (), model) => seenIn model
  | (.error _, _) => none

/-- The cases in which the scroll margin `margin` does not hold after a
motion, in a view of `contents` in a frame of `size`: each motion of evil's
vocabulary, with no count and with a count of 3, from each of `heads` as
the cursor, with the anchor at the text's start. The margin holds when the
cursor's row is among the rows the display model answers for the next
scene's view, `margin` rows from the first and from the last, except where
the first is the text's first row or the last its last (`marginHolds`). -/
def marginFailures (contents : String) (size : Size) (margin : Nat) (heads : List Nat) :
    List String :=
  let rows := allRows contents size.width
  heads.flatMap fun head =>
    Evil.motions.toList.flatMap fun motion =>
      [0, 3].filterMap fun count =>
        let seen :=
          viewInvoked (viewState contents size margin head)
            { command := Vim.moveCommand, arguments := [.str motion.name, .nat count] }
        let held :=
          match seen with
          | some seen => seen.row.any fun row => marginHolds rows seen.shown row margin
          | none => false
        if held then none else some s!"{motion.name} with {count} from {head} of {repr contents}"

/-- `viewState` with a second window on the same buffer, view 1, below view
0, with markers of its own: its scroll anchor at the text's start and its
cursor at `second`. View 0 is focused. -/
def splitViews (contents : String) (size : Size) (second : Nat) : TextM EditorState := do
  let state ← viewState contents size
  let some target := state.focusedTarget? | throw .noSuchText
  let text := target.buffer.text
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let shape := (← target.selection).shape
  let selection ← text.mark (.selection { ranges := #[⟨second, second⟩], shape })
  return {
      state with
      windows := state.windows.push { id := ⟨1⟩, buffer := ⟨0⟩, scroll, selection }
      nextView := 2
      frame :=
        { state.frame with
          windows := #[⟨0⟩, ⟨1⟩], layout := .masterStack { side := .top } } }

/-- How many requests the last key of `typed` took, on the counting model,
in a view of twenty short lines in a frame of `size`, in `cells`. -/
def viewCost (size : Size) (typed : String)
    (cells : Display.Cells := { advance := 1, lineHeight := 1 }) : Option Nat := do
  let model := { countingModel with display := { cells } }
  let driver ←
    (Loop.Driver.over evilHanded (fun _ => none) (viewState (numbered 20) size) model).toOption
  let pressed := keys typed
  let before :=
    (pressed.dropLast).foldl (fun driver key => (driver.feed { event := press key, stamp := 0 }).1)
      driver
  let last ← pressed.getLast?
  let after := (before.feed { event := press last, stamp := 0 }).1
  return after.model.watch.clock - before.model.watch.clock

/-- Where a view is in its text, by the rows `rows` of the text as the
display model answers them: the index of the first row the view shows, and
of the cursor's row. -/
def ViewSeen.place (seen : ViewSeen) (rows : Array Display.Row) : Option (Nat × Nat) := do
  let top ← rows.findIdx? (some · == seen.shown[0]?)
  let cursor ← rows.findIdx? (some · == seen.row)
  return (top, cursor)

/-- Where view 0 of `driver` is in its text once the keys `typed` are
pressed (`ViewSeen.place`). -/
def viewPlaced (driver : EvilDriver) (typed : String) (rows : Array Display.Row) :
    Option (Nat × Nat) :=
  (viewSeen (evilFed driver typed)).bind (·.place rows)

/-- The key string that names `key` `count` times. -/
def keyTimes (key : String) (count : Nat) : String :=
  " ".intercalate (List.replicate count key)

/-- The invocation the default key `key` yields in the Vim scheme's initial
state: what the loop runs for it. -/
def viewInvocation (key : String) : Option Invocation :=
  (vimDefaultEdit key).map (·.compile)

/-- The cases in which the cursor's row is not among the rows the next
scene's view shows after the command of one of `keys`, run as the
invocation its key yields, in a view of `contents` in a frame of `size`:
from each of `anchors` as the scroll anchor and each of `heads` as the
cursor. A key that yields no command is a case. -/
def scrollFailures (keys : List String) (contents : String) (size : Size)
    (anchors heads : List Nat) : List String :=
  keys.flatMap fun key =>
    match viewInvocation key with
    | none => [s!"{key} runs no command"]
    | some invocation =>
      anchors.flatMap fun anchor =>
        heads.filterMap fun head =>
          let start : TextM EditorState := do
            let state ← viewState contents size 0 head
            let some target := state.focusedTarget? | throw .noSuchText
            target.scrollTo anchor
            return state
          match viewInvoked start invocation with
          | some seen =>
            if seen.index.isSome then none
            else some s!"{key} from anchor {anchor} and cursor {head} of {repr contents}"
          | none => some s!"{key} from anchor {anchor} and cursor {head}: no scene"

/-- The checks of a view that follows its cursor (`Editor/Loop.lean`,
"Following the cursor"), on the loop's driver over the editor's models,
under the Vim scheme that ships with evil's commands: keys are pressed, and
what the next scene shows of a view is asked of the driver's models
(`viewSeen`): where its scroll anchor is, the rows the display model
answers from it for the scene's view, and the row it answers for the
cursor. No check says where a text wraps: the texts are lines shorter than
their view, and the text the display contract's own cases wrap. -/
def viewChecks : List Check :=
  [{  name :=
        "a motion that puts the cursor below the last row a view shows moves the view's anchor in the next scene, and the rows the display answers from it include the cursor's row: j from the last row shown scrolls one row, with the cursor's row the last row shown"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 5⟩ with
          | none => false
          | some driver =>
            let onLast := evilFed driver "4 j"
            match viewSeen onLast, viewSeen (evilFed onLast "j") with
            | some was, some now =>
              was.anchor == 0 && was.shown.size == 5 && was.index == some 4 &&
                now.head != was.head &&
                now.anchor != was.anchor &&
                now.index == some 4 &&
                now.shown[0]? == was.shown[1]?
            | _, _ => false },
    { name :=
        "a motion that puts the cursor above the first row a view shows moves the view's anchor in the next scene, and the rows the display answers from it include the cursor's row: k from the first row shown scrolls one row, and g g from far below shows the text's start, each with the cursor's row the first row shown"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 5⟩ with
          | none => false
          | some driver =>
            let far := evilFed driver "G"
            let onFirst := evilFed far "4 k"
            match viewSeen far, viewSeen onFirst, viewSeen (evilFed onFirst "k"),
              viewSeen (evilFed far "g g") with
            | some low, some was, some now, some start =>
              low.anchor != 0 && low.index == some 4 && was.anchor == low.anchor &&
                was.index == some 0 &&
                now.head != was.head &&
                now.anchor != was.anchor &&
                now.index == some 0 &&
                now.shown[1]? == was.shown[0]? &&
                start.anchor == 0 &&
                start.head == 0 &&
                start.index == some 0
            | _, _, _, _ => false },
    { name :=
        "a motion that leaves the cursor among the rows a view shows leaves the view's anchor where it was: j, k, l, w, b and $, in a view that has scrolled"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 5⟩ with
          | none => false
          | some driver =>
            let inside := evilFed driver "9 j k k"
            match viewSeen inside with
            | none => false
            | some was =>
              was.anchor != 0 && was.index == some 2 &&
                ["j", "k", "l", "w", "b", "$"].all fun key =>
                  match viewSeen (evilFed inside key) with
                  | some now =>
                    now.head != was.head && now.anchor == was.anchor && now.index.isSome &&
                      now.shown == was.shown
                  | none => false },
    { name :=
        "a cursor that moves onto the last visual row of a line wrapped over three rows, below the view, has that row among the rows shown in the next scene: $ from the line's first row, which was the last row shown"
      run :=
        pure <|
          match viewDriver wrapping ⟨4, 4⟩ with
          | none => false
          | some driver =>
            let onLine := evilFed driver "2 j"
            let rows := allRows wrapping 4
            match viewSeen onLine, viewSeen (evilFed onLine "$") with
            | some was, some now =>
              -- The cursor's row was the first of three rows of one line,
              -- and is now the last of them: no line break is between them,
              -- and one is after the last.
              was.anchor == 0 && was.index == some 3 && was.row == rows[3]? &&
                (rows[3]?.map (·.stop)) == (rows[4]?.map (·.start)) &&
                (rows[4]?.map (·.stop)) == (rows[5]?.map (·.start)) &&
                (rows[5]?.map (·.stop + 1)) == (rows[6]?.map (·.start)) &&
                now.row == rows[5]? &&
                now.anchor != 0 &&
                now.index == some 3
            | _, _ => false },
    { name :=
        "a resize that leaves a view with fewer rows than the cursor's row is followed by a scene whose view shows the cursor's row, and a resize that grows the view keeps its anchor"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 8⟩ with
          | none => false
          | some driver =>
            let low := evilFed driver "7 j"
            let shrunk := viewResized low ⟨10, 3⟩
            match viewSeen low, viewSeen shrunk, viewSeen (viewResized shrunk ⟨10, 12⟩) with
            | some was, some now, some grown =>
              was.anchor == 0 && was.index == some 7 && now.head == was.head &&
                now.shown.size == 3 &&
                now.anchor != 0 &&
                now.index == some 2 &&
                grown.anchor == now.anchor &&
                grown.shown.size == 12 &&
                grown.index == some 2
            | _, _, _ => false },
    { name :=
        "with the scroll margin set to two, after every motion of the vocabulary, with no count and with a count of 3, from a spread of cursors of forty short lines and of a text with wrapped lines, in a view of seven rows, the cursor's row is at least two rows from the first and from the last row the next scene's view shows, except where the first is the text's first row or the last its last"
      run := do
        let resting (contents : String) (every : Nat) : List Nat :=
          (List.range (contents.utf8ByteSize + 1)).filter fun head =>
            head % every == 0 && restsWell contents head
        let forty := numbered 40
        let wrong :=
          marginFailures forty ⟨10, 7⟩ 2 (resting forty 7) ++
            marginFailures ragged ⟨4, 7⟩ 2 (resting ragged 1)
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate (wrong.take 12)))
        return !Evil.motions.isEmpty && (resting forty 7).length > 10 &&
            (resting ragged 1).length > 20 },
    { name :=
        "with no margin set the same sweep finds the cursor's row among the rows the next scene's view shows after every motion"
      run := do
        let forty := numbered 40
        let heads :=
          (List.range (forty.utf8ByteSize + 1)).filter fun head =>
            head % 11 == 0 && restsWell forty head
        let wrong := marginFailures forty ⟨10, 7⟩ 0 heads
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate (wrong.take 12)))
        return heads.length > 5 },
    { name :=
        "every view is followed, not the focused one alone: an edit made through one window that moves the cursor of another window on the same buffer out of the rows that window shows moves that window's anchor, and leaves the anchor of the window it was made through"
      run :=
        pure <|
          let contents := numbered 20
          let rows := allRows contents 10
          let grow : Dispatched := fun call => do
            call.target.buffer.text.insert 0 "x\nx\nx\n"
            return none
          let idle : Dispatched := fun _ => pure none
          let handed := evilHanded (commands := [("grow", grow), ("idle", idle)])
          -- Rows of a pixel: a frame of fifteen is fourteen above its bottom
          -- row, a window of seven less the divider's two below it, and one
          -- of seven, whose texts have four rows and six above their status
          -- rows.
          match
            (Loop.Driver.over handed (fun _ => none) (splitViews contents ⟨10, 15⟩ (startOf rows 3))
                editorModel).toOption with
          | none => false
          | some driver =>
            let still := viewRan driver "idle"
            let grown := viewRan driver "grow"
            match viewSeen still ⟨1⟩, viewSeen grown ⟨1⟩, viewSeen grown ⟨0⟩ with
            | some was, some other, some own =>
              was.anchor == 0 && was.shown.size == 6 && was.index == some 3 &&
                other.head != was.head &&
                other.anchor != 0 &&
                other.index == some 5 &&
                own.anchor == 0 &&
                own.index.isSome
            | _, _, _ => false },
    { name :=
        "the minibuffer's view follows its cursor: an answer typed into a prompt until it wraps over more rows than the minibuffer's strip shows moves the minibuffer's anchor, and the rows the display answers from it include the cursor's row; the view that asked keeps its anchor"
      run :=
        pure <|
          let ask : Dispatched := fun _ => do
            discard <| prompt "Name: " { command := "greet" }
            return none
          let cells : Display.Cells := { advance := 8, lineHeight := 16 }
          let answer := "abcdefghijklm"
          let typed := " ".intercalate (answer.toList.map (·.toString))
          let handed := evilHanded Minibuffer.commands [("ask", ask)]
          let model : EditorModel := { editorModel with display := { cells } }
          match viewDriver (numbered 20) ⟨32, 64⟩ (handed := handed) (model := model) with
          | none => false
          | some driver =>
            let asking := viewRan driver "ask"
            let typing := evilFed asking typed
            let rows := allRows answer 32 cells
            match asking.loop.state.minibufferView? with
            | none => false
            | some view =>
              match viewSeen asking view, viewSeen typing view, viewSeen typing with
              | some was, some now, some asker =>
                was.anchor == 0 && was.index == some 0 && evilShown typing view == answer ++ "|" &&
                  now.head == answer.utf8ByteSize &&
                  -- The answer has more rows than the strip shows, and the
                  -- cursor is on the last of them.
                  !now.shown.isEmpty &&
                  now.shown.size < rows.size &&
                  now.row == rows.back? &&
                  now.anchor != 0 &&
                  now.index.isSome &&
                  asker.anchor == 0 &&
                  asker.index.isSome
              | _, _, _ => false },
    { name :=
        "a command that moves the cursor below the rows its view shows and then fails leaves the view's anchor where it was: the view follows the cursor that was put back"
      run :=
        pure <|
          let contents := numbered 20
          let fall : Dispatched :=
            failingAfter fun call => do
              let selection ← call.target.selection
              let last := contents.utf8ByteSize - 1
              call.target.select { selection with ranges := #[⟨last, last⟩] }
          match
            viewDriver contents ⟨10, 5⟩ (handed := evilHanded (commands := [("fall", fall)])) with
          | none => false
          | some driver =>
            let moved := evilFed driver "2 j"
            let failed := viewRan moved "fall"
            match viewSeen moved, viewSeen failed with
            | some was, some now =>
              now.anchor == was.anchor && now.head == was.head && now.index == was.index &&
                was.index == some 2 &&
                failed.loop.state.echo.startsWith "fall: refused: "
            | _, _ => false },
    { name :=
        "a view whose selection marker was given up is not followed: its anchor stays, the step is not refused, and the echo area says nothing of it, in that scene or the next"
      run :=
        pure <|
          let contents := numbered 20
          let drop : Dispatched := fun call => do
            let selection ← call.target.selection
            let last := contents.utf8ByteSize - 1
            call.target.select { selection with ranges := #[⟨last, last⟩] }
            call.target.buffer.text.unmark call.target.window.selection
            return none
          let anchorOf (driver : EvilDriver) : Option Nat := do
            let target ← driver.loop.state.target? ⟨0⟩
            return (← (target.anchor.runModel driver.model.texts).1.toOption).offset
          match
            viewDriver contents ⟨10, 5⟩ (handed := evilHanded (commands := [("drop", drop)])) with
          | none => false
          | some driver =>
            let dropped := viewRan driver "drop"
            let next := viewResized dropped ⟨10, 4⟩
            anchorOf dropped == some 0 && anchorOf next == some 0 &&
              dropped.model.display.scenes.size == 1 &&
              next.model.display.scenes.map (·.echo) == #["", ""] },
    { name := "a view of no height keeps its anchor wherever its cursor goes"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 0⟩ with
          | none => false
          | some driver =>
            match viewSeen (evilFed driver "G") with
            | some now => now.anchor == 0 && now.head != 0 && now.shown.isEmpty
            | none => false },
    { name :=
        "the scene of a step that moved a view's anchor names the scroll marker the scene before it named: where the marker is is all that changed"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 5⟩ with
          | none => false
          | some driver =>
            let onLast := evilFed driver "4 j"
            match viewSeen onLast, viewSeen (evilFed onLast "j") with
            | some was, some now => now.scroll == was.scroll && now.anchor != was.anchor
            | _, _ => false },
    { name :=
        "what following costs, as differences on the watch model's clock, for the same key: a frame whose window's text has one row, whose one view keeps its anchor, costs four requests more than a frame of no height, where nothing is asked; and in cells of 8 by 16 a frame whose window's text area is 8 pixels tall, whose view shows no row, costs two more than one of no height"
      run :=
        pure <|
          let cells : Display.Cells := { advance := 8, lineHeight := 16 }
          -- In cells of a pixel a frame of three is a window of two above
          -- the bottom row, whose text has one row above its status row; in
          -- cells of 16 a frame of 40 is a window of 24 and a text area of 8.
          match viewCost ⟨10, 0⟩ "l", viewCost ⟨10, 3⟩ "l", viewCost ⟨80, 0⟩ "l" cells,
            viewCost ⟨80, 40⟩ "l" cells with
          | some bare, some one, some flat, some short =>
            bare > 0 && one == bare + 4 && flat == bare && short == flat + 2
          | _, _, _, _ => false },
    { name :=
        "C-d moves a view's anchor and its cursor down by half the rows the view fits, and C-u up by the same; C-f and C-b by the rows it fits: in a view of six rows over forty lines, three rows and six, with the cursor keeping its row of the view; a count before C-d is the rows of that one command, and the next C-d is half a view again; a count before C-f is so many views"
      run :=
        pure <|
          let contents := numbered 40
          let rows := allRows contents 10
          match viewDriver contents ⟨10, 6⟩ with
          | none => false
          | some driver =>
            let placed (typed : String) : Option (Nat × Nat) := viewPlaced driver typed rows
            placed "l h" == some (0, 0) && placed "C-d" == some (3, 3) &&
              placed "C-d C-u" == some (0, 0) &&
              placed "2 j C-d" == some (3, 5) &&
              placed "2 j C-d C-d C-u" == some (3, 5) &&
              placed "C-f" == some (6, 6) &&
              placed "C-f C-f C-b" == some (6, 6) &&
              placed "2 j C-f" == some (6, 8) &&
              placed "5 C-d" == some (5, 5) &&
              placed "5 C-d C-d" == some (8, 8) &&
              placed "2 C-f" == some (12, 12) &&
              placed "2 C-f 2 C-b" == some (0, 0) &&
              placed "1 0 C-d 4 C-u" == some (6, 6) },
    { name :=
        "at the text's end C-d and C-f, repeated, leave the text's last row as the last row shown, in a full view, with the cursor on the last line, and one more changes nothing and says nothing; and back at its start C-u and C-b leave the text's first row as the first row shown with the cursor on it, and one more changes nothing and says nothing"
      run :=
        pure <|
          let contents := numbered 20
          let rows := allRows contents 10
          match viewDriver contents ⟨10, 5⟩ with
          | none => false
          | some driver =>
            (["C-d", "C-f"].all fun key =>
                let ended := evilFed driver (keyTimes key 12)
                let again := evilFed ended key
                match viewSeen ended, viewSeen again with
                | some now, some more =>
                  now.shown.size == 5 && now.shown.back? == rows.back? && now.row == rows.back? &&
                    more == now &&
                    ended.loop.state.echo == "" &&
                    again.loop.state.echo == ""
                | _, _ => false) &&
              [("C-d", "C-u"), ("C-f", "C-b")].all fun (down, up) =>
                let started := evilFed driver s!"{keyTimes down 12} {keyTimes up 12}"
                let again := evilFed started up
                match viewSeen started, viewSeen again with
                | some now, some more =>
                  now.anchor == 0 && now.head == 0 && now.row == rows[0]? && more == now &&
                    again.loop.state.echo == ""
                | _, _ => false },
    { name :=
        "in a text that ends in a line feed C-d and C-f, repeated, leave the empty row after the last line as the last row shown, and the cursor on the last line, in the column it was in, and not in the empty row; one more changes nothing"
      run :=
        pure <|
          let contents := numbered 20 "\n"
          let rows := allRows contents 10
          match viewDriver contents ⟨10, 5⟩ with
          | none => false
          | some driver =>
            -- The text's last row is the empty one after its last line feed.
            (rows.back?.map fun row => row.start == row.stop) == some true &&
              ["C-d", "C-f"].all fun key =>
                let ended := evilFed driver s!"l {keyTimes key 12}"
                match viewSeen ended, viewSeen (evilFed ended key) with
                | some now, some more =>
                  now.shown.size == 5 && now.shown.back? == rows.back? &&
                    now.row == rows[rows.size - 2]? &&
                    now.row.map (·.start + 1) == some now.head &&
                    more == now &&
                    ended.loop.state.echo == ""
                | _, _ => false },
    { name :=
        "after each of C-d, C-u, C-f and C-b, from a spread of scroll anchors and of cursors, of forty short lines, of a text that ends in a line feed and of a text with wrapped lines, the cursor's row is among the rows the next scene's view shows"
      run := do
        let scrollKeys := ["C-d", "C-u", "C-f", "C-b"]
        let every (contents : String) (step : Nat) : List Nat :=
          (List.range (contents.utf8ByteSize + 1)).filter fun offset =>
            offset % step == 0 && restsWell contents offset
        let forty := numbered 40
        let ended := numbered 12 "\n"
        let wrong :=
          scrollFailures scrollKeys forty ⟨10, 6⟩ (every forty 21) (every forty 13) ++
            scrollFailures scrollKeys ended ⟨10, 5⟩ (every ended 9) (every ended 4) ++
            scrollFailures scrollKeys ragged ⟨4, 3⟩ (every ragged 5) (every ragged 3)
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate (wrong.take 12)))
        return (every forty 21).length > 3 && (every ragged 3).length > 8 },
    { name :=
        "C-d keeps the cursor's x across the row of a shorter line; in a visual state it moves the selection's head and leaves its other end; and the window keeps no wanted column after it"
      run :=
        pure <|
          let contents := "abcdef\nab\nabcdef\nab\nabcdef\nabcdef\nabcdef\nabcdef"
          let wanted (driver : EvilDriver) : Option (Option Window.Wanted) :=
            (driver.loop.state.window? ⟨0⟩).map (·.wanted)
          -- Where the display model moves the cursor from offset 4, two rows
          -- down, aiming for its own x.
          let moved :=
            onDisplay contents
              (Display.linesFrom
                { snapshot := ⟨0⟩, width := 10, position := 4, lines := 2, goal := none })
          match viewDriver contents ⟨10, 4⟩ (head := 4), moved with
          | some driver, some moved =>
            let down := evilFed driver "C-d"
            let visual := evilFed driver "v C-d"
            (rowAt contents 10 moved.position).map (·.start + 4) == some moved.position &&
              (viewSeen down).map (·.head) == some moved.position &&
              ((viewSeen visual).map fun seen => (seen.selection.ranges, seen.selection.shape)) ==
                some (#[⟨4, moved.position⟩], .inclusive) &&
              (wanted (evilFed driver "j k")).map (·.isSome) == some true &&
              wanted (evilFed driver "j k C-d") == some none
          | _, _ => false },
    { name :=
        "in a text with wrapped lines C-d moves the cursor by visual rows, into the middle of a line: one row down from the first row of a line wrapped over two is the line's second row"
      run :=
        pure <|
          let rows := allRows wrapping 4
          match viewDriver wrapping ⟨4, 2⟩ with
          | none => false
          | some driver =>
            match viewSeen (evilFed driver "C-d") with
            | some now =>
              -- No line break is between the first row and the second.
              (rows[0]?.map (·.stop)) == (rows[1]?.map (·.start)) && now.row == rows[1]? &&
                some now.head == rows[1]?.map (·.start) &&
                now.place rows == some (1, 1)
            | none => false },
    { name := "in a frame of no height C-d, C-u, C-f and C-b move nothing and say nothing"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 0⟩ (head := 9) with
          | none => false
          | some driver =>
            ["C-d", "C-u", "C-f", "C-b"].all fun key =>
              let after := evilFed driver key
              match viewSeen after with
              | some now => now.anchor == 0 && now.head == 9 && after.loop.state.echo == ""
              | none => false },
    { name :=
        "C-d stopped by the interrupt before any one of its requests leaves the view's anchor and its selection as they were, and says it was interrupted; run to its end it moves both, and leaves the text model holding as many snapshots as it held"
      run :=
        pure <|
          let contents := numbered 40
          let rows := allRows contents 10
          let held (driver : EvilDriver) : Nat :=
            (driver.model.texts.snapshots.filter (·.isSome)).size
          match viewDriver contents ⟨10, 6⟩, vimDefaultCommand "C-d" with
          | some driver, some command =>
            let before := evilFed driver "2 j"
            -- `C-d` with an interrupt key that arrives once it has made `asks`
            -- of its requests, or with none.
            let ran (asks : Option Nat) : EvilDriver :=
              evilFed
                { before with
                  model :=
                    { before.model with
                      watch := { before.model.watch with arrivesAfter := asks } } }
                "C-d"
            let left (driver : EvilDriver) : Option (Nat × Selection × String) :=
              (viewSeen driver).map fun seen =>
                (seen.anchor, seen.selection, driver.loop.state.echo)
            let was := (viewSeen before).map fun seen => (seen.anchor, seen.selection)
            let stopped :=
              was.map fun (anchor, selection) =>
                (anchor, selection, s!"{command.name}: interrupted")
            let whole := left (ran none)
            let runs := (List.range 40).map fun asks => left (ran (some asks))
            viewPlaced before "" rows == some (0, 2) &&
              (viewSeen (ran none)).bind (·.place rows) == some (3, 5) &&
              whole.isSome &&
              stopped.isSome &&
              whole != stopped &&
              runs.all (fun run => run == stopped || run == whole) &&
              (runs.filter (· == stopped)).length > 5 &&
              runs.getLast? == some whole &&
              held (ran none) == held before
          | _, _ => false },
    { name :=
        "after z t, z z and z b the cursor's row is the first, the middle and the last of the rows the next scene's view shows, the third of five rows and the third of six for the middle; and the text, the selection and the wanted column the window keeps are what they were; a count before one changes nothing of it, and in a visual state the selection stays as it is"
      run :=
        pure <|
          let contents := numbered 40
          [5, 6].all fun height =>
            match viewDriver contents ⟨10, height⟩ with
            | none => false
            | some driver =>
              let before := evilFed driver "2 0 j l j k"
              let kept (driver : EvilDriver) :=
                (evilText driver, (viewSeen driver).map (·.selection),
                  (driver.loop.state.window? ⟨0⟩).map (·.wanted), evilHistory driver)
              let index (typed : String) : Option Nat :=
                (viewSeen (evilFed before typed)).bind (·.index)
              let unchanged (typed : String) : Bool :=
                kept (evilFed before typed) == kept before &&
                  (evilFed before typed).loop.state.echo == ""
              evilText before == some contents &&
                ((driver.loop.state.window? ⟨0⟩).map (·.wanted)) == some none &&
                ((before.loop.state.window? ⟨0⟩).map (·.wanted.isSome)) == some true &&
                index "z t" == some 0 &&
                index "z z" == some 2 &&
                index "z b" == some (height - 1) &&
                index "7 z t" == some 0 &&
                ["z t", "z z", "z b", "7 z t"].all unchanged &&
                (["z t", "z z", "z b"].all fun typed =>
                  let visual := evilFed before "v j"
                  (viewSeen (evilFed visual typed)).map (·.selection) ==
                      (viewSeen visual).map (·.selection) &&
                    ((viewSeen visual).map
                        (·.selection.ranges.all fun range => range.anchor != range.head)) ==
                      some true) },
    { name :=
        "on the text's last line z t leaves the view showing one row, and z b from there shows the rows G showed; and near the text's start z z and z b leave the text's first row as the first row shown"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 5⟩ with
          | none => false
          | some driver =>
            let last := evilFed driver "G"
            let top := evilFed last "z t"
            match viewSeen last, viewSeen top, viewSeen (evilFed top "z b"),
              viewSeen (evilFed driver "j z z"), viewSeen (evilFed driver "j z b") with
            | some was, some one, some back, some middle, some bottom =>
              was.shown.size == 5 && one.shown.size == 1 && one.index == some 0 &&
                back.shown == was.shown &&
                back.index == some 4 &&
                middle.anchor == 0 &&
                middle.index == some 1 &&
                bottom.anchor == 0 &&
                bottom.index == some 1
            | _, _, _, _, _ => false },
    { name :=
        "in a view taller than its text z z hides no row: with the cursor on the last line of three lines and a line feed, in a view of ten rows, the anchor stays at the text's first row and every row of the text is shown; and after z t, which shows from the cursor's row, z z shows every row again"
      run :=
        pure <|
          let contents := numbered 3 "\n"
          let rows := allRows contents 10
          match viewDriver contents ⟨10, 10⟩ with
          | none => false
          | some driver =>
            let last := evilFed driver "G"
            let top := evilFed last "z t"
            match viewSeen last, viewSeen (evilFed last "z z"), viewSeen top,
              viewSeen (evilFed top "z z") with
            | some was, some now, some one, some back =>
              rows.size == 4 && was.anchor == 0 && was.shown == rows && was.index == some 2 &&
                now.anchor == 0 &&
                now.shown == rows &&
                now.index == some 2 &&
                now.head == was.head &&
                one.shown == rows.extract 2 4 &&
                one.index == some 0 &&
                back.anchor == 0 &&
                back.shown == rows &&
                back.index == some 2
            | _, _, _, _ => false },
    { name :=
        "in a view taller than its text z b, C-d, C-u, C-f and C-b leave the anchor at the text's first row with every row shown: C-d moves the cursor half the text's rows and C-f to its last line, C-u and C-b to its first; and with the scroll margin set to two, z t on the last line leaves the two rows the text has above it shown"
      run :=
        pure <|
          let contents := numbered 3 "\n"
          let rows := allRows contents 10
          match viewDriver contents ⟨10, 10⟩, viewDriver contents ⟨10, 10⟩ (margin := 2) with
          | some driver, some margined =>
            let second := evilFed driver "j"
            let whole (typed : String) (cursor : Nat) : Bool :=
              match viewSeen (evilFed second typed) with
              | some now =>
                now.anchor == 0 && now.shown == rows && now.place rows == some (0, cursor)
              | none => false
            viewPlaced second "" rows == some (0, 1) && whole "z b" 1 && whole "C-d" 2 &&
              whole "C-u" 0 &&
              whole "C-f" 2 &&
              whole "C-b" 0 &&
              whole "G C-d" 2 &&
              viewPlaced driver "G z t" rows == some (2, 2) &&
              viewPlaced margined "G z t" rows == some (0, 2)
          | _, _ => false },
    { name :=
        "with the scroll margin set to two, after z t two rows are above the cursor's row, and after z b two rows are below it: the scroll puts the row at the edge, and the view then follows with the margin"
      run :=
        pure <|
          match viewDriver (numbered 40) ⟨10, 7⟩ (margin := 2) with
          | none => false
          | some driver =>
            let before := evilFed driver "2 0 j"
            let index (typed : String) : Option Nat :=
              (viewSeen (evilFed before typed)).bind (·.index)
            index "z t" == some 2 && index "z b" == some 4 && index "z z" == some 3 },
    { name := "in a frame of no height z t, z z and z b move nothing and say nothing"
      run :=
        pure <|
          match viewDriver (numbered 20) ⟨10, 0⟩ (head := 9) with
          | none => false
          | some driver =>
            ["z t", "z z", "z b"].all fun typed =>
              let after := evilFed driver typed
              match viewSeen after with
              | some now => now.anchor == 0 && now.head == 9 && after.loop.state.echo == ""
              | none => false }]

/-- Forty lines of seven bytes with their breaks, `line00` to `line39`: the
text of the float checks of the loop, in which row `r`, column `c` is at
`7 * r + c`. -/
def floatLines : String :=
  "\n".intercalate ((List.range 40).map fun line => s!"line{line / 10}{line % 10}")

/-- `viewState floatLines size 0 head` with a second buffer, `hint`, over a
text of its own holding `hint`, shown in a float, view 1, on top of view 0,
anchored at `offset` of view 0's buffer, 50 percent of the tiled area wide
and 25 percent tall, `pinned` or not, opened without the focus. -/
def hinted (size : Size) (head offset : Nat) (pinned : Bool) : TextM EditorState := do
  let state ← viewState floatLines size 0 head
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  let text ← createText "hint"
  let history ← UndoTree.over text
  let (.ok hint, state) := state.addBuffer "hint" text history | throw .noSuchText
  let anchor ← buffer.text.mark (.anchor { offset, bias := .before })
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  let spot : WindowSpot := .float (.position ⟨0⟩ anchor) { width := 50, height := 25 } pinned
  let (.ok _, state) := state.openWindow hint scroll selection spot | throw .noSuchText
  return state

/-- The models of the float checks of the loop: the display in cells 8
pixels across and 16 down. -/
def floatModel : EditorModel :=
  .over { advance := 8, lineHeight := 16 }

/-- A driver of the float checks of the loop over `hinted`, with the cursor
at `head` and the float anchored at `offset`, under the Vim scheme that
ships, with the frame padding 8, in a frame of 640 by 480, whose one
window's text area is 640 by 448; none if making the state was refused.
Nothing is published until a step is fed. -/
def floatDriver (head offset : Nat) (pinned : Bool := false) : Option EvilDriver :=
  let frame := frameAround ⟨640, 448⟩ floatModel.display.cells
  (Loop.Driver.over { evilHanded with padding := 8 } (fun _ => none)
      (hinted frame head offset pinned) floatModel).toOption

/-- The views of the last scene `driver`'s display recorded, with their
rectangles, and the focused view. -/
def sceneViews (driver : EvilDriver) : Option (Array (ViewId × Rect) × Option ViewId) :=
  driver.model.display.scenes.back?.map fun scene =>
    (scene.views.map fun view => (view.id, view.rect), scene.focused)

/-- Whether the text model of `driver` holds the marker `id`. -/
def holdsMarker (driver : EvilDriver) (id : MarkerId) : Bool :=
  ((id.text.marker id : TextM Marker).runModel driver.model.texts).1.toOption.isSome

/-- The snapshot the last scene `driver`'s display recorded names for the
view `view`. -/
def sceneSnapshot (driver : EvilDriver) (view : ViewId) : Option SnapshotId :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map (·.snapshot)

/-- The checks of the floats a publish places against a position of a
window (`Editor/Loop.lean`, "After each event"), on the loop's driver over
the editor's models. -/
def floatViewChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  -- The first publish: a resize to the size the frame has.
  let published (driver : EvilDriver) : EvilDriver := viewResized driver ⟨640, 448⟩
  [{  name :=
        "a pinned float anchored at a position keeps its anchor marker while another tab is in view and when its tab comes back; closing a tab gives up the markers of its windows, the float's anchor among them, and the loop counts its views as closed"
      run :=
        pure <|
          match floatDriver 18 18 (pinned := true) with
          | none => false
          | some driver =>
            let shown := published driver
            let delivered (driver : EvilDriver) (command : EditorM Unit) : EvilDriver :=
              (driver.stepped (driver.loop.deliver driver.handed "tab" command)).1
            let held : Array MarkerId :=
              ((shown.loop.state.window? ⟨1⟩).map
                      (fun window => #[window.scroll, window.selection])).getD
                  #[] ++
                (shown.loop.state.frame.floats.filterMap (·.anchor.marker?))
            let away :=
              delivered shown do
                let .ok made ← (⟨0⟩ : ViewId).newTab | giveUp "no tab"
                let .ok () ← made.focus | giveUp "no focus"
            let back :=
              delivered away do
                let .ok () ← changeTab (.select 0) | giveUp "no select"
            let closed :=
              delivered away do
                let .ok () ← changeTab (.close 0) | giveUp "no close"
            held.size == 3 && away.loop.state.frame.tabIndex == 1 && held.all (holdsMarker away) &&
              back.loop.state.frame.tabIndex == 0 &&
              back.loop.state.frame.floats.size == 1 &&
              held.all (holdsMarker back) &&
              closed.loop.state.frame.tabs.size == 1 &&
              held.all (!holdsMarker closed ·) &&
              Loop.closedViews away.loop.state closed.loop.state == #[⟨0⟩, ⟨1⟩] &&
              [away, back, closed].all (·.loop.state.wellFormed) },
    { name :=
        "criterion 1 in the loop: a float anchored at a position is placed directly under the position's row, at its x, the padding included, and listed after the window it floats over; with the position on the last row shown it is flipped above the row"
      run :=
        pure <|
          match floatDriver 18 18, floatDriver 18 (7 * 26 + 4) with
          | some driver, some low =>
            sceneViews (published driver) ==
                some (#[(⟨0⟩, rect 0 0 640 464), (⟨1⟩, rect 40 56 320 116)], some ⟨0⟩) &&
              sceneViews (published low) ==
                some (#[(⟨0⟩, rect 0 0 640 464), (⟨1⟩, rect 40 308 320 116)], some ⟨0⟩)
          | _, _ => false },
    { name :=
        "a transient float whose anchor scrolled away is closed at the publish: once the cursor moves thirty rows down it is in neither the scene nor the state, and its window's markers and its anchor marker are given up; a pinned one stays where it last was"
      run :=
        pure <|
          match floatDriver 18 18, floatDriver 18 18 (pinned := true) with
          | some driver, some pinned =>
            let shown := published driver
            let held : Array MarkerId :=
              ((shown.loop.state.window? ⟨1⟩).map
                      (fun window => #[window.scroll, window.selection])).getD
                  #[] ++
                (shown.loop.state.frame.floats.filterMap (·.anchor.marker?))
            let moved := evilFed shown "3 0 j"
            let kept := evilFed (published pinned) "3 0 j"
            held.size == 3 && held.all (holdsMarker shown) &&
              (sceneViews moved).map (·.1.map (·.1)) == some #[⟨0⟩] &&
              (moved.loop.state.window? ⟨1⟩).isNone &&
              moved.loop.state.frame.floats.isEmpty &&
              held.all (!holdsMarker moved ·) &&
              moved.loop.state.wellFormed &&
              sceneViews kept ==
                some (#[(⟨0⟩, rect 0 0 640 464), (⟨1⟩, rect 40 56 320 116)], some ⟨0⟩)
          | _, _ => false },
    { name :=
        "the snapshot of a float the publish closes is released: the one the last scene named for it once its anchor scrolled away, and the one a publish took for it when the float closed in that same publish; and the loop no longer lists either"
      run :=
        pure <|
          -- The anchor of `away`, on row 35, is below the 27 rows view 0
          -- shows, so the first publish takes a snapshot for view 1 and
          -- closes it.
          match floatDriver 18 18, floatDriver 0 (7 * 35) with
          | some driver, some away =>
            let shown := published driver
            let moved := evilFed shown "3 0 j"
            let unlisted (driver : EvilDriver) (id : SnapshotId) : Bool :=
              !driver.loop.shown.any (·.snapshot == id)
            let before := away.model.texts.snapshots.size
            let closed := published away
            let taken :=
              (List.range' before (closed.model.texts.snapshots.size - before)).map SnapshotId.mk
            let unnamed :=
              taken.filter fun id =>
                (closed.model.display.scenes.back?.map fun scene =>
                      !scene.views.any (·.snapshot == id)).getD
                  false
            match sceneSnapshot shown ⟨1⟩ with
            | some float =>
              releasedSnapshot moved float && unlisted moved float &&
                (sceneViews closed).map (·.1.map (·.1)) == some #[⟨0⟩] &&
                taken.length == 2 &&
                unnamed.length == 1 &&
                unnamed.all (releasedSnapshot closed) &&
                unnamed.all (unlisted closed)
            | none => false
          | _, _ => false },
    { name :=
        "a float the publish closes is told to the scheme as closed: neither state of the scheme the loop keeps holds anything for it"
      run :=
        pure <|
          let program : EditorM ((List ViewId × List ViewId) × Bool) := do
            -- The anchor, on row 35, is below the 27 rows view 0 shows.
            let state ← hinted (frameAround ⟨640, 448⟩ floatModel.display.cells) 0 (7 * 35) false
            let told : TestScheme.State × List ViewId := ({}, [⟨0⟩, ⟨1⟩])
            let loop : Loop remembering :=
              { state := { state with heights := floatModel.display.cells.heights }, input := told
                atRest := told }
            let loop ← loop.publish (padding := 8)
            return (remembered loop, loop.state.frame.floats.isEmpty)
          (program.runModel floatModel).1.toOption == some (([⟨0⟩], [⟨0⟩]), true) },
    { name :=
        "a publish asks the display one spot for each float anchored at a position, and none with no such float"
      run :=
        pure <|
          let spotsAsked (start : TextM EditorState) : Option Nat :=
            let program : EditorM Unit := do
              let state ← start
              let loop : Loop Vim.Default.scheme :=
                { state := { state with heights := floatModel.display.cells.heights } }
              discard <| loop.publish (padding := 8)
            let count (request : EditorRequest) : Nat :=
              match request with
              | .display (.spot _) => 1
              | _ => 0
            let handle (request : EditorRequest) (models : EditorModel × Nat) :
              request.Reply × (EditorModel × Nat) :=
              let (reply, model) := EditorModel.handle request models.1
              (reply, (model, models.2 + count request))
            match Program.run (port := editorPort) handle program.run (floatModel, 0) with
            | (.ok (), (_, asked)) => some asked
            | _ => none
          let frame := frameAround ⟨640, 448⟩ floatModel.display.cells
          spotsAsked (hinted frame 18 18 false) == some 1 &&
            spotsAsked (viewState floatLines frame 0 18) == some 0 }]

end ModelTest
