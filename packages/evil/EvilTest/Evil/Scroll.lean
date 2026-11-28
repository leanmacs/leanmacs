import Editor.Loop.Driver
import Editor.Test.Excerpt
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Views
import Evil.Motions
import Evil.Vim
import Evil.Vim.Default
import EvilTest.Check
import EvilTest.Support.Evil
import EvilTest.Support.Vim

/-!
# Model tests: `Evil/Scroll.lean`

The model tests of `Evil/Scroll.lean`: `evilScrollChecks`, the
scroll commands by key (`C-d`, `C-u`, `C-f`, `C-b`, `z t`, `z z` and
`z b`) and the scroll margin after every motion of evil's vocabulary, on
the loop's driver under the Vim scheme that ships, read through the kit's
views (`Editor/Test/Views.lean`). That a view follows its cursor whatever
moved it is the loop's (`ModelTest.viewChecks`, under the test scheme). The
root module `EvilTest.Model` runs them; its module doc says what each shows.
-/

namespace EvilTest

open Editor
open Editor.Test

/-- The shape the Vim scheme that ships reports of a view before any key:
the shape of the selection a state of the scroll checks starts with. -/
def scrollShape : Shape :=
  (Vim.Default.scheme.report Vim.Default.scheme.init ⟨0⟩).shape

/-- A driver of the scroll checks over `viewState`, under the Vim scheme that
ships, each step handed `handed`, on `model`; `none` if making the state was
refused. `size` is the window's text area (`frameAround`). -/
def scrollDriver (contents : String) (size : Size) (margin : Nat := 0) (head : Nat := 0)
    (handed : Loop.Keys Vim.Default.scheme := evilHanded) (model : EditorModel := editorModel) :
    Option EvilDriver :=
  let frame := frameAround size model.display.cells
  (Loop.Driver.over handed (fun _ => none) (viewState contents frame margin head scrollShape)
      model).toOption

/-- What the scene shows of view 0 after `invocation` has run, as a step no
key yielded, from the state `start` makes, under the Vim scheme that ships
with evil's commands, on models of their own. -/
def scrollInvoked (start : TextM EditorState) (invocation : Invocation) : Option ViewSeen :=
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
def motionMarginFailures (contents : String) (size : Size) (margin : Nat) (heads : List Nat) :
    List String :=
  let rows := allRows contents size.width
  heads.flatMap fun head =>
    Evil.motions.toList.flatMap fun motion =>
      [0, 3].filterMap fun count =>
        let seen :=
          scrollInvoked (viewState contents size margin head scrollShape)
            { command := Vim.moveCommand, arguments := [.str motion.name, .nat count] }
        let held :=
          match seen with
          | some seen => seen.row.any fun row => marginHolds rows seen.shown row margin
          | none => false
        if held then none else some s!"{motion.name} with {count} from {head} of {repr contents}"

/-- The invocation the default key `key` yields in the Vim scheme's initial
state: what the loop runs for it. -/
def scrollInvocation (key : String) : Option Invocation :=
  (vimDefaultEdit key).map (·.compile)

/-- The cases in which the cursor's row is not among the rows the next
scene's view shows after the command of one of `keys`, run as the
invocation its key yields, in a view of `contents` in a frame of `size`:
from each of `anchors` as the scroll anchor and each of `heads` as the
cursor. A key that yields no command is a case. -/
def scrollFailures (keys : List String) (contents : String) (size : Size)
    (anchors heads : List Nat) : List String :=
  keys.flatMap fun key =>
    match scrollInvocation key with
    | none => [s!"{key} runs no command"]
    | some invocation =>
      anchors.flatMap fun anchor =>
        heads.filterMap fun head =>
          let start : TextM EditorState := do
            let state ← viewState contents size 0 head scrollShape
            let some target := state.focusedTarget? | throw .noSuchText
            target.scrollTo anchor
            return state
          match scrollInvoked start invocation with
          | some seen =>
            if seen.index.isSome then none
            else some s!"{key} from anchor {anchor} and cursor {head} of {repr contents}"
          | none => some s!"{key} from anchor {anchor} and cursor {head}: no scene"

