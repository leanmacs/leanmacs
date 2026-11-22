/-!
# The interface package `evil-api`

The interface package of evil (`docs/design/extension-points.md`, "Three
layers"): the contract between the default package `evil`, which
implements it, and whatever reaches evil's commands by their names. A name
another package reaches is part of the contract a replacement must keep,
so it is declared here, in the interface package, and a reacher names the
constant, never the text ("Reaches by name"):

- completion at point (`packages/at-point/AtPoint.lean`) runs
  `insert-newline` and `insert-tab` when its `RET` and `TAB` find no
  session open, and names `insertNewlineName` and `insertTabName`;
- the Edit menu's Undo and Redo, and `s-z` and `s-Z`
  (`packages/menu/Menu/Compiled.lean`), run `undo` and `redo`: the default
  package `menu` requires this package and names `undoName` and
  `redoName`. The core's own at-point stand-in
  (`lean/Editor/Test/AtPoint.lean`) names the first two as text, since the
  core cannot import a package.

It registers no behaviour. A package that supplies another input scheme
implements it to answer those reaches in evil's place.

Its test library publishes a fake (`EvilApiTest.fake`) and the contract
check every implementation runs (`EvilApiTest.contractChecks`).
-/

namespace EvilApi

/-- The name the command that breaks the line at the selections, where
typing is text, is registered under. -/
def insertNewlineName : String :=
  "insert-newline"

/-- The name the command that types a tab at the selections, where typing
is text, is registered under. -/
def insertTabName : String :=
  "insert-tab"

/-- The name the command that undoes a step of the buffer's history is
registered under. -/
def undoName : String :=
  "undo"

/-- The name the command that redoes a step of the buffer's history is
registered under. -/
def redoName : String :=
  "redo"

/-- Every name this interface declares: the names an implementation must
register, which the contract check holds it to. -/
def names : Array String :=
  #[insertNewlineName, insertTabName, undoName, redoName]

end EvilApi
