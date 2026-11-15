import Editor.Config.Registry
import Editor.Evil
import Editor.Evil.Motions
import Editor.Evil.Operators
import Editor.Evil.Repeat
import Editor.Evil.Scroll
import Editor.Evil.Undo
import Editor.InputScheme.Vim

/-!
# Evil's commands, as compiled code registers them

What a host is handed so that the Vim scheme's keys do something
(`Editor/Evil.lean`): the registrations of the commands its invocations
name. A host registers them for the owner `compiled` when its loop starts,
before any config (`Editor/Config/Registry.lean`, "Compiled commands"), so
they hold when config fails to load, and a reload does not replace them.

- **`Evil.commands`**, each a command that is given what it was called with
  (`Action.call`):

  | Name | Runs |
  |---|---|
  | `move` (`Vim.moveCommand`) | `Evil.move` over the compiled vocabulary, `Evil.motions` |
  | `normal`, `visual`, `visual-line` | `Evil.enter`, one function for the three: it reads the state it enters from its call's report |
  | `insert`, `append`, `insert-line-start`, `append-line-end` | `Evil.insert`, `Evil.append`, `Evil.insertLineStart`, `Evil.appendLineEnd`: an insert before the cursor's cell, after it, at the line's first character that is not a blank, and at the line's end |
  | `self-insert` (`Vim.selfInsertCommand`) | `Evil.selfInsert`: typed text, in insert state and in the minibuffer |
  | `operate` (`Vim.operateCommand`) | `Evil.operate` over the compiled vocabulary, `Evil.operators` and `Evil.motions` (`Editor/Evil/Operators.lean`) |
  | `delete-char` | `Evil.deleteChar`: the cell under the cursor, which is the operator `delete` over the motion `right` |
  | `put-after`, `put-before` | `Evil.putAfter`, `Evil.putBefore`: the register the call names, after and before the cursor (`Editor/Evil/Registers.lean`) |
  | `open-below`, `open-above` | `Evil.openBelow`, `Evil.openAbove`: an empty line below and above the cursor's, and an insert on it |
  | `undo`, `redo` | `Evil.undo`, `Evil.redo`: steps of the buffer's history, with the cursor placed (`Editor/Evil/Undo.lean`) |
  | `repeat` (`Vim.repeatCommand`) | `Evil.repeat`: the last change again, by the command the registry holds for the name the change compiled to, with the text typed after it (`Editor/Evil/Repeat.lean`) |
  | `scroll-down`, `scroll-up` | `Evil.scroll .half`, down and up: the view and its cursor by half the rows the view fits, or by the count (`Editor/Evil/Scroll.lean`) |
  | `scroll-page-down`, `scroll-page-up` | `Evil.scroll .page`, down and up: the view and its cursor by the rows the view fits |

  The seven of the second and third rows enter a state only when a key
  that enters it runs them: the scheme enters the state, at the key, and
  the command reshapes the selection for the state it is told of. Run by
  its name, each is told of the state the view is already in and enters
  none (`Editor/Evil.lean`, "Entering a state").

A name here and the name the Vim scheme's default tables give a key
(`Editor/InputScheme/Vim/Default.lean`) are changed together: the scheme
yields an invocation of a name, and this is where the name is given a
command.

This module is apart from `Editor/Evil.lean` because it names the registry,
which is the config session's: `Editor.lean` imports the commands and the
motions (`Editor/Evil/Motions.lean`), so that config can call them, and
not this, which is the one module of evil's it leaves out.

Pinned by `ModelTest.evilMotionChecks`, `ModelTest.evilStateChecks` and
`ModelTest.evilInsertChecks`, on the models, and the scroll commands by
`ModelTest.viewChecks`.
-/

namespace Editor.Evil

/-- Evil's commands, as a host registers them for the owner `compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := Vim.moveCommand, action := .call (move motions) },
    { name := "normal", action := .call enter }, { name := "visual", action := .call enter },
    { name := "visual-line", action := .call enter }, { name := "insert", action := .call insert },
    { name := "append", action := .call append },
    { name := "insert-line-start", action := .call insertLineStart },
    { name := "append-line-end", action := .call appendLineEnd },
    { name := Vim.selfInsertCommand, action := .call selfInsert },
    { name := Vim.operateCommand, action := .call (operate operators motions) },
    { name := "delete-char", action := .call deleteChar },
    { name := "put-after", action := .call putAfter },
    { name := "put-before", action := .call putBefore },
    { name := "open-below", action := .call openBelow },
    { name := "open-above", action := .call openAbove }, { name := "undo", action := .call undo },
    { name := "redo", action := .call redo },
    { name := Vim.repeatCommand, action := .call «repeat» },
    { name := "scroll-down", action := .call (scroll .half true) },
    { name := "scroll-up", action := .call (scroll .half false) },
    { name := "scroll-page-down", action := .call (scroll .page true) },
    { name := "scroll-page-up", action := .call (scroll .page false) }]

end Editor.Evil