/-- The checks of evil's scroll commands (`Evil/Scroll.lean`) by
key, and of the scroll margin after every motion of evil's vocabulary
(`Evil.motions`), on the loop's driver over the editor's models, under the
Vim scheme that ships with evil's commands: keys are pressed, and what the
next scene shows of a view is asked of the driver's models (`viewSeen`). -/
def evilScrollChecks : List Check :=
  [{  name :=
        "in a view of six rows over forty lines whose rows 1 to 10 are folded, C-d moves the anchor and the cursor down three rows counting the fold as one"
      run :=
        pure <|
          let forty := numbered 40
          let folds : Array Foldable :=
            #[{ start := 3, stop := 32, key := "f", text := "[1-10]", folded := true }]
          let start : TextM EditorState := do
            let state ←
              viewState forty (frameAround ⟨10, 6⟩ editorModel.display.cells) 0 0 scrollShape
            return { state with buffers := state.buffers.modify 0 (·.map ({ · with folds })) }
          match (Loop.Driver.over evilHanded (fun _ => none) start editorModel).toOption with
          | none => false
          | some driver =>
            (viewSeen (evilFed driver "C-d")).map (fun seen => (seen.anchor, seen.head)) ==
              some (36, 36) },
    { name :=
        "with the scroll margin set to two, after every motion of the vocabulary, with no count and with a count of 3, from a spread of cursors of forty short lines and of a text with wrapped lines, in a view of seven rows, the cursor's row is at least two rows from the first and from the last row the next scene's view shows, except where the first is the text's first row or the last its last"
      run := do
        let resting (contents : String) (every : Nat) : List Nat :=
          (List.range (contents.utf8ByteSize + 1)).filter fun head =>
            head % every == 0 && restsWell contents head
        let forty := numbered 40
        let wrong :=
          motionMarginFailures forty ⟨10, 7⟩ 2 (resting forty 7) ++
            motionMarginFailures ragged ⟨4, 7⟩ 2 (resting ragged 1)
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
        let wrong := motionMarginFailures forty ⟨10, 7⟩ 0 heads
        unless wrong.isEmpty do
          throw (IO.userError ("; ".intercalate (wrong.take 12)))
        return heads.length > 5 },
    { name :=
        "C-d moves a view's anchor and its cursor down by half the rows the view fits, and C-u up by the same; C-f and C-b by the rows it fits: in a view of six rows over forty lines, three rows and six, with the cursor keeping its row of the view; a count before C-d is the rows of that one command, and the next C-d is half a view again; a count before C-f is so many views"
      run :=
        pure <|
          let contents := numbered 40
          let rows := allRows contents 10
          match scrollDriver contents ⟨10, 6⟩ with
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
          match scrollDriver contents ⟨10, 5⟩ with
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
          match scrollDriver contents ⟨10, 5⟩ with
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
          match scrollDriver contents ⟨10, 4⟩ (head := 4), moved with
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
          match scrollDriver wrapping ⟨4, 2⟩ with
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
          match scrollDriver (numbered 20) ⟨10, 0⟩ (head := 9) with
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
          match scrollDriver contents ⟨10, 6⟩, vimDefaultCommand "C-d" with
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
            match scrollDriver contents ⟨10, height⟩ with
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
          match scrollDriver (numbered 20) ⟨10, 5⟩ with
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
          match scrollDriver contents ⟨10, 10⟩ with
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
          match scrollDriver contents ⟨10, 10⟩, scrollDriver contents ⟨10, 10⟩ (margin := 2) with
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
          match scrollDriver (numbered 40) ⟨10, 7⟩ (margin := 2) with
          | none => false
          | some driver =>
            let before := evilFed driver "2 0 j"
            let index (typed : String) : Option Nat :=
              (viewSeen (evilFed before typed)).bind (·.index)
            index "z t" == some 2 && index "z b" == some 4 && index "z z" == some 3 },
    { name := "in a frame of no height z t, z z and z b move nothing and say nothing"
      run :=
        pure <|
          match scrollDriver (numbered 20) ⟨10, 0⟩ (head := 9) with
          | none => false
          | some driver =>
            ["z t", "z z", "z b"].all fun typed =>
              let after := evilFed driver typed
              match viewSeen after with
              | some now => now.anchor == 0 && now.head == 9 && after.loop.state.echo == ""
              | none => false },
    { name :=
        "in a window four rows tall over six headed excerpts, after each of G, k and j across the headers, gg, C-f, C-b, C-d, C-u, z t, z z and z b, the rows the published view shows from its anchor, asked with its blocks, hold the cursor's row"
      run :=
        pure <|
          match evilExcerptDriver with
          | none => false
          | some driver =>
            let six := viewResized (excerptInvoked driver "make-six") ⟨20, 4⟩
            let keys :=
              ["G", "k", "k", "k", "k", "k", "k", "j", "j", "j", "g g", "C-f", "C-f", "C-b", "C-d",
                "C-d", "C-u", "G", "z t", "z z", "z b", "g g", "z b", "j", "j", "z z"]
            let (_, held) :=
              keys.foldl
                (fun (driver, held) key =>
                  let fed := evilFed driver key
                  (fed, held && (blockedSeen fed).any (·.2.2)))
                (six, true)
            (lastView six).any (·.blocks.size == 6) && held },
    { name :=
        "the scroll commands ask the rows a view fits with its blocks: C-f from the start of six headed excerpts in four rows moves the anchor and the cursor two rows, the rows that fit with the headers, not four"
      run :=
        pure <|
          match evilExcerptDriver with
          | none => false
          | some driver =>
            let six := viewResized (excerptInvoked driver "make-six") ⟨20, 4⟩
            -- `one` and the separator fit with the first header; `two`, at
            -- 5, is two rows down; without the headers `three`, at 10, is
            -- four rows down.
            (blockedSeen six).map (fun (anchor, head, _) => (anchor, head)) == some (0, 0) &&
              (blockedSeen (evilFed six "C-f")).map (fun (anchor, head, _) => (anchor, head)) ==
                some (5, 5) }]

end EvilTest
