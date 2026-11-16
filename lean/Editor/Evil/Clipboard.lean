import Editor.Evil
import Editor.Evil.Motions
import Editor.Evil.Registers

/-!
# The Edit menu's clipboard commands

Cut, Copy, Paste and Select All, the four commands of the Edit menu
(`Editor/Menu/Compiled.lean`) on `s-x`, `s-c`, `s-v` and `s-a`, built from
evil's own pieces: `"+d`, `"+y` and `"+P`, and the operator `replace`
(`Editor/Evil/Operators.lean`) for a Paste in place of a selection. The
clipboard is the register `Evil.clipboard`, reached through the clipboard
port (`Editor/Clipboard.lean`).

## What each command does in each state

A command cannot end a selection or enter a state, so where one of these
must, the state's run table (`Editor/InputScheme/Vim.lean`, "Vim states",
and the tables in `Editor/InputScheme/Vim/Default.lean`) runs another edit
in its place, for its key and for its menu item alike. Where the table has
no entry, the command of this module runs.

| State | `clipboard-copy` | `clipboard-cut` | `clipboard-paste` | `select-all` |
|---|---|---|---|---|
| `normal` | Gives up (`nothingSelected`) | Gives up (`nothingSelected`) | `"+P`: the clipboard's text before the cursor (`put-before`) | Enters `visual-line` and selects every line |
| `insert` | Gives up | Gives up | The clipboard's text at the bar, as typed text is inserted | Enters `visual-line` and selects every line, which ends the insert session |
| `visual`, `visual-line` | `"+y`: the selection to the clipboard, character-wise or line-wise as the state is, and normal state | `"+d`: the selection deleted into the clipboard, as one undoable change and the last change, and normal state | `"+` put in place of the selection (`replace`), and normal state; the replaced text goes to the unnamed register | Stays in or enters `visual-line` and selects every line |
| `minibuffer` | Gives up | Gives up | The clipboard's text at the bar, as typed text | Gives up (`noLineSelection`) |

- **The clipboard is written last.** Copy and Cut write it only through
  `store` (`Editor/Evil/Registers.lean`, "The clipboard is written last"),
  the last request of the operate command. A refused Copy or Cut gives up
  before any request, so it leaves the clipboard and the buffer as they
  were, and one stopped by the interrupt is rolled back before the write.
  A Cut with a clipboard that cannot be reached is `"+d`'s: it deletes,
  keeps the text in the unnamed register and says so in the echo area.
- **Paste and Select All never write the clipboard.** A Paste reads it
  first, before any edit, and gives up with `nothingToPut` or
  `clipboardUnavailable` having changed nothing.
- **Select All** leaves one range from offset 0 to the first non-blank of
  the last line (`lastLine`), both put where the state lets a cursor rest,
  in the line shape: what `ggVG` covers. The window keeps no wanted
  column.
- **A count or a register typed before a chord is dropped**: a run table's
  edit is used as written.
- **Text pasted in insert state is not typed text for dot repeat**: it is
  an invocation, not a key, so a `.` after the session replays the change
  without it.
- **Config overrides by chord everywhere.** A config command registered
  under one of these names runs in its place only where no run table
  rewrites the name.

Pinned by `ModelTest.clipboardCommandChecks`, by chord and by menu.
-/

namespace Editor.Evil

/-- The name of the command that cuts the selection to the clipboard. -/
def cutName : String :=
  "clipboard-cut"

/-- The name of the command that copies the selection to the clipboard. -/
def copyName : String :=
  "clipboard-copy"

/-- The name of the command that pastes the clipboard. -/
def pasteName : String :=
  "clipboard-paste"

/-- The name of the command that selects every line. -/
def selectAllName : String :=
  "select-all"

/-- What Copy and Cut give up with where nothing is selected. -/
def nothingSelected : String :=
  "nothing is selected"

/-- What Select All gives up with in a state that does not select lines. -/
def noLineSelection : String :=
  "no state here selects lines"

/-- Copy, where the state's run table has no entry for it: nothing is
selected there, so it gives up before any request. -/
def copy (_ : Call) : EditorM Unit :=
  giveUp nothingSelected

/-- Cut, where the state's run table has no entry for it: nothing is
selected there, so it gives up before any request. -/
def cut (_ : Call) : EditorM Unit :=
  giveUp nothingSelected

/-- Paste, where the state's run table has no entry for it: where the call's
report is exclusive, as in insert state and the minibuffer, the clipboard's
text is inserted at the head of each range, as typed text is; elsewhere it
is put before the cursor, as `"+P` puts it. It never writes the
clipboard. -/
def paste (call : Call) : EditorM Unit := do
  if call.report.shape == .exclusive then
    let register ← fetch clipboard
    call.target.insertAtSelections register.text
  else
    put false { call with arguments := [.nat 0, .str clipboard] }

/-- Select All: where the call's report selects lines, the selection becomes
one range of the line shape from offset 0 to the first non-blank of the last
line, each end put where the report lets a cursor rest, and the window keeps
no wanted column. In any other state it gives up (`noLineSelection`). -/
def selectAll (call : Call) : EditorM Unit := do
  unless call.report.selecting && call.report.shape == .line do
    giveUp noLineSelection
  let text := call.target.buffer.text
  let rest := restOf call.report
  let last ← text.motion .lineFirstNonBlank (← text.offsetOf ⟨← lastLine text, 0⟩)
  let anchor ← rested rest text 0
  let head ← rested rest text last
  call.target.select { ranges := #[⟨anchor, head⟩], shape := .line }
  discard <| call.target.window.id.setWanted none

end Editor.Evil
