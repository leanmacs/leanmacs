import Editor.Config.Registry
import Editor.Evil
import Editor.Evil.Clipboard
import Editor.Evil.Jumps
import Editor.Evil.Motions
import Editor.Evil.Objects
import Editor.Evil.Operators
import Editor.Evil.Repeat
import Editor.Evil.Scroll
import Editor.Evil.TreeObjects
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
  | `operate` (`Vim.operateCommand`) | `Evil.operate` over the compiled vocabulary, `Evil.operators`, `Evil.motions` and `Evil.objects` (`Editor/Evil/Operators.lean`) |
  | `select-object` (`Vim.selectObjectCommand`) | `Evil.selectObject` over `Evil.objects`, Vim's objects and the syntax tree's: a visual selection set to a text object (`Editor/Evil/Objects.lean`, `Editor/Evil/TreeObjects.lean`) |
  | `delete-char` | `Evil.deleteChar`: the cell under the cursor, which is the operator `delete` over the motion `right` |
  | `put-after`, `put-before` | `Evil.putAfter`, `Evil.putBefore`: the register the call names, after and before the cursor (`Editor/Evil/Registers.lean`) |
  | `open-below`, `open-above` | `Evil.openBelow`, `Evil.openAbove`: an empty line below and above the cursor's, and an insert on it |
  | `undo`, `redo` | `Evil.undo`, `Evil.redo`: steps of the buffer's history, with the cursor placed (`Editor/Evil/Undo.lean`) |
  | `repeat` (`Vim.repeatCommand`) | `Evil.repeat`: the last change again, by the command the registry holds for the name the change compiled to, with the text typed after it (`Editor/Evil/Repeat.lean`) |
  | `scroll-down`, `scroll-up` | `Evil.scroll .half`, down and up: the view and its cursor by half the rows the view fits, or by the count (`Editor/Evil/Scroll.lean`) |
  | `scroll-page-down`, `scroll-page-up` | `Evil.scroll .page`, down and up: the view and its cursor by the rows the view fits |
  | `scroll-line-to-top`, `scroll-line-to-center`, `scroll-line-to-bottom` | `Evil.scrollLineTo`, with `.top`, `.middle` and `.bottom`: the view placed so that the cursor's row is the first row shown, the middle one or the last, with nothing else changed |
  | `insert-delete-backward`, `insert-delete-word-backward`, `insert-newline`, `insert-tab` | `Evil.deleteBackward`, `Evil.deleteWordBackward`, `Evil.newline`, `Evil.insertTab`: insert state's `<Backspace>`, `C-w`, `RET` and `TAB` (`Editor/Evil.lean`, "Editing keys") |
  | `insert-left`, `insert-right`, `insert-up`, `insert-down` | `Evil.insertMove` over `Evil.motions`, by the motions `left`, `right`, `up` and `down`: insert state's arrow keys, each a move that starts a new step of the history once it moved |
  | `clipboard-cut`, `clipboard-copy` (`Evil.cutName`, `Evil.copyName`) | `Evil.cut`, `Evil.copy`: they give up, nothing being selected, where no run table runs `"+d` or `"+y` in their place (`Editor/Evil/Clipboard.lean`) |
  | `clipboard-paste` (`Evil.pasteName`) | `Evil.paste`: the clipboard's text at the bar where the call's report is exclusive, and before the cursor otherwise |
  | `select-all` (`Evil.selectAllName`) | `Evil.selectAll`: every line selected, where the call's report selects lines |
  | `jump-backward`, `jump-forward` | `Evil.jumpBackward`, `Evil.jumpForward`: Vim's `C-o` and `C-i`, a step back or on through the window's jump list by the count (`Editor/Evil/Jumps.lean`) |

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
which is the config session's: `Editor.lean` imports the commands, the
motions (`Editor/Evil/Motions.lean`) and the text objects
(`Editor/Evil/Objects.lean`), so that config can call them, and not this, which is the one module of evil's it leaves out.

Pinned by `ModelTest.evilMotionChecks`, `ModelTest.evilStateChecks` and
`ModelTest.evilInsertChecks`, on the models, the scroll commands by
`ModelTest.viewChecks`, and the clipboard commands by
`ModelTest.clipboardCommandChecks`.
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
    { name := Vim.operateCommand, action := .call (operate operators motions objects) },
    { name := Vim.selectObjectCommand, action := .call (selectObject objects) },
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
    { name := "scroll-page-up", action := .call (scroll .page false) },
    { name := "scroll-line-to-top", action := .call (scrollLineTo .top) },
    { name := "scroll-line-to-center", action := .call (scrollLineTo .middle) },
    { name := "scroll-line-to-bottom", action := .call (scrollLineTo .bottom) },
    { name := "insert-delete-backward", action := .call deleteBackward },
    { name := "insert-delete-word-backward", action := .call deleteWordBackward },
    { name := "insert-newline", action := .call newline },
    { name := "insert-tab", action := .call insertTab },
    { name := "insert-left", action := .call (insertMove motions left.name) },
    { name := "insert-right", action := .call (insertMove motions right.name) },
    { name := "insert-up", action := .call (insertMove motions up.name) },
    { name := "insert-down", action := .call (insertMove motions down.name) },
    { name := cutName, action := .call cut }, { name := copyName, action := .call copy },
    { name := pasteName, action := .call paste },
    { name := selectAllName, action := .call selectAll },
    { name := "jump-backward", action := .call jumpBackward },
    { name := "jump-forward", action := .call jumpForward }]

end Editor.Evil
