import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Fake
import Editor.Completion.Later
import Editor.Completion.Style
import Editor.Config.Owner
import Editor.Config.Packages
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
import Editor.FileJobs
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Files
import Editor.Floating
import Editor.Fuzzy
import Editor.Fuzzy.Model
import Editor.GeneratedView
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
import Editor.Mode
import Editor.ModeLine
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.ProjectMode
import Editor.Role
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Test.Completion
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Geometry
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Test.States
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Vocabulary
import Editor.Watch
import Editor.Watch.Model
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.AtPoint
import ModelTest.Support.Candidates
import ModelTest.Support.Display
import ModelTest.Support.Evil
import ModelTest.Support.Listings
import ModelTest.Support.Modes
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
`candidateChecks`, `completionJobChecks`, `directoryChecks`,
`laterLoopChecks`, `loopFileJobChecks`, `openFilesChecks`,
`dispatchQuitChecks`, `systemQuitChecks`,
`searchDecorationChecks`, `viewChecks`, `floatViewChecks`,
`atPointRepeatChecks`, `atPointLoopChecks`, `atPointAskChecks`,
`atPointByItselfChecks` and `pressedChecks`. `searchDecorationChecks` are of the loop's
decorations under the Vim scheme, and `modeDispatchChecks` of modes in the
loop. `directoryChecks` also cover the reasking of a source
(`Editor/Completion/Candidate.lean`) and what the state lists while it is
asked again (`Editor/State.lean`), through the loop's reconciler of a
prompt's jobs. The checks of completion at point in the loop run on the
evil driver (`ModelTest/Support/AtPoint.lean`), through the kit's at-point
package (`Editor/Test/AtPoint.lean`) and at-point sources written for them,
so nothing of the package that ships is asked. `loopFileJobChecks` are of
when the loop starts the file jobs, under the core's names, on stand-in
works; what those jobs do through the loop is the files feature's
(`stalenessChecks` and `autoReloadChecks`, `ModelTest/Editor/Files.lean`).
The root module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

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
    localLeader := TestScheme.localLeader
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
        "while a restart hands the session over, a key and a committed text change no text and say the hand-over again; a resize is handled"
      run :=
        pure <|
          match evilDriver "a|b" with
          | none => false
          | some driver =>
            let plan : Restart.Plan := { record := "/s/session/handover", handover := default }
            let handing :=
              { driver with
                loop :=
                  { driver.loop with
                    state := { driver.loop.state with restore := { handing := some { plan } } } } }
            let fed (driver : EvilDriver) (event : Event) : EvilDriver :=
              (driver.feed { event, stamp := 0 }).1
            let keyed := evilFed handing "i x"
            let committed := fed handing (.commit "y")
            let resized := fed handing (.resize { width := 641, height := 479, scale := 2.0 })
            evilText keyed == some "ab" && evilText committed == some "ab" &&
              keyed.loop.state.echo == Restart.handingLine false &&
              committed.loop.state.echo == Restart.handingLine false &&
              resized.loop.state.frame.size == ⟨641, 479⟩ },
    { name :=
        "while a restart hands the session over, a pointer press and a preedit leave the selection, the focus and the preedit as they were and say the hand-over again"
      run :=
        pure <|
          match evilDriver "a|b" with
          | none => false
          | some driver =>
            let plan : Restart.Plan := { record := "/s/session/handover", handover := default }
            let handing :=
              { driver with
                loop :=
                  { driver.loop with
                    state :=
                      { driver.loop.state with
                        echo := "", restore := { handing := some { plan } } } } }
            let fed (driver : EvilDriver) (event : Event) : EvilDriver :=
              (driver.feed { event, stamp := 0 }).1
            let unchanged (after : EvilDriver) : Bool :=
              evilSelection after == evilSelection handing &&
                after.loop.state.frame.focused == handing.loop.state.frame.focused &&
                after.loop.state.preedit == none &&
                after.loop.state.echo == Restart.handingLine false
            let pressed :=
              fed handing
                (.pointer { action := .press, x := 3.0, y := 4.0, button := some .primary })
            let composed := fed handing (.preedit "ka")
            unchanged pressed && unchanged composed },
    { name :=
        "a layout a restore holds is not chosen while the config generation is the restore's, and is once config has installed past it; with no hold, a handed layout is chosen as before"
      run :=
        pure <|
          let program : EditorM (Layout × Layout × Layout) := do
            let state ← windowsUnder 2 Layout.default
            let held : Loop Vim.Default.scheme :=
              { state := { state with restore := { heldLayout := some 0 } } }
            let same ← held.publish (layout := some .monocle) (generation := 0)
            let after ← held.publish (layout := some .monocle) (generation := 1)
            let unheld ← ({ state } : Loop Vim.Default.scheme).publish (layout := some .monocle)
            return (same.state.frame.layout, after.state.frame.layout, unheld.state.frame.layout)
          (program.runModel editorModel).1.toOption ==
            some (Layout.default.fits 2, .monocle, .monocle) },
    { name :=
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

/-- The key hints each scene of a run showed; none of them when the run was
refused. -/
def hintsShown (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) : Array (Array KeyHint) :=
  match dispatched keys events start with
  | some (_, scenes, _) => scenes.map (·.keyHints)
  | none => #[]

/-- The checks of the key hints the scene shows (`Loop.keyHints`): the keys
that can follow the pending prefix, with their descriptions and the names
of prefixes the keys are handed, and none at rest. The hints are shown at
once (`hintedKeys`, a delay of 0), so what they list is pinned apart from
when they are shown (`keyHintLoopChecks`). -/
def dispatchHintChecks : List Check :=
  let hinted := hintedKeys
  [{  name :=
        "after a prefix the scene lists the keys that can follow it, with a binding's description and a prefix's name and count; after a further prefix the keys under it; and none once the sequence completes"
      run :=
        pure
          (hintsShown hinted (presses "C-x r t") ==
            #[afterPrefix, #[{ key := "t", leads := .binding (some "Rectangle") }], #[]]) },
    { name := "after a key that goes on with no binding the scene lists no key hints"
      run := pure (hintsShown hinted (presses "C-x" ++ [pressF5]) == #[afterPrefix, #[]]) }]

/-- The texts of the views each scene of a run of `keys` over `events` drew
after its first, the window's: the candidate list's, while one is drawn.
Each is read once the run has reached that scene, before a later one
releases its snapshot. `none` when the run was refused. -/
def listsShown (keys : Loop.Keys TestScheme.scheme) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) :
    Option (Array (Array (Option String))) :=
  (List.range events.length).toArray.mapM fun index => do
    let (_, scenes, model) ← dispatched keys (events.take (index + 1)) start
    let scene ← scenes.back?
    return (scene.views.extract 1 scene.views.size).map (shownText model)

/-- A run of `C-x` with `before`, then a publish with no step handed `after`
(`Loop.publishHinted`), as a host publishes after an install: the loop
and the hint delay change that publish hands back, and the scenes of the
step and of the publish. `none` when the run was refused. -/
def publishedHinted (before after : Loop.Keys TestScheme.scheme) :
    Option ((TestLoop × Loop.HintDelayChange) × Array Scene) :=
  let program : EditorM (TestLoop × Loop.HintDelayChange) := do
    let (loop, _) ← stepsWith before { state := ← EditorState.initial ⟨640, 480⟩ } (presses "C-x")
    loop.publishHinted after
  match program.runModel editorModel with
  | (.ok result, model) => some (result, model.display.scenes)
  | (.error _, _) => none

/-- The checks of when the key hints are shown and where (`Editor/Loop.lean`,
"Key hints"): the delay armed when a prefix becomes pending and withdrawn
when the sequence completes or resets (`Loop.armedHints`), the hints shown
at once with a delay of 0 and following the walk, drawn as the candidate
list's view by the display chosen for `key`, and the pending keys drawn by
the selected window's `pending-keys` segment. -/
def keyHintLoopChecks : List Check :=
  let pendingField (text : String) : StatusField :=
    { text, face := ModeLine.secondaryFace, side := .right, padding := ModeLine.padding }
  [{  name :=
        "armedHints opens hints of a new generation and arms their delay when a prefix becomes pending, keeps them while it stays pending, closes them and disarms when nothing can follow, opens them due at once with a delay of 0, and opens none with .never or while a prompt is open"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let loop : TestLoop := { state }
            let (armed, arming) := Loop.armedHints (hintedKeys 500) loop afterPrefix
            let (closed, closing) := Loop.armedHints (hintedKeys 500) armed #[]
            let (kept, keeping) := Loop.armedHints (hintedKeys 500) armed afterPrefix
            let (rest, resting) := Loop.armedHints (hintedKeys 500) loop #[]
            let (never, nothing) := Loop.armedHints (hintedKeys .never) loop afterPrefix
            let (atOnce, once) := Loop.armedHints (hintedKeys 0) loop afterPrefix
            let (_, asking) := prompted state
            let (prompting, notArmed) :=
              Loop.armedHints (hintedKeys 500) ({ state := asking } : TestLoop) afterPrefix
            arming == .arm 1 500 && armed.state.keyHints == some { generation := 1 } &&
              armed.state.keyHintGeneration == 1 &&
              closing == .disarm &&
              closed.state.keyHints == none &&
              closed.state.keyHintGeneration == 1 &&
              keeping == .keep &&
              kept.state == armed.state &&
              resting == .keep &&
              rest.state == state &&
              nothing == .keep &&
              never.state.keyHints == none &&
              once == .keep &&
              atOnce.state.keyHints == some { generation := 1, due := true } &&
              notArmed == .keep &&
              prompting.state.keyHints == none },
    { name :=
        "with a delay of 0 the scene after a prefix lists its hints and draws them as the candidate list's view, after a further prefix the list follows the walk with no new delay, and once the sequence completes there are no hints and no list"
      run :=
        pure
          (hintsShown hintedKeys (presses "C-x r t") ==
              #[afterPrefix, #[{ key := "t", leads := .binding (some "Rectangle") }], #[]] &&
            listsShown hintedKeys (presses "C-x r t") ==
              some
                #[#[some (hintRows afterPrefix .unregistered)],
                  #[some
                      (hintRows #[{ key := "t", leads := .binding (some "Rectangle") }]
                        .unregistered)],
                  #[]] &&
            listsShown hintedKeys (presses "C-x C-s") ==
              some #[#[some (hintRows afterPrefix .unregistered)], #[]]) },
    { name :=
        "with a delay of 500 the step after a prefix hands the delay to arm for generation 1 and its scene shows no hints; the step that completes the sequence hands its withdrawal"
      run :=
        pure <|
          match dispatched (hintedKeys 500) (presses "C-x C-s") with
          | some ((_, steps), scenes, _) =>
            steps.map (·.hintDelay) == #[.arm 1 500, .disarm] &&
              scenes.map (·.keyHints) == #[#[], #[]] &&
              scenes.map (·.views.size) == #[1, 1]
          | none => false },
    { name :=
        "the hints are drawn by the display chosen for the key category: a fake display's rows, not the default display's"
      run :=
        let starred : Completion.Display :=
          { name := "fake"
            sheet := fun showing =>
              { rows := showing.listed.map fun listed => { text := s!"* {listed.text}" } } }
        let fake : Loop.Keys TestScheme.scheme :=
          { hintedKeys with
            displaying :=
              { default := .unregistered
                byCategory := fun category => if category == "key" then some starred else none } }
        pure
          (listsShown fake (presses "C-x") == some #[#[some (hintRows afterPrefix starred)]] &&
            hintRows afterPrefix starred != hintRows afterPrefix .unregistered) },
    { name :=
        "the selected window's status line holds the keys pending in mode-line.secondary while a sequence is pending, and none once it completes; no other window's holds them"
      run :=
        pure <|
          let holds (scene : Scene) (text : String) : Nat :=
            (scene.views.filter (·.status.contains (pendingField text))).size
          match dispatched (hintedKeys .never) (presses "C-x C-s"),
            dispatched (hintedKeys .never) (presses "C-x") threeWindows with
          | some (_, scenes, _), some (_, three, _) =>
            scenes.map (holds · "C-x") == #[1, 0] &&
              (scenes.all fun scene =>
                scene.views.all fun view => !view.status.any (·.text == "C-x C-s")) &&
              three.map (holds · "C-x") == #[1] &&
              three.all (·.views.size == 3)
          | _, _ => false },
    { name :=
        "publishHinted, the publish after an install with no step: with hints due under a pending prefix, a publish handed a delay of .never closes them, its scene lists no hints and draws no list while the prefix is still drawn pending, and it hands the delay's withdrawal"
      run :=
        pure <|
          match publishedHinted (hintedKeys 0) (hintedKeys .never) with
          | some ((loop, change), scenes) =>
            scenes.map (·.keyHints) == #[afterPrefix, #[]] &&
              scenes.map (·.views.size) == #[2, 1] &&
              scenes.all (·.views.any (·.status.contains (pendingField "C-x"))) &&
              loop.state.keyHints == none &&
              change == .disarm
          | none => false },
    { name :=
        "publishHinted with no hints open under a pending prefix, a delay of .never, and a publish handed a delay of 500: it opens them at a new generation, its scene shows none yet, and it hands the delay to arm"
      run :=
        pure <|
          match publishedHinted (hintedKeys .never) (hintedKeys 500) with
          | some ((loop, change), scenes) =>
            scenes.map (·.keyHints) == #[#[], #[]] && scenes.map (·.views.size) == #[1, 1] &&
              loop.state.keyHints == some { generation := 1 } &&
              change == .arm 1 500
          | none => false }]

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
        "recorded departure (task places-restore-on-rollback): a command that deletes the text a mark and a jump entry are inside and is then refused has the text put back, but the mark and the entry, collapsed by the deletion to its start, are carried past the text the rollback puts back, to its end, and not where they were: the loop restores only the windows' selection and scroll markers"
      run :=
        pure <|
          let collapse : Dispatched := failingAfter fun call => call.target.buffer.text.delete 1 4
          let keys := dispatchKeys [("C-c x", invoke "collapse")] [("collapse", collapse)]
          let program : EditorM (String × List Marker × String) := do
            let state ← holding "abcd" #[⟨0, 0⟩]
            let text : TextId := ⟨0⟩
            let mark ← text.mark (.anchor { offset := 3, bias := .after })
            let entry ← text.mark (.anchor { offset := 3, bias := .after })
            let (_, state) := state.setLocalMark ⟨0⟩ 'a' (some mark)
            let (_, state) :=
              state.setJumps ⟨0⟩ { list := { entries := #[.held ⟨0⟩ entry], index := 1 } }
            let (loop, _) ← stepsWith keys ({ state } : TestLoop) (presses "C-c x")
            return (← text.read, [← text.marker mark, ← text.marker entry], loop.state.echo)
          (program.runModel editorModel).1.toOption ==
            some
              ("abcd",
                [.anchor { offset := 4, bias := .after }, .anchor { offset := 4, bias := .after }],
                "collapse: refused: bad range") },
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
                    [(Editor.Test.keys "C-c b", invoke "boom"),
                      (Editor.Test.keys "C-c s", invoke "stamp")]]
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
            let ran ← Loop.run keys state (invoke "release") (Editor.Test.keys "C-c r")
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
        "an at-point source is asked inside the asking command, its requests answered there, and a name nobody registered answers none; a buffer's chain is asked by its modes, filtered by the occasion"
      run :=
        pure <|
          let reading : Completion.AtPoint :=
            { name := "reading"
              ask := fun spot => do
                let state ← editorState
                return some { start := spot.offset, stop := state.windows.size, sources := [] } }
          let dots : Completion.AtPoint :=
            { Completion.AtPoint.silent "dots" with triggers := ['.'] }
          let registered : Loop.Registered :=
            { atPoint := fun name => [reading, dots].find? (·.name == name)
              atPointNames := fun major _ =>
                if major == some "notes" then #["reading", "dots", "nobody"] else #[] }
          let asking :
            EditorM
              (Option Completion.Region ×
                Option Completion.Region ×
                Array String × Array String × Array String × Array String) :=
            do
            let asked ← ControlRequest.ask (.askAtPoint "reading" { view := ⟨0⟩, offset := 0 })
            let nobody ← ControlRequest.ask (.askAtPoint "nobody" { view := ⟨0⟩, offset := 0 })
            let onKey ← RegistryRequest.ask (.atPointSources (some "notes") #["one"] .key)
            let onDot ← RegistryRequest.ask (.atPointSources (some "notes") #["one"] (.trigger '.'))
            let onPause ← RegistryRequest.ask (.atPointSources (some "notes") #["one"] (.pause 240))
            let elsewhere ← RegistryRequest.ask (.atPointSources (some "text") #["one"] .key)
            return (asked, nobody, onKey, onDot, onPause, elsewhere)
          let program :
            EditorM
              (Guarded
                  (Option Completion.Region ×
                    Option Completion.Region ×
                    Array String × Array String × Array String × Array String) ×
                EditorState) :=
            do
            asking.dispatched registered (← twoBuffers)
          match (program.runModel editorModel).1 with
          | .ok (.finished (asked, nobody, onKey, onDot, onPause, elsewhere), _) =>
            asked == some { start := 0, stop := 2, sources := [] } && nobody.isNone &&
              onKey == #["reading", "dots"] &&
              onDot == #["dots"] &&
              onPause == #[] &&
              elsewhere == #[]
          | _ => false },
    { name :=
        "a dispatched command that asks for the display rules is answered the rules the loop was told of, and the state is as it was"
      run :=
        let rules : Array DisplayRule :=
          #[{ mode := some "notes", target := .edge .left }, { target := .main, focus := false }]
        let program : EditorM (Guarded (Array DisplayRule) × EditorState × EditorState) := do
          let state ← twoBuffers
          let (ended, after) ←
            (RegistryRequest.ask .displayRules).dispatched { displayRules := rules } state
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
        "a command that asks which names commands are registered under is answered the names the loop was told of the registry, in their order, and none where it was told none; the state is as it was"
      run :=
        pure <|
          let asks (registered : Loop.Registered) : Option (Guarded (Array String) × Bool) :=
            let program : EditorM (Guarded (Array String) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← commandNames.dispatched registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          asks { commandNames := #["load-theme", "quit", "mine"] } ==
              some (.finished #["load-theme", "quit", "mine"], true) &&
            asks {} == some (.finished #[], true) },
    { name :=
        "a command that asks which key sequences reach a command in a view is answered what the loop was told for that view, and none where it was told nothing; the state is as it was"
      run :=
        pure <|
          let bound : KeyBinding :=
            { keys := [controlKey "c", charKey "m"], command := "marked", desc := some "Mark" }
          let asks (registered : Loop.Registered) : Option (Guarded (Array KeyBinding) × Bool) :=
            let program : EditorM (Guarded (Array KeyBinding) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ← (keyBindings ⟨3⟩).dispatched registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          asks { keyBindings := fun view => if view == ⟨3⟩ then #[bound] else #[] } ==
              some (.finished #[bound], true) &&
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
              return (reply, state.outbox.theme, { state with outbox.theme := none } == start)
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
          (command.runModel editorModel).1.toOption == some false },
    { name :=
        "a command that asks a source by a name the loop was told no source of is answered none, with the state as it was; by a name it was told of, the source runs inside the command with the query handed, its state requests answered from the state the command had reached, and the answer carries the source's category and whether it filtered already"
      run :=
        pure <|
          let said : Completion.Source :=
            { name := "said", category := "said"
              candidates := fun _ => do
                return #[.ofText (← editorState).echo] }
          let registered : Loop.Registered :=
            {
              sources := fun name =>
                match name with
                | "echo" => some (Completion.Fake.echo "echo" "test")
                | "filtering" =>
                  some { Completion.Fake.echo "filtering" "test" with filtered := true }
                | "said" => some said
                | _ => none }
          let command :
            EditorM
              (Option Completion.Answer ×
                Bool ×
                Option Completion.Answer ×
                Option (Array Completion.Candidate) × Option Completion.Answer) :=
            do
            let start ← editorState
            let missing ← ControlRequest.ask (.askSource "nope" { text := "w", view := ⟨0⟩ })
            let unchanged := (← editorState) == start
            let echoed ← ControlRequest.ask (.askSource "echo" { text := "wq", view := ⟨1⟩ })
            message "hello"
            let read ← ControlRequest.ask (.askSource "said" { text := "", view := ⟨0⟩ })
            let filtering ← ControlRequest.ask (.askSource "filtering" { text := "w", view := ⟨0⟩ })
            return (missing, unchanged, echoed, read.map (·.candidates), filtering)
          let program : EditorM (Guarded _ × EditorState) := do
            command.dispatched registered (← EditorState.initial ⟨640, 480⟩)
          match (program.runModel editorModel).1 with
          | .ok (outcome, _) =>
            outcome ==
              .finished
                (none, true,
                  some
                    { category := "test", filtered := false
                      candidates := #[{ text := "wq", annotation := some "1" }] },
                  some #[.ofText "hello"],
                  some
                    { category := "test", filtered := true
                      candidates := #[{ text := "w", annotation := some "0" }] })
          | .error _ => false },
    { name :=
        "a command that asks a registered source that answers later is answered its category, whether it filtered, no candidates and how it answers, and the source's candidates are never run; asked whether a job is registered, it is answered from the names the loop was told"
      run :=
        pure <|
          let later : Completion.Source :=
            {
              Completion.Source.answeringLater "later" "pick" "later-pick" (.afterPause 20)
                true with
              candidates := fun _ => do
                discard <| (⟨99⟩ : TextId).read
                return offered #["never"] }
          let registered : Loop.Registered :=
            { sources := fun name => if name == "later" then some later else none
              jobs := (· == "later-pick") }
          let command : EditorM (Option Completion.Answer × Bool × Bool) := do
            let answered ← ControlRequest.ask (.askSource "later" { text := "w", view := ⟨0⟩ })
            return (answered, ← RegistryRequest.ask (.hasJob "later-pick"),
                ← RegistryRequest.ask (.hasJob "nope"))
          let program : EditorM (Guarded _ × EditorState) := do
            command.dispatched registered (← EditorState.initial ⟨640, 480⟩)
          match (program.runModel editorModel).1 with
          | .ok (outcome, _) =>
            outcome ==
              .finished
                (some {
                      category := "pick", filtered := true, candidates := #[]
                      later := some { job := "later-pick", reask := .afterPause 20 } },
                  true, false)
          | .error _ => false },
    { name :=
        "a command that asks which sources are registered in a category is answered the names the loop was told, in their order, and none for a category it was told none of; the state is as it was"
      run :=
        pure <|
          let registered : Loop.Registered :=
            {
              categorySources := fun category =>
                if category == "buffer" then #["buffers", "mine"] else #[] }
          let asks (category : String) : Option (Guarded (Array String) × Bool) :=
            let program : EditorM (Guarded (Array String) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ←
                (RegistryRequest.ask (.categorySources category) :
                        EditorM (Array String)).dispatched
                    registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          asks "buffer" == some (.finished #["buffers", "mine"], true) &&
            asks "other" == some (.finished #[], true) },
    { name :=
        "a command that asks for a text to be matched with a category's style is answered the hits of the style the loop was told for that category, and of the default for another category and for none, each run over the matcher; the state is as it was"
      run :=
        pure <|
          let registered : Loop.Registered :=
            {
              matching :=
                { default := .unregistered
                  byCategory := fun category =>
                    if category == "buffer" then some containing else none } }
          let candidates := #["wq", "edit", "rewrite", "w"]
          let asks (category : Option String) : Option (Guarded (Array Completion.Hit) × Bool) :=
            let program : EditorM (Guarded (Array Completion.Hit) × Bool) := do
              let start ← EditorState.initial ⟨640, 480⟩
              let (outcome, state) ←
                (ControlRequest.ask (.matchCandidates category "w" candidates) :
                        EditorM (Array Completion.Hit)).dispatched
                    registered start
              return (outcome, state == start)
            (program.runModel editorModel).1.toOption
          let orderless := styled containing "w" candidates
          let fuzzy := styled Completion.Style.unregistered "w" candidates
          orderless != fuzzy && asks (some "buffer") == some (.finished orderless, true) &&
            asks (some "other") == some (.finished fuzzy, true) &&
            asks none == some (.finished fuzzy, true) },
    { name :=
        "a source asked by name that is refused refuses the asking command at the request, with nothing of the asking command run after it"
      run :=
        pure <|
          let registered : Loop.Registered :=
            {
              sources := fun name =>
                if name == "refusing" then some (Completion.Fake.refusing "refusing" "test")
                else none }
          let asking : EditorM Unit := do
            discard <| createText "early"
            discard <| ControlRequest.ask (.askSource "refusing" { text := "", view := ⟨0⟩ })
            discard <| createText "late"
          let program : EditorM (Guarded Unit × EditorState) := do
            asking.dispatched registered (← EditorState.initial ⟨640, 480⟩)
          match program.runModel editorModel with
          | (.ok (outcome, _), model) =>
            outcome == .refused .badRange && model.texts.contents == #["", "early"]
          | (.error _, _) => false },
    { name :=
        "a command that asks a source by name where no loop dispatches it is answered none: the handler of the runners knows no registry"
      run :=
        pure <|
          let command : EditorM (Option Completion.Answer) :=
            ControlRequest.ask (.askSource "echo" { text := "w", view := ⟨0⟩ })
          (command.runModel editorModel).1.toOption == some none }]

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
                loop.state.outbox.answered.isEmpty &&
                  steps.back?.map (·.ended) == some (some (.refused .badRange)))
          (program.runModel editorModel).1.toOption ==
            some (some "abc", [none, none], "go: refused: bad range", true, true) },
    { name :=
        "after a command that dropped a jump list's entry has run to its end, its marker is given up and the entry kept still answers, with nothing in the echo"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Bool) := do
            let state ← threeWindows
            let text : TextId := ⟨0⟩
            let dropped ← text.mark (.anchor { offset := 0, bias := .after })
            let kept ← text.mark (.anchor { offset := 0, bias := .after })
            let held (marker : MarkerId) : Place := .held ⟨0⟩ marker
            let (_, state) :=
              state.setJumps ⟨0⟩ { list := { entries := #[held dropped, held kept], index := 2 } }
            let (loop, _) ←
              stepsWith
                  (ran (asks [.setJumps ⟨0⟩ { list := { entries := #[held kept], index := 1 } }]))
                  ({ state } : TestLoop) (presses "C-c g")
            return ([← refusalOf (text.marker dropped), ← refusalOf (text.marker kept)],
                loop.state.echo, loop.state.wellFormed)
          (program.runModel editorModel).1.toOption ==
            some ([some .noSuchMarker, none], "", true) },
    { name :=
        "a marker a split's copy of a jump list shares is kept while one window holds it, and given up once none does"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String) := do
            let state ← threeWindows
            let text : TextId := ⟨0⟩
            let shared ← text.mark (.anchor { offset := 0, bias := .after })
            let jumps : Jumps := { list := { entries := #[.held ⟨0⟩ shared], index := 1 } }
            let (_, state) := state.setJumps ⟨0⟩ jumps
            let (_, state) := state.setJumps ⟨1⟩ jumps
            let (closed, _) ←
              stepsWith (ran (asks [.removeWindow ⟨1⟩])) ({ state } : TestLoop) (presses "C-c g")
            let whileHeld ← refusalOf (text.marker shared)
            let (cleared, _) ← stepsWith (ran (asks [.setJumps ⟨0⟩ {}])) closed (presses "C-c g")
            return ([whileHeld, ← refusalOf (text.marker shared)], cleared.state.echo)
          (program.runModel editorModel).1.toOption == some ([none, some .noSuchMarker], "") },
    { name :=
        "a command that drops a jump list's entry and is then refused gives up nothing: the entry and its marker are as they were"
      run :=
        pure <|
          let program : EditorM (Option TextError × Bool) := do
            let state ← threeWindows
            let text : TextId := ⟨0⟩
            let marker ← text.mark (.anchor { offset := 0, bias := .after })
            let jumps : Jumps := { list := { entries := #[.held ⟨0⟩ marker], index := 1 } }
            let (_, state) := state.setJumps ⟨0⟩ jumps
            let (loop, _) ←
              stepsWith (bound (failingAfter fun _ => asks [.setJumps ⟨0⟩ {}]))
                  ({ state } : TestLoop) (presses "C-c g")
            return (← refusalOf (text.marker marker),
                (loop.state.window? ⟨0⟩).map (·.jumps) == some jumps)
          (program.runModel editorModel).1.toOption == some (none, true) },
    { name :=
        "after a command that removed a buffer has run to its end, the markers of its marks and of the places held in it are given up before its text is released, with nothing in the echo"
      run :=
        pure <|
          let program : EditorM (List (Option TextError) × String × Bool) := do
            let (state, text) ← hiddenBuffer
            let mark ← text.mark (.anchor { offset := 0, bias := .after })
            let entry ← text.mark (.anchor { offset := 0, bias := .after })
            let global ← text.mark (.anchor { offset := 0, bias := .after })
            let (_, state) := state.setLocalMark ⟨2⟩ 'a' (some mark)
            let (_, state) :=
              state.setJumps ⟨0⟩ { list := { entries := #[.held ⟨2⟩ entry], index := 1 } }
            let (_, state) := state.setGlobalMark 'A' (some (.held ⟨2⟩ global))
            let (loop, _) ←
              stepsWith (ran (asks [.removeBuffer ⟨2⟩])) ({ state } : TestLoop) (presses "C-c g")
            return ([← refusalOf text.read], loop.state.echo,
                loop.state.wellFormed && loop.state.placeMarkers.isEmpty)
          (program.runModel editorModel).1.toOption == some ([some .noSuchText], "", true) }]

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
            [(Editor.Test.keys "C-c 1", invoke "focus"), (Editor.Test.keys "C-c x", invoke "close"),
              (Editor.Test.keys "C-c f", invoke "fail")]]
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
            [(Editor.Test.keys "C-c a", invoke "ask"), (Editor.Test.keys "C-c f", invoke "fail"),
              (Editor.Test.keys "C-c y", invoke "accept"),
              (Editor.Test.keys "C-c s", invoke "swap"), (Editor.Test.keys "C-c n", invoke "idle")]]
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
notice of a closed view, undo from a command, what a command is told of
its view, and the key hints: what they list, when and where they are
shown, and the pending keys' segment. -/
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
    dispatchRunCommandChecks ++
    dispatchHintChecks ++
    keyHintLoopChecks

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
    { name := "the scheme's localleader followed by a mode's suffix runs that mode's local command"
      run :=
        let registry :=
          modeRegistry.replaceModes .config
            #[{ filling "major" [Role.nextItem] with locals := [("C-x", "major-local")] }]
        let typed := TestScheme.scheme.leaders.localLeader ++ keys "C-x"
        pure
          (roleTyped registry (withModes "major" []) typed ==
              some #[some "major-local", some "other"] &&
            roleTyped registry (withModes "major" []) typed ⟨1⟩ == some #[some "", some "other"]) }]

/-- `candidateDriver` whose prompts are shown by a display of no rows, so no
candidate list is drawn: for the checks that count what the listing alone
costs. -/
def unshownDriver (model : EditorModel := editorModel) : Option TestDriver :=
  (Loop.Driver.over
      { candidateKeys with displaying := { default := { windowed with sheet := fun _ => {} } } }
      driverJobs (EditorState.initial ⟨640, 480⟩) model).toOption

/-- `candidateDriver` whose prompts are matched by a job over more than
`inline` candidates (`Loop.Keys.inlineMatches`), two unless given, so the
four pick candidates are. -/
def smallLimitDriver (model : EditorModel := editorModel) (inline : Nat := 2) : Option TestDriver :=
  (Loop.Driver.over { candidateKeys with inlineMatches := inline } driverJobs
      (EditorState.initial ⟨640, 480⟩) model).toOption

/-- The status line of the minibuffer's view of a prompt of the candidate
checks listing `texts` for `pattern`: the label, then a field for each the
fuzzy model answers for the pattern, in its order, in the candidates'
face. -/
def laterFields (pattern : String) (texts : Array String) : Array StatusField :=
  #[{ text := pickLabel, face := Loop.promptFace }] ++
    (FuzzyModel.rank pattern texts).filterMap fun index =>
      (texts[index]?).map fun text => { text, face := windowedRow }

/-- The ids of the jobs `driver` holds, at a post or finished and not
delivered, each with its name. -/
def heldJobs (driver : TestDriver) : Array (Nat × String) :=
  driver.posting.map (fun job => (job.id, job.name)) ++
    driver.pending.map fun job => (job.id, job.name)

/-- A driver of the candidate checks whose loop is told of one source,
`pickSource`, registered under its name. -/
def namedPickDriver : Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    { candidateKeys with
      registered :=
        { sources := fun name => if name == pickSource.name then some pickSource else none } }
  (Loop.Driver.over keys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- A driver of the candidate checks whose loop is told that the category
`pick` has the sources `names`, each answered by `sources`. -/
def categoryDriver (names : Array String) (sources : String → Option Completion.Source) :
    Option TestDriver :=
  let keys : Loop.Keys TestScheme.scheme :=
    { candidateKeys with
      registered :=
        { sources, categorySources := fun category => if category == "pick" then names else #[] } }
  (Loop.Driver.over keys driverJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- `driver` with the choice of its open prompt moved by `steps`, through
the state and not by a command. -/
def chose (driver : TestDriver) (steps : List Candidates.Step) : TestDriver :=
  { driver with
    loop :=
      { driver.loop with
        state :=
          steps.foldl (fun state step => (state.chooseCandidate step).2) driver.loop.state } }

/-- The text the candidate list's view shows in the last scene `driver`'s
display model holds, if it is there. -/
def listText (driver : TestDriver) : Option String := do
  shownText driver.model (← listView driver)

/-- The rectangle of the view `id` in the last scene `driver`'s display
model holds, if the view is there. -/
def viewRect (driver : TestDriver) (id : ViewId) : Option Rect := do
  ((← driver.model.display.scenes.back?).views.find? (·.id == id)).map (·.rect)

/-- The status line of the minibuffer's view of a prompt of the candidate
checks whose minibuffer holds `pattern`: the label, then a field for each
candidate the fuzzy model answers for the pattern, in its order, with the
one at `chosen` of them, if any, in the chosen face. -/
def pickFields (pattern : String) (chosen : Option Nat := none) : Array StatusField :=
  #[{ text := pickLabel, face := Loop.promptFace }] ++
    (pickListed pattern).listed.mapIdx fun index candidate =>
      { text := candidate.text
        face := if chosen == some index then windowedChosen else windowedRow }

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
        "a prompt matched by a style and drawn by a display written here, neither shipped, lists the candidates the style keeps in its order, draws the display's rows in the candidate list's view, and accepting takes the chosen one"
      run :=
        pure <|
          let reversing : Completion.Style :=
            { name := "reversing"
              hits := fun text candidates =>
                pure <|
                  ((Array.range candidates.size).filter fun index =>
                        (candidates[index]?).any (·.startsWith text)).reverse.map
                    Completion.Hit.ofIndex }
          let bracketed : Completion.Display :=
            { name := "bracketed"
              sheet := fun showing =>
                {
                  rows :=
                    showing.listed.mapIdx fun index listed =>
                      {
                        text :=
                          if showing.chosen == some index then s!"[{listed.text}]"
                          else listed.text } } }
          let written : Config.Owner := { name := "written" }
          let registry : Config.Registry :=
            ((minibufferRegistry.replaceStyles written #[reversing]).replaceDisplays written
                  #[bracketed]).replaceBindings
              .config
              ((minibufferBindings ++ [("C-c l", "ask-letters")]).toArray.map fun (text, command) =>
                .ofKeys (keys text) command)
          let asking : Dispatched := fun _ => do
            discard <|
                prompt "Letter: " asked "" [.given (.ofTexts "letters" "letter" #["ab", "b", "ac"])]
            return none
          let keys : Loop.Keys TestScheme.scheme :=
            { minibufferKeys with
              maps := registry.activeMaps TestScheme.scheme
              matching := registry.matching
              displaying := registry.displaying
              command? := fun name =>
                if name == "ask-letters" then some asking else minibufferKeys.command? name }
          match
            (Loop.Driver.over keys driverJobs (EditorState.initial ⟨640, 480⟩)
                editorModel).toOption with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c l a")
            let (chosen, _) := fedTo typed (rolePresses Role.nextItem)
            let (accepted, _) := fedTo chosen (presses "C-c 1")
            (registry.matching.styleFor (some "letter")).name == "reversing" &&
              (registry.displaying.displayFor (some "letter")).name == "bracketed" &&
              (candidatesOf typed).map (·.listed.map (·.text)) == some #["ac", "ab"] &&
              listText typed == some "ac\nab" &&
              listText chosen == some "[ac]\nab" &&
              promptEcho accepted == greeted [.str "ac", .nat 7] &&
              accepted.loop.state.prompt.isNone },
    { name :=
        "a filtered source's candidates are listed in the order it gave, none dropped, each with the style's ranges where it matches: passed c, ab and xyz for b list c, ab and xyz, with ranges on ab alone; for the empty text no style marks them"
      run :=
        pure <|
          let passed := offered #["c", "ab", "xyz"]
          let candidates : Candidates := { passed }
          let listing (pattern : String) := ranked (candidates.listing pattern marking)
          let hitRanges := ((styled marking "b" #["ab"])[0]?).map (·.ranges)
          let marked := listing "b"
          marked.map (·.text) == #["c", "ab", "xyz"] &&
            marked.map (·.ranges) == #[#[], hitRanges.getD #[], #[]] &&
            hitRanges.any (!·.isEmpty) &&
            listing "" == passed.map Completion.Listed.of },
    { name :=
        "the scene lists the candidates one a row in a view of their own, directly above the minibuffer's; the windows above are shorter by its rows while it is open and get them back when it closes"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (cancelled, _) := fedTo asking (presses "C-c n")
            let heights := asking.loop.state.heights
            let rows := (pickListed "").listed.size
            match listView asking, asking.loop.state.minibufferView? with
            | some list, some minibuffer =>
              listText asking ==
                  some ("\n".intercalate ((pickListed "").listed.map (·.text)).toList) &&
                rows == pickCandidates.size &&
                some (list.rect.y + list.rect.height) == (viewRect asking minibuffer).map (·.y) &&
                list.rect.height == rows * heights.text &&
                list.selections.isEmpty &&
                list.status.isEmpty &&
                (viewRect asking ⟨0⟩).map (·.height) ==
                  some (480 - heights.message - heights.text - rows * heights.text) &&
                (viewRect cancelled ⟨0⟩).map (·.height) == some (480 - heights.message) &&
                (listView cancelled).isNone
            | _, _ => false },
    { name :=
        "moving the choice past the last row shown scrolls the list so the chosen candidate stays shown, through the loop: of fifteen, the scene's list shows the first ten, then from the second on after eleven steps forward, the first ten again after ten back, and the last ten when the last is chosen from nothing"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c 9")
            let stepped (driver : TestDriver) (steps : List Candidates.Step) : TestDriver :=
              steps.foldl (fun driver step => (fedTo (chose driver [step]) (presses "C-c s")).1)
                driver
            let order := (FuzzyModel.rank "" manyTexts).filterMap (manyTexts[·]?)
            let window (first : Nat) : Option String :=
              some ("\n".intercalate (order.extract first (first + windowedRows)).toList)
            let down := stepped asking (List.replicate 11 .next)
            let up := stepped down (List.replicate 10 .previous)
            let last := stepped asking [.previous]
            order.size == 15 && listText asking == window 0 && listText down == window 1 &&
              listText up == window 0 &&
              listText last == window 5 },
    { name :=
        "typing that cuts the matches leaves the strip as tall as it has been: the window's view and the list's keep their rectangles and the list shows fewer lines; the cancel key gives the height back"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (typed, _) := fedTo asking (presses "e")
            let (cancelled, _) := fedTo typed (presses "C-c n")
            let lines (driver : TestDriver) : Nat :=
              ((listText driver).map fun text => (text.splitOn "\n").length).getD 0
            (pickListed "e").listed.size < pickCandidates.size &&
              viewRect asking ⟨0⟩ == viewRect typed ⟨0⟩ &&
              (listView typed).isSome &&
              (listView asking).map (·.rect) == (listView typed).map (·.rect) &&
              lines typed == (pickListed "e").listed.size &&
              lines asking == pickCandidates.size &&
              (viewRect cancelled ⟨0⟩).map (·.height) ==
                some (480 - cancelled.loop.state.heights.message) },
    { name :=
        "with the loop handed a style that keeps the candidates holding the text for the category pick and marking for the rest, after w is typed a pick prompt lists the first's hits, in the candidates' order with w last, and a prompt of another category lists the fuzzy model's, with w first"
      run :=
        pure <|
          let keys : Loop.Keys TestScheme.scheme :=
            { candidateKeys with
              matching :=
                { default := marking
                  byCategory := fun category =>
                    if category == "pick" then some containing else none } }
          match
            (Loop.Driver.over keys driverJobs (EditorState.initial ⟨640, 480⟩)
                editorModel).toOption with
          | none => false
          | some driver =>
            let (pick, _) := fedTo driver (presses "C-c a w")
            let (other, _) := fedTo driver (presses "C-c 6 w")
            let listing (style : Completion.Style) : Array (String × Array Completion.Span) :=
              (styled style "w" pickCandidates).map fun hit =>
                ((pickCandidates[hit.index]?).getD "", hit.ranges)
            let listed (driver : TestDriver) : Option (Array (String × Array Completion.Span)) :=
              (candidatesOf driver).map (·.listed.map fun listed => (listed.text, listed.ranges))
            listed pick == some (listing containing) && listed other == some (listing marking) &&
              (listed pick).bind (·.back?.map (·.1)) == some "w" &&
              (listed other).bind (·[0]?.map (·.1)) == some "w" },
    { name :=
        "a prompt that asks for a category lists its defaults where the loop knows no source of it; the sources registered in it after a default it does not name; and a source registered under a default's name in that default's place"
      run :=
        pure <|
          let extra : Completion.Source := .ofTexts "extra" "pick" #["xw"]
          let only : Completion.Source := .ofTexts "pick" "pick" #["only"]
          let lookup (sources : List Completion.Source) (name : String) :
            Option Completion.Source := sources.find? (·.name == name)
          match candidateDriver, categoryDriver #["extra"] (lookup [extra]),
            categoryDriver #["pick", "extra"] (lookup [only, extra]) with
          | some bare, some added, some replaced =>
            let (asked, _) := fedTo bare (presses "C-c 7")
            let (picked, _) := fedTo bare (presses "C-c a")
            let (more, _) := fedTo added (presses "C-c 7")
            let (instead, _) := fedTo replaced (presses "C-c 7")
            let xw := (Completion.Candidate.ofText "xw").inGroup "extra"
            candidatesOf asked == candidatesOf picked &&
              candidatesOf asked == some (pickListed "") &&
              (candidatesOf more).map (·.all) == some (pickOffered.push xw) &&
              (candidatesOf more).map (·.category) == some (some "pick") &&
              (candidatesOf instead).map (·.all) ==
                some #[(Completion.Candidate.ofText "only").inGroup "pick", xw]
          | _, _, _ => false },
    { name :=
        "a prompt asked with a source and one that has filtered already keeps the first's candidates to match and the filtered one's apart, in its group, and the first source's category; after a text is typed it lists the matches in the fuzzy model's order, each with the style's ranges, then the filtered source's candidates in the order it gave them, though one does not match, the one that matches with the style's ranges"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c 5")
            let (typed, _) := fedTo asking (presses "w")
            let passed := (offered #["zz", "w"]).map (·.inGroup filteredSource.name)
            -- For `w`, `zz` is not marked and `w` is; for the empty text
            -- neither is.
            let passedListed (pattern : String) : Array Completion.Listed :=
              passed.map fun candidate =>
                .of candidate
                  (if pattern.isEmpty || candidate.text == "zz" then #[]
                  else markedSpans pattern candidate.text)
            let withPassed (listed : Candidates) : Candidates :=
              let pattern := listed.listedFor.getD ""
              { listed with
                passed, listed := listed.listed ++ passedListed pattern
                grouped := Completion.grouped (listed.listed ++ passedListed pattern) }
            candidatesOf asking == some (withPassed (pickListed "")) &&
              (candidatesOf asking).map (·.all) == some pickOffered &&
              (candidatesOf asking).map (·.category) == some (some "pick") &&
              candidatesOf typed == some (withPassed (pickListed "w")) &&
              (markedSpans "w" "w").size == 1 &&
              (candidatesOf typed).map (fun listed => (listed.listed.map (·.text)).toList.drop 3) ==
                some ["zz", "w"] },
    { name :=
        "a prompt asked with only a source that has filtered already holds no candidate to match, the filtered one's apart in its group, and that source's category; after a text is typed it lists them in the order the source gave, the one the style matches with the style's ranges, and the listing asks the style once, for its ranges: its step costs the read of the minibuffer and one ranking, as a prompt with candidates to match does, shown by a display of no rows"
      run :=
        pure <|
          match unshownDriver countingModel with
          | none => false
          | some driver =>
            -- How many requests the last of `keys` took.
            let cost (keys : String) : Nat :=
              let events := presses keys
              let (before, _) := fedTo driver events.dropLast
              let (after, _) := fedTo before (events.drop (events.length - 1))
              after.model.watch.clock - before.model.watch.clock
            let (asking, _) := fedTo driver (presses "C-c 8")
            let (typed, _) := fedTo asking (presses "w")
            let passed := (offered #["zz", "w"]).map (·.inGroup filteredSource.name)
            let listing (pattern : String) : Candidates :=
              { passed, category := some filteredSource.category, listedFor := some pattern
                listed :=
                  passed.map fun candidate =>
                    .of candidate
                      (if pattern.isEmpty || candidate.text == "zz" then #[]
                      else markedSpans pattern candidate.text)
                place := rootPlace }
            candidatesOf asking == some (listing "") &&
              (candidatesOf asking).map (·.all) == some #[] &&
              (candidatesOf asking).map (·.category) == some (some "other") &&
              candidatesOf typed == some (listing "w") &&
              (candidatesOf typed).map (·.listed.map (·.text)) == some #["zz", "w"] &&
              (candidatesOf typed).map (·.listed.map (·.ranges.isEmpty)) == some #[true, false] &&
              cost "C-c 8 w" == cost "C-c p w" + 2 &&
              cost "C-c a w" == cost "C-c p w" + 2 },
    { name :=
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
              (candidatesOf one).map (·.listed[0]?.map (·.text)) == some (some "w") &&
              (candidatesOf one).map (·.listed.size) == some 3 &&
              pickCandidates.back? == some "w" &&
              candidatesOf two == some (pickListed "wq") &&
              (candidatesOf two).map (·.listed.map (·.text)) == some #["wq"] &&
              candidatesOf three == some (pickListed "wqz") &&
              (candidatesOf three).map (·.listed.map (·.text)) == some #[] &&
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
        "what the listing costs, counted on the watch model's clock: a prompt with candidates is published with one request more than one with none, the read of the minibuffer, while its text is as it was, and with two more, the read and the ranking, at the step that asked for it and at each step that changed the text; the prompt is shown by a display of no rows, so no list is drawn"
      run :=
        pure <|
          match unshownDriver countingModel with
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
        "text typed into a prompt with candidates: in the scene, the minibuffer's view's status line is the label, in the prompt's face, and the candidate list has one row for each candidate the fuzzy model answers for that text, in its order, each in the candidates' face; the other view's status line lists none"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asking, _) := fedTo driver (presses "C-c a")
            let (typed, _) := fedTo asking (presses "e")
            pickShown asking == some (pickFields "") &&
              (pickShown asking).map (·.size) == some (1 + pickCandidates.size) &&
              pickShown typed == some (pickFields "e") &&
              (pickShown typed).map (·.size) == some 3 &&
              (statusIn typed ⟨0⟩).map (·.any (·.face == windowedRow)) == some false },
    { name :=
        "where a candidate is the typed text and others match it too, its row is the first of the list, though it is the last of the candidates"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            pickShown typed == some (pickFields "w") &&
              ((pickShown typed).map fun fields => (fields.map (·.text)).extract 0 2) ==
                some #[pickLabel, "w"] &&
              (pickShown typed).map (·.size) == some 4 &&
              pickCandidates.back? == some "w" },
    { name :=
        "a text no candidate matches: the scene lists none, and the minibuffer's status line is the label alone, with the list empty; so is that of a prompt asked with no candidates"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a z")
            let (plain, _) := fedTo driver (presses "C-c p w")
            let label : Array StatusField := #[{ text := pickLabel, face := Loop.promptFace }]
            pickShown typed == some label && pickShown plain == some label &&
              minibufferText typed == some "z" },
    { name :=
        "with a candidate chosen, its row of the candidate list and no other is in the chosen face, and the rows say what they said"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (typed, _) := fedTo driver (presses "C-c a w")
            let (second, _) := fedTo (chose typed [.next, .next]) (presses "C-c s")
            let (unchosen, _) := fedTo (chose second [.next, .next]) (presses "C-c s")
            pickShown second == some (pickFields "w" (some 1)) &&
              ((pickShown second).map fun fields => fields.map (·.face == windowedChosen)) ==
                some #[false, false, true, false] &&
              windowedChosen != windowedRow &&
              candidatesOf unchosen == some (pickListed "w") &&
              pickShown unchosen == some (pickFields "w") },
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
            let first := (pickListed "e").listed[0]?.map (·.text)
            !(rolePresses Role.nextItem).isEmpty && first.isSome && first != some "e" &&
              candidatesOf chosen == some (pickListed "e" (some 0)) &&
              minibufferText chosen == some "e" &&
              first.map (fun candidate => picked [.str candidate, .nat 7]) ==
                some (promptEcho accepted) &&
              accepted.loop.state.prompt == none },
    { name :=
        "the keys of the roles next-item and previous-item move the choice through the listing, and the scene's chosen row follows: next twice is the second, previous then the first, previous again nothing, and previous from nothing the last"
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
              pickShown second == some (pickFields "w" (some 1)) &&
              candidatesOf first == some (pickListed "w" (some 0)) &&
              pickShown first == some (pickFields "w" (some 0)) &&
              candidatesOf unchosen == some (pickListed "w") &&
              pickShown unchosen == some (pickFields "w") &&
              candidatesOf last == some (pickListed "w" (some 2)) &&
              pickShown last == some (pickFields "w" (some 2)) &&
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
              pickShown typed == some (pickFields "ed") &&
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
              (candidatesOf typed).map (·.listed.map (·.text)) == some #[] &&
              pickShown typed == some label &&
              candidatesOf moved == candidatesOf typed &&
              pickShown moved == some label &&
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
            !PromptRefusal.notOpen.describe.isEmpty &&
              promptEcho next == PromptRefusal.notOpen.describe &&
              promptEcho previous == PromptRefusal.notOpen.describe &&
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
                pickShown chosen == some (pickFields "w" (some 1)) &&
                pickShown after == pickShown chosen &&
                candidatesOf after == some (pickListed "w" (some 1)) &&
                after.loop.state.wellFormed },
    { name :=
        "a prompt asked with two sources holds the candidates of both, the first source's then the second's, each in its source's group, and its listing for the empty text is the fuzzy model's order of all of them; a candidate with a group of its own keeps it"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (two, _) := fedTo driver (presses "C-c 2")
            let (grouped, _) := fedTo driver (presses "C-c g")
            let pairs (all : Array Completion.Candidate) : Array (String × Option String) :=
              all.map fun candidate => (candidate.text, candidate.group)
            let both :=
              #[("wq", some "a"), ("edit", some "a"), ("rewrite", some "b"), ("w", some "b")]
            let ranked := (FuzzyModel.rank "" (both.map (·.1))).filterMap (both[·]?)
            (candidatesOf two).map (pairs ·.all) == some both &&
              (candidatesOf two).map (pairs <| ·.listed.map (·.candidate)) == some ranked &&
              (candidatesOf two).map (·.listedFor) == some (some "") &&
              (candidatesOf grouped).map (pairs ·.all) ==
                some #[("x", some "own"), ("y", some "c")] },
    { name :=
        "a prompt asked with a source by name holds what the source registered under that name answers, the same as the prompt asked with that source as a value; where no source is registered under the name it is refused with noSuchSource, no prompt opens and no text is made"
      run :=
        pure <|
          match candidateDriver, namedPickDriver with
          | some driver, some registered =>
            let (named, _) := fedTo registered (presses "C-c m")
            let (given, _) := fedTo driver (presses "C-c a")
            let (refused, _) := fedTo driver (presses "C-c m")
            candidatesOf named == some (pickListed "") &&
              candidatesOf named == candidatesOf given &&
              promptEcho named == "" &&
              refused.loop.state.prompt.isNone &&
              promptEcho refused == PromptRefusal.describe (.noSuchSource pickSource.name) &&
              refused.model.texts.contents == driver.model.texts.contents
          | _, _ => false },
    { name :=
        "a source that is refused refuses the asking command: no prompt opens and no text is made"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver (presses "C-c r")
            refused.loop.state.prompt.isNone &&
              refused.model.texts.contents == driver.model.texts.contents },
    { name :=
        "a source is asked with the prompt's initial text and the view the prompt was asked from"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (echoed, _) := fedTo driver (presses "C-c e")
            match echoed.loop.state.prompt with
            | none => false
            | some asked =>
              asked.candidates.all ==
                #[{ text := "w", annotation := some (toString asked.asker.index),
                    group := some "echo" }] }]

/-- A loop over `twoBuffers` with a prompt open whose candidates are
`candidates`, its minibuffer read as `typed` at the last publish, and the
keys `keys` of its completion jobs recorded; with the prompt's view.
`none` if making the state was refused. -/
def promptLoop (candidates : Candidates) (typed : Option String := none)
    (keys : Array String := #[]) : Option (Loop TestScheme.scheme × ViewId) := do
  let state ← onTextModel twoBuffers
  match prompted state with
  | (.ok view, asking) =>
    some
        ({ state := { withCandidates asking candidates with completionKeys := keys }, typed }, view)
  | _ =>
    none

/-- What a step of the completion job checks is handed: `later-pick` is the
one job registered, the config generation is `generation`, a prompt over
more than `inline` candidates is matched by a job, and the style is
`style`, which config owns when `owned`. -/
def jobKeys (generation : Nat := 0) (inline : Nat := 2) (style : Completion.Style := marking)
    (owned : Bool := false) : Loop.Keys TestScheme.scheme :=
  { registered := { jobs := (· == "later-pick"), generation }, inlineMatches := inline
    matching :=
      { default := style
        ownerFor := fun _ => if owned then Config.Owner.config else Config.Owner.compiled } }

/-- The candidates of the prompt `loop` holds once `spawn`'s work has run on
the job model and the command it finished with has run on that loop's
state: what the match lists. `none` if the work did not finish. -/
def matchedBy (loop : Loop TestScheme.scheme) (spawn : Loop.Spawn) : Option Candidates :=
  match ((spawn.work ()).runModel {}).1 with
  | .finished command =>
    let program : EditorM (Guarded Unit × EditorState) := command.dispatched {} loop.state
    match (program.runModel editorModel).1 with
    | .ok (_, state) => state.prompt.map (·.candidates)
    | .error _ => none
  | _ => none

/-- The checks of the reconciler of a prompt's jobs (`Loop.completionJobs`,
`Editor/Loop.lean`, "Prompts"), pure over the editor state: which source
jobs it starts and cancels, which match it spawns, and that closing a
prompt cancels every job it started for it. -/
def completionJobChecks : List Check :=
  let later : Completion.Later := { job := "later-pick" }
  let source (reask : Completion.Reask := .never) : Completion.Asking :=
    { source := "later", later := { later with reask }, askedFor := "a" }
  [{  name := "a source's order carries the place the prompt's candidates hold"
      run :=
        pure <|
          let place : Completion.Place := { directory := some "/w", home := some "/home/me" }
          match promptLoop { asking := #[source], place } (some "a") with
          | none => false
          | some (loop, view) =>
            let (_, starts, _, _) := loop.completionJobs (jobKeys)
            let order : Completion.Order :=
              { view, index := 0, generation := 1, query := { text := "a", view := ⟨0⟩, place } }
            starts.map (·.arguments) == #[order.arguments] &&
              (starts.map (Completion.Order.ofArguments? ·.arguments)).map
                  (·.map (·.query.place)) ==
                #[some place] },
    { name :=
        "a prompt asked with a place and a context of its command's starts its source's job with both, in place of the asking view's place; the job started again for a typed key carries both too"
      run :=
        pure <|
          let place : Completion.Place := { directory := some "/w", home := some "/home/me" }
          let context : List Argument := [.str "fd", .nat 2, .bool true]
          let asks : Dispatched := fun _ => do
            discard <|
                prompt pickLabel pickContinuation ""
                  [.given (.answeringLater "echo" "pick" "later-echo" (.afterPause 30) true)]
                  (place := some place) (context := context)
            return none
          let keys :=
            dispatchKeys [("C-c t", invoke "ask-placed")]
              (("ask-placed", asks) :: candidateCommands)
          match
            (Loop.Driver.over keys driverJobs (EditorState.initial ⟨640, 480⟩)
                editorModel).toOption with
          | none => false
          | some driver =>
            let (asked, steps) := fedTo driver (presses "C-c t")
            let ordered (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :=
              (steps.back?.join.bind (·.starts[0]?)).bind fun start =>
                Completion.Order.ofArguments? start.arguments
            match asked.posting[0]? with
            | none => false
            | some first =>
              let (echoed, _) := asked.posted first.id
              let (_, typed) := fedTo echoed (presses "w")
              (ordered steps).map (fun order => (order.query.place, order.query.context)) ==
                  some (place, context) &&
                (candidatesOf asked).map (fun held => (held.place, held.context)) ==
                  some (place, context) &&
                (ordered typed).map
                    (fun order => (order.query.text, order.query.place, order.query.context)) ==
                  some ("w", place, context) },
    { name :=
        "a source not yet asked has its job started once, under `completion <view> <source>`, with the order of the first generation for the text it was asked with and no pause, and its key recorded; asked again with the text unchanged, or by a source asked once with the text changed, nothing is started"
      run :=
        pure <|
          match promptLoop { asking := #[source] } (some "a") with
          | none => false
          | some (loop, view) =>
            let (started, starts, cancels, spawns) := loop.completionJobs (jobKeys)
            let key := Loop.sourceKey view "later"
            let order : Completion.Order :=
              { view, index := 0, generation := 1, query := { text := "a", view := ⟨0⟩ } }
            let (_, again, againCancels, _) := started.completionJobs (jobKeys)
            let (_, typed, _, _) := { started with typed := some "b" }.completionJobs (jobKeys)
            starts == #[{ name := "later-pick", arguments := order.arguments, key := some key }] &&
              cancels.isEmpty &&
              spawns.isEmpty &&
              started.state.completionKeys == #[key] &&
              (started.state.prompt.map (·.candidates.asking.map (·.generation))) == some #[1] &&
              again.isEmpty &&
              againCancels.isEmpty &&
              typed.isEmpty },
    { name :=
        "a source that depends on the text, asked with another text than the typed one, has its job cancelled and started again under its key, at the next generation, for the typed text, after its pause; what it answered stays until the new generation's first batch"
      run :=
        pure <|
          let asked : Completion.Asking :=
            { source (.afterPause 30) with
              generation := 1, answered := offered #["old"], fresh := true, done := true }
          match promptLoop { asking := #[asked] } (some "b") with
          | none => false
          | some (loop, view) =>
            let key := Loop.sourceKey view "later"
            let (after, starts, cancels, _) :=
              { loop with state := { loop.state with completionKeys := #[key] } }.completionJobs
                (jobKeys)
            let order : Completion.Order :=
              { view, index := 0, generation := 2, query := { text := "b", view := ⟨0⟩ }
                pause := 30 }
            cancels == #[key] &&
              starts ==
                #[{ name := "later-pick", arguments := order.arguments, key := some key }] &&
              after.state.prompt.map (·.candidates.asking) ==
                some
                  #[{ asked with
                      askedFor := "b", generation := 2, fresh := false, done := false }] &&
              after.state.completionKeys == #[key] },
    { name :=
        "with no prompt open every key recorded for a prompt's jobs is cancelled, none is kept, and nothing is started or spawned"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let loop : Loop TestScheme.scheme :=
              {
                state :=
                  { state with completionKeys := #["completion 3 later", "completion-match 3"] } }
            let (after, starts, cancels, spawns) := loop.completionJobs (jobKeys)
            cancels == #["completion 3 later", "completion-match 3"] && starts.isEmpty &&
              spawns.isEmpty &&
              after.state.completionKeys.isEmpty },
    { name := "a source whose job is not registered is not started, and stays unasked"
      run :=
        pure <|
          let unregistered : Completion.Asking := { source .never with later := { job := "nope" } }
          match promptLoop { asking := #[unregistered] } (some "a") with
          | none => false
          | some (loop, _) =>
            let (after, starts, _, _) := loop.completionJobs (jobKeys)
            starts.isEmpty && after.state.completionKeys.isEmpty &&
              after.state.prompt.map (·.candidates.asking.map (·.generation)) == some #[0] },
    { name :=
        "a prompt over more candidates than the inline limit, whose listing is not for the typed text, has one match spawned under `completion-match <view>`, labelled `completion-match`, of the owner of its style, and its match in flight for the text, the revision and the config generation; none while one is in flight, none at or under the limit, none for the text and revision a match failed for, and one again for another text"
      run :=
        pure <|
          let candidates : Candidates := { all := offered #["wq", "edit", "rewrite", "w"] }
          match promptLoop candidates (some "w") with
          | none => false
          | some (loop, view) =>
            let keys := jobKeys (generation := 4) (owned := true)
            let (spawned, starts, cancels, spawns) := loop.completionJobs keys
            let (_, _, _, inFlight) := spawned.completionJobs keys
            let (_, _, _, under) := loop.completionJobs (jobKeys (inline := 4))
            let failed :=
              { loop with
                state := withCandidates loop.state { candidates with unmatched := some ("w", 0) } }
            let (_, _, _, unmatched) := failed.completionJobs keys
            let (_, _, _, other) := { failed with typed := some "e" }.completionJobs keys
            let key := Loop.matchKey view
            spawns.map (fun spawn => (spawn.key, spawn.label, spawn.owner)) ==
                #[(key, Loop.matchLabel, Config.Owner.config)] &&
              starts.isEmpty &&
              cancels.isEmpty &&
              spawned.state.prompt.map (·.candidates.matching) ==
                some (some { pattern := "w", revision := 0, generation := 4 }) &&
              spawned.state.completionKeys == #[key] &&
              inFlight.isEmpty &&
              under.isEmpty &&
              unmatched.isEmpty &&
              other.size == 1 &&
              (spawns[0]?.bind (matchedBy spawned ·)).map (·.listed.map (·.text)) ==
                some
                  ((FuzzyModel.rank "w" #["wq", "edit", "rewrite", "w"]).map fun index =>
                    #["wq", "edit", "rewrite", "w"][index]!) },
    { name :=
        "a prompt of filtered candidates alone, more of them than the inline limit, has a match spawned for the typed text, whose delivery lists them in the order given, none dropped, the one the style matches marked; within the limit, none is spawned"
      run :=
        pure <|
          let candidates : Candidates := { passed := offered #["zz", "ab", "w"] }
          match promptLoop candidates (some "w") with
          | none => false
          | some (loop, view) =>
            let (spawned, _, _, spawns) := loop.completionJobs (jobKeys)
            let (_, _, _, under) := loop.completionJobs (jobKeys (inline := 3))
            let listed := (spawns[0]?.bind (matchedBy spawned ·)).map (·.listed)
            spawns.map (·.key) == #[Loop.matchKey view] &&
              listed.map (·.map (·.text)) == some #["zz", "ab", "w"] &&
              listed.map (·.map (·.ranges.isEmpty)) == some #[true, true, false] &&
              under.isEmpty },
    { name :=
        "a prompt over the inline limit whose listing is for the typed text at an older revision than its candidates', a batch having come, has one match spawned for the text at the candidates' revision; at their revision, none"
      run :=
        pure <|
          let candidates : Candidates :=
            { all := offered #["wq", "edit", "rewrite", "w"], listedFor := some "w", revision := 1 }
          match promptLoop candidates (some "w") with
          | none => false
          | some (loop, view) =>
            let (spawned, _, _, spawns) := loop.completionJobs (jobKeys)
            let current :=
              { loop with state := withCandidates loop.state { candidates with listedAt := 1 } }
            let (_, _, _, atRevision) := current.completionJobs (jobKeys)
            spawns.map (·.key) == #[Loop.matchKey view] &&
              spawned.state.prompt.map (·.candidates.matching) ==
                some (some { pattern := "w", revision := 1, generation := 0 }) &&
              atRevision.isEmpty },
    { name :=
        "a match in flight stamped with an older config generation is not in flight: its key is cancelled, and a match is spawned for the typed text, stamped with the keys' generation, running the keys' style"
      run :=
        pure <|
          let candidates : Candidates :=
            { all := offered #["wq", "edit", "rewrite", "w"]
              matching := some { pattern := "w", revision := 0, generation := 1 } }
          match promptLoop candidates (some "w") with
          | none => false
          | some (loop, view) =>
            let key := Loop.matchKey view
            let keys := jobKeys (generation := 2) (style := containing)
            let (after, _, cancels, spawns) :=
              { loop with state := { loop.state with completionKeys := #[key] } }.completionJobs
                keys
            cancels == #[key] && spawns.map (·.key) == #[key] &&
              after.state.prompt.map (·.candidates.matching) ==
                some (some { pattern := "w", revision := 0, generation := 2 }) &&
              (spawns[0]?.bind (matchedBy after ·)).map (·.listed.map (·.text)) ==
                some #["wq", "rewrite", "w"] },
    { name :=
        "a listing of 15 drawn by the core's own display shows every row, in the listing's order, the chosen one marked, and one of 4 shows 4; the minibuffer's status line is the label alone"
      run :=
        pure <|
          let texts := (Array.range 15).map (s!"c{·}")
          let prompt (count : Nat) : Prompt :=
            { label := "L: ", view := ⟨1⟩, asker := ⟨0⟩, continuation := asked
              candidates :=
                { listed := ((offered texts).extract 0 count).map Completion.Listed.of
                  chosen := some 2 } }
          let sheet (count : Nat) : Completion.Sheet :=
            let candidates := (prompt count).candidates
            (Completion.Displaying.unregistered.displayFor none).sheet
              { listed := candidates.listed, chosen := candidates.chosen }
          let rows := (sheet 15).rows
          rows.map (·.text) ==
              texts.mapIdx (fun index text => (if index == 2 then "> " else "  ") ++ text) &&
            (sheet 4).rows.size == 4 &&
            (Loop.promptStatus (prompt 15)).map (·.text) == #["L: "] }]

/-- The step a fed key handed back last, if it was not refused. -/
def lastStep (steps : Array (Option (Loop.Stepped TestScheme.scheme))) :
    Option (Loop.Stepped TestScheme.scheme) :=
  steps.back?.join

/-- The text of the candidate chosen in the prompt open in `driver`. -/
def chosenText (driver : TestDriver) : Option String := do
  let candidates ← candidatesOf driver
  let index ← candidates.chosen
  return (← candidates.listed[index]?).text

/-- The checks of a source asked again when the directory part of the text
changes (`Reask.beforeLast`), of what is listed while its answer is another
directory's or hidden (`Candidates.answering`), and of a source's job that
fails (`StateRequest.sourceFailed`). -/
def directoryChecks : List Check :=
  let dirSource (answeredFor : Option String) (answered : Array Completion.Candidate) :
    Completion.Asking :=
    { source := "dir", later := { job := "later-pick", reask := .beforeLast '/' },
      askedFor := "src/"
      generation := 1, answered, answeredFor, fresh := true, done := true }
  let hidden (text : String) : Completion.Candidate := { text, hiddenUntil := some "." }
  [{  name :=
        "a source asked again by its directory part: a text typed within the same directory starts nothing, and one that adds a / cancels its key and starts the next generation for the typed text with no pause"
      run :=
        pure <|
          let asked := dirSource (some "src/") (offered #["src/x"])
          let within :=
            match promptLoop { asking := #[asked] } (some "src/ma") with
            | none => false
            | some (loop, view) =>
              let key := Loop.sourceKey view "dir"
              let (_, starts, cancels, _) :=
                { loop with state := { loop.state with completionKeys := #[key] } }.completionJobs
                  (jobKeys)
              starts.isEmpty && cancels.isEmpty
          let into :=
            match promptLoop { asking := #[asked] } (some "src/main/") with
            | none => false
            | some (loop, view) =>
              let key := Loop.sourceKey view "dir"
              let (_, starts, cancels, _) :=
                { loop with state := { loop.state with completionKeys := #[key] } }.completionJobs
                  (jobKeys)
              cancels == #[key] &&
                (starts.map fun start =>
                    (Completion.Order.ofArguments? start.arguments).map fun order =>
                      (order.generation, order.query.text, order.pause)) ==
                  #[some (2, "src/main/", 0)]
          within && into },
    { name :=
        "the candidates as they answer a text leave a source that is asked again after a pause, or never, as it is, and empty a source asked again by directory whose answer is another directory's"
      run :=
        pure <|
          let pausing : Completion.Asking :=
            { source := "p", later := { job := "j", reask := .afterPause 30 }, askedFor := "a"
              answeredFor := some "a", answered := offered #["a1"] }
          let never : Completion.Asking :=
            { source := "n", later := { job := "j" }, askedFor := "", answeredFor := some ""
              answered := offered #["n1"] }
          let candidates : Candidates :=
            { asking := #[pausing, never, dirSource (some "src/") (offered #["src/x"])] }
          let answered (typed : String) := (candidates.answering typed).asking.map (·.answered)
          answered "src/m" == #[offered #["a1"], offered #["n1"], offered #["src/x"]] &&
            answered "src/main/" == #[offered #["a1"], offered #["n1"], #[]] &&
            answered "lib/" == #[offered #["a1"], offered #["n1"], #[]] &&
            (candidates.current "lib/").matchableSize == 2 },
    { name :=
        "hidden candidates are listed only while the text after the source's separator starts with what reveals them, in their order, from the same answer; a given source with no separator reads the whole text; the size a listing is chosen by counts them all"
      run :=
        pure <|
          let answered := #[.ofText "src/x", hidden "src/.env", hidden "src/.cache/"]
          let candidates : Candidates :=
            { all := #[hidden ".a", .ofText "b"], asking := #[dirSource (some "src/") answered] }
          let listed (typed : String) :=
            ((candidates.answering typed).asking.map (·.answered.map (·.text))).flatten
          let given (typed : String) := (candidates.answering typed).all.map (·.text)
          listed "src/" == #["src/x"] && listed "src/e" == #["src/x"] &&
            listed "src/." == #["src/x", "src/.env", "src/.cache/"] &&
            listed "src/.e" == #["src/x", "src/.env", "src/.cache/"] &&
            given "." == #[".a", "b"] &&
            given "a" == #["b"] &&
            ["src/", "src/e", "src/.", "src/.e"].all fun typed =>
              (candidates.current typed).matchableSize == 5 },
    { name :=
        "a source's batch records the text its generation was asked for on its first batch; a job's failure for the open prompt's source at its generation clears it, marks it done, records the text and says <source>: <message>; for another generation or view it changes nothing and says nothing"
      run :=
        pure <|
          let asking : Completion.Asking :=
            { source := "dir", later := { job := "j", reask := .beforeLast '/' }, askedFor := "src/"
              generation := 2, answered := offered #["old/x"], answeredFor := some "old/" }
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            match prompted state with
            | (.ok view, opened) =>
              let (_, set) := opened.setCandidates { asking := #[asking] }
              let (taken, added) := set.addCandidates view 0 2 (offered #["src/a"])
              let failed := set.sourceFailed view 0 2 "cannot list src/"
              let stale := set.sourceFailed view 0 1 "old"
              let elsewhere := set.sourceFailed ⟨9⟩ 0 2 "other"
              let source (state : EditorState) := state.prompt.bind (·.candidates.asking[0]?)
              taken && (source added).map (·.answeredFor) == some (some "src/") &&
                (source failed).map
                    (fun source => (source.answered, source.done, source.answeredFor)) ==
                  some (#[], true, some "src/") &&
                failed.echo == "dir: cannot list src/" &&
                stale == set &&
                elsewhere == set
            | _ => false },
    { name :=
        "a source's job that throws finishes with the command that says its source failed, and posts nothing; a malformed order still fails the job"
      run :=
        pure <|
          let (outcome, model) :=
            (Completion.Later.refusing "no" laterOrder.arguments ()).runModel {}
          let (bad, _) := (Completion.Later.refusing "no" [] ()).runModel {}
          let failedCommand :=
            match outcome with
            | .finished command =>
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let program : EditorM (Guarded Unit × EditorState) := command.dispatched {} state
                match (program.runModel editorModel).1 with
                | .ok (_, after) => after.echo == state.echo
                | .error _ => false
            | _ => false
          failedCommand && model.posted.isEmpty && (bad matches .failed _) },
    { name :=
        "through the loop: after a source asked again by directory has answered, typing a / publishes a scene that lists nothing of the old directory before the next batch arrives, and the new directory's entries after it; a job that throws says why in the echo area and lists nothing"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c d")
            match asked.posting[0]? with
            | none => false
            | some first =>
              let (one, _) := asked.posted first.id
              let (done, _) := one.finish first.id
              let (typed, _) := fedTo done (presses "a /")
              let listedTexts (driver : TestDriver) :=
                (candidatesOf driver).map (·.listed.map (·.text))
              let afterBatch :=
                match typed.posting[0]? with
                | none => none
                | some second => listedTexts (typed.posted second.id).1
              let (refused, _) := fedTo driver (presses "C-c x")
              let failed :=
                match refused.pending[0]? with
                | none => refused
                | some job => (refused.finish job.id).1
              listedTexts one == some #["x", "y"] && listedTexts typed == some #[] &&
                afterBatch == some #["a/x", "a/y"] &&
                failed.loop.state.echo == "dir: no" &&
                listedTexts failed == some #[] }]

/-- The checks of sources that answer later and of matching off the editor
thread through the loop (`Editor/Loop.lean`, "Prompts"), on the loop's
driver over the editor's models and the job model, with the candidate
checks' commands: the phase's four criteria on the models, a match that
fails, and what a key costs while a match runs. -/
def laterLoopChecks : List Check :=
  let label : Array StatusField := #[{ text := pickLabel, face := Loop.promptFace }]
  [{  name :=
        "criterion 1 on the models: a prompt asked with a source that answers later lists nothing while its job is held at its first post, then the first batch, then everything once the second arrives, each in the fuzzy model's order for the text, and after a key the order for the typed text; a choice made before the second batch stays on its candidate"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c l")
            match asked.posting[0]? with
            | none => false
            | some job =>
              let (one, _) := asked.posted job.id
              let chosen := chose one [.next, .next]
              let (two, _) := chosen.posted job.id
              let (typed, _) := fedTo two (presses "w")
              job.name == "later-pick" && pickShown asked == some label &&
                pickShown one == some (laterFields "" #["wq", "edit"]) &&
                chosenText chosen == some "edit" &&
                (candidatesOf two).map (·.listed.map (·.text)) ==
                  some (((laterFields "" pickCandidates).extract 1).map (·.text)) &&
                chosenText two == some "edit" &&
                pickShown typed == some (laterFields "w" pickCandidates) },
    { name :=
        "criterion 2 on the models: in a prompt whose source depends on the text, a key hands back a cancel of the source's key and a start of its job for the typed text, at the next generation, after its pause; the first job is held no more, what it answered stays listed until the new job's batch, which lists the answer for the typed text"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c t")
            match asked.posting[0]?, asked.loop.state.minibufferView? with
            | some first, some view =>
              let (echoed, _) := asked.posted first.id
              let (typed, steps) := fedTo echoed (presses "w")
              match typed.posting[0]? with
              | none => false
              | some second =>
                let (answered, _) := typed.posted second.id
                let stepped := lastStep steps
                let order :=
                  (stepped.bind (·.starts[0]?)).bind fun start =>
                    Completion.Order.ofArguments? start.arguments
                (candidatesOf echoed).map (·.listed.map (·.text)) == some #["!"] &&
                  stepped.map (·.cancels) == some #[Loop.sourceKey view "echo"] &&
                  stepped.map (·.starts.map (·.name)) == some #["later-echo"] &&
                  order.map (fun order => (order.query.text, order.generation, order.pause)) ==
                    some ("w", 2, 30) &&
                  !(heldJobs typed).any (·.1 == first.id) &&
                  (candidatesOf typed).map (·.listed.map (·.text)) == some #["!"] &&
                  (candidatesOf answered).map (·.listed.map (·.text)) == some #["w!"]
            | _, _ => false },
    { name :=
        "criterion 3 on the models: accepting or cancelling a prompt whose source's job is held hands back a cancel of the key it was started under; the driver then holds no job of it, its post never runs, and no key is kept for the prompt"
      run :=
        pure <|
          match candidateDriver with
          | none => false
          | some driver =>
            let closes (asks source closing : String) : Bool :=
              let (asked, _) := fedTo driver (presses asks)
              match asked.loop.state.minibufferView?, asked.posting[0]? with
              | some view, some job =>
                let (closed, steps) := fedTo asked (presses closing)
                (lastStep steps).map (·.cancels.contains (Loop.sourceKey view source)) ==
                    some true &&
                  heldJobs closed == #[] &&
                  (closed.posted job.id).2.isNone &&
                  closed.loop.state.prompt.isNone &&
                  closed.loop.state.completionKeys.isEmpty
              | _, _ => false
            closes "C-c l" "later" "C-c y" && closes "C-c l" "later" "C-c n" &&
              closes "C-c t" "echo" "C-c y" &&
              closes "C-c t" "echo" "C-c n" },
    { name :=
        "criterion 4 on the models: over the inline limit the step that opens the prompt spawns one match and lists nothing until it is delivered, which lists the fuzzy model's order; a key then costs its step the read of the minibuffer and no ranking, and hands back one match for the typed text, the listing staying the old text's; keys typed while it runs spawn nothing; its delivery lists the hits for the text it was spawned with, and its scene spawns one match for the latest text"
      run :=
        pure <|
          match smallLimitDriver, smallLimitDriver countingModel, candidateDriver countingModel with
          | some driver, some counting, some plain =>
            -- How many requests the last of `keys` took.
            let cost (driver : TestDriver) (keys : String) : Nat :=
              let events := presses keys
              let (before, _) := fedTo driver events.dropLast
              let (after, _) := fedTo before (events.drop (events.length - 1))
              after.model.watch.clock - before.model.watch.clock
            let (asked, askSteps) := fedTo driver (presses "C-c a")
            match asked.pending[0]? with
            | none => false
            | some first =>
              let (listed, _) := asked.finish first.id
              let (typed, typeSteps) := fedTo listed (presses "w")
              match typed.pending[0]? with
              | none => false
              | some second =>
                let (more, moreSteps) := fedTo typed (presses "q z")
                let (delivered, deliveredStep) := more.finish second.id
                (lastStep askSteps).map (·.spawns.size) == some 1 &&
                  first.name == Loop.matchLabel &&
                  pickShown asked == some label &&
                  (candidatesOf listed).map (·.listed) == some (pickListed "").listed &&
                  (lastStep typeSteps).map (·.spawns.size) == some 1 &&
                  (candidatesOf typed).map (·.listedFor) == some (some "") &&
                  moreSteps.all (fun step => step.map (·.spawns.size) == some 0) &&
                  minibufferText more == some "wqz" &&
                  (candidatesOf delivered).map (·.listedFor) == some (some "w") &&
                  (candidatesOf delivered).map (·.listed) == some (pickListed "w").listed &&
                  deliveredStep.map (·.spawns.size) == some 1 &&
                  cost counting "C-c a w" == cost plain "C-c p w" + 1
          | _, _, _ => false },
    { name :=
        "over the inline limit, a source's batch with the text unchanged spawns a match, whose delivery lists the batch; a batch that lands while a match runs spawns none, and the delivery of the match for the older revision spawns one more, whose delivery lists every batch at the candidates' revision"
      run :=
        pure <|
          match smallLimitDriver (inline := 1) with
          | none => false
          | some driver =>
            let matchOf (driver : TestDriver) : Option Nat :=
              (driver.pending.find? (·.name == Loop.matchLabel)).map (·.id)
            let texts (driver : TestDriver) : Option (Array String) :=
              (candidatesOf driver).map (·.listed.map (·.text))
            let current (driver : TestDriver) : Bool :=
              (candidatesOf driver).any fun candidates => candidates.listedAt == candidates.revision
            let first := ((laterFields "" #["wq", "edit"]).extract 1).map (·.text)
            let every := ((laterFields "" pickCandidates).extract 1).map (·.text)
            let (asked, _) := fedTo driver (presses "C-c l")
            match asked.posting[0]? with
            | none => false
            | some job =>
              let (one, oneStep) := asked.posted job.id
              match matchOf one with
              | none => false
              | some firstMatch =>
                -- The match delivers before the second batch.
                let (listed, _) := one.finish firstMatch
                let (two, twoStep) := listed.posted job.id
                let (all, _) :=
                  match matchOf two with
                  | some id => two.finish id
                  | none => (two, none)
                -- The second batch lands while the match runs.
                let (both, bothStep) := one.posted job.id
                let (stale, staleStep) := both.finish firstMatch
                let (caught, caughtStep) :=
                  match matchOf stale with
                  | some id => stale.finish id
                  | none => (stale, none)
                minibufferText one == some "" && oneStep.map (·.spawns.size) == some 1 &&
                  texts listed == some first &&
                  current listed &&
                  twoStep.map (·.spawns.size) == some 1 &&
                  texts all == some every &&
                  current all &&
                  bothStep.map (·.spawns.size) == some 0 &&
                  texts stale == some first &&
                  !current stale &&
                  staleStep.map (·.spawns.size) == some 1 &&
                  texts caught == some every &&
                  current caught &&
                  caughtStep.map (·.spawns.size) == some 0 },
    { name :=
        "over the inline limit, a key undone while the match for it runs leaves the listing it had, current again: the undoing step cancels that match and spawns none, the driver holds no job, a choice made then stays through the match's delivery, even one that raced the cancel, and that delivery spawns nothing"
      run :=
        pure <|
          match smallLimitDriver with
          | none => false
          | some driver =>
            let (asked, _) := fedTo driver (presses "C-c a")
            match asked.pending[0]? with
            | none => false
            | some first =>
              let (opened, _) := asked.finish first.id
              let (typed, _) := fedTo opened (presses "w")
              match typed.pending[0]? with
              | none => false
              | some second =>
                let (listed, _) := typed.finish second.id
                let (more, _) := fedTo listed (presses "q")
                match more.pending[0]?, more.loop.state.minibufferView? with
                | some third, some view =>
                  let (undone, undoSteps) := fedTo more (presses "C-c b")
                  let chosen := chose undone [.next]
                  let (delivered, deliveredStep) := chosen.finish third.id
                  -- A delivery that was already on its way when the cancel
                  -- came.
                  let raced :=
                    match third.outcome with
                    | .finished command =>
                      some
                        (chosen.stepped
                          (chosen.loop.deliver chosen.handed s!"job {third.id} {third.name}"
                            command))
                    | _ => none
                  let kept (driver : TestDriver) : Bool :=
                    (candidatesOf driver).map (·.listedFor) == some (some "w") &&
                      (candidatesOf driver).map (·.listed) == some (pickListed "w").listed &&
                      chosenText driver == chosenText chosen
                  minibufferText more == some "wq" &&
                    (candidatesOf more).map (·.listedFor) == some (some "w") &&
                    minibufferText undone == some "w" &&
                    (lastStep undoSteps).map (·.spawns.size) == some 0 &&
                    (lastStep undoSteps).map (·.cancels.contains (Loop.matchKey view)) ==
                      some true &&
                    heldJobs undone == #[] &&
                    (chosenText chosen).isSome &&
                    kept delivered &&
                    deliveredStep.all (·.spawns.isEmpty) &&
                    raced.any
                      (fun (racedDriver, racedStep) =>
                        kept racedDriver && racedStep.toOption.any (·.spawns.isEmpty))
                | _, _ => false },
    { name :=
        "a match that fails does not freeze the listing: its delivery says `completion-match: fuzzy: ` and why in the echo area, the listing stays empty and its scene spawns nothing; a key typed once the matcher answers again spawns a new match, whose delivery lists the fuzzy model's order for the typed text"
      run :=
        pure <|
          match smallLimitDriver with
          | none => false
          | some driver =>
            let broken := { driver with jobs := { driver.jobs with fuzzyRefusal := some "broken" } }
            let (asked, _) := fedTo broken (presses "C-c a")
            match asked.pending[0]? with
            | none => false
            | some first =>
              let (failed, failedStep) := asked.finish first.id
              let mended := { failed with jobs := { failed.jobs with fuzzyRefusal := none } }
              let (typed, steps) := fedTo mended (presses "w")
              match typed.pending[0]? with
              | none => false
              | some second =>
                let (listed, _) := typed.finish second.id
                failed.model.display.scenes.back?.map (·.echo) ==
                    some "completion-match: fuzzy: broken" &&
                  (candidatesOf failed).map (·.listed.size) == some 0 &&
                  failedStep.map (·.spawns.size) == some 0 &&
                  (lastStep steps).map (·.spawns.size) == some 1 &&
                  (candidatesOf listed).map (·.listed) == some (pickListed "w").listed }]

/-- Stand-in works under the core's names of the file jobs (`FileJobs`), for
`jobs` of them: each finishes with nothing, and none is run here. They
stand in for the files feature, which registers the real ones, so the
checks below are of when the loop starts the jobs, not what they do. -/
def standInFileJobs (jobs : List String := [FileJobs.checkJob, FileJobs.followJob])
    (name : String) : Option (List Argument → Work) :=
  if jobs.contains name then some fun _ _ => pure (pure ()) else none

/-- The initial state at 640 by 480 with a file buffer, `note.txt`, the
buffer 1, holding `notePath` at `noteStamp`, shown by no view, and
auto-reload's choice `autoReload`. -/
def fileBufferState (autoReload : Option Bool := none) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let text ← createText "note\n"
  let history ← UndoTree.over text
  let (.ok id, state) := state.addBuffer "note.txt" text history | return state
  return { (state.attachFile id notePath noteStamp .lf).2 with autoReload }

/-- The loop's driver over `fileBufferState autoReload`, with no keys and the
stand-in works of `jobs`. -/
def fileJobDriver (jobs : List String := [FileJobs.checkJob, FileJobs.followJob])
    (autoReload : Option Bool := none) : Option TestDriver :=
  (Loop.Driver.over (dispatchKeys []) (standInFileJobs jobs) (fileBufferState autoReload)
      editorModel).toOption

/-- The jobs `events` start on `driver`, every step's, in order. -/
def startsOn (driver : TestDriver) (events : List Event) : Array JobStart :=
  (fedTo driver events).2.flatMap fun step => (step.map (·.starts)).getD #[]

/-- The checks of when the loop starts the file jobs (`Loop.fileJobs`,
`Editor/Loop.lean`, "Files that changed on disk" and "Auto-reload"), under
the core's names (`Editor/FileJobs.lean`), on the loop's driver with
stand-in works and no files feature. -/
def loopFileJobChecks : List Check :=
  [{  name :=
        "where `check-files` is registered, the frame gaining the keyboard focus starts one check of every file buffer, with the core's order of the buffer, its path and its stamp; with no such job registered it starts none"
      run :=
        pure <|
          let focus := [Event.focus false, .focus true]
          match fileJobDriver, fileJobDriver (jobs := [FileJobs.followJob]) with
          | some driver, some unchecked =>
            let checks := (startsOn driver focus).filter (·.name == FileJobs.checkJob)
            checks.map (·.arguments) ==
                #[FileJobs.checkArguments
                    #[{ buffer := ⟨1⟩, path := notePath, stamp := noteStamp }]] &&
              (startsOn unchecked focus).isEmpty
          | _, _ => false },
    { name :=
        "with auto-reload on and `follow-file` registered, each open file buffer gets one follow keyed by the buffer, with the core's order, its own stamp expected; with it off, or the job not registered, none"
      run :=
        pure <|
          let step := [Event.focus true]
          let order : FileJobs.FollowOrder :=
            { buffer := ⟨1⟩, path := notePath, stamp := noteStamp, expected := some noteStamp }
          match fileJobDriver (autoReload := some true), fileJobDriver (autoReload := some false),
            fileJobDriver (jobs := [FileJobs.checkJob]) (autoReload := some true) with
          | some on, some off, some unregistered =>
            (startsOn on step).filter (·.name == FileJobs.followJob) ==
                #[{ name := FileJobs.followJob, arguments := order.arguments
                    key := some (Following.keyOf ⟨1⟩) }] &&
              ((startsOn off step).filter (·.name == FileJobs.followJob)).isEmpty &&
              ((startsOn unregistered step).filter (·.name == FileJobs.followJob)).isEmpty
          | _, _, _ => false }]

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

/-- What the commands `ask-all` and `ask-all-then-fail` of the quit checks
ask for: a cancel of the key `k`, `other` to be run after the command, a
reload of config and the theme `second`. -/
def askAll (_ : Call) : EditorM Unit := do
  cancelJob "k"
  Editor.invoke { command := "other" }
  reloadConfig
  discard <| loadTheme "second"

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
refused. Two ask for all of it at once, a cancel of the key `k`, `other` to
be run after it, a reload and the theme `second`: `ask-all` (`a`), and
`ask-all-then-fail` (`b`), which asks and is then refused. -/
def quitKeys : Loop.Keys TestScheme.scheme :=
  {
    dispatchKeys
      [("C-o n", opens (inFiles "note.txt")), ("C-o w", invoke Files.saveName),
        ("C-l l", invoke "leave"), ("C-l f", invoke "leave-then-fail"), ("C-l s", invoke "stamp"),
        ("C-l o", invoke "other"), ("C-l h", invoke "hand-leave"),
        ("C-l t", invoke "hand-leave-other"), ("C-l r", invoke "again"),
        ("C-l g", invoke "again-then-fail"), ("C-l p", invoke "pick"),
        ("C-l k", invoke "pick-then-fail"), ("C-l a", invoke "ask-all"),
        ("C-l b", invoke "ask-all-then-fail")]
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
        ("pick-then-fail", failingAfter fun _ => discard <| loadTheme "second"),
        ("ask-all", fun call => do
          askAll call
          return none),
        ("ask-all-then-fail", failingAfter askAll)] with
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
            asked steps == #[some false, some true] && !once.loop.state.outbox.reload &&
              once.reloads == 1 &&
              asked went == #[some false, some false] &&
              asked lost == #[some false, some false] &&
              !failed.loop.state.outbox.reload &&
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
            asked steps == #[some none, some (some "second")] &&
              once.loop.state.outbox.theme == none &&
              once.themes == #["second"] &&
              asked went == #[some none, some none] &&
              asked lost == #[some none, some none] &&
              failed.loop.state.outbox.theme == none &&
              failed.themes == #["second"] &&
              driver.themes == #[] },
    { name :=
        "a step whose command asked for a cancel, an invocation, a reload and a theme at once hands each back, and the state after it has an empty outbox; one whose command asked them all and was then refused hands back none, and its state's outbox is empty too"
      run :=
        pure <|
          match quitDriver with
          | none => false
          | some driver =>
            let (once, steps) := fedTo driver (presses "C-l a")
            let (failed, lost) := fedTo driver (presses "C-l b")
            let refused := lost.filterMap id
            steps.size == 2 &&
              (steps[1]?.join.any fun step =>
                step.reload && step.theme == some "second" && step.cancels.contains "k" &&
                  step.answered == #[{ command := "other" }]) &&
              once.loop.state.outbox == {} &&
              once.reloads == 1 &&
              once.themes == #["second"] &&
              refused.size == 2 &&
              refused.all
                (fun step =>
                  !step.reload && step.theme == none && !step.cancels.contains "k" &&
                    step.answered.isEmpty) &&
              failed.loop.state.outbox == {} &&
              failed.reloads == 0 &&
              failed.themes == #[] }]

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
          let handed := evilHanded Test.Minibuffer.package.registered.commands [("ask", ask)]
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

/-- The checks of what a repeat replays after completion at point
(`EditorState.retyped`, `Loop.ranInto`): what a command typed in place of
typed text reaches the last change's recording, only when the command ran to
its end; and `.` after an insert that accepted a preview inserts what that
insert left. -/
def atPointRepeatChecks : List Check :=
  let retyping : Config.Registration :=
    { name := "retyping", action := .call fun call => retype call.target.window.id "zz" }
  let refusing : Config.Registration :=
    { name := "refusing"
      action :=
        .call fun call => do
          retype call.target.window.id "yy"
          throw .badRange }
  [{  name :=
        "what a command says it typed reaches the insert session's recording once it has run to its end, and a command that is refused tells the scheme nothing"
      run :=
        pure <|
          match evilDriver "ab|c" (evilHanded #[retyping, refusing]) with
          | none => false
          | some driver =>
            let inserting := evilFed driver "i x"
            let told :=
              (inserting.stepped
                  (inserting.loop.invoke inserting.handed { command := "retyping" })).1
            let refused := (told.stepped (told.loop.invoke told.handed { command := "refusing" })).1
            told.loop.input.inserted == some "xzz" && told.loop.atRest.inserted == some "xzz" &&
              refused.loop.input.inserted == some "xzz" &&
              told.loop.state.retyped.isEmpty },
    { name :=
        "after a C-n C-n RET <Escape>, a move and . insert at the new bar what the insert left, the previewed text included"
      run :=
        pure <|
          match atPointDriver "say he\nsay h|e" #["line"] [lineAtPoint] with
          | none => false
          | some driver =>
            let done := evilFed driver "a C-n C-n RET <Escape>"
            let repeated := evilFed done "k ."
            evilText done == some "say he\nsay hello" &&
              evilText repeated == some "say hello\nsay hello" }]

/-- The checks of completion at point through the loop (`Editor/Loop.lean`,
"Completion at point"), on the evil driver over the models. -/
def atPointLoopChecks : List Check :=
  [{  name := "a session at point is asked with the place of its view, which its candidates keep"
      run :=
        pure <|
          match atPointDriver "say h|e" #["line"] [lineAtPoint] with
          | none => false
          | some driver =>
            let opened := evilFed driver "a C-n"
            match opened.loop.state.atPoint with
            | none => false
            | some session =>
              session.candidates.place == opened.loop.state.placeOf session.view &&
                session.candidates.place.directory == some "/" },
    { name :=
        "a previewed candidate accepted with RET is what the region the source named now holds, and one undo restores the text from before the first preview"
      run :=
        pure <|
          match atPointDriver "say h|e" #["line"] [lineAtPoint] with
          | none => false
          | some driver =>
            let opened := evilFed driver "a C-n"
            let previewed := evilFed opened "C-n"
            let accepted := evilFed previewed "RET"
            let undone := evilUndone (evilFed accepted "<Escape>")
            let typedOn := evilFed driver "a C-n C-n x <Escape>"
            opened.loop.state.atPoint.isSome && sessionChosen opened == none &&
              evilText opened == some "say he" &&
              sessionRows opened == #["say hello"] &&
              evilText previewed == some "say hello" &&
              sessionChosen previewed == some 0 &&
              evilText accepted == some "say hello" &&
              accepted.loop.state.atPoint.isNone &&
              evilText undone == some "say he" &&
              evilText typedOn == some "say hellox" },
    { name :=
        "moving the cursor out of the region closes the session and gives the windows back their rows; moving inside it keeps it; <Escape> closes it with the preview left, and so does typing on to a text nothing matches"
      run :=
        pure <|
          match atPointDriver "alpha a|l" #["last2"] [lastTwoAtPoint] with
          | none => false
          | some driver =>
            let opened := evilFed driver "a C-n"
            let inside := evilFed opened "<ArrowLeft> <ArrowLeft>"
            let outside := evilFed inside "<ArrowLeft>"
            let escaped := evilFed opened "C-n <Escape>"
            let unmatched := evilFed opened "z"
            let heights := outside.loop.state.heights
            match opened.loop.state.atPoint with
            | none => false
            | some session =>
              listShown opened && inside.loop.state.atPoint.isSome && listShown inside &&
                outside.loop.state.atPoint.isNone &&
                !listShown outside &&
                outside.loop.state.minibufferPlace == heights.message &&
                (outside.loop.state.rects.find? (·.1 == ⟨0⟩)).map (·.2.height) ==
                  some (480 - heights.message) &&
                opened.loop.state.minibufferPlace == 2 * heights.text + heights.message &&
                markerGone outside session.start &&
                markerGone outside session.stop &&
                escaped.loop.state.atPoint.isNone &&
                evilText escaped == some "alpha alpha" &&
                markerGone escaped session.start &&
                unmatched.loop.state.atPoint.isNone &&
                evilText unmatched == some "alpha alz" &&
                markerGone unmatched session.stop },
    { name :=
        "with a session open, C-n/TAB and C-p/S-TAB move the choice down and up, previewing it in the region, and RET accepts only a chosen candidate"
      run :=
        pure <|
          let threes : Completion.AtPoint :=
            { lineAtPoint [.source "threes"] with name := "threes" }
          match atPointDriver "|a" #["threes"] [threes] with
          | none => false
          | some driver =>
            let opened := evilFed driver "a C-SPC"
            let one := evilFed opened "C-n"
            let two := evilFed one "TAB"
            let back := evilFed two "C-p"
            let none' := evilFed back "S-TAB"
            let wrapped := evilFed none' "S-TAB"
            let accepted := evilFed wrapped "RET"
            let broken := evilFed driver "a C-n RET"
            sessionChosen opened == none && evilText opened == some "a" &&
              evilText one == some "a1" &&
              evilText two == some "a2" &&
              evilText back == some "a1" &&
              evilText none' == some "a" &&
              sessionChosen none' == none &&
              evilText wrapped == some "a3" &&
              evilText accepted == some "a3" &&
              accepted.loop.state.atPoint.isNone &&
              broken.loop.state.atPoint.isNone &&
              evilText broken == some "a\n" },
    { name :=
        "a previewed session closed because its text stopped matching closes its buffer's group: what is typed after it is a step of its own, and one more undo restores the text from before the preview"
      run :=
        pure <|
          match atPointDriver "say h|e" #["line"] [lineAtPoint] with
          | none => false
          | some driver =>
            let typed := evilFed driver "a C-n C-n x"
            let after := evilFed typed "y <Escape>"
            let once := evilUndone after
            let twice := evilUndone once
            typed.loop.state.atPoint.isNone && evilText after == some "say helloxy" &&
              evilText once == some "say hellox" &&
              evilText twice == some "say he" },
    { name :=
        "a session over more candidates than are matched inline has its listing matched by a job under completion-match <view>, and closing the session cancels it"
      run :=
        pure <|
          let threes : Completion.AtPoint :=
            { lineAtPoint [.source "threes"] with name := "threes" }
          match atPointDriver "|a" #["threes"] [threes] with
          | none => false
          | some driver =>
            let driver := { driver with keys := { driver.keys with inlineMatches := 1 } }
            let (opened, steps) := evilSteps driver "a C-SPC"
            let (_, quitSteps) := evilSteps opened "C-g"
            let spawned : Array String := steps.flatMap (·.spawns.map (·.key))
            let cancelled : Array String := quitSteps.flatMap (·.cancels)
            spawned == #[Loop.matchKey ⟨0⟩] && cancelled.contains (Loop.matchKey ⟨0⟩) },
    { name :=
        "C-n with a source that answers later and reads the open buffers' texts starts its job under completion 0 later, with an order whose texts are snapshots of the open buffers; its batches list the candidates that match, and closing the session cancels the key and releases the snapshots"
      run :=
        pure <|
          match atPointDriver "alpha alpine al|p" #["later"] [] with
          | none => false
          | some driver =>
            let (asked, steps) := evilSteps driver "a C-n"
            let started : Array JobStart := steps.flatMap (·.starts)
            let order :=
              (started.find? (·.name == laterJob)).bind fun start =>
                Completion.Order.ofArguments? start.arguments
            let listed := evilDrained asked
            let closed := evilFed listed "<Escape>"
            let texts := (order.map (·.query.texts)).getD #[]
            let contents (driver : EvilDriver) (id : SnapshotId) : Option String :=
              (driver.model.texts.snapshots[id.index]?).join.map (·.contents)
            (started.find? (·.name == laterJob)).bind (·.key) ==
                some (Loop.sourceKey ⟨0⟩ "later") &&
              texts.toList.map (contents asked) == [some "alpha alpine alp"] &&
              (order.bind (·.query.region)) == some { start := 13, stop := 16 } &&
              sessionRows listed == #["alpha", "alpine"] &&
              closed.loop.state.atPoint.isNone &&
              texts.all (contents closed · |>.isNone) &&
              !closed.loop.state.completionKeys.contains (Loop.sourceKey ⟨0⟩ "later") },
    { name :=
        "C-n on a word no batch of a source that answers later holds opens a session of it, and when its job lists nothing that matches the session closes and the echo area says no completions"
      run :=
        pure <|
          match atPointDriver "xyz |" #["later"] [] with
          | none => false
          | some driver =>
            let asked := evilFed driver "a q w C-n"
            let drained := evilDrained asked
            asked.loop.state.atPoint.map (·.source) == some "later" &&
              drained.loop.state.atPoint.isNone &&
              drained.loop.state.echo == Completion.AtPoint.noCompletions }]

/-- The checks of what a key asks of completion at point (`Loop.atPointAsks`),
pure: a trigger's command, the pause armed, kept or withdrawn. -/
def atPointAskChecks : List Check :=
  let paused : Completion.AtPoint := { Completion.AtPoint.silent "paused" with pause := some 100 }
  let atPoints := [dotsAtPoint, paused, laterAtPoint]
  [{  name :=
        "completion at point through an implementation written here: the kit's at-point package and an at-point source over the job model's later source, neither shipped, open a session on a trigger, list what the job answered, preview the chosen one in the region and accept it"
      run :=
        pure <|
          match atPointDriver "|" #["dotted"] [{ laterAtPoint ['.'] with name := "dotted" }] with
          | none => false
          | some driver =>
            let typed := evilFed driver "i a x"
            let dotted := evilDrained (evilFed typed ".")
            let previewed := evilFed dotted "C-n"
            let accepted := evilFed previewed "RET"
            typed.loop.state.atPoint.isNone &&
              dotted.loop.state.atPoint.map (·.source) == some "dotted" &&
              sessionChosen dotted == none &&
              sessionRows dotted == #["alpha", "beta", "alpine"] &&
              evilText previewed == some "ax.alpha" &&
              sessionChosen previewed == some 0 &&
              evilText accepted == some "ax.alpha" &&
              accepted.loop.state.atPoint.isNone },
    { name :=
        "a typed . with a trigger source hands back at-point-triggered with it, and a typed a none; a typed key with pause sources arms each distinct pause, and a chain with no pause keeps what is armed"
      run :=
        pure <|
          match atPointDriver "|" #["dots", "paused", "later"] atPoints,
            atPointDriver "|" #["dots"] atPoints with
          | some driver, some noPause =>
            let loop := driver.loop
            let triggered := loop.atPointAsks driver.handed (some (⟨0⟩, some "x."))
            let plain := loop.atPointAsks driver.handed (some (⟨0⟩, some "a"))
            triggered ==
                (#[{ command := Completion.AtPoint.triggeredCommand, arguments := [.str "."] }],
                  .arm ⟨0⟩ #[100, 240]) &&
              plain == (#[], .arm ⟨0⟩ #[100, 240]) &&
              noPause.loop.atPointAsks noPause.handed (some (⟨0⟩, some "a")) == (#[], .keep) &&
              (atPointDriver "|" #["paused", "paused"] atPoints).any fun once =>
                once.loop.atPointAsks once.handed (some (⟨0⟩, some "a")) == (#[], .arm ⟨0⟩ #[100])
          | _, _ => false },
    { name :=
        "a key that typed nothing withdraws what is armed, and keeps nothing armed as it is; no step key asks nothing; a key for an unfocused view, or with a prompt or a session open, asks nothing and withdraws"
      run :=
        pure <|
          match atPointDriver "|" #["dots", "paused"] atPoints with
          | none => false
          | some driver =>
            let loop := driver.loop
            let armed := { loop with pausing := some { view := ⟨0⟩, pauses := #[100] } }
            let session := { armed with state := { armed.state with atPoint := some stateSession } }
            let (_, prompting) := prompted armed.state
            armed.atPointAsks driver.handed (some (⟨0⟩, none)) == (#[], .disarm) &&
              loop.atPointAsks driver.handed (some (⟨0⟩, none)) == (#[], .keep) &&
              armed.atPointAsks driver.handed none == (#[], .keep) &&
              armed.atPointAsks driver.handed (some (⟨5⟩, some ".")) == (#[], .disarm) &&
              session.atPointAsks driver.handed (some (⟨0⟩, some ".")) == (#[], .disarm) &&
              ({ armed with state := prompting }).atPointAsks driver.handed
                  (some (⟨0⟩, some ".")) ==
                (#[], .disarm) }]

/-- The checks of completion at point asked by itself, through the loop on
the evil driver over the models: a trigger, and a pause. -/
def atPointByItselfChecks : List Check :=
  [{  name :=
        "a source that declares a trigger character opens a session when that character is typed, with nothing chosen, and no other character does"
      run :=
        pure <|
          match atPointDriver "|" #["dots"] [dotsAtPoint] with
          | none => false
          | some driver =>
            let typed := evilFed driver "i a x"
            let dotted := evilFed typed "."
            typed.loop.state.atPoint.isNone && !listShown typed &&
              dotted.loop.state.atPoint.map (·.source) == some "dots" &&
              sessionChosen dotted == none &&
              listShown dotted &&
              sessionRows dotted == #["wq", "w"] &&
              evilText dotted == some "ax." },
    { name :=
        "typing a then b in insert state leaves the driver with one pause armed and no job; 239 ms open nothing, and one more opens a session of a source that pauses 240 ms, with nothing chosen; a move before the pause withdraws it, and nothing opens"
      run :=
        pure <|
          match atPointDriver "alpha |" #["later"] [] with
          | none => false
          | some driver =>
            let typed := evilFed driver "a a l"
            let early := typed.pass 239
            let due := early.pass 1
            let moved := (evilFed typed "<ArrowLeft>").pass 240
            typed.armed.size == 1 && typed.pending.isEmpty && typed.posting.isEmpty &&
              early.loop.state.atPoint.isNone &&
              due.loop.state.atPoint.map (·.source) == some "later" &&
              sessionChosen due == none &&
              due.armed.isEmpty &&
              moved.armed.isEmpty &&
              moved.loop.state.atPoint.isNone },
    { name :=
        "a pause on a word no batch of a source that answers later holds opens a session of it, and when its job lists nothing that matches the session closes and the echo area is left as it was"
      run :=
        pure <|
          match atPointDriver "xyz |" #["later"] [] with
          | none => false
          | some driver =>
            let typed := evilFed driver "a q w"
            let due := typed.pass 240
            let drained := evilDrained due
            due.loop.state.atPoint.map (·.source) == some "later" &&
              drained.loop.state.atPoint.isNone &&
              drained.loop.state.echo != Completion.AtPoint.noCompletions &&
              drained.loop.state.echo == typed.loop.state.echo }]

/-- The command `marked` of the pressed-keys checks: it says `marked`, then
what it was called with (`calledWith`). -/
def saysCalled : Dispatched := fun call => do
  message s!"marked {calledWith call}"
  return none

/-- A driver of the pressed-keys checks over the initial state: `C-c m`
bound to `marked` (`saysCalled`); `none` if making the state was
refused. -/
def pressedDriver : Option TestDriver :=
  (Loop.Driver.over (dispatchKeys [("C-c m", invoke "marked")] [("marked", saysCalled)])
      (fun _ => none) (EditorState.initial ⟨640, 480⟩) editorModel).toOption

/-- `driver` after the reserved invocation that presses the keys the key
string `text` names (`InputScheme.keysInvocation`) is run as a step of its
own. -/
def pressing {scheme : InputScheme} (driver : Loop.Driver scheme) (text : String) :
    Loop.Driver scheme :=
  (driver.stepped (driver.loop.invoke driver.handed (InputScheme.keysInvocation (keys text)))).1

/-- The checks of the reserved invocation that presses keys
(`InputScheme.keysName`, `Loop.pressed`): the loop feeds its keys to the
scheme from rest and runs what they complete as the keys would, and says a
sequence they do not complete. -/
def pressedChecks : List Check :=
  [{  name :=
        "the reserved keys invocation of C-c m runs marked with the keys C-c m and no argument, as pressing C-c m at rest does"
      run :=
        pure <|
          match pressedDriver with
          | none => false
          | some driver =>
            promptEcho (pressing driver "C-c m") == "marked C-c m" &&
              promptEcho (fedTo driver (presses "C-c m")).1 == "marked C-c m" },
    { name := "the reserved keys invocation of a sequence nothing binds says so and runs nothing"
      run :=
        pure <|
          match pressedDriver with
          | none => false
          | some driver =>
            let pressed := pressing driver "C-c q"
            promptEcho pressed == Loop.notBound "C-c q" &&
              promptEcho pressed == "C-c q: not bound" },
    { name :=
        "the reserved keys invocation feeds its keys from rest: with C-c pending, C-c m still runs marked with the keys C-c m"
      run :=
        pure <|
          match pressedDriver with
          | none => false
          | some driver =>
            let waiting := (fedTo driver (presses "C-c")).1
            TestScheme.scheme.pending waiting.loop.input == keys "C-c" &&
              promptEcho (pressing waiting "C-c m") == "marked C-c m" },
    { name :=
        "under the Vim scheme the reserved keys invocation runs a key as pressing it does: i enters insert state, and x deletes the character under the cursor"
      run :=
        pure <|
          match evilDriver "|x foo" with
          | none => false
          | some driver =>
            let report (driver : EvilDriver) := Vim.Default.scheme.report driver.loop.input ⟨0⟩
            let pressedI := pressing driver "i"
            let typedI := evilFed driver "i"
            let pressedX := pressing driver "x"
            let typedX := evilFed driver "x"
            report pressedI == report typedI && report pressedI != report driver &&
              evilShown pressedI == evilShown typedI &&
              evilText pressedX == some " foo" &&
              evilShown pressedX == evilShown typedX }]

end ModelTest
