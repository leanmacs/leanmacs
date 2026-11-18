import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Contribution
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Completion.Display
import Editor.Completion.Displays
import Editor.Completion.Styles
import Editor.Config.Registry
import Editor.Config.Stores
import Editor.Display
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Evil.Undo
import Editor.Ex.Line
import Editor.File
import Editor.Files
import Editor.Floating
import Editor.GeneratedView
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Loop.Driver
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Program
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.TabBar
import Editor.Text
import Editor.Text.Contract
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Workspace
import ModelTest.Check
import ModelTest.Support.Completion
import ModelTest.Support.Driver
import ModelTest.Support.Evil
import ModelTest.Support.Excerpt
import ModelTest.Support.Files
import ModelTest.Support.Frame
import ModelTest.Support.Geometry
import ModelTest.Support.Keys
import ModelTest.Support.Loop
import ModelTest.Support.Models
import ModelTest.Support.Prompts
import ModelTest.Support.States
import ModelTest.Support.Views
import ModelTest.Support.Workspace

/-!
# Model tests: `Editor/State.lean`

The model tests of `Editor/State.lean`: `windowOperationChecks`,
`floatingWindowChecks`, `stateChecks`, `tabChecks`, `paddingChecks`,
`heightChecks`, `titleChecks`, `readOnlyChecks`, `excerptBufferChecks`,
`displayStateChecks` and `atPointStateChecks`.
`readOnlyChecks` and `excerptBufferChecks` also cover
`Editor/Command/Dispatch.lean`, and `paddingChecks`, `heightChecks` and
`titleChecks` read the state through the loop; each is here because what it pins
is the state's. The root module `ModelTest` runs them; its module doc says what
each shows.
-/

namespace ModelTest

open Editor

/-- The views of `state`'s frame and their rectangles, in drawing order
(`EditorState.rects`). -/
def laidOut (state : EditorState) : Array (ViewId × Rect) :=
  state.rects

/-- Ways to spoil `threeWindows`, each breaking one layout invariant and
keeping every other clause of `EditorState.wellFormed`, with what the state
is then. So each is refused by one clause alone, and a `wellFormed` without
that clause would accept it. -/
def spoilings : List (String × (EditorState → EditorState)) :=
  let withWindows (windows : Array ViewId) (state : EditorState) : EditorState :=
    { state with frame := { state.frame with windows } }
  let withWindow (id : ViewId) (change : Window → Window) (state : EditorState) : EditorState :=
    { state with windows := state.windows.map fun was => if was.id == id then change was else was }
  [("whose focused window is not in the list", fun state =>
      { state with frame := { state.frame with focused := ⟨7⟩ } }),
    ("whose list names one window twice, with as many entries as there are windows",
      withWindows #[⟨0⟩, ⟨1⟩, ⟨1⟩]),
    ("whose list names a window there is none of, with as many entries as there are windows",
      withWindow ⟨2⟩ ({ · with id := ⟨7⟩ })),
    ("with a window that is not in the list", withWindows #[⟨0⟩, ⟨1⟩]),
    ("with a window whose buffer does not exist", withWindow ⟨1⟩ ({ · with buffer := ⟨5⟩ })),
    ("with a prompt whose view has no window", fun state =>
      { state with
        prompt := some { label := "", view := ⟨7⟩, asker := ⟨0⟩, continuation := asked } }),
    ("with a prompt whose view is also a window of the list", fun state =>
      { state with
        prompt := some { label := "", view := ⟨2⟩, asker := ⟨0⟩, continuation := asked } }),
    ("with a prompt whose choice is past its listing", fun state =>
      let (_, asking) := state.openPrompt "" asked ⟨7⟩ (UndoTree.new ⟨7⟩ 0) ⟨⟨7⟩, 0⟩ ⟨⟨7⟩, 1⟩
      { asking with
        prompt :=
          asking.prompt.map
            ({ · with
              candidates :=
                { all := offered #["a"], listedFor := some ""
                  listed := (offered #["a"]).map Completion.Listed.of, chosen := some 1 } }) }),
    ("with an order of use that names a buffer there is none of", fun state =>
      { state with recent := state.recent.push ⟨5⟩ }),
    ("with an order of use that names one buffer twice", fun state =>
      { state with recent := state.recent ++ state.recent }),
    ("whose manual split tree has fewer tiles than the list has windows", fun state =>
      { state with
        frame := { state.frame with layout := .splits (.split .rows 1 1 .tile .tile) } }),
    ("whose layout to return to from a zoom has fewer tiles than the list has windows", fun state =>
      { state with
        frame :=
          { state.frame with
            layout := .monocle, zoomedFrom := some (.splits .tile) } }),
    ("with a window docked at a side the layout has no edge for", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩], docked := #[(⟨2⟩, .left)] } }),
    ("with a float anchored to a window not in the frame", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩], floats := #[{ view := ⟨2⟩, anchor := .window ⟨7⟩ }] } }),
    ("with a float anchored to a float", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩]
            floats :=
              #[{ view := ⟨1⟩, anchor := .frame }, { view := ⟨2⟩, anchor := .window ⟨1⟩ }] } }),
    ("with a float anchored at a marker of another text than its window's buffer's", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩]
            floats := #[{ view := ⟨2⟩, anchor := .position ⟨0⟩ ⟨⟨5⟩, 0⟩ }] } }),
    ("with a hidden tab whose tiled list is empty", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩]
            tabsAfter :=
              #[{ windows := #[], floats := #[{ view := ⟨2⟩, anchor := .frame }]
                  focused := ⟨2⟩ }] } }),
    ("with a hidden tab whose focus is not one of its windows", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩], tabsAfter := #[{ windows := #[⟨2⟩], focused := ⟨0⟩ }] } }),
    ("with one window listed in two tabs, with as many entries as there are windows", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩], tabsBefore := #[{ windows := #[⟨1⟩], focused := ⟨1⟩ }] } }),
    ("with a hidden tab whose manual split tree does not fit its list", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩, ⟨1⟩]
            tabsAfter :=
              #[{ windows := #[⟨2⟩], focused := ⟨2⟩
                  layout := .splits (.split .rows 1 1 .tile .tile) }] } }),
    ("with a hidden tab's float anchored to a window of the tab in view", fun state =>
      { state with
        frame :=
          { state.frame with
            windows := #[⟨0⟩]
            tabsAfter :=
              #[{ windows := #[⟨1⟩], floats := #[{ view := ⟨2⟩, anchor := .window ⟨0⟩ }]
                  focused := ⟨1⟩ }] } }),
    ("with a tab bar whose view is a window's", fun state =>
      { state with
        tabBar := some { view := ⟨2⟩, text := ⟨9⟩, scroll := ⟨⟨9⟩, 0⟩, content := "" } })]

/-- `state` with its open prompt's choice moved by each of `steps`, and the
display asked after each, as the loop's publishes would. -/
def choseShown (state : EditorState) (steps : List Candidates.Step)
    (displaying : Completion.Displaying := .standard) : EditorState :=
  steps.foldl (fun state step => (state.chooseCandidate step).2.displayed displaying) state

/-- The texts of the rows of the sheet the open prompt of `state` keeps. -/
def sheetTexts (state : EditorState) : Array String :=
  (state.prompt.map fun asked => asked.sheet.rows.map (·.text)).getD #[]

