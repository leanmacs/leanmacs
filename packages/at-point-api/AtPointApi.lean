import Editor.Completion.AtPoint

/-!
# The interface package `at-point-api`

The interface package of completion at point's commands
(`docs/design/extension-points.md`, "Three layers"): the contract between
the default package `at-point`, which implements it, and whatever reaches
one of its commands by name. A name another package reaches is part of the
contract a replacement must keep, so it is declared here, in the interface
package, and a reacher names the constant, never the text ("Reaches by
name"). The reached names are nine:

- the seven the Vim scheme's insert table binds (the core's
  `packages/evil/Evil/Vim/Default.lean`, `insertCommands`):
  `at-point-complete`, `-next`, `-previous`, `-tab`, `-backtab`, `-return`
  and `-quit`. The core cannot import a package, so it names them as text;
- the two the core runs by itself, whose names are the core's
  (`Completion.AtPoint.triggeredCommand`, `.pausedCommand`, the core's
  `lean/Editor/Completion/AtPoint.lean`): the loop runs the first when a
  typed character is an at-point source's trigger, and the headless host
  and the loop's driver the second when a pause fires. They are declared
  from those constants.

It registers no behaviour.

Its test library publishes a fake (`AtPointApiTest.fake`, the core's test
kit's implementation) and the contract check every implementation runs
(`AtPointApiTest.contractChecks`).
-/

namespace AtPointApi

/-- The name of the command that asks: `C-SPC` in insert state. -/
def completeName : String :=
  "at-point-complete"

/-- The name of the command that moves the choice down, or asks: `C-n`. -/
def nextName : String :=
  "at-point-next"

/-- The name of the command that moves the choice up, or asks: `C-p`. -/
def previousName : String :=
  "at-point-previous"

/-- The name of `TAB`'s command in insert state. -/
def tabName : String :=
  "at-point-tab"

/-- The name of `S-TAB`'s command in insert state. -/
def backtabName : String :=
  "at-point-backtab"

/-- The name of `RET`'s command in insert state. -/
def returnName : String :=
  "at-point-return"

/-- The name of `C-g`'s command in insert state. -/
def quitName : String :=
  "at-point-quit"

/-- The name of the command the loop runs on a typed trigger: the core's
(`Completion.AtPoint.triggeredCommand`). -/
def triggeredName : String :=
  Editor.Completion.AtPoint.triggeredCommand

/-- The name of the command a pause that fired runs: the core's
(`Completion.AtPoint.pausedCommand`). -/
def pausedName : String :=
  Editor.Completion.AtPoint.pausedCommand

/-- Every name this interface declares, in the order the implementation
registers them: the names an implementation must register a command
under, which the contract check holds it to. -/
def names : Array String :=
  #[completeName, nextName, previousName, tabName, backtabName, returnName, quitName, triggeredName,
    pausedName]

end AtPointApi
