import Editor.Api
import Editor.Clipboard.Model
import Editor.Command
import Editor.Command.Model
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Evil.Kit
import Editor.Evil.Registers
import Editor.File
import Editor.Highlight
import Editor.InputScheme
import Editor.InputScheme.Vim
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Language
import Editor.Language.IndentUnit
import Editor.Loop.Driver
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.ProjectMode
import Editor.Scene
import Editor.State
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Models
import Editor.Test.Modes
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Workspace
import ModelTest.Support.Vim

/-!
# Model tests: support: Evil

The fixtures of evil's checks: texts with the cursor written into them as a bar,
the driver under the Vim scheme that ships (evil's kit, `Editor/Evil/Kit.lean`),
and what a check reads of its state, scene, history and registers. Shared by several test modules under
`ModelTest/Editor/`; it holds no checks of its own.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- Texts of the resting rule's checks, each with every position it has, in
order, and where each rests under `onCell` and under `offLineBreak`,
written out by hand: the empty text; one line feed; a line with no line
break; a line and its line feed; two lines around an empty one; a carriage
return and line feed, with the position between the two; and a character
of four bytes. -/
def restings : List (String × List Nat × List Nat × List Nat) :=
  [("", [0], [0], [0]), ("\n", [0, 1], [0, 0], [0, 0]), ("ab", [0, 1, 2], [0, 1, 1], [0, 1, 1]),
    ("ab\n", [0, 1, 2, 3], [0, 1, 2, 2], [0, 1, 1, 1]),
    ("ab\n\ncd", [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 4, 5, 5], [0, 1, 1, 3, 4, 5, 5]),
    ("ab\r\ncd", [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 2, 4, 5, 5], [0, 1, 1, 1, 4, 5, 5]),
    ("a😀", [0, 1, 5], [0, 1, 1], [0, 1, 1])]

/-- The keys the key string `typed` names, pressed under the Vim scheme that
ships with evil's commands, from the text and the cursor `fixture` says:
the text after them with a bar at the cursor, or what the echo area says
when a command said something. -/
def evilKeys (fixture typed : String) : String :=
  match evilDriver fixture with
  | none => "no driver"
  | some driver =>
    let driver := evilFed driver typed
    if driver.loop.state.echo.isEmpty then evilShown driver else driver.loop.state.echo

/-- Whether each row of `rows` holds: the keys of a row, pressed from its
first fixture, leave its second (`evilKeys`). A failure names each row that
does not hold, with what its keys left, and each row whose key string
names no keys. -/
def evilRows (rows : List (String × String × String)) : IO Bool := do
  let wrong :=
    rows.filterMap fun (typed, before, after) =>
      let got := evilKeys before typed
      -- A key string that is refused presses nothing, which a row that
      -- expects the text unchanged would not show.
      if (keys typed).isEmpty then some s!"{repr typed} names no keys"
      else if got == after then none else some s!"{typed} from {repr before} left {repr got}"
  unless wrong.isEmpty do
    throw (IO.userError ("; ".intercalate wrong))
  return true

/-- Whether a cursor of normal state may rest at the byte offset `head` of
`contents`, said of the string alone: the text is empty and the offset 0;
or a cell starts there, which is a character's start that is not the line
feed of a carriage return and line feed, and that cell is not the line
break of a row that has content. -/
def restsWell (contents : String) (head : Nat) : Bool :=
  let chars := contents.toList
  let offsets :=
    (chars.foldl (fun (offsets, walked) char => (offsets ++ [walked], walked + char.utf8Size))
        ([], 0)).1
  let before := none :: chars.map some
  let after := (chars.drop 1).map some ++ [none]
  contents.isEmpty && head == 0 ||
    ((offsets.zip chars).zip (before.zip after)).any fun ((offset, char), (before, after)) =>
      offset == head && !(char == '\n' && before == some '\r') &&
        !((char == '\n' || char == '\r' && after == some '\n') && before.isSome &&
            before != some '\n')

/-- The texts every motion, operator and text object is swept over: those
of the resting rule's checks, one with a run of punctuation beside a word, a
run of blanks, an empty line, a line that begins with a tab, and a last line
with no line feed, and one with brackets of each kind nested, quotes of two
kinds, an escaped pair and an indented `{ }` block over lines. -/
def sweepTexts : List String :=
  restings.map (·.1) ++ ["foo.bar  x\n\n\tab\nend", "f(a [b] \"c\" 'd' \\(e\\))\n  {\n x\n }"]

/-- What a scene shows of one view, as the evil checks read it. -/
structure EvilSeen where
  /-- The selection the view's one selection marker holds. -/
  selection : Selection
  /-- The text each range of that selection covers, by its shape. -/
  covered : Array String
  /-- How the view's cursors are drawn. -/
  cursor : Cursor
  /-- The left side of the view's mode line: its badge, its buffer's name
  and its modified mark. -/
  status : Array StatusField
  deriving DecidableEq, Repr

/-- What the last scene `driver`'s display recorded shows of the view
`view`: the selection its selection marker holds in the text model, what
that selection covers, the view's cursor and its status line. `none` when
no scene has the view, or it does not name one selection marker. -/
def evilSeen (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option EvilSeen := do
  let scene ← driver.model.display.scenes.back?
  let shown ← scene.views.find? (·.id == view)
  let #[marker] := shown.selections | none
  let program : TextM (Selection × Array String) := do
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let extents ← marker.text.extents selection
    return (selection, ← extents.mapM fun extent => marker.text.slice extent.start extent.stop)
  let (selection, covered) ← (program.runModel driver.model.texts).1.toOption
  return { selection, covered, cursor := shown.cursor, status := leftOf shown.status }

/-- What the scene after the keys `typed`, pressed from the fixture
`fixture`, shows of view 0 (`evilSeen`). -/
def evilScene (fixture typed : String) : Option EvilSeen :=
  (evilDriver fixture).bind fun driver => evilSeen (evilFed driver typed)

/-- The selection the scene shows after the keys `typed`, pressed from the
fixture `fixture`: its ranges, as an anchor and a head each, its shape,
and the text each range covers. -/
def evilSelected (fixture typed : String) : Option (List (Nat × Nat) × Shape × List String) :=
  (evilScene fixture typed).map fun seen =>
    ((seen.selection.ranges.map fun range => (range.anchor, range.head)).toList,
      seen.selection.shape, seen.covered.toList)

/-- The cursor and the left side of the mode line a scene shows of a view of
the buffer `scratch`, not modified, in the Vim state view 0 is in after the
keys `typed` under the grammar alone: what the default scheme reports of
that state, as the badge, and then the buffer's name. -/
def evilLooks (typed : String) : Cursor × Array StatusField :=
  let report := vimDefaultReport typed
  (report.cursor,
    report.status.map ({ · with padding := ModeLine.badgePadding }) ++
      #[ModeLine.field "scratch" ModeLine.bufferFace])

/-- The modified mark, as the mode line of a selected view draws it. -/
def evilMark : StatusField :=
  ModeLine.field ModeLine.modifiedMark ModeLine.modifiedFace

/-- The history of the buffer 0 of `driver`, as the checks read it: how many
nodes its tree has, and whether an edit is pending in its open group. -/
def evilHistory (driver : EvilDriver) : Option (Nat × Bool) :=
  (driver.loop.state.buffer? ⟨0⟩).map fun buffer =>
    (buffer.history.nodes.size, buffer.history.pending)

/-- `driver` after one undo request of the buffer 0 (`BufferId.undo`), made
by a command the loop is handed, which says in the echo area whether there
was a step to undo: `undone` or `nothing to undo`. -/
def evilUndone (driver : EvilDriver) : EvilDriver :=
  let undo : EditorM Unit := do
    match ← (⟨0⟩ : BufferId).undo with
    | .ok (some _) =>
      message "undone"
    | _ =>
      message "nothing to undo"
  (driver.stepped (driver.loop.deliver driver.handed "undo" undo)).1

/-- What the buffer 0 of `driver` holds in the text model. -/
def evilText (driver : EvilDriver) : Option String := do
  let buffer ← driver.loop.state.buffer? ⟨0⟩
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- What the unnamed register holds before the keys of an operator's row:
a text no row yields, so that a register the keys left as it was is seen. -/
def evilSentinel : Register :=
  { text := "the sentinel", linewise := true }

/-- What the keys of an operator's row left, as the checks read it. -/
structure EvilEdited where
  /-- The buffer's text with a bar at the head of the selection's primary
  range. -/
  shown : String
  /-- The unnamed register; `none` when it is as it was before the keys. -/
  register : Option Register
  /-- Whether the scene's status line says the view is in insert state: its
  first field, the mode line's badge, is the one the scheme reports of that
  state. -/
  insert : Bool
  /-- What the echo area says. -/
  echo : String
  deriving DecidableEq, Repr

/-- A driver of the evil checks over the state the fixture `fixture` says,
with the unnamed register holding `evilSentinel`, on the models `model`. -/
def evilRegistered (fixture : String) (model : EditorModel := editorModel) : Option EvilDriver :=
  let (contents, head) := barred fixture
  (Loop.Driver.over evilHanded (fun _ => none)
      (do
        return (← evilState contents head).setRegister Evil.unnamed evilSentinel)
      model).toOption

/-- What `driver`, made by `evilRegistered`, shows after its keys. -/
def evilLeft (driver : EvilDriver) : EvilEdited :=
  let register := driver.loop.state.register? Evil.unnamed
  { shown := evilShown driver
    register := if register == some evilSentinel then none else register
    insert :=
      let badge (field : StatusField) := (field.text, field.face)
      ((evilSeen driver).bind (·.status[0]?)).map badge ==
          (vimDefaultReport "i").status[0]?.map badge &&
        (vimDefaultReport "i").status[0]? != (vimDefaultReport "").status[0]?
    echo := driver.loop.state.echo }

/-- The keys the key string `typed` names, pressed under the Vim scheme that
ships with evil's commands, from the text and the cursor `fixture` says,
with the unnamed register holding a sentinel: what they left. -/
def evilEdited (fixture typed : String) : Option EvilEdited :=
  (evilRegistered fixture).map fun driver => evilLeft (evilFed driver typed)

/-- The operate command called with `arguments`, as an invocation no key
yielded, from the text and the cursor `fixture` says: what it left. -/
def evilOperated (fixture : String) (arguments : List Argument) : Option EvilEdited :=
  (evilRegistered fixture).map fun driver =>
    evilLeft
      (driver.stepped
          (driver.loop.invoke driver.handed { command := Vim.operateCommand, arguments })).1

/-- A register's text that is not line-wise, as a row expects it. -/
def charwise (text : String) : Option Register :=
  some { text }

/-- A register's text that is line-wise, as a row expects it. -/
def linewise (text : String) : Option Register :=
  some { text, linewise := true }

/-- The register a row expects its keys to leave as it was. -/
def asItWas : Option Register :=
  none

/-- The text objects source of the test mode the tree's text objects are
checked under, in the model's query subset over its JSON grammar: an object
is a function and inside one, an array a class and inside one, and a pair
and an array's item an argument. -/
def jsonTextObjects : String :=
  "(object) @function.outer\n(object) @function.inner\n(array) @class.outer\n(array) @class.inner\n(pair) @parameter.inner\n(array (_) @parameter.inner)"

/-- A driver of the evil checks over the state the fixture `fixture` says,
with the unnamed register holding `evilSentinel`, whose buffer's text is
entered in a test mode of the model's JSON grammar that keeps the text
objects source `textObjects`, `jsonTextObjects` unless another is given, on
the editor's models. -/
def treeRegistered (fixture : String) (textObjects : String := jsonTextObjects) :
    Option EvilDriver :=
  let (contents, head) := barred fixture
  let prepared : EditorM EditorState := do
    let state ← evilState contents head
    if let some (some buffer) := state.buffers[0]? then
      Highlight.enter "json-objects" buffer.text
          { grammar := "json", textObjects := some textObjects }
    return state.setRegister Evil.unnamed evilSentinel
  match prepared.runModel editorModel with
  | (.ok state, model) => (Loop.Driver.over evilHanded (fun _ => none) (pure state) model).toOption
  | (.error _, _) => none

/-- The test language of the indent checks: the model's JSON grammar with
`jsonIndents` and `jsonTextObjects`, indented by two spaces. -/
def modelJsonIndented : Language :=
  { name := "model-json", patterns := [.extension "json"]
    syntaxTree :=
      { grammar := "json", indents := some jsonIndents, textObjects := some jsonTextObjects }
    indentUnit := .spaces 2 }

/-- What a step of the indent checks is handed: evil's commands
(`evilHanded`), with the `code` mode and `languages` registered as compiled
code registers them, and `config` registered for config. -/
def indentHanded (languages : Array Language) (config : Array Language := #[]) :
    Loop.Keys Vim.Default.scheme :=
  { evilHanded with
    registered :=
      (((({} : Config.Registry).replaceModes .compiled Language.modes).replaceLanguages .compiled
              languages).replaceLanguages
          .config config).registered }

/-- A driver of the indent checks over the state the fixture `fixture` says,
with the unnamed register holding `evilSentinel`, whose buffer's language
is `language`, `modelJsonIndented` unless another is given, and whose text
is entered in its tree; the table registers `language`, and `config` for
config. On the editor's models. -/
def indentDriver (fixture : String) (language : Language := modelJsonIndented)
    (config : Array Language := #[]) : Option EvilDriver :=
  let (contents, head) := barred fixture
  let prepared : EditorM EditorState := do
    let state ← evilState contents head
    let named := some language.name
    let state : EditorState :=
      { state with buffers := state.buffers.map (·.map ({ · with language := named })) }
    if let some (some buffer) := state.buffers[0]? then
      Highlight.enter Language.codeName buffer.text language.syntaxTree
    return state.setRegister Evil.unnamed evilSentinel
  match prepared.runModel editorModel with
  | (.ok state, model) =>
    (Loop.Driver.over (indentHanded #[language] config) (fun _ => none) (pure state) model).toOption
  | (.error _, _) => none

/-- The keys `typed` pressed from `fixture` on `indentDriver`: what they
left. -/
def indentEdited (fixture typed : String) (language : Language := modelJsonIndented)
    (config : Array Language := #[]) : Option EvilEdited :=
  (indentDriver fixture language config).map fun driver => evilLeft (evilFed driver typed)

/-- Whether `left` is what a command that gave up with `reason` leaves: the
text and the cursor `shown`, the register as it was, the view not in insert
state, and an echo area that ends with the reason and says no refusal. -/
def evilGaveUp (left : Option EvilEdited) (shown reason : String) : Bool :=
  !reason.isEmpty &&
    match left with
    | some left =>
      left.shown == shown && left.register == none && !left.insert && left.echo.endsWith reason &&
        (left.echo.splitOn "refused").length == 1
    | none => false

/-- The keys the key string `typed` names, pressed from the text and the
cursor `fixture` says with the unnamed register holding a sentinel, on the
editor's models with the clipboard model `clipboard`: what they left, and
the text the clipboard model then holds. -/
def evilClipped (fixture typed : String) (clipboard : ClipboardModel := {}) :
    Option (EvilEdited × Option String) :=
  (evilRegistered fixture { editorModel with clipboard }).map fun driver =>
    let after := evilFed driver typed
    (evilLeft after, after.model.clipboard.held)

/-- A driver of the evil checks over a buffer holding `contents` whose lines
end in a carriage return and line feed (`Buffer.lineEnding`), with the
cursor at `head`, on the models `model`. -/
def evilCrlfDriver (contents : String) (head : Nat) (model : EditorModel := editorModel) :
    Option EvilDriver :=
  (Loop.Driver.over evilHanded (fun _ => none)
      (do
        let state ← evilState contents head
        return { state with buffers := state.buffers.map (·.map ({ · with lineEnding := .crlf })) })
      model).toOption

end ModelTest
