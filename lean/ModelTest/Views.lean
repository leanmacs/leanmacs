import Editor.Clipboard.Model
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Display.Model
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.Floating
import Editor.FrameCommands.Compiled
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Menu.Compiled
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Role
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.State.Request
import Editor.TabBar
import Editor.TabCommands.Compiled
import Editor.Watch.Model
import Editor.WindowCommands.Compiled
import ModelTest.Evil

/-!
# Model tests: views and windows

The checks of padding, views and floating views, heights, frame and tab
commands, the tab bar, window commands, the frame's display, titles, menus
and clipboard commands.

Its lists of checks: `paddingChecks`, `viewChecks`, `floatViewChecks`,
`heightChecks`, `frameCommandChecks`, `tabCommandChecks`, `tabBarChecks`,
`windowCommandChecks`, `frameDisplayChecks`, `titleChecks`, `menuChecks`,
`clipboardCommandChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- `count` lines of two digits each, `00`, `01` and so on, joined by line
feeds, and then `ending`. -/
def numbered (count : Nat) (ending : String := "") : String :=
  "\n".intercalate ((List.range count).map fun line => s!"{line / 10}{line % 10}") ++ ending

/-- The frame whose one window's text area is `area`, in `cells`: two rows
of a cell taller, for the window's status row and the frame's bottom row,
which the display model answers a cell tall each. So "a view of six rows"
of a check is a view whose rows are asked with six rows' height. -/
def frameAround (area : Size) (cells : Display.Cells) : Size :=
  ⟨area.width, area.height + 2 * cells.lineHeight⟩

/-- A state of the view checks: `evilState` over `contents` with the cursor
at `head`, in a frame of `size`, with the scroll margin `margin`. The one
window has the frame above its bottom row, and its scroll anchor is at the
text's start. -/
def viewState (contents : String) (size : Size) (margin : Nat := 0) (head : Nat := 0) :
    TextM EditorState := do
  let state ← evilState contents head
  return { (state.setScrollMargin margin) with frame := { state.frame with size } }

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

/-- `driver` fed a resize of the frame to `size`. -/
def viewResized (driver : EvilDriver) (size : Size) : EvilDriver :=
  let frame := frameAround size driver.model.display.cells
  (driver.feed
      { event := .resize { width := frame.width, height := frame.height, scale := 1.0 }
        stamp := 0 }).1

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

/-- The last scene of a run of the loop over the state `start` makes, each
step handed the frame padding `padding`, fed `events`; `none` when the run
was refused or published nothing. -/
def paddedScene (padding : Nat) (events : List Event)
    (start : TextM EditorState := EditorState.initial ⟨640, 480⟩) : Option Scene :=
  match dispatched { padding } events start with
  | some (_, scenes, _) => scenes.back?
  | none => none

/-- A resize to 640 by 480 at scale 1, in fullscreen when `fullscreen` says,
whose window's corners reach `corner` points in and whose title bar covers
`top` points of it. -/
def resizedWith (corner : Nat) (fullscreen : Bool := false) (top : Nat := 0) : Event :=
  .resize { width := 640, height := 480, scale := 1.0, fullscreen, corner, top }

/-- `twoBuffers` with its two windows one above the other. -/
def twoRows : TextM EditorState := do
  let state ← twoBuffers
  return { state with
      frame :=
        { state.frame with
          windows := #[⟨0⟩, ⟨1⟩], layout := .masterStack { side := .top } } }

/-- The padding of the view `id` in `scene`, if it has the view. -/
def paddingIn (scene : Scene) (id : ViewId) : Option Padding :=
  (scene.views.find? (·.id == id)).map (·.padding)

/-- The checks of the views' padding (`EditorState.paddingOf`,
`EditorState.bottomInset`, `Loop.Keys.padding`): what the loop puts in the
scene, in points. Lean handles no scale, so every number here is points:
that layout multiplies them at its scale is pinned in `crates/editor-layout`
(`tests/padding.rs`), and that the first glyph is where these say over real
layout by `FfiTest.paddingChecks`. -/
def paddingChecks : List Check :=
  [{  name :=
        "a resize keeps its corner clearance in the frame beside fullscreen, and the frame keeps no scale"
      run := do
        let some ((loop, _), _, _) := looped (EditorState.initial ⟨0, 0⟩) [resizedWith 14]
          | return false
        let frame := loop.state.frame
        let some ((later, _), _, _) :=
          looped (EditorState.initial ⟨0, 0⟩) [resizedWith 14, resizedWith 0 true]
          | return false
        return frame.corner == 14 && !frame.fullscreen && frame.size == ⟨640, 480⟩ &&
            later.state.frame.corner == 0 &&
            later.state.frame.fullscreen &&
            frame ==
              { size := ⟨640, 480⟩, windows := frame.windows, focused := frame.focused,
                corner := 14 } },
    { name :=
        "at a padding of 8 each window's view is padded 8 across and 8 down, each window of a split its own, and the scene's echo padding is 8 with square corners"
      run :=
        pure <|
          match paddedScene 8 [resizedWith 0] twoBuffers with
          | none => false
          | some scene =>
            paddingIn scene ⟨0⟩ == some { across := 8, down := 8 } &&
              paddingIn scene ⟨1⟩ == some { across := 8, down := 8 } &&
              (scene.views.map (·.rect.x)) == #[0, 320] &&
              scene.echoPadding == 8 },
    { name :=
        "criterion 3, on the model: with a prompt open and a corner clearance of 14, the minibuffer's view is padded 14 across and none down and the echo 14, the larger of the padding 8 and the corner; with a corner of 4 both are 8, the padding; and in fullscreen with a corner of 14 both are 8, the padding alone"
      run :=
        let bottom (events : List Event) : Option (Nat × Nat × Nat) := do
          let scene ← paddedScene 8 events (promptedOver "x")
          let minibuffer ← scene.views.back?
          let window ← paddingIn scene ⟨0⟩
          guard (minibuffer.id != ⟨0⟩ && window == { across := 8, down := 8 })
          return (minibuffer.padding.across, minibuffer.padding.down, scene.echoPadding)
        pure
          (bottom [resizedWith 14] == some (14, 0, 14) &&
            bottom [resizedWith 4] == some (8, 0, 8) &&
            bottom [resizedWith 14 true] == some (8, 0, 8)) },
    { name :=
        "the state's bottom inset is the padding and at least the corner outside fullscreen, and the padding alone in fullscreen; a view's padding is the state's, the minibuffer's view's across only"
      run := do
        let some state := onTextModel (promptedOver "x") | return false
        let shaped (padding corner : Nat) (fullscreen : Bool) : EditorState :=
          { state with
            padding,
            frame :=
              { state.frame with
                corner, fullscreen } }
        let some minibuffer := state.minibufferView? | return false
        return (shaped 8 14 false).bottomInset == 14 && (shaped 8 4 false).bottomInset == 8 &&
            (shaped 8 14 true).bottomInset == 8 &&
            (shaped 0 0 false).bottomInset == 0 &&
            (shaped 8 14 false).paddingOf minibuffer == { across := 14, down := 0 } &&
            (shaped 8 14 false).paddingOf ⟨0⟩ == { across := 8, down := 8 } &&
            (shaped 0 14 false).paddingOf ⟨0⟩ == {} },
    { name :=
        "a resize keeps its top inset in the frame, and a resize in fullscreen that says none leaves none"
      run := do
        let some ((loop, _), _, _) :=
          looped (EditorState.initial ⟨0, 0⟩) [resizedWith 14 (top := 28)]
          | return false
        let some ((later, _), _, _) :=
          looped (EditorState.initial ⟨0, 0⟩) [resizedWith 14 (top := 28), resizedWith 0 true]
          | return false
        return loop.state.frame.top == 28 && later.state.frame.top == 0 &&
            later.state.frame.fullscreen },
    { name :=
        "criterion 4, on the model: with a top inset of 28 a window along the frame's top edge is padded 8 across, 8 down and 28 at the top, the lower window of a rows split 8, 8 and none, and both windows of a columns split 8, 8 and 28; after a fullscreen resize that says none, every window is padded 8, 8 and none"
      run :=
        let under (top : Nat) : Padding := { across := 8, down := 8, top }
        pure <|
          match paddedScene 8 [resizedWith 0 (top := 28)] twoRows,
            paddedScene 8 [resizedWith 0 (top := 28)] twoBuffers,
            paddedScene 8 [resizedWith 0 (top := 28), resizedWith 0 true] twoRows,
            paddedScene 8 [resizedWith 0 (top := 28), resizedWith 0 true] twoBuffers with
          | some rows, some columns, some fullRows, some fullColumns =>
            (rows.views.map (·.rect.y != 0)) == #[false, true] &&
              paddingIn rows ⟨0⟩ == some (under 28) &&
              paddingIn rows ⟨1⟩ == some (under 0) &&
              paddingIn columns ⟨0⟩ == some (under 28) &&
              paddingIn columns ⟨1⟩ == some (under 28) &&
              paddingIn fullRows ⟨0⟩ == some (under 0) &&
              paddingIn fullRows ⟨1⟩ == some (under 0) &&
              paddingIn fullColumns ⟨0⟩ == some (under 0) &&
              paddingIn fullColumns ⟨1⟩ == some (under 0)
          | _, _, _, _ => false },
    { name :=
        "the state's top inset is the frame's outside fullscreen and none in fullscreen, whatever the window last said; the minibuffer's view takes none, and the area a command asks about its top window carries it"
      run := do
        let some state := onTextModel (promptedOver "x") | return false
        let shaped (top : Nat) (fullscreen : Bool) : EditorState :=
          { state with
            padding := 8,
            frame :=
              { state.frame with
                top, fullscreen } }
        let some minibuffer := state.minibufferView? | return false
        let some rect := (shaped 28 false).rect? ⟨0⟩ | return false
        let area := Scroll.Area.ofRect ⟨3⟩ rect 16 ((shaped 28 false).paddingOf ⟨0⟩)
        return (shaped 28 false).topInset == 28 && (shaped 28 true).topInset == 0 &&
            (shaped 28 false).paddingOf ⟨0⟩ == { across := 8, down := 8, top := 28 } &&
            (shaped 28 true).paddingOf ⟨0⟩ == { across := 8, down := 8 } &&
            ((shaped 28 false).paddingOf minibuffer).top == 0 &&
            area.padding == { across := 8, down := 8, top := 28 } },
    { name :=
        "a loop handed no padding gives every view no padding and the echo none: it draws and scrolls as before there was one"
      run :=
        pure <|
          match paddedScene 0 [resizedWith 0] twoBuffers,
            paddedScene 0 [resizedWith 0] (promptedOver "x"),
            dispatched {} [resizedWith 0] twoBuffers with
          | some windows, some prompted, some (_, scenes, _) =>
            windows.views.all (·.padding == {}) && windows.echoPadding == 0 &&
              prompted.views.all (·.padding == {}) &&
              prompted.echoPadding == 0 &&
              scenes.back? == some windows
          | _, _, _ => false },
    { name :=
        "the area a view is asked about keeps the rectangle's width and its height less the bottom row, and carries the padding; the loop's follow asks with the view's padding, so a cursor on the fifth row of a text area five rows tall is followed when the view is padded a row down, and not when it is not"
      run := do
        let area :=
          Scroll.Area.ofRect ⟨3⟩ { x := 0, y := 0, width := 640, height := 200 } 16
            { across := 8, down := 8 }
        -- Lines of two digits and a break: the fifth row starts at byte 12.
        -- In cells of a pixel a frame 10 by 7 gives the window 6 rows, 5
        -- above its status row, and a padding of 1 down leaves 3.
        let anchorAfter (padding : Nat) : Option Nat :=
          let program : EditorM Nat := do
            let state ← viewState (numbered 20) ⟨10, 7⟩ 0 12
            let keys : Loop.Keys TestScheme.scheme := { padding }
            let (loop, _) ← stepsWith keys { state } [.focus true]
            let some target := loop.state.focusedTarget? | throw .noSuchText
            return (← target.anchor).offset
          match program.runModel editorModel with
          | (.ok offset, _) => some offset
          | (.error _, _) => none
        return area ==
              { snapshot := ⟨3⟩, width := 640, height := 184,
                padding := { across := 8, down := 8 } } &&
            anchorAfter 0 == some 0 &&
            anchorAfter 1 == some 6 }]

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

/-- Whether asking the text model of `driver` for the snapshot `id` is
refused with `noSuchSnapshot`: it was released. -/
def releasedSnapshot (driver : EvilDriver) (id : SnapshotId) : Bool :=
  match ((id.lineCount : TextM Nat).runModel driver.model.texts).1 with
  | .error .noSuchSnapshot => true
  | _ => false

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

/-- A rectangle at `x`, `y`, `width` across and `height` down. -/
def rectAt (x y width height : Nat) : Rect :=
  { x, y, width, height }

/-- The initial state in a frame of `size`, with `heights` as the heights
the display last answered. -/
def sizedState (size : Size) (heights : Display.Heights := default) : Option EditorState :=
  (onTextModel (EditorState.initial size)).map ({ · with heights })

/-- The checks of how the views and the minibuffer's place are sized by the
heights the display answers (`EditorState.rects`, `EditorState.bottomRow`,
`Scroll.Area.ofRect`), and of what `Loop.publish` keeps of them; and that
opening a prompt clears the echo, as Vim does (`EditorState.openPrompt`).
The heights are the state's: a check sets them as the display would. -/
def heightChecks : List Check :=
  let sixteen : Display.Heights := { text := 16, status := 16, message := 16 }
  let odd : Display.Heights := { text := 24, status := 20, message := 28 }
  [{  name :=
        "with no prompt open a window of a 640 by 480 frame ends above the bottom row, 640 by 464, and is asked about with its height less its status row"
      run :=
        pure <|
          match sizedState ⟨640, 480⟩ sixteen with
          | none => false
          | some state =>
            state.rects == #[(⟨0⟩, rectAt 0 0 640 464)] && state.bottomRow ⟨0⟩ == 16 &&
              Scroll.Area.ofRect ⟨3⟩ (rectAt 0 0 640 464) (state.bottomRow ⟨0⟩) ==
                { snapshot := ⟨3⟩, width := 640, height := 448 } },
    { name :=
        "with a prompt open the minibuffer's place is a text row and the bottom row, and the minibuffer's view is asked about with its height less the bottom row"
      run :=
        pure <|
          match sizedState ⟨640, 480⟩ sixteen with
          | none => false
          | some state =>
            match prompted state with
            | (.ok view, asking) =>
              asking.rects == #[(⟨0⟩, rectAt 0 0 640 448), (view, rectAt 0 448 640 32)] &&
                asking.bottomRow view == 16 &&
                Scroll.Area.ofRect ⟨3⟩ (rectAt 0 448 640 32) (asking.bottomRow view) ==
                  { snapshot := ⟨3⟩, width := 640, height := 16 }
            | _ => false },
    { name :=
        "with heights of 24, 20 and 28 a 640 by 480 frame gives a window of 452 asked about at 432, and a prompt's place of 52 asked about at 24"
      run :=
        pure <|
          match sizedState ⟨640, 480⟩ odd with
          | none => false
          | some state =>
            let window := rectAt 0 0 640 452
            state.rects == #[(⟨0⟩, window)] &&
              (Scroll.Area.ofRect ⟨3⟩ window (state.bottomRow ⟨0⟩)).height == 432 &&
              match prompted state with
              | (.ok view, asking) =>
                let place := rectAt 0 428 640 52
                asking.rects == #[(⟨0⟩, rectAt 0 0 640 428), (view, place)] &&
                  (Scroll.Area.ofRect ⟨3⟩ place (asking.bottomRow view)).height == 24
              | _ => false },
    { name := "a frame of 0 by 0 gives views of 0 by 0, with a prompt open or not"
      run :=
        pure <|
          match sizedState ⟨0, 0⟩ sixteen with
          | none => false
          | some state =>
            state.rects == #[(⟨0⟩, rectAt 0 0 0 0)] &&
              match prompted state with
              | (.ok view, asking) =>
                asking.rects == #[(⟨0⟩, rectAt 0 0 0 0), (view, rectAt 0 0 0 0)]
              | _ => false },
    { name := "a publish keeps the heights the display answered, for the commands until the next"
      run :=
        pure <|
          match evilDriver "|abc" with
          | none => false
          | some driver =>
            -- The display model's cells are 1 by 1, so its heights are 1.
            (viewResized driver ⟨40, 30⟩).loop.state.heights ==
              { text := 1, status := 1, message := 1 } },
    { name := "opening a prompt clears the echo, and an open that is refused leaves it as it was"
      run :=
        pure <|
          match sizedState ⟨640, 480⟩ with
          | none => false
          | some state =>
            let said := { state with echo := "before" }
            match prompted said with
            | (.ok _, asking) =>
              asking.echo == "" &&
                match prompted { asking with echo := "before" } with
                | (.error (.alreadyOpen _), refused) => refused.echo == "before"
                | _ => false
            | _ => false }]

/-- The registry of the frame command checks: the frame's commands, and the
ex line's, whose `quit` the frame's `s-q` names, and the frame's bindings,
with the menu bar's bindings, registered for the owner `compiled`, as a
host registers them, and `config` as config's bindings and `commands` as
config's commands. -/
def frameRegistry (config : Array Config.KeyBinding := #[])
    (commands : Array Config.Registration := #[]) : Config.Registry :=
  (((({} : Config.Registry).replace .compiled
                (FrameCommands.commands ++ Ex.commands)).replaceBindings
            .compiled (FrameCommands.bindings ++ Menu.bindings)).replaceBindings
        .config config).replace
    .config commands

/-- What a step of the frame command checks is handed: the active keymaps
`registry` makes for the test scheme from the loop's state, its plain
commands and those given their call, and the menu bar that ships with its
key equivalents filled from `registry`, as a host's are. -/
def frameKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  { maps := registry.activeMaps TestScheme.scheme
    command? := fun name =>
      match registry.find? name with
      | some { registration := { action := .plain run, .. }, .. } =>
        some fun _ => do
          run
          return none
      | some { registration := { action := .call run, .. }, .. } =>
        some fun call => do
          run call
          return none
      | _ => none
    menu := some (registry.menuOf Menu.standard) }

/-- A driver of the frame command checks over the initial state, with the
keys of `registry`; `none` if making the state was refused. With `held`
the scratch buffer holds a file, made up and never loaded, so that an edit
of it is an unsaved change. -/
def frameDriver (registry : Config.Registry := frameRegistry) (held : Bool := false) :
    Option TestDriver :=
  let start : TextM EditorState := do
    let state ← EditorState.initial ⟨640, 480⟩
    if held then
      return (state.attachFile ⟨0⟩ "/files/note.txt" { seconds := 0, nanoseconds := 0, size := 0 }
            .lf).2
    return state
  (Loop.Driver.over (frameKeys registry) driverJobs start editorModel).toOption

/-- The window's word that it is 640 by 480 at scale 1, in fullscreen or not. -/
def resizedTo (fullscreen : Bool) : Event :=
  .resize { width := 640, height := 480, scale := 1.0, fullscreen }

/-- What `driver`'s display model was asked of the window, and whether the
frame last said it is in fullscreen, after `events`; `none` without a
driver. -/
def framed (driver : Option TestDriver) (events : List Event) :
    Option (Array Display.FrameRequest × Bool) :=
  driver.map fun driver =>
    let fed := (fedTo driver events).1
    (fed.model.display.asked, fed.loop.state.frame.fullscreen)

/-- The checks of the frame's commands (`Editor/FrameCommands.lean`,
`Editor/FrameCommands/Compiled.lean`) and of the frame's last reported
fullscreen state, on the loop's driver over the editor's models and the
test scheme, with the registry's active keymaps. -/
def frameCommandChecks : List Check :=
  [{  name :=
        "a resize in fullscreen sets the frame's last reported state, and a resize out of it clears it"
      run :=
        pure <|
          match frameDriver with
          | none => false
          | some driver =>
            let entered := (fedTo driver [resizedTo true]).1
            let left := (fedTo entered [resizedTo false]).1
            !driver.loop.state.frame.fullscreen && entered.loop.state.frame.fullscreen &&
              !left.loop.state.frame.fullscreen &&
              left.model.display.asked.isEmpty },
    { name :=
        "toggle-fullscreen, run with the window last reported windowed, asks the display to enter fullscreen and nothing else, and leaves the frame's state as it was"
      run := pure (framed frameDriver (presses "C-s-f") == some (#[.enterFullscreen], false)) },
    { name := "toggle-fullscreen, run with the window last reported in fullscreen, asks to leave it"
      run :=
        pure
          (framed frameDriver (resizedTo true :: presses "C-s-f") ==
            some (#[.leaveFullscreen], true)) },
    { name :=
        "C-s-f runs toggle-fullscreen: pressed twice with a resize in fullscreen between, it asks to enter and then to leave"
      run :=
        pure
          (framed frameDriver (presses "C-s-f" ++ [resizedTo true] ++ presses "C-s-f") ==
            some (#[.enterFullscreen, .leaveFullscreen], true)) },
    { name := "s-m runs minimise-window, which asks the display to minimise the window"
      run := pure (framed frameDriver (presses "s-m") == some (#[.minimise], false)) },
    { name :=
        "s-q runs quit: with a buffer that holds a file edited, it is refused with the quit command's message and the driver goes on; with nothing unsaved it stops the driver"
      run :=
        pure <|
          match frameDriver (held := true) with
          | none => false
          | some driver =>
            let (refused, _) := fedTo driver ([.commit "x"] ++ presses "s-q")
            let (left, steps) := fedTo driver (presses "s-q")
            !refused.stopped && !refused.loop.state.quitting &&
              echoOf refused == some (Ex.notQuitting (.unsaved "scratch")) &&
              left.stopped &&
              steps.back?.join.map (·.next) == some .stop },
    { name :=
        "the compiled bindings are C-s-f to toggle-fullscreen, s-m to minimise-window and s-q to quit, and config's binding of C-s-f is the one that runs while config binds it"
      run :=
        let rebound :=
          frameRegistry #[{ keys := keys "C-s-f", command := FrameCommands.minimiseName }]
        pure
          (FrameCommands.bindings ==
              #[{ keys := keys "C-s-f", command := FrameCommands.toggleFullscreenName },
                { keys := keys "s-m", command := FrameCommands.minimiseName },
                { keys := keys "s-q", command := Ex.quitName }] &&
            FrameCommands.toggleFullscreenName == "toggle-fullscreen" &&
            FrameCommands.minimiseName == "minimise-window" &&
            FrameCommands.commands.map (·.name) == #["toggle-fullscreen", "minimise-window"] &&
            framed (frameDriver rebound) (presses "C-s-f") == some (#[.minimise], false)) }]

/-- Active keymaps, for every view, that bind each key string of `table` to
the command name beside it, as config's `bindKey` binds one. -/
def windowMaps (table : List (String × String)) : EditorState → ViewId → List (Keymap Vim.Bound) :=
  fun _ _ => [Vim.Default.keymap (table.map fun (text, name) => (text, .command { name }))]

/-- What a step of the window checks is handed: evil's commands, the
minibuffer's, the ex line's and the window commands, `layout` as config's
layout, and `maps` as the active keymaps, none unless a check names them,
so the window commands are reached by the keys the Vim scheme that ships
binds. -/
def windowHanded (layout : Layout)
    (maps : EditorState → ViewId → List (Keymap Vim.Bound) := fun _ _ => []) :
    Loop.Keys Vim.Default.scheme :=
  { evilHanded (Ex.commands ++ WindowCommands.commands) with
    layout := some layout, maps }

/-- A driver of the window checks over `windowsUnder count layout`, with
config's layout `layout` already applied and the window `focus` focused, on
the editor's models in cells 16 pixels tall, so that the tiled area of the
frame of 640 by 480 is 640 by 464. -/
def windowDriver (count : Nat) (layout : Layout) (focus : Nat := 0)
    (handed : Loop.Keys Vim.Default.scheme := windowHanded layout) : Option EvilDriver :=
  let start : TextM EditorState := do
    let state ← windowsUnder count layout
    return { state with
        frame :=
          { state.frame with
            chosen := some layout, focused := ⟨focus⟩ } }
  (Loop.Driver.over handed (fun _ => none) start
      (.over { advance := 8, lineHeight := 16 })).toOption

/-- The state of the window driver over `count` windows under `layout`,
`focus` focused, once the keys `typed` name were pressed. -/
def windowsAfter (count : Nat) (layout : Layout) (typed : String) (focus : Nat := 0) :
    Option EditorState :=
  (windowDriver count layout focus).map fun driver => (evilFed driver typed).loop.state

/-- The window list, as indices, and the focus of `state`. -/
def windowOrder (state : EditorState) : List Nat × Nat :=
  (state.frame.windows.toList.map (·.index), state.frame.focused.index)

/-- The rectangles of `state`'s windows, each as its view's index and its
x, y, width and height. -/
def windowRects (state : EditorState) : List (Nat × Nat × Nat × Nat × Nat) :=
  state.rects.toList.map fun (view, rect) => (view.index, rect.x, rect.y, rect.width, rect.height)

/-- What a step of the tab checks is handed: `windowHanded`'s commands and
the tab commands, `layout` as config's layout, and `maps` as the active
keymaps. -/
def tabHanded (layout : Layout := Layout.default)
    (maps : EditorState → ViewId → List (Keymap Vim.Bound) := fun _ _ => []) :
    Loop.Keys Vim.Default.scheme :=
  { evilHanded (Ex.commands ++ WindowCommands.commands ++ TabCommands.commands) with
    layout := some layout, maps }

/-- The state of a driver of the tab checks over one window under the
default layout, `tab-rename` bound to `C-c r`, `tab-move-right` to `C-c m`
and `tab-move-left` to `C-c M`, once the keys `typed` name were pressed. -/
def tabsAfter (typed : String) : Option EvilDriver :=
  let maps :=
    windowMaps
      [("C-c r", TabCommands.renameName), ("C-c m", TabCommands.moveRightName),
        ("C-c M", TabCommands.moveLeftName)]
  (windowDriver 1 Layout.default (handed := tabHanded Layout.default maps)).map (evilFed · typed)

/-- The windows of each tab of `state`, as indices, in order. -/
def tabOrder (state : EditorState) : List (List Nat) :=
  state.frame.tabs.toList.map fun tab => tab.windows.toList.map (·.index)

/-- The checks of the tab commands (`Editor/TabCommands.lean`), by key, on
the loop's driver over the editor's models, under the Vim scheme that
ships with the tab commands handed: tmux's keys under `C-w`, the refusals
in the echo area, the prompts of `tab-switch` and `tab-rename`, and that
each command acts on the tab of its call's window. -/
def tabCommandChecks : List Check :=
  let delivered (driver : EvilDriver) (command : EditorM Unit) : EvilDriver :=
    (driver.stepped (driver.loop.deliver driver.handed "tab" command)).1
  let state (driver : Option EvilDriver) : Option EditorState := driver.map (·.loop.state)
  [{  name := "C-w c makes a tab after the one in view, on the same buffer, and selects it"
      run :=
        pure <|
          match state (tabsAfter "C-w c") with
          | some after =>
            after.frame.tabs.size == 2 && after.frame.tabIndex == 1 &&
              tabOrder after == [[0], [1]] &&
              after.frame.focused == ⟨1⟩ &&
              (after.window? ⟨1⟩).map (·.buffer) == some ⟨0⟩ &&
              after.wellFormed
          | none => false },
    { name :=
        "C-w n and C-w p go to the next and the previous tab, wrapping, and with a count C-w n goes to the tab of that number"
      run :=
        pure <|
          match state (tabsAfter "C-w c C-w c C-w n"), state (tabsAfter "C-w c C-w c C-w n C-w p"),
            state (tabsAfter "C-w c C-w c C-w p C-w p"),
            state (tabsAfter "C-w c C-w c C-w n 3 C-w n") with
          | some wrapped, some back, some twice, some counted =>
            wrapped.frame.tabIndex == 0 && back.frame.tabIndex == 2 && twice.frame.tabIndex == 0 &&
              counted.frame.tabIndex == 2
          | _, _, _, _ => false },
    { name := "C-w 2 selects tab 2, and C-w 5 says there is no tab 5"
      run :=
        pure <|
          match state (tabsAfter "C-w c C-w 1 C-w 2"), state (tabsAfter "C-w c C-w 1 C-w 5") with
          | some second, some missing =>
            second.frame.tabIndex == 1 && missing.frame.tabIndex == 0 &&
              missing.echo == s!"{TabCommands.selectName 5}: {(LayoutRefusal.noSuchTab 4).describe}"
          | _, _ => false },
    { name :=
        "criterion 3: C-w & with one tab says the last tab cannot be closed and leaves the state; with two it closes the tab in view and its window"
      run :=
        pure <|
          match tabsAfter "", state (tabsAfter "C-w &"), state (tabsAfter "C-w c C-w &") with
          | some start, some refused, some closed =>
            refused.echo == s!"{TabCommands.closeName}: {LayoutRefusal.onlyTab.describe}" &&
              refused.frame == start.loop.state.frame &&
              refused.windows == start.loop.state.windows &&
              closed.frame.tabs.size == 1 &&
              tabOrder closed == [[0]] &&
              (closed.window? ⟨1⟩).isNone &&
              closed.wellFormed
          | _, _, _ => false },
    { name :=
        "C-w w asks for a tab, labelled Tab:, with a candidate of number and label for every tab; typing 2 and accepting selects tab 2, and a name that matches nothing says so"
      run :=
        pure <|
          match tabsAfter "C-w c C-w p C-w w", state (tabsAfter "C-w c C-w p C-w w 2 RET"),
            state (tabsAfter "C-w c C-w p C-w w z q RET") with
          | some asking, some chosen, some missed =>
            asking.loop.state.prompt.map (·.label) == some TabCommands.switchPrompt &&
              asking.loop.state.prompt.map (·.candidates.all) == some #["1 scratch", "2 scratch"] &&
              chosen.frame.tabIndex == 1 &&
              chosen.prompt.isNone &&
              missed.frame.tabIndex == 0 &&
              missed.echo == TabCommands.noMatch "zq"
          | _, _, _ => false },
    { name :=
        "C-w w resolves an answer as a candidate exactly, then the first tab whose label it is, then a number of a tab, then the fuzzy matcher's best candidate: from tab 1, a label notes, a candidate 2 scratch, a near miss nots, a label 1 over the number 1, and a candidate 2 scratch over tab 1's label 2 scratch each select tab 2"
      run :=
        pure <|
          -- Each answer is typed in tab 1, so a selection of tab 2 is the
          -- answer's doing; where two branches disagree, the earlier one
          -- names tab 2 and the later one tab 1.
          match state (tabsAfter "C-w c C-c r n o t e s RET C-w p C-w w n o t e s RET"),
            state (tabsAfter "C-w c C-w p C-w w 2 SPC s c r a t c h RET"),
            state (tabsAfter "C-w c C-c r n o t e s RET C-w p C-w w n o t s RET"),
            state (tabsAfter "C-w c C-c r 1 RET C-w p C-w w 1 RET"),
            state
              (tabsAfter
                "C-w c C-w p C-c r 2 SPC s c r a t c h RET C-w w 2 SPC s c r a t c h RET") with
          | some labelled, some exact, some fuzzy, some labelOverNumber, some exactOverLabel =>
            labelled.frame.tabIndex == 1 && exact.frame.tabIndex == 1 &&
              fuzzy.frame.tabIndex == 1 &&
              labelOverNumber.tabLabel 1 == "1" &&
              labelOverNumber.frame.tabIndex == 1 &&
              exactOverLabel.tabLabel 0 == "2 scratch" &&
              exactOverLabel.frame.tabIndex == 1 &&
              [labelled, exact, fuzzy, labelOverNumber, exactOverLabel].all (·.prompt.isNone)
          | _, _, _, _, _ => false },
    { name :=
        "tab-rename asks for a name, labelled Rename tab:, and names the tab of its window; an empty answer goes back to the generated label, its focused window's buffer's name"
      run :=
        pure <|
          match tabsAfter "C-c r", state (tabsAfter "C-c r n o t e s RET"),
            state (tabsAfter "C-c r n o t e s RET C-c r C-u RET") with
          | some asking, some named, some back =>
            asking.loop.state.prompt.map (·.label) == some TabCommands.renamePrompt &&
              named.frame.name == some "notes" &&
              named.tabLabel 0 == "notes" &&
              back.frame.name == none &&
              back.tabLabel 0 == "scratch"
          | _, _, _ => false },
    { name :=
        "tab-move-right and tab-move-left move the tab of their window one place, clamped at the ends, and it stays in view"
      run :=
        pure <|
          match state (tabsAfter "C-w c C-w c C-w 1 C-c m"),
            state (tabsAfter "C-w c C-w c C-w 1 C-c m C-c m C-c m"),
            state (tabsAfter "C-w c C-w c C-w 1 C-c M"), state (tabsAfter "C-w c C-w c C-c M") with
          | some right, some clamped, some still, some left =>
            -- The tab bar's view took the id 2 at the publish after the first
            -- C-w c, so the third tab's window is 3.
            tabOrder right == [[1], [0], [3]] && right.frame.tabIndex == 1 &&
              tabOrder clamped == [[1], [3], [0]] &&
              clamped.frame.tabIndex == 2 &&
              tabOrder still == [[0], [1], [3]] &&
              tabOrder left == [[0], [3], [1]] &&
              left.frame.tabIndex == 1
          | _, _, _, _ => false },
    { name :=
        "criterion 1 by key: after C-w s C-w c C-w s C-w z C-w p the first tab's windows, focus and layout are as they were before C-w c, and its rectangles too in the area the tab bar leaves, and after C-w n the second tab is zoomed with its focus where it was left"
      run :=
        pure <|
          match state (tabsAfter "C-w s"), state (tabsAfter "C-w s C-w c C-w s C-w z"),
            state (tabsAfter "C-w s C-w c C-w s C-w z C-w p"),
            state (tabsAfter "C-w s C-w c C-w s C-w z C-w p C-w n") with
          | some split, some zoomed, some first, some second =>
            windowOrder first == windowOrder split && first.frame.toTab == split.frame.toTab &&
              windowRects first == windowRects { split with tabBarShown := .always } &&
              first.frame.tabIndex == 0 &&
              second.frame.tabIndex == 1 &&
              second.frame.layout == .monocle &&
              windowOrder second == windowOrder zoomed &&
              second.frame.toTab == zoomed.frame.toTab
          | _, _, _, _ => false },
    { name :=
        "each tab command acts on the tab of its call's window, not on the tab in view: run on a hidden tab's window, tab-close closes that tab, tab-rename names it, tab-move-left moves it, tab-next selects the tab after it and tab-new opens a tab after it"
      run :=
        pure <|
          match tabsAfter "C-w c C-w c C-w 1" with
          | none => false
          | some driver =>
            let onView (view : Nat) (name : String) (arguments : List Argument := []) :
              EditorM Unit := do
              let some target := (← editorState).target? ⟨view⟩ | giveUp "no window"
              discard <| runCommand name { target, arguments }
            -- The tab bar's view took the id 2 at the publish after the first
            -- C-w c, so the third tab's window is 3, and a new one is 4.
            let closed := delivered driver (onView 3 TabCommands.closeName)
            let renamed := delivered driver (onView 1 TabCommands.renameName [.str "far"])
            let moved := delivered driver (onView 3 TabCommands.moveLeftName)
            let next := delivered driver (onView 1 TabCommands.nextName)
            let made := delivered driver (onView 1 TabCommands.newName)
            tabOrder closed.loop.state == [[0], [1]] && closed.loop.state.frame.tabIndex == 0 &&
              renamed.loop.state.frame.tabs.map (·.name) == #[none, some "far", none] &&
              tabOrder moved.loop.state == [[0], [3], [1]] &&
              moved.loop.state.frame.tabIndex == 0 &&
              next.loop.state.frame.tabIndex == 2 &&
              tabOrder made.loop.state == [[0], [1], [4], [3]] &&
              made.loop.state.frame.tabIndex == 2 &&
              made.loop.state.frame.focused == ⟨4⟩ &&
              [closed, renamed, moved, next, made].all (·.loop.state.wellFormed) },
    { name :=
        "criterion 2 in the loop: a publish handed another layout rearranges the tab in view only; after C-w p a publish handed the same layout keeps the first tab under its own; C-w c then makes a tab under it"
      run :=
        pure <|
          match tabsAfter "C-w s C-w c C-w s" with
          | none => false
          | some driver =>
            let chosen := evilFed { driver with keys := tabHanded .monocle } "<Escape>"
            let back := evilFed chosen "C-w p <Escape>"
            let made := evilFed back "C-w c"
            let before := driver.loop.state.frame
            chosen.loop.state.frame.tabIndex == 1 && chosen.loop.state.frame.layout == .monocle &&
              chosen.loop.state.frame.windows == before.windows &&
              chosen.loop.state.frame.tabsBefore == before.tabsBefore &&
              back.loop.state.frame.tabIndex == 0 &&
              back.loop.state.frame.layout == Layout.default &&
              back.loop.state.frame.windows == before.tabsBefore.flatMap (·.windows) &&
              made.loop.state.frame.tabIndex == 1 &&
              made.loop.state.frame.layout == .monocle &&
              [chosen, back, made].all (·.loop.state.wellFormed) }]

/-- The checks of the tab bar (`Editor/TabBar.lean`): the line it shows,
its strip above the minibuffer's (`EditorState.tabBarRect?`), and, on the
loop's driver over the editor's models, the view a publish draws it in. -/
def tabBarChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let chip (start stop : Nat) (selected : Bool := false) : Decoration :=
    { start, stop, face := if selected then TabBar.selectedFace else TabBar.face }
  let withTabs (state : EditorState) (count : Nat) : EditorState :=
    { state with
      frame :=
        { state.frame with
          tabsAfter :=
            (Array.range (count - 1)).map fun _ => { windows := #[⟨0⟩], focused := ⟨0⟩ } } }
  [{  name :=
        "the line lists every tab as a chip of its number and label, joined by a space, each chip's bytes in the tab bar's face and the selected one's in its own; a label of several bytes a character is counted in bytes"
      run :=
        pure <|
          TabBar.line #["scratch"] 0 == (" 1 scratch ", #[chip 0 11 true]) &&
            TabBar.line #["scratch", "scratch"] 1 ==
              (" 1 scratch   2 scratch ", #[chip 0 11, chip 12 23 true]) &&
            TabBar.line #["scratch", "scratch"] 0 ==
              (" 1 scratch   2 scratch ", #[chip 0 11 true, chip 12 23]) &&
            TabBar.line #["a", "b", "c"] 0 ==
              (" 1 a   2 b   3 c ", #[chip 0 5 true, chip 6 11, chip 12 17]) &&
            TabBar.line #["a", "b", "c"] 1 ==
              (" 1 a   2 b   3 c ", #[chip 0 5, chip 6 11 true, chip 12 17]) &&
            TabBar.line #["a", "b", "c"] 2 ==
              (" 1 a   2 b   3 c ", #[chip 0 5, chip 6 11, chip 12 17 true]) &&
            TabBar.line #["é", "b"] 0 == (" 1 é   2 b ", #[chip 0 6 true, chip 7 12]) },
    { name :=
        "the tab bar's strip is a text row above the minibuffer's, cut from the tiled area, shown with two tabs or more by default: at 640 by 480 the tiled area is 640 by 448 and the bar 0,448 640 by 16; with a prompt open it sits above the minibuffer's taller strip; with one tab there is none and the tiled area is 640 by 464; always shows it with one tab, and never shows none with three"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some one =>
            let two := withTabs one 2
            let (_, asking) := prompted two
            let three := withTabs one 3
            two.tiled == rect 0 0 640 448 && two.tabBarRect? == some (rect 0 448 640 16) &&
              two.cutFrame.2 == rect 0 464 640 16 &&
              asking.tabBarRect? == some (rect 0 432 640 16) &&
              asking.cutFrame.2 == rect 0 448 640 32 &&
              asking.tiled == rect 0 0 640 432 &&
              one.tabBarRect? == none &&
              one.tiled == rect 0 0 640 464 &&
              { one with tabBarShown := .always }.tabBarRect? == some (rect 0 448 640 16) &&
              { three with tabBarShown := .never }.tabBarRect? == none &&
              { three with tabBarShown := .never }.tiled == rect 0 0 640 464 },
    { name :=
        "a frame shorter than the two strips is clamped: the minibuffer's strip first, then the bar in what is left, and none when nothing is"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 20⟩),
            onTextModel (EditorState.initial ⟨640, 10⟩) with
          | some short, some shorter =>
            let short := withTabs short 2
            let shorter := withTabs shorter 2
            short.tiled.height == 0 && short.tabBarRect? == some (rect 0 0 640 4) &&
              short.cutFrame.2 == rect 0 4 640 16 &&
              shorter.tabBarRect? == none &&
              shorter.tiled.height == 0
          | _, _ => false },
    { name :=
        "a float anchored to the frame is centred in the tiled area the bar leaves, and no float meets the bar's strip"
      run :=
        pure <|
          match
            onTextModel do
              let state ← EditorState.initial ⟨640, 480⟩
              withFloats state [(.frame, false)] with
          | none => false
          | some state =>
            let two := withTabs state 2
            two.rect? ⟨1⟩ == some (Floating.centred {} (rect 0 0 640 448)) &&
              (two.rect? ⟨1⟩).any (fun float => float.y + float.height ≤ 448) },
    { name :=
        "criterion 5, in the loop: after C-w c the last view of the scene is the tab bar, its text the line of both tabs with the second's chip selected, in the bar's strip, padded across by the frame padding and not down, with no selection and no status field; after C-w p the chips' faces swap, the bar keeps its view, and the snapshot of the old line is released; it is never the focused view; after C-w & there is no bar and the tiled area is whole again"
      run :=
        pure <|
          let handed : Loop.Keys Vim.Default.scheme :=
            { tabHanded Layout.default with padding := 8 }
          match (windowDriver 1 Layout.default (handed := handed)).map (evilFed · "C-w c") with
          | none => false
          | some tabbed =>
            let back := evilFed tabbed "C-w p"
            let closed := evilFed back "C-w &"
            let barOf (driver : EvilDriver) : Option View :=
              driver.model.display.scenes.back?.bind fun scene =>
                scene.views.back?.bind fun view =>
                  if driver.loop.state.tabBar.any (·.view == view.id) then some view else none
            let focused (driver : EvilDriver) : Option ViewId :=
              driver.model.display.scenes.back?.bind (·.focused)
            match barOf tabbed, barOf back with
            | some bar, some again =>
              shownText tabbed.model bar == some " 1 scratch   2 scratch " &&
                bar.decorations == #[chip 0 11, chip 12 23 true] &&
                bar.rect == rect 0 448 640 16 &&
                bar.padding == { across := 8, down := 0 } &&
                bar.selections.isEmpty &&
                bar.status.isEmpty &&
                focused tabbed == some ⟨1⟩ &&
                again.id == bar.id &&
                again.decorations == #[chip 0 11 true, chip 12 23] &&
                shownText back.model again == some " 1 scratch   2 scratch " &&
                focused back == some ⟨0⟩ &&
                (bar.snapshot == again.snapshot || releasedSnapshot back bar.snapshot) &&
                barOf closed == none &&
                closed.loop.state.tiled == rect 0 0 640 464 &&
                [tabbed, back, closed].all (·.loop.state.wellFormed)
            | _, _ => false },
    { name :=
        "renaming a tab changes the bar's line, and the snapshot of the line before is released"
      run :=
        pure <|
          match tabsAfter "C-w c" with
          | none => false
          | some tabbed =>
            let named := evilFed tabbed "C-c r n RET"
            let barOf (driver : EvilDriver) : Option View :=
              driver.model.display.scenes.back?.bind (·.views.back?)
            match barOf tabbed, barOf named with
            | some bar, some again =>
              shownText named.model again == some " 1 scratch   2 n " && again.id == bar.id &&
                bar.snapshot != again.snapshot &&
                releasedSnapshot named bar.snapshot
            | _, _ => false },
    { name :=
        "a loop handed never shows no bar with two tabs, and the tiled area is whole; handed always it shows one with one tab; handed none it keeps the state's, never or always as an earlier publish left it"
      run :=
        pure <|
          let handed (shown : Option TabBar.Shown) : Loop.Keys Vim.Default.scheme :=
            { tabHanded Layout.default with tabBar := shown }
          let barredDriver (shown : Option TabBar.Shown) (typed : String) : Option EvilDriver :=
            (windowDriver 1 Layout.default (handed := handed shown)).map (evilFed · typed)
          let barred (shown : Option TabBar.Shown) (typed : String) : Option EditorState :=
            (barredDriver shown typed).map (·.loop.state)
          -- Published once handed `shown`, then handed none.
          let kept (shown : TabBar.Shown) (typed : String) : Option EditorState :=
            (barredDriver (some shown) typed).map fun driver =>
              (evilFed { driver with keys := handed none } "<Escape>").loop.state
          match barred (some .never) "C-w c", barred (some .always) "<Escape>", kept .never "C-w c",
            kept .always "<Escape>" with
          | some never, some always, some keptNever, some keptAlways =>
            never.tabBarShown == .never && never.tabBarRect? == none &&
              never.tiled == rect 0 0 640 464 &&
              always.tabBarRect? == some (rect 0 448 640 16) &&
              keptNever.tabBarShown == .never &&
              keptNever.frame.tabs.size == 2 &&
              keptNever.tabBarRect? == none &&
              keptAlways.tabBarShown == .always &&
              keptAlways.frame.tabs.size == 1 &&
              keptAlways.tabBarRect? == some (rect 0 448 640 16)
          | _, _, _, _ => false }]

/-- The checks of the window commands (`Editor/WindowCommands.lean`), by
key, on the loop's driver over the editor's models, under the Vim scheme
that ships, with evil's, the minibuffer's, the ex line's and the window
commands handed: Vim 9.1's `C-w` behaviours under the manual split layout,
resizes among them, the reorders, zoom and resizes under master-and-stack,
focus by direction under the three layouts, and the refusals in the echo
area. -/
def windowCommandChecks : List Check :=
  let manual (count : Nat) (typed : String) (focus : Nat := 0) : Option EditorState :=
    windowsAfter count Layout.manual typed focus
  let edged := Layout.edge .left 25 Layout.default
  let floatsOf (state : EditorState) : List Nat := state.frame.floats.toList.map (·.view.index)
  [{  name :=
        "criterion 4, by key: C-w F on a stack window floats it, pinned, centred in the tiled area, focused; C-w F again puts it back at the end of the list; C-w C-w reaches the float and leaves it, which stays; C-w C-c closes it and the focus goes back to the window focused before it"
      run :=
        pure <|
          let after (typed : String) : Option EditorState := windowsAfter 3 Layout.default typed 1
          match after "C-w j C-w F", after "C-w j C-w F C-w F", after "C-w j C-w F C-w C-w",
            after "C-w j C-w F C-w C-w C-w C-w C-w C-w", after "C-w j C-w F C-w C-c" with
          | some floated, some back, some left, some round, some closed =>
            windowOrder floated == ([0, 1], 2) && floatsOf floated == [2] &&
              floated.frame.floats.map (·.pinned) == #[true] &&
              floated.rect? ⟨2⟩ == some { x := 128, y := 116, width := 384, height := 232 } &&
              floated.wellFormed &&
              windowOrder back == ([0, 1, 2], 2) &&
              floatsOf back == [] &&
              windowOrder left == ([0, 1], 0) &&
              floatsOf left == [2] &&
              round.frame.focused == ⟨2⟩ &&
              windowOrder closed == ([0, 1], 1) &&
              floatsOf closed == [] &&
              closed.wellFormed
          | _, _, _, _, _ => false },
    { name :=
        "C-w h from a float reaches the tile wholly left of it; C-w s and C-w o from a float are refused, and the echo area says a floating window is not in the layout; C-w F on the last tile is refused, and the echo area says it cannot leave the tiles"
      run :=
        pure <|
          -- Main is 30 percent wide, and the float narrowed to 10 percent
          -- of 640 is 64 wide at 288, right of main and over the stack.
          let narrow := Layout.masterStack { share := 30 }
          match windowsAfter 3 narrow "C-w F 1 0 C-w < C-w h" 2,
            windowsAfter 2 Layout.default "C-w F C-w s" 1,
            windowsAfter 2 Layout.default "C-w F C-w o" 1,
            windowsAfter 1 Layout.default "C-w F" with
          | some reached, some split, some only, some last =>
            reached.frame.focused == ⟨0⟩ && floatsOf reached == [2] &&
              (reached.frame.floating? ⟨2⟩).map (·.share.width) == some 10 &&
              split.echo ==
                s!"{WindowCommands.splitName}: {(LayoutRefusal.floating ⟨1⟩).describe}" &&
              split.echo == "window-split: a floating window is not in the layout" &&
              only.echo == s!"{WindowCommands.onlyName}: a floating window is not in the layout" &&
              windowOrder only == ([0], 1) &&
              floatsOf only == [1] &&
              last.echo == "window-float: the last tiled window cannot leave the tiles" &&
              windowOrder last == ([0], 0)
          | _, _, _, _ => false },
    { name :=
        "C-w o from main closes every other window, floats among them: a pinned float, and a transient float anchored to a tile that closes with it"
      run :=
        pure <|
          let start : TextM EditorState := do
            let state ← windowsUnder 3 Layout.default
            withFloats { state with frame := { state.frame with chosen := some Layout.default } }
                [(.window ⟨2⟩, false), (.frame, true)]
          match
            (Loop.Driver.over (windowHanded Layout.default) (fun _ => none) start
                (.over { advance := 8, lineHeight := 16 })).toOption with
          | none => false
          | some driver =>
            let only := (evilFed driver "C-w o").loop.state
            windowOrder only == ([0], 0) && floatsOf only == [] && only.windows.size == 1 &&
              only.echo == "" &&
              only.wellFormed },
    { name :=
        "criterion 3, by key: under a layout with a left edge, C-w H docks the window at the left edge, in its strip, focused; C-w l and C-w h move between it and main; C-w C-c closes it and the strip goes; docked again, C-w m makes it main; C-w H again moves it back to the end of the list"
      run :=
        pure <|
          let after (typed : String) : Option EditorState := windowsAfter 2 edged typed 1
          match after "C-w H", after "C-w H C-w l", after "C-w H C-w l C-w h",
            after "C-w H C-w C-c", after "C-w H C-w m", after "C-w H C-w H" with
          | some docked, some right, some left, some closed, some promoted, some back =>
            windowOrder docked == ([0], 1) && docked.frame.docked == #[(⟨1⟩, .left)] &&
              windowRects docked == [(0, 160, 0, 480, 464), (1, 0, 0, 158, 464)] &&
              docked.wellFormed &&
              right.frame.focused == ⟨0⟩ &&
              left.frame.focused == ⟨1⟩ &&
              windowOrder closed == ([0], 0) &&
              closed.frame.docked == #[] &&
              windowRects closed == [(0, 0, 0, 640, 464)] &&
              windowOrder promoted == ([1, 0], 1) &&
              promoted.frame.docked == #[] &&
              windowOrder back == ([0, 1], 1) &&
              back.frame.docked == #[] &&
              windowRects back == [(0, 0, 0, 318, 464), (1, 320, 0, 320, 464)]
          | _, _, _, _, _, _ => false },
    { name :=
        "C-w L under a layout with no right edge is refused, and the echo area says so with the command's name; C-w H on the last tile is refused with lastTile"
      run :=
        pure <|
          match windowsAfter 2 edged "C-w L" 1, windowsAfter 1 edged "C-w H" with
          | some refused, some last =>
            refused.echo == s!"{WindowCommands.edgeRightName}: the layout has no right edge" &&
              windowOrder refused == ([0, 1], 1) &&
              refused.frame.docked == #[] &&
              last.echo == s!"{WindowCommands.edgeLeftName}: {LayoutRefusal.lastTile.describe}" &&
              windowOrder last == ([0], 0)
          | _, _ => false },
    { name :=
        "C-w o from a docked window is refused, as Emacs refuses a side window as the only window, and the echo area says why; from main it closes every other window, the docked one too; C-w b and C-w t reach the docked window and main, and C-w p goes back to the docked window"
      run :=
        pure <|
          let after (typed : String) : Option EditorState := windowsAfter 3 edged typed 2
          match after "C-w H C-w o", after "C-w H C-w l C-w o", after "C-w H C-w t",
            after "C-w H C-w t C-w b", after "C-w H C-w l C-w C-p" with
          | some refused, some only, some top, some bottom, some back =>
            refused.echo == s!"{WindowCommands.onlyName}: {(LayoutRefusal.atEdge ⟨2⟩).describe}" &&
              windowOrder refused == ([0, 1], 2) &&
              refused.frame.docked == #[(⟨2⟩, .left)] &&
              windowOrder only == ([0], 0) &&
              only.frame.docked == #[] &&
              only.wellFormed &&
              top.frame.focused == ⟨0⟩ &&
              bottom.frame.focused == ⟨2⟩ &&
              back.frame.focused == ⟨2⟩
          | _, _, _, _, _ => false },
    { name :=
        "criterion 1, C-w s: two windows on the same buffer with equal markers at first, the new one above and focused, and the windows of the column equal in height; three from one window at 640 by 464 give four rows of 116, the upper three less the divider below them"
      run :=
        pure <|
          let split := (windowDriver 1 Layout.manual).map (evilFed · "C-w s")
          match split, manual 1 "C-w s C-w s C-w s" with
          | some split, some thrice =>
            let state := split.loop.state
            windowOrder state == ([1, 0], 1) &&
              windowRects state == [(1, 0, 0, 640, 230), (0, 0, 232, 640, 232)] &&
              state.windows.all (·.buffer == ⟨0⟩) &&
              evilSelection split ⟨1⟩ == evilSelection split ⟨0⟩ &&
              (evilSelection split ⟨1⟩).isSome &&
              (windowRects thrice).map (·.2.2.2.2) == [114, 114, 114, 116] &&
              thrice.wellFormed
          | _, _ => false },
    { name :=
        "criterion 1, C-w v: the new window on the left and focused; two give three columns equal to a pixel; under a column split, C-w s then C-w v, the heights do not change"
      run :=
        pure <|
          match manual 1 "C-w v", manual 1 "C-w v C-w v", manual 1 "C-w s C-w v" with
          | some once, some twice, some under =>
            windowOrder once == ([1, 0], 1) &&
              windowRects once == [(1, 0, 0, 318, 464), (0, 320, 0, 320, 464)] &&
              windowRects twice ==
                [(2, 0, 0, 211, 464), (1, 213, 0, 211, 464), (0, 426, 0, 214, 464)] &&
              windowRects under ==
                [(2, 0, 0, 318, 230), (1, 320, 0, 320, 230), (0, 0, 232, 640, 232)]
          | _, _, _ => false },
    { name :=
        "criterion 1, C-w C-n (Vim's CTRL-W n): a new window above, focused, on a new empty buffer with no file; the old window keeps its buffer"
      run :=
        pure <|
          match (windowDriver 1 Layout.manual).map (evilFed · "C-w C-n") with
          | none => false
          | some driver =>
            let state := driver.loop.state
            let made := state.window? ⟨1⟩
            windowOrder state == ([1, 0], 1) &&
              windowRects state == [(1, 0, 0, 640, 230), (0, 0, 232, 640, 232)] &&
              (state.window? ⟨0⟩).map (·.buffer) == some ⟨0⟩ &&
              made.any (·.buffer != ⟨0⟩) &&
              (made.bind fun window => state.buffer? window.buffer).any fun buffer =>
                buffer.file.isNone &&
                  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents) == some "" },
    { name :=
        "criterion 1 and 5, C-w C-c (Vim's CTRL-W c): the window leaves the list and the tree, and the windows of its column are equal again; on the last window it is refused, and the echo area says why"
      run :=
        pure <|
          match manual 1 "C-w s C-w s C-w C-c", manual 1 "C-w C-c" with
          | some closed, some last =>
            windowOrder closed == ([1, 0], 1) &&
              windowRects closed == [(1, 0, 0, 640, 230), (0, 0, 232, 640, 232)] &&
              closed.wellFormed &&
              windowOrder last == ([0], 0) &&
              last.echo == s!"{WindowCommands.closeName}: {LayoutRefusal.onlyWindow.describe}"
          | _, _ => false },
    { name :=
        "C-w q: with several windows it closes the window as C-w C-c does; on the last window it asks the editor to quit"
      run :=
        pure <|
          match manual 1 "C-w s C-w q", manual 1 "C-w q" with
          | some closed, some last =>
            windowOrder closed == ([0], 0) && !closed.quitting && last.quitting
          | _, _ => false },
    { name :=
        "C-w o: every other window is closed, and the window it was run in takes the whole tiled area; with one window it says so"
      run :=
        pure <|
          match manual 1 "C-w s C-w v C-w o", manual 1 "C-w o" with
          | some only, some alone =>
            windowOrder only == ([2], 2) && windowRects only == [(2, 0, 0, 640, 464)] &&
              only.wellFormed &&
              alone.echo == WindowCommands.alreadyOnly
          | _, _ => false },
    { name :=
        "criterion 1 and 4, C-w h j k l under manual splits: in a 2 by 2 grid each direction reaches the neighbour and at an edge nothing changes; in a column beside a row, left from the column reaches the top of the row; a count of 2 goes two windows"
      run :=
        pure <|
          let grid :=
            Splits.split .rows 1 1 (.split .columns 1 1 .tile .tile)
              (.split .columns 1 1 .tile .tile)
          let beside := Splits.split .columns 1 1 (.split .rows 1 1 .tile .tile) .tile
          let row := Splits.even .columns 3
          let focus (count : Nat) (tree : Splits) (typed : String) (start : Nat := 0) :
            Option Nat :=
            (windowsAfter count (.splits tree) typed start).map (·.frame.focused.index)
          focus 4 grid "C-w l" == some 1 && focus 4 grid "C-w l C-w j" == some 3 &&
            focus 4 grid "C-w l C-w j C-w h" == some 2 &&
            focus 4 grid "C-w l C-w j C-w h C-w k" == some 0 &&
            focus 4 grid "C-w h C-w k" == some 0 &&
            (windowsAfter 4 (.splits grid) "C-w h").any (·.echo.isEmpty) &&
            focus 3 beside "C-w l" == some 2 &&
            focus 3 beside "C-w h" 2 == some 0 &&
            focus 3 beside "C-w j" == some 1 &&
            focus 3 row "2 C-w l" == some 2 },
    { name :=
        "criterion 1, C-w C-w (Vim's CTRL-W w) and C-w W: the next and the previous window in the tree's order, the last wrapping to the first and the first to the last; with a count, the Nth window"
      run :=
        pure <|
          let focus (typed : String) : Option Nat := (manual 3 typed).map (·.frame.focused.index)
          focus "C-w C-w" == some 1 && focus "C-w C-w C-w C-w C-w C-w" == some 0 &&
            focus "3 C-w C-w" == some 2 &&
            focus "C-w W" == some 2 &&
            focus "2 C-w W" == some 1 },
    { name :=
        "the selected window's mode line follows the focus: from view 0 of three, C-w C-w moves mode-line.active to view 1's row and again to view 2's, and the other two rows are in mode-line.inactive; three more come back to view 0"
      run :=
        pure <|
          let faces (typed : String) : Option (Array (Option FaceName)) :=
            (windowDriver 3 Layout.default).bind fun driver =>
              (evilFed driver typed).model.display.scenes.back?.map (·.views.map (·.statusFace))
          let active := some ModeLine.activeFace
          let inactive := some ModeLine.inactiveFace
          faces "C-w C-w" == some #[inactive, active, inactive] &&
            faces "C-w C-w C-w C-w" == some #[inactive, inactive, active] &&
            faces "C-w C-w C-w C-w C-w C-w" == some #[active, inactive, inactive] },
    { name := "criterion 1, C-w t and C-w b: the first and the last window of the tree's order"
      run :=
        pure <|
          (manual 3 "C-w b").map (·.frame.focused.index) == some 2 &&
            (manual 3 "C-w b C-w t").map (·.frame.focused.index) == some 0 },
    { name :=
        "criterion 1, C-w C-p (Vim's CTRL-W p): after C-w s it goes back to the window split, and again forth; with no last window it is refused, and the echo area says why"
      run :=
        pure <|
          match manual 1 "C-w s C-w C-p", manual 1 "C-w s C-w C-p C-w C-p", manual 1 "C-w C-p" with
          | some back, some forth, some missing =>
            back.frame.focused == ⟨0⟩ && forth.frame.focused == ⟨1⟩ &&
              missing.echo ==
                s!"{WindowCommands.lastName}: {LayoutRefusal.noPreviousWindow.describe}"
          | _, _, _ => false },
    { name :=
        "criterion 1, C-w =: every split back to its slot counts, so a column beside a column gives equal columns, and equal rows in each"
      run :=
        pure <|
          let tree :=
            Splits.split .columns 7 3 (.split .rows 1 4 .tile .tile) (.split .rows 2 1 .tile .tile)
          (windowsAfter 4 (.splits tree) "C-w =").map windowRects ==
            some
              [(0, 0, 0, 318, 230), (1, 0, 232, 318, 232), (2, 320, 0, 320, 230),
                (3, 320, 232, 320, 232)] },
    { name :=
        "C-w x exchanges the window with the next and puts the focus in the other window; C-w r and C-w R rotate a row of windows, the focus staying in its window"
      run :=
        pure <|
          let row := Layout.splits (Splits.even .columns 3)
          (manual 3 "C-w x").map windowOrder == some ([1, 0, 2], 1) &&
            (windowsAfter 3 row "C-w r").map windowOrder == some ([2, 0, 1], 0) &&
            (windowsAfter 3 row "C-w R").map windowOrder == some ([1, 2, 0], 0) },
    { name :=
        "criterion 3, by key under master-and-stack from views 0, 1 and 2 focused on 2: C-w m makes 2 main, C-w M demotes it again, C-w r rotates the stack and C-w R back; C-w z leaves one view in the scene, the focused one, over the tiled area, and C-w z again gives the three views and master-and-stack back"
      run :=
        pure <|
          let after (typed : String) : Option (List Nat × Nat) :=
            (windowsAfter 3 Layout.default typed 2).map windowOrder
          let scene (typed : String) : Option (List (Nat × Rect) × Layout) :=
            (windowDriver 3 Layout.default 2).bind fun driver =>
              let driver := evilFed driver typed
              driver.model.display.scenes.back?.map fun scene =>
                (scene.views.toList.map fun view => (view.id.index, view.rect),
                  driver.loop.state.frame.layout)
          let tiled : Rect := { x := 0, y := 0, width := 640, height := 464 }
          after "C-w m" == some ([2, 0, 1], 2) && after "C-w m C-w M" == some ([0, 2, 1], 2) &&
            after "C-w m C-w M C-w r" == some ([0, 1, 2], 2) &&
            after "C-w m C-w M C-w r C-w R" == some ([0, 2, 1], 2) &&
            scene "C-w z" == some ([(2, tiled)], .monocle) &&
            (scene "C-w z C-w z").map (fun (views, layout) => (views.map (·.1), layout)) ==
              some ([0, 1, 2], Layout.default) },
    { name :=
        "resize by key under master-and-stack: C-w > on main makes the share 55 and on a stack window 45, with a count 60; C-w , and C-w . change main's count"
      run :=
        pure <|
          let layout (typed : String) (focus : Nat := 0) : Option Layout :=
            (windowsAfter 2 Layout.default typed focus).map (·.frame.layout)
          layout "C-w >" == some (.masterStack { share := 55 }) &&
            layout "C-w >" 1 == some (.masterStack { share := 45 }) &&
            layout "2 C-w >" == some (.masterStack { share := 60 }) &&
            layout "C-w <" == some (.masterStack { share := 45 }) &&
            layout "C-w ," == some (.masterStack { count := 2 }) &&
            layout "C-w , C-w ." == some Layout.default },
    { name :=
        "while zoomed, by key: under master-and-stack C-w , leaves the one view shown and C-w z then shows two windows in main, and C-w > then C-w z shows main wider; under manual splits C-w = then C-w z shows the rows balanced"
      run :=
        pure <|
          let rects (layout : Layout) (count : Nat) (typed : String) :
            Option (List (Nat × Nat × Nat × Nat × Nat)) :=
            (windowsAfter count layout typed).map windowRects
          rects Layout.default 3 "C-w z C-w ," == some [(0, 0, 0, 640, 464)] &&
            rects Layout.default 3 "C-w z C-w , C-w z" ==
              some [(0, 0, 0, 318, 230), (1, 0, 232, 318, 232), (2, 320, 0, 320, 464)] &&
            rects Layout.default 2 "C-w z C-w > C-w z" ==
              some [(0, 0, 0, 350, 464), (1, 352, 0, 288, 464)] &&
            rects (.splits (.split .rows 7 3 .tile .tile)) 2 "C-w z C-w = C-w z" ==
              some [(0, 0, 0, 640, 230), (1, 0, 232, 640, 232)] },
    { name :=
        "resize by key under manual splits, after C-w s at 640 by 464: C-w + makes the focused top row 5 percent of the extent taller and C-w - shorter, with a count 10 percent; on the bottom row C-w + grows it and shrinks the top; C-w > in a tree of rows only, and C-w + and C-w - under master-and-stack on the left, are refused, and the echo area says why"
      run :=
        pure <|
          let heights (typed : String) : Option (List Nat) :=
            (manual 1 typed).map fun state => (windowRects state).map (·.2.2.2.2)
          let rowsRefused := (LayoutRefusal.notResizable .rows).describe
          heights "C-w s C-w +" == some [253, 209] && heights "C-w s C-w -" == some [206, 256] &&
            heights "C-w s 2 C-w +" == some [276, 186] &&
            heights "C-w s C-w j C-w +" == some [206, 256] &&
            heights "C-w s C-w j C-w -" == some [253, 209] &&
            (windowsAfter 2 Layout.default "C-w +").map (·.echo) ==
              some s!"{WindowCommands.tallerName}: {rowsRefused}" &&
            (windowsAfter 2 Layout.default "C-w -").map (·.echo) ==
              some s!"{WindowCommands.shorterName}: {rowsRefused}" &&
            match manual 1 "C-w s C-w >" with
            | none => false
            | some wider =>
              (windowRects wider).map (·.2.2.2.2) == [230, 232] &&
                wider.echo ==
                  s!"{WindowCommands.widerName}: {(LayoutRefusal.notResizable .columns).describe}" },
    { name :=
        "criterion 4, by key: under master-and-stack C-w l from main reaches the top of the stack, C-w j walks it and C-w h comes back to main; under monocle no window is in any direction and the focus stays"
      run :=
        pure <|
          let focus (layout : Layout) (typed : String) : Option Nat :=
            (windowsAfter 3 layout typed).map (·.frame.focused.index)
          focus Layout.default "C-w l" == some 1 && focus Layout.default "C-w l C-w j" == some 2 &&
            focus Layout.default "C-w l C-w j C-w h" == some 0 &&
            focus .monocle "C-w l" == some 0 &&
            focus .monocle "C-w j" == some 0 },
    { name :=
        "criterion 6, on the models, over two windows side by side: with no active keymaps C-w in insert state deletes the word before the bar and l after it is text, the view staying in insert state and focused; with active keymaps that bind the window keys, as a config's bindKey binds them, C-w l and C-w h in insert state focus the window on the right and come back without leaving insert state, and typing goes on where it was"
      run :=
        pure <|
          let stateOf (driver : EvilDriver) (view : Nat) : String :=
            (driver.loop.input : Vim.State).stateOf Vim.Default.states ⟨view⟩
          let bound := windowHanded Layout.default (windowMaps Vim.Default.windowKeys)
          match (windowDriver 2 Layout.default).map (evilFed · "i h e l l o SPC w o r l d C-w l"),
            windowDriver 2 Layout.default 0 bound with
          | some plain, some driver =>
            let typed := evilFed driver "i a b C-w l"
            let back := evilFed typed "C-w h"
            let more := evilFed back "c"
            evilText plain == some "hello l" && plain.loop.state.frame.focused == ⟨0⟩ &&
              stateOf plain 0 == "insert" &&
              typed.loop.state.frame.focused == ⟨1⟩ &&
              stateOf typed 0 == "insert" &&
              back.loop.state.frame.focused == ⟨0⟩ &&
              stateOf back 0 == "insert" &&
              evilText more == some "abc" &&
              stateOf more 0 == "insert"
          | _, _ => false },
    { name :=
        "window-close, window-only and window-quit on the minibuffer's view, by a config's binding that holds there, over two windows: each is refused with ofMinibuffer, the echo area says why under the command's name, no window is closed, and the prompt stays open"
      run :=
        pure <|
          let table :=
            [("C-w C-c", WindowCommands.closeName), ("C-w o", WindowCommands.onlyName),
              ("C-w q", WindowCommands.quitName)]
          let refused (typed name : String) : Bool :=
            match
              (windowDriver 2 Layout.manual 0 (windowHanded Layout.manual (windowMaps table))).map
                (evilFed · s!": {typed}") with
            | none => false
            | some driver =>
              let state := driver.loop.state
              state.prompt.isSome && (windowOrder state).1 == [0, 1] && !state.quitting &&
                state.echo == s!"{name}: {(LayoutRefusal.ofMinibuffer ⟨0⟩).describe}"
          table.all fun (typed, name) => refused typed name }]

/-- The checks of a request of the window through the display interface,
on its model. -/
def frameDisplayChecks : List Check :=
  [{  name :=
        "a frame request is recorded by the model in order and changes no answer of rows, a move or the heights"
      run := do
        let query : Display.RowsQuery := { snapshot := ⟨0⟩, width := 2, height := 4, anchor := 0 }
        let move : Display.MoveQuery :=
          { snapshot := ⟨0⟩, width := 2, position := 0, lines := 1, goal := none }
        let ask : DisplayM _ := do
          return (← Display.rowsShown query, ← Display.linesFrom move, ← Display.heights)
        let program : DisplayM _ := do
          Display.askFrame .enterFullscreen
          Display.askFrame .minimise
          let answers ← ask
          Display.askFrame .leaveFullscreen
          return answers
        let (asked, model) := program.runModel (displayOver ["abcd"])
        let (unasked, plain) := ask.runModel (displayOver ["abcd"])
        return asked.toOption == unasked.toOption && asked.toOption.isSome &&
            model.asked == #[.enterFullscreen, .minimise, .leaveFullscreen] &&
            plain.asked.isEmpty &&
            model.scenes.isEmpty }]

/-- The title of the last scene `driver`'s display recorded. -/
def titleOf (driver : TestDriver) : Option String :=
  driver.model.display.scenes.back?.map (·.title)

/-- The checks of the scene's title: the selected buffer's name. -/
def titleChecks : List Check :=
  [{  name :=
        "the scene's title is the selected buffer's name: scratch on the initial state, the file's name once one is opened, and the asking window's buffer's while a prompt is open, not the minibuffer's"
      run :=
        pure <|
          match newDriver, noteOpen, minibufferDriver with
          | some driver, some opened, some asking =>
            let started := (fedTo driver [resizedTo false]).1
            let prompting := (fedTo asking (presses "C-c a")).1
            let minibuffer := do
              let view ← prompting.loop.state.minibufferView?
              let target ← prompting.loop.state.target? view
              return target.buffer.name
            EditorState.title started.loop.state == "scratch" &&
              titleOf started == some "scratch" &&
              titleOf opened == some "note.txt" &&
              prompting.loop.state.prompt.isSome &&
              minibuffer.isSome &&
              minibuffer != some "scratch" &&
              titleOf prompting == some "scratch" &&
              EditorState.title EditorState.none == ""
          | _, _, _ => false }]

/-- The menu bar the frame driver over `registry` publishes once the window
has said its size; `none` without one. -/
def menuShown (registry : Config.Registry) : Option Menu := do
  let driver ← frameDriver registry
  let scene ← (fedTo driver [resizedTo false]).1.model.display.scenes.back?
  scene.menu

/-- The key equivalent of `character` with `modifiers` held, the system key
alone unless told. -/
def equivalent (character : Char) (modifiers : Modifiers := { superKey := true }) :
    Option KeyEquivalent :=
  some { character, modifiers }

/-- The Vim scheme of the menu's run-table checks: the default states, with
normal state's run table holding `t-enter`, run as `visual-line` entering
that state, and `t-fail`, run as itself entering it too. -/
def menuRunScheme : InputScheme :=
  let enter (name : String) : Vim.Edit := .run { name, enters := some "visual-line" } none none
  Vim.scheme
    (Vim.Default.states.register
      { Vim.Default.states.initial with
        runs := [("t-enter", enter "visual-line"), ("t-fail", enter "t-fail")] })

/-- A driver of the menu's run-table checks over the text and cursor
`fixture` says, with evil's commands and `t-fail`, which gives up. -/
def menuRunDriver (fixture : String) : Option (Loop.Driver menuRunScheme) :=
  let (contents, head) := barred fixture
  let fail : Dispatched := fun _ => giveUp "failed"
  let keys : Loop.Keys menuRunScheme :=
    { command? := (evilHanded (commands := [("t-fail", fail)])).command? }
  (Loop.Driver.over keys (fun _ => none) (evilState contents head) editorModel).toOption

/-- The selection of view 0 of `driver`, as the text model has it. -/
def menuRunSelection (driver : Loop.Driver menuRunScheme) : Option Selection := do
  let target ← driver.loop.state.target? ⟨0⟩
  (target.selection.runModel driver.model.texts).1.toOption

/-- The key equivalents the compiled bindings give the menu's commands. -/
def compiledEquivalents : String → Option KeyEquivalent
  | "open-file" => equivalent 'o'
  | "save-buffer" => equivalent 's'
  | "undo" => equivalent 'z'
  | "redo" => equivalent 'Z'
  | "clipboard-cut" => equivalent 'x'
  | "clipboard-copy" => equivalent 'c'
  | "clipboard-paste" => equivalent 'v'
  | "select-all" => equivalent 'a'
  | "minimise-window" => equivalent 'm'
  | "toggle-fullscreen" => equivalent 'f' { control := true, superKey := true }
  | _ => none

/-- The key equivalent `menu`'s item that runs `command` shows; `none` when
no item runs it. -/
def keyShown (menu : Menu) (command : String) : Option (Option KeyEquivalent) :=
  menu.menus.findSome? fun submenu =>
    submenu.items.findSome? fun
      | .item _ key (.command name) => if name == command then some key else none
      | _ => none

/-- The registry of nothing but the binding of `text` to `open-file`. -/
def openBoundTo (text : String) : Config.Registry :=
  ({} : Config.Registry).replaceBindings .compiled #[{ keys := keys text, command := "open-file" }]

/-- The checks of the menu bar (`Editor/Menu.lean`, `Editor/Menu/Compiled.lean`):
a command item chosen runs its command as an invocation, and the key
equivalents the published menu shows are the chords the registry binds. -/
def menuChecks : List Check :=
  [{  name :=
        "a menu's undo undoes as u does: after x over abc, both leave abc and the same selection"
      run :=
        pure <|
          match evilDriver "|abc" with
          | none => false
          | some driver =>
            let cut := evilFed driver "x"
            let byKey := evilFed cut "u"
            let byMenu := (cut.feed { event := .menu "undo", stamp := 0 }).1
            evilShown cut != evilShown byKey && evilShown byMenu == evilShown byKey &&
              (evilShown byKey).replace "|" "" == "abc" &&
              evilSelection byMenu == evilSelection byKey },
    { name :=
        "a menu item naming a command the view's state's run table has an entry for runs that entry, with the report of the state it enters: t-enter in normal state leaves the view in visual-line, its selection of the line shape, at rest; one that gives up leaves the scheme at rest in normal state"
      run :=
        pure <|
          match menuRunDriver "a|b\ncd" with
          | none => false
          | some driver =>
            let initial := menuRunScheme.report menuRunScheme.init ⟨0⟩
            let entered := (driver.feed { event := .menu "t-enter", stamp := 0 }).1
            let failed := (driver.feed { event := .menu "t-fail", stamp := 0 }).1
            let report := menuRunScheme.report entered.loop.input ⟨0⟩
            report.shape == .line && report.selecting &&
              menuRunScheme.report entered.loop.atRest ⟨0⟩ == report &&
              (menuRunSelection entered).map (·.shape) == some .line &&
              entered.loop.state.echo.isEmpty &&
              failed.loop.state.echo == "t-fail: failed" &&
              menuRunScheme.report failed.loop.input ⟨0⟩ == initial &&
              menuRunScheme.report failed.loop.atRest ⟨0⟩ == initial &&
              menuRunSelection failed == menuRunSelection driver },
    { name := "a menu's minimise-window asks the frame to minimise"
      run := pure (framed frameDriver [.menu "minimise-window"] == some (#[.minimise], false)) },
    { name :=
        "a menu runs config's command of its name in place of the compiled one, and a command only config registers"
      run :=
        let replaced :=
          frameRegistry (commands :=
            #[{ name := "minimise-window", action := .plain (Display.askFrame .enterFullscreen) }])
        let greeting :=
          frameRegistry (commands :=
            #[{ name := "greet", action := .plain (Display.askFrame .leaveFullscreen) }])
        pure
          (framed (frameDriver replaced) [.menu "minimise-window"] ==
              some (#[.enterFullscreen], false) &&
            framed (frameDriver greeting) [.menu "greet"] == some (#[.leaveFullscreen], false)) },
    { name :=
        "a menu naming no command says no such command as an invocation does, and asks the frame nothing"
      run :=
        pure <|
          match frameDriver with
          | none => false
          | some driver =>
            let fed := (fedTo driver [.menu "nope"]).1
            fed.loop.state.echo == "nope: no such command" && fed.model.display.asked.isEmpty },
    { name :=
        "a menu, a file to open and the system's quit publish with the padding and the mode line the step's keys carry: views padded 8 across and 8 down, the echo 8, and the status lines the handed segments', whether the command runs to its end or is refused"
      run :=
        let ran : Call → EditorM (Option Config.Write) := fun _ => pure none
        let refused : Call → EditorM (Option Config.Write) := fun _ => throw .badRange
        let handed : Loop.Keys TestScheme.scheme :=
          { padding := 8
            modeLine := { left := #[ModeLine.position], right := #[ModeLine.buffer] }
            command? := fun
              | "noop" => some ran
              | "balk" => some refused
              | name => if name == Files.openName || name == Ex.quitName then some ran else none }
        let status : Array StatusField :=
          #[{ text := "All", face := ModeLine.secondaryFace, padding := 4 },
            { text := "scratch", face := ModeLine.bufferFace, side := .right, padding := 4 }]
        let publishedBy (event : Event) : Bool :=
          match dispatched handed [event] with
          | some (_, #[scene], _) =>
            scene.views.map (·.padding) == #[{ across := 8, down := 8 }] &&
              scene.echoPadding == 8 &&
              scene.views.map (·.status) == #[status]
          | _ => false
        pure
          ([Event.menu "noop", .menu "balk", .openFiles ["a"], .quitRequested].all publishedBy) },
    { name :=
        "on the compiled registry the published menu is the standard one with the chords bound to its commands: s-o, s-s, s-z, s-Z, s-x, s-c, s-v, s-a, s-m and C-s-f, and the system items' own"
      run :=
        pure
          (menuShown frameRegistry == some (Menu.standard.withKeys compiledEquivalents) &&
            ["open-file", "save-buffer", "undo", "redo", "clipboard-cut", "clipboard-copy",
                  "clipboard-paste", "select-all", "minimise-window", "toggle-fullscreen",
                  "nope"].all
              fun name => frameRegistry.keyEquivalent? name == compiledEquivalents name) },
    { name :=
        "the published default menu's Edit menu is Undo, Redo, a separator, Cut, Copy, Paste, a separator and Select All, with the key equivalents s-z, s-Z (s-S-z), s-x, s-c, s-v and s-a"
      run :=
        let edit : Option Submenu :=
          (menuShown frameRegistry).bind fun menu => menu.menus.find? (·.title == "Edit")
        pure
          (edit.map (·.items) ==
            some
              #[.item "Undo" (equivalent 'z') (.command "undo"),
                .item "Redo" (equivalent 'Z') (.command "redo"), .separator,
                .item "Cut" (equivalent 'x') (.command "clipboard-cut"),
                .item "Copy" (equivalent 'c') (.command "clipboard-copy"),
                .item "Paste" (equivalent 'v') (.command "clipboard-paste"), .separator,
                .item "Select All" (equivalent 'a') (.command "select-all")]) },
    { name := "after config binds toggle-fullscreen to M-s-f, Enter Full Screen shows M-s-f"
      run :=
        let rebound :=
          frameRegistry #[{ keys := keys "M-s-f", command := FrameCommands.toggleFullscreenName }]
        let shown := equivalent 'f' { alt := true, superKey := true }
        pure
          (rebound.keyEquivalent? "toggle-fullscreen" == shown &&
            ((menuShown rebound).bind (keyShown · "toggle-fullscreen")) == some shown) },
    { name :=
        "an item whose command has no single chord with the system key shows none: s-o rebound by config to another command, only C-x C-f, only C-o"
      run :=
        let taken := frameRegistry #[{ keys := keys "s-o", command := "save-buffer" }]
        let registries := [taken, openBoundTo "C-x C-f", openBoundTo "C-o"]
        pure <|
          registries.all fun registry =>
            registry.keyEquivalent? "open-file" == none &&
              ((menuShown registry).bind (keyShown · "open-file")) == some none },
    { name :=
        "a chord a system item shows is no command item's, as AppKit runs the system item: config's s-q, s-h or M-s-h alone to save-buffer shows none on Save, and beside the compiled s-s Save shows s-s"
      run :=
        let bound := fun text =>
          ({} : Config.Registry).replaceBindings .config
            #[{ keys := keys text, command := Files.saveName }]
        let beside := frameRegistry #[{ keys := keys "s-q", command := Files.saveName }]
        pure
          (["s-q", "s-h", "M-s-h"].all
              (fun text =>
                ((menuShown (bound text)).bind (keyShown · Files.saveName)) == some none) &&
            ((menuShown beside).bind (keyShown · Files.saveName)) == some (equivalent 's') &&
            (menuShown beside).map (·.systemKeys) == some Menu.standard.systemKeys) }]

/-- The registry of the clipboard command checks: the menu bar's compiled
bindings, for the owner `compiled`, and `config` as config's bindings. -/
def clipRegistry (config : Array Config.KeyBinding := #[]) : Config.Registry :=
  (({} : Config.Registry).replaceBindings .compiled Menu.bindings).replaceBindings .config config

/-- What a step of the clipboard command checks is handed: evil's commands
and the minibuffer's, then `commands`, with the active keymaps and the menu
bar `clipRegistry config` makes, as a host's are. -/
def clipHanded (config : Array Config.KeyBinding := #[])
    (commands : List (String × Dispatched) := []) : Loop.Keys Vim.Default.scheme :=
  let registry := clipRegistry config
  { evilHanded Minibuffer.commands
      commands with
    maps := registry.activeMaps Vim.Default.scheme
    menu := some (registry.menuOf Menu.standard) }

/-- A driver of the clipboard command checks over the text and cursor
`fixture` says, with the unnamed register holding `evilSentinel`, on the
editor's models with the clipboard model `clipboard`, each step handed
`handed`. -/
def clipDriver (fixture : String) (clipboard : ClipboardModel := {})
    (handed : Loop.Keys Vim.Default.scheme := clipHanded) : Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over handed (fun _ => none)
      (do
        return (← evilState contents head).setRegister Evil.unnamed evilSentinel)
      { editorModel with clipboard }).toOption

/-- `driver` once the command `name` was chosen: by pressing the key string
`chord` when `byKey`, and from its menu item otherwise. -/
def clipRan (byKey : Bool) (name chord : String) (driver : EvilDriver) : EvilDriver :=
  if byKey then evilFed driver chord else (driver.feed { event := .menu name, stamp := 0 }).1

/-- What the scheme reports of the focused view of `driver`. -/
def clipReport (driver : EvilDriver) : InputScheme.Report :=
  Vim.Default.scheme.report driver.loop.input driver.loop.state.frame.focused

/-- The keys `typed` pressed from the text and cursor `fixture` says, on the
clipboard model `clipboard`, and then the command `name` chosen by `chord`
when `byKey` and by its menu item otherwise: what they left, the text the
clipboard model then holds, and the scheme's report of the focused
view. -/
def clipLeft (byKey : Bool) (name chord fixture typed : String) (clipboard : ClipboardModel) :
    Option (EvilEdited × Option String × InputScheme.Report) :=
  (clipDriver fixture clipboard).map fun driver =>
    let after := clipRan byKey name chord (evilFed driver typed)
    (evilLeft after, after.model.clipboard.held, clipReport after)

/-- A prompt opened over `a|b` and `A` typed in it, on the clipboard model
`clipboard`, and then the command `name` chosen by `chord` when `byKey` and
by its menu item otherwise: what the minibuffer's view shows, what the asking
view shows, what the echo area says, the text the clipboard model holds,
and whether the prompt is still open. -/
def clipInPrompt (byKey : Bool) (name chord : String) (clipboard : ClipboardModel := {}) :
    Option (String × String × String × Option String × Bool) :=
  let ask : Dispatched := fun _ => do
    discard <| prompt "Name: " { command := "greet" }
    return none
  (clipDriver "a|b" clipboard (clipHanded (commands := [("ask", ask)]))).map fun driver =>
    let (asking, _) := driver.stepped (driver.loop.runNamed driver.handed "ask")
    let after := clipRan byKey name chord (evilFed asking "A")
    (evilShown after ⟨1⟩, evilShown after, after.loop.state.echo, after.model.clipboard.held,
      after.loop.state.prompt.isSome)

/-- Whether `holds` of a command chosen by its chord and of one chosen by
its menu item. -/
def bothWays (holds : Bool → Bool) : Bool :=
  holds true && holds false

/-- What a command that gave up with `reason` says in the echo area, after
its name. -/
def gaveUpSaying (name reason : String) : String :=
  s!"{name}: {reason}"

/-- The checks of the Edit menu's clipboard commands
(`Editor/Evil/Clipboard.lean`): Cut, Copy, Paste and Select All, each by
its chord and by its menu item, in each Vim state, on the loop's driver over
the editor's models with the registry's active keymaps and the clipboard
model. -/
def clipboardCommandChecks : List Check :=
  [{  name :=
        "Copy in visual over part of a line leaves that text in the clipboard model and the view in normal state; in visual-line it leaves the lines, line-wise; in normal state it gives up with nothingSelected in the echo area and the clipboard model holds what it held"
      run :=
        pure <|
          !Evil.nothingSelected.isEmpty &&
            bothWays fun byKey =>
              let copy := clipLeft byKey Evil.copyName "s-c"
              let normal := vimDefaultReport ""
              copy "foo |bar baz" "v l l" { held := some "before" } ==
                  some (⟨"foo |bar baz", charwise "bar", false, ""⟩, some "bar", normal) &&
                copy "ab\nc|d\nef" "V" { held := some "before" } ==
                  some (⟨"ab\n|cd\nef", linewise "cd\n", false, ""⟩, some "cd\n", normal) &&
                copy "foo |bar" "" { held := some "before" } ==
                  some
                    (⟨"foo |bar", asItWas, false, gaveUpSaying Evil.copyName Evil.nothingSelected⟩,
                      some "before", normal) },
    { name :=
        "Cut in visual and visual-line removes the selection, leaves it in the clipboard model, and one u gives back the text; it is one step of the history; in normal state it gives up with nothingSelected and the buffer and the clipboard model are as they were; with a clipboard not available it deletes, keeps the text in the unnamed register and says so"
      run :=
        pure <|
          bothWays fun byKey =>
            let cut := clipLeft byKey Evil.cutName "s-x"
            let normal := vimDefaultReport ""
            let undone (fixture typed : String) : Option (Option (Nat × Bool) × Option String) :=
              (clipDriver fixture).map fun driver =>
                let ran := clipRan byKey Evil.cutName "s-x" (evilFed driver typed)
                (evilHistory ran, evilText (evilFed ran "u"))
            cut "foo |bar baz" "v l l" { held := some "before" } ==
                some (⟨"foo | baz", charwise "bar", false, ""⟩, some "bar", normal) &&
              cut "ab\nc|d\nef" "V" { held := some "before" } ==
                some (⟨"ab\n|ef", linewise "cd\n", false, ""⟩, some "cd\n", normal) &&
              undone "foo |bar baz" "v l l" == some (some (2, false), some "foo bar baz") &&
              undone "ab\nc|d\nef" "V" == some (some (2, false), some "ab\ncd\nef") &&
              cut "foo |bar" "" { held := some "before" } ==
                some
                  (⟨"foo |bar", asItWas, false, gaveUpSaying Evil.cutName Evil.nothingSelected⟩,
                    some "before", normal) &&
              cut "foo |bar baz" "v l l" { available := false } ==
                some
                  (⟨"foo | baz", charwise "bar", false, Evil.clipboardUnavailable⟩, none, normal) },
    { name :=
        "Cut in visual replaces the last change, as \" + d does: after an x, a . after it leaves what a . after \" + d leaves (a change over a selection, not repeated), not a second x; a . after a Copy repeats the x, as a . after \" + y does"
      run :=
        pure <|
          bothWays fun byKey =>
            let repeated (chord name : String) : Option (EvilEdited × Option String) :=
              (clipDriver "foo |bar bar bar").map fun driver =>
                let after := evilFed (clipRan byKey name chord (evilFed driver "x v l l")) "."
                (evilLeft after, after.model.clipboard.held)
            let cut := repeated "s-x" Evil.cutName
            let copied := repeated "s-c" Evil.copyName
            cut.isSome && cut == evilClipped "foo |bar bar bar" "x v l l \" + d ." &&
              (cut.map fun left =>
                  (left.1.shown, left.1.echo.endsWith (Evil.notRepeated Evil.overSelection))) ==
                some ("foo |bar bar", true) &&
              copied.isSome &&
              copied == evilClipped "foo |bar bar bar" "x v l l \" + y ." &&
              (copied.map (·.1.shown)) == some "foo |r bar bar" },
    { name :=
        "Paste called with a report that is not exclusive, in no state whose run table has an entry for it, puts the clipboard's text before the cursor, as \" + P does, and leaves the clipboard model as it was"
      run :=
        pure <|
          let pasting : Dispatched := fun call => do
            Evil.paste { call with report := { call.report with shape := .inclusive } }
            return none
          let pasted (fixture : String) (held : String) : Option (EvilEdited × Option String) :=
            (clipDriver fixture { held := some held }
                  (clipHanded (commands := [("t-paste", pasting)]))).map
              fun driver =>
              let (after, _) := driver.stepped (driver.loop.runNamed driver.handed "t-paste")
              (evilLeft after, after.model.clipboard.held)
          pasted "a|b" "XY" == evilClipped "a|b" "\" + P" { held := some "XY" } &&
            (pasted "a|b" "XY").map (fun left => (left.1.shown, left.2)) ==
              some ("aX|Yb", some "XY") &&
            (pasted "a|b\n" "cd\n").map (fun left => (left.1.shown, left.2)) ==
              some ("|cd\nab\n", some "cd\n") },
    { name :=
        "Paste puts the clipboard's text before the cursor in normal state (as \" + P), in place of the selection in visual and visual-line, and at the bar as typed text in insert state and in the minibuffer"
      run :=
        pure <|
          bothWays fun byKey =>
            let paste := clipLeft byKey Evil.pasteName "s-v"
            let held : ClipboardModel := { held := some "XY" }
            (paste "a|b" "" held).map (·.1) == (evilClipped "a|b" "\" + P" held).map (·.1) &&
              (paste "a|b" "" held).map (·.1.shown) == some "aX|Yb" &&
              (paste "a|bcd" "v l" held).map (·.1.shown) == some "aX|Yd" &&
              (paste "ab\nc|d\nef" "V" held).map (·.1.shown) == some "ab\n|XY\nef" &&
              paste "a|b" "i" held ==
                some (⟨"aXY|b", asItWas, true, ""⟩, some "XY", vimDefaultReport "i") &&
              clipInPrompt byKey Evil.pasteName "s-v" held ==
                some ("AXY|", "a|b", "", some "XY", true) },
    { name :=
        "after a Paste in each of normal, visual, visual-line, insert and minibuffer the clipboard model holds what it held before, and in the visual states the replaced text is in the unnamed register and not the clipboard, and the view is in normal state"
      run :=
        pure <|
          bothWays fun byKey =>
            let paste := clipLeft byKey Evil.pasteName "s-v"
            let held : ClipboardModel := { held := some "XY" }
            let normal := vimDefaultReport ""
            (paste "a|b" "" held).map (fun left => (left.1.register, left.2)) ==
                some (asItWas, (some "XY", normal)) &&
              (paste "a|bcd" "v l" held).map (fun left => (left.1.register, left.2)) ==
                some (charwise "bc", (some "XY", normal)) &&
              (paste "ab\nc|d\nef" "V" held).map (fun left => (left.1.register, left.2)) ==
                some (linewise "cd\n", (some "XY", normal)) &&
              (paste "a|b" "i" held).map (·.2.1) == some (some "XY") &&
              (clipInPrompt byKey Evil.pasteName "s-v" held).map (·.2.2.2.1) == some (some "XY") },
    { name :=
        "Paste with a clipboard model holding no text gives up with nothingToPut, and with one not available with clipboardUnavailable, in normal, a visual state and insert state, and leaves the buffer as it was"
      run :=
        pure <|
          bothWays fun byKey =>
            let refused (fixture typed shown : String) (clipboard : ClipboardModel)
              (reason : String) : Bool :=
              match clipLeft byKey Evil.pasteName "s-v" fixture typed clipboard with
              | some (left, _, _) =>
                left.shown == shown && left.register == none && left.echo.endsWith reason &&
                  (left.echo.splitOn "refused").length == 1
              | none => false
            [("a|b", "", "a|b"), ("a|bcd", "v l", "ab|cd"), ("a|b", "i", "a|b")].all
              fun (fixture, typed, shown) =>
              refused fixture typed shown {} Evil.nothingToPut &&
                refused fixture typed shown { available := false } Evil.clipboardUnavailable },
    { name :=
        "Select All from normal and from insert state leaves the view in visual-line with one range from offset 0 to the first non-blank of the last line, the cursor on the last line; from visual too"
      run :=
        pure <|
          bothWays fun byKey =>
            let all (fixture typed : String) :
              Option (Option Selection × InputScheme.Report × String) :=
              (clipDriver fixture).map fun driver =>
                let after := clipRan byKey Evil.selectAllName "s-a" (evilFed driver typed)
                (evilSelection after, clipReport after, after.loop.state.echo)
            let lines (anchor head : Nat) :
              Option (Option Selection × InputScheme.Report × String) :=
              some (some { ranges := #[⟨anchor, head⟩], shape := .line }, vimDefaultReport "V", "")
            all "a|b\ncd\n  ef" "" == lines 0 8 && all "a|b\ncd\n  ef" "i" == lines 0 8 &&
              all "ab\nc|d\n" "" == lines 0 3 &&
              all "a|b\ncd" "v" == lines 0 3 &&
              all "a|b\ncd" "V" == lines 0 3 },
    { name :=
        "s-x, s-c, s-v and s-a run the four commands in normal, insert, visual, visual-line and the minibuffer (each leaves what that command leaves there, or its refusal names it), and config's binding of s-c to another command runs that command instead, with the clipboard model as it was"
      run :=
        pure <|
          let greet : Dispatched := fun _ => do
            message "hello"
            return none
          let rebound := clipHanded #[{ keys := keys "s-c", command := "greet" }] [("greet", greet)]
          let overridden :=
            (clipDriver "foo |bar baz" { held := some "before" } rebound).map fun driver =>
              let after := evilFed driver "v l l s-c"
              (evilLeft after, after.model.clipboard.held, clipReport after)
          overridden ==
              some
                (⟨"foo ba|r baz", asItWas, false, "hello"⟩, some "before", vimDefaultReport "v") &&
            bothWays fun byKey =>
              let insertRefused (name chord reason : String) : Bool :=
                (clipLeft byKey name chord "a|b" "i" { held := some "before" }).map
                    (fun left => (left.1.shown, left.1.echo, left.2.1)) ==
                  some ("a|b", gaveUpSaying name reason, some "before")
              insertRefused Evil.copyName "s-c" Evil.nothingSelected &&
                insertRefused Evil.cutName "s-x" Evil.nothingSelected &&
                clipInPrompt byKey Evil.copyName "s-c" { held := some "before" } ==
                  some
                    ("A|", "a|b", gaveUpSaying Evil.copyName Evil.nothingSelected, some "before",
                      true) &&
                clipInPrompt byKey Evil.cutName "s-x" { held := some "before" } ==
                  some
                    ("A|", "a|b", gaveUpSaying Evil.cutName Evil.nothingSelected, some "before",
                      true) &&
                clipInPrompt byKey Evil.selectAllName "s-a" ==
                  some
                    ("A|", "a|b", gaveUpSaying Evil.selectAllName Evil.noLineSelection, none,
                      true) &&
                (clipLeft byKey Evil.copyName "s-c" "a|b\ncd" "V j" {}).map (·.2.1) ==
                  some (some "ab\ncd\n") },
    { name :=
        "a Cut or Copy refused (nothing selected) or stopped by the interrupt before any one of its requests leaves the clipboard model as it was, and a refused or stopped Cut leaves the buffer as it was"
      run :=
        pure <|
          let swept (byKey : Bool) (name chord : String) (whole : EvilEdited × Option String) :
            Bool :=
            match clipDriver "foo |bar baz" { held := some "before" } with
            | none => false
            | some driver =>
              let selected := evilFed driver "v l l"
              let ran (asks : Option Nat) : EvilEdited × Option String :=
                let after :=
                  clipRan byKey name chord
                    { selected with
                      model :=
                        { selected.model with
                          watch := { selected.model.watch with arrivesAfter := asks } } }
                (evilLeft after, after.model.clipboard.held)
              let stopped : EvilEdited × Option String :=
                (⟨"foo ba|r baz", asItWas, false, s!"{Vim.operateCommand}: interrupted"⟩,
                  some "before")
              let runs := (List.range 80).map fun asks => ran (some asks)
              ran none == whole && runs.all (fun run => run == stopped || run == whole) &&
                (runs.filter (· == stopped)).length > 4 &&
                runs.getLast? == some whole
          swept true Evil.cutName "s-x" (⟨"foo | baz", charwise "bar", false, ""⟩, some "bar") &&
            swept false Evil.copyName "s-c"
              (⟨"foo |bar baz", charwise "bar", false, ""⟩, some "bar") &&
            bothWays fun byKey =>
              [(Evil.cutName, "s-x"), (Evil.copyName, "s-c")].all fun (name, chord) =>
                (clipLeft byKey name chord "foo |bar" "" { held := some "before" }).map
                    (fun left => (left.1.shown, left.2.1)) ==
                  some ("foo |bar", some "before") }]

end ModelTest
