import Editor.Command
import Editor.Command.Model
import Editor.Display
import Editor.Display.Model
import Editor.Event
import Editor.ExcerptView
import Editor.InputScheme.Vim.Default
import Editor.Loop
import Editor.Loop.Driver
import Editor.Program
import Editor.Scene
import Editor.Scroll
import Editor.State
import Editor.Text
import ModelTest.Check
import ModelTest.Support.Evil
import ModelTest.Support.Excerpt
import ModelTest.Support.Views

/-!
# Model tests: `Editor/ExcerptView.lean`

The model tests of `Editor/ExcerptView.lean`: `excerptDisplayChecks`. The root
module `ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor

/-- The header blocks `ex` of `excerptRegistrations` has, its headers `one`
and `two` before its excerpts' starts `first` and `second`. -/
def exHeaders (first second : Nat) : Array Block :=
  #[{ before := first, text := "one", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] },
    { before := second, text := "two", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] }]

/-- The view `view` of the last scene `driver` published. -/
def lastView (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option View := do
  (← driver.model.display.scenes.back?).views.find? (·.id == view)

/-- Of the window's view in the last scene of `driver`: its scroll anchor's
offset, the head of its selection's primary range, and whether the rows the
display model answers from its anchor, asked with its blocks, hold the
row of that head, also asked with them. -/
def blockedSeen (driver : EvilDriver) : Option (Nat × Nat × Bool) := do
  let shown ← lastView driver
  let #[marker] := shown.selections | none
  let program : EditorM (Nat × Nat × Bool) := do
    let .anchor anchor ← shown.scroll.text.marker shown.scroll | throw .noSuchMarker
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let some range := selection.ranges[selection.primary]? | throw .badSelection
    let area :=
      Scroll.Area.ofRect shown.snapshot shown.rect driver.model.display.cells.heights.status
        shown.padding shown.blocks
    let rows ← area.rows anchor.offset
    let own := (← area.rows range.head)[0]?
    return (anchor.offset, range.head, own.any rows.contains)
  (program.runModel driver.model).1.toOption

/-- The rectangle's top of the first view of the last scene of `driver`
that is not the window's: the float `float-five` opened. -/
def floatTop (driver : EvilDriver) : Option Nat := do
  let scene ← driver.model.display.scenes.back?
  return (← scene.views.find? (·.id != ⟨0⟩)).rect.y

/-- The checks of what a view of an excerpt buffer shows
(`Editor/ExcerptView.lean`; `Editor/Loop.lean`, "Decorations"; the follow
and the scroll commands over blocks, `Editor/Scroll.lean`, "Blocks"), on
the loop's driver over the editor's models, with evil's keys, and of the
pure functions that place what is drawn. -/
def excerptDisplayChecks : List Check :=
  [{  name :=
        "the headers of an excerpt list are a block in block-header before each excerpt's start, none for an empty header, zipped to the shorter of the list and the entries"
      run :=
        pure <|
          let placed : Array Excerpt.Placed := #[⟨0, 4, 4, 8⟩, ⟨5, 11, 0, 6⟩, ⟨12, 12, 3, 3⟩]
          let entries : Array Buffer.ExcerptEntry :=
            #[{ source := ⟨0⟩, header := "one" }, { source := ⟨1⟩ }]
          ExcerptView.headers placed entries ==
              #[{ before := 0, text := "one", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] }] &&
            ExcerptView.headers placed (entries.push { source := ⟨0⟩, header := "é" }) ==
              #[{ before := 0, text := "one", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] },
                { before := 12, text := "é", decorations := #[⟨0, 2, ExcerptView.headerFace⟩] }] },
    { name :=
        "a source's spans are drawn at every excerpt of it, clipped to the excerpt and moved to where it is, and an empty excerpt draws none"
      run :=
        pure <|
          let face : FaceName := ⟨"f"⟩
          let overlap : Array Excerpt.Placed := #[⟨0, 8, 0, 8⟩, ⟨9, 19, 4, 14⟩]
          ExcerptView.translated overlap (fun _ => #[⟨4, 7, face⟩]) ==
              #[⟨4, 7, face⟩, ⟨9, 12, face⟩] &&
            ExcerptView.translated overlap (fun _ => #[⟨6, 10, face⟩]) ==
              #[⟨6, 8, face⟩, ⟨11, 15, face⟩] &&
            ExcerptView.translated #[⟨0, 0, 3, 3⟩, ⟨1, 3, 0, 2⟩] (fun _ => #[⟨0, 14, face⟩]) ==
              #[⟨1, 3, face⟩] &&
            ExcerptView.translated overlap
                (fun index => if index == 0 then #[] else #[⟨4, 5, face⟩]) ==
              #[⟨9, 10, face⟩] },
    { name :=
        "the published view of an excerpt buffer has a header block above each excerpt, read from the snapshot it shows: an edit before an excerpt in a source keeps them, and one typed in the first excerpt moves the second's"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let edited := excerptInvoked driver "edit-one"
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            (lastView driver).map (·.blocks) == some (exHeaders 0 5) &&
              (lastView edited).map (·.blocks) == some (exHeaders 0 5) &&
              (lastView typed).map (·.blocks) == some (exHeaders 0 6) &&
              -- A plain buffer's view has none.
              (lastView (excerptInvoked driver "show-one")).map (·.blocks) == some #[] },
    { name :=
        "a source buffer's span is drawn at the same text in every excerpt of it, under the excerpt buffer's own span and the search's matches, in that order"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let made := excerptInvoked driver "make-overlap"
            let error : FaceName := ⟨"compilation.error"⟩
            (lastView made).map (·.decorations) ==
              some
                #[⟨4, 7, error⟩, ⟨9, 12, error⟩, ⟨0, 1, ⟨"own"⟩⟩, ⟨5, 6, Loop.searchMatchFace⟩,
                  ⟨10, 11, Loop.searchMatchFace⟩] },
    { name :=
        "in a window four rows tall over six headed excerpts, after each of G, k and j across the headers, gg, C-f, C-b, C-d, C-u, z t, z z and z b, the rows the published view shows from its anchor, asked with its blocks, hold the cursor's row"
      run :=
        pure <|
          match excerptDriver with
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
          match excerptDriver with
          | none => false
          | some driver =>
            let six := viewResized (excerptInvoked driver "make-six") ⟨20, 4⟩
            -- `one` and the separator fit with the first header; `two`, at
            -- 5, is two rows down; without the headers `three`, at 10, is
            -- four rows down.
            (blockedSeen six).map (fun (anchor, head, _) => (anchor, head)) == some (0, 0) &&
              (blockedSeen (evilFed six "C-f")).map (fun (anchor, head, _) => (anchor, head)) ==
                some (5, 5) },
    { name :=
        "a float anchored at a position of an excerpt buffer's view sits lower by the header rows above the position than one over the same text with no header"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let blocked := floatTop (excerptInvoked driver "float-five")
            let plain := floatTop (excerptInvoked (excerptInvoked driver "make-plain") "float-five")
            -- `alpha`, at 5, is below both headers: two rows of one pixel.
            match blocked, plain with
            | some blocked, some plain => blocked == plain + 2
            | _, _ => false }]

/-- A tracked entry of the source `⟨0⟩`, shown by `scenes` scenes. -/
def trackedEntry (scenes : Nat := 0) : Buffer.ExcerptEntry :=
  { source := ⟨0⟩, viewed := some { scenes } }

/-- The entries of the excerpt buffer `id` of `state`, if it is one. -/
def entriesOf (state : EditorState) (id : BufferId) : Option (Array Buffer.ExcerptEntry) :=
  (state.buffer? id).bind (·.excerpts) |>.map (·.entries)

/-- The checks of what is viewed of a tracked excerpt
(`Editor/ExcerptView.lean`, "What was not examined"; `Editor/State.lean`,
"Excerpt buffers"), on hand-built rows and entries. -/
def excerptViewedChecks : List Check :=
  let placed : Array Excerpt.Placed := #[⟨0, 4, 0, 4⟩, ⟨5, 11, 0, 6⟩, ⟨12, 12, 3, 3⟩]
  [{  name :=
        "the excerpts a view shows are those a row starts in, or an empty one a row starts at; a separator row shows none"
      run :=
        pure <|
          ExcerptView.shown placed #[⟨0, 3⟩] == #[0] && ExcerptView.shown placed #[⟨4, 4⟩] == #[] &&
            ExcerptView.shown placed #[⟨6, 10⟩] == #[1] &&
            ExcerptView.shown placed #[⟨12, 12⟩] == #[2] &&
            ExcerptView.shown placed #[⟨0, 3⟩, ⟨4, 4⟩, ⟨5, 10⟩, ⟨11, 11⟩] == #[0, 1] &&
            ExcerptView.shown placed #[] == #[] },
    { name :=
        "a span in review-unexamined covers each tracked excerpt no scene has shown, and none an untracked, a shown or an empty one"
      run :=
        pure <|
          let four : Array Excerpt.Placed :=
            #[⟨0, 4, 0, 4⟩, ⟨5, 9, 0, 4⟩, ⟨10, 14, 0, 4⟩, ⟨15, 15, 0, 0⟩]
          ExcerptView.unexamined four
                #[trackedEntry, { source := ⟨0⟩ }, trackedEntry 1, trackedEntry, trackedEntry] ==
              #[⟨0, 4, ExcerptView.unexaminedFace⟩] &&
            ExcerptView.unexaminedFace == ⟨"review-unexamined"⟩ },
    { name :=
        "markViewed counts a scene and keeps the first time, creditViewed adds the time on screen; an untracked entry and an index past the end are left alone"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let state := driver.loop.state
            let id : BufferId := ⟨state.buffers.size⟩
            let buffer : Buffer :=
              { name := "tracked", text := ⟨0⟩, history := UndoTree.new ⟨0⟩ 0
                excerpts := some { entries := #[trackedEntry, { source := ⟨0⟩ }] } }
            let state := { state with buffers := state.buffers.push (some buffer) }
            let after :=
              ((state.markViewed id #[0, 1, 5] 100).markViewed id #[0] 200).creditViewed id
                #[0, 1, 7] 50
            entriesOf after id ==
                some
                  #[{ source := ⟨0⟩,
                      viewed := some { scenes := 2, firstAt := some 100, shownFor := 50 } },
                    { source := ⟨0⟩ }] &&
              -- A buffer that is not an excerpt buffer is left alone.
              (state.markViewed ⟨0⟩ #[0] 1).buffer? ⟨0⟩ == state.buffer? ⟨0⟩ }]

end ModelTest
