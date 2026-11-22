import Editor.Package
import Evil
import Evil.Clipboard
import Evil.Jumps
import Evil.Motions
import Evil.Objects
import Evil.Operators
import Evil.Repeat
import Evil.Scroll
import Evil.TreeObjects
import Evil.Undo
import Evil.Vim
import Evil.Vim.Default
import EvilApi

/-!
# The `evil` package: evil's commands

What a host registers so that the Vim scheme's keys do something
(`Evil.lean`): the package `evil` (`Evil.package`,
`Editor/Package.lean`), whose `setup` registers the commands the scheme's
invocations name. A host registers it for the owner `evil` when its loop
starts, before any config (`Editor/Config/Packages.lean`), so they hold
when config fails to load, and a reload does not replace them.

- **The commands**, each a command that is given what it was called with
  (`commandWith`):

  | Name | Runs |
  |---|---|
  | `move` (`Vim.moveCommand`) | `Evil.move` over the compiled vocabulary, `Evil.motions` |
  | `normal`, `visual`, `visual-line` | `Evil.enter`, one function for the three: it reads the state it enters from its call's report |
  | `insert`, `append`, `insert-line-start`, `append-line-end` | `Evil.insert`, `Evil.append`, `Evil.insertLineStart`, `Evil.appendLineEnd`: an insert before the cursor's cell, after it, at the line's first character that is not a blank, and at the line's end |
  | `self-insert` (`Vim.selfInsertCommand`) | `Evil.selfInsert`: typed text, in insert state and in the minibuffer |
  | `operate` (`Vim.operateCommand`) | `Evil.operate` over the compiled vocabulary, `Evil.operators`, `Evil.motions` and `Evil.objects` (`Evil/Operators.lean`) |
  | `select-object` (`Vim.selectObjectCommand`) | `Evil.selectObject` over `Evil.objects`, Vim's objects and the syntax tree's: a visual selection set to a text object (`Evil/Objects.lean`, `Evil/TreeObjects.lean`) |
  | `delete-char` | `Evil.deleteChar`: the cell under the cursor, which is the operator `delete` over the motion `right` |
  | `put-after`, `put-before` | `Evil.putAfter`, `Evil.putBefore`: the register the call names, after and before the cursor (`Evil/Registers.lean`) |
  | `open-below`, `open-above` | `Evil.openBelow`, `Evil.openAbove`: an empty line below and above the cursor's, and an insert on it |
  | `undo`, `redo` | `Evil.undo`, `Evil.redo`: steps of the buffer's history, with the cursor placed (`Evil/Undo.lean`) |
  | `repeat` (`Vim.repeatCommand`) | `Evil.repeat`: the last change again, by the command the registry holds for the name the change compiled to, with the text typed after it (`Evil/Repeat.lean`) |
  | `scroll-down`, `scroll-up` | `Evil.scroll .half`, down and up: the view and its cursor by half the rows the view fits, or by the count (`Evil/Scroll.lean`) |
  | `scroll-page-down`, `scroll-page-up` | `Evil.scroll .page`, down and up: the view and its cursor by the rows the view fits |
  | `scroll-line-to-top`, `scroll-line-to-center`, `scroll-line-to-bottom` | `Evil.scrollLineTo`, with `.top`, `.middle` and `.bottom`: the view placed so that the cursor's row is the first row shown, the middle one or the last, with nothing else changed |
  | `insert-delete-backward`, `insert-delete-word-backward`, `insert-newline`, `insert-tab` | `Evil.deleteBackward`, `Evil.deleteWordBackward`, `Evil.newline`, `Evil.insertTab`: insert state's `<Backspace>`, `C-w`, `RET` and `TAB` (`Evil.lean`, "Editing keys") |
  | `insert-left`, `insert-right`, `insert-up`, `insert-down` | `Evil.insertMove` over `Evil.motions`, by the motions `left`, `right`, `up` and `down`: insert state's arrow keys, each a move that starts a new step of the history once it moved |
  | `clipboard-cut`, `clipboard-copy` (`Evil.cutName`, `Evil.copyName`) | `Evil.cut`, `Evil.copy`: they give up, nothing being selected, where no run table runs `"+d` or `"+y` in their place (`Evil/Clipboard.lean`) |
  | `clipboard-paste` (`Evil.pasteName`) | `Evil.paste`: the clipboard's text at the bar where the call's report is exclusive, and before the cursor otherwise |
  | `select-all` (`Evil.selectAllName`) | `Evil.selectAll`: every line selected, where the call's report selects lines |
  | `set-mark` | `Evil.setMark`: Vim's `m`, the mark its first argument, a character, names, set at the cursor (`Evil/Marks.lean`) |
  | `jump-backward`, `jump-forward` | `Evil.jumpBackward`, `Evil.jumpForward`: Vim's `C-o` and `C-i`, a step back or on through the window's jump list by the count (`Evil/Jumps.lean`) |

  The seven of the second and third rows enter a state only when a key
  that enters it runs them: the scheme enters the state, at the key, and
  the command reshapes the selection for the state it is told of. Run by
  its name, each is told of the state the view is already in and enters
  none (`Evil.lean`, "Entering a state").

