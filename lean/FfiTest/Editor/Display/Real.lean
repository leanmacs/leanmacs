import Editor.Display
import Editor.Display.Real
import Editor.Face
import Editor.Ffi.Display
import Editor.Ffi.Document
import Editor.Ffi.Marker
import Editor.Ffi.Snapshot
import Editor.Ffi.Window
import Editor.Menu
import Editor.Scene
import Editor.Text
import Editor.Text.Real
import FfiTest.Check
import FfiTest.Support.Scenes

/-!
# FFI tests: `Editor/Display/Real.lean`

The tests of `Editor/Display/Real.lean`: `sceneChecks` and `displayChecks'`, of
`RealDisplay.encode`, and the `display` scenario (`displayScenario`). The root
module `FfiTest` runs them, and each list's own doc says what it checks.
-/

namespace FfiTest

/-- The theme of the display fixture, which
`crates/editor-layout/tests/frame_fixture.rs` states the same way (its
`theme`): `default`, `keyword` with a weight, `emphasis` with a slant,
`number` with an underline, `selection`, `mode-line`, `position` and
`cursor.normal`, and not `cursor.insert`, which view 2's cursors name. -/
def fixtureTheme : Editor.Theme :=
  #[{ name := ⟨"default"⟩
      face :=
        { foreground := some (.rgb 0x20 0x20 0x20), background := some (.rgb 0xf8 0xf8 0xf8) } },
    { name := ⟨"keyword"⟩, face := { foreground := some (.rgb 0 0 0xc0), weight := some 700 } },
    { name := ⟨"emphasis"⟩
      face := { foreground := some (.rgb 0 0x80 0), slant := some .italic } },
    { name := ⟨"number"⟩
      face := { foreground := some (.rgb 0xc0 0 0), underline := some { style := .single } } },
    { name := ⟨"selection"⟩, face := { background := some (.rgb 0xc0 0xd8 0xff) } },
    { name := ⟨"mode-line"⟩
      face :=
        { foreground := some (.rgb 0xff 0xff 0xff), background := some (.rgb 0x40 0x40 0x40) } },
    { name := ⟨"position"⟩, face := { foreground := some (.rgb 0xff 0xff 0) } },
    { name := ⟨"cursor.normal"⟩
      face :=
        { foreground := some (.rgb 0xf8 0xf8 0xf8), background := some (.rgb 0x20 0x20 0x20) } }]

