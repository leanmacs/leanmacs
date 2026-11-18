import Editor.Display
import Editor.Display.Real
import Editor.Event
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Marker
import Editor.Ffi.Snapshot
import Editor.Ffi.Transaction
import Editor.Ffi.Window
import Editor.Menu
import Editor.Scene
import Editor.Text
import Editor.Text.Real

/-!
# FFI tests: support: Scenes

Scenes published to a display: a marker in a document, a range marker, and the
scene fixture with its menu. Shared by several test modules; it holds no checks
of its own.
-/

namespace FfiTest

/-- Marks `document` with `marker`, and returns its number. -/
def markIn (document : Editor.Ffi.Document) (marker : Editor.Ffi.Marker) : IO Nat := do
  match ← document.mark marker with
  | .ok number =>
    return number.toNat
  | .error refusal =>
    throw (IO.userError s!"the fixture's marker was refused: {repr refusal}")

/-- A selection marker of the one range from `anchor` to `head`. -/
def rangeMarker (anchor head : UInt64) : Editor.Ffi.Marker :=
  .selection { ranges := #[{ anchor, head }] }

/-- What `sceneChecks` publish from: one text, "ab\ncd\nef", its markers, and
the binding over a table that holds its snapshot alone, with a theme to
send. -/
structure SceneFixture where
  /-- The binding, over a display in cells 8 pixels across and 16 down. -/
  real : Editor.RealDisplay
  /-- The text's snapshot, the only one in the binding's table. -/
  snapshot : Editor.SnapshotId
  /-- The number of the text's anchor marker at offset 3, where its second
  row starts. -/
  anchor : Nat
  /-- The number of its selection marker of the range 4..5. -/
  selection : Nat
  /-- The number of its anchor marker at offset 0. -/
  top : Nat
  /-- The text's document. The library reads the markers in it, and a
  snapshot holds it weakly, so whoever publishes keeps it alive. -/
  document : Editor.Ffi.Document

/-- Makes a `SceneFixture` whose binding has `theme` to send: no definition,
unless a check gives one. -/
def sceneFixture (theme : Editor.Theme := #[]) : IO SceneFixture := do
  let document ← Editor.Ffi.Document.new "ab\ncd\nef"
  let anchor ← markIn document (.anchor { offset := 3, bias := .before })
  let selection ← markIn document (rangeMarker 4 5)
  let top ← markIn document (.anchor { offset := 0, bias := .before })
  let table ← Editor.Snapshots.new
  let snapshot ← table.add (← document.snapshot)
  let display ← Editor.Ffi.Display.newCells 8 16
  return {
      real := ← Editor.RealDisplay.over display table.reader theme, snapshot, anchor, selection, top
      document }

/-- The marker numbered `index` of the fixture's text, which is text 0. -/
def SceneFixture.own (index : Nat) : Editor.MarkerId :=
  { text := ⟨0⟩, index }

/-- A menu bar with each kind of item, each role and a key with every
modifier: the menu `crates/editor-ffi/src/display/wire.rs`'s own round trip
crosses. -/
def fixtureMenu : Editor.Menu :=
  {
    menus :=
      #[{ title := "Ap", role := some .app
          items :=
            #[.item "Q" (some { character := 'q', modifiers := { superKey := true } })
                (.system .quit),
              .item "S" none (.system .services), .separator] },
        { title := "é", role := some .window
          items :=
            #[.item "U"
                (some
                  { character := 'Z'
                    modifiers :=
                      { shift := true, control := true, alt := true, superKey := true } })
                (.command "undo")] },
        { title := "" }] }

/-- A scene that takes the branches of the binding's encoding the display
fixture does not: a pending prefix, a preedit, an echo padding and a menu
bar; view 1, of a snapshot the table does not hold and padded, before view
2, of the one it holds, scrolled to its second row with a selection, a
right status field with a padding and a status face; and view 3, of the
same snapshot, whose scroll marker is `scroll` and whose selection markers
are `selections`. Each view is 4 columns by 3 rows. Between views 1 and 2
is one divider, in a face of its own. -/
def SceneFixture.scene (fixture : SceneFixture) (scroll : Editor.MarkerId)
    (selections : Array Editor.MarkerId) : Editor.Scene :=
  let rect (y : Nat) : Editor.Rect := { x := 0, y, width := 32, height := 48 }
  { size := { width := 32, height := 144 }
    views :=
      #[{ id := ⟨1⟩, rect := rect 0, snapshot := ⟨fixture.snapshot.index + 1⟩
          scroll := SceneFixture.own fixture.anchor, selections := #[]
          cursor := { shape := .block, face := ⟨"c1"⟩ }, decorations := #[], status := #[]
          padding := { across := 8, down := 4, top := 28 } },
        { id := ⟨2⟩, rect := rect 48, snapshot := fixture.snapshot
          scroll := SceneFixture.own fixture.anchor
          selections := #[SceneFixture.own fixture.selection]
          cursor := { shape := .bar, face := ⟨"c2"⟩ }
          decorations := #[{ start := 0, stop := 2, face := ⟨"kw"⟩ }]
          status :=
            #[{ text := "NORMAL", face := ⟨"mode"⟩ },
              { text := "1:1", face := ⟨"pos"⟩, side := .right, padding := 4 }]
          statusFace := some ⟨"dim"⟩ },
        { id := ⟨3⟩, rect := rect 96, snapshot := fixture.snapshot, scroll, selections
          cursor := { shape := .underline, face := ⟨"c3"⟩ }, decorations := #[], status := #[] }]
    dividers := #[{ rect := { x := 0, y := 46, width := 32, height := 2 }, face := ⟨"rule"⟩ }]
    focused := some ⟨2⟩, echo := "fixture", echoPadding := 14, pending := "g"
    preedit := some "é", title := "notes.txt", menu := some fixtureMenu }

/-- The fixture's scene with view 3's markers of two texts: its scroll
marker is the text's anchor at offset 3, and its selection marker is a
marker of text 1 with the number of the text's own selection marker, which
is what the library would read if the number were sent. -/
def SceneFixture.mixed (fixture : SceneFixture) : Editor.Scene :=
  fixture.scene (SceneFixture.own fixture.anchor) #[{ text := ⟨1⟩, index := fixture.selection }]

/-- The rows of the fixture's text the rows query answers for one of its
views, from `anchor`, as pairs; `none` when it is refused. -/
def SceneFixture.asked (fixture : SceneFixture) (anchor : Nat) : IO (Option (Array (Nat × Nat))) :=
  do
  let answer ← fixture.real.rows { snapshot := fixture.snapshot, width := 32, height := 48, anchor }
  return answer.toOption.map (·.map fun row => (row.start, row.stop))

/-- The rows the view numbered `view` shows in the frame the fixture's
display holds, as pairs; `none` when the frame has no such view. -/
def SceneFixture.shown (fixture : SceneFixture) (view : UInt64) : IO (Option (Array (Nat × Nat))) :=
  do
  return (← fixture.real.display.frameRows view).map
      (·.map fun row => (row.start.toNat, row.stop.toNat))

end FfiTest
