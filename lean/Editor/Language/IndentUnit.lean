/-!
# One level of indentation

A language's indent unit (`Language.indentUnit`, `Editor/Language.lean`): a
number of spaces, or a tab. It is a module of its own, importing nothing,
so that the state requests (`Editor/State/Request.lean`), which a command
asks the loop for a language's unit with (`indentUnitOf`), name it without
importing the language table, which imports the commands
(`Language → Mode → Command → State.Request`).

Read by `=` and by the commands that open a line
(`Editor/Indent.lean`, `Indent.whitespace`), through `Target.indentUnit`
(`Editor/Api.lean`).
-/

namespace Editor

/-- One level of a language's indentation. -/
inductive Language.IndentUnit where
  /-- This many spaces. -/
  | spaces (count : Nat)
  /-- One tab. -/
  | tab
  deriving DecidableEq, Repr

/-- The unit of an entry that says none, and of a buffer whose language the
table has no entry of: four spaces. -/
def Language.IndentUnit.default : Language.IndentUnit :=
  .spaces 4

end Editor