/-- The display fixture: the scene `crates/editor-layout/tests/frame_fixture.rs`
lays out, built here through the library's documents and markers and the
text binding's table of snapshots, and the binding over a display in cells
8 pixels across and 16 down, with `fixtureTheme` to send. Text A is the
text of view 1, text B of view 2, and their snapshots are 0 and 1. The
documents come back too: a snapshot holds its document weakly, and the
library reads the markers in the document, so whoever publishes keeps it
alive, as the text binding does. -/
def displayFixture : IO (Editor.RealDisplay × Editor.Scene × Array Editor.Ffi.Document) := do
  let a ← Editor.Ffi.Document.new "fn main() {\n\tlet x = 1;\n}\nabcdefghijklmnopqrstuvwxyz\n"
  let b ← Editor.Ffi.Document.new "hello\nworld wide web"
  let marker (text : Nat) (index : Nat) : Editor.MarkerId := { text := ⟨text⟩, index }
  let scrollA ← markIn a (.anchor { offset := 0, bias := .before })
  let selectedA ← markIn a (rangeMarker 3 7)
  let cursorA ← markIn a (rangeMarker 18 18)
  let scrollB ← markIn b (.anchor { offset := 6, bias := .before })
  let cursorB ← markIn b (rangeMarker 12 12)
  let table ← Editor.Snapshots.new
  let snapshotA ← table.add (← a.snapshot)
  let snapshotB ← table.add (← b.snapshot)
  let display ← Editor.Ffi.Display.newCells 8 16
  let scene : Editor.Scene :=
    { size := { width := 96, height := 112 }
      views :=
        #[{ id := ⟨1⟩, rect := { x := 0, y := 0, width := 96, height := 80 }, snapshot := snapshotA
            scroll := marker 0 scrollA, selections := #[marker 0 selectedA, marker 0 cursorA]
            cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }
            decorations :=
              #[{ start := 0, stop := 2, face := ⟨"keyword"⟩ },
                { start := 17, stop := 18, face := ⟨"number"⟩ },
                { start := 1, stop := 5, face := ⟨"emphasis"⟩ }]
            status :=
              #[{ text := "fixture.rs", face := ⟨"mode-line"⟩ },
                { text := " 1:8", face := ⟨"position"⟩ }] },
          { id := ⟨2⟩, rect := { x := 0, y := 80, width := 64, height := 32 }, snapshot := snapshotB
            scroll := marker 1 scrollB, selections := #[marker 1 cursorB]
            cursor := { shape := .bar, face := ⟨"cursor.insert"⟩ }, decorations := #[]
            status := #[] }]
      focused := some ⟨1⟩, echo := "fixture", pending := "", preedit := none }
  return (← Editor.RealDisplay.over display table.reader fixtureTheme, scene, #[a, b])

/-- A theme whose definitions use every constructor of `Slant`, of
`UnderlineStyle` and of `LineHeight`, every attribute of a face, a name of
more than one byte to a character, and a weight on each side of the range
the library takes. -/
def everyTheme : Editor.Theme :=
  #[{ name := ⟨"all"⟩
      face :=
        { family := some "mono", size := some 20, weight := some 700, slant := some .italic
          foreground := some (.rgba 0x11 0x22 0x33 0x44), background := some (.rgb 0xaa 0xbb 0xcc)
          underline := some { style := .curly, color := some (.rgb 0xff 0 0) }
          strikeThrough := some true, lineHeight := some (.pixels 24)
          verticalPadding := some 3 } },
    { name := ⟨"unset"⟩, face := {} },
    { name := ⟨"é"⟩
      face :=
        { slant := some .upright, underline := some { style := .none }, strikeThrough := some false
          lineHeight := some (.multiple 96) } },
    { name := ⟨"b"⟩, face := { slant := some .oblique, underline := some { style := .single } } },
    { name := ⟨"c"⟩, face := { weight := some 5000, underline := some { style := .double } } },
    { name := ⟨"d"⟩, face := { weight := some 0, underline := some { style := .dotted } } },
    { name := ⟨"e"⟩, face := { underline := some { style := .dashed } } }]

/-- A scene of no view, 8 pixels by 16. -/
def emptyScene : Editor.Scene :=
  { size := { width := 8, height := 16 }, views := #[], focused := none, echo := "", pending := ""
    preedit := none }