/-- The checks of the candidate list in the state (`Editor/State.lean`,
"The minibuffer's place" and "Prompts"): what the display answered kept on
the prompt, the window round the choice, the place that grows and never
shrinks while the prompt is open, its strip cut into the list's part and
the minibuffer view's, and the list's view's rectangle and padding. -/
def displayStateChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let texts := (Array.range 15).map (s!"c{·}")
  let drawn : GeneratedView := { view := ⟨90⟩, text := ⟨90⟩, scroll := ⟨⟨90⟩, 0⟩, content := "" }
  [{  name :=
        "moving the choice past the last row shown scrolls the list so the chosen candidate stays shown"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let listing := (listingIn (prompted state).2 texts (Array.range 15)).displayed .standard
            let down := choseShown listing (List.replicate 11 .next)
            let up := choseShown down (List.replicate 10 .previous)
            let last := choseShown listing [.previous]
            let first (state : EditorState) : Option Nat := state.prompt.map (·.candidates.first)
            first listing == some 0 && sheetTexts listing == texts.extract 0 10 &&
              first down == some 1 &&
              sheetTexts down == texts.extract 1 11 &&
              (down.prompt.bind (·.sheet.rows.back?)).bind (·.decorations[0]?) ==
                some { start := 0, stop := 3, face := Completion.Displays.chosenFace } &&
              first up == some 0 &&
              sheetTexts up == texts.extract 0 10 &&
              last.prompt.bind (·.candidates.chosen) == some 14 &&
              first last == some 5 },
    { name := "the place grows and never shrinks while the prompt is open"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let five := (listingIn (prompted state).2 texts (Array.range 5)).displayed .standard
            let two := ((five.listCandidates "c1" #[.ofIndex 1, .ofIndex 10]).2).displayed .standard
            let seven :=
              ((two.listCandidates "c" ((Array.range 7).map .ofIndex)).2).displayed .standard
            let twelve :=
              ((seven.listCandidates "" ((Array.range 12).map .ofIndex)).2).displayed .standard
            let (_, closed) := twelve.closePrompt none
            let (_, again) := prompted closed 8
            let tallest (state : EditorState) : Option Nat := state.prompt.map (·.tallest)
            let heights := five.heights
            tallest five == some 5 &&
              five.minibufferPlace == 5 * heights.text + heights.text + heights.message &&
              sheetTexts two == #["c1", "c10"] &&
              tallest two == some 5 &&
              two.minibufferPlace == five.minibufferPlace &&
              two.candidateListRect? == five.candidateListRect? &&
              two.tiled == five.tiled &&
              tallest seven == some 7 &&
              tallest twelve == some Completion.Displays.rows &&
              closed.minibufferPlace == heights.message &&
              closed.candidateListRect? == none &&
              tallest again == some 0 &&
              again.candidateListRect? == none },
    { name :=
        "with three rows listed at 640 by 480 the place is the rows, the input and the bottom row; the tiled area is shorter by the rows; the minibuffer's view is at the strip's bottom, the input and the bottom row tall, and the list's directly above it, with the list view's rectangle and padding"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let three :=
              { (listingIn asking texts (Array.range 3)).displayed .standard with
                candidateList := some drawn }
            let heights := three.heights
            let strip := 3 * heights.text + heights.text + heights.message
            let below := heights.text + heights.message
            let minibuffer := (three.minibufferView?.bind three.rect?)
            three.listRows == 3 && three.minibufferPlace == strip &&
              three.tiled == rect 0 0 640 (480 - strip) &&
              asking.tiled == rect 0 0 640 (480 - below) &&
              minibuffer == some (rect 0 (480 - below) 640 below) &&
              three.candidateListRect? == some (rect 0 (480 - strip) 640 (3 * heights.text)) &&
              three.cutStrip ==
                (rect 0 (480 - strip) 640 (3 * heights.text), rect 0 (480 - below) 640 below) &&
              three.rect? drawn.view == three.candidateListRect? &&
              three.isCandidateList drawn.view &&
              !three.isCandidateList ⟨0⟩ &&
              three.paddingOf drawn.view == { across := three.bottomInset, down := 0 } &&
              asking.listRows == 0 &&
              asking.candidateListRect? == none },
    { name :=
        "a frame shorter than the strip cuts the list before the input: at 640 by 40 the list keeps what the input and the bottom row leave, and at 640 by 20 it is 0 tall"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 40⟩),
            onTextModel (EditorState.initial ⟨640, 20⟩) with
          | some tall, some short =>
            let listed (state : EditorState) : EditorState :=
              (listingIn (prompted state).2 texts (Array.range 5)).displayed .standard
            let tall := listed tall
            let short := listed short
            let below := tall.heights.text + tall.heights.message
            tall.tiled.height == 0 && tall.candidateListRect? == some (rect 0 0 640 (40 - below)) &&
              (tall.minibufferView?.bind tall.rect?) == some (rect 0 (40 - below) 640 below) &&
              short.candidateListRect? == some (rect 0 0 640 0) &&
              (short.minibufferView?.bind short.rect?) == some (rect 0 0 640 20)
          | _, _ => false },
    { name :=
        "relisting keeps where the window starts for the same text and starts it at 0 for another, and a listing says whether it holds two groups"
      run :=
        pure <|
          let candidates : Candidates :=
            { all := #[{ text := "a", group := some "A" }, { text := "b", group := some "B" }]
              listedFor := some "", first := 3 }
          let listed := #[Completion.Listed.of { text := "a", group := some "A" }]
          (candidates.relist "" 1 listed).first == 3 &&
            (candidates.relist "x" 1 listed).first == 0 &&
            !(candidates.relist "" 1 listed).grouped &&
            (candidates.list "" #[.ofIndex 0, .ofIndex 1]).grouped &&
            (candidates.list "" #[.ofIndex 0, .ofIndex 1]).first == 0 &&
            !(candidates.list "" #[.ofIndex 0]).grouped },
    { name :=
        "the state is well formed with the candidate list drawn, and not once the list's view is a window's"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let listing := (listingIn (prompted state).2 texts (Array.range 3)).displayed .standard
            { listing with candidateList := some drawn }.wellFormed &&
              !{ listing with candidateList := some { drawn with view := ⟨0⟩ } }.wellFormed },
    { name := "displaying with no prompt open leaves the state as it was"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state => state.displayed .standard == state }]

/-- States of the quit checks, each `twoBuffers` with its histories set by
hand. -/
structure QuitStates where
  /-- The scratch buffer, which holds no file, is modified. -/
  bare : EditorState
  /-- And the buffer `other` holds a file and is modified. -/
  held : EditorState
  /-- And a save of `other` is in flight, writing the state its text is
  in. -/
  saving : EditorState
  /-- And `other` was edited since that save began. -/
  moved : EditorState
  /-- The save of `saving` ended with a stamp: `other` is saved. -/
  saved : EditorState

/-- The states of the quit checks. The operations ask the text store
nothing, so a revision and a snapshot's id are written out by hand. -/
def quitStates : TextM QuitStates := do
  let state ← twoBuffers
  let stamp : File.Stamp := { seconds := 3, nanoseconds := 0, size := 9 }
  let edited := (UndoTree.new ⟨1⟩ 0).record 3
  let (_, bare) := state.setHistory ⟨0⟩ ((UndoTree.new ⟨0⟩ 0).record 2)
  let (_, held) := bare.attachFile ⟨1⟩ "/files/note.txt" stamp .lf
  let (_, held) := held.setHistory ⟨1⟩ edited
  let (_, saving) := held.beginSave ⟨1⟩ ⟨5⟩ edited.state
  let (_, moved) := saving.setHistory ⟨1⟩ (edited.record 4)
  let (_, saved) := saving.endSave ⟨1⟩ ⟨5⟩ (some stamp)
  return { bare, held, saving, moved, saved }

/-- The tiled list, the floats and the focus `state` is left with by a
change that was not refused, when it is well formed; none otherwise. -/
def floatedTo (result : Except LayoutRefusal Unit × EditorState) :
    Option (List Nat × List Nat × Nat) :=
  match result with
  | (.ok (), after) =>
    if after.wellFormed then
      some
        (after.frame.windows.toList.map (·.index), after.frame.floats.toList.map (·.view.index),
          after.frame.focused.index)
    else none
  | (.error _, _) => none

/-- The tiled list, the docked windows and the focus `state` is left with
by a change that was not refused, when it is well formed; none
otherwise. -/
def dockedTo (result : Except LayoutRefusal Unit × EditorState) :
    Option (List Nat × List (Nat × Side) × Nat) :=
  match result with
  | (.ok (), after) =>
    if after.wellFormed then
      some
        (after.frame.windows.toList.map (·.index),
          after.frame.docked.toList.map fun (view, side) => (view.index, side),
          after.frame.focused.index)
    else none
  | (.error _, _) => none

/-- The window list and the focus `state` is left with by a change that
was not refused; none for a refused one. -/
def arrangedTo (result : Except LayoutRefusal Unit × EditorState) : Option (List Nat × Nat) :=
  match result with
  | (.ok (), after) => some (after.frame.windows.toList.map (·.index), after.frame.focused.index)
  | (.error _, _) => none

/-- Whether `rect` lies wholly on `side` of `start` and overlaps it across:
for `left`, its right edge is at or before the start's left edge, and the
two vertical spans overlap. -/
def lies (side : Side) (start rect : Rect) : Bool :=
  let acrossRows := rect.y < start.y + start.height && start.y < rect.y + rect.height
  let acrossColumns := rect.x < start.x + start.width && start.x < rect.x + rect.width
  match side with
  | .left => rect.x + rect.width ≤ start.x && acrossRows
  | .right => start.x + start.width ≤ rect.x && acrossRows
  | .top => rect.y + rect.height ≤ start.y && acrossColumns
  | .bottom => start.y + start.height ≤ rect.y && acrossColumns

/-- The sample states of the direction property: one to five windows under
master-and-stack with main on the left and with two main windows on top,
under monocle, and under every manual split tree reached by up to three
splits and five even columns; and one to four tiles with none to two
windows docked at an edge, under a left edge round master-and-stack, a
right edge round a bottom edge round manual splits, and a top edge round
monocle; each with no float, with a transient float anchored to the frame,
and with a pinned one and a transient one anchored to view 0 on top of it,
and each of those also with a prompt open. -/
def directionStates : List EditorState :=
  let layouts : List (Nat × Layout) :=
    (List.range 5).flatMap
        (fun index =>
          [(index + 1, Layout.default), (index + 1, .masterStack { side := .top, count := 2 }),
            (index + 1, .monocle)]) ++
      (splitsReached 3).map (fun tree => (tree.size, .splits tree)) ++
      [(5, .splits (Splits.even .columns 5))]
  let edged : List (Nat × List Side × Layout) :=
    (List.range 4).flatMap fun index =>
      [[], [Side.left], [.left, .left]].map
          (fun docked => (index + 1, docked, Layout.edge .left 25 Layout.default)) ++
        [[], [Side.right], [.bottom], [.right, .bottom]].map
          (fun docked => (index + 1, docked, .edge .right 30 (.edge .bottom 20 Layout.manual))) ++
        [[Side.top], [.top, .top]].map fun docked => (index + 1, docked, .edge .top 25 .monocle)
  let withPrompt (made : Option EditorState) : List EditorState :=
    match made with
    | none => []
    | some state =>
      let floated :=
        [[], [(Floating.Anchor.frame, false)], [(.frame, true), (.window ⟨0⟩, false)]].filterMap
          fun floats => onTextModel (withFloats state floats)
      floated.flatMap fun state => [state, (prompted state).2]
  layouts.flatMap (fun (count, layout) => withPrompt (onTextModel (windowsUnder count layout))) ++
    edged.flatMap fun (tiles, docked, layout) =>
      withPrompt (onTextModel (dockedUnder tiles docked layout))

/-- The checks of the operations on the frame's windows that the window
commands are made of (`Editor/State.lean`): a split's placement, a
removal's inheritor under manual splits, zoom, the last window focused,
the reorders and the parameter changes of `EditorState.arrange`, focus by
direction (`EditorState.toward?`) and in list order (`cycled`), and what a
refusal says. -/
def windowOperationChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let marker (index : Nat) : MarkerId := ⟨⟨0⟩, index⟩
  let ids (indices : List Nat) : Array ViewId := indices.toArray.map (⟨·⟩)
  [{  name :=
        "under manual splits a split puts the new window before its source when the placement says before, and after it otherwise, splits the source's tile along the placement's axis and balances the tree along it; the focus stays; under master-and-stack the placement is ignored and the new window goes right after its source"
      run :=
        pure <|
          match onTextModel (windowsUnder 1 Layout.manual),
            onTextModel (windowsUnder 2 Layout.default) with
          | some one, some two =>
            (match one.splitWindow ⟨0⟩ (marker 8) (marker 9) { before := true } with
              | (.ok made, after) =>
                made == ⟨1⟩ && after.frame.windows == ids [1, 0] &&
                  after.frame.layout == .splits (.split .rows 1 1 .tile .tile) &&
                  after.frame.focused == ⟨0⟩ &&
                  after.rects == #[(⟨1⟩, rect 0 0 640 230), (⟨0⟩, rect 0 232 640 232)] &&
                  after.wellFormed
              | _ => false) &&
              (match one.splitWindow ⟨0⟩ (marker 8) (marker 9) { axis := .columns } with
              | (.ok _, after) =>
                after.frame.windows == ids [0, 1] &&
                  after.frame.layout == .splits (.split .columns 1 1 .tile .tile) &&
                  after.rects == #[(⟨0⟩, rect 0 0 318 464), (⟨1⟩, rect 320 0 320 464)]
              | _ => false) &&
              match
                two.splitWindow ⟨0⟩ (marker 8) (marker 9) { axis := .columns, before := true } with
              | (.ok made, after) =>
                made == ⟨2⟩ && after.frame.windows == ids [0, 2, 1] &&
                  after.frame.layout == Layout.default &&
                  after.wellFormed
              | _ => false
          | _, _ => false },
    { name :=
        "under manual splits removing a focused window moves the focus to the window that inherits its place, the first of the next part of its group or the last of the previous part, and balances the tree along the group's axis"
      run :=
        pure <|
          let removedFrom (tree : Splits) (focus gone : Nat) : Option (Nat × Layout) :=
            match onTextModel (windowsUnder tree.size (.splits tree)) with
            | none => none
            | some state =>
              match (state.focusWindow ⟨focus⟩).2.removeWindow ⟨gone⟩ with
              | (.ok _, after) =>
                if after.wellFormed then some (after.frame.focused.index, after.frame.layout)
                else none
              | _ => none
          let three := Splits.split .columns 1 1 (.split .rows 1 1 .tile .tile) .tile
          let nested := Splits.split .rows 1 1 (.split .rows 1 1 .tile .tile) .tile
          let weighted :=
            Splits.split .columns 1 1 (.split .rows 1 1 .tile .tile) (.split .rows 5 1 .tile .tile)
          removedFrom three 1 1 == some (0, .splits (.split .columns 1 1 .tile .tile)) &&
            removedFrom three 2 2 == some (1, .splits (.split .rows 1 1 .tile .tile)) &&
            removedFrom three 0 0 == some (1, .splits (.split .columns 1 1 .tile .tile)) &&
            removedFrom nested 1 1 == some (2, .splits (.split .rows 1 1 .tile .tile)) &&
            removedFrom weighted 0 0 ==
              some (1, .splits (.split .columns 1 1 .tile (.split .rows 1 1 .tile .tile))) },
    { name :=
        "splitting a window and removing the new one gives back the frame from before the split, under master-and-stack, monocle and manual splits, with either placement"
      run :=
        pure <|
          [Layout.default, .monocle, Layout.manual].all fun layout =>
            [({} : Placement), { axis := .columns, before := true }].all fun placement =>
              match onTextModel (windowsUnder 2 layout) with
              | none => false
              | some state =>
                match state.splitWindow ⟨1⟩ (marker 8) (marker 9) placement with
                | (.ok made, split) =>
                  split.wellFormed &&
                    match split.removeWindow made with
                    | (.ok _, back) => back.frame == state.frame
                    | _ => false
                | _ => false },
    { name :=
        "a window split while zoomed is in the tree zoom returns to, and so is a window removed while zoomed, whose inheritor is the one of the layout to return to"
      run :=
        pure <|
          match onTextModel (windowsUnder 2 Layout.manual) with
          | none => false
          | some state =>
            match state.arrange ⟨0⟩ .zoom with
            | (.ok (), zoomed) =>
              zoomed.frame.layout == .monocle &&
                match zoomed.splitWindow ⟨0⟩ (marker 8) (marker 9) with
                | (.ok made, split) =>
                  split.wellFormed && split.frame.windows == ids [0, 2, 1] &&
                    split.frame.zoomedFrom ==
                      some (.splits (.split .rows 2 1 (.split .rows 1 1 .tile .tile) .tile)) &&
                    (match (split.focusWindow made).2.removeWindow made with
                    | (.ok _, removed) =>
                      removed.wellFormed && removed.frame.focused == ⟨1⟩ &&
                        removed.frame.zoomedFrom == some (.splits (.split .rows 1 1 .tile .tile))
                    | _ => false) &&
                    match split.arrange ⟨0⟩ .zoom with
                    | (.ok (), back) =>
                      back.frame.zoomedFrom == none &&
                        back.frame.layout ==
                          .splits (.split .rows 2 1 (.split .rows 1 1 .tile .tile) .tile)
                    | _ => false
                | _ => false
            | _ => false },
    { name :=
        "the frame keeps the window of the list focused before the current one: focusing another window sets it, focusing the same one changes nothing, and focusing the minibuffer's view or leaving it does not set it"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (_, one) := state.focusWindow ⟨1⟩
            let (_, two) := one.focusWindow ⟨2⟩
            let (_, again) := two.focusWindow ⟨2⟩
            let asking := (prompted two).2
            let (_, away) := asking.focusWindow ⟨0⟩
            let (_, back) := away.focusWindow (asking.minibufferView?.getD ⟨9⟩)
            state.frame.lastFocused == none && one.frame.lastFocused == some ⟨0⟩ &&
              two.frame.lastFocused == some ⟨1⟩ &&
              again == two &&
              asking.frame.lastFocused == some ⟨1⟩ &&
              away.frame.lastFocused == some ⟨1⟩ &&
              back.frame.lastFocused == some ⟨1⟩ },
    { name :=
        "promote moves a window to main, and main itself swaps with the next; demote swaps a window with the next, and the last stays; the focus stays on its view"
      run :=
        pure <|
          match onTextModel (windowsUnder 4 Layout.default) with
          | none => false
          | some state =>
            arrangedTo (state.arrange ⟨2⟩ .promote) == some ([2, 0, 1, 3], 0) &&
              arrangedTo (state.arrange ⟨0⟩ .promote) == some ([1, 0, 2, 3], 0) &&
              arrangedTo (state.arrange ⟨0⟩ .demote) == some ([1, 0, 2, 3], 0) &&
              arrangedTo (state.arrange ⟨3⟩ .demote) == some ([0, 1, 2, 3], 0) &&
              arrangedTo ((state.focusWindow ⟨2⟩).2.arrange ⟨2⟩ .promote) ==
                some ([2, 0, 1, 3], 2) },
    { name :=
        "rotate under master-and-stack rotates the stack and keeps main, forward putting the last first and back the reverse, and the focus stays on its view; under manual splits the whole list rotates"
      run :=
        pure <|
          match onTextModel (windowsUnder 4 Layout.default),
            onTextModel (windowsUnder 3 Layout.manual) with
          | some state, some manual =>
            let onTwo := (state.focusWindow ⟨2⟩).2
            arrangedTo (onTwo.arrange ⟨2⟩ (.rotate true)) == some ([0, 3, 1, 2], 2) &&
              arrangedTo (onTwo.arrange ⟨2⟩ (.rotate false)) == some ([0, 2, 3, 1], 2) &&
              arrangedTo (manual.arrange ⟨0⟩ (.rotate true)) == some ([2, 0, 1], 0) &&
              (manual.arrange ⟨0⟩ (.rotate true)).2.frame.layout == manual.frame.layout
          | _, _ => false },
    { name :=
        "exchange swaps a window with the next, with the previous when it is last, or with the Nth of the list, and the focus moves to the other view, which now stands where the window was; a window of one, or the Nth itself, changes nothing"
      run :=
        pure <|
          match onTextModel (windowsUnder 4 Layout.default),
            onTextModel (windowsUnder 1 Layout.default) with
          | some state, some alone =>
            let onOne := (state.focusWindow ⟨1⟩).2
            let onThree := (state.focusWindow ⟨3⟩).2
            let onTwo := (state.focusWindow ⟨2⟩).2
            arrangedTo (onOne.arrange ⟨1⟩ (.exchange none)) == some ([0, 2, 1, 3], 2) &&
              (onOne.arrange ⟨1⟩ (.exchange none)).2.frame.lastFocused == some ⟨1⟩ &&
              arrangedTo (onThree.arrange ⟨3⟩ (.exchange none)) == some ([0, 1, 3, 2], 2) &&
              arrangedTo (onTwo.arrange ⟨2⟩ (.exchange (some 1))) == some ([2, 1, 0, 3], 0) &&
              arrangedTo (onTwo.arrange ⟨2⟩ (.exchange (some 3))) == some ([0, 1, 2, 3], 2) &&
              arrangedTo (onTwo.arrange ⟨2⟩ (.exchange (some 9))) == some ([0, 1, 2, 3], 2) &&
              arrangedTo (alone.arrange ⟨0⟩ (.exchange none)) == some ([0], 0)
          | _, _ => false },
    { name :=
        "zoom keeps the layout it leaves and makes the layout monocle, and zoom again goes back to it; under monocle that is not a zoom it is refused with monocleChosen, and the state is as it was"
      run :=
        pure <|
          match onTextModel (windowsUnder 3 Layout.default),
            onTextModel (windowsUnder 2 .monocle) with
          | some state, some monocle =>
            (match state.arrange ⟨1⟩ .zoom with
              | (.ok (), zoomed) =>
                zoomed.frame.layout == .monocle && zoomed.frame.zoomedFrom == some Layout.default &&
                  zoomed.frame.windows == state.frame.windows &&
                  match zoomed.arrange ⟨0⟩ .zoom with
                  | (.ok (), back) => back.frame == state.frame
                  | _ => false
              | _ => false) &&
              match monocle.arrange ⟨0⟩ .zoom with
              | (.error .monocleChosen, after) => after == monocle
              | _ => false
          | _, _ => false },
    { name :=
        "balance puts master-and-stack's share back to 50 and balances manual splits along both axes; under monocle it changes nothing"
      run :=
        pure <|
          let tree := Splits.split .columns 9 1 .tile (.split .rows 1 7 .tile .tile)
          match onTextModel (windowsUnder 2 (.masterStack { share := 70 })),
            onTextModel (windowsUnder 3 (.splits tree)), onTextModel (windowsUnder 2 .monocle) with
          | some stack, some manual, some monocle =>
            (stack.arrange ⟨1⟩ .balance).2.frame.layout == .masterStack { share := 50 } &&
              (manual.arrange ⟨1⟩ .balance).2.frame.layout ==
                .splits (.split .columns 1 1 .tile (.split .rows 1 1 .tile .tile)) &&
              (monocle.arrange ⟨1⟩ .balance).2 == monocle
          | _, _, _ => false },
    { name :=
        "resize under master-and-stack grows main's share by 5 percent a step for a main window that grows or a stack window that shrinks, and shrinks it otherwise, clamped to 0 and 100, a share above 100 read as 100; across its side's axis, with one window and under monocle it is refused with notResizable, and the state is as it was"
      run :=
        pure <|
          let share (layout : Layout) : Option Nat :=
            match layout with
            | .masterStack parameters => some parameters.share
            | _ => none
          let resized (start : Nat) (view : Nat) (grow : Bool) (steps : Nat) : Option Nat :=
            match onTextModel (windowsUnder 3 (.masterStack { share := start })) with
            | none => none
            | some state =>
              match state.arrange ⟨view⟩ (.resize .columns grow steps) with
              | (.ok (), after) => share after.frame.layout
              | _ => none
          let refused (count : Nat) (layout : Layout) (axis : Axis) : Bool :=
            match onTextModel (windowsUnder count layout) with
            | none => false
            | some state =>
              match state.arrange ⟨0⟩ (.resize axis true 1) with
              | (.error (.notResizable refusedAxis), after) => refusedAxis == axis && after == state
              | _ => false
          resized 50 0 true 1 == some 55 && resized 50 1 true 1 == some 45 &&
            resized 50 0 false 2 == some 40 &&
            resized 50 2 false 1 == some 55 &&
            resized 98 0 true 1 == some 100 &&
            resized 150 1 false 1 == some 100 &&
            resized 3 0 false 1 == some 0 &&
            refused 3 Layout.default .rows &&
            refused 1 Layout.default .columns &&
            refused 2 .monocle .columns },
    { name :=
        "resize under manual splits moves the boundary of the deepest split on the axis that holds the window's tile by 5 percent a step, towards the tile's part when it grows; with no split on the axis it is refused with notResizable, and the state is as it was"
      run :=
        pure <|
          let tree := Splits.split .columns 1 1 .tile (.split .rows 1 1 .tile .tile)
          let resized (view : Nat) (axis : Axis) (grow : Bool) (steps : Nat) : Option Layout :=
            match onTextModel (windowsUnder 3 (.splits tree)) with
            | none => none
            | some state =>
              match state.arrange ⟨view⟩ (.resize axis grow steps) with
              | (.ok (), after) => some after.frame.layout
              | _ => none
          let rows (first second : Nat) : Layout :=
            .splits (.split .columns 1 1 .tile (.split .rows first second .tile .tile))
          resized 1 .rows true 1 == some (rows 55 45) &&
            resized 1 .rows false 1 == some (rows 45 55) &&
            resized 2 .rows true 2 == some (rows 40 60) &&
            resized 2 .rows false 1 == some (rows 55 45) &&
            resized 2 .columns false 1 ==
              some (.splits (.split .columns 55 45 .tile (.split .rows 1 1 .tile .tile))) &&
            match onTextModel (windowsUnder 3 (.splits tree)) with
            | none => false
            | some state =>
              match state.arrange ⟨0⟩ (.resize .rows true 1) with
              | (.error (.notResizable .rows), after) => after == state
              | _ => false },
    { name :=
        "main's count goes up and down by the steps asked, not below 0; under any layout but master-and-stack it is refused with noMain, and the state is as it was"
      run :=
        pure <|
          match onTextModel (windowsUnder 3 Layout.default),
            onTextModel (windowsUnder 3 Layout.manual) with
          | some state, some manual =>
            let (_, more) := state.arrange ⟨0⟩ (.mainCount true 1)
            let (_, fewer) := more.arrange ⟨0⟩ (.mainCount false 5)
            more.frame.layout == .masterStack { count := 2 } &&
              fewer.frame.layout == .masterStack { count := 0 } &&
              match manual.arrange ⟨0⟩ (.mainCount true 1) with
              | (.error .noMain, after) => after == manual
              | _ => false
          | _, _ => false },
    { name :=
        "while zoomed, balance, resize and main's count change the layout zoom returns to and leave monocle shown, so zoom again shows the change; a refusal is the layout zoom returns to's, and the state is as it was"
      run :=
        pure <|
          let tree := Splits.split .rows 7 3 .tile .tile
          let zoomed (layout : Layout) : Option EditorState :=
            (onTextModel (windowsUnder 2 layout)).bind fun state =>
              match state.arrange ⟨0⟩ .zoom with
              | (.ok (), zoomed) => some zoomed
              | _ => none
          let changed (layout : Layout) (change : Arrange) : Option (Layout × Option Layout) :=
            (zoomed layout).bind fun state =>
              match state.arrange ⟨0⟩ change with
              | (.ok (), after) =>
                match after.arrange ⟨0⟩ .zoom with
                | (.ok (), back) => some (after.frame.layout, some back.frame.layout)
                | _ => none
              | _ => none
          let refused (layout : Layout) (change : Arrange) (refusal : LayoutRefusal) : Bool :=
            match zoomed layout with
            | none => false
            | some state =>
              match state.arrange ⟨0⟩ change with
              | (.error got, after) => got == refusal && after == state
              | _ => false
          changed Layout.default (.mainCount true 1) ==
              some (.monocle, some (.masterStack { count := 2 })) &&
            changed Layout.default (.resize .columns true 1) ==
              some (.monocle, some (.masterStack { share := 55 })) &&
            changed (.masterStack { share := 70 }) .balance ==
              some (.monocle, some (.masterStack { share := 50 })) &&
            changed (.splits tree) .balance ==
              some (.monocle, some (.splits (.split .rows 1 1 .tile .tile))) &&
            changed (.splits tree) (.resize .rows true 1) ==
              some (.monocle, some (.splits (.split .rows 75 25 .tile .tile))) &&
            refused (.splits tree) (.resize .columns true 1) (.notResizable .columns) &&
            refused (.splits tree) (.mainCount true 1) .noMain &&
            refused Layout.default (.resize .rows true 1) (.notResizable .rows) },
    { name :=
        "while zoomed under a left edge round manual splits, docking a tile, undocking a window, resizing the strip and opening a window at the edge change the layout zoom returns to and leave monocle shown: the tree is fitted to the tiles, the strip's size moves, the state is well formed, and zoom again lays out what the change makes unzoomed; the edge's refusals are the layout zoom returns to's, and the state is as it was"
      run :=
        pure <|
          match onTextModel (dockedUnder 2 [.left] (.edge .left 25 Layout.manual)) with
          | none => false
          | some state =>
            match state.arrange ⟨0⟩ .zoom with
            | (.ok (), zoomed) =>
              let edged (tree : Splits) (size : Nat := 25) : Option Layout :=
                some (.edge .left size (.splits tree))
              let row := Splits.split .rows 1 1 .tile .tile
              -- What a change made while zoomed leaves: monocle shown, the
              -- layout zoom returns to, and the rectangles zoom again gives,
              -- the frame then being the one the same change makes unzoomed.
              let shown (zoomedAfter plainAfter : EditorState) :
                Option (Option Layout × Array (ViewId × Rect)) :=
                match zoomedAfter.arrange zoomedAfter.frame.focused .zoom with
                | (.ok (), back) =>
                  if
                      zoomedAfter.wellFormed && zoomedAfter.frame.layout == .monocle &&
                        back.wellFormed &&
                        back.frame == plainAfter.frame then
                    some (zoomedAfter.frame.zoomedFrom, back.rects)
                  else none
                | _ => none
              let arranged (view : Nat) (change : Arrange) :
                Option (Option Layout × Array (ViewId × Rect)) :=
                match zoomed.arrange ⟨view⟩ change, state.arrange ⟨view⟩ change with
                | (.ok (), after), (.ok (), plain) => shown after plain
                | _, _ => none
              let opened : Option (Option Layout × Array (ViewId × Rect)) :=
                match zoomed.openWindow ⟨0⟩ (marker 8) (marker 9) (.edge .left),
                  state.openWindow ⟨0⟩ (marker 8) (marker 9) (.edge .left) with
                | (.ok made, after), (.ok _, plain) =>
                  if made == ⟨3⟩ && after.frame.docked == #[(⟨2⟩, .left), (⟨3⟩, .left)] then
                    shown after plain
                  else none
                | _, _ => none
              let refused (view : Nat) (change : Arrange) (refusal : LayoutRefusal) : Bool :=
                match zoomed.arrange ⟨view⟩ change with
                | (.error got, after) => got == refusal && after == zoomed
                | _ => false
              let (_, oneTile) := zoomed.arrange ⟨1⟩ (.edge .left)
              -- C-w H on tile 1: it joins the strip, below view 2.
              arranged 1 (.edge .left) ==
                  some
                    (edged .tile,
                      #[(⟨0⟩, rect 160 0 480 464), (⟨2⟩, rect 0 0 158 230),
                        (⟨1⟩, rect 0 232 158 232)]) &&
                oneTile.frame.docked == #[(⟨2⟩, .left), (⟨1⟩, .left)] &&
                -- The docked window back into the tiles, at the end: the
                -- last tile is split along rows, and the strip, empty, takes
                -- no room.
                arranged 2 (.edge .left) ==
                  some
                    (edged (.split .rows 1 2 .tile row),
                      #[(⟨0⟩, rect 0 0 640 152), (⟨1⟩, rect 0 154 640 153),
                        (⟨2⟩, rect 0 309 640 155)]) &&
                arranged 2 (.resize .columns true 1) ==
                  some
                    (edged row 30,
                      #[(⟨0⟩, rect 192 0 448 230), (⟨1⟩, rect 192 232 448 232),
                        (⟨2⟩, rect 0 0 190 464)]) &&
                opened ==
                  some
                    (edged row,
                      #[(⟨0⟩, rect 160 0 480 230), (⟨1⟩, rect 160 232 480 232),
                        (⟨2⟩, rect 0 0 158 230), (⟨3⟩, rect 0 232 158 232)]) &&
                refused 2 (.resize .rows true 1) (.notResizable .rows) &&
                refused 0 (.edge .right) (.noSuchEdge .right) &&
                refused 2 (.edge .top) (.noSuchEdge .top) &&
                match oneTile.arrange ⟨0⟩ (.edge .left) with
                | (.error .lastTile, after) => after == oneTile
                | _ => false
            | _ => false },
    { name :=
        "every change of the window list refuses a view not in the list with noSuchWindow and the minibuffer's view with ofMinibuffer, and the state is as it was"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let asking := (prompted state).2
            let minibuffer := asking.minibufferView?.getD ⟨9⟩
            let changes : List Arrange :=
              [.promote, .demote, .rotate true, .exchange none, .zoom, .balance,
                .resize .columns true 1, .mainCount true 1]
            changes.all fun change =>
              (match state.arrange ⟨9⟩ change with
                | (.error (.noSuchWindow id), after) => id == ⟨9⟩ && after == state
                | _ => false) &&
                match asking.arrange minibuffer change with
                | (.error (.ofMinibuffer id), after) => id == minibuffer && after == asking
                | _ => false },
    { name :=
        "focus by direction under master-and-stack: from main to the right is the top of the stack, from any stack window to the left is main, down and up walk the stack, a count goes as far as it can, and at an edge there is none"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            state.toward? ⟨0⟩ .right 1 == some ⟨1⟩ && state.toward? ⟨1⟩ .left 1 == some ⟨0⟩ &&
              state.toward? ⟨2⟩ .left 1 == some ⟨0⟩ &&
              state.toward? ⟨1⟩ .bottom 1 == some ⟨2⟩ &&
              state.toward? ⟨2⟩ .top 1 == some ⟨1⟩ &&
              state.toward? ⟨0⟩ .right 2 == some ⟨1⟩ &&
              state.toward? ⟨0⟩ .left 1 == none &&
              state.toward? ⟨0⟩ .top 1 == none &&
              state.toward? ⟨1⟩ .right 1 == none &&
              state.toward? ⟨9⟩ .right 1 == none },
    { name :=
        "focus by direction under manual splits: in a 2 by 2 grid each direction reaches the neighbour and an edge has none; in a row of three a count of 2 goes two windows, and a count past the edge stops at the last"
      run :=
        pure <|
          let grid :=
            Splits.split .rows 1 1 (.split .columns 1 1 .tile .tile)
              (.split .columns 1 1 .tile .tile)
          let row := Splits.split .columns 1 1 .tile (.split .columns 1 1 .tile .tile)
          match onTextModel (windowsUnder 4 (.splits grid)),
            onTextModel (windowsUnder 3 (.splits row)) with
          | some grid, some row =>
            grid.toward? ⟨0⟩ .right 1 == some ⟨1⟩ && grid.toward? ⟨0⟩ .bottom 1 == some ⟨2⟩ &&
              grid.toward? ⟨3⟩ .left 1 == some ⟨2⟩ &&
              grid.toward? ⟨3⟩ .top 1 == some ⟨1⟩ &&
              grid.toward? ⟨0⟩ .left 1 == none &&
              grid.toward? ⟨3⟩ .bottom 1 == none &&
              row.toward? ⟨0⟩ .right 2 == some ⟨2⟩ &&
              row.toward? ⟨0⟩ .right 5 == some ⟨2⟩ &&
              row.toward? ⟨2⟩ .left 1 == some ⟨1⟩
          | _, _ => false },
    { name :=
        "focus by direction under monocle: only the shown window has a rectangle, so no window lies in any direction of any window"
      run :=
        pure <|
          match onTextModel (windowsUnder 3 .monocle) with
          | none => false
          | some state =>
            (List.range 3).all fun index =>
              [Side.left, .right, .top, .bottom].all fun side =>
                state.toward? ⟨index⟩ side 1 == none },
    { name :=
        "criterion 4: focus by direction reaches a tiled or docked window that lies wholly on that side and overlaps across, whenever one does, and never a float or the minibuffer's view, for every window, floats among them, and side of one to five windows under master-and-stack, monocle and every manual split tree reached by up to three splits, and of one to four tiles with none to two windows docked at an edge, with none to two floats, with a prompt open and without"
      run :=
        pure <|
          directionStates.all fun state =>
            state.frame.all.all fun window =>
              [Side.left, .right, .top, .bottom].all fun side =>
                match state.rect? window with
                | none => state.toward? window side 1 == none
                | some start =>
                  let candidates :=
                    state.rects.filter fun (id, rect) =>
                      state.frame.anchors id && id != window && lies side start rect
                  match state.toward? window side 1 with
                  | some reached =>
                    state.minibufferView? != some reached && candidates.any (·.1 == reached)
                  | none => candidates.isEmpty },
    { name :=
        "focus in list order: the next and the previous window of the list, wrapping at either end, or with a count the Nth window, the last when the count is past the end"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            state.cycled ⟨0⟩ true 0 == some ⟨1⟩ && state.cycled ⟨2⟩ true 0 == some ⟨0⟩ &&
              state.cycled ⟨0⟩ false 0 == some ⟨2⟩ &&
              state.cycled ⟨1⟩ false 0 == some ⟨0⟩ &&
              state.cycled ⟨0⟩ true 3 == some ⟨2⟩ &&
              state.cycled ⟨2⟩ false 1 == some ⟨0⟩ &&
              state.cycled ⟨0⟩ true 9 == some ⟨2⟩ &&
              state.cycled ⟨9⟩ true 0 == none },
    { name :=
        "every refusal of the layout says why in a sentence, and the last window's is Vim's E444: it cannot be closed"
      run :=
        pure <|
          let all : List LayoutRefusal :=
            [.onlyWindow, .noSuchWindow ⟨1⟩, .noSuchBuffer ⟨1⟩, .markersOfAnotherText,
              .ofMinibuffer ⟨1⟩, .noPreviousWindow, .notResizable .rows, .noMain, .monocleChosen,
              .noSuchEdge .left, .lastTile, .atEdge ⟨1⟩, .floating ⟨1⟩]
          all.all (!·.describe.isEmpty) &&
            LayoutRefusal.lastTile.describe == "the last tiled window cannot leave the tiles" &&
            (LayoutRefusal.floating ⟨1⟩).describe == "a floating window is not in the layout" &&
            LayoutRefusal.onlyWindow.describe == "the last window cannot be closed" &&
            (LayoutRefusal.noSuchEdge .left).describe == "the layout has no left edge" &&
            (LayoutRefusal.noSuchEdge .bottom).describe == Layout.noEdge .bottom },
    { name :=
        "a window docked at an edge is one of the frame's windows and of the state's views, and not of the tiled list; the layout gives it its strip, after the tiles"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let rect (x y width height : Nat) : Rect := { x, y, width, height }
            state.wellFormed && state.frame.windows == #[⟨0⟩, ⟨1⟩] &&
              state.frame.all == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
              state.frame.contains ⟨2⟩ &&
              !state.frame.contains ⟨7⟩ &&
              state.views == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
              state.rects ==
                #[(⟨0⟩, rect 160 0 238 464), (⟨1⟩, rect 400 0 240 464), (⟨2⟩, rect 0 0 158 464)] },
    { name :=
        "criterion 3: a window docked at the left edge is reached by direction from main, and main from it; closing it empties the edge and the focus goes back to the window focused before it, or to main; the last tile cannot be closed while it is docked"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let onSidebar := (state.focusWindow ⟨2⟩).2
            let viaStack := ((state.focusWindow ⟨1⟩).2.focusWindow ⟨2⟩).2
            let unremembered := { state with frame := { state.frame with focused := ⟨2⟩ } }
            let closed (from_ : EditorState) : Option (List (Nat × Side) × Nat) :=
              match from_.removeWindow ⟨2⟩ with
              | (.ok window, after) =>
                if window.id == ⟨2⟩ && after.wellFormed && after.rects.size == 2 then
                  some
                    (after.frame.docked.toList.map (fun (view, side) => (view.index, side)),
                      after.frame.focused.index)
                else none
              | _ => none
            let (_, oneTile) := state.removeWindow ⟨1⟩
            state.toward? ⟨0⟩ .left 1 == some ⟨2⟩ && state.toward? ⟨2⟩ .right 1 == some ⟨0⟩ &&
              state.toward? ⟨1⟩ .left 2 == some ⟨2⟩ &&
              closed onSidebar == some ([], 0) &&
              closed viaStack == some ([], 1) &&
              closed unremembered == some ([], 0) &&
              closed state == some ([], 0) &&
              oneTile.frame.windows == #[⟨0⟩] &&
              match oneTile.removeWindow ⟨0⟩ with
              | (.error .onlyWindow, after) => after == oneTile
              | _ => false },
    { name :=
        "closing a focused window of two docked at one edge moves the focus to the window of that side that took its index, or, for the last, to the side's new last window"
      run :=
        pure <|
          match onTextModel (dockedUnder 1 [.left, .left] (.edge .left 25 Layout.default)) with
          | none => false
          | some state =>
            let focusAfter (focus gone : Nat) : Option Nat :=
              match (state.focusWindow ⟨focus⟩).2.removeWindow ⟨gone⟩ with
              | (.ok _, after) => if after.wellFormed then some after.frame.focused.index else none
              | _ => none
            focusAfter 1 1 == some 2 && focusAfter 2 2 == some 1 && focusAfter 1 2 == some 1 },
    { name :=
        "criterion 3: promote moves a docked window into the tiles as main, the old main first of the stack; the edge command docks a tile, moves a docked window back to the end of the list, and moves one docked at another side to its side; the focus stays"
      run :=
        pure <|
          match onTextModel sidebar,
            onTextModel
              (dockedUnder 2 [.left] (.edge .left 25 (.edge .bottom 30 Layout.default))) with
          | some state, some two =>
            let onSidebar := (state.focusWindow ⟨2⟩).2
            dockedTo (state.arrange ⟨2⟩ .promote) == some ([2, 0, 1], [], 0) &&
              dockedTo (onSidebar.arrange ⟨2⟩ .promote) == some ([2, 0, 1], [], 2) &&
              dockedTo (state.arrange ⟨2⟩ (.edge .left)) == some ([0, 1, 2], [], 0) &&
              dockedTo (state.arrange ⟨1⟩ (.edge .left)) ==
                some ([0], [(2, .left), (1, .left)], 0) &&
              dockedTo ((state.focusWindow ⟨1⟩).2.arrange ⟨1⟩ (.edge .left)) ==
                some ([0], [(2, .left), (1, .left)], 1) &&
              dockedTo (two.arrange ⟨2⟩ (.edge .bottom)) == some ([0, 1], [(2, .bottom)], 0) &&
              dockedTo (two.arrange ⟨0⟩ (.edge .bottom)) ==
                some ([1], [(2, .left), (0, .bottom)], 0)
          | _, _ => false },
    { name :=
        "the edge command refuses the last tile with lastTile, and a side the layout has no edge at with noSuchEdge, for a tile and for a docked window, each with the state as it was"
      run :=
        pure <|
          match onTextModel sidebar, onTextModel (windowsUnder 2 Layout.default) with
          | some state, some plain =>
            let (_, oneTile) := state.removeWindow ⟨1⟩
            let refused (from_ : EditorState) (view : Nat) (side : Side) (refusal : LayoutRefusal) :
              Bool :=
              match from_.arrange ⟨view⟩ (.edge side) with
              | (.error got, after) => got == refusal && after == from_
              | _ => false
            refused oneTile 0 .left .lastTile && refused state 1 .right (.noSuchEdge .right) &&
              refused state 2 .top (.noSuchEdge .top) &&
              refused plain 1 .left (.noSuchEdge .left)
          | _, _ => false },
    { name :=
        "demote, exchange and rotate on a docked window act on the windows of its side, as a list, and leave the tiles; one window at an edge stays"
      run :=
        pure <|
          match onTextModel (dockedUnder 2 [.left, .left, .left] (.edge .left 25 Layout.default)),
            onTextModel sidebar with
          | some state, some alone =>
            let onTwo := (state.focusWindow ⟨2⟩).2
            let left (views : List Nat) : List (Nat × Side) := views.map (·, .left)
            dockedTo (onTwo.arrange ⟨2⟩ .demote) == some ([0, 1], left [3, 2, 4], 2) &&
              dockedTo (onTwo.arrange ⟨4⟩ .demote) == some ([0, 1], left [2, 3, 4], 2) &&
              dockedTo (onTwo.arrange ⟨2⟩ (.exchange none)) == some ([0, 1], left [3, 2, 4], 3) &&
              dockedTo (onTwo.arrange ⟨2⟩ (.exchange (some 3))) ==
                some ([0, 1], left [4, 3, 2], 4) &&
              dockedTo (onTwo.arrange ⟨2⟩ (.rotate true)) == some ([0, 1], left [4, 2, 3], 2) &&
              dockedTo (onTwo.arrange ⟨2⟩ (.rotate false)) == some ([0, 1], left [3, 4, 2], 2) &&
              dockedTo (alone.arrange ⟨2⟩ .demote) == some ([0, 1], left [2], 0) &&
              dockedTo (alone.arrange ⟨2⟩ (.rotate true)) == some ([0, 1], left [2], 0)
          | _, _ => false },
    { name :=
        "resize on a docked window moves its edge's strip by 5 percent a step along the side's axis, and across it is refused with notResizable, the state as it was; resize, balance and main's count on any window act on the layout inside the edges, and balance leaves a strip's size"
      run :=
        pure <|
          match onTextModel sidebar,
            onTextModel (dockedUnder 2 [.left] (.edge .left 25 (.masterStack { share := 70 }))) with
          | some state, some wide =>
            (state.arrange ⟨2⟩ (.resize .columns true 1)).2.frame.layout ==
                .edge .left 30 Layout.default &&
              (state.arrange ⟨2⟩ (.resize .columns false 2)).2.frame.layout ==
                .edge .left 15 Layout.default &&
              (match state.arrange ⟨2⟩ (.resize .rows true 1) with
              | (.error (.notResizable .rows), after) => after == state
              | _ => false) &&
              (state.arrange ⟨0⟩ (.resize .columns true 1)).2.frame.layout ==
                .edge .left 25 (.masterStack { share := 55 }) &&
              (state.arrange ⟨2⟩ (.mainCount true 1)).2.frame.layout ==
                .edge .left 25 (.masterStack { count := 2 }) &&
              (wide.arrange ⟨2⟩ .balance).2.frame.layout == .edge .left 25 Layout.default &&
              match onTextModel (dockedUnder 2 [.left] (.edge .left 25 Layout.manual)) with
              | none => false
              | some manual =>
                match manual.arrange ⟨2⟩ (.mainCount true 1) with
                | (.error .noMain, after) => after == manual
                | _ => false
          | _, _ => false },
    { name :=
        "zoom from a docked window shows it over the tiled area, and zoom again goes back; zoom from a tile shows the tile alone, and a docked window then has no rectangle"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let whole : Rect := { x := 0, y := 0, width := 640, height := 464 }
            match ((state.focusWindow ⟨2⟩).2.arrange ⟨2⟩ .zoom), state.arrange ⟨0⟩ .zoom with
            | (.ok (), fromSidebar), (.ok (), fromMain) =>
              fromSidebar.wellFormed && fromSidebar.frame.layout == .monocle &&
                fromSidebar.frame.zoomedFrom == some (.edge .left 25 Layout.default) &&
                fromSidebar.rects == #[(⟨2⟩, whole)] &&
                fromMain.rects == #[(⟨0⟩, whole)] &&
                fromMain.rect? ⟨2⟩ == none &&
                match fromSidebar.arrange ⟨2⟩ .zoom with
                | (.ok (), back) => back.frame == (state.focusWindow ⟨2⟩).2.frame
                | _ => false
            | _, _ => false },
    { name :=
        "splitting a docked window docks the new one at the same side, right after it, whatever the placement; the tiles and the layout are as they were, and the focus stays"
      run :=
        pure <|
          match onTextModel (dockedUnder 2 [.left, .left] (.edge .left 25 Layout.manual)) with
          | none => false
          | some state =>
            match
              state.splitWindow ⟨2⟩ (marker 8) (marker 9) { axis := .columns, before := true } with
            | (.ok made, after) =>
              made == ⟨4⟩ && after.wellFormed && after.frame.windows == state.frame.windows &&
                after.frame.docked == #[(⟨2⟩, .left), (⟨4⟩, .left), (⟨3⟩, .left)] &&
                after.frame.layout == state.frame.layout &&
                after.frame.focused == ⟨0⟩
            | _ => false },
    { name := "a split under manual splits inside an edge reads the placement, as manual splits do"
      run :=
        pure <|
          match onTextModel (dockedUnder 1 [.left] (.edge .left 25 Layout.manual)) with
          | none => false
          | some state =>
            match
              state.splitWindow ⟨0⟩ (marker 8) (marker 9) { axis := .columns, before := true } with
            | (.ok made, after) =>
              after.wellFormed && after.frame.windows == #[made, ⟨0⟩] &&
                after.frame.layout == .edge .left 25 (.splits (.split .columns 1 1 .tile .tile))
            | _ => false },
    { name :=
        "focus in list order walks the tiles and then the docked windows, wrapping; the Nth counts them too; the window focused before is kept across a docked window"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let (_, onSidebar) := state.focusWindow ⟨2⟩
            let (_, back) := onSidebar.focusWindow ⟨1⟩
            state.cycled ⟨1⟩ true 0 == some ⟨2⟩ && state.cycled ⟨2⟩ true 0 == some ⟨0⟩ &&
              state.cycled ⟨0⟩ false 0 == some ⟨2⟩ &&
              state.cycled ⟨0⟩ true 3 == some ⟨2⟩ &&
              state.cycled ⟨2⟩ false 0 == some ⟨1⟩ &&
              onSidebar.frame.lastFocused == some ⟨0⟩ &&
              back.frame.lastFocused == some ⟨2⟩ },
    { name := "a docked window shows another buffer as any window does"
      run :=
        pure <|
          match onTextModel (dockedUnder 1 [.left] (.edge .left 25 Layout.default)) with
          | none => false
          | some state =>
            -- The docked window, view 1, is shown its buffer with new
            -- markers: the operation takes it, as it takes a tile.
            match state.showBuffer ⟨1⟩ ⟨0⟩ (marker 8) (marker 9) with
            | (.ok (), after) =>
              after.wellFormed && (after.window? ⟨1⟩).map (·.scroll) == some (marker 8)
            | _ => false },
    { name := "a prompt asked from a docked window gives the focus back to it when it closes"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let (_, onSidebar) := state.focusWindow ⟨2⟩
            let (_, asking) := prompted onSidebar
            match asking.prompt, asking.closePrompt none with
            | some asked, (.ok (), closed) =>
              asking.askedFrom asked == ⟨2⟩ && closed.frame.focused == ⟨2⟩ && closed.wellFormed
            | _, _ => false },
    { name :=
        "config choosing a layout without an edge moves the windows docked there to the end of the tiled list, in order, before fitting the layout: the same windows are there and none is lost; an edge the new layout keeps keeps its windows"
      run :=
        pure <|
          match
            onTextModel
              (dockedUnder 2 [.left, .bottom, .left]
                (.edge .left 25 (.edge .bottom 30 Layout.default))) with
          | none => false
          | some state =>
            let chosen (layout : Layout) : Frame := state.frame.choose layout
            let all (frame : Frame) : Array Nat := (frame.all.map (·.index)).qsort (· < ·)
            (chosen Layout.default).windows == #[⟨0⟩, ⟨1⟩, ⟨2⟩, ⟨3⟩, ⟨4⟩] &&
              (chosen Layout.default).docked == #[] &&
              (chosen Layout.manual).layout == Layout.manual.fits 5 &&
              (chosen Layout.manual).windows.size == 5 &&
              (chosen (.edge .left 25 Layout.default)).windows == #[⟨0⟩, ⟨1⟩, ⟨3⟩] &&
              (chosen (.edge .left 25 Layout.default)).docked == #[(⟨2⟩, .left), (⟨4⟩, .left)] &&
              [Layout.default, Layout.manual, .monocle, .edge .left 25 Layout.default].all
                fun layout =>
                all (chosen layout) == all state.frame &&
                  ({ state with frame := chosen layout } : EditorState).wellFormed },
    { name :=
        "a window opened into the stack goes after the last of the tiled list: under master-and-stack main keeps its side and the stack grows, under monocle it is appended, and under manual splits the last tile is split along rows; the focus stays"
      run :=
        pure <|
          let rect (x y width height : Nat) : Rect := { x, y, width, height }
          let opened (count : Nat) (layout : Layout) : Option EditorState :=
            (onTextModel (windowsUnder count layout)).bind fun state =>
              match state.openWindow ⟨0⟩ (marker 8) (marker 9) .stack with
              | (.ok made, after) =>
                if
                    made == ⟨count⟩ && after.wellFormed && after.frame.focused == ⟨0⟩ &&
                      after.frame.windows == windowsUpTo (count + 1) &&
                      (after.window? made).map (fun window => (window.buffer, window.scroll)) ==
                        some (⟨0⟩, marker 8) then
                  some after
                else none
              | _ => none
          (opened 1 Layout.default).map (·.rects) ==
              some #[(⟨0⟩, rect 0 0 318 464), (⟨1⟩, rect 320 0 320 464)] &&
            (opened 2 Layout.default).map (·.frame.layout) == some Layout.default &&
            (opened 2 .monocle).map (·.frame.layout) == some .monocle &&
            (opened 2 Layout.manual).map (·.frame.layout) ==
              some (.splits (.split .rows 1 2 .tile (.split .rows 1 1 .tile .tile))) &&
            (opened 1 Layout.manual).map (·.frame.layout) ==
              some (.splits (.split .rows 1 1 .tile .tile)) },
    { name :=
        "a window opened at an edge is docked there, after that side's others; at a side the layout has no edge for it is refused with noSuchEdge; a buffer there is none of, markers of another text and the minibuffer's buffer are refused, each with the state as it was"
      run :=
        pure <|
          match onTextModel sidebar, onTextModel (windowsUnder 1 Layout.default) with
          | some state, some plain =>
            let asking := (prompted state).2
            let minibuffer := asking.minibufferBuffer?.getD ⟨9⟩
            let refused (from_ : EditorState) (buffer : BufferId) (scroll : MarkerId)
              (spot : WindowSpot) (refusal : LayoutRefusal) : Bool :=
              match from_.openWindow buffer scroll (marker 9) spot with
              | (.error got, after) => got == refusal && after == from_
              | _ => false
            (match state.openWindow ⟨0⟩ (marker 8) (marker 9) (.edge .left) with
              | (.ok made, after) =>
                made == ⟨3⟩ && after.wellFormed && after.frame.windows == #[⟨0⟩, ⟨1⟩] &&
                  after.frame.docked == #[(⟨2⟩, .left), (⟨3⟩, .left)] &&
                  after.frame.focused == ⟨0⟩
              | _ => false) &&
              refused plain ⟨0⟩ (marker 8) (.edge .left) (.noSuchEdge .left) &&
              refused state ⟨0⟩ (marker 8) (.edge .right) (.noSuchEdge .right) &&
              refused state ⟨9⟩ (marker 8) .stack (.noSuchBuffer ⟨9⟩) &&
              refused state ⟨0⟩ ⟨⟨5⟩, 0⟩ .stack .markersOfAnotherText &&
              match asking.minibufferView? with
              | some view => refused asking minibuffer ⟨⟨7⟩, 0⟩ .stack (.ofMinibuffer view)
              | none => false
          | _, _ => false }]

/-- The checks of the floating windows of the frame (`Editor/State.lean`, "A
floating window"): the focus rule, a float moved into the tiles and out of
them, what each window operation does with one, what happens when an anchor
goes, opening one, their rectangles, and the spots a publish sets. -/
def floatingWindowChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
  let floating (tiles : Nat) (floats : List (Floating.Anchor × Bool))
    (layout : Layout := Layout.default) : Option EditorState :=
    onTextModel do
      withFloats (← windowsUnder tiles layout) floats
  let floatsOf (state : EditorState) : List Nat := state.frame.floats.toList.map (·.view.index)
  let hasWindow (state : EditorState) (view : Nat) : Bool := (state.window? ⟨view⟩).isSome
  [{  name :=
        "criterion 3: a transient float closes when the focus moves to another window: focusing it keeps it, and moving the focus from it to a tile closes it, which leaves it in neither the floats nor the windows, while a pinned float stays; one opened without the focus closes when the focus moves off the window it was opened from; a prompt asked from it keeps it, and closing the prompt focuses it again"
      run :=
        pure <|
          match floating 2 [(.frame, false)], floating 2 [(.frame, false), (.frame, true)] with
          | some state, some both =>
            let (_, onFloat) := state.focusWindow ⟨2⟩
            let (_, away) := onFloat.focusWindow ⟨1⟩
            let (_, bothAway) := ((both.focusWindow ⟨2⟩).2.focusWindow ⟨1⟩)
            let (_, unfocused) := state.focusWindow ⟨1⟩
            let (_, asking) := prompted onFloat
            let (_, answered) := asking.closePrompt none
            floatsOf onFloat == [2] && onFloat.frame.focused == ⟨2⟩ && floatsOf away == [] &&
              !hasWindow away 2 &&
              away.frame.focused == ⟨1⟩ &&
              floatsOf bothAway == [3] &&
              floatsOf unfocused == [] &&
              unfocused.frame.focused == ⟨1⟩ &&
              floatsOf asking == [2] &&
              answered.frame.focused == ⟨2⟩ &&
              floatsOf answered == [2] &&
              [state, onFloat, away, bothAway, unfocused, asking, answered].all (·.wellFormed)
          | _, _ => false },
    { name :=
        "removing a focused float focuses the window focused before it, or main when there is none; a float never counts as the last window, and the last tile is still refused while floats remain"
      run :=
        pure <|
          match floating 2 [(.frame, true)], floating 2 [(.frame, false)],
            floating 1 [(.frame, true)] with
          | some pinned, some transient, some lone =>
            let (_, viaOne) := (pinned.focusWindow ⟨1⟩).2.focusWindow ⟨2⟩
            let direct := { pinned with frame := { pinned.frame with focused := ⟨2⟩ } }
            let focusAfter (from_ : EditorState) : Option Nat :=
              match from_.removeWindow ⟨2⟩ with
              | (.ok window, after) =>
                if window.id == ⟨2⟩ && after.wellFormed && !hasWindow after 2 then
                  some after.frame.focused.index
                else none
              | _ => none
            focusAfter viaOne == some 1 && focusAfter direct == some 0 &&
              focusAfter (transient.focusWindow ⟨2⟩).2 == some 0 &&
              (match lone.removeWindow ⟨1⟩ with
              | (.ok _, after) => after.wellFormed && after.frame.floats.isEmpty
              | _ => false) &&
              match lone.removeWindow ⟨0⟩ with
              | (.error .onlyWindow, after) => after == lone
              | _ => false
          | _, _, _ => false },
    { name :=
        "criterion 4: a pinned float moved into the tiles joins the stack: under master-and-stack it is appended to the list, focused, and laid out in the stack's part; under manual splits the last tile is split along rows, and under monocle it is appended; a tile moved out of the tiles floats pinned, centred, on top, and the last tile is refused with lastTile"
      run :=
        pure <|
          match floating 2 [(.frame, true)], floating 2 [(.frame, true)] Layout.manual,
            floating 2 [(.frame, true)] .monocle, floating 2 [], floating 1 [] with
          | some state, some manual, some monocle, some two, some one =>
            let joined (from_ : EditorState) := (from_.focusWindow ⟨2⟩).2.arrange ⟨2⟩ .float
            let floated := two.arrange ⟨1⟩ .float
            floatedTo (joined state) == some ([0, 1, 2], [], 2) &&
              (joined state).2.rect? ⟨2⟩ == some (rect 320 232 320 232) &&
              floatedTo (joined manual) == some ([0, 1, 2], [], 2) &&
              (joined manual).2.frame.layout ==
                .splits (.split .rows 1 2 .tile (.split .rows 1 1 .tile .tile)) &&
              floatedTo (joined monocle) == some ([0, 1, 2], [], 2) &&
              (joined monocle).2.frame.layout == .monocle &&
              floatedTo floated == some ([0], [1], 0) &&
              floated.2.frame.floats == #[{ view := ⟨1⟩, anchor := .frame, pinned := true }] &&
              floated.2.rect? ⟨1⟩ == some (rect 128 116 384 232) &&
              match one.arrange ⟨0⟩ .float with
              | (.error .lastTile, after) => after == one
              | _ => false
          | _, _, _, _, _ => false },
    { name :=
        "two tiled windows side by side are carved: the left one gives up the divider's width at its right and the state's dividers are that strip; a float over both is not carved and leaves the dividers as they are without it; the minibuffer's view keeps the strip below the tiled area"
      run :=
        pure <|
          match onTextModel (windowsUnder 2 Layout.default), floating 2 [(.frame, true)] with
          | some two, some floated =>
            let (_, asking) := prompted two
            EditorState.dividerWidth == 2 &&
              two.rects == #[(⟨0⟩, rect 0 0 318 464), (⟨1⟩, rect 320 0 320 464)] &&
              two.dividers == #[rect 318 0 2 464] &&
              floated.dividers == two.dividers &&
              floated.rect? ⟨2⟩ == some (rect 128 116 384 232) &&
              floated.rect? ⟨0⟩ == two.rect? ⟨0⟩ &&
              (asking.minibufferView?.bind asking.rect?) == some asking.cutFrame.2 &&
              asking.dividers == #[rect 318 0 2 asking.tiled.height]
          | _, _ => false },
    { name :=
        "a float is refused a split, a demote, a rotate and an exchange with floating, the state as it was; promote makes it main, the edge command docks it, refused with noSuchEdge where the layout has no edge, and resize steps its share by 5 percent on the axis; zoom from a float anchored to the frame shows the window focused before it under it"
      run :=
        pure <|
          match floating 2 [(.frame, true)],
            onTextModel do
              withFloats (← sidebar) [(.frame, true)] with
          | some state, some edged =>
            let refused (result : Except LayoutRefusal Unit × EditorState) : Bool :=
              match result with
              | (.error (.floating ⟨2⟩), after) => after == state
              | _ => false
            let shareAfter (change : Arrange) : Option Floating.Share :=
              ((state.arrange ⟨2⟩ change).2.frame.floating? ⟨2⟩).map (·.share)
            let zoomed := ((state.focusWindow ⟨2⟩).2.arrange ⟨2⟩ .zoom).2
            (match state.splitWindow ⟨2⟩ (marker 0 8) (marker 0 9) with
              | (.error (.floating ⟨2⟩), after) => after == state
              | _ => false) &&
              refused (state.arrange ⟨2⟩ .demote) &&
              refused (state.arrange ⟨2⟩ (.rotate true)) &&
              refused (state.arrange ⟨2⟩ (.exchange none)) &&
              floatedTo (state.arrange ⟨2⟩ .promote) == some ([2, 0, 1], [], 0) &&
              dockedTo (edged.arrange ⟨3⟩ (.edge .left)) ==
                some ([0, 1], [(2, .left), (3, .left)], 0) &&
              (edged.arrange ⟨3⟩ (.edge .left)).2.frame.floats.isEmpty &&
              (match state.arrange ⟨2⟩ (.edge .left) with
              | (.error (.noSuchEdge .left), after) => after == state
              | _ => false) &&
              shareAfter (.resize .columns true 1) == some { width := 65, height := 50 } &&
              shareAfter (.resize .rows false 2) == some { width := 60, height := 40 } &&
              zoomed.wellFormed &&
              zoomed.rect? ⟨0⟩ == some (rect 0 0 640 464) &&
              zoomed.rect? ⟨1⟩ == none &&
              zoomed.rect? ⟨2⟩ == some (rect 128 116 384 232)
          | _, _ => false },
    { name :=
        "focus by direction from a float reaches a tile beside its rectangle, and never lands on a float; focus in list order walks the tiles, the docked windows, then the floats"
      run :=
        pure <|
          match floating 2 [(.window ⟨1⟩, true)],
            onTextModel do
              withFloats (← sidebar) [(.frame, true)] with
          | some state, some edged =>
            -- View 2 floats centred in view 1, the right half: 192 by 232 at 384, 116.
            state.rect? ⟨2⟩ == some (rect 384 116 192 232) &&
              state.toward? ⟨2⟩ .left 1 == some ⟨0⟩ &&
              state.toward? ⟨2⟩ .right 1 == none &&
              state.toward? ⟨0⟩ .right 1 == some ⟨1⟩ &&
              state.toward? ⟨1⟩ .left 1 == some ⟨0⟩ &&
              edged.cycled ⟨1⟩ true 0 == some ⟨2⟩ &&
              edged.cycled ⟨2⟩ true 0 == some ⟨3⟩ &&
              edged.cycled ⟨3⟩ true 0 == some ⟨0⟩ &&
              edged.cycled ⟨0⟩ false 0 == some ⟨3⟩ &&
              edged.cycled ⟨0⟩ true 9 == some ⟨3⟩ &&
              -- A float nearer than any tile, which focus by direction
              -- passes over: view 3 is 10 pixels right of view 2, and the
              -- tile view 1 is 130.
              match floating 2 [(.window ⟨0⟩, true), (.position ⟨0⟩ (marker 0 1), true)] with
              | none => false
              | some near =>
                let near :=
                  { near with
                    frame :=
                      (near.frame.withFloat ⟨2⟩ ({ · with share := { width := 20 } })).withFloat ⟨3⟩
                        ({ · with
                          share := { width := 10 }
                          spot := some { x := 200, y := 100, height := 16 } }) }
                near.rect? ⟨2⟩ == some (rect 127 116 63 232) &&
                  near.rect? ⟨3⟩ == some (rect 200 116 64 232) &&
                  near.toward? ⟨2⟩ .right 1 == some ⟨1⟩
          | _, _ => false },
    { name :=
        "when a window that floats are anchored to closes, or leaves the tiles for the floats, the transient ones anchored to it close and the pinned ones are anchored to the frame, with no spot; a focused float that closes so gives the focus back"
      run :=
        pure <|
          match
            floating 2 [(.window ⟨1⟩, false), (.position ⟨1⟩ (marker 0 50), true), (.frame, false)],
            onTextModel do
              withFloats (← sidebar) [(.window ⟨2⟩, false), (.window ⟨2⟩, true)] with
          | some state, some edged =>
            let kept : Array Floating :=
              #[{ view := ⟨3⟩, anchor := .frame, pinned := true },
                { view := ⟨4⟩, anchor := .frame }]
            let (_, removed) := state.removeWindow ⟨1⟩
            let (_, floated) := state.arrange ⟨1⟩ .float
            let (_, edgeFloated) := edged.arrange ⟨2⟩ .float
            let (_, onAnchored) := state.focusWindow ⟨2⟩
            let (_, fromFocused) := onAnchored.removeWindow ⟨1⟩
            removed.frame.floats == kept && !hasWindow removed 2 &&
              floated.frame.floats == kept.push { view := ⟨1⟩, anchor := .frame, pinned := true } &&
              !hasWindow floated 2 &&
              edgeFloated.frame.floats ==
                #[{ view := ⟨4⟩, anchor := .frame, pinned := true },
                  { view := ⟨2⟩, anchor := .frame, pinned := true }] &&
              floatsOf fromFocused == [3] &&
              fromFocused.frame.focused == ⟨0⟩ &&
              [removed, floated, edgeFloated, fromFocused].all (·.wellFormed)
          | _, _ => false },
    { name :=
        "showing another buffer in a window closes the transient floats anchored at a position of it and anchors the pinned ones to the frame, since their marker is of the text it showed; a float anchored to the window itself stays"
      run :=
        pure <|
          match
            onTextModel do
              withFloats (← twoBuffers)
                  [(.position ⟨1⟩ (marker 1 50), false), (.window ⟨1⟩, false),
                    (.position ⟨1⟩ (marker 1 51), true)] with
          | none => false
          | some state =>
            match state.showBuffer ⟨1⟩ ⟨0⟩ (marker 0 8) (marker 0 9) with
            | (.ok (), after) =>
              state.wellFormed && after.wellFormed && !hasWindow after 2 &&
                after.frame.floats ==
                  #[{ view := ⟨3⟩, anchor := .window ⟨1⟩ },
                    { view := ⟨4⟩, anchor := .frame, pinned := true }]
            | _ => false },
    { name :=
        "a window opened as a float goes on top of the floats, placed against the frame, a window or a position of that window's buffer, with its share and pinned or not, and the focus stays; it is refused, the state as it was, with noSuchWindow for an anchor window not in the frame, with floating for a float as the anchor, with markersOfAnotherText for a position marker of another text than that window's buffer's, and with noSuchBuffer for a buffer there is none of"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let quarter : Floating.Share := { width := 50, height := 25 }
            let refused (anchor : Floating.Anchor) (refusal : LayoutRefusal)
              (buffer : BufferId := ⟨0⟩) : Bool :=
              match state.openWindow buffer (marker 0 8) (marker 0 9) (.float anchor {} false) with
              | (.error got, after) => got == refusal && after == state
              | _ => false
            [Floating.Anchor.frame, .window ⟨1⟩, .position ⟨1⟩ (marker 1 3)].all
                (fun anchor =>
                  match
                    state.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float anchor quarter true) with
                  | (.ok made, after) =>
                    made == ⟨2⟩ && after.wellFormed && after.frame.focused == ⟨0⟩ &&
                      after.frame.windows == #[⟨0⟩, ⟨1⟩] &&
                      after.frame.floats ==
                        #[{ view := ⟨2⟩, anchor, share := quarter, pinned := true }] &&
                      (after.window? ⟨2⟩).map (·.buffer) == some ⟨0⟩
                  | _ => false) &&
              refused (.window ⟨9⟩) (.noSuchWindow ⟨9⟩) &&
              refused (.position ⟨1⟩ (marker 0 3)) .markersOfAnotherText &&
              refused .frame (.noSuchBuffer ⟨9⟩) ⟨9⟩ &&
              match state.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float .frame {} false) with
              | (.ok made, after) =>
                match
                  after.openWindow ⟨0⟩ (marker 0 10) (marker 0 11)
                    (.float (.window made) {} false) with
                | (.error (.floating view), again) => view == made && again == after
                | _ => false
              | _ => false },
    { name :=
        "the rectangles of floats come after the tiles and the docked windows and before the minibuffer's view, in stacking order: one anchored to the frame centred in the tiled area, to a window centred in its rectangle, or in the tiled area when monocle hides it, at a position beside its spot, and before it has one as for its window"
      run :=
        pure <|
          match
            onTextModel do
              withFloats (← sidebar)
                  [(.frame, false), (.window ⟨1⟩, true), (.position ⟨0⟩ (marker 0 3), true),
                    (.position ⟨1⟩ (marker 0 4), true)],
            floating 2 [(.window ⟨1⟩, true)] .monocle with
          | some state, some monocle =>
            let spotted :=
              { state with
                frame :=
                  state.frame.withFloat ⟨5⟩
                    ({ · with spot := some { x := 200, y := 40, height := 16 } }) }
            let asking := (prompted spotted).2
            spotted.rects ==
                #[(⟨0⟩, rect 160 0 238 464), (⟨1⟩, rect 400 0 240 464), (⟨2⟩, rect 0 0 158 464),
                  (⟨3⟩, rect 128 116 384 232), (⟨4⟩, rect 448 116 144 232),
                  (⟨5⟩, rect 200 56 384 232), (⟨6⟩, rect 448 116 144 232)] &&
              asking.rects.map (·.1) ==
                #[⟨0⟩, ⟨1⟩, ⟨2⟩, ⟨3⟩, ⟨4⟩, ⟨5⟩, ⟨6⟩] ++ asking.minibufferView?.toArray &&
              spotted.wellFormed &&
              asking.wellFormed &&
              monocle.rect? ⟨1⟩ == none &&
              monocle.rect? ⟨2⟩ == some (rect 128 116 384 232)
          | _, _ => false },
    { name :=
        "a publish's spots are offset by the anchor window's rectangle into frame pixels; a transient float whose anchor is not drawn closes, whether the display answered none or its window has no rectangle, and the focus on it goes back; a pinned one keeps its last spot"
      run :=
        pure <|
          match
            floating 2
              [(.position ⟨1⟩ (marker 0 3), false), (.position ⟨1⟩ (marker 0 4), true),
                (.position ⟨0⟩ (marker 0 5), false)],
            floating 2 [(.window ⟨1⟩, false), (.window ⟨1⟩, true)] .monocle with
          | some state, some monocle =>
            let spot (x y : Nat) : Display.Spot := { x, y, height := 16 }
            let first :=
              state.located
                #[(⟨2⟩, some (spot 8 24)), (⟨3⟩, some (spot 16 40)), (⟨4⟩, some (spot 0 0))]
            let second := first.located #[(⟨2⟩, none), (⟨3⟩, none), (⟨4⟩, some (spot 0 16))]
            let spots (state : EditorState) : List (Nat × Option Display.Spot) :=
              state.frame.floats.toList.map fun float => (float.view.index, float.spot)
            let onFloat := (first.focusWindow ⟨4⟩).2
            let closedFocused := onFloat.located #[(⟨4⟩, none)]
            spots first ==
                [(2, some (spot 328 24)), (3, some (spot 336 40)), (4, some (spot 0 0))] &&
              spots second == [(3, some (spot 336 40)), (4, some (spot 0 16))] &&
              !hasWindow second 2 &&
              floatsOf (monocle.located #[]) == [3] &&
              closedFocused.frame.focused == ⟨0⟩ &&
              floatsOf closedFocused == [3] &&
              [first, second, monocle.located #[], closedFocused].all (·.wellFormed)
          | _, _ => false },
    { name :=
        "zoomed on a tile that is not the first, a focused transient float anchored to it keeps that tile under it: monocle shows the float's anchor window, at a position or the window itself, so the publish keeps the float open; a float anchored to the frame shows the window focused before it, and a prompt asked from the float shows its anchor too"
      run :=
        pure <|
          -- Three tiles zoomed on view 1, then a transient float, view 3,
          -- anchored to it and focused.
          let zoomedFloat (anchor : Floating.Anchor) : Option EditorState :=
            onTextModel do
              let state ← windowsUnder 3 Layout.default
              let state := ((state.focusWindow ⟨1⟩).2.arrange ⟨1⟩ .zoom).2
              let state ← withFloats state [(anchor, false)]
              return (state.focusWindow ⟨3⟩).2
          let spot : Display.Spot := { x := 8, y := 24, height := 16 }
          match zoomedFloat (.position ⟨1⟩ (marker 0 3)), zoomedFloat (.window ⟨1⟩),
            zoomedFloat .frame with
          | some atPosition, some onWindow, some onFrame =>
            let kept (state : EditorState) : Bool :=
              state.frame.layout == .monocle && state.frame.focused == ⟨3⟩ &&
                state.rects.map (·.1) == #[⟨1⟩, ⟨3⟩] &&
                state.rect? ⟨1⟩ == some (rect 0 0 640 464) &&
                floatsOf state == [3] &&
                state.wellFormed
            let located := atPosition.located #[(⟨3⟩, some spot)]
            kept atPosition && kept located &&
              (located.frame.floating? ⟨3⟩).bind (·.spot) == some spot &&
              kept onWindow &&
              kept (onWindow.located #[]) &&
              kept onFrame &&
              (prompted atPosition).2.rect? ⟨1⟩ == some (rect 0 0 640 448) &&
              ((prompted atPosition).2.located #[(⟨3⟩, some spot)]).frame.floats.size == 1
          | _, _, _ => false }]

/-- The checks of the editor state and its layout invariants
(`Editor/State.lean`), on the text model. -/
def stateChecks : List Check :=
  [{      name :=
            "the initial state is well formed: one scratch buffer, one window on it, the only one of the frame's list, the default layout, and the focus on view 0"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                state.wellFormed && state.buffers.map (·.map (·.name)) == #[some "scratch"] &&
                  state.windows.map (·.id) == #[⟨0⟩] &&
                  state.frame.windows == #[⟨0⟩] &&
                  state.frame.layout == Layout.default &&
                  state.frame.focused == ⟨0⟩ &&
                  state.frame.hasFocus &&
                  state.echo == "" &&
                  state.preedit == none },
        { name :=
            "the order buffers were used in: the initial state's is its one buffer; focusing a window puts its buffer first, adding a buffer puts it last, showing a buffer puts it first, removing one takes it out; opening a prompt, focusing the minibuffer and closing the prompt leave it as it was; each state is well formed"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let (_, focused) := state.focusWindow ⟨1⟩
                let (_, added) := focused.addBuffer "third" ⟨2⟩ (UndoTree.new ⟨2⟩ 0)
                let (_, shown) := added.showBuffer ⟨0⟩ ⟨2⟩ ⟨⟨2⟩, 0⟩ ⟨⟨2⟩, 1⟩
                let (_, removed) := shown.removeBuffer ⟨0⟩
                let (_, asking) := prompted removed
                let (_, back) := asking.focusWindow ⟨1⟩
                let (_, again) := back.focusWindow (asking.minibufferView?.getD ⟨9⟩)
                let (_, closed) := again.closePrompt none
                state.recent == #[⟨0⟩] && focused.recent == #[⟨1⟩, ⟨0⟩] &&
                  added.recent == #[⟨1⟩, ⟨0⟩, ⟨2⟩] &&
                  shown.recent == #[⟨2⟩, ⟨1⟩, ⟨0⟩] &&
                  removed.recent == #[⟨2⟩, ⟨1⟩] &&
                  asking.recent == removed.recent &&
                  asking.minibufferView?.isSome &&
                  back.recent == #[⟨1⟩, ⟨2⟩] &&
                  again.recent == back.recent &&
                  again.frame.focused == asking.frame.focused &&
                  closed.recent == back.recent &&
                  [state, focused, added, shown, removed, asking, back, again, closed].all
                    (·.wellFormed) },
        { name :=
            "the most recently used buffer but one is the first of the order that is open and is neither it nor the minibuffer's, and with no order the first such buffer by slot; none when no other buffer is open; the open buffers are the order's, then the rest by slot, without the minibuffer's"
          run :=
            pure <|
              match onTextModel twoBuffers, onTextModel (EditorState.initial ⟨640, 480⟩) with
              | some state, some alone =>
                let (_, added) := state.addBuffer "third" ⟨2⟩ (UndoTree.new ⟨2⟩ 0)
                let (_, asking) := prompted { added with recent := #[⟨2⟩, ⟨0⟩] }
                let unordered := { asking with recent := #[] }
                let (_, lonely) := prompted alone
                asking.mostRecent ⟨2⟩ == some ⟨0⟩ && asking.mostRecent ⟨0⟩ == some ⟨2⟩ &&
                  unordered.mostRecent ⟨0⟩ == some ⟨1⟩ &&
                  unordered.mostRecent ⟨1⟩ == some ⟨0⟩ &&
                  alone.mostRecent ⟨0⟩ == none &&
                  lonely.minibufferBuffer? == some ⟨1⟩ &&
                  lonely.mostRecent ⟨0⟩ == none &&
                  { lonely with recent := #[] }.mostRecent ⟨0⟩ == none &&
                  asking.minibufferBuffer? == some ⟨3⟩ &&
                  asking.openBuffers == #[⟨2⟩, ⟨0⟩, ⟨1⟩] &&
                  unordered.openBuffers == #[⟨0⟩, ⟨1⟩, ⟨2⟩]
              | _, _ => false },
        { name :=
            "the initial state's buffer has no file, and its line ending is a line feed; no path finds a buffer"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                ((state.buffer? ⟨0⟩).map fun buffer => (buffer.file, buffer.lineEnding)) ==
                    some (none, .lf) &&
                  state.findFile "/files/note.txt" == none },
        { name := "why a job was not started names the job, as a sentence for the echo area"
          run :=
            pure
              (((JobRefusal.noSuchJob "load-it").describe.splitOn "load-it").length == 2 &&
                (JobRefusal.noSuchJob "a").describe != (JobRefusal.noSuchJob "b").describe) },
        { name :=
            "a free name is the name itself when no buffer has it, and otherwise the name followed by <2>, <3> and so on, the first no buffer has"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let named (names : List String) : EditorState :=
                  names.foldl (fun state name => (state.addBuffer name ⟨1⟩ (UndoTree.new ⟨1⟩ 0)).2)
                    state
                state.freeName "new" == "new" && state.freeName "other" == "other<2>" &&
                  (named ["other<2>"]).freeName "other" == "other<3>" &&
                  (named ["other<3>"]).freeName "other" == "other<2>" &&
                  (named ["other<2>", "other<3>"]).freeName "other" == "other<4>" &&
                  (named ["other<2>"]).freeName "other<2>" == "other<2><2>" },
        { name :=
            "a frame of three tabs: its tabs in order, the one in view second at index 1, every window of every tab, and the tab of each window; none for a window of no tab"
          run :=
            pure <|
              match onTextModel threeTabs with
              | none => false
              | some state =>
                let frame := state.frame
                frame.tabs.map (·.windows) == #[#[⟨0⟩], #[⟨1⟩], #[⟨2⟩]] &&
                  frame.tabs[1]? == some frame.toTab &&
                  frame.tabIndex == 1 &&
                  frame.everyWindow == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
                  [0, 1, 2].all (fun index => frame.tabOf? ⟨index⟩ == some index) &&
                  frame.tabOf? ⟨7⟩ == none &&
                  state.wellFormed },
        { name :=
            "selecting a tab of a frame of three tabs brings it into view, keeps the order of the tabs, and selecting the tab that was in view again gives back the frame it started from, for every tab; an index past the last changes nothing"
          run :=
            pure <|
              match onTextModel threeTabs with
              | none => false
              | some state =>
                let frame := state.frame
                [0, 1, 2].all
                    (fun index =>
                      let moved := frame.selected index
                      moved.tabIndex == index && moved.tabs == frame.tabs &&
                        frame.tabs[index]? == some moved.toTab &&
                        moved.selected frame.tabIndex == frame &&
                        { state with frame := moved }.wellFormed) &&
                  frame.selected 3 == frame },
        { name := "a state of two tabs, each with its windows, layout and focus, is well formed"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                { state with
                    frame :=
                      { state.frame with
                        windows := #[⟨0⟩, ⟨1⟩]
                        tabsAfter :=
                          #[{ windows := #[⟨2⟩], focused := ⟨2⟩,
                              layout := .splits .tile }] } }.wellFormed },
        { name :=
            "a state that breaks one layout invariant is not well formed: a focus outside the list, a window named twice, a list entry with no window, a window outside the list, a window with no buffer, a prompt whose view has no window, a prompt whose view is a window of the list, a prompt whose choice is past its listing, an order of use that names a removed buffer or one buffer twice, a hidden tab with no tile, a hidden tab focused outside itself, a window in two tabs, a hidden tab whose split tree does not fit its list, a hidden tab's float anchored in the tab in view; and the same prompt with a choice in its listing is well formed"
          run := do
            let some state := onTextModel threeWindows | return false
            -- A failure names the spoiled states that were taken for well formed.
            let accepted := spoilings.filter fun (_, spoil) => (spoil state).wellFormed
            unless accepted.isEmpty do
              throw
                  (IO.userError
                    s!"well formed: a state {"; a state ".intercalate (accepted.map (·.1))}")
            let (_, chosen) := (picking (prompted state).2).chooseCandidate .previous
            return state.wellFormed && chosen.wellFormed &&
                chosen.prompt.map (·.candidates.chosen) == some (some 2) },
        { name :=
            "the rectangles of a state's views: the windows laid out by the frame's layout in the tiled area and carved, the frame above the minibuffer's strip, which is the bottom message height with no prompt open, a text row and that with one, and the whole height where the frame is shorter; the minibuffer's view in that strip while a prompt is open; under monocle only the selected window, the asker while a prompt is open"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                let rect (x y width height : Nat) : Rect := { x, y, width, height }
                let sized (size : Size) (state : EditorState) : EditorState :=
                  { state with
                    heights := { text := 20, status := 18, message := 12 }
                    frame := { state.frame with size } }
                let windows := #[⟨0⟩, ⟨1⟩, ⟨2⟩]
                let plain := sized ⟨640, 480⟩ state
                let asking := sized ⟨640, 480⟩ (prompted state).2
                let short := sized ⟨640, 10⟩ (prompted state).2
                let monocle (state : EditorState) : EditorState :=
                  { state with frame := { state.frame with layout := .monocle } }
                let onOne := (state.focusWindow ⟨1⟩).2
                let alone := sized ⟨640, 480⟩ (monocle onOne)
                let aloneAsking := sized ⟨640, 480⟩ (prompted (monocle onOne)).2
                plain.tiled == rect 0 0 640 468 &&
                  plain.rects ==
                    (Layout.carve plain.tiled 2 (Layout.default.place windows ⟨0⟩ plain.tiled)).1 &&
                  asking.tiled == rect 0 0 640 448 &&
                  asking.rects ==
                    (Layout.carve asking.tiled 2
                          (Layout.default.place windows ⟨0⟩ asking.tiled)).1 ++
                      #[(⟨3⟩, rect 0 448 640 32)] &&
                  short.tiled == rect 0 0 640 0 &&
                  short.rects.back? == some (⟨3⟩, rect 0 0 640 10) &&
                  alone.rects == #[(⟨1⟩, rect 0 0 640 468)] &&
                  aloneAsking.frame.focused == ⟨3⟩ &&
                  aloneAsking.rects == #[(⟨1⟩, rect 0 0 640 448), (⟨3⟩, rect 0 448 640 32)] &&
                  [plain, asking, short, alone, aloneAsking].all (·.wellFormed) },
        { name :=
            "with a prompt open the views and the dividers tile the frame, the windows in list order and the minibuffer's view last, and with none the windows and the dividers tile the frame above the bottom row, at even, odd and zero sizes and under every layout"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                sampleSizes.all fun size =>
                  [Layout.default, .masterStack { share := 61, side := .bottom }, .monocle].all
                    fun layout =>
                    let shaped (state : EditorState) : EditorState :=
                      { state with
                        frame :=
                          { state.frame with
                            size, layout } }
                    let plain := shaped state
                    let asking := shaped (prompted state).2
                    tiles plain.tiled (plain.rects.map (·.2) ++ plain.dividers) &&
                      tiles (frameRect size) (asking.rects.map (·.2) ++ asking.dividers) &&
                      (asking.rects.map (·.1)).back? == asking.minibufferView? &&
                      (layout == .monocle || plain.rects.map (·.1) == plain.frame.windows) },
        { name := "removing the only window is refused with onlyWindow, and the state is as it was"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                match state.removeWindow ⟨0⟩ with
                | (.error .onlyWindow, after) => after == state
                | _ => false },
        { name :=
            "focusing a window that is not in the list is refused with noSuchWindow, and the state is as it was; so is removing one"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                (match state.focusWindow ⟨7⟩ with
                  | (.error (.noSuchWindow id), after) => id == ⟨7⟩ && after == state
                  | _ => false) &&
                  match state.removeWindow ⟨7⟩ with
                  | (.error (.noSuchWindow id), after) => id == ⟨7⟩ && after == state
                  | _ => false },
        { name :=
            "removing a window of three keeps the state well formed, takes it out of the list, whose layout gives its space to the rest, and hands back the window; the focus moves to the window that took its index, or to the new last window when it was last"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                let left := { x := 0, y := 0, width := 318, height := 464 }
                let right := { x := 320, y := 0, width := 320, height := 464 }
                let (_, onOne) := state.focusWindow ⟨1⟩
                let (_, onTwo) := state.focusWindow ⟨2⟩
                state.wellFormed &&
                  (match state.removeWindow ⟨0⟩ with
                  | (.ok removed, after) =>
                    removed.id == ⟨0⟩ && after.wellFormed && after.frame.focused == ⟨1⟩ &&
                      after.windows.map (·.id) == #[⟨1⟩, ⟨2⟩] &&
                      after.frame.windows == #[⟨1⟩, ⟨2⟩] &&
                      laidOut after == #[(⟨1⟩, left), (⟨2⟩, right)]
                  | _ => false) &&
                  (match state.removeWindow ⟨1⟩ with
                  | (.ok _, after) =>
                    after.wellFormed && after.frame.focused == ⟨0⟩ &&
                      laidOut after == #[(⟨0⟩, left), (⟨2⟩, right)]
                  | _ => false) &&
                  (match onOne.removeWindow ⟨1⟩ with
                  | (.ok _, after) => after.wellFormed && after.frame.focused == ⟨2⟩
                  | _ => false) &&
                  onTwo.frame.focused == ⟨2⟩ &&
                  match onTwo.removeWindow ⟨2⟩ with
                  | (.ok _, after) =>
                    after.wellFormed && after.frame.focused == ⟨1⟩ &&
                      laidOut after == #[(⟨0⟩, left), (⟨1⟩, right)]
                  | _ => false },
        { name :=
            "focusing a window in the list sets the frame's focus, and the window focused before it as the last focused, and changes nothing else"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                match state.focusWindow ⟨1⟩ with
                | (.ok (), after) =>
                  after.frame.focused == ⟨1⟩ &&
                    after ==
                      { state with
                        frame :=
                          { state.frame with
                            focused := ⟨1⟩, lastFocused := some ⟨0⟩ } }
                | _ => false },
        { name := "the initial state's window keeps no wanted column"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state => (state.window? ⟨0⟩).map (·.wanted) == some none },
        { name :=
            "the initial state has no register: none is read under the empty name, under a letter or under the clipboard's name"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                state.registers.isEmpty && ["", "\"", "a", "+"].all (state.register? · == none) },
        { name :=
            "a register set under a name is read back under that name with its text and whether it is line-wise, and under no other; a second one set under the name replaces it, and a register under another name stays; nothing else of the state changes"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                let word : Register := { text := "word" }
                let line : Register := { text := "a line\n", linewise := true }
                let once := state.setRegister "a" word
                let both := once.setRegister "b" line
                let again := both.setRegister "a" line
                once.register? "a" == some word && once.register? "b" == none &&
                  once.register? "" == none &&
                  !word.linewise &&
                  both.register? "a" == some word &&
                  both.register? "b" == some line &&
                  again.register? "a" == some line &&
                  again.register? "b" == some line &&
                  again.registers.size == 2 &&
                  { again with registers := #[] } == state &&
                  (state.setRegister "" word).register? "" == some word },
        { name :=
            "a new state's scroll margin is no rows; a margin set is the state's, a second one set replaces it, and nothing else of the state changes"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                let two := state.setScrollMargin 2
                let five := two.setScrollMargin 5
                state.scrollMargin == 0 && two.scrollMargin == 2 && five.scrollMargin == 5 &&
                  two != state &&
                  { five with scrollMargin := 0 } == state &&
                  five.setScrollMargin 0 == state &&
                  two.wellFormed },
        { name :=
            "the initial state's selection is one cursor at 0, of the shape the state is made with, and exclusive when it is made with none"
          run :=
            pure <|
              let cursor (start : TextM EditorState) : Option Marker :=
                onTextModel do
                  let some target := (← start).focusedTarget? | throw .noSuchText
                  target.buffer.text.marker target.window.selection
              let one (shape : Shape) : Option Marker :=
                some (.selection { ranges := #[⟨0, 0⟩], shape })
              cursor (EditorState.initial ⟨640, 480⟩) == one .exclusive &&
                cursor (EditorState.initial ⟨640, 480⟩ .inclusive) == one .inclusive &&
                cursor (EditorState.initial ⟨640, 480⟩ .line) == one .line },
        { name :=
            "setting a window's wanted column keeps the column with the head it was kept at, and leaves the other windows and the rest of the state; setting none keeps none again"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                let kept : Window.Wanted := { column := .goal 3, head := 7 }
                let wanted (state : EditorState) (index : Nat) : Option (Option Window.Wanted) :=
                  (state.window? ⟨index⟩).map (·.wanted)
                match state.setWanted ⟨1⟩ (some kept) with
                | (.ok (), after) =>
                  wanted after 1 == some (some kept) && wanted after 0 == some none &&
                    wanted after 2 == some none &&
                    after ==
                      { state with
                        windows :=
                          state.windows.map fun window =>
                            if window.id == ⟨1⟩ then { window with wanted := some kept }
                            else window } &&
                    (match after.setWanted ⟨1⟩ (some { column := .lineEnd, head := 2 }) with
                    | (.ok (), ends) =>
                      wanted ends 1 == some (some { column := .lineEnd, head := 2 })
                    | _ => false) &&
                    match after.setWanted ⟨1⟩ none with
                    | (.ok (), cleared) => cleared == state
                    | _ => false
                | _ => false },
        { name :=
            "setting the wanted column of a view with no window is refused with noSuchWindow, and the state is as it was"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                match state.setWanted ⟨7⟩ (some { column := .goal 3, head := 7 }) with
                | (.error (.noSuchWindow id), after) => id == ⟨7⟩ && after == state
                | _ => false },
        { name :=
            "a window shown another buffer keeps no wanted column, and a window a split makes has none while its source keeps its own"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let kept : Window.Wanted := { column := .goal 3, head := 4 }
                let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
                let (_, keeping) := state.setWanted ⟨0⟩ (some kept)
                let wanted (state : EditorState) (index : Nat) : Option (Option Window.Wanted) :=
                  (state.window? ⟨index⟩).map (·.wanted)
                (match keeping.showBuffer ⟨0⟩ ⟨1⟩ (marker 1 8) (marker 1 9) with
                  | (.ok (), shown) =>
                    wanted keeping 0 == some (some kept) && wanted shown 0 == some none
                  | _ => false) &&
                  match keeping.splitWindow ⟨0⟩ (marker 0 8) (marker 0 9) with
                  | (.ok made, split) =>
                    wanted split made.index == some none && wanted split 0 == some (some kept)
                  | _ => false },
        { name :=
            "setting a buffer's major mode names it and says it became the major mode, leaving the other buffers; setting it again changes nothing and says not; another mode replaces it"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let major (state : EditorState) (index : Nat) : Option String :=
                  (state.buffer? ⟨index⟩).bind (·.major)
                match state.setMajorMode ⟨1⟩ "listing" with
                | (.ok true, listed) =>
                  major state 1 == none && major listed 1 == some "listing" &&
                    major listed 0 == none &&
                    listed ==
                      { state with
                        buffers :=
                          state.buffers.modify 1 (·.map ({ · with major := some "listing" })) } &&
                    (match listed.setMajorMode ⟨1⟩ "listing" with
                    | (.ok false, again) => again == listed
                    | _ => false) &&
                    match listed.setMajorMode ⟨1⟩ "other" with
                    | (.ok true, other) => major other 1 == some "other"
                    | _ => false
                | _ => false },
        { name :=
            "a minor mode added is first and added once, and removing one takes it away; removing one not there changes nothing"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let minors (state : EditorState) : Array String :=
                  ((state.buffer? ⟨0⟩).map (·.minors)).getD #[]
                let (_, one) := state.addMinorMode ⟨0⟩ "one"
                let (_, two) := one.addMinorMode ⟨0⟩ "two"
                let (added, again) := two.addMinorMode ⟨0⟩ "one"
                let (removed, without) := two.removeMinorMode ⟨0⟩ "one"
                let (absent, unchanged) := two.removeMinorMode ⟨0⟩ "three"
                minors state == #[] && minors one == #["one"] && minors two == #["two", "one"] &&
                  added matches .ok () &&
                  again == two &&
                  removed matches .ok () &&
                  minors without == #["two"] &&
                  absent matches .ok () &&
                  unchanged == two &&
                  ((two.buffer? ⟨1⟩).map (·.minors)) == some #[] },
        { name :=
            "setting a major mode, adding a minor mode and removing one each refuse a buffer there is none of with noSuchBuffer, and the state is as it was"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let refused {α : Type} : Except BufferRefusal α × EditorState → Bool
                  | (.error (.noSuchBuffer id), after) => id == ⟨5⟩ && after == state
                  | _ => false
                refused (state.setMajorMode ⟨5⟩ "listing") &&
                  refused (state.addMinorMode ⟨5⟩ "one") &&
                  refused (state.removeMinorMode ⟨5⟩ "one") },
        { name := "the initial state has no prompt open"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state => state.prompt == none },
        { name :=
            "opening a prompt replies the minibuffer's view, a new one: the state has the prompt with its label, its continuation and the focused view as its asker, a buffer in the next slot over the text given, with the minibuffer's mode and a name no other buffer has, a window on it with the markers given, the focus on it, and the window list as it was; it is well formed"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                match prompted state with
                | (.ok view, after) =>
                  view == ⟨1⟩ &&
                    after.prompt ==
                      some
                        { label := "Name: ", view := ⟨1⟩, asker := ⟨0⟩, continuation := asked } &&
                    after.buffers.size == 2 &&
                    after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
                    after.buffer? ⟨1⟩ ==
                      some
                        { name := Prompt.bufferName, text := ⟨7⟩, history := UndoTree.new ⟨7⟩ 0
                          major := some Prompt.mode } &&
                    state.findBuffer Prompt.bufferName == none &&
                    after.windows ==
                      state.windows.push
                        { id := ⟨1⟩, buffer := ⟨1⟩, scroll := ⟨⟨7⟩, 0⟩, selection := ⟨⟨7⟩, 1⟩ } &&
                    after.frame == { state.frame with focused := ⟨1⟩ } &&
                    after.nextView == 2 &&
                    after.wellFormed
                | _ => false },
        { name :=
            "the minibuffer's buffer gets the next free name when a buffer is already called by the minibuffer's name"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, named) := state.addBuffer Prompt.bufferName ⟨3⟩ (UndoTree.new ⟨3⟩ 0)
                match prompted named with
                | (.ok _, after) =>
                  (after.buffer? ⟨2⟩).map (·.name) == some s!"{Prompt.bufferName}<2>" &&
                    after.findBuffer Prompt.bufferName == some ⟨1⟩ &&
                    after.wellFormed
                | _ => false },
        { name :=
            "a second prompt is refused with alreadyOpen and the open prompt's view, a history or a marker of another text than the minibuffer's with notItsText, and a prompt asked for with no window focused with noWindow, each with the state as it was"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let refused (refusal : PromptRefusal) (was : EditorState) :
                  Except PromptRefusal ViewId × EditorState → Bool
                  | (.error why, after) => why == refusal && after == was
                  | _ => false
                let astray (history scroll selection : Nat) :=
                  state.openPrompt "Name: " asked ⟨7⟩ (UndoTree.new ⟨history⟩ 0) ⟨⟨scroll⟩, 0⟩
                    ⟨⟨selection⟩, 1⟩
                asking.prompt.isSome && refused (.alreadyOpen ⟨1⟩) asking (prompted asking 8) &&
                  refused .notItsText state (astray 0 7 7) &&
                  refused .notItsText state (astray 7 0 7) &&
                  refused .notItsText state (astray 7 7 0) &&
                  refused .noWindow EditorState.none (prompted EditorState.none) },
        { name :=
            "the focus leaves the minibuffer's view for a window of the list and comes back to it, and nothing else changes"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                match asking.focusWindow ⟨0⟩ with
                | (.ok (), away) =>
                  away == { asking with frame := { asking.frame with focused := ⟨0⟩ } } &&
                    away.wellFormed &&
                    match away.focusWindow ⟨1⟩ with
                    | (.ok (), back) => back == asking
                    | _ => false
                | _ => false },
        { name :=
            "removing, splitting and showing another buffer in the minibuffer's view, and showing the minibuffer's buffer in another window, are each refused with ofMinibuffer and the minibuffer's view, with the state as it was"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let refused {α : Type} : Except LayoutRefusal α × EditorState → Bool
                  | (.error (.ofMinibuffer view), after) => view == ⟨2⟩ && after == asking
                  | _ => false
                asking.prompt.map (·.view) == some ⟨2⟩ && refused (asking.removeWindow ⟨2⟩) &&
                  refused (asking.splitWindow ⟨2⟩ ⟨⟨7⟩, 2⟩ ⟨⟨7⟩, 3⟩) &&
                  refused (asking.showBuffer ⟨2⟩ ⟨1⟩ ⟨⟨1⟩, 8⟩ ⟨⟨1⟩, 9⟩) &&
                  refused (asking.showBuffer ⟨0⟩ ⟨2⟩ ⟨⟨7⟩, 2⟩ ⟨⟨7⟩, 3⟩) },
        { name :=
            "with a prompt open over two windows, removing one window is done and leaves the prompt open, and removing the other is refused with onlyWindow: the minibuffer's window does not count"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                match asking.removeWindow ⟨1⟩ with
                | (.ok removed, one) =>
                  removed.id == ⟨1⟩ && one.wellFormed && one.prompt == asking.prompt &&
                    one.frame.focused == ⟨2⟩ &&
                    one.windows.map (·.id) == #[⟨0⟩, ⟨2⟩] &&
                    match one.removeWindow ⟨0⟩ with
                    | (.error .onlyWindow, same) => same == one
                    | _ => false
                | _ => false },
        { name :=
            "removing the minibuffer's buffer while its prompt is open is refused with shown and the minibuffer's view"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                match asking.removeBuffer ⟨1⟩ with
                | (.error (.shown view), after) => view == ⟨1⟩ && after == asking
                | _ => false },
        { name := "why a prompt was refused is a sentence for the echo area, one for each refusal"
          run :=
            pure <|
              (([PromptRefusal.alreadyOpen ⟨1⟩, .notOpen, .notItsText, .noWindow,
                            .noSuchSource "a"].map
                        PromptRefusal.describe).eraseDups.length ==
                    5 &&
                  [PromptRefusal.alreadyOpen ⟨1⟩, .notOpen, .notItsText, .noWindow,
                        .noSuchSource "a"].all
                    fun refusal => !refusal.describe.isEmpty) &&
                PromptRefusal.describe (.noSuchSource "picks") ==
                  "no completion source is registered under `picks`" },
        { name :=
            "closing a prompt with no answer leaves no prompt: the minibuffer's window is gone, its buffer's slot is empty, the focus is on the asking view, the window list and the next view's id are as they were after the open, and nothing is answered; the state is well formed"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                match asking.closePrompt none with
                | (.ok (), closed) =>
                  closed ==
                      { state with
                        buffers := state.buffers.push none, nextView := 2 } &&
                    closed.prompt == none &&
                    closed.window? ⟨1⟩ == none &&
                    closed.buffers[1]? == some none &&
                    closed.frame.focused == ⟨0⟩ &&
                    closed.frame.windows == asking.frame.windows &&
                    closed.nextView == asking.nextView &&
                    closed.outbox.answered == #[] &&
                    closed.wellFormed
                | _ => false },
        { name :=
            "closing a prompt with an answer does the same, and records the continuation with the answer as its first argument, before its own"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                match asking.closePrompt none, asking.closePrompt (some "héllo") with
                | (.ok (), cancelled), (.ok (), accepted) =>
                  accepted.outbox.answered ==
                      #[{ command := "greet", arguments := [.str "héllo", .nat 7] }] &&
                    { accepted with outbox.answered := #[] } == cancelled &&
                    accepted.wellFormed
                | _, _ => false },
        { name :=
            "two prompts opened and accepted one after the other leave two answered invocations, in order, and the second prompt's view and buffer have ids the first's never had"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (first, one) := prompted state
                let (_, one) := one.closePrompt (some "a")
                let (second, two) := prompted one 8
                let minibuffer := two.minibufferBuffer?
                let (_, two) := two.closePrompt (some "b")
                replied first == .inr ⟨1⟩ && replied second == .inr ⟨2⟩ && minibuffer == some ⟨2⟩ &&
                  two.outbox.answered ==
                    #[{ command := "greet", arguments := [.str "a", .nat 7] },
                      { command := "greet", arguments := [.str "b", .nat 7] }] &&
                  two.buffers.size == 3 &&
                  two.nextView == 3 &&
                  two.wellFormed },
        { name :=
            "closing a prompt gives the focus back to the asking view, though the focus was moved to another window meanwhile"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let (_, away) := asking.focusWindow ⟨1⟩
                let (_, closed) := away.closePrompt (some "a")
                asking.prompt.map (·.asker) == some ⟨0⟩ && away.frame.focused == ⟨1⟩ &&
                  closed.frame.focused == ⟨0⟩ &&
                  closed.wellFormed },
        { name :=
            "when the asking view was removed while the prompt was open, the prompt stays open, and closing it focuses the first window of the list"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let (removed, without) := asking.removeWindow ⟨0⟩
                let (_, closed) := without.closePrompt (some "a")
                (replied removed).isRight && without.prompt == asking.prompt &&
                  without.wellFormed &&
                  without.frame.focused == ⟨3⟩ &&
                  closed.frame.focused == ⟨1⟩ &&
                  closed.frame.windows == #[⟨1⟩, ⟨2⟩] &&
                  closed.outbox.answered.size == 1 &&
                  closed.wellFormed },
        { name :=
            "closing a prompt when none is open is refused with notOpen, with or without an answer, and the state is as it was"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                [none, some "a"].all fun answer =>
                  match state.closePrompt answer with
                  | (.error .notOpen, after) => after == state
                  | _ => false },
        { name :=
            "a prompt is opened with no candidates, no listing and no choice, and a prompt opened after one with candidates was closed has none either"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let (_, chosen) := (picking asking).chooseCandidate .next
                let (_, closed) := chosen.closePrompt (some "a")
                let (_, again) := prompted closed 8
                asking.prompt.map (·.candidates) == some {} &&
                  (chosen.prompt.map (·.candidates.chosen)) == some (some 0) &&
                  closed.prompt == none &&
                  again.prompt.map (·.candidates) == some {} },
        { name :=
            "a prompt's candidates to match are its own, then what each asking source that has not filtered answered, in the asking order; those listed as given are its passed ones, then what each filtered asking source answered; and the size to match is counted over the sources"
          run :=
            pure <|
              let later : Completion.Later := { job := "j" }
              let asking : Array Completion.Asking :=
                #[{ source := "a", later, askedFor := "", answered := offered #["a1"] },
                  { source := "f", filtered := true, later, askedFor := "",
                    answered := offered #["f1"] },
                  { source := "b", later, askedFor := "", answered := offered #["b1", "b2"] }]
              let candidates : Candidates :=
                { all := offered #["x"], passed := offered #["p"], asking }
              candidates.matchable.map (·.text) == #["x", "a1", "b1", "b2"] &&
                candidates.passing.map (·.text) == #["p", "f1"] &&
                candidates.matchableSize == 4 &&
                ({} : Candidates).matchable.isEmpty },
        { name :=
            "relisting for the text the listing was made for keeps the choice on the same candidate, wherever it now is; relisting for another text, or without the chosen candidate, chooses nothing; either way the listing is the one given, for that text, made at the revision given"
          run :=
            pure <|
              let listing (texts : Array String) : Array Completion.Listed :=
                (offered texts).map Completion.Listed.of
              let candidates : Candidates :=
                { all := offered #["wq", "w", "e"], listedFor := some "w"
                  listed := listing #["w", "wq"], chosen := some 1, revision := 3 }
              let kept := candidates.relist "w" 3 (listing #["w", "e", "wq"])
              let other := candidates.relist "x" 3 (listing #["w", "e", "wq"])
              let gone := candidates.relist "w" 2 (listing #["w", "e"])
              kept.chosen == some 2 && kept.listed == listing #["w", "e", "wq"] &&
                kept.listedFor == some "w" &&
                kept.listedAt == 3 &&
                other.chosen == none &&
                other.listedFor == some "x" &&
                gone.chosen == none &&
                gone.listedAt == 2 &&
                gone.listed == listing #["w", "e"] },
        { name :=
            "setting an open prompt's candidates replaces them and forgets the listing and the choice, and changes nothing else of the state"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let (_, chosen) := (picking asking).chooseCandidate .next
                let (set, replaced) := chosen.setCandidates { all := offered #["x", "y"] }
                replied set == .inr () &&
                  replaced.prompt.map (·.candidates) == some { all := offered #["x", "y"] } &&
                  withCandidates replaced {} == asking &&
                  replaced.wellFormed },
        { name :=
            "listing an open prompt's candidates keeps the candidates at the indices given, in that order, drops an index that is none of theirs, records the pattern the listing is for and forgets the choice; the candidates themselves stay"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let (_, chosen) := (picking asking).chooseCandidate .next
                let (listed, after) :=
                  chosen.listCandidates "w" (#[2, 9, 0, 3].map Completion.Hit.ofIndex)
                let (emptied, unmatched) := after.listCandidates "z" #[]
                replied listed == .inr () &&
                  after.prompt.map (·.candidates) ==
                    some
                      { all := offered #["wq", "edit", "w"], listedFor := some "w",
                        listed := (offered #["w", "wq"]).map Completion.Listed.of } &&
                  replied emptied == .inr () &&
                  unmatched.prompt.map (·.candidates) ==
                    some { all := offered #["wq", "edit", "w"], listedFor := some "z" } &&
                  withCandidates after {} == asking &&
                  after.wellFormed },
        { name :=
            "listing a prompt whose candidates include ones a filtered source passed keeps the hits' candidates, with their ranges, in the hits' order, then every passed candidate in the order given, whatever the pattern; a pattern with no hit lists the passed ones alone, and the choice is forgotten"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let all := offered #["wq", "edit", "w"]
                let passed := offered #["zz", "a"]
                let (set, collected) :=
                  asking.setCandidates { all, passed, category := some "pick" }
                let (_, first) := collected.listCandidates "" #[⟨0, #[]⟩, ⟨1, #[]⟩, ⟨2, #[]⟩]
                let (_, chosen) := first.chooseCandidate .next
                let (listed, after) :=
                  chosen.listCandidates "w" #[⟨2, #[⟨0, 1⟩]⟩, ⟨9, #[]⟩, ⟨0, #[⟨0, 1⟩]⟩]
                let (emptied, unmatched) := after.listCandidates "q" #[]
                let passedListed := passed.map Completion.Listed.of
                replied set == .inr () && replied listed == .inr () &&
                  after.prompt.map (·.candidates) ==
                    some
                      { all, passed, category := some "pick", listedFor := some "w"
                        listed :=
                          #[{ candidate := .ofText "w", ranges := #[⟨0, 1⟩] },
                              { candidate := .ofText "wq", ranges := #[⟨0, 1⟩] }] ++
                            passedListed } &&
                  replied emptied == .inr () &&
                  unmatched.prompt.map (·.candidates) ==
                    some
                      { all, passed, category := some "pick", listedFor := some "q"
                        listed := passedListed } &&
                  withCandidates after {} == asking &&
                  after.wellFormed },
        { name :=
            "choosing among a listing: next from nothing chosen is the first and previous the last, next from the last and previous from the first are nothing chosen, and each other step moves by one; with nothing listed neither changes anything"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let listed := picking asking
                let steps (steps : List Candidates.Step) (start : EditorState) :
                  Option (Option Nat) :=
                  (steps.foldl (fun state step => (state.chooseCandidate step).2) start).prompt.map
                    (·.candidates.chosen)
                let (stepped, after) := listed.chooseCandidate .next
                let (_, bare) := asking.setCandidates { all := offered #["a"] }
                replied stepped == .inr () && withCandidates after {} == asking &&
                  after.wellFormed &&
                  steps [.next] listed == some (some 0) &&
                  steps [.previous] listed == some (some 2) &&
                  steps [.next, .next] listed == some (some 1) &&
                  steps [.next, .next, .next] listed == some (some 2) &&
                  steps [.next, .next, .next, .next] listed == some none &&
                  steps [.next, .previous] listed == some none &&
                  steps [.previous, .previous] listed == some (some 1) &&
                  steps [.previous, .previous, .previous, .previous] listed == some none &&
                  steps [.previous, .next] listed == some none &&
                  (bare.chooseCandidate .next).2 == bare &&
                  (bare.chooseCandidate .previous).2 == bare &&
                  (asking.chooseCandidate .next).2 == asking },
        { name :=
            "what a prompt answers with: the chosen candidate when the listing is for the text, and the text when nothing is chosen, when the listing is for another text and when there are no candidates"
          run :=
            pure <|
              let listed : Candidates :=
                { all := offered #["wq", "edit", "w"], listedFor := some "w",
                  listed := (offered #["w", "wq"]).map Completion.Listed.of }
              ({ listed with chosen := some 1 } : Candidates).answer "w" == "wq" &&
                ({ listed with chosen := some 0 } : Candidates).answer "w" == "w" &&
                listed.answer "w" == "w" &&
                ({ listed with chosen := some 1 } : Candidates).answer "wx" == "wx" &&
                ({ listed with chosen := some 1 } : Candidates).answer "" == "" &&
                ({} : Candidates).answer "typed" == "typed" &&
                ({ all := offered #["a"], listedFor := some "z" } : Candidates).answer "z" == "z" },
        { name :=
            "with no prompt open, setting candidates, listing them and choosing one are each refused with notOpen, and the state is as it was"
          run :=
            pure <|
              match onTextModel twoBuffers with
              | none => false
              | some state =>
                let refused : Except PromptRefusal Unit × EditorState → Bool
                  | (.error .notOpen, after) => after == state
                  | _ => false
                refused (state.setCandidates { all := offered #["a"] }) &&
                  refused (state.listCandidates "a" #[.ofIndex 0]) &&
                  refused (state.chooseCandidate .next) &&
                  refused (state.chooseCandidate .previous) },
        { name :=
            "the initial state is not asked to quit, does not leave, has no buffer with unsaved changes and no save in flight"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                !state.quitting && !state.leaves && state.unsaved.isNone && !state.isSaving },
        { name :=
            "a modified buffer with no file has no unsaved changes; one that holds a file has; one whose save in flight is writing the state its text is in has not; one edited since that save began has; and one whose save was ended with a stamp has not"
          run :=
            pure <|
              match onTextModel quitStates with
              | none => false
              | some states =>
                let unsaved (state : EditorState) := state.unsaved.map (·.name)
                ((states.bare.buffer? ⟨0⟩).map (·.isModified)) == some true &&
                  unsaved states.bare == none &&
                  unsaved states.held == some "other" &&
                  unsaved states.saving == none &&
                  unsaved states.moved == some "other" &&
                  unsaved states.saved == none &&
                  [states.bare, states.held, states.saved].all (!·.isSaving) &&
                  states.saving.isSaving &&
                  states.moved.isSaving },
        { name :=
            "a state asked to quit leaves when no buffer has unsaved changes and no save is in flight, and not while a save is in flight or a buffer has unsaved changes; a state that was not asked never leaves"
          run :=
            pure <|
              match onTextModel quitStates with
              | none => false
              | some states =>
                let asked (state : EditorState) : EditorState := { state with quitting := true }
                (asked states.bare).leaves && (asked states.saved).leaves &&
                  !(asked states.saving).leaves &&
                  !(asked states.held).leaves &&
                  !(asked states.moved).leaves &&
                  !states.bare.leaves &&
                  !states.saved.leaves },
        { name :=
            "a quit that cannot go ahead is withdrawn: a state asked to quit while a buffer has unsaved changes is no longer asked, and is otherwise as it was; one asked with nothing unsaved, a save in flight among them, stays asked; one that was not asked is as it was"
          run :=
            pure <|
              match onTextModel quitStates with
              | none => false
              | some states =>
                let asked (state : EditorState) : EditorState := { state with quitting := true }
                (asked states.held).settleQuit == states.held &&
                  (asked states.moved).settleQuit == states.moved &&
                  (asked states.saving).settleQuit == asked states.saving &&
                  (asked states.bare).settleQuit == asked states.bare &&
                  (asked states.saved).settleQuit == asked states.saved &&
                  states.held.settleQuit == states.held },
        { name :=
            "a view's rectangle is the one the state's rectangles give it: for each window, laid out by the frame's layout, and for the minibuffer's view while a prompt is open, in the strip its place then takes; a view with no window has none, and neither has the minibuffer's view of a prompt that is not open"
          run :=
            pure <|
              match onTextModel threeWindows with
              | none => false
              | some state =>
                let asking := (prompted state).2
                -- Whether `rect?` answers, for every view, the rectangle the
                -- layout gives it.
                let agrees (state : EditorState) : Bool :=
                  let laid := state.rects
                  laid.map (·.1) == state.views &&
                    laid.all fun (id, rect) => state.rect? id == some rect
                agrees state && agrees asking && asking.views.size == state.views.size + 1 &&
                  state.rect? ⟨9⟩ == none &&
                  asking.minibufferView?.map state.rect? == some none }] ++
      windowOperationChecks ++ floatingWindowChecks

/-- The checks of tabs on the state's model (`TabChange`,
`EditorState.changeTab`, `WindowSpot.tab`, `Editor/State.lean`, "Tabs").
The operations ask the text store nothing, so a marker's id is written out
by hand. -/
def tabChecks : List Check :=
  let marker (index : Nat) (text : Nat := 0) : MarkerId := ⟨⟨text⟩, index⟩
  [{  name :=
        "criterion 1, on the model: a new tab on view 1's buffer goes after the tab in view, which is unchanged and stays in view, its layout the default fitted to one window; focusing its window brings it into view, zooming there leaves the first tab as it was, and selecting each tab gives it back exactly as it was left; every state is well formed"
      run :=
        pure <|
          match onTextModel (windowsUnder 2 Layout.default) with
          | none => false
          | some state =>
            let (_, focused) := state.focusWindow ⟨1⟩
            match focused.openWindow ⟨0⟩ (marker 90) (marker 91) .tab with
            | (.ok made, tabbed) =>
              let (_, second) := tabbed.focusWindow made
              let (_, zoomed) := second.arrange made .zoom
              let (_, first) := zoomed.changeTab (.select 0)
              let (_, again) := first.changeTab (.select 1)
              made == ⟨2⟩ && tabbed.frame.toTab == focused.frame.toTab &&
                tabbed.frame.tabIndex == 0 &&
                tabbed.frame.tabsAfter ==
                  #[{ windows := #[made], focused := made, layout := Layout.default.fits 1 }] &&
                (tabbed.window? made).map (·.buffer) == some ⟨0⟩ &&
                second.frame.tabIndex == 1 &&
                second.frame.focused == made &&
                zoomed.frame.layout == .monocle &&
                zoomed.frame.tabsBefore == #[focused.frame.toTab] &&
                first.frame.tabIndex == 0 &&
                first.frame.toTab == focused.frame.toTab &&
                again.frame.tabIndex == 1 &&
                again.frame.toTab == zoomed.frame.toTab &&
                [focused, tabbed, second, zoomed, first, again].all (·.wellFormed)
            | _ => false },
    { name :=
        "a new tab takes the layout config chose, fitted to its one window, and the tab in view keeps its own"
      run :=
        pure <|
          match onTextModel (windowsUnder 2 Layout.default) with
          | none => false
          | some state =>
            let chosen : Layout := .edge .left 25 (.splits (.split .rows 1 1 .tile .tile))
            let state := { state with frame := { state.frame with chosen := some chosen } }
            match state.openWindow ⟨0⟩ (marker 90) (marker 91) .tab with
            | (.ok _, tabbed) =>
              tabbed.frame.tabsAfter.map (·.layout) == #[chosen.fits 1] &&
                tabbed.frame.layout == Layout.default &&
                tabbed.wellFormed
            | _ => false },
    { name :=
        "closing the tab in view brings the tab that takes its index into view, or the new last one when it was last; its windows leave the state and its buffers stay; closing a hidden tab keeps the tab in view in view"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            let (closed, next) := state.changeTab (.close 1)
            let (_, last) := { state with frame := state.frame.selected 2 }.changeTab (.close 2)
            let (_, hidden) := state.changeTab (.close 0)
            replied closed == .inr () && next.frame.tabIndex == 1 && next.frame.windows == #[⟨2⟩] &&
              next.frame.focused == ⟨2⟩ &&
              next.windows.map (·.id) == #[⟨0⟩, ⟨2⟩] &&
              next.buffers == state.buffers &&
              last.frame.tabIndex == 1 &&
              last.frame.windows == #[⟨1⟩] &&
              last.frame.tabs.size == 2 &&
              hidden.frame.tabIndex == 0 &&
              hidden.frame.toTab == state.frame.toTab &&
              hidden.windows.map (·.id) == #[⟨1⟩, ⟨2⟩] &&
              [next, last, hidden].all (·.wellFormed) },
    { name := "closing the last tab is refused with onlyTab, and the state is as it was"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            match state.changeTab (.close 0) with
            | (.error .onlyTab, after) => after == state
            | _ => false },
    { name := "a tab past the last is refused with noSuchTab by every change, the state as it was"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            [TabChange.select 3, .close 3, .rename 3 (some "x"), .move 3 0].all fun change =>
              match state.changeTab change with
              | (.error (.noSuchTab 3), after) => after == state
              | _ => false },
    { name :=
        "while a prompt is open, selecting another tab and closing the tab in view are refused with promptOpen, the state as it was; selecting the tab in view and closing a hidden tab are not"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let refused (change : TabChange) : Bool :=
              match asking.changeTab change with
              | (.error .promptOpen, after) => after == asking
              | _ => false
            let (same, kept) := asking.changeTab (.select 1)
            let (closed, hidden) := asking.changeTab (.close 0)
            refused (.select 0) && refused (.close 1) && replied same == .inr () &&
              kept == asking &&
              replied closed == .inr () &&
              hidden.frame.tabs.size == 2 &&
              hidden.prompt == asking.prompt &&
              hidden.wellFormed },
    { name := "renaming a tab gives it the name, and none goes back to the generated one"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            let (renamed, named) := state.changeTab (.rename 0 (some "notes"))
            let (_, back) := named.changeTab (.rename 0 none)
            let (_, own) := state.changeTab (.rename 1 (some "here"))
            replied renamed == .inr () &&
              named.frame.tabs.map (·.name) == #[some "notes", none, none] &&
              named.frame.tabIndex == 1 &&
              back == state &&
              own.frame.name == some "here" },
    { name :=
        "moving a tab moves it to the index, clamped to the last, and the tab in view stays in view wherever it now stands"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            let order (state : EditorState) : Array (Array ViewId) :=
              state.frame.tabs.map (·.windows)
            let (_, front) := state.changeTab (.move 1 0)
            let (_, clamped) := state.changeTab (.move 0 9)
            let (_, first) := state.changeTab (.move 2 0)
            order front == #[#[⟨1⟩], #[⟨0⟩], #[⟨2⟩]] && front.frame.tabIndex == 0 &&
              order clamped == #[#[⟨1⟩], #[⟨2⟩], #[⟨0⟩]] &&
              clamped.frame.tabIndex == 0 &&
              order first == #[#[⟨2⟩], #[⟨0⟩], #[⟨1⟩]] &&
              first.frame.tabIndex == 2 &&
              [front, clamped, first].all (·.wellFormed) },
    { name :=
        "leaving a tab closes its transient floats, whose windows leave the state, and keeps its pinned ones"
      run :=
        pure <|
          match
            onTextModel do
              let state ← windowsUnder 1 Layout.default
              withFloats state [(.frame, false), (.frame, true)] with
          | none => false
          | some state =>
            match state.openWindow ⟨0⟩ (marker 90) (marker 91) .tab with
            | (.ok made, tabbed) =>
              let (selected, left) := tabbed.changeTab (.select 1)
              replied selected == .inr () && left.frame.focused == made &&
                left.frame.tabsBefore.map (·.floats.map (·.view)) == #[#[⟨2⟩]] &&
                (left.window? ⟨1⟩).isNone &&
                (left.window? ⟨2⟩).isSome &&
                left.wellFormed
            | _ => false },
    { name :=
        "focusing a hidden tab's window selects its tab and focuses the window there; while a prompt is open it is refused with promptOpen, the state as it was"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            let (focused, after) := state.focusWindow ⟨2⟩
            let (_, asking) := prompted state
            replied focused == .inr () && after.frame.tabIndex == 2 && after.frame.focused == ⟨2⟩ &&
              after.wellFormed &&
              match asking.focusWindow ⟨2⟩ with
              | (.error .promptOpen, same) => same == asking
              | _ => false },
    { name :=
        "showing a buffer in a hidden tab's window shows it there, the tab in view staying in view, and closes that tab's transient float anchored at a position of the window"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let float : Window :=
              { id := ⟨2⟩, buffer := ⟨1⟩, scroll := marker 20 1, selection := marker 21 1 }
            let state :=
              { state with
                windows := state.windows.push float
                frame :=
                  { state.frame with
                    windows := #[⟨0⟩]
                    tabsAfter :=
                      #[{ windows := #[⟨1⟩], focused := ⟨1⟩
                          floats := #[{ view := ⟨2⟩, anchor := .position ⟨1⟩ (marker 5 1) }] }] } }
            match state.showBuffer ⟨1⟩ ⟨0⟩ (marker 90) (marker 91) with
            | (.ok (), after) =>
              state.wellFormed && after.frame.tabIndex == 0 &&
                after.frame.toTab == state.frame.toTab &&
                (after.window? ⟨1⟩).map (·.buffer) == some ⟨0⟩ &&
                after.frame.tabsAfter.map (·.floats.size) == #[0] &&
                (after.window? ⟨2⟩).isNone &&
                after.wellFormed
            | _ => false },
    { name :=
        "criterion 2, on the model: config's layout chosen through monocle, manual splits and the default rearranges the tab in view and keeps every window of it, the docked window joining the tiles when the edge goes, the split tree fitting them; the hidden tab is unchanged at every step, and every state is well formed"
      run :=
        pure <|
          match onTextModel (dockedUnder 4 [.left] (.edge .left 25 Layout.default)) with
          | none => false
          | some state =>
            let start : EditorState :=
              { state with
                frame :=
                  { state.frame with
                    windows := #[⟨0⟩, ⟨1⟩, ⟨2⟩],
                    layout := (Layout.edge .left 25 Layout.default).fits 3
                    tabsAfter := #[{ windows := #[⟨3⟩], focused := ⟨3⟩ }] } }
            let chosen (state : EditorState) (layout : Layout) : EditorState :=
              { state with frame := state.frame.choose layout }
            let monocle := chosen start .monocle
            let manual := chosen monocle Layout.manual
            let back := chosen manual Layout.default
            let kept (state : EditorState) : Bool :=
              state.frame.all.toList.mergeSort (·.index ≤ ·.index) == [⟨0⟩, ⟨1⟩, ⟨2⟩, ⟨4⟩] &&
                state.frame.tabsAfter == start.frame.tabsAfter &&
                state.wellFormed
            start.wellFormed && start.frame.docked == #[(⟨4⟩, .left)] && kept monocle &&
              monocle.frame.windows == #[⟨0⟩, ⟨1⟩, ⟨2⟩, ⟨4⟩] &&
              monocle.frame.docked.isEmpty &&
              kept manual &&
              manual.frame.layout.fitted 4 &&
              (match manual.frame.layout with
              | .splits tree => tree.size == 4
              | _ => false) &&
              kept back &&
              back.frame.layout == Layout.default }]

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

/-- The keys of the read-only checks: `C-r m` makes a buffer `ro` holding
`abc`, read-only, and shows it in the window; `C-r i` (`insert-x`) inserts
`x` at the window's cursors; `C-r d` (`delete-first`) deletes the first byte
of its text; `C-r u` (`undo`) undoes in the window's buffer; `C-r w`
(`write-w`) appends `w` to the buffer's text inside `writing`; and `C-r f`
(`write-fails`) appends `f` inside `writing` and is then refused there. -/
def readOnlyKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-r m", invoke "make-ro"), ("C-r i", invoke "insert-x"), ("C-r d", invoke "delete-first"),
      ("C-r u", invoke "undo"), ("C-r w", invoke "write-w"), ("C-r f", invoke "write-fails")]
    [("make-ro", fun call => do
        if let .ok made← createBuffer "ro" "abc" then
          discard <| made.setReadOnly true
          discard <| call.target.window.id.show made
        return none),
      ("insert-x", fun call => do
        call.target.insertAtSelections "x"
        return none),
      ("delete-first", fun call => do
        call.target.buffer.text.delete 0 1
        return none),
      ("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("write-w", fun call => do
        call.target.window.buffer.writing do
            let text := call.target.buffer.text
            text.insert (← text.byteLength) "w"
        return none),
      ("write-fails", fun call => do
        call.target.window.buffer.writing do
            let text := call.target.buffer.text
            text.insert (← text.byteLength) "f"
            text.delete 9 99
        return none)]

/-- A driver of the read-only checks, with their keys and no job; `none` if
making the state was refused. -/
def readOnlyDriver : Option TestDriver :=
  (Loop.Driver.over readOnlyKeys (fun _ => none) (EditorState.initial ⟨640, 480⟩)
      editorModel).toOption

/-- The checks of read-only buffers (`Editor/State.lean`, "Buffers";
`Editor/Command/Dispatch.lean`, "Read-only buffers"), on the loop's driver
over the editor's models. -/
def readOnlyChecks : List Check :=
  [{  name :=
        "an insert, a delete and an undo in a read-only buffer each end the command as giving up: the text is as it was, the echo area says the buffer is read-only, and the buffer stays read-only"
      run :=
        pure <|
          match readOnlyDriver with
          | none => false
          | some driver =>
            let made := settledAfter driver "C-r m"
            let inserted := settledAfter made "C-r i"
            let deleted := settledAfter made "C-r d"
            let written := settledAfter made "C-r w"
            let undone := settledAfter written "C-r u"
            (showing made).bind (·.text) == some "abc" &&
              (showing made).map (·.buffer.readOnly) == some true &&
              (showing inserted).bind (·.text) == some "abc" &&
              echoOf inserted == some "insert-x: ro is read-only" &&
              (showing deleted).bind (·.text) == some "abc" &&
              echoOf deleted == some "delete-first: ro is read-only" &&
              (showing undone).bind (·.text) == some "abcw" &&
              echoOf undone == some "undo: ro is read-only" &&
              (showing undone).map (·.buffer.readOnly) == some true },
    { name :=
        "writing lets the owning command's own edit through and leaves the buffer read-only; a command refused inside writing is rolled back, the flag with it"
      run :=
        pure <|
          match readOnlyDriver with
          | none => false
          | some driver =>
            let made := settledAfter driver "C-r m"
            let written := settledAfter made "C-r w"
            let failed := settledAfter made "C-r f"
            (showing written).bind (·.text) == some "abcw" &&
              (showing written).map (·.buffer.readOnly) == some true &&
              (showing failed).bind (·.text) == some "abc" &&
              (showing failed).map (·.buffer.readOnly) == some true &&
              echoOf failed == some "write-fails: refused: bad range" },
    { name :=
        "a committed text into a read-only buffer is dropped, and the echo area says the buffer is read-only, with no command's name; into another buffer it is inserted"
      run :=
        pure <|
          match readOnlyDriver with
          | none => false
          | some driver =>
            let made := settledAfter driver "C-r m"
            let committed := (fedTo made [.commit "z"]).1
            let elsewhere := (fedTo driver [.commit "z"]).1
            (showing committed).bind (·.text) == some "abc" &&
              echoOf committed == some "ro is read-only" &&
              (showing elsewhere).bind (·.text) == some "z" }]

/-- The buffer called `name` in `driver`'s state, if there is one. -/
def excerptBufferNamed (driver : EvilDriver) (name : String) : Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer name)

/-- What the text of the buffer called `name` holds in `driver`'s text model,
read as a command reads it, so an excerpt text is caught up. -/
def excerptRead (driver : EvilDriver) (name : String) : Option String := do
  let buffer ← excerptBufferNamed driver name
  (buffer.text.read.runModel driver.model.texts).1.toOption

/-- The checks of excerpt buffers (`Editor/State.lean`, "Excerpt buffers";
`Editor/Command/Dispatch.lean`, "Read-only buffers and excerpt sources";
`Editor/Api.lean`, "Undo"), on the loop's driver over the editor's
models, with evil's keys. -/
def excerptBufferChecks : List Check :=
  [{  name :=
        "an edit typed in an excerpt buffer changes the source buffer's text at the mapped position, as one revision of the source traced to the user, and the excerpt buffer shows it"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let traced := do
              let one ← excerptBufferNamed typed "one"
              (one.text.trace 5 6 |>.runModel typed.model.texts).1.toOption
            excerptRead driver "ex" == some "two\n\nalpha\n" &&
              excerptRead typed "one" == some "one\ntXwo\nthree\n" &&
              excerptRead typed "ex" == some "tXwo\n\nalpha\n" &&
              excerptRead typed "two" == some "alpha\nbeta\n" &&
              traced == some #[⟨5, 6, .entry 1 Origin.user⟩] },
    { name :=
        "u in the excerpt buffer after a typed session restores the source buffer and the excerpt buffer, one step for the whole session, and C-r redoes it"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed :=
              evilFed (excerptFed (evilFed driver "l i") [.commit "X", .commit "Y"]) "<Escape>"
            let undone := evilFed typed "u"
            let redone := evilFed undone "C-r"
            excerptRead typed "one" == some "one\ntXYwo\nthree\n" &&
              excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead redone "one" == some "one\ntXYwo\nthree\n" &&
              excerptRead redone "ex" == some "tXYwo\n\nalpha\n" &&
              redone.loop.state.echo.isEmpty },
    { name :=
        "u in the excerpt buffer after the source was edited in its own buffer since is refused, saying so, and changes nothing"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let moved := excerptInvoked typed "edit-one"
            let undone := evilFed moved "u"
            excerptRead moved "one" == some "Zone\ntXwo\nthree\n" &&
              undone.loop.state.echo == Evil.sourceMovedSays "one" &&
              excerptRead undone "one" == some "Zone\ntXwo\nthree\n" &&
              excerptRead undone "ex" == some "tXwo\n\nalpha\n" },
    { name :=
        "C-r in the excerpt buffer after the source was edited in its own buffer since the undo is refused, saying so, and changes nothing"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let moved := excerptInvoked (evilFed typed "u") "edit-one"
            let redone := evilFed moved "C-r"
            excerptRead moved "one" == some "Zone\ntwo\nthree\n" &&
              redone.loop.state.echo == Evil.sourceMovedSays "one" &&
              excerptRead redone "one" == some "Zone\ntwo\nthree\n" &&
              excerptRead redone "ex" == some "two\n\nalpha\n" },
    { name :=
        "a redo in the excerpt buffer while an edit through it is pending answers nothing and keeps the edit, which the next u takes back"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let pending := excerptInvoked (evilFed typed "u") "edit-redo"
            let undone := evilFed pending "u"
            pending.loop.state.echo.isEmpty &&
              excerptRead pending "one" == some "one\nxtwo\nthree\n" &&
              excerptRead pending "ex" == some "xtwo\n\nalpha\n" &&
              excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" },
    { name :=
        "u in the excerpt buffer once a source buffer of its last step was removed says so, under the name the step recorded, and drops that step, so the next u undoes the older step over a live source"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let older := evilFed (excerptFed (evilFed driver "j j i") [.commit "Q"]) "<Escape>"
            let newer := evilFed (excerptFed (evilFed older "k k i") [.commit "X"]) "<Escape>"
            let removed := excerptInvoked newer "remove-one"
            let refused := evilFed removed "u"
            let undone := evilFed refused "u"
            let emptied := evilFed undone "u"
            excerptRead older "two" == some "Qalpha\nbeta\n" &&
              excerptRead newer "one" == some "one\nXtwo\nthree\n" &&
              (excerptBufferNamed removed "one").isNone &&
              refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              excerptRead refused "two" == some "Qalpha\nbeta\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead undone "two" == some "alpha\nbeta\n" &&
              emptied.loop.state.echo == Evil.nothingToUndo },
    { name :=
        "u in the excerpt buffer once one of the two sources of its last step was removed says so and drops that source from the step, so the next u undoes the step in the source left"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let removed := excerptInvoked (excerptInvoked driver "edit-both") "remove-one"
            let refused := evilFed removed "u"
            let undone := evilFed refused "u"
            excerptRead removed "two" == some "Alpha\nbeta\n" &&
              refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              excerptRead refused "two" == some "Alpha\nbeta\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead undone "two" == some "alpha\nbeta\n" },
    { name :=
        "C-r in the excerpt buffer once the source buffer of the step to redo was removed says so and drops the step, so the next C-r has nothing to redo"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let removed := excerptInvoked (evilFed typed "u") "remove-one"
            let refused := evilFed removed "C-r"
            let emptied := evilFed refused "C-r"
            refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              emptied.loop.state.echo == Evil.nothingToRedo },
    { name := "u in the source buffer takes back an edit made through the excerpt buffer"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let undone := evilFed (excerptInvoked typed "show-one") "u"
            excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" },
    { name :=
        "a command applying one transaction with an edit in each excerpt changes both source buffers, and one u restores both"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let edited := excerptInvoked driver "edit-both"
            let undone := evilFed edited "u"
            excerptRead edited "one" == some "one\ntXwo\nthree\n" &&
              excerptRead edited "two" == some "Alpha\nbeta\n" &&
              excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "two" == some "alpha\nbeta\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" &&
              undone.loop.state.echo.isEmpty },
    { name :=
        "a command that edits both sources through the excerpt buffer and then fails is rolled back in both, the echo area says the refusal and nothing more, and u then has nothing to undo"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let failed := excerptInvoked driver "edit-both-fails"
            let undone := evilFed failed "u"
            excerptRead failed "one" == some "one\ntwo\nthree\n" &&
              excerptRead failed "two" == some "alpha\nbeta\n" &&
              excerptRead failed "ex" == some "two\n\nalpha\n" &&
              failed.loop.state.echo == "edit-both-fails: refused: bad range" &&
              undone.loop.state.echo == Evil.nothingToUndo },
    { name :=
        "with source two read-only, a command editing both gives up saying so and neither source changes; a commit into the second excerpt is dropped saying so, and one into the first is inserted"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let readOnly := excerptInvoked driver "two-ro"
            let edited := excerptInvoked readOnly "edit-both"
            let second := excerptFed (evilFed readOnly "j j i") [.commit "Q"]
            let first := excerptFed (evilFed readOnly "i") [.commit "Q"]
            edited.loop.state.echo == "edit-both: two is read-only" &&
              excerptRead edited "one" == some "one\ntwo\nthree\n" &&
              excerptRead edited "two" == some "alpha\nbeta\n" &&
              second.loop.state.echo == "two is read-only" &&
              excerptRead second "two" == some "alpha\nbeta\n" &&
              excerptRead first "one" == some "one\nQtwo\nthree\n" },
    { name := "an excerpt over a text no buffer holds refuses an edit there, saying so"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let made := excerptInvoked driver "make-unheld"
            let edited := excerptInvoked made "insert-x"
            excerptRead made "ex2" == some "free\n" &&
              edited.loop.state.echo == "insert-x: ex2 reads a text no buffer holds" &&
              excerptRead edited "ex2" == some "free\n" },
    { name :=
        "a commit into an excerpt over a text no buffer holds is dropped, saying so, and changes nothing"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let made := excerptInvoked driver "make-unheld"
            let committed := excerptFed (evilFed made "i") [.commit "Q"]
            committed.loop.state.echo == EditorState.unheldReason "ex2" &&
              excerptRead committed "ex2" == some "free\n" },
    { name :=
        "with source one's file changed on disk unbeknown to the user, a command editing both sources through the excerpt buffer is superseded, saying so, and neither source changes; the change is then told, and the same command lands"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let changed := excerptInvoked driver "one-changed"
            let refused := excerptInvoked changed "edit-both"
            let landed := excerptInvoked refused "edit-both"
            refused.loop.state.echo == Files.changedOnDisk "one.txt" &&
              excerptRead refused "one" == some "one\ntwo\nthree\n" &&
              excerptRead refused "two" == some "alpha\nbeta\n" &&
              excerptRead refused "ex" == some "two\n\nalpha\n" &&
              excerptRead landed "one" == some "one\ntXwo\nthree\n" &&
              excerptRead landed "two" == some "Alpha\nbeta\n" },
    { name :=
        "with source one's file changed on disk unbeknown to the user, a commit into the first excerpt is dropped, saying so, and the change is then told, so the next commit is inserted"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let changed := excerptInvoked driver "one-changed"
            let refused := excerptFed (evilFed changed "i") [.commit "Q"]
            let landed := excerptFed refused [.commit "R"]
            refused.loop.state.echo == Files.changedOnDisk "one.txt" &&
              excerptRead refused "one" == some "one\ntwo\nthree\n" &&
              excerptRead refused "ex" == some "two\n\nalpha\n" &&
              excerptRead landed "one" == some "one\nRtwo\nthree\n" &&
              excerptRead landed "ex" == some "Rtwo\n\nalpha\n" },
    { name :=
        "the ranges a transaction changes are its runs of deletes and inserts in the text before, an insert's empty and changes that do nothing passed over"
      run :=
        pure <|
          Change.ranges TextContract.acrossBoth.changes == #[(1, 1), (5, 6)] &&
            Change.ranges #[.retain 2, .delete 0, .insert "", .retain 1] == #[] &&
            Change.ranges #[.delete 2, .insert "ab", .retain 3, .delete 1] == #[(0, 2), (5, 6)] &&
            Change.ranges #[.insert "a", .retain 0, .insert "b"] == #[(0, 0)] }]

/-- The state the at-point state checks start from: the initial one at 640
by 480. -/
def atPointBase : Option EditorState :=
  onTextModel (EditorState.initial ⟨640, 480⟩)

/-- `state` with a session open (`stateSession`) whose candidates are each
of `texts`, listed for `typed` at the indices `indices`. -/
def sessionListing (state : EditorState) (texts : Array String) (indices : Array Nat)
    (typed : String := "a") : EditorState :=
  let (_, opened) := state.openAtPoint (stateSession typed) { all := offered texts }
  match opened.candidatesIn? ⟨0⟩ with
  | some candidates =>
    opened.replaceCandidatesIn ⟨0⟩ (candidates.list typed (indices.map Completion.Hit.ofIndex))
  | none => opened

/-- The checks of a session at point in the state (`Editor/State.lean`, "A
session at point"): opening, closing, the choice, what a preview and an edit
record, when nothing more is to come, batches and matches reaching it by
its view, the place it takes and the invariants. -/
def atPointStateChecks : List Check :=
  [{  name :=
        "a session opens with the candidates its sources answered, its region and texts, and nothing chosen; it is refused while a prompt is open, while a session is, and for a view with no window"
      run :=
        pure <|
          match atPointBase with
          | none => false
          | some state =>
            let collected : Completion.Collected :=
              { all := offered #["a1", "a2"], category := some "word"
                region := some { start := 0, stop := 1 }, texts := #[⟨3⟩] }
            let (opened, made) := state.openAtPoint (stateSession) collected
            let (again, _) := made.openAtPoint (stateSession) collected
            let (_, asking) := prompted state
            let (prompting, _) := asking.openAtPoint (stateSession) collected
            let (nowhere, _) := state.openAtPoint { stateSession with view := ⟨9⟩ } collected
            opened matches .ok () &&
              made.atPoint.map (·.candidates) ==
                some
                  { all := offered #["a1", "a2"], category := some "word"
                    region := some { start := 0, stop := 1 }, texts := #[⟨3⟩] } &&
              made.atPoint.bind (·.candidates.chosen) == none &&
              made.wellFormed &&
              again matches .error .alreadyOpen &&
              prompting matches .error .promptOpen &&
              nowhere matches .error .noWindow &&
              (EditorState.openAtPoint stateSession collected
                    { state with atPoint := some stateSession }).2 ==
                { state with atPoint := some stateSession } },
    { name :=
        "closing hands the session back and leaves none; the choice moves through the listing with nothing chosen as one stop; a preview records what it left and that it was made; an edit takes the region's text as typed and shown and forgets the choice; each is refused with no session"
      run :=
        pure <|
          match atPointBase with
          | none => false
          | some state =>
            let listing := sessionListing state #["a1", "a2", "a3"] #[0, 1, 2]
            let chosen (state : EditorState) := state.atPoint.bind (·.candidates.chosen)
            let (_, one) := listing.chooseAtPoint .next
            let (_, two) := one.chooseAtPoint .next
            let (_, back) := listing.chooseAtPoint .previous
            let (_, previewed) := two.retypeAtPoint "a2" true
            let (_, retaken) := previewed.retakeAtPoint "a2x"
            let (closed, after) := retaken.closeAtPoint
            chosen one == some 0 && chosen two == some 1 && chosen back == some 2 &&
              previewed.atPoint.map (fun s => (s.shown, s.typed, s.previewed)) ==
                some ("a2", "a", true) &&
              retaken.atPoint.map (fun s => (s.shown, s.typed, s.previewed, s.candidates.chosen)) ==
                some ("a2x", "a2x", true, none) &&
              closed.toOption.map (·.typed) == some "a2x" &&
              after.atPoint.isNone &&
              (state.closeAtPoint).1.toOption.isNone &&
              (state.chooseAtPoint .next).1 matches .error .notOpen &&
              (state.retypeAtPoint "x" true).1 matches .error .notOpen &&
              (state.retakeAtPoint "x").1 matches .error .notOpen &&
              (state.retype ⟨0⟩ "x").retyped == #[(⟨0⟩, "x")] },
    { name :=
        "nothing more is to come once no match is in flight and every asking source is done, and either nothing can be listed or the listing for the typed text at the revision is empty"
      run :=
        pure <|
          let asking : Completion.Asking :=
            { source := "words", later := { job := "words" }, askedFor := "a" }
          let empty : Candidates := {}
          let waiting : Candidates := { asking := #[asking] }
          let done : Candidates := { asking := #[{ asking with done := true }] }
          let other : Candidates := (({ all := offered #["b"] } : Candidates).list "a" #[])
          let listed : Candidates :=
            (({ all := offered #["ab"] } : Candidates).list "a" #[.ofIndex 0])
          let matching : Candidates :=
            { other with matching := some { pattern := "a", revision := 0, generation := 0 } }
          empty.exhausted "a" && !waiting.exhausted "a" && done.exhausted "a" &&
            other.exhausted "a" &&
            !other.exhausted "b" &&
            !listed.exhausted "a" &&
            !matching.exhausted "a" },
    { name :=
        "a batch, a source's end, a match's delivery and its failure reach a session by its view, and another view's are dropped"
      run :=
        pure <|
          match atPointBase with
          | none => false
          | some state =>
            let asking : Completion.Asking :=
              { source := "words", later := { job := "words" }, askedFor := "a", generation := 1 }
            let (_, opened) := state.openAtPoint stateSession { asking := #[asking] }
            let (taken, batched) := opened.addCandidates ⟨0⟩ 0 1 (offered #["ab", "ac"])
            let (other, _) := opened.addCandidates ⟨5⟩ 0 1 (offered #["ab"])
            let ended := batched.sourceAnswered ⟨0⟩ 0 1
            let inFlight :=
              ended.replaceCandidatesIn ⟨0⟩
                { (ended.candidatesIn? ⟨0⟩).getD {} with
                  matching := some { pattern := "a", revision := 1, generation := 0 } }
            let listedIn := inFlight.listMatched ⟨0⟩ "a" 1 #[.of (.ofText "ab")]
            let failed := inFlight.matchFailed ⟨0⟩ "a" 1 "broken"
            taken && !other &&
              (batched.candidatesIn? ⟨0⟩).map (·.matchable.map (·.text)) == some #["ab", "ac"] &&
              (ended.candidatesIn? ⟨0⟩).map (·.asking.all (·.done)) == some true &&
              (listedIn.candidatesIn? ⟨0⟩).map (·.listed.map (·.text)) == some #["ab"] &&
              (failed.candidatesIn? ⟨0⟩).bind (·.unmatched) == some ("a", 1) &&
              (state.candidatesIn? ⟨0⟩).isNone },
    { name :=
        "while a session is open and no prompt is, the place is the list's rows and the bottom row, with no input row; it grows and never shrinks, and closing the session gives the bottom row back"
      run :=
        pure <|
          match atPointBase with
          | none => false
          | some state =>
            let texts := (Array.range 8).map (s!"a{·}")
            let five := (sessionListing state texts (Array.range 5)).displayed .standard
            let two :=
              (five.replaceCandidatesIn ⟨0⟩
                    (((five.candidatesIn? ⟨0⟩).getD {}).list "a1"
                      #[.ofIndex 1, .ofIndex 2])).displayed
                .standard
            let (_, closed) := two.closeAtPoint
            let heights := five.heights
            let rows (state : EditorState) := state.atPoint.map (·.sheet.rows.size)
            five.listRows == 5 && five.minibufferPlace == 5 * heights.text + heights.message &&
              rows two == some 2 &&
              two.listRows == 5 &&
              two.minibufferPlace == five.minibufferPlace &&
              five.candidateListRect? ==
                some
                  { x := 0, y := 480 - (5 * heights.text + heights.message), width := 640
                    height := 5 * heights.text } &&
              five.tiled.height == 480 - (5 * heights.text + heights.message) &&
              closed.minibufferPlace == heights.message &&
              closed.candidateListRect? == none &&
              (sessionListing state texts #[]).candidateListRect? == none },
    { name :=
        "the state is not well formed with a session whose view is no window, or whose choice is past its listing"
      run :=
        pure <|
          match atPointBase with
          | none => false
          | some state =>
            let listing := sessionListing state #["a1"] #[0]
            !{ state with atPoint := some { stateSession with view := ⟨9⟩ } }.wellFormed &&
              listing.wellFormed &&
              !(listing.withCompleting ⟨0⟩ fun completing =>
                    { completing with
                      candidates := { completing.candidates with chosen := some 4 } }).wellFormed }]

end ModelTest
