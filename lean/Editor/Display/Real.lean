import Editor.Display
import Editor.Face
import Editor.Ffi
import Editor.Text.Real

/-!
# The real binding of the display interface

The display interface (`Editor/Display.lean`) answered by the Rust
library's layout (`crates/editor-layout`, behind `Ffi.Display`), over its
fake shaper until a real one exists (the display pipeline's phase 3).

It needs only the read half of the text binding's table of snapshots
(`SnapshotReader`): a query names its text by a `SnapshotId`, which the
table turns into the library's snapshot, and the library reaches the
document behind it, for its edit log, through the snapshot itself.

- A snapshot the table does not hold is refused here with
  `noSuchSnapshot`; an offset that is not a position, by the library, with
  `badPosition`.
- Numbers are `Nat` here and machine words in the library. One no word
  holds is sent as the largest word, which no text is long enough to
  accept, so it is refused, or, for a width, a height or a goal, is wider
  than any view: never cut down to one the library would read as another.

**Publishing** sends the scene as words, one string and the snapshot
handles its views show (`encode`; the layout is
`crates/editor-ffi/src/display/wire.rs`'s), and the library lays it out and
keeps the frame. A view's scroll anchor and selections go as their markers'
numbers, which the library reads in the document of the view's snapshot as
it is when the scene arrives. The library cannot tell whose number it is
given, so a view whose markers are not all of one text is sent with no
scroll marker and no selection, and is shown from its start. A document
gone by then (released) resolves nothing either; the text binding keeps
every document a command can name alive.

**The theme travels with the scene, in the binding.** The scene names faces
and the display interface publishes a scene (`Editor/Scene.lean`,
`Editor/Display.lean`); neither says what a face looks like. This binding
holds the theme (`Editor/Face.lean`) and writes its definitions into the
same words and the same string as the scene, so a scene and its faces reach
layout in one call. They are written only on the first publish after the
theme was set (`over`, `setTheme`): the words carry a presence, and absent
is "as last published", so a publish costs the faces only when they
changed. A theme stays to be sent until the library has taken it. Lean
merges nothing: a theme is a list of definitions, sent in order, and where
it defines a name twice the later definition is over the earlier by layout's
rule.

**A theme to be sent is in the heights already.** The loop asks the heights
before it lays out the views it publishes (`Loop.publish`), and the heights
are in the faces layout has. So the heights answer first defines a theme
still to be sent, by itself (`Ffi.Display.define`), and the theme stays to
be sent with the scene, which layout then takes as no change: the heights
and the rows queries a publish is sized by are in the faces its frame is
laid out in, after a re-theme and at the first publish alike.
`ConfigTest.faceChecks` checks it after a reload that makes `mode-line`
taller.

It is never imported by `Editor` or by anything `model-test` reaches: it
links the Rust library. `contract-test` holds it to the display contract
(`Editor/Display/Contract.lean`), and `ffi-test display` to the fixture
frame checked in at `tests/display/frame.expected`. The library writes a
scene back as it was sent whatever it was sent, so `ffi-test` also compares
the words of one scene with the library's layout written out
(`FfiTest.sceneChecks`): a scene with what the fixture has none of, a
pending prefix, a preedit, a view whose snapshot the table does not hold
and a view whose markers are of two texts, and it checks what the library
shows of each of those views; and the words of a theme whose definitions
use every constructor of a face's attributes, when a theme is sent and when
it is not, and which names layout reads by itself.
-/

namespace Editor

/-- The real binding: the library's display, the read half of the text
binding's table of snapshots it finds a query's snapshot in, and the theme
it has yet to send. -/
structure RealDisplay where
  /-- The library's display. -/
  display : Ffi.Display
  /-- The snapshots a query may name. -/
  snapshots : SnapshotReader
  /-- The theme not yet sent: set by `over` and by `setTheme`, and none
  once a publish has sent it. -/
  theme : IO.Ref (Option Theme)
  /-- The platform whose window the requests of the window go to; none for
  a display that asks no window anything. -/
  platform : Option Ffi.Platform := none

namespace RealDisplay

/-- The binding over `display` and `snapshots`, with `theme` to send with
the first scene published, and the window of `platform` to send requests of
the window to, when there is one. -/
def over (display : Ffi.Display) (snapshots : SnapshotReader) (theme : Theme)
    (platform : Option Ffi.Platform := none) : BaseIO RealDisplay := do
  return { display, snapshots, theme := ← IO.mkRef (some theme), platform }

/-- The library's name of a request of the window. -/
def library : Display.FrameRequest → Ffi.WindowRequest
  | .enterFullscreen => .enterFullscreen
  | .leaveFullscreen => .leaveFullscreen
  | .minimise => .minimise
  | .keepRunning => .keepRunning

/-- Makes `theme` what the faces look like from the next publish on: it is
sent with the next scene published, in place of the theme sent before,
and the heights asked before that publish are already in it (`heights`). -/
def setTheme (real : RealDisplay) (theme : Theme) : BaseIO Unit :=
  real.theme.set (some theme)

/-- The library's machine word for an offset of the port: one no word
holds is the largest, past the end of every text. -/
def offset (number : Nat) : USize :=
  if number < USize.size then number.toUSize else (USize.size - 1).toUSize

/-- The rows a view shows: `Display.rowsShown`'s answer. -/
def rows (real : RealDisplay) (query : Display.RowsQuery) :
    IO (Except DisplayError (Array Display.Row)) := do
  let some snapshot ← real.snapshots.find? query.snapshot | return .error .noSuchSnapshot
  let answer ←
    real.display.rows snapshot (RealTexts.word query.width) (RealTexts.word query.height)
        (offset query.anchor)
  match answer with
  | some rows =>
    return .ok (rows.map fun row => { start := row.start.toNat, stop := row.stop.toNat })
  | none =>
    return .error .badPosition

/-- Where a move goes: `Display.linesFrom`'s answer. -/
def move (real : RealDisplay) (query : Display.MoveQuery) :
    IO (Except DisplayError Display.Moved) := do
  let some snapshot ← real.snapshots.find? query.snapshot | return .error .noSuchSnapshot
  let answer ←
    real.display.move snapshot (RealTexts.word query.width) (offset query.position) query.lines
        (query.goal.map RealTexts.word)
  match answer with
  | some moved =>
    return .ok { position := moved.position.toNat, goal := moved.goal.toNat }
  | none =>
    return .error .badPosition

/-- The library's tag of a cursor shape. -/
def shapeTag : CursorShape → UInt64
  | .block => 0
  | .bar => 1
  | .underline => 2
  | .hollow => 3

/-- A scene as it crosses to the library (the layout is
`crates/editor-ffi/src/display/wire.rs`'s): words, one string of every text
in it, and the snapshot handles its views show, which the words name by
index. -/
structure Encoded where
  /-- The words. -/
  words : Array UInt64
  /-- The string. -/
  strings : String
  /-- The snapshot handles. -/
  snapshots : Array Ffi.Snapshot

/-- The numbers of `view`'s scroll marker and selection markers, when they
are all markers of one text. Otherwise `none`: the library resolves a
number in the document of the view's snapshot and cannot tell whose it is,
so the view is sent from its text's start with no selection. -/
def markers (view : View) : Option (UInt64 × Array UInt64) :=
  if view.selections.all (·.text == view.scroll.text) then
    some (RealTexts.word view.scroll.index, view.selections.map (RealTexts.word ·.index))
  else none

/-- Adds a text's length to `words` and the text to `strings`. -/
def pushText (encoded : Encoded) (text : String) : Encoded :=
  { encoded with
    words := encoded.words.push text.utf8ByteSize.toUInt64
    strings := encoded.strings ++ text }

/-- Adds an optional number: its presence, then it or 0. -/
def pushOptional (words : Array UInt64) : Option UInt64 → Array UInt64
  | some value => words.push 1 |>.push value
  | none => words.push 0 |>.push 0

/-- `view` added to `encoded`: its snapshot, found in the table, as the
next handle when the table holds it. -/
def encodeView (real : RealDisplay) (encoded : Encoded) (view : View) : IO Encoded := do
  let snapshot ← real.snapshots.find? view.snapshot
  let index := snapshot.map fun _ => encoded.snapshots.size.toUInt64
  let snapshots :=
    match snapshot with
    | some found => encoded.snapshots.push found
    | none => encoded.snapshots
  let (scroll, selections) :=
    match markers view with
    | some (scroll, selections) => (some scroll, selections)
    | none => (none, #[])
  let rect := view.rect
  let words :=
    #[RealTexts.word view.id.index, RealTexts.word rect.x, RealTexts.word rect.y,
      RealTexts.word rect.width, RealTexts.word rect.height]
  let words := pushOptional (pushOptional words index) scroll
  let words := (words.push selections.size.toUInt64 ++ selections).push (shapeTag view.cursor.shape)
  let mut encoded :=
    pushText
      { encoded with
        words := encoded.words ++ words, snapshots }
      view.cursor.face.name
  encoded := { encoded with words := encoded.words.push view.decorations.size.toUInt64 }
  for decoration in view.decorations do
    encoded :=
      pushText
        { encoded with
          words :=
            encoded.words.push (RealTexts.word decoration.start) |>.push
              (RealTexts.word decoration.stop) }
        decoration.face.name
  encoded := { encoded with words := encoded.words.push view.status.size.toUInt64 }
  for field in view.status do
    encoded :=
      { encoded with
        words :=
          encoded.words.push field.text.utf8ByteSize.toUInt64 |>.push
            field.face.name.utf8ByteSize.toUInt64
        strings := encoded.strings ++ field.text ++ field.face.name }
  return encoded

/-- The library's tag of a slant. -/
def slantTag : Slant → UInt64
  | .upright => 0
  | .italic => 1
  | .oblique => 2

/-- The library's tag of an underline style. -/
def underlineTag : UnderlineStyle → UInt64
  | .none => 0
  | .single => 1
  | .double => 2
  | .curly => 3
  | .dotted => 4
  | .dashed => 5

/-- The word of a weight: 1 to 1000, a weight outside that range sent as
the nearest end of it, which is what the library would refuse otherwise. -/
def weightWord (weight : Nat) : UInt64 :=
  (min 1000 (max 1 weight)).toUInt64

/-- One definition of a face added to `encoded`: its 22 words, an absent
attribute written as 0, and its name and then its family, when it has one,
added to the string. -/
def encodeFace (encoded : Encoded) (definition : FaceDefinition) : Encoded :=
  let face := definition.face
  let color (color : Color) : UInt64 := color.word.toUInt64
  let underline := face.underline.getD { style := .none }
  let (kind, height) : UInt64 × UInt64 :=
    match face.lineHeight with
    | some (.multiple sixtyFourths) => (0, sixtyFourths.toUInt64)
    | some (.pixels height) => (1, height.sixtyFourths.toUInt64)
    | none => (0, 0)
  let named := pushText encoded definition.name.name
  let words := named.words.push face.family.isSome.toUInt64
  let familied := pushText { named with words } (face.family.getD "")
  let words := pushOptional familied.words (face.size.map (·.sixtyFourths.toUInt64))
  let words := pushOptional words (face.weight.map weightWord)
  let words := pushOptional words (face.slant.map slantTag)
  let words := pushOptional words (face.foreground.map color)
  let words := pushOptional words (face.background.map color)
  let words := words.push face.underline.isSome.toUInt64 |>.push (underlineTag underline.style)
  let words := pushOptional words (underline.color.map color)
  let words := pushOptional words (face.strikeThrough.map (·.toUInt64))
  { familied with words := words.push face.lineHeight.isSome.toUInt64 |>.push kind |>.push height }

/-- The definitions of `theme` added to `encoded`: their count, then each
(`encodeFace`). After a presence, they are a scene's faces; by themselves,
they are what `heights` defines ahead of the scene. -/
def encodeDefinitions (encoded : Encoded) (theme : Theme) : Encoded :=
  theme.foldl encodeFace { encoded with words := encoded.words.push theme.size.toUInt64 }

/-- The tag of a system action, as the library reads it: 0 about, 1
services, 2 hide, 3 hide others, 4 show all, 5 quit. -/
def systemTag : SystemAction → UInt64
  | .about => 0
  | .services => 1
  | .hide => 2
  | .hideOthers => 3
  | .showAll => 4
  | .quit => 5

/-- `item` added to `encoded`: its kind (0 a separator, 1 a command, 2 a
system item), then for an item its title, its key's presence, scalar value
and modifier bits, and its command's name or its system action's tag. -/
def encodeMenuItem (encoded : Encoded) : MenuItem → Encoded
  | .separator => { encoded with words := encoded.words.push 0 }
  | .item title key action =>
    let kind : UInt64 :=
      match action with
      | .command _ => 1
      | .system _ => 2
    let encoded := pushText { encoded with words := encoded.words.push kind } title
    let (scalar, bits) : UInt64 × UInt64 :=
      match key with
      | some key => (key.character.toNat.toUInt64, Ffi.modifierBits key.modifiers)
      | none => (0, 0)
    let encoded :=
      { encoded with words := encoded.words.push key.isSome.toUInt64 |>.push scalar |>.push bits }
    match action with
    | .command name => pushText encoded name
    | .system system => { encoded with words := encoded.words.push (systemTag system) }

/-- `menu` added to `encoded` (`crates/editor-ffi/src/menu.rs`): its count of
menus, then each menu's title, role (0 none, 1 the application's, 2 the
windows menu) and count of items, and each item. -/
def encodeMenu (encoded : Encoded) (menu : Menu) : Encoded :=
  menu.menus.foldl
    (fun encoded submenu =>
      let role : UInt64 :=
        match submenu.role with
        | none => 0
        | some .app => 1
        | some .window => 2
      let encoded := pushText encoded submenu.title
      let encoded :=
        { encoded with words := encoded.words.push role |>.push submenu.items.size.toUInt64 }
      submenu.items.foldl encodeMenuItem encoded)
    { encoded with words := encoded.words.push menu.menus.size.toUInt64 }

/-- `scene` as it crosses to the library, with the definitions `faces`
after its views when there are any to send: none is sent as their absence,
which is "as last published". A view whose snapshot the table does not
hold is sent with none, and shows nothing. -/
def encode (real : RealDisplay) (scene : Scene) (faces : Option Theme) : IO Encoded := do
  let words :=
    pushOptional #[RealTexts.word scene.size.width, RealTexts.word scene.size.height]
      (scene.focused.map (RealTexts.word ·.index))
  let encoded :=
    pushText (pushText { words, strings := "", snapshots := #[] } scene.echo) scene.pending
  let encoded := { encoded with words := encoded.words.push scene.preedit.isSome.toUInt64 }
  let encoded := pushText encoded (scene.preedit.getD "")
  let encoded := pushText encoded scene.title
  let encoded := { encoded with words := encoded.words.push scene.menu.isSome.toUInt64 }
  let encoded := (scene.menu.map (encodeMenu encoded)).getD encoded
  let encoded := { encoded with words := encoded.words.push scene.views.size.toUInt64 }
  let encoded ← scene.views.foldlM real.encodeView encoded
  match faces with
  | none =>
    return { encoded with words := encoded.words.push 0 }
  | some theme =>
    return encodeDefinitions { encoded with words := encoded.words.push 1 } theme

/-- Publishes `scene` to the library, with the theme if it has not been
sent yet. The theme counts as sent once the library has taken the scene.
Words this binding wrote that the library cannot read are an error: they
are this binding's mistake. -/
def publish (real : RealDisplay) (scene : Scene) : IO Unit := do
  let unsent ← real.theme.get
  let encoded ← real.encode scene unsent
  unless ← real.display.publish encoded.words encoded.strings encoded.snapshots do
    throw (IO.userError "the library could not read a scene's words")
  if unsent.isSome then
    real.theme.set none

/-- The heights the library's layout answers at its scale, in the faces
the next publish lays out in: a theme not yet sent is defined in layout
first, by itself, and stays to be sent with that publish's scene. So a
caller that sizes its views by these heights and then publishes is
answered the heights of that publish's frame, the first after a re-theme
too. Words this binding wrote that the library cannot read are an error,
as for `publish`. -/
def heights (real : RealDisplay) : IO Display.Heights := do
  if let some theme← real.theme.get then
    let defined := encodeDefinitions { words := #[], strings := "", snapshots := #[] } theme
    unless ← real.display.define defined.words defined.strings do
      throw (IO.userError "the library could not read a theme's words")
  let heights ← real.display.heights
  return {
      text := heights.text.toNat, status := heights.status.toNat
      message := heights.message.toNat }

/-- Answers `request` from the library. -/
def handle (real : RealDisplay) : (request : DisplayRequest) → IO request.Reply
  | .publish scene => real.publish scene
  | .rows query => real.rows query
  | .move query => real.move query
  | .heights => real.heights
  | .frame request => do
    if let some platform := real.platform then
      Ffi.windowRequest platform (library request)

end RealDisplay

/-- Runs a display program against the real binding `real`: its result, or
the refusal it failed with. -/
def DisplayM.runReal {α : Type} (program : DisplayM α) (real : RealDisplay) :
    IO (Except DisplayError α) :=
  Program.runM (port := displayPort) real.handle program.run

end Editor