/-- The checks of the real binding's encoding of a scene
(`Editor.RealDisplay.encode`) that the display fixture does not make: a
pending prefix and a preedit, a view whose snapshot the table does not
hold, and a view whose markers are of two texts; and of a theme: its
definitions as words, when it is sent and when it is not, and the names
layout reads by itself. The words are compared with the library's layout
written out here once (`crates/editor-ffi/src/display/wire.rs`), since the
library writes back what it was sent whatever it was. What a frame holds
is layout's rule: a view's rows are compared with the rows query's answer,
and a frame with another frame, never with a colour or a size written
here. -/
def sceneChecks (_ : Unit) : List Check :=
  [{  name :=
        "a scene with a pending prefix, a preedit, a title, a menu bar with each kind of item, a view of a snapshot the table does not hold, a view whose markers are of two texts and a divider is the words and the string of the library's layout"
      run := do
        let fixture ← sceneFixture
        let encoded ← fixture.real.encode fixture.mixed none
        let anchor := fixture.anchor.toUInt64
        let selection := fixture.selection.toUInt64
        -- The echo's padding after its length, and the title's length after
        -- the preedit's presence and length.
        let scene : Array UInt64 := #[32, 144, 1, 2, 7, 14, 1, 1, 2, 9]
        -- The menu's presence and three menus: "Ap", the application's,
        -- with Quit (s-q), Services and a separator; "é", the windows
        -- menu, with the command undo on every modifier and Z; and an
        -- untitled plain menu with no item. Then the count of views.
        let menu : Array UInt64 :=
          #[1, 3, 2, 1, 3, 2, 1, 1, 0x71, 8, 5, 2, 1, 0, 0, 0, 1, 0, 2, 2, 1, 1, 1, 1, 0x5a, 15, 4,
            0, 0, 0, 3]
        -- No snapshot; its scroll marker; no selection; a block cursor; no
        -- status field and no status face; padded 8 across, 4 down and 28
        -- at the top, with no gutter; no block, no mark and no stop.
        let first : Array UInt64 :=
          #[1, 0, 0, 32, 48, 0, 0, 1, anchor, 0, 0, 2, 0, 0, 0, 0, 8, 4, 28, 0, 0, 0, 0]
        -- The first handle; its scroll marker and its selection; a bar
        -- cursor; a decoration; a left status field with no padding and a
        -- right one padded 4; a status face; and no block, no mark and no
        -- stop.
        let second : Array UInt64 :=
          #[2, 0, 48, 32, 48, 1, 0, 1, anchor, 1, selection, 1, 2, 1, 0, 2, 2, 2, 6, 4, 0, 0, 3, 3,
            1, 4, 1, 3, 0, 0, 0, 0, 0, 0, 0]
        -- The second handle; no scroll marker and no selection; an
        -- underline cursor; no block, no mark and no stop.
        let third : Array UInt64 :=
          #[3, 0, 96, 32, 48, 1, 1, 0, 0, 0, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- One divider: its rectangle and its face's length.
        let dividers : Array UInt64 := #[1, 0, 46, 32, 2, 4]
        -- No faces: as last published.
        let faces : Array UInt64 := #[0]
        return encoded.words == scene ++ menu ++ first ++ second ++ third ++ dividers ++ faces &&
            encoded.strings == "fixturegénotes.txtApQSéUundoc1c2kwNORMALmode1:1posdimc3rule" &&
            encoded.snapshots.size == 2 },
    { name :=
        "a view's blocks cross after its padding, each its offset, its text and its decorations, come back as sent, and are drawn as block rows above their rows, which the rows query, asked with them, leaves out"
      run := do
        let fixture ← sceneFixture
        let real := fixture.real
        let blocks : Array Editor.Block :=
          #[{ before := 3, text := "hé",
              decorations := #[{ start := 0, stop := 3, face := ⟨"h"⟩ }] }]
        let scene := fixture.mixed
        let scene :=
          { scene with
            views :=
              scene.views.modify 2 fun view =>
                { view with
                  scroll := SceneFixture.own fixture.top, blocks } }
        let encoded ← real.encode scene none
        real.publish scene
        let back ← real.display.scene
        let frame ← real.display.frameText
        let shown ← fixture.shown 3
        -- From the start, three rows tall: `ab`, the block and `cd`.
        let asked ←
          real.rows { snapshot := fixture.snapshot, width := 32, height := 48, anchor := 0, blocks }
        let wordsBlocks : Array UInt64 := #[1, 3, 3, 1, 0, 3, 1]
        let held ← fixture.document.read
        -- The blocks, then no mark, no stop, the divider and no faces, end
        -- the words.
        let tail := encoded.words.extract (encoded.words.size - 16) encoded.words.size
        return tail == wordsBlocks ++ #[0, 0, 1, 0, 46, 32, 2, 4, 0] &&
            encoded.strings.endsWith "héhrule" &&
            back.map (·.1) == some ((← real.encode scene (some #[])).words) &&
            (frame.splitOn "  block 0 row").length == 2 &&
            shown == some #[(0, 2), (3, 5)] &&
            asked.toOption.map (·.map fun row => (row.start, row.stop)) == some #[(0, 2), (3, 5)] &&
            held == "ab\ncd\nef" },
    { name :=
        "a view's gutter crosses with its padding and its marks after its blocks, each its range, its text and its face, come back as sent, and are drawn as mark rows beside their rows, which the frame's rows leave out and the rows query, asked with the gutter, agrees with"
      run := do
        let fixture ← sceneFixture
        let real := fixture.real
        let marks : Array Editor.GutterMark :=
          #[{ start := 0, stop := 3, text := "+", face := ⟨"diff.added"⟩ },
            { start := 6, stop := 6, text := "-", face := ⟨"diff.removed"⟩ }]
        let scene := fixture.mixed
        let scene :=
          { scene with
            views :=
              scene.views.modify 2 fun view =>
                { view with
                  scroll := SceneFixture.own fixture.top, padding := { gutter := 8 }, marks } }
        let encoded ← real.encode scene none
        real.publish scene
        let back ← real.display.scene
        let frame ← real.display.frameText
        let shown ← fixture.shown 3
        let asked ←
          real.rows
              { snapshot := fixture.snapshot, width := 32, height := 48, anchor := 0
                padding := { gutter := 8 } }
        -- The marks, then no stop, the divider and no faces, end the words.
        let tail := encoded.words.extract (encoded.words.size - 17) encoded.words.size
        let wordsMarks : Array UInt64 := #[2, 0, 3, 1, 10, 6, 6, 1, 12]
        return tail == wordsMarks ++ #[0, 1, 0, 46, 32, 2, 4, 0] &&
            encoded.strings.endsWith "+diff.added-diff.removedrule" &&
            back.map (·.1) == some ((← real.encode scene (some #[])).words) &&
            (frame.splitOn "  mark ").length == 3 &&
            shown == asked.toOption.map (·.map fun row => (row.start, row.stop)) &&
            shown.isSome },
    { name :=
        "a view's align-to stops cross after its marks, each its offset and its x in points, an x no u32 holds as the largest, come back as sent, and the library lays the view's rows out under them"
      run := do
        let fixture ← sceneFixture
        let real := fixture.real
        -- `cd` starts at 3: at a stop 24 points in, it is drawn right of
        -- where it is drawn with none.
        let stops : Array Editor.AlignStop := #[{ offset := 3, x := 24 }]
        let scene := fixture.mixed
        let stopped (stops : Array Editor.AlignStop) : Editor.Scene :=
          { scene with
            views :=
              scene.views.modify 2 fun view =>
                { view with
                  scroll := SceneFixture.own fixture.top, stops } }
        let encoded ← real.encode (stopped stops) none
        let past ← real.encode (stopped #[{ offset := 3, x := 2 ^ 40 }]) none
        real.publish (stopped #[])
        let bare ← real.display.frameText
        real.publish (stopped stops)
        let back ← real.display.scene
        let frame ← real.display.frameText
        let held ← fixture.document.read
        -- The stops, then the divider and no faces, end the words.
        let tail := encoded.words.extract (encoded.words.size - 10) encoded.words.size
        let pastTail := past.words.extract (past.words.size - 10) past.words.size
        return tail == #[1, 3, 24, 1, 0, 46, 32, 2, 4, 0] &&
            pastTail == #[1, 3, (2 ^ 32 - 1 : Nat).toUInt64, 1, 0, 46, 32, 2, 4, 0] &&
            -- The theme went with the first publish, so not with this one.
            back.map (·.1) == some encoded.words &&
            frame != bare &&
            held ==
              "ab
cd
ef" },
    { name :=
        "published, that scene comes back as sent; the view of the unknown snapshot shows nothing, the view after it shows its text from its anchor, and the view whose markers are of two texts shows its text from the start with no selection"
      run := do
        let fixture ← sceneFixture
        let real := fixture.real
        real.publish fixture.mixed
        -- The first publish sends the binding's theme, which has no
        -- definition.
        let encoded ← real.encode fixture.mixed (some #[])
        let back ← real.display.scene
        let mixed ← real.display.frameText
        let unknown ← fixture.shown 1
        let second ← fixture.shown 2
        let third ← fixture.shown 3
        let fromAnchor ← fixture.asked 3
        let fromStart ← fixture.asked 0
        -- View 3 scrolled to the start, with no selection: the same frame.
        real.publish (fixture.scene (SceneFixture.own fixture.top) #[])
        let plain ← real.display.frameText
        -- View 3 with the scroll marker and the selection marker the
        -- library would read if the numbers were sent: another frame.
        real.publish
            (fixture.scene (SceneFixture.own fixture.anchor) #[SceneFixture.own fixture.selection])
        let whole ← real.display.frameText
        -- The document is held until here, past the last publish.
        let held ← fixture.document.read
        return back == some (encoded.words, encoded.strings) && unknown == some #[] &&
            second.isSome &&
            second == fromAnchor &&
            third == fromStart &&
            second != third &&
            mixed == plain &&
            mixed != whole &&
            held == "ab\ncd\nef" },
    { name := "a display nothing was published to has no scene to write back"
      run := do
        let display ← Editor.Ffi.Display.newCells 8 16
        return (← display.scene).isNone },
    { name :=
        "a theme that uses every slant, every underline style and both kinds of line height is the words and the string of the library's layout, with a weight out of range sent as the nearest end; and the library takes it and writes it back"
      run := do
        let fixture ← sceneFixture everyTheme
        let real := fixture.real
        let encoded ← real.encode emptyScene (some everyTheme)
        -- The scene, no view and no divider.
        let scene : Array UInt64 := #[8, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- Present, and seven definitions.
        let faces : Array UInt64 := #[1, 7]
        -- Its name; a family; 20 pixels; weight 700; italic; a foreground
        -- and a background; a curly underline with a colour; struck
        -- through; a line height of 24 pixels; a vertical padding of 3.
        let all : Array UInt64 :=
          #[3, 1, 4, 1, 1280, 1, 700, 1, 1, 1, 0x11223344, 1, 0xaabbccff, 1, 3, 1, 0xff0000ff, 1, 1,
            1, 1, 1536, 1, 192]
        -- Its name, and nothing set.
        let unset : Array UInt64 :=
          #[5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A name of two bytes; upright; no underline, which is set; not
        -- struck through, which is set; one and a half times the font's
        -- own line height.
        let upright : Array UInt64 :=
          #[2, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 96, 0, 0]
        -- Oblique, and a single underline with no colour of its own.
        let oblique : Array UInt64 :=
          #[1, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A weight over 1000, sent as 1000, and a double underline.
        let heavy : Array UInt64 :=
          #[1, 0, 0, 0, 0, 1, 1000, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A weight of 0, sent as 1, and a dotted underline.
        let light : Array UInt64 :=
          #[1, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        -- A dashed underline.
        let dashed : Array UInt64 :=
          #[1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        real.publish emptyScene
        let back ← real.display.scene
        return encoded.words ==
              scene ++ faces ++ all ++ unset ++ upright ++ oblique ++ heavy ++ light ++ dashed &&
            encoded.strings == "allmonounsetébcde" &&
            back == some (encoded.words, encoded.strings) },
    { name :=
        "a theme is sent with the first scene published after it was set and not with the next, which is laid out in the faces last sent"
      run := do
        let first : Editor.Theme :=
          #[{ name := ⟨"default"⟩, face := { background := some (.rgb 1 2 3) } }]
        let second : Editor.Theme :=
          #[{ name := ⟨"default"⟩, face := { background := some (.rgb 4 5 6) } }]
        let fixture ← sceneFixture first
        let real := fixture.real
        let scene := fixture.scene (SceneFixture.own fixture.top) #[]
        let sent (faces : Option Editor.Theme) : IO (Option (Array UInt64 × String)) := do
          let encoded ← real.encode scene faces
          return some (encoded.words, encoded.strings)
        real.publish scene
        let withFirst ← real.display.scene
        let inFirst ← real.display.frameText
        real.publish scene
        let withNone ← real.display.scene
        let stillFirst ← real.display.frameText
        real.setTheme second
        real.publish scene
        let withSecond ← real.display.scene
        let inSecond ← real.display.frameText
        real.publish scene
        let withNoneAgain ← real.display.scene
        let stillSecond ← real.display.frameText
        -- The document is held until here, past the last publish.
        let held ← fixture.document.read
        return withFirst == (← sent (some first)) && withNone == (← sent none) &&
            stillFirst == inFirst &&
            withSecond == (← sent (some second)) &&
            inSecond != inFirst &&
            withNoneAgain == withNone &&
            stillSecond == inSecond &&
            held == "ab\ncd\nef" },
    { name :=
        "of the built-in theme's names, layout reads default, selection and mode-line by itself: with each renamed in turn the frame is another, and with echo-area renamed, which nothing draws, it is the built-in theme's"
      run := do
        let renamed (name : String) : Editor.Theme :=
          Editor.Theme.builtin.map fun definition =>
            if definition.name.name == name then { definition with name := ⟨name ++ ".renamed"⟩ }
            else definition
        let fixture ← sceneFixture Editor.Theme.builtin
        let real := fixture.real
        -- View 2 has a selection and a status field.
        let scene :=
          fixture.scene (SceneFixture.own fixture.anchor) #[SceneFixture.own fixture.selection]
        real.publish scene
        let builtin ← real.display.frameText
        let mut frames := #[builtin]
        for name in ["default", "selection", "mode-line"] do
          real.setTheme (renamed name)
          real.publish scene
          frames := frames.push (← real.display.frameText)
        real.setTheme (renamed "echo-area")
        real.publish scene
        let unread ← real.display.frameText
        -- The document is held until here, past the last publish.
        let held ← fixture.document.read
        let distinct :=
          (List.range frames.size).all fun later =>
            (List.range later).all fun earlier => frames[later]? != frames[earlier]?
        return frames.size == 4 && distinct && unread == builtin && held == "ab\ncd\nef" }]

/-- Publishes the display fixture through the real binding and checks it
against the frame checked in at `fixture` (`tests/display/frame.expected`),
which `editor-layout`'s own test lays out from the same scene: the frame's
text must be the file's; the scene the library writes back must be the
words and the string it was sent; and for a position on each of three of
the frame's rows, one of them inside a wrapped line, the position one
visual line below it, asked through the binding, must be on the frame's
next row. Returns the names of what did not hold. -/
def displayChecks' (fixture : String) : IO (List String) := do
  let expected ← IO.FS.readFile fixture
  let (real, scene, documents) ← displayFixture
  let published ← (Editor.Display.publish scene).runReal real
  let mut failed : List String := []
  if let .error refusal := published then
    failed := failed ++ [s!"publishing was refused: {repr refusal}"]
  if (← real.display.frameText) != expected then
    failed := failed ++ ["the published frame differs from the fixture"]
  -- The first publish sends the fixture's theme with the scene.
  let encoded ← real.encode scene (some fixtureTheme)
  if (← real.display.scene) != some (encoded.words, encoded.strings) then
    failed := failed ++ ["the scene the library writes back is not the one it was sent"]
  let rows := (← real.display.frameRows 1).getD #[]
  -- The documents are held until here, past the publish.
  if documents.size != 2 then
    failed := failed ++ ["the fixture made two documents"]
  for position in [2, 14, 19] do
    let some here := rows.findIdx? fun row => row.start.toNat ≤ position ∧ position < row.stop.toNat
      | failed := failed ++ [s!"no row of the frame holds {position}"]
    let some next := rows[here + 1]?
      | failed := failed ++ [s!"the frame has no row below {position}'s"]
    let moved ←
      (Editor.Display.linesFrom
              { snapshot := ⟨0⟩, width := 96, position, lines := 1, goal := none }).runReal
          real
    match moved with
    | .ok moved =>
      unless next.start.toNat ≤ moved.position ∧ moved.position ≤ next.stop.toNat do
        failed :=
          failed ++
            [s!"one line below {position} is {moved.position}, not on the frame's next row {next.start}..{next.stop}"]
    | .error refusal =>
      failed := failed ++ [s!"the move from {position} was refused: {repr refusal}"]
  return failed

/-- Runs `displayChecks'` on the fixture at `fixture`: exits 0 when all hold,
and 1 after naming on stderr those that do not. -/
def displayScenario (fixture : String) : IO UInt8 := do
  let failed ← displayChecks' fixture
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println
      "ffi-test display: the published frame is the fixture, the scene comes back as sent, and three moves land on the frame's next row"
  return 0

end FfiTest
