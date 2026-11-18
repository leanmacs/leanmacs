import Editor.File
import Editor.Fuzzy
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.Loop
import Editor.ModeLine
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.UndoTree
import Editor.Value

/-!
# Config tests: support: Lines

What a printed scene's lines say: offsets, a view's line and its status line, a
line after its view's id, a list view's lines and rectangle, a prompt's line and
status, a prompt that lists given fields (`listsAfter`), and which view has the
focus; and the order the library's matcher ranks
texts in (`realOrder`), which a list view shows. Shared by several test modules;
it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- The byte offset of the first occurrence of `needle` in `text`; none
when it does not hold it. -/
def offsetOf (text needle : String) : Option Nat :=
  match text.splitOn needle with
  | before :: _ :: _ => some before.utf8ByteSize
  | _ => none

/-- The view line of the last scene the host printed. -/
def lastViewLine (lines : Array String) : String :=
  (lines.filter (·.startsWith "view 0 ")).back?.getD ""

/-- The status line the host prints for the view `view`, selected, of a
buffer called `name`, modified or not, opened from `file` or from none, of
which the test scheme reports nothing, with its cursor at `cursor` (a row
and a column in cells) in a text of `lines` rows, and with its file found
changed on disk by a check when `changed`: what the host prints
(`Headless.statusLine`) of the fields the shipped mode line gives such a
view (`ModeLine.standard`), its row in `mode-line.active`
(`Loop.statusOf`). So a check that compares a host's whole output
repeats neither the mode line's faces and texts nor the host's form. Each
call site passes the cursor its printed `selections` imply and the rows its
text has, since the line:col and the position segments read them. The
scratch buffer is the default: the loop's frame is made with it, and its
name is the editor state's to choose. -/
def statusOf (view : Nat := 0) (name : String := "scratch") (modified : Bool := false)
    (cursor : Point := ⟨0, 0⟩) (lines : Nat := 1) (file : Option System.FilePath := none)
    (changed : Bool := false) : String :=
  let saved := UndoTree.new ⟨0⟩ 0
  -- A file whose change on disk a check found has the changed mark,
  -- whatever its stamps; with no path given, it has none to show.
  let path := if changed then some (file.getD "") else file
  let buffer : Buffer :=
    { name, text := ⟨0⟩, history := if modified then saved.record 1 else saved
      file :=
        path.map fun path =>
          { path, stamp := { seconds := 0, nanoseconds := 0, size := 0 }
            changed := if changed then some { found := none, told := true } else none } }
  Headless.statusLine ⟨view⟩
    (ModeLine.standard.fields { buffer, cursor := some cursor, lines, modified })
    (some ModeLine.activeFace)

/-- Whether `output` has a line that says a job registered under `name`
ended ok, whatever its id: the loop's own checks of files shift the ids of
the jobs a command starts. -/
def endedOk (output : Array String) (name : String) : Bool :=
  output.any fun line => line.startsWith "job " && line.endsWith s!" {name}: ok"

/-- The line of a view 0 that fills a frame of no size, showing `text` with
its one cursor at `cursor`. -/
def viewLine (text : String) (cursor : Nat) : String :=
  s!"view 0 0,0 0x0: {text.quote}, scroll 0, selections {cursor}..{cursor}, padding 8 8"

/-- What `line`, a line of a printed scene, says after its view's id: from
its first `:` on. -/
def afterId (line : String) : String :=
  (line.dropWhile (· != ':')).toString

/-- Whether a view line of `lines` is the candidate list's showing `rows`,
whichever view it is of: a view with no selection whose text is the rows,
one a line. -/
def listViewShows (lines : Array String) (rows : List String) : Bool :=
  let text := "\n".intercalate rows
  lines.any fun line =>
    line.startsWith "view " &&
      (afterId line).startsWith s!": {text.quote}, scroll 0, selections , padding"

/-- Whether `lines` show a prompt labelled `label` listing `fields`: a
status line that is the label alone, in the prompt's face, and the
candidate list's view showing the fields, one a row, whichever views they
are of: each prompt opens a minibuffer view of its own. -/
def listsAfter (lines : Array String) (label : String) (fields : List String) : Bool :=
  let status := Headless.statusLine ⟨0⟩ #[{ text := label, face := Loop.promptFace }]
  lines.any (fun line => line.startsWith "status " && afterId line == afterId status) &&
    listViewShows lines fields

/-- The texts of `texts` that the library's matcher (`Fuzzy.real`) answers
for `pattern`, in its order: what a prompt of the fuzzy style lists, so a
check computes the library's order and never writes it out. -/
def realOrder (pattern : String) (texts : Array String) : IO (List String) := do
  let ranked ← Fuzzy.real (.rank pattern texts)
  return (ranked.filterMap (texts[·]?)).toList

/-- The rectangle the view line of `lines` for the view `id` prints: its
x, y, width and height. -/
def printedRect (lines : Array String) (id : Nat) : Option (Nat × Nat × Nat × Nat) := do
  let line ← lines.find? (·.startsWith s!"view {id} ")
  match line.splitOn " " with
  | _ :: _ :: corner :: size :: _ =>
    match corner.splitOn ",", ((size.dropEnd 1).toString).splitOn "x" with
    | [x, y], [width, height] =>
      return (← x.toNat?, ← y.toNat?, ← width.toNat?, ← height.toNat?)
    | _, _ =>
      none
  | _ =>
    none

/-- The id of the candidate list's view in `lines`, a printed scene: the
view with no selection. -/
def listViewId (lines : Array String) : Option Nat := do
  let line ←
    lines.find? fun line => line.startsWith "view " && (line.splitOn "selections , ").length > 1
  (line.splitOn " ")[1]?.bind (·.toNat?)

/-- The line of the minibuffer's view, view 1 in a frame of no size, showing
`text` with its one cursor at `cursor`. -/
def minibufferLine (text : String) (cursor : Nat) : String :=
  s!"view 1 0,0 0x0: {text.quote}, scroll 0, selections {cursor}..{cursor}, padding 8 0"

/-- The status line of the minibuffer's view, view 1, while a prompt
labelled `label` is open: what the host prints (`Headless.statusLine`) of
the one field the loop gives that view, the label in the prompt's face
(`Loop.promptFace`). So a check repeats neither the face nor the host's
form. -/
def promptStatus (label : String := "Name: ") : String :=
  Headless.statusLine ⟨1⟩ #[{ text := label, face := Loop.promptFace }]

/-- Whether the scene line `line` names `view` as the focused view. -/
def focuses (line : String) (view : Nat) : Bool :=
  (line.splitOn s!", focused {view}, ").length == 2

end ConfigTest
