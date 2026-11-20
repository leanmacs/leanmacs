import Editor.Restore.Frame
import Editor.Test.States
import Editor.Text.Model
import ModelTest.Check

/-!
# Model tests: `Editor/Restore/Frame.lean`

The model tests of `Editor/Restore/Frame.lean`: `restoreFrameChecks`, pure
and on the text model. That a restore puts a record back as it was, `of`
then a restore then `of` again, is `ModelTest.restoreChecks`' (a). The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Restore
open Editor.Test

namespace RestoreFrameTest

/-- Whether `record` written as JSON, rendered, parsed and read back is
`record`. -/
def roundTrips (record : Frame.Record) : Bool :=
  match Json.parse (Json.render record.toJson).toUTF8 with
  | .ok json => Frame.Record.ofJson? json == some record
  | .error _ => false

/-- A tree of manual splits of three tiles, resized. -/
def resized : Splits :=
  .split .columns 2 1 .tile (.split .rows 1 3 .tile .tile)

/-- A record of two tabs: the first, in view, three tiled windows under
manual splits at an edge, a docked window and a pinned float at a position;
the second, named, zoomed over two windows. -/
def sample : Frame.Record :=
  { selected := 0, chosen := some (.edge .left 25 (.splits .tile))
    tabs :=
      #[{ windows := #[0, 1, 2], docked := #[(3, .left)]
          floats :=
            #[{ view := 4, anchor := .position 1 ⟨1, 2⟩, share := { width := 40 }, pinned := true }]
          layout := .edge .left 25 (.splits resized), focused := 1, lastFocused := some 0 },
        { name := some "logs", windows := #[7, 8], layout := .monocle
          zoomedFrom := some (.masterStack { share := 60, side := .right, count := 2 })
          focused := 8 }]
    elsewhere := #[(8, "*vc-status*")] }