Four of the names are the interface package `evil-api`'s
(`packages/evil-api/EvilApi.lean`), which declares what another package
reaches of evil by name: `insert-newline` and `insert-tab`, which
completion at point runs with no session open, and `undo` and `redo`, which
the Edit menu runs. They are registered under its constants, and
`EvilTest.evilPackageChecks` holds this package to its contract.

A name here and the name the Vim scheme's default tables give a key
(`Evil/Vim/Default.lean`) are changed together: the scheme
yields an invocation of a name, and this is where the name is given a
command.

This module is apart from `Evil.lean` because it is what a host is
handed, not what config calls: `Editor.lean` imports the commands, the
motions (`Evil/Motions.lean`) and the text objects
(`Evil/Objects.lean`), so that config can call them, and not this, which is the one module of evil's it leaves out.

## The scheme

`Evil.scheme` is the input scheme this feature supplies an editor: the Vim
scheme over its default states and bindings (`Vim.Default.scheme`), named
`vim`, as a `SchemePackage` (`Editor/InputScheme.lean`, "The scheme a
package supplies"). The entry module of the Lake package that holds evil
declares it as its `scheme`. It is here, beside `package`, and not in the
entry module: an entry module imports package modules and nothing else
(`tools/host-imports-check.sh`), and this is the package module that
imports the default tables.

Pinned by `EvilTest.evilMotionChecks`, `EvilTest.evilStateChecks` and
`EvilTest.evilInsertChecks`, on the models, the scroll commands by
`EvilTest.evilScrollChecks`, and the clipboard commands by
`EvilTest.clipboardCommandChecks`.
-/

namespace Editor.Evil

/-- The package `evil`: evil's commands, under the names the Vim scheme's
default tables give its keys. -/
def package : Package :=
  { name := "evil"
    setup := do
      commandWith Vim.moveCommand (move motions)
      commandWith "normal" enter
      commandWith "visual" enter
      commandWith "visual-line" enter
      commandWith "insert" insert
      commandWith "append" append
      commandWith "insert-line-start" insertLineStart
      commandWith "append-line-end" appendLineEnd
      commandWith Vim.selfInsertCommand selfInsert
      commandWith Vim.operateCommand (operate operators motions objects)
      commandWith Vim.selectObjectCommand (selectObject objects)
      commandWith "delete-char" deleteChar
      commandWith "put-after" putAfter
      commandWith "put-before" putBefore
      commandWith "open-below" openBelow
      commandWith "open-above" openAbove
      commandWith EvilApi.undoName undo
      commandWith EvilApi.redoName redo
      commandWith Vim.repeatCommand «repeat»
      commandWith "scroll-down" (scroll .half true)
      commandWith "scroll-up" (scroll .half false)
      commandWith "scroll-page-down" (scroll .page true)
      commandWith "scroll-page-up" (scroll .page false)
      commandWith "scroll-line-to-top" (scrollLineTo .top)
      commandWith "scroll-line-to-center" (scrollLineTo .middle)
      commandWith "scroll-line-to-bottom" (scrollLineTo .bottom)
      commandWith "insert-delete-backward" deleteBackward
      commandWith "insert-delete-word-backward" deleteWordBackward
      commandWith EvilApi.insertNewlineName newline
      commandWith EvilApi.insertTabName insertTab
      commandWith "insert-left" (insertMove motions left.name)
      commandWith "insert-right" (insertMove motions right.name)
      commandWith "insert-up" (insertMove motions up.name)
      commandWith "insert-down" (insertMove motions down.name)
      commandWith cutName cut
      commandWith copyName copy
      commandWith pasteName paste
      commandWith selectAllName selectAll
      commandWith "jump-backward" jumpBackward
      commandWith "jump-forward" jumpForward
      commandWith "set-mark" setMark }

/-- The input scheme evil supplies: the Vim scheme over its default states
and bindings ("The scheme", in the module docs). -/
def scheme : SchemePackage :=
  { name := "vim", scheme := Vim.Default.scheme }

end Editor.Evil
