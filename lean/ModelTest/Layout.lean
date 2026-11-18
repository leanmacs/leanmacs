import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Display.Model
import Editor.Ex.Line
import Editor.Floating
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Language
import Editor.Layout
import Editor.Mode
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.State.Request
import Editor.TabBar
import ModelTest.Ports

/-!
# Model tests: layout and state

The checks of the user's origin, window layout and floats, the editor's
state and tabs, state requests and the loop.

Its lists of checks: `originChecks`, `layoutChecks`, `floatChecks`,
`windowOperationChecks`, `floatingWindowChecks`, `stateChecks`, `tabChecks`,
`stateRequestChecks`, `loopChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- The checks of the user's origin (`Origin.user`) and of how a refusal is
described to the user (`TextError.describe`). -/
def originChecks : List Check :=
  [{  name :=
        "the user's origin is not the unattributed one, and a transaction applied with it is traced to an entry by the user"
      run := do
        let command : TextM (Array Attribution) := do
          let text ← createText "ab"
          discard <| text.apply (Transaction.replacing 2 1 1 "xyz") Origin.user
          text.trace 0 5
        return Origin.user != Origin.unattributed &&
            resulted (command.runModel {}).1 ==
              .inr
                #[{ start := 0, stop := 1, author := .earlier 0 },
                  { start := 1, stop := 4, author := .entry 1 Origin.user },
                  { start := 4, stop := 5, author := .earlier 0 }] },
    { name := "every refusal of the text port is described in a few words of its own"
      run :=
        pure
          ([TextError.noSuchText, .badRange, .noSuchSnapshot, .badPosition, .badChange,
                  .badSelection, .unknownRevision, .forgotten, .noSuchMarker, .noInverse,
                  .notInState].map
              TextError.describe ==
            ["no such text", "bad range", "no such snapshot", "bad position", "bad change",
              "bad selection", "unknown revision", "forgotten revision", "no such marker",
              "no inverse", "not in state"]) }]

/-- The rectangle of a frame of `size`, from its top left. -/
def frameRect (size : Size) : Rect :=
  { x := 0, y := 0, width := size.width, height := size.height }

/-- The area of `rect`. -/
def area (rect : Rect) : Nat :=
  rect.width * rect.height

/-- The area two rectangles share: none when they do not overlap. -/
def shared (first second : Rect) : Nat :=
  (min (first.x + first.width) (second.x + second.width) - max first.x second.x) *
    (min (first.y + first.height) (second.y + second.height) - max first.y second.y)

/-- Whether no two of `rects` share any area. -/
def disjoint : List Rect → Bool
  | [] => true
  | rect :: rest => rest.all (shared rect · == 0) && disjoint rest

/-- Whether `parts` tile `whole`: each is inside it, no two share any area,
and their areas sum to its area. -/
def tiles (whole : Rect) (parts : Array Rect) : Bool :=
  parts.all
      (fun part =>
        whole.x ≤ part.x && whole.y ≤ part.y && part.x + part.width ≤ whole.x + whole.width &&
          part.y + part.height ≤ whole.y + whole.height) &&
    disjoint parts.toList &&
    (parts.map area).foldl (· + ·) 0 == area whole

/-- Frame sizes for the tiling checks: even, odd, small and zero. -/
def sampleSizes : List Size :=
  [⟨640, 480⟩, ⟨641, 479⟩, ⟨7, 3⟩, ⟨1, 1⟩, ⟨0, 0⟩, ⟨0, 480⟩, ⟨640, 0⟩]

/-- The windows `0` to `count - 1`, in order. -/
def windowsUpTo (count : Nat) : Array ViewId :=
  (Array.range count).map (⟨·⟩)

/-- The rectangles the layout checks lay windows out in: each of
`sampleSizes`, at the frame's origin and away from it. -/
def sampleRects : List Rect :=
  sampleSizes.flatMap fun size =>
    [frameRect size, { x := 5, y := 7, width := size.width, height := size.height }]

/-- The trees of the manual split layout reached from one tile by up to
`splits` splits, each of any tile on either axis, and each then balanced
along its axis or not: every tree once per way of reaching it. -/
def splitsReached (splits : Nat) : List Splits :=
  (List.range splits).foldl
      (fun (all, last) _ =>
        let next :=
          last.flatMap fun tree =>
            (List.range tree.size).flatMap fun index =>
              [Axis.rows, .columns].flatMap fun axis =>
                let inserted := tree.insert index axis
                [inserted, inserted.balance (· == axis)]
        (all ++ next, next))
      ([Splits.tile], [Splits.tile]) |>.1

/-- The checks of the layouts (`Editor/Layout.lean`): master-and-stack's
rectangles tile the area for any number of windows, any count of main's
and any size, with its geometry pinned; monocle gives the whole area to
one window; and the manual split layout's rectangles tile the area for
every tree its operations reach, with its geometry and its operations
pinned. -/
def layoutChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let shares := [0, 1, 33, 50, 61, 99, 100, 150]
  let sides := [Side.left, .right, .top, .bottom]
  [{  name :=
        "criterion 1: master-and-stack gives each of one to eight windows exactly one rectangle, in list order, and they tile the area: each inside it, no two overlapping, their areas summing to its, at even, odd, small and zero sizes, for every share, every side and every count of main's windows from 0 to 9"
      run :=
        pure <|
          (List.range 8).all fun index =>
            let windows := windowsUpTo (index + 1)
            sampleRects.all fun whole =>
              shares.all fun share =>
                sides.all fun side =>
                  (List.range 10).all fun count =>
                    let laid := (Layout.masterStack { share, side, count }).place windows ⟨0⟩ whole
                    laid.map (·.1) == windows && tiles whole (laid.map (·.2)) },
    { name :=
        "master-and-stack's count of main's windows: with 2 of 4 the first two divide main's half and the other two the stack's, each the other way; with 0, and with as many as there are windows or more, every window divides the whole area that way"
      run :=
        pure <|
          let four := windowsUpTo 4
          let whole := rect 0 0 640 480
          let rows : Array (ViewId × Rect) :=
            #[(⟨0⟩, rect 0 0 640 120), (⟨1⟩, rect 0 120 640 120), (⟨2⟩, rect 0 240 640 120),
              (⟨3⟩, rect 0 360 640 120)]
          (Layout.masterStack { count := 2 }).place four ⟨0⟩ whole ==
              #[(⟨0⟩, rect 0 0 320 240), (⟨1⟩, rect 0 240 320 240), (⟨2⟩, rect 320 0 320 240),
                (⟨3⟩, rect 320 240 320 240)] &&
            (Layout.masterStack { count := 0 }).place four ⟨0⟩ whole == rows &&
            (Layout.masterStack { count := 4 }).place four ⟨0⟩ whole == rows &&
            (Layout.masterStack { count := 5 }).place four ⟨0⟩ whole == rows },
    { name :=
        "the manual split layout gives each window of the list exactly one rectangle, in list order, and they tile the area, for every tree reached from one tile by up to four splits at every tile on both axes, balanced or not, and for trees whose weights are 0 and 0, 0 and 1, and 3 and 1, at even, odd, small and zero sizes"
      run :=
        pure <|
          let weighted : List Splits :=
            [.split .rows 0 0 .tile .tile, .split .columns 0 1 .tile .tile,
              .split .rows 3 1 .tile (.split .columns 0 0 .tile .tile),
              .split .columns 3 1 (.split .rows 0 1 .tile .tile) .tile]
          (splitsReached 4 ++ weighted).all fun tree =>
            let windows := windowsUpTo tree.size
            sampleRects.all fun whole =>
              let laid := (Layout.splits tree).place windows ⟨0⟩ whole
              laid.map (·.1) == windows && tiles whole (laid.map (·.2)) },
    { name :=
        "the manual split layout's geometry: two splits of the first tile on rows at 640 by 464, each balanced, give rows of 154, 155 and 155, each cut rounding its first part down; a column split inside a row split cuts the row; a tree whose tiles are as many as the windows is kept, and any other is fitted to as many even rows"
      run :=
        pure <|
          let twice :=
            (((Splits.tile.insert 0 .rows).balance (· == .rows)).insert 0 .rows).balance
              (· == .rows)
          let grid := Splits.split .rows 1 1 (.split .columns 1 1 .tile .tile) .tile
          (Layout.splits twice).place (windowsUpTo 3) ⟨0⟩ (rect 0 0 640 464) ==
              #[(⟨0⟩, rect 0 0 640 154), (⟨1⟩, rect 0 154 640 155), (⟨2⟩, rect 0 309 640 155)] &&
            (Layout.splits grid).place (windowsUpTo 3) ⟨0⟩ (rect 0 0 640 480) ==
              #[(⟨0⟩, rect 0 0 320 240), (⟨1⟩, rect 320 0 320 240), (⟨2⟩, rect 0 240 640 240)] &&
            grid.fit 3 == grid &&
            grid.fit 2 == Splits.even .rows 2 &&
            (Splits.even .rows 3).size == 3 &&
            (Layout.splits grid).place (windowsUpTo 2) ⟨0⟩ (rect 0 0 640 480) ==
              #[(⟨0⟩, rect 0 0 640 240), (⟨1⟩, rect 0 240 640 240)] &&
            Layout.manual.place (windowsUpTo 1) ⟨0⟩ (rect 0 0 640 480) ==
              #[(⟨0⟩, rect 0 0 640 480)] &&
            Layout.manual.place #[] ⟨0⟩ (rect 0 0 640 480) == #[] },
    { name :=
        "the manual split layout's operations: a split then the removal of either of its two tiles gives back the tree; a removed tile's parent is replaced by its sibling, and the tile that inherits its place is the first of the next part of its group, or the last of the previous part when it was last, with the group's axis"
      run :=
        pure <|
          let three := Splits.split .columns 1 1 (.split .rows 1 1 .tile .tile) .tile
          let nested := Splits.split .rows 1 1 (.split .rows 1 1 .tile .tile) .tile
          (splitsReached 3).all
              (fun tree =>
                (List.range tree.size).all fun index =>
                  [Axis.rows, .columns].all fun axis =>
                    ((tree.insert index axis).remove index).map (·.1) == some tree &&
                      ((tree.insert index axis).remove (index + 1)).map (·.1) == some tree) &&
            three.remove 1 == some (.split .columns 1 1 .tile .tile, 0, .rows) &&
            three.remove 0 == some (.split .columns 1 1 .tile .tile, 0, .rows) &&
            three.remove 2 == some (.split .rows 1 1 .tile .tile, 1, .columns) &&
            nested.remove 1 == some (.split .rows 1 1 .tile .tile, 1, .rows) &&
            Splits.tile.remove 0 == none &&
            three.remove 3 == none },
    { name :=
        "balancing the manual split layout sets each split on a chosen axis to the slots of its parts along it: a tile one, a split on the same axis the sum of its parts', and one on the other axis the larger of its parts'; three tiles in a row are 1 to 2 and then 1 to 1"
      run :=
        pure <|
          let row := Splits.split .columns 5 1 .tile (.split .columns 3 3 .tile .tile)
          let mixed :=
            Splits.split .columns 7 1 (.split .rows 1 4 .tile (.split .rows 1 1 .tile .tile))
              (.split .rows 2 1 .tile .tile)
          row.balance (· == .columns) ==
              .split .columns 1 2 .tile (.split .columns 1 1 .tile .tile) &&
            mixed.balance (· == .columns) ==
              .split .columns 1 1 (.split .rows 1 4 .tile (.split .rows 1 1 .tile .tile))
                (.split .rows 2 1 .tile .tile) &&
            mixed.balance (· == .rows) ==
              .split .columns 7 1 (.split .rows 1 2 .tile (.split .rows 1 1 .tile .tile))
                (.split .rows 1 1 .tile .tile) &&
            (mixed.balance fun _ => true) ==
              .split .columns 1 1 (.split .rows 1 2 .tile (.split .rows 1 1 .tile .tile))
                (.split .rows 1 1 .tile .tile) },
    { name :=
        "resizing in the manual split layout moves the boundary of the deepest split on the axis that holds the tile by 5 percent a step, growing the tile's part or shrinking it, clamped to 0 and 100; with no split on the axis holding the tile it is none"
      run :=
        pure <|
          let grid := Splits.split .rows 1 1 (.split .columns 1 1 .tile .tile) .tile
          grid.resize 1 .columns true 1 ==
              some (.split .rows 1 1 (.split .columns 45 55 .tile .tile) .tile) &&
            grid.resize 0 .columns true 2 ==
              some (.split .rows 1 1 (.split .columns 60 40 .tile .tile) .tile) &&
            grid.resize 0 .rows false 1 ==
              some (.split .rows 45 55 (.split .columns 1 1 .tile .tile) .tile) &&
            grid.resize 2 .rows true 30 ==
              some (.split .rows 0 100 (.split .columns 1 1 .tile .tile) .tile) &&
            grid.resize 2 .columns true 1 == none &&
            Splits.tile.resize 0 .rows true 1 == none },
    { name :=
        "rotating the windows: under master-and-stack the stack rotates and main stays, forward putting the last first, as Vim's C-w r, and back the reverse; under the manual split layout and monocle the whole list rotates"
      run :=
        pure <|
          let four := windowsUpTo 4
          let ids (indices : List Nat) : Array ViewId := indices.toArray.map (⟨·⟩)
          Layout.default.rotated four true == ids [0, 3, 1, 2] &&
            Layout.default.rotated four false == ids [0, 2, 3, 1] &&
            (Layout.masterStack { count := 2 }).rotated four true == ids [0, 1, 3, 2] &&
            Layout.manual.rotated four true == ids [3, 0, 1, 2] &&
            Layout.monocle.rotated four false == ids [1, 2, 3, 0] &&
            Layout.default.rotated #[⟨0⟩] true == #[⟨0⟩] },
    { name :=
        "master-and-stack's geometry: main takes its share of the extent on its side, rounded down, and the stack the rest, cut the other way into equal parts, the first ones a pixel larger; one window takes the whole area, and no window none"
      run :=
        pure <|
          let three := windowsUpTo 3
          let whole := rect 0 0 640 480
          Layout.default.place three ⟨0⟩ whole ==
              #[(⟨0⟩, rect 0 0 320 480), (⟨1⟩, rect 320 0 320 240), (⟨2⟩, rect 320 240 320 240)] &&
            (Layout.masterStack { share := 60, side := .right }).place three ⟨0⟩ whole ==
              #[(⟨0⟩, rect 256 0 384 480), (⟨1⟩, rect 0 0 256 240), (⟨2⟩, rect 0 240 256 240)] &&
            (Layout.masterStack { side := .top }).place three ⟨0⟩ whole ==
              #[(⟨0⟩, rect 0 0 640 240), (⟨1⟩, rect 0 240 320 240), (⟨2⟩, rect 320 240 320 240)] &&
            (Layout.masterStack { side := .bottom }).place three ⟨0⟩ whole ==
              #[(⟨0⟩, rect 0 240 640 240), (⟨1⟩, rect 0 0 320 240), (⟨2⟩, rect 320 0 320 240)] &&
            Layout.default.place (windowsUpTo 4) ⟨0⟩ (rect 0 0 640 479) ==
              #[(⟨0⟩, rect 0 0 320 479), (⟨1⟩, rect 320 0 320 160), (⟨2⟩, rect 320 160 320 160),
                (⟨3⟩, rect 320 320 320 159)] &&
            (Layout.masterStack { share := 150 }).place (windowsUpTo 2) ⟨0⟩ whole ==
              #[(⟨0⟩, whole), (⟨1⟩, rect 640 0 0 480)] &&
            Layout.default.place #[⟨4⟩] ⟨4⟩ (rect 5 7 30 20) == #[(⟨4⟩, rect 5 7 30 20)] &&
            Layout.default.place #[] ⟨0⟩ whole == #[] },
    { name :=
        "criterion 2: monocle gives the selected window the whole area and no other window any, for one to eight windows, every selected window and every size; a selected window not in the list gives the first window the area, and no window gives none"
      run :=
        pure <|
          (List.range 8).all fun index =>
            let windows := windowsUpTo (index + 1)
            sampleRects.all fun whole =>
              windows.all
                  (fun selected =>
                    Layout.monocle.place windows selected whole == #[(selected, whole)]) &&
                Layout.monocle.place windows ⟨9⟩ whole == #[(⟨0⟩, whole)] &&
                Layout.monocle.place #[] ⟨0⟩ whole == #[] },
    { name :=
        "criterion 2: an edge layout gives the windows docked at its side a strip of its size in percent of the extent along the side's axis, divided the other way, and the layout inside it the rest; tiles first, then the strip; a right edge cuts from the right, and a bottom edge inside a left one spans only the width the left strip leaves"
      run :=
        pure <|
          let docked (entries : List (Nat × Side)) : Array (ViewId × Side) :=
            entries.toArray.map fun (index, side) => (⟨index⟩, side)
          let two := windowsUpTo 2
          let whole := rect 0 0 640 464
          (Layout.edge .left 25 Layout.default).place two ⟨0⟩ whole (docked [(2, .left)]) ==
              #[(⟨0⟩, rect 160 0 240 464), (⟨1⟩, rect 400 0 240 464), (⟨2⟩, rect 0 0 160 464)] &&
            (Layout.edge .left 25 Layout.default).place two ⟨0⟩ whole
                (docked [(2, .left), (3, .left)]) ==
              #[(⟨0⟩, rect 160 0 240 464), (⟨1⟩, rect 400 0 240 464), (⟨2⟩, rect 0 0 160 232),
                (⟨3⟩, rect 0 232 160 232)] &&
            (Layout.edge .right 25 Layout.default).place two ⟨0⟩ whole (docked [(2, .right)]) ==
              #[(⟨0⟩, rect 0 0 240 464), (⟨1⟩, rect 240 0 240 464), (⟨2⟩, rect 480 0 160 464)] &&
            (Layout.edge .left 20 (.edge .bottom 30 Layout.default)).place two ⟨0⟩
                (rect 0 0 640 480) (docked [(2, .left), (3, .bottom)]) ==
              #[(⟨0⟩, rect 128 0 256 336), (⟨1⟩, rect 384 0 256 336), (⟨3⟩, rect 128 336 512 144),
                (⟨2⟩, rect 0 0 128 480)] },
    { name :=
        "an edge layout with no window docked at its side reserves no strip: it lays out exactly as the layout inside it, and the default arguments dock nothing"
      run :=
        pure <|
          let whole := rect 0 0 640 464
          [Layout.default, .monocle, Layout.manual].all fun inner =>
            (List.range 4).all fun count =>
              let windows := windowsUpTo (count + 1)
              (Layout.edge .left 25 inner).place windows ⟨0⟩ whole #[] ==
                  inner.place windows ⟨0⟩ whole &&
                (Layout.edge .top 40 (.edge .left 25 inner)).place windows ⟨0⟩ whole ==
                  inner.place windows ⟨0⟩ whole },
    { name :=
        "criterion 2: edge layouts of up to two layers, at each side and sizes of 0, 1, 25, 50 and 100 percent, over master-and-stack, monocle and manual splits, give every docked window exactly one rectangle and every tile one (under monocle the selected tile alone), tiles first in list order, and the rectangles tile the area, for one to five tiles, none to two windows docked at each layer's side, at even, odd, small and zero sizes"
      run :=
        pure <|
          let sizes := [0, 1, 25, 50, 100]
          let sides := [Side.left, .right, .top, .bottom]
          let layers : List (List (Side × Nat)) :=
            [[]] ++ sides.flatMap (fun side => sizes.map fun size => [(side, size)]) ++
              sides.flatMap fun outer =>
                (sides.filter (· != outer)).flatMap fun inner =>
                  [0, 25, 100].flatMap fun first =>
                    [1, 50].map fun second => [(outer, first), (inner, second)]
          let wrapped (inner : Layout) (layers : List (Side × Nat)) : Layout :=
            layers.foldr (fun (side, size) layout => .edge side size layout) inner
          let dockings (layers : List (Side × Nat)) : List (Array (ViewId × Side)) :=
            layers.foldl
              (fun (all : List (Array (ViewId × Side))) (side, _) =>
                all.flatMap fun so =>
                  (List.range 3).map fun count =>
                    so ++ (Array.range count).map fun index => (⟨10 + so.size + index⟩, side))
              [#[]]
          let sorted (ids : Array ViewId) : Array Nat := (ids.map (·.index)).qsort (· < ·)
          [Layout.default, .monocle, Layout.manual].all fun inner =>
            layers.all fun layer =>
              let layout := wrapped inner layer
              (dockings layer).all fun docked =>
                (List.range 5).all fun index =>
                  let windows := windowsUpTo (index + 1)
                  sampleRects.all fun whole =>
                    let laid := layout.place windows ⟨0⟩ whole docked
                    let ids := laid.map (·.1)
                    let shownTiles := if inner == .monocle then #[⟨0⟩] else windows
                    tiles whole (laid.map (·.2)) &&
                      sorted ids == sorted (shownTiles ++ docked.map (·.1)) &&
                      ids.extract 0 shownTiles.size == shownTiles },
    { name :=
        "monocle with the selected view docked shows it over the whole area, as a zoom from a docked window does; with a selected view docked or tiled nowhere it shows the first window"
      run :=
        pure <|
          let whole := rect 0 0 640 464
          Layout.monocle.place (windowsUpTo 2) ⟨2⟩ whole #[(⟨2⟩, .left)] == #[(⟨2⟩, whole)] &&
            Layout.monocle.place (windowsUpTo 2) ⟨7⟩ whole #[(⟨2⟩, .left)] == #[(⟨0⟩, whole)] },
    { name :=
        "the operations of a layout on its list pass through an edge to the layout inside it: inserted, removed, fits, fitted, balanced, resized and rotated under an edge are the inner layout's, wrapped; the edge's sides, its tiling layout and a tiling replaced are read through every layer"
      run :=
        pure <|
          let tree := Splits.split .columns 3 1 .tile (.split .rows 1 1 .tile .tile)
          let inners : List Layout :=
            [Layout.default, .masterStack { share := 70, count := 2 }, .monocle, .splits tree]
          let four := windowsUpTo 4
          inners.all
                        (fun inner =>
                          let edged := Layout.edge .left 25 inner
                          edged.inserted 1 { axis := .columns } ==
                              .edge .left 25 (inner.inserted 1 { axis := .columns }) &&
                            edged.removed 1 ==
                              (.edge .left 25 (inner.removed 1).1, (inner.removed 1).2) &&
                            edged.fits 5 == .edge .left 25 (inner.fits 5) &&
                            edged.fitted 3 == inner.fitted 3 &&
                            edged.balanced == .edge .left 25 inner.balanced &&
                            edged.resized 0 3 .columns true 1 ==
                              (inner.resized 0 3 .columns true 1).map (.edge .left 25 ·) &&
                            edged.rotated four true == inner.rotated four true) &&
                      (Layout.edge .left 20 (.edge .bottom 30 Layout.manual)).edgeSides ==
                        [.left, .bottom] &&
                    Layout.default.edgeSides == [] &&
                  (Layout.edge .left 20 (.edge .bottom 30 Layout.manual)).tiling == Layout.manual &&
                Layout.monocle.tiling == .monocle &&
              (Layout.edge .left 20 (.edge .bottom 30 Layout.manual)).withTiling .monocle ==
                .edge .left 20 (.edge .bottom 30 .monocle) &&
            Layout.manual.withTiling .monocle == .monocle },
    { name :=
        "resizing an edge's strip moves its size by 5 percent a step, growing or shrinking, clamped to 0 and 100, at any layer; across the side's axis, and for a side the layout has no edge at, it is none"
      run :=
        pure <|
          let d := Layout.default
          (Layout.edge .left 25 d).resizedEdge .left .columns true 1 == some (.edge .left 30 d) &&
            (Layout.edge .left 25 d).resizedEdge .left .columns false 2 ==
              some (.edge .left 15 d) &&
            (Layout.edge .left 98 d).resizedEdge .left .columns true 1 ==
              some (.edge .left 100 d) &&
            (Layout.edge .left 3 d).resizedEdge .left .columns false 1 == some (.edge .left 0 d) &&
            (Layout.edge .left 25 d).resizedEdge .left .rows true 1 == none &&
            (Layout.edge .left 25 d).resizedEdge .right .columns true 1 == none &&
            d.resizedEdge .left .columns true 1 == none &&
            (Layout.edge .left 20 (.edge .bottom 30 d)).resizedEdge .bottom .rows true 1 ==
              some (.edge .left 20 (.edge .bottom 35 d)) },
    { name :=
        "what is wrong with a layout config chooses: an edge above 100 percent, a side given twice, and a share above 100 at any depth, each with its sentence; every other layout has nothing wrong"
      run :=
        pure <|
          let d := Layout.default
          (Layout.edge .left 101 d).problem? == some (Layout.edgeTooLarge 101) &&
            (Layout.edge .left 20 (.edge .bottom 30 (.edge .left 10 d))).problem? ==
              some (Layout.edgeTwice .left) &&
            (Layout.edge .left 20 (.masterStack { share := 150 })).problem? ==
              some (Layout.shareTooLarge 150) &&
            (Layout.masterStack { share := 150 }).problem? == some (Layout.shareTooLarge 150) &&
            (Layout.edge .left 100 (.edge .right 0 d)).problem? == none &&
            [d, .monocle, Layout.manual].all (·.problem? == none) &&
            Layout.edgeTooLarge 101 != Layout.edgeTwice .left },
    { name :=
        "the carve: of two side-by-side tiles the left one gives up the divider's width at its right, and the divider is that strip, full height; of two stacked tiles the upper one gives up the width at its foot, the divider across its width"
      run :=
        pure <|
          let whole := rect 0 0 640 480
          Layout.carve whole 2 #[(⟨0⟩, rect 0 0 320 480), (⟨1⟩, rect 320 0 320 480)] ==
              (#[(⟨0⟩, rect 0 0 318 480), (⟨1⟩, rect 320 0 320 480)], #[rect 318 0 2 480]) &&
            Layout.carve whole 2 #[(⟨0⟩, rect 0 0 640 240), (⟨1⟩, rect 0 240 640 240)] ==
              (#[(⟨0⟩, rect 0 0 640 238), (⟨1⟩, rect 0 240 640 240)], #[rect 0 238 640 2]) &&
            Layout.carve whole 2 (Layout.default.place (windowsUpTo 3) ⟨0⟩ whole) ==
              (#[(⟨0⟩, rect 0 0 318 480), (⟨1⟩, rect 320 0 320 238), (⟨2⟩, rect 320 240 320 240)],
                #[rect 318 0 2 480, rect 320 238 320 2]) },
    { name :=
        "the carve of one tile, and of monocle's, gives no divider and leaves the tile as it was; a tile short of both edges gives up its right strip, full height, and then its foot, short of that strip"
      run :=
        pure <|
          let whole := rect 0 0 640 480
          let grid := Splits.split .rows 1 1 (.split .columns 1 1 .tile .tile) .tile
          Layout.carve whole 2 #[(⟨0⟩, whole)] == (#[(⟨0⟩, whole)], #[]) &&
            Layout.carve whole 2 (Layout.monocle.place (windowsUpTo 3) ⟨1⟩ whole) ==
              (#[(⟨1⟩, whole)], #[]) &&
            Layout.carve whole 2 ((Layout.splits grid).place (windowsUpTo 3) ⟨0⟩ whole) ==
              (#[(⟨0⟩, rect 0 0 318 238), (⟨1⟩, rect 320 0 320 238), (⟨2⟩, rect 0 240 640 240)],
                #[rect 318 0 2 240, rect 0 238 318 2, rect 320 238 320 2]) &&
            Layout.carve whole 2 #[] == (#[], #[]) },
    { name :=
        "the carve of a tile narrower or shorter than the divider's width gives up the whole tile and no more, and no divider is empty"
      run :=
        pure <|
          let whole := rect 0 0 3 3
          let narrow := Splits.split .columns 1 2 .tile .tile
          let short := Splits.split .rows 1 2 .tile .tile
          Layout.carve whole 2 ((Layout.splits narrow).place (windowsUpTo 2) ⟨0⟩ whole) ==
              (#[(⟨0⟩, rect 0 0 0 3), (⟨1⟩, rect 1 0 2 3)], #[rect 0 0 1 3]) &&
            Layout.carve whole 2 ((Layout.splits short).place (windowsUpTo 2) ⟨0⟩ whole) ==
              (#[(⟨0⟩, rect 0 0 3 0), (⟨1⟩, rect 0 1 3 2)], #[rect 0 0 3 1]) &&
            Layout.carve whole 2 #[(⟨0⟩, rect 0 0 0 3), (⟨1⟩, rect 0 0 3 3)] ==
              (#[(⟨0⟩, rect 0 0 0 3), (⟨1⟩, rect 0 0 3 3)], #[]) },
    { name :=
        "the carve keeps every window's place in the list and every tile's top left corner, and the carved rectangles and the dividers tile the area together, with no divider empty; a tile along the area's right edge or foot keeps that edge, so no divider runs along the area's edges, for master-and-stack at every side, share and count, every manual split tree reached by up to three splits, monocle, and edges with docked windows over each, for one to five windows, at even, odd, small and zero sizes"
      run :=
        pure <|
          let edged : List (Layout × Array (ViewId × Side)) :=
            [Layout.default, .monocle, Layout.manual].flatMap fun inner =>
              [(Layout.edge .left 25 inner, #[(⟨10⟩, .left)]),
                (Layout.edge .right 30 inner, #[(⟨10⟩, .right), (⟨11⟩, .right)]),
                (Layout.edge .left 20 (.edge .bottom 30 inner), #[(⟨10⟩, .left), (⟨11⟩, .bottom)])]
          let layouts : List (Layout × Array (ViewId × Side)) :=
            (shares.flatMap fun share =>
                sides.flatMap fun side =>
                  [0, 1, 2].map fun count => (Layout.masterStack { share, side, count }, #[])) ++
              (splitsReached 3).map (fun tree => (Layout.splits tree, #[])) ++
              [(Layout.monocle, #[])] ++
              edged
          layouts.all fun (layout, docked) =>
            (List.range 5).all fun index =>
              let windows := windowsUpTo (index + 1)
              sampleRects.all fun whole =>
                let laid := layout.place windows ⟨0⟩ whole docked
                let (carved, dividers) := Layout.carve whole 2 laid
                let right := whole.x + whole.width
                let foot := whole.y + whole.height
                carved.map (·.1) == laid.map (·.1) && tiles whole (carved.map (·.2) ++ dividers) &&
                  (dividers.all fun divider => 0 < divider.width && 0 < divider.height) &&
                  (laid.zip carved).all fun ((_, before), (_, after)) =>
                    after.x == before.x && after.y == before.y &&
                      (before.x + before.width != right || after.x + after.width == right) &&
                      (before.y + before.height != foot || after.y + after.height == foot) }]

/-- Whether `rect` is inside `area`. -/
def inside (area rect : Rect) : Bool :=
  area.x ≤ rect.x && area.y ≤ rect.y && rect.x + rect.width ≤ area.x + area.width &&
    rect.y + rect.height ≤ area.y + area.height

/-- Whether the float `Floating.beside` places for `share` against `spot`
in `area` keeps the placement rule (`Editor/Floating.lean`, "Placement"):
inside the area; against the row, its top the row's bottom or its bottom
the row's top, sharing no pixel with the row's band; at the spot's x, or
with its right edge the area's when the spot's would overflow, and never
right of the spot; the share of the area wide; and the share tall whenever
that fits on either side, below whenever it fits below. The spot is
clamped into the area first, as the placement clamps it. -/
def besideHolds (share : Floating.Share) (spot : Display.Spot) (area : Rect) : Bool :=
  let placed := Floating.beside share spot area
  let right := area.x + area.width
  let bottom := area.y + area.height
  let x := max area.x (min spot.x right)
  let top := max area.y (min spot.y bottom)
  let rowBottom := min bottom (top + spot.height)
  let width := Floating.Share.of share.width area.width
  let height := Floating.Share.of share.height area.height
  let below := bottom - rowBottom
  let above := top - area.y
  inside area placed && (placed.y == rowBottom || placed.y + placed.height == top) &&
    (placed.y + placed.height ≤ top || rowBottom ≤ placed.y) &&
    (if x + width ≤ right then placed.x == x else placed.x + placed.width == right) &&
    placed.x ≤ x &&
    placed.width == width &&
    if height ≤ below then placed.height == height && placed.y == rowBottom
    else if height ≤ above then placed.height == height else true

/-- The checks of the placement of a float (`Editor/Floating.lean`): beside a
position, as a property over areas, windows in them, spots anywhere in
those windows, row heights and shares, and by examples; centred; and a
share resized. -/
def floatChecks : List Check :=
  let rect (x y width height : Nat) : Rect := { x, y, width, height }
  let percents := [0, 1, 25, 50, 60, 100]
  let shares : List Floating.Share :=
    percents.flatMap fun width => percents.map fun height => { width, height }
  let area := rect 0 0 640 464
  [{  name :=
        "criterion 1: a float beside a position is inside the area, against the row and clear of it, at the position or shifted left just enough, the share wide, and the share tall below when it fits there and above when it fits there, for spots at the left, middle and last pixel and at the top, middle and last row of the area and of each window master-and-stack gives one to three windows in it, rows 1, 16 and the window tall, every share from 0 to 100 on each axis, at even, odd, small and zero sizes"
      run :=
        pure <|
          sampleRects.all fun area =>
            let windows :=
              area ::
                (List.range 3).flatMap fun count =>
                  (Layout.default.place (windowsUpTo (count + 1)) ⟨0⟩ area).toList.map (·.2)
            windows.all fun window =>
              let xs := [window.x, window.x + window.width / 2, window.x + window.width - 1]
              [1, 16, window.height].all fun height =>
                let ys :=
                  [window.y, window.y + window.height / 2, window.y + window.height - height]
                xs.all fun x =>
                  ys.all fun y => shares.all fun share => besideHolds share { x, y, height } area },
    { name :=
        "a float beside a position: below the row at the position, flipped above a row near the area's bottom, shifted left near its right, and on the larger side clamped when neither side holds it"
      run :=
        pure <|
          let quarter : Floating.Share := { width := 50, height := 25 }
          let tall : Floating.Share := { width := 50, height := 100 }
          Floating.beside quarter { x := 40, y := 40, height := 16 } area == rect 40 56 320 116 &&
            Floating.beside quarter { x := 40, y := 424, height := 16 } area ==
              rect 40 308 320 116 &&
            Floating.beside quarter { x := 568, y := 40, height := 16 } area ==
              rect 320 56 320 116 &&
            Floating.beside tall { x := 40, y := 100, height := 16 } area == rect 40 116 320 348 &&
            Floating.beside tall { x := 40, y := 400, height := 16 } area == rect 40 0 320 400 },
    { name := "a float centred: 60 by 50 percent of 640 by 464 is 384 by 232 at 128, 116"
      run := pure <| Floating.centred {} area == rect 128 116 384 232 },
    { name := "a float's share resized steps by 5 percent on its axis and clamps to 5 and 100"
      run :=
        pure <|
          let share : Floating.Share := {}
          share.resized .columns true 1 == { width := 65, height := 50 } &&
            share.resized .rows false 2 == { width := 60, height := 40 } &&
            share.resized .columns true 30 == { width := 100, height := 50 } &&
            share.resized .rows false 30 == { width := 60, height := 5 } }]

/-- The initial state at 640 by 480 with two more windows over its one
buffer, each with markers of its own, laid out by the default layout: view
0 is main, and views 1 and 2 the stack.

```
+---------+---------+
|         | view 1  |
| view 0  +---------+
|         | view 2  |
+---------+---------+
|  the minibuffer's |
|       strip       |
+-------------------+
```

View 0 is focused. -/
def threeWindows : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  let more ←
    #[1, 2].mapM fun index => do
        let scroll ← buffer.text.mark (.anchor { offset := 0, bias := .before })
        let selection ← buffer.text.mark (.selection { ranges := #[⟨0, 0⟩] })
        return ({ id := ⟨index⟩, buffer := ⟨0⟩, scroll, selection } : Window)
  return { state with
      windows := state.windows ++ more
      frame := { state.frame with windows := #[⟨0⟩, ⟨1⟩, ⟨2⟩] } }

/-- The initial state at 640 by 480 with a second buffer, `other`, over a
text of its own holding "other", and a second window, view 1, on it, beside
view 0. View 0 is focused. -/
def twoBuffers : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let text ← createText "other"
  let scroll ← text.mark (.anchor { offset := 0, bias := .before })
  let selection ← text.mark (.selection { ranges := #[⟨0, 0⟩] })
  let history ← UndoTree.over text
  return { state with
      buffers := state.buffers.push (some { name := "other", text, history })
      windows := state.windows.push { id := ⟨1⟩, buffer := ⟨1⟩, scroll, selection }
      frame := { state.frame with windows := #[⟨0⟩, ⟨1⟩] } }

/-- The value of a program over the text port run on a text model with no
text; `none` if it was refused. -/
def onTextModel {α : Type} (program : TextM α) : Option α :=
  match (program.runModel {}).1 with
  | .ok value => some value
  | .error _ => none

/-- The views of `state`'s frame and their rectangles, in drawing order
(`EditorState.rects`). -/
def laidOut (state : EditorState) : Array (ViewId × Rect) :=
  state.rects

/-- The continuation the prompts of these checks are asked with: a command's
name and an argument of the asker's own. No command is registered under it
here: a continuation is plain data. -/
def asked : Invocation :=
  { command := "greet", arguments := [.nat 7] }

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
                { all := #["a"], listedFor := some "", listed := #["a"], chosen := some 1 } }) }),
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
      { state with tabBar := some { view := ⟨2⟩, text := ⟨9⟩, scroll := ⟨⟨9⟩, 0⟩, line := "" } })]

/-- `threeWindows` as three tabs: view 0 alone in the first, view 1 in the
second, which is in view, and view 2 in the third, each focused on its one
window under the default layout. -/
def threeTabs : TextM EditorState := do
  let state ← threeWindows
  return { state with
      frame :=
        { state.frame with
          windows := #[⟨1⟩], focused := ⟨1⟩
          tabsBefore := #[{ windows := #[⟨0⟩], focused := ⟨0⟩ }]
          tabsAfter := #[{ windows := #[⟨2⟩], focused := ⟨2⟩ }] } }

/-- `state` with a prompt asked for from its focused view, and the reply: the
label `Name: `, the continuation `asked`, and a minibuffer over the text
`text`, with a new history over it, an anchor that is its marker 0 and a
selection that is its marker 1. The operation asks the text store nothing,
so the ids are written out by hand. -/
def prompted (state : EditorState) (text : Nat := 7) : Except PromptRefusal ViewId × EditorState :=
  state.openPrompt "Name: " asked ⟨text⟩ (UndoTree.new ⟨text⟩ 0) ⟨⟨text⟩, 0⟩ ⟨⟨text⟩, 1⟩

/-- `state` with its open prompt's candidates replaced by `candidates`,
whatever they are, by hand: for comparing two states but for their
candidates, and for building a state no operation makes. A state with no
prompt open is as it was. -/
def withCandidates (state : EditorState) (candidates : Candidates) : EditorState :=
  { state with prompt := state.prompt.map ({ · with candidates }) }

/-- `state`, which has a prompt open, with the candidates `wq`, `edit` and
`w` and a listing of all three for the empty text, in that order, made with
the state's own operations. -/
def picking (state : EditorState) : EditorState :=
  let (_, set) := state.setCandidates #["wq", "edit", "w"]
  (set.listCandidates "" #[0, 1, 2]).2

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

/-- The initial state at 640 by 480 with `count` windows over its one
buffer, views 0 up to `count - 1` in that order, each with markers of its
own, under `layout` fitted to them. View 0 is focused. -/
def windowsUnder (count : Nat) (layout : Layout) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  let more ←
    (Array.range (count - 1)).mapM fun index => do
        let scroll ← buffer.text.mark (.anchor { offset := 0, bias := .before })
        let selection ← buffer.text.mark (.selection { ranges := #[⟨0, 0⟩] })
        return ({ id := ⟨index + 1⟩, buffer := ⟨0⟩, scroll, selection } : Window)
  return { state with
      windows := state.windows ++ more
      frame :=
        { state.frame with
          windows := windowsUpTo count, layout := layout.fits count } }

/-- The initial state at 640 by 480 with `tiles` windows in the frame's
list, views 0 up to `tiles - 1`, and a window docked at each side of
`docked`, in order, views `tiles` on, all over its one buffer and each with
markers of its own, under `layout` fitted to the tiles. View 0 is
focused. -/
def dockedUnder (tiles : Nat) (docked : List Side) (layout : Layout) : TextM EditorState := do
  let state ← windowsUnder (tiles + docked.length) layout
  return { state with
      frame :=
        { state.frame with
          windows := windowsUpTo tiles, layout := layout.fits tiles
          docked := docked.toArray.mapIdx fun index side => (⟨tiles + index⟩, side) } }

/-- `dockedUnder 2 [.left]` under `.edge .left 25 Layout.default`: views 0
and 1 tiled, main and the stack, and view 2 docked at the left edge.

```
+----+------+------+
|    |      |      |
| 2  |  0   |  1   |
|    |      |      |
+----+------+------+
```

View 0 is focused. -/
def sidebar : TextM EditorState :=
  dockedUnder 2 [.left] (.edge .left 25 Layout.default)

/-- `state` with a float on its buffer 0 for each of `floats`, an anchor and
whether it is pinned, in order, each on top of the ones before, with views
from the state's next one on (`EditorState.freshView`), markers of its own
and the default share. The focus is as it was. -/
def withFloats (state : EditorState) (floats : List (Floating.Anchor × Bool)) : TextM EditorState :=
  do
  let some buffer := state.buffer? ⟨0⟩ | throw .noSuchText
  floats.foldlM
      (fun state (anchor, pinned) => do
        let scroll ← buffer.text.mark (.anchor { offset := 0, bias := .before })
        let selection ← buffer.text.mark (.selection { ranges := #[⟨0, 0⟩] })
        let made := state.freshView
        return {
            state with
            windows := state.windows.push { id := made, buffer := ⟨0⟩, scroll, selection }
            frame :=
              { state.frame with
                floats := state.frame.floats.push { view := made, anchor, pinned } }
            nextView := made.index + 1 })
      state

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
            pure
              (([PromptRefusal.alreadyOpen ⟨1⟩, .notOpen, .notItsText, .noWindow].map
                      PromptRefusal.describe).eraseDups.length ==
                  4 &&
                [PromptRefusal.alreadyOpen ⟨1⟩, .notOpen, .notItsText, .noWindow].all fun refusal =>
                  !refusal.describe.isEmpty) },
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
                    closed.answered == #[] &&
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
                  accepted.answered ==
                      #[{ command := "greet", arguments := [.str "héllo", .nat 7] }] &&
                    { accepted with answered := #[] } == cancelled &&
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
                  two.answered ==
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
                  closed.answered.size == 1 &&
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
            "setting an open prompt's candidates replaces them and forgets the listing and the choice, and changes nothing else of the state"
          run :=
            pure <|
              match onTextModel (EditorState.initial ⟨640, 480⟩) with
              | none => false
              | some state =>
                let (_, asking) := prompted state
                let (_, chosen) := (picking asking).chooseCandidate .next
                let (set, replaced) := chosen.setCandidates #["x", "y"]
                replied set == .inr () &&
                  replaced.prompt.map (·.candidates) == some { all := #["x", "y"] } &&
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
                let (listed, after) := chosen.listCandidates "w" #[2, 9, 0, 3]
                let (emptied, unmatched) := after.listCandidates "z" #[]
                replied listed == .inr () &&
                  after.prompt.map (·.candidates) ==
                    some
                      { all := #["wq", "edit", "w"], listedFor := some "w",
                        listed := #["w", "wq"] } &&
                  replied emptied == .inr () &&
                  unmatched.prompt.map (·.candidates) ==
                    some { all := #["wq", "edit", "w"], listedFor := some "z" } &&
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
                let (_, bare) := asking.setCandidates #["a"]
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
                { all := #["wq", "edit", "w"], listedFor := some "w", listed := #["w", "wq"] }
              ({ listed with chosen := some 1 } : Candidates).answer "w" == "wq" &&
                ({ listed with chosen := some 0 } : Candidates).answer "w" == "w" &&
                listed.answer "w" == "w" &&
                ({ listed with chosen := some 1 } : Candidates).answer "wx" == "wx" &&
                ({ listed with chosen := some 1 } : Candidates).answer "" == "" &&
                ({} : Candidates).answer "typed" == "typed" &&
                ({ all := #["a"], listedFor := some "z" } : Candidates).answer "z" == "z" },
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
                refused (state.setCandidates #["a"]) && refused (state.listCandidates "a" #[0]) &&
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

/-- `twoBuffers` with a third buffer, `hidden`, over a text of its own that
no window shows, and that text. -/
def hiddenBuffer : TextM (EditorState × TextId) := do
  let state ← twoBuffers
  let text ← createText "hidden"
  let history ← UndoTree.over text
  return ({ state with buffers := state.buffers.push (some { name := "hidden", text, history }) },
      text)

/-- The path of a file of the state checks. Nothing opens it. -/
def notePath : System.FilePath :=
  "/files/note.txt"

/-- A stamp of the state checks: any one, for a file the checks say a
buffer holds. -/
def noteStamp : File.Stamp :=
  { seconds := 3, nanoseconds := 0, size := 9 }

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

/-- The requests a well-formed state is seen to stay well formed under, on
`hiddenBuffer`, whose buffers' texts are 0, 1 and 2: each kind of request,
accepted and refused. -/
def stateRequests : List StateRequest :=
  let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
  [.read, .addBuffer "new" ⟨3⟩ (UndoTree.new ⟨3⟩ 0), .addBuffer "other" ⟨3⟩ (UndoTree.new ⟨3⟩ 0),
    .removeBuffer ⟨2⟩, .removeBuffer ⟨1⟩, .removeBuffer ⟨9⟩, .setHistory ⟨0⟩ (UndoTree.new ⟨0⟩ 4),
    .setHistory ⟨0⟩ (UndoTree.new ⟨1⟩ 0), .setValue ⟨0⟩ "count" (.nat 1),
    .setValue ⟨9⟩ "count" .null, .setSpans ⟨0⟩ #[{ start := 0, stop := 1, face := ⟨"a"⟩ }],
    .setSpans ⟨9⟩ #[], .setMajorMode ⟨0⟩ "listing", .setMajorMode ⟨9⟩ "listing",
    .addMinorMode ⟨1⟩ "one", .removeMinorMode ⟨1⟩ "one", .split ⟨0⟩ (marker 0 8) (marker 0 9),
    .split ⟨1⟩ (marker 1 8) (marker 1 9), .split ⟨0⟩ (marker 1 8) (marker 0 9),
    .split ⟨9⟩ (marker 0 8) (marker 0 9), .removeWindow ⟨1⟩, .removeWindow ⟨9⟩, .focus ⟨1⟩,
    .focus ⟨9⟩, .show ⟨0⟩ ⟨2⟩ (marker 2 0) (marker 2 1), .show ⟨0⟩ ⟨9⟩ (marker 2 0) (marker 2 1),
    .show ⟨0⟩ ⟨2⟩ (marker 0 0) (marker 2 1), .show ⟨9⟩ ⟨2⟩ (marker 2 0) (marker 2 1), .message "hi",
    .startJob "count" [.nat 1], .startJob "count" [.nat 1] (some "k"), .cancelJob "k",
    .attachFile ⟨2⟩ notePath noteStamp .crlf, .attachFile ⟨9⟩ notePath noteStamp .lf,
    .beginSave ⟨0⟩ ⟨4⟩ ⟨0⟩, .beginSave ⟨9⟩ ⟨4⟩ ⟨0⟩, .endSave ⟨0⟩ ⟨4⟩ (some noteStamp),
    .endSave ⟨9⟩ ⟨4⟩ none,
    .openPrompt "Name: " asked ⟨8⟩ (UndoTree.new ⟨8⟩ 0) (marker 8 0) (marker 8 1),
    .openPrompt "Name: " asked ⟨8⟩ (UndoTree.new ⟨8⟩ 0) (marker 0 0) (marker 8 1),
    .closePrompt none, .closePrompt (some "typed"), .setCandidates #["one", "two"],
    .chooseCandidate .next, .chooseCandidate .previous,
    .setWanted ⟨0⟩ (some { column := .goal 3, head := 7 }), .setWanted ⟨1⟩ none,
    .setWanted ⟨9⟩ (some { column := .lineEnd, head := 0 }), .ex "w", .exNames, .themeNames,
    .loadTheme "second", .invoke asked, .quit, .reload, .giveUp "no", .breakOff "far enough",
    .setRegister "a" { text := "a line\n", linewise := true }, .setScrollMargin 2,
    .split ⟨0⟩ (marker 0 8) (marker 0 9) { axis := .columns, before := true },
    .arrange ⟨0⟩ .promote, .arrange ⟨1⟩ (.exchange none), .arrange ⟨0⟩ .zoom, .arrange ⟨9⟩ .zoom,
    .arrange ⟨0⟩ (.mainCount true 1), .arrange ⟨1⟩ (.edge .left),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .stack,
    .openWindow ⟨2⟩ (marker 2 8) (marker 2 9) .stack,
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.edge .left),
    .openWindow ⟨9⟩ (marker 0 8) (marker 0 9) .stack,
    .openWindow ⟨0⟩ (marker 1 8) (marker 0 9) .stack, .displayRules,
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float .frame {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨1⟩) {} true),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.position ⟨1⟩ (marker 1 3)) {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.position ⟨1⟩ (marker 0 3)) {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨9⟩) {} false),
    .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨4⟩) {} false), .arrange ⟨1⟩ .float,
    .arrange ⟨0⟩ .float, .arrange ⟨4⟩ .float, .arrange ⟨4⟩ .promote, .arrange ⟨4⟩ (.edge .left),
    .arrange ⟨4⟩ (.resize .columns true 1), .arrange ⟨4⟩ .demote, .removeWindow ⟨4⟩,
    .removeWindow ⟨3⟩, .focus ⟨4⟩, .focus ⟨3⟩, .split ⟨4⟩ (marker 0 8) (marker 0 9),
    .show ⟨1⟩ ⟨0⟩ (marker 0 0) (marker 0 1), .openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .tab,
    .tab (.select 1), .tab (.rename 1 (some "notes")), .tab (.move 0 1), .tab (.select 0),
    .tab (.close 1), .tab (.close 0), .tab (.select 7), .setLanguage ⟨0⟩ (some "rust"),
    .setLanguage ⟨0⟩ none, .setLanguage ⟨9⟩ (some "rust"), .languageOf notePath,
    .indentUnitOf "rust"]

/-- The checks of the state requests' pure handler (`EditorState.handle`,
`Editor/State/Request.lean`), on states made on the text model. The handler
asks the text store nothing, so a marker's id is written out by hand. -/
def stateRequestChecks : List Check :=
  let marker (text index : Nat) : MarkerId := ⟨⟨text⟩, index⟩
  [{  name :=
        "setLanguage records a buffer's language by name and clears it, and refuses a buffer there is none of with the state unchanged; a buffer has no language until one is set"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let languageOf (state : EditorState) : Option String :=
              (state.buffer? ⟨1⟩).bind (·.language)
            let (set, recorded) := state.handle (.setLanguage ⟨1⟩ (some "rust"))
            let (cleared, plain) := recorded.handle (.setLanguage ⟨1⟩ none)
            let (refused, same) := state.handle (.setLanguage ⟨9⟩ (some "rust"))
            set.toOption.isSome && languageOf state == none && languageOf recorded == some "rust" &&
              (recorded.buffer? ⟨0⟩).bind (·.language) == none &&
              cleared.toOption.isSome &&
              languageOf plain == none &&
              (match refused with
              | .error (.noSuchBuffer id) => id == ⟨9⟩
              | _ => false) &&
              same == state },
    { name :=
        "with no loop to answer, a path's language is none; a dispatched command that asks is answered the name of the language the loop's table chooses for the path, or none"
      run :=
        let program : EditorM (Guarded (Option String × Option String) × EditorState) := do
          (do
                  return (← languageOf "/p/main.rs", ← languageOf "/p/notes.txt")).dispatched
              { languages := Language.shipped.toList } (← twoBuffers)
        pure <|
          (EditorState.none.handle (.languageOf "/p/main.rs")).1 == none &&
            match (program.runModel editorModel).1 with
            | .ok (.finished answer, _) => answer == (some "rust", none)
            | _ => false },
    { name :=
        "with no loop to answer, a language's indent unit is none; a dispatched command that asks is answered the unit of the loop's entry of that name, the first in the table, or none; and a target's unit is its buffer's language's, or four spaces for a buffer with no language or one the table has no entry of"
      run :=
        let table := [{ Language.json with indentUnit := .tab }, Language.rust, Language.json]
        let program :
          EditorM
            (Guarded (List (Option Language.IndentUnit) × List Language.IndentUnit) ×
              EditorState) :=
          do
          (do
                  let asked := [← indentUnitOf "json", ← indentUnitOf "rust", ← indentUnitOf "toml"]
                  let unitOf (language : Option String) : EditorM Language.IndentUnit := do
                    discard <| (⟨0⟩ : BufferId).setLanguage language
                    let some target := (← editorState).target? ⟨0⟩ | throw TextError.noSuchText
                    target.indentUnit
                  let units := [← unitOf (some "json"), ← unitOf none, ← unitOf (some "toml")]
                  return (asked, units)).dispatched
              { languages := table } (← twoBuffers)
        pure <|
          (EditorState.none.handle (.indentUnitOf "rust")).1 == none &&
            match (program.runModel editorModel).1 with
            | .ok (.finished answer, _) =>
              answer == ([some .tab, some (.spaces 4), none], [.tab, .spaces 4, .spaces 4])
            | _ => false },
    { name := "a read hands back the whole state and changes nothing"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (read, after) := state.handle .read
            read == state && after == state },
    { name :=
        "a tab request is the change it carries (EditorState.changeTab), and a refused one leaves the state as it was"
      run :=
        pure <|
          match onTextModel threeTabs with
          | none => false
          | some state =>
            let (selected, after) := state.handle (.tab (.select 0))
            let (absent, same) := state.handle (.tab (.close 7))
            replied selected == .inr () && after == (state.changeTab (.select 0)).2 &&
              after.frame.tabIndex == 0 &&
              replied absent == .inl (.noSuchTab 7) &&
              same == state },
    { name :=
        "adding a buffer gives it the next slot's id and finds it by its name; a name a buffer has is refused with nameTaken, and a history over another text with notItsHistory, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let tree := UndoTree.new ⟨2⟩ 0
            let (added, after) := state.handle (.addBuffer "third" ⟨2⟩ tree)
            let (taken, same) := state.handle (.addBuffer "other" ⟨2⟩ tree)
            let (astray, still) := state.handle (.addBuffer "third" ⟨3⟩ tree)
            replied added == .inr ⟨2⟩ && after.findBuffer "third" == some ⟨2⟩ &&
              after.buffer? ⟨2⟩ == some { name := "third", text := ⟨2⟩, history := tree } &&
              state.findBuffer "third" == none &&
              state.findBuffer "other" == some ⟨1⟩ &&
              replied taken == .inl (.nameTaken "other") &&
              same == state &&
              replied astray == .inl .notItsHistory &&
              still == state },
    { name :=
        "renaming a buffer gives it the name, which then finds it; its own name changes nothing; a name another buffer has is refused with nameTaken, and a buffer there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (renamed, after) := state.handle (.renameBuffer ⟨1⟩ "renamed")
            let (own, same) := state.handle (.renameBuffer ⟨1⟩ "other")
            let (taken, kept) := state.handle (.renameBuffer ⟨1⟩ EditorState.scratchName)
            let (absent, still) := state.handle (.renameBuffer ⟨9⟩ "x")
            replied renamed == .inr () && after.findBuffer "renamed" == some ⟨1⟩ &&
              after.findBuffer "other" == none &&
              replied own == .inr () &&
              same == state &&
              replied taken == .inl (.nameTaken EditorState.scratchName) &&
              kept == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "removing a buffer empties its slot, and its id is not given to the next buffer; a buffer a window shows is refused with shown and that view, and one there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel hiddenBuffer with
          | none => false
          | some (state, _) =>
            let (removed, after) := state.handle (.removeBuffer ⟨2⟩)
            let (again, gone) := after.handle (.removeBuffer ⟨2⟩)
            let (next, _) := after.handle (.addBuffer "next" ⟨3⟩ (UndoTree.new ⟨3⟩ 0))
            let (shown, same) := state.handle (.removeBuffer ⟨1⟩)
            let (absent, still) := state.handle (.removeBuffer ⟨9⟩)
            replied removed == .inr () && after.buffers[2]? == some none &&
              after.buffer? ⟨2⟩ == none &&
              after.findBuffer "hidden" == none &&
              after.buffers.size == 3 &&
              replied again == .inl (.noSuchBuffer ⟨2⟩) &&
              gone == after &&
              replied next == .inr ⟨3⟩ &&
              replied shown == .inl (.shown ⟨1⟩) &&
              same == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "setting a buffer's history replaces its tree; a tree over another text is refused with notItsHistory, and a buffer there is none of with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let tree := UndoTree.new ⟨1⟩ 7
            let (set, after) := state.handle (.setHistory ⟨1⟩ tree)
            let (astray, same) := state.handle (.setHistory ⟨0⟩ tree)
            let (absent, still) := state.handle (.setHistory ⟨9⟩ tree)
            replied set == .inr () && (after.buffer? ⟨1⟩).map (·.history) == some tree &&
              after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
              replied astray == .inl .notItsHistory &&
              same == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              still == state },
    { name :=
        "a buffer-local value is set under its name and read back, a second value of the name replaces the first, and other names and other buffers are left; a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (set, one) := state.handle (.setValue ⟨1⟩ "count" (.nat 1))
            let (_, two) := one.handle (.setValue ⟨1⟩ "label" (.str "a"))
            let (_, three) := two.handle (.setValue ⟨1⟩ "count" (.nat 2))
            let (absent, same) := state.handle (.setValue ⟨9⟩ "count" (.nat 1))
            replied set == .inr () && state.value? ⟨1⟩ "count" == none &&
              one.value? ⟨1⟩ "count" == some (.nat 1) &&
              three.value? ⟨1⟩ "count" == some (.nat 2) &&
              three.value? ⟨1⟩ "label" == some (.str "a") &&
              ((three.buffer? ⟨1⟩).map (·.locals.size)) == some 2 &&
              three.value? ⟨0⟩ "count" == none &&
              three.value? ⟨9⟩ "count" == none &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "a buffer's spans are set, replacing those it had, and other buffers keep theirs; a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let spans : Array Decoration := #[{ start := 0, stop := 2, face := ⟨"a"⟩ }]
            let (set, one) := state.handle (.setSpans ⟨1⟩ spans)
            let (_, two) := one.handle (.setSpans ⟨1⟩ #[])
            let (absent, same) := state.handle (.setSpans ⟨9⟩ spans)
            replied set == .inr () && (state.buffer? ⟨1⟩).map (·.spans) == some #[] &&
              (one.buffer? ⟨1⟩).map (·.spans) == some spans &&
              (one.buffer? ⟨0⟩).map (·.spans) == some #[] &&
              (two.buffer? ⟨1⟩).map (·.spans) == some #[] &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "the minor-mode requests are the state's operations: one added is first, one removed is gone, and a buffer there is none of is refused with noSuchBuffer"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (added, one) := state.handle (.addMinorMode ⟨0⟩ "one")
            let (removed, bare) := one.handle (.removeMinorMode ⟨0⟩ "one")
            let (absent, same) := state.handle (.addMinorMode ⟨9⟩ "one")
            replied added == .inr () && one == (state.addMinorMode ⟨0⟩ "one").2 &&
              ((one.buffer? ⟨0⟩).map (·.minors)) == some #["one"] &&
              replied removed == .inr () &&
              bare == state &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state },
    { name :=
        "the major-mode request sets the mode of the buffer its view shows and says whether it became the major mode; a view with no window is refused with noSuchWindow, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (set, listed) := state.handle (.setMajorMode ⟨1⟩ "listing")
            let (again, same) := listed.handle (.setMajorMode ⟨1⟩ "listing")
            let (absent, still) := state.handle (.setMajorMode ⟨9⟩ "listing")
            replied set == .inr true && listed == (state.setMajorMode ⟨1⟩ "listing").2 &&
              ((listed.buffer? ⟨1⟩).bind (·.major)) == some "listing" &&
              replied again == .inr false &&
              same == listed &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              still == state },
    { name :=
        "a split gives the new window an id no window has or had, shows the source window's buffer in it with the markers handed in, puts it right after its source in the list, and leaves the focus"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (made, after) := state.handle (.split ⟨1⟩ (marker 0 8) (marker 0 9))
            let (closed, without) := after.handle (.removeWindow ⟨3⟩)
            let (next, later) := without.handle (.split ⟨0⟩ (marker 0 10) (marker 0 11))
            replied made == .inr ⟨3⟩ && after.wellFormed &&
              after.window? ⟨3⟩ ==
                some { id := ⟨3⟩, buffer := ⟨0⟩, scroll := marker 0 8, selection := marker 0 9 } &&
              after.frame.windows == #[⟨0⟩, ⟨1⟩, ⟨3⟩, ⟨2⟩] &&
              after.frame.focused == state.frame.focused &&
              after.windows.extract 0 3 == state.windows &&
              (replied closed).isRight &&
              replied next == .inr ⟨4⟩ &&
              without.frame.windows == state.frame.windows &&
              later.frame.windows == #[⟨0⟩, ⟨4⟩, ⟨1⟩, ⟨2⟩] &&
              later.frame.focused == state.frame.focused },
    { name :=
        "a split is refused with noSuchWindow for a view with no window, and with markersOfAnotherText when a marker handed in is not of the source buffer's text, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (absent, same) := state.handle (.split ⟨9⟩ (marker 0 8) (marker 0 9))
            let (scroll, still) := state.handle (.split ⟨0⟩ (marker 1 8) (marker 0 9))
            let (selection, yet) := state.handle (.split ⟨0⟩ (marker 0 8) (marker 1 9))
            replied absent == .inl (.noSuchWindow ⟨9⟩) && same == state &&
              replied scroll == .inl .markersOfAnotherText &&
              still == state &&
              replied selection == .inl .markersOfAnotherText &&
              yet == state },
    { name :=
        "splitting a window and removing the new window gives back the frame, its windows and the focus from before the split, from one window or three, whichever window is focused"
      run :=
        pure <|
          [onTextModel threeWindows, onTextModel (EditorState.initial ⟨640, 480⟩)].all fun
            | none => false
            | some start =>
              start.frame.windows.all fun focused =>
                let state := (start.focusWindow focused).2
                state.windows.all fun window =>
                  let (made, split) := state.handle (.split window.id (marker 0 8) (marker 0 9))
                  match made with
                  | .error _ => false
                  | .ok view =>
                    let (closed, after) := split.handle (.removeWindow view)
                    split.frame.windows != state.frame.windows && (replied closed).isRight &&
                      after.frame == state.frame &&
                      after.windows == state.windows &&
                      after.buffers == state.buffers },
    { name :=
        "the request to remove the only window is refused with onlyWindow, and the frame and the state are as they were"
      run :=
        pure <|
          match onTextModel (EditorState.initial ⟨640, 480⟩) with
          | none => false
          | some state =>
            let (closed, after) := state.handle (.removeWindow ⟨0⟩)
            replied closed == .inl .onlyWindow && after.frame == state.frame && after == state },
    { name :=
        "the focus request focuses a window in the list, and refuses one that is not with noSuchWindow"
      run :=
        pure <|
          match onTextModel threeWindows with
          | none => false
          | some state =>
            let (focused, after) := state.handle (.focus ⟨2⟩)
            let (absent, same) := state.handle (.focus ⟨9⟩)
            replied focused == .inr () && after.frame.focused == ⟨2⟩ &&
              after == (state.focusWindow ⟨2⟩).2 &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state },
    { name :=
        "showing another buffer in a window sets its buffer and its markers and leaves the other windows; a buffer there is none of is refused with noSuchBuffer, a view with no window with noSuchWindow, and a marker of another text with markersOfAnotherText, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (shown, after) := state.handle (.show ⟨0⟩ ⟨1⟩ (marker 1 8) (marker 1 9))
            let (absent, same) := state.handle (.show ⟨0⟩ ⟨9⟩ (marker 1 8) (marker 1 9))
            let (unseen, still) := state.handle (.show ⟨9⟩ ⟨1⟩ (marker 1 8) (marker 1 9))
            let (astray, yet) := state.handle (.show ⟨0⟩ ⟨1⟩ (marker 0 8) (marker 1 9))
            replied shown == .inr () && after.wellFormed &&
              after.window? ⟨0⟩ ==
                some { id := ⟨0⟩, buffer := ⟨1⟩, scroll := marker 1 8, selection := marker 1 9 } &&
              after.window? ⟨1⟩ == state.window? ⟨1⟩ &&
              after.frame == state.frame &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              same == state &&
              replied unseen == .inl (.noSuchWindow ⟨9⟩) &&
              still == state &&
              replied astray == .inl .markersOfAnotherText &&
              yet == state },
    { name :=
        "the wanted-column request is the state's operation: the window keeps the column and the head, none clears it, and a view with no window is refused with noSuchWindow, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let kept : Window.Wanted := { column := .goal 3, head := 7 }
            let (set, after) := state.handle (.setWanted ⟨1⟩ (some kept))
            let (cleared, bare) := after.handle (.setWanted ⟨1⟩ none)
            let (absent, same) := state.handle (.setWanted ⟨9⟩ (some kept))
            replied set == .inr () && after == (state.setWanted ⟨1⟩ (some kept)).2 &&
              (after.window? ⟨1⟩).map (·.wanted) == some (some kept) &&
              after.window? ⟨0⟩ == state.window? ⟨0⟩ &&
              replied cleared == .inr () &&
              bare == state &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state },
    { name := "a message sets the echo area's text, and the last of two is the one kept"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let ((), one) := state.handle (.message "first")
            let ((), two) := one.handle (.message "second")
            one == { state with echo := "first" } && two == { state with echo := "second" } },
    { name :=
        "a request to start a job is appended to the state's starts, with its name and its arguments, in order"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (first, one) := state.handle (.startJob "count" [.nat 3])
            let (_, two) := one.handle (.startJob "load" [.str "a", .bool true])
            replied first == .inr () && state.starts == #[] &&
              two.starts ==
                #[{ name := "count", arguments := [.nat 3] },
                  { name := "load", arguments := [.str "a", .bool true] }] &&
              { two with starts := #[] } == state },
    { name :=
        "a request to start a job with a key keeps the key with the start, and a request to cancel a key is appended to the state's cancels, in order, and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (started, one) := state.handle (.startJob "count" [.nat 3] (some "k"))
            let ((), two) := one.handle (.cancelJob "k")
            let ((), three) := two.handle (.cancelJob "j")
            replied started == .inr () && state.cancels == #[] &&
              one.starts == #[{ name := "count", arguments := [.nat 3], key := some "k" }] &&
              three.cancels == #["k", "j"] &&
              { three with cancels := #[] } == one },
    { name :=
        "attaching a file to a buffer sets its path, its stamp and its line ending, with no save in flight, and leaves the rest of the buffer and the other buffers; the buffer is then found by that path and by no other"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (attached, after) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            replied attached == .inr () &&
              (after.buffer? ⟨1⟩) ==
                (state.buffer? ⟨1⟩).map
                  ({ · with
                    file := some { path := notePath, stamp := noteStamp }, lineEnding := .crlf }) &&
              ((after.buffer? ⟨1⟩).bind (·.file)).map (·.saving) == some none &&
              after.buffer? ⟨0⟩ == state.buffer? ⟨0⟩ &&
              after.findFile notePath == some ⟨1⟩ &&
              after.findFile "/files/other.txt" == none &&
              after.findFile "/files/../files/note.txt" == none &&
              state.findFile notePath == none &&
              { after with buffers := state.buffers } == state },
    { name :=
        "attaching a file is refused with noSuchBuffer for a buffer there is none of, and with fileOpen and the buffer that holds the path when another buffer does, each with the state as it was; attaching the path a buffer holds to that buffer again replaces its stamp and its line ending"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let later : File.Stamp :=
              { noteStamp with
                seconds := 9, size := 12 }
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (absent, same) := state.handle (.attachFile ⟨9⟩ notePath noteStamp .lf)
            let (taken, still) := held.handle (.attachFile ⟨0⟩ notePath later .lf)
            let (unseen, yet) := held.handle (.attachFile ⟨9⟩ notePath later .lf)
            let (again, replaced) := held.handle (.attachFile ⟨1⟩ notePath later .lf)
            replied absent == .inl (.noSuchBuffer ⟨9⟩) && same == state &&
              replied taken == .inl (.fileOpen ⟨1⟩) &&
              still == held &&
              replied unseen == .inl (.noSuchBuffer ⟨9⟩) &&
              yet == held &&
              replied again == .inr () &&
              ((replaced.buffer? ⟨1⟩).map fun buffer => (buffer.file, buffer.lineEnding)) ==
                some (some { path := notePath, stamp := later }, .lf) &&
              replaced.findFile notePath == some ⟨1⟩ },
    { name :=
        "beginning a save of a buffer with a file records the snapshot and the state as the save in flight and leaves the rest; it is refused with noFile for a buffer with no file, with beingSaved while a save is in flight and with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (begun, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ ⟨3⟩)
            let (bare, same) := held.handle (.beginSave ⟨0⟩ ⟨5⟩ ⟨3⟩)
            let (twice, still) := saving.handle (.beginSave ⟨1⟩ ⟨6⟩ ⟨4⟩)
            let (absent, yet) := held.handle (.beginSave ⟨9⟩ ⟨5⟩ ⟨3⟩)
            replied begun == .inr () &&
              (saving.buffer? ⟨1⟩) ==
                (held.buffer? ⟨1⟩).map
                  ({ · with
                    file :=
                      some
                        { path := notePath, stamp := noteStamp
                          saving := some { snapshot := ⟨5⟩, state := ⟨3⟩ } } }) &&
              { saving with buffers := held.buffers } == held &&
              replied bare == .inl .noFile &&
              same == held &&
              replied twice == .inl .beingSaved &&
              still == saving &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              yet == held },
    { name :=
        "ending a save with a stamp clears the save in flight, records the stamp, and marks the state the save kept as saved: a buffer still in that state is no longer modified, and one whose text has moved on since still is; ending it with no stamp clears the save in flight and changes neither the stamp nor the saved state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let later : File.Stamp :=
              { noteStamp with
                seconds := 9, size := 12 }
            let edited := (UndoTree.new ⟨1⟩ 0).record 3
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, held) := held.handle (.setHistory ⟨1⟩ edited)
            let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ edited.state)
            let (ended, saved) := saving.handle (.endSave ⟨1⟩ ⟨5⟩ (some later))
            let (_, moved) := saving.handle (.setHistory ⟨1⟩ (edited.record 4))
            let (_, late) := moved.handle (.endSave ⟨1⟩ ⟨5⟩ (some later))
            let (refused, unsaved) := saving.handle (.endSave ⟨1⟩ ⟨5⟩ none)
            let seen (state : EditorState) :=
              (state.buffer? ⟨1⟩).map fun buffer =>
                (buffer.file, buffer.isModified, buffer.history.saved)
            seen held == some (some { path := notePath, stamp := noteStamp }, true, some ⟨0⟩) &&
              replied ended == .inr () &&
              seen saved == some (some { path := notePath, stamp := later }, false, some ⟨3⟩) &&
              (saved.buffer? ⟨1⟩).map (·.history) == some (edited.markSaved edited.state) &&
              { saved with buffers := held.buffers } == held &&
              seen late == some (some { path := notePath, stamp := later }, true, some ⟨3⟩) &&
              replied refused == .inr () &&
              unsaved == held },
    { name :=
        "ending a save with no stamp withdraws a quit that was asked: the state is no longer asked to quit, whether or not the buffer is modified, and is otherwise as it was before the save began; ending it with a stamp leaves the state asked"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let asked (state : EditorState) : EditorState := { state with quitting := true }
            let edited := (UndoTree.new ⟨1⟩ 0).record 3
            let (_, clean) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, held) := clean.handle (.setHistory ⟨1⟩ edited)
            let ends (held : EditorState) (stamp : Option File.Stamp) : EditorState :=
              let history := ((held.buffer? ⟨1⟩).map (·.history.state)).getD ⟨0⟩
              let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ history)
              ((asked saving).handle (.endSave ⟨1⟩ ⟨5⟩ stamp)).2
            (clean.buffer? ⟨1⟩).map (·.isModified) == some false &&
              (held.buffer? ⟨1⟩).map (·.isModified) == some true &&
              ends clean none == clean &&
              ends held none == held &&
              (ends clean (some noteStamp)).quitting &&
              (ends held (some noteStamp)).quitting },
    { name :=
        "ending a save is refused with notBeingSaved for a snapshot that is not the one of the save in flight, for a buffer with no save in flight and for one with no file, and with noSuchBuffer, each with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, held) := state.handle (.attachFile ⟨1⟩ notePath noteStamp .crlf)
            let (_, saving) := held.handle (.beginSave ⟨1⟩ ⟨5⟩ ⟨3⟩)
            let (other, same) := saving.handle (.endSave ⟨1⟩ ⟨6⟩ (some noteStamp))
            let (idle, still) := held.handle (.endSave ⟨1⟩ ⟨5⟩ (some noteStamp))
            let (bare, yet) := saving.handle (.endSave ⟨0⟩ ⟨5⟩ none)
            let (absent, last) := saving.handle (.endSave ⟨9⟩ ⟨5⟩ none)
            replied other == .inl .notBeingSaved && same == saving &&
              replied idle == .inl .notBeingSaved &&
              still == held &&
              replied bare == .inl .notBeingSaved &&
              yet == saving &&
              replied absent == .inl (.noSuchBuffer ⟨9⟩) &&
              last == saving },
    { name :=
        "the request to open a prompt is the state's operation: it replies the minibuffer's view and leaves the prompt open, and a second is refused with alreadyOpen, a value, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let request : StateRequest :=
              .openPrompt "Name: " asked ⟨7⟩ (UndoTree.new ⟨7⟩ 0) (marker 7 0) (marker 7 1)
            let (made, asking) := state.handle request
            let (again, same) := asking.handle request
            replied made == .inr ⟨2⟩ && asking == (prompted state).2 && asking.prompt.isSome &&
              replied again == .inl (.alreadyOpen ⟨2⟩) &&
              same == asking },
    { name :=
        "the request to close a prompt is the state's operation, with an answer and with none, and with no prompt open it is refused with notOpen, a value"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let (cancelled, without) := asking.handle (.closePrompt none)
            let (accepted, answered) := asking.handle (.closePrompt (some "a"))
            let (refused, same) := state.handle (.closePrompt (some "a"))
            replied cancelled == .inr () && without == (asking.closePrompt none).2 &&
              without.prompt == none &&
              replied accepted == .inr () &&
              answered == (asking.closePrompt (some "a")).2 &&
              answered.answered.size == 1 &&
              replied refused == .inl .notOpen &&
              same == state },
    { name :=
        "the requests to set an open prompt's candidates and to choose among its listing are the state's operations, and with no prompt open each is refused with notOpen, a value, with the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asking) := prompted state
            let listed := picking asking
            let (set, replaced) := listed.handle (.setCandidates #["x"])
            let (next, first) := listed.handle (.chooseCandidate .next)
            let (previous, last) := listed.handle (.chooseCandidate .previous)
            let (noSet, sameSet) := state.handle (.setCandidates #["x"])
            let (noChoice, sameChoice) := state.handle (.chooseCandidate .next)
            replied set == .inr () && replaced == (listed.setCandidates #["x"]).2 &&
              replaced.prompt.map (·.candidates) == some { all := #["x"] } &&
              replied next == .inr () &&
              first == (listed.chooseCandidate .next).2 &&
              first.prompt.map (·.candidates.chosen) == some (some 0) &&
              replied previous == .inr () &&
              last == (listed.chooseCandidate .previous).2 &&
              last.prompt.map (·.candidates.chosen) == some (some 2) &&
              replied noSet == .inl .notOpen &&
              sameSet == state &&
              replied noChoice == .inl .notOpen &&
              sameChoice == state },
    { name :=
        "the handler knows no registry: asked which command an ex name is bound to, it answers none for any name, and leaves the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            ["w", "greet", ""].all fun name =>
              let (bound, after) := state.handle (.ex name)
              bound == none && after == state },
    { name :=
        "the handler knows no registry: asked which ex names are bound, it answers none, and leaves the state as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (names, after) := state.handle .exNames
            names == #[] && after == state },
    { name :=
        "the handler knows no registry: asked which themes are registered, it answers none and leaves the state as it was; asked to load a theme, it takes any name and keeps the latest until the loop takes it out"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (names, after) := state.handle .themeNames
            let (first, loaded) := state.handle (.loadTheme "first")
            let (second, again) := loaded.handle (.loadTheme "second")
            names == #[] && after == state && replied first == .inr () &&
              replied second == .inr () &&
              loaded == { state with theme := some "first" } &&
              again == { state with theme := some "second" } },
    { name :=
        "the request to have an invocation run next records it after what is recorded, the answer of a prompt that was closed among it, and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let first : Invocation := { command := "one", arguments := [.str "a"] }
            let second : Invocation := { command := "two" }
            let (_, once) := state.handle (.invoke first)
            let (_, twice) := once.handle (.invoke second)
            let (_, asking) := prompted state
            let (_, answered) := asking.handle (.closePrompt (some "typed"))
            let (_, after) := answered.handle (.invoke second)
            once.answered == #[first] && twice.answered == #[first, second] &&
              { twice with answered := #[] } == state &&
              after.answered == answered.answered.push second &&
              answered.answered.size == 1 },
    { name :=
        "the request to quit sets the state's flag that the editor was asked to quit and changes nothing else; asked again, the state is as it was"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asked) := state.handle .quit
            let (_, again) := asked.handle .quit
            !state.quitting && asked.quitting && { asked with quitting := false } == state &&
              again == asked },
    { name :=
        "the request to reload the config sets the state's flag that a reload was asked for and changes nothing else"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, asked) := state.handle .reload
            !state.reload && asked.reload && { asked with reload := false } == state },
    { name :=
        "the request by which a command gives up changes nothing of the state: the handler knows no command to end, and the state after it is the state before"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, after) := state.handle (.giveUp "no such thing")
            after == state },
    { name :=
        "the request by which a command breaks off changes nothing of the state either: the handler knows no command to end"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let (_, after) := state.handle (.breakOff "far enough")
            after == state },
    { name :=
        "the request to set a register sets the register of that name, in place of the one the name had, and changes nothing else of the state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let word : Register := { text := "word" }
            let line : Register := { text := "a line\n", linewise := true }
            let (_, set) := state.handle (.setRegister "a" word)
            let (_, replaced) := set.handle (.setRegister "a" line)
            state.register? "a" == none && set.register? "a" == some word &&
              set == state.setRegister "a" word &&
              replaced.register? "a" == some line &&
              { replaced with registers := #[] } == state },
    { name :=
        "the request to set the scroll margin sets the state's margin, in place of the one it had, and changes nothing else of the state: with no prompt open and with one open, and in the state with nothing in it"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            [state, (prompted state).2, EditorState.none].all fun start =>
              let (_, set) := start.handle (.setScrollMargin 2)
              let (_, replaced) := set.handle (.setScrollMargin 7)
              start.scrollMargin == 0 && set == start.setScrollMargin 2 && set.scrollMargin == 2 &&
                replaced.scrollMargin == 7 &&
                { replaced with scrollMargin := 0 } == start },
    { name :=
        "every kind of request, accepted and refused, leaves a well-formed state well formed, with no prompt open and with one open, with no float and with a transient float at a position and a pinned one, and the state with nothing in it answers each without a buffer or a window"
      run := do
        let some (state, _) := onTextModel hiddenBuffer | return false
        let some floated :=
          onTextModel do
            withFloats (← hiddenBuffer).1 [(.position ⟨1⟩ (marker 1 2), false), (.frame, true)]
          | return false
        let (_, asking) := prompted state
        let (_, floatAsking) := prompted floated
        let spoiled :=
          [state, asking, floated, floatAsking].flatMap fun start =>
            stateRequests.filter fun request => !(start.handle request).2.wellFormed
        unless spoiled.isEmpty do
          throw
              (IO.userError
                s!"{spoiled.length} of the requests left a state that is not well formed")
        let (read, _) := EditorState.none.handle .read
        return state.wellFormed && asking.wellFormed && asking.prompt.isSome &&
            floated.wellFormed &&
            floated.frame.floats.size == 2 &&
            read.buffers.isEmpty &&
            read.windows.isEmpty &&
            stateRequests.all fun request =>
              let (_, after) := EditorState.none.handle request
              after.windows.isEmpty && after.frame == EditorState.none.frame },
    { name :=
        "the arrange request reaches the state's arrange, and a refused one leaves the state; the split request's placement reaches the split"
      run :=
        pure <|
          match onTextModel threeWindows, onTextModel (windowsUnder 1 Layout.manual) with
          | some state, some manual =>
            let (promoted, after) := state.handle (.arrange ⟨2⟩ .promote)
            let (absent, same) := state.handle (.arrange ⟨9⟩ .zoom)
            let (made, split) :=
              manual.handle
                (.split ⟨0⟩ (marker 0 8) (marker 0 9) { axis := .columns, before := true })
            replied promoted == .inr () && after == (state.arrange ⟨2⟩ .promote).2 &&
              after.frame.windows == #[⟨2⟩, ⟨0⟩, ⟨1⟩] &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state &&
              replied made == .inr ⟨1⟩ &&
              split.frame.windows == #[⟨1⟩, ⟨0⟩] &&
              split.frame.layout == .splits (.split .columns 1 1 .tile .tile)
          | _, _ => false },
    { name :=
        "the openWindow request reaches the state's openWindow with its spot, and a refused one leaves the state"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let (stacked, after) := state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .stack)
            let (docked, edged) :=
              state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.edge .left))
            let (absent, same) :=
              state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.edge .top))
            replied stacked == .inr ⟨3⟩ &&
              after == (state.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) .stack).2 &&
              after.frame.windows == #[⟨0⟩, ⟨1⟩, ⟨3⟩] &&
              replied docked == .inr ⟨3⟩ &&
              edged.frame.docked == #[(⟨2⟩, .left), (⟨3⟩, .left)] &&
              replied absent == .inl (.noSuchEdge .top) &&
              same == state },
    { name :=
        "the openWindow request with a float spot reaches the state's openWindow, and the arrange request's float reaches its arrange; a refused one leaves the state"
      run :=
        pure <|
          match onTextModel twoBuffers with
          | none => false
          | some state =>
            let spot : WindowSpot := .float (.window ⟨1⟩) { width := 50 } true
            let (opened, after) := state.handle (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) spot)
            let (floated, moved) := state.handle (.arrange ⟨1⟩ .float)
            let (absent, same) :=
              state.handle
                (.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) (.float (.window ⟨9⟩) {} false))
            let (last, kept) := (moved.handle (.arrange ⟨0⟩ .float))
            replied opened == .inr ⟨2⟩ &&
              after == (state.openWindow ⟨0⟩ (marker 0 8) (marker 0 9) spot).2 &&
              after.frame.floats.map (·.view) == #[⟨2⟩] &&
              replied floated == .inr () &&
              moved == (state.arrange ⟨1⟩ .float).2 &&
              moved.frame.floats.map (·.view) == #[⟨1⟩] &&
              replied absent == .inl (.noSuchWindow ⟨9⟩) &&
              same == state &&
              replied last == .inl .lastTile &&
              kept == moved },
    { name :=
        "with no loop to answer, the display rules are none, and asking for them leaves the state as it was"
      run :=
        pure <|
          match onTextModel sidebar with
          | none => false
          | some state =>
            let (rules, after) := state.handle .displayRules
            rules == #[] && after == state }]

/-- The loop the model tests run: one over the test scheme. -/
abbrev TestLoop :=
  Loop TestScheme.scheme

/-- One step of `loop` with no keymap: the loop after `event` and what the
step said to do next, for the checks that look at nothing else of a step. -/
def stepped (loop : TestLoop) (event : Event) : EditorM (TestLoop × Loop.Next) := do
  let after ← loop.step {} event
  return (after.loop, after.next)

/-- Starts a loop from the state `start` makes, feeds it `events` in order,
and returns the loop and what each step said to do next. -/
def stepsFrom (start : TextM EditorState) (events : List Event) :
    EditorM (TestLoop × Array Loop.Next) := do
  let mut loop : TestLoop := { state := ← start }
  let mut nexts := #[]
  for event in events do
    let (next, said) ← stepped loop event
    loop := next
    nexts := nexts.push said
  return (loop, nexts)

/-- The shipped mode line (`ModeLine.standard`) of a view of a buffer called
`name`, with no file and no major mode, modified when `modified` says, of
which the scheme reports `reported`, its cursor at `cursor` in a text of
`lines` rows, selected when `selected` says: what the loop draws of a view
of the scratch buffer. -/
def modeLineOf (name : String := "scratch") (modified : Bool := false)
    (cursor : Option Point := some ⟨0, 0⟩) (lines : Nat := 1) (reported : Array StatusField := #[])
    (selected : Bool := true) : Array StatusField :=
  let history := UndoTree.new ⟨0⟩ 0
  ModeLine.standard.fields
    { buffer := { name, text := ⟨0⟩, history := if modified then history.record 1 else history }
      reported, cursor, lines, selected }

/-- The left side of a status line: the fields of the buffer's name and its
modified mark, and a badge. -/
def leftOf (status : Array StatusField) : Array StatusField :=
  status.filter (·.side == .left)

/-- What a run of the loop on the editor's models came to: the loop and what
each step said, the scenes the display recorded, and the models. `none` when
it was refused. -/
def looped (start : TextM EditorState) (events : List Event) :
    Option ((TestLoop × Array Loop.Next) × Array Scene × EditorModel) :=
  match (stepsFrom start events).runModel editorModel with
  | (.ok result, model) => some (result, model.display.scenes, model)
  | (.error _, _) => none

/-- The initial state at 640 by 480 with a prompt open, asked from view 0 with
the label `Name: ` and the continuation `asked`: the minibuffer is view 1,
over a text of its own holding `text`, with a scroll anchor at its start
and one cursor after `text`. -/
def promptedOver (text : String) : TextM EditorState := do
  let state ← EditorState.initial ⟨640, 480⟩
  let made ← createText text
  let scroll ← made.mark (.anchor { offset := 0, bias := .before })
  let selection ← made.mark (.selection { ranges := #[⟨text.utf8ByteSize, text.utf8ByteSize⟩] })
  return (state.openPrompt "Name: " asked made (← UndoTree.over made) scroll selection).2

/-- A press of a key that no keymap binds and that prints nothing, with its
physical code as a window reports it: the loop steps it through its scheme,
which yields nothing for it. -/
def pressF5 : Event :=
  .key { logical := .named ⟨"F5"⟩, physical := .code "F5" } true ""

/-- The text of the snapshot a view shows, as the text model holds it. -/
def shownText (model : EditorModel) (view : View) : Option String :=
  (model.texts.snapshots[view.snapshot.index]?).join.map (·.contents)

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

end ModelTest
