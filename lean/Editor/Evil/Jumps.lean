import Editor.Evil
import Editor.Jumps.Go

/-!
# Evil: `C-o` and `C-i`

Vim's `CTRL-O` and `CTRL-I` (`:help jumplist`) as evil's commands: a step
back or on through the window's jump list (`Jumps.move`,
`Editor/Jumps/Go.lean`) by the call's count, 1 when it has none. The rules
of the list are `Editor/JumpList.lean`'s and `Editor/Jumps.lean`'s; the
motions that record a jump say so themselves (`Vocabulary.Motion.jumps`).

- **A step that fails does nothing and says nothing**, where Vim beeps: at
  either end of the list, and with an empty one.
- **The cursor rests where the call's report says** once the step lands in
  an open buffer, as after a move (`Evil.settle`). A step onto a closed
  file's entry puts the cursor at its row and column when the load is
  delivered.

Pinned by `ModelTest.evilJumpChecks`.
-/

namespace Editor.Evil

/-- Steps the call's window by `n` times the call's count, 1 when it has
none, through its jump list, and rests the cursor where it lands. -/
def jump (n : Int) (call : Call) : EditorM Unit := do
  let view := call.target.window.id
  let count := max 1 (countOf call)
  unless ← Jumps.move view (n * count) do
    return
  let .ok target ← view.target | return
  let selection ← target.selection
  let some range := selection.ranges[selection.primary]? | return
  settle { call with target } range.head

/-- Vim's `CTRL-O`: back through the window's jump list by the count. -/
def jumpBackward (call : Call) : EditorM Unit :=
  jump (-1) call

/-- Vim's `CTRL-I`: on through the window's jump list by the count. -/
def jumpForward (call : Call) : EditorM Unit :=
  jump 1 call

end Editor.Evil
