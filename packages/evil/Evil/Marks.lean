import Editor.Command.Call
import Editor.Jumps
import Editor.Vocabulary

/-!
# Evil: marks

Vim's marks (`:help mark-motions`): `m` sets one, and `` ` `` and `'` go to
one, as evil's command and two motions. Where a mark is kept is the editor
state's (`Editor/State.lean`, "The jump list and marks"); the places are
held by markers, so a mark follows the edits made before it; a mark whose
line is deleted is erased, and undo and redo put the lowercase marks back
(`Editor/Marks.lean`).

- **Setting a mark** (`setMark`, `set-mark`, the character first in its
  arguments): `a` to `z` sets a mark of the buffer the call's window shows,
  `A` to `Z` a global mark, which remembers its buffer and, once that
  buffer is closed, its file (`Jumps.detach`), and `'` or `` ` `` the
  previous-context mark, which is a record of a jump (`Jumps.record`,
  Vim's `setpcmark`), so it also appends to the jump list. Setting a mark
  is no jump. Any other character says `badMarkName`, Vim's E191.
- **Going to a mark** (`markExact`, `mark-exact`, `` ` ``, and `markLine`,
  `mark-line`, `'`): to the mark's exact position, taken exclusively by an
  operator, or to the first non-blank of its line, taken as whole lines.
  `''` and ``` `` ``` go to the previous-context mark of the motion's
  window (`Vocabulary.From.view`), and a lowercase mark is the motion's
  buffer's (`From.buffer`). Both are jumps (`Vocabulary.Motion.jumps`), so
  repeating `''` goes back and forth between two places.
- **A mark not set** says `markNotSet` (E20), and a character that names
  no mark `unknownMark` (E78); the motion fails, so an operator is given up.
- **A global mark in another buffer, or in a closed file** leads out of
  the text (`Vocabulary.To.elsewhere`): with no operator, the move command
  goes there as a jump; under an operator the motion fails with
  `markNotSet`, as Vim's `getmark_buf_fnum` gives no line there. The
  previous-context mark, held in another buffer, is gone to the same way.

Pinned by `EvilTest.evilMarkChecks`.
-/

namespace Editor.Evil

/-- What a mark motion says for a mark that is not set: Vim's E20. -/
def markNotSet : String :=
  "E20: Mark not set"

/-- What a mark motion says for a character that names no mark: Vim's
E78. -/
def unknownMark : String :=
  "E78: Unknown mark"

/-- What `m` says for a character that names no mark it sets: Vim's
E191. -/
def badMarkName : String :=
  "E191: Argument must be a letter or forward/backward quote"

/-- Whether `char` names the previous-context mark: `'` or `` ` ``. -/
def isContextMark (char : Char) : Bool :=
  char == '\'' || char == '`'

/-- The place of the mark the argument of `origin` names, if it is set
("Going to a mark", in the module docs); `unknownMark` for an argument that
names no mark. -/
def markPlace (origin : Vocabulary.From) : EditorM (Except String (Option Place)) := do
  let state ← editorState
  let some argument := origin.argument | return .error unknownMark
  let [char] := argument.toList | return .error unknownMark
  if isContextMark char then
    return .ok ((state.window? origin.view).bind (·.jumps.previous))
  else
    if char.isLower then
      return .ok ((state.localMark? origin.buffer char).map (.held origin.buffer ·))
    else if char.isUpper then
      return .ok (state.globalMark? char)
    else
      return .error unknownMark

/-- Where the mark motion leads in `text` from `origin`: the mark's position,
or the first non-blank of its line with `line`; out of the text to a place
of another buffer or a file; and a failure, where it is, with E20 or E78
("Going to a mark", in the module docs). -/
def markTarget (line : Bool) (text : TextId) (origin : Vocabulary.From) : EditorM Vocabulary.To :=
  do
  let failed (said : String) : Vocabulary.To :=
    { head := origin.head, failed := true, said := some said }
  match ← markPlace origin with
  | .error said =>
    return failed said
  | .ok none =>
    return failed markNotSet
  | .ok (some place) =>
    match place with
    | .held buffer marker =>
      if buffer == origin.buffer && marker.text == text then
        let offset ← Marks.offsetOf marker
        return {
            head :=
              ←
                if line then
                  text.motion .lineFirstNonBlank offset
                else
                  pure offset }
      else
        return { head := origin.head, elsewhere := some { place, line } }
    | .file .. =>
      return { head := origin.head, elsewhere := some { place, line } }

/-- The mark motion called `name`, taken by an operator as `reach`: to the
mark's position, or with `line` its line's first non-blank. Under an
operator a mark out of the text fails with `markNotSet`. -/
def markMotion (name : String) (line : Bool) (reach : Vocabulary.Reach) : Vocabulary.Motion :=
  { name
    reach
    jumps := true
    target := markTarget line
    taken := fun _ text origin => do
      let to ← markTarget line text origin
      if to.elsewhere.isSome then
        return { head := origin.head, reach, failed := true, said := some markNotSet }
      return { head := to.head, reach, failed := to.failed, said := to.said } }

/-- Vim's `` ` ``: to the mark's exact position, taken exclusively. -/
def markExact : Vocabulary.Motion :=
  markMotion "mark-exact" false .exclusive

/-- Vim's `'`: to the first non-blank of the mark's line, taken as whole
lines. -/
def markLine : Vocabulary.Motion :=
  markMotion "mark-line" true .lines

/-- Vim's `m` ("Setting a mark", in the module docs): sets the mark the
call's first argument, a character, names, at the head of the call's
window's cursor. -/
def setMark (call : Call) : EditorM Unit := do
  let view := call.target.window.id
  let chars :=
    match call.arguments with
    | .str argument :: _ => argument.toList
    | _ => []
  let [char] := chars | message badMarkName
  if isContextMark char then
    Jumps.record view
  else
    if char.isLower || char.isUpper then
      let some place ← Jumps.here view | return
      if char.isLower then
        if let .held buffer marker := place then
          discard <| buffer.setMark char (some marker)
      else
        discard <| setGlobalMark char (some place)
    else
      message badMarkName

end Editor.Evil