/-- The state the record of `of` is made from: buffer 0, `ab\ncd`, holding a
file, in views 0, 1 and 2 tiled under manual splits at a left edge and view
3 docked there, with a pinned float, view 4, anchored at row 1, column 1 of
view 1's buffer; and a second tab, named, whose one window shows `other`,
which holds no file and is not kept. View 1 is focused, after view 0. -/
def built : TextM EditorState := do
  let state ← dockedUnder 3 [.left] (.edge .left 25 (.splits .tile))
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  buffer.text.insert 0 "ab\ncd"
  let (_, state) := state.attachFile ⟨0⟩ notePath noteStamp .lf
  let marker ← buffer.text.mark (.anchor { offset := 4, bias := .before })
  let state ← withFloats { state with nextView := 4 } [(.position ⟨1⟩ marker, true)]
  let other ← createText "other"
  let scroll ← other.mark (.anchor { offset := 0, bias := .before })
  let selection ← other.mark (.selection { ranges := #[⟨0, 0⟩] })
  let history ← UndoTree.over other
  return {
      state with
      buffers := state.buffers.push (some { name := "other", text := other, history })
      windows := state.windows.push { id := ⟨5⟩, buffer := ⟨1⟩, scroll, selection }
      frame :=
        { state.frame with
          layout := .edge .left 25 (.splits resized), focused := ⟨1⟩, lastFocused := some ⟨0⟩
          tabsAfter := #[{ windows := #[⟨5⟩], focused := ⟨5⟩, name := some "logs" }] }
      nextView := 6 }

/-- The record `of` makes of `built`. -/
def recorded : Option (Frame.Record × Bool) :=
  let program : TextM (Frame.Record × Bool) := do
    let state ← built
    return (← Frame.Record.of state, state.wellFormed)
  (program.runModel {}).1.toOption

end RestoreFrameTest

open RestoreFrameTest in
/-- The checks of the frame as the session index records it
(`Editor/Restore/Frame.lean`). -/
def restoreFrameChecks : List Check :=
  [{  name :=
        "a frame's record round-trips through its JSON: two tabs, a name, docked and floating windows, a zoom and every layout"
      run :=
        pure <|
          roundTrips sample && roundTrips {} &&
            [Layout.monocle, .masterStack {}, .splits .tile, .splits resized,
                  .edge .top 30 (.edge .left 25 (.splits resized)),
                  .edge .bottom 10 (.masterStack { side := .bottom, count := 0 })].all
              fun layout => roundTrips { tabs := #[{ windows := #[0], layout, focused := 0 }] } },
    { name := "the floats' anchors round-trip: the frame, a window and a position"
      run :=
        pure <|
          [Float.Anchor.frame, .window 2, .position 2 ⟨7, 9⟩].all fun anchor =>
            roundTrips
              {
                tabs :=
                  #[{ windows := #[2], floats := #[{ view := 3, anchor }], focused := 2 }] } },
    { name := "keys a record does not know inside the frame are passed over"
      run :=
        pure <|
          let text :=
            "{\"selected\":0,\"later\":[1],\"tabs\":[{\"windows\":[0],\"docked\":[],\"floats\":[],\"layout\":\"monocle\",\"focused\":0,\"folds\":true}]}"
          match Json.parse text.toUTF8 with
          | .ok json =>
            Frame.Record.ofJson? json ==
              some { tabs := #[{ windows := #[0], layout := .monocle, focused := 0 }] }
          | .error _ => false },
    { name :=
        "renumbering gives the tab in view's focused view the start's id and every other the next free id in order, keeping the shape: focus, the window focused before, docked windows, float anchors and the windows elsewhere"
      run :=
        pure <|
          let (renumbered, map, next) := sample.renumber 0 20
          map == #[(0, 20), (1, 0), (2, 21), (3, 22), (4, 23), (7, 24), (8, 25)] && next == 26 &&
            renumbered ==
              { sample with
                tabs :=
                  #[{ windows := #[20, 0, 21], docked := #[(22, .left)]
                      floats :=
                        #[{ view := 23, anchor := .position 0 ⟨1, 2⟩, share := { width := 40 }
                            pinned := true }]
                      layout := .edge .left 25 (.splits resized), focused := 0
                      lastFocused := some 20 },
                    { name := some "logs", windows := #[24, 25], layout := .monocle
                      zoomedFrom := some (.masterStack { share := 60, side := .right, count := 2 })
                      focused := 25 }]
                elsewhere := #[(25, "*vc-status*")] } &&
            renumbered.check.isNone },
    { name :=
        "check takes a well-formed record, and refuses each break of what a state keeps: no tab, the tab in view past the tabs, a view in two places, no tiled window, a layout that does not fit, a docked side with no edge, a float anchored outside its tab, a focus not the tab's"
      run :=
        pure <|
          let first : Tab.Record :=
            { windows := #[0, 1, 2], docked := #[(3, .left)]
              floats := #[{ view := 4, anchor := .position 1 ⟨1, 2⟩ }]
              layout := .edge .left 25 (.splits resized), focused := 1 }
          let breaks : List Frame.Record :=
            [{}, { sample with selected := 2 },
              { sample with tabs := #[first, { first with windows := #[9, 1] }] },
              { sample with
                tabs :=
                  #[{ first with
                      windows := #[], floats := #[], docked := #[] }] },
              { sample with tabs := #[{ first with layout := .splits .tile }] },
              { sample with tabs := #[{ first with docked := #[(3, .right)] }] },
              { sample with
                tabs := #[{ first with floats := #[{ view := 4, anchor := .window 9 }] }] },
              { sample with tabs := #[{ first with focused := 9 }] }]
          sample.check.isNone && breaks.all (·.check.isSome) },
    { name :=
        "the record of a state: its tabs in order, the one in view, manual splits after a resize at an edge, a docked window, a pinned float at a position as a spot, a named tab, the window focused before, and a window whose buffer is not kept elsewhere"
      run :=
        pure <|
          recorded ==
            some ({
                  selected := 0, chosen := none
                  tabs :=
                    #[{ windows := #[0, 1, 2], docked := #[(3, .left)]
                        floats := #[{ view := 4, anchor := .position 1 ⟨1, 1⟩, pinned := true }]
                        layout := .edge .left 25 (.splits resized), focused := 1
                        lastFocused := some 0 },
                      { name := some "logs", windows := #[5], focused := 5 }]
                  elsewhere := #[(5, "other")] }, true) }]

end ModelTest
