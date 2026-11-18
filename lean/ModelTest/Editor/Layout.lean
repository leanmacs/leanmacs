import Editor.Layout
import Editor.Scene
import ModelTest.Check
import ModelTest.Support.Geometry

/-!
# Model tests: `Editor/Layout.lean`

The model tests of `Editor/Layout.lean`: `layoutChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

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

end ModelTest
