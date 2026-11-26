/-!
# A tool call's diff, as the conversation shows it

The change a diff makes, as lines of text (`Acp.Conversation.diffLines`):
the lines the old and the new text share at their start and at their end
are dropped, but for two of each kept as context (`context`), each written
after two spaces; then each old line of the middle written after `- `, and
each new line after `+ `. A text's lines are split at line feeds; a last
line with no line feed after it is followed by the row `\ no line feed at
end`, so a text that differs from another only there shows it. An old text
of none is a new file: every line is new. Equal texts show no line.

It is pure and linear, and fits what the adapter sends: before a tool runs
its diff holds only the edit's own strings, and afterwards the whole file
(`docs/design/agent-hosting.md`, "The ACP spike"), whose change is one run
of lines. A hunked review is the review interface's later work. The core's
line diff (`Editor.Diff.Model`) is a test double, which a library may not
use, and the diff service takes snapshots, not strings.
-/

namespace Acp.Conversation

/-- How many lines of context are kept on each side of a change. -/
def context : Nat :=
  2

/-- The row that follows a last line with no line feed after it. -/
def noLineFeed : String :=
  "\\ no line feed at end"

/-- The lines of `text`, each with whether a line feed ends it. -/
def linesOf (text : String) : Array (String × Bool) :=
  let parts := (text.splitOn "\n").toArray
  -- A text that ends in a line feed splits into an empty last part.
  if text.isEmpty then #[]
  else
    if text.endsWith "\n" then (parts.pop).map ((·, true))
    else (parts.pop.map ((·, true))).push ((parts.back?.getD ""), false)

/-- How many items `old` and `new` share at their start. -/
def sharedStart (old new : Array (String × Bool)) : Nat :=
  ((List.range (min old.size new.size)).find? fun index => old[index]? != new[index]?).getD
    (min old.size new.size)

/-- A line written after `mark`, followed by the row for a missing line feed
when it has none. -/
def marked (mark : String) (line : String × Bool) : Array String :=
  if line.2 then #[mark ++ line.1] else #[mark ++ line.1, noLineFeed]

/-- The change from `old`, none for a new file, to `new`, as lines (the
module docs). -/
def diffLines (old : Option String) (new : String) : Array String :=
  let before := linesOf (old.getD "")
  let after := linesOf new
  let start := sharedStart before after
  -- The shared end, counted from the end, never reaching into the shared start.
  let room := min before.size after.size - start
  let finish := sharedStart (before.reverse.extract 0 room) (after.reverse.extract 0 room)
  if start == before.size && start == after.size then #[]
  else
    let leading := before.extract (start - min start context) start
    let removed := before.extract start (before.size - finish)
    let added := after.extract start (after.size - finish)
    let trailing := after.extract (after.size - finish) (after.size - finish + min finish context)
    leading.flatMap (marked "  ") ++ removed.flatMap (marked "- ") ++ added.flatMap (marked "+ ") ++
      trailing.flatMap (marked "  ")

end Acp.Conversation
