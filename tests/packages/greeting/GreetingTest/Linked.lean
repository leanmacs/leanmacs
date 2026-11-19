import Editor.Command.Append
import Editor.Text.Real
import Greeting.EditorPackage

/-!
# The linked test of the package `greeting`

The root of an executable linked as the editor is linked, with the glue and
the Rust library (the core's `editorLinked` facet,
`lake build +GreetingTest.Linked:editorLinked`): the tests of the package
that need the real library. The gate builds it in `mise run lean` and runs
it in `mise run ffi-test` (`tools/package-set.sh`), in the package's
directory, with the toolchain's directory and the core's `.olean` directory
as its arguments, which a test that starts a config session needs. This one
starts none and only requires that the two are given.
-/

/-- A command over the text port: it makes a text of the package's
greeting, appends to it and reads it back. -/
def greet : Editor.TextM String := do
  let text ← Editor.createText Greeting.helloText
  Editor.append text "!"
  text.read

/-- Runs `greet` against the Rust library, through the text port's real
binding, and exits 0 when the text read back is the package's greeting with
the mark appended, 1 when it is not, and 2 for a command line that is not
the two directories. -/
def main (arguments : List String) : IO UInt32 := do
  if arguments.length != 2 then
    IO.eprintln "usage: GreetingTest-Linked <sysroot> <core olean dir>"
    return 2
  match (← greet.runReal (← Editor.RealTexts.new)).1 with
  | .ok text =>
    if text == Greeting.helloText ++ "!" then
      IO.println s!"greeting linked test: the Rust library holds {repr text}"
      return 0
    else
      IO.eprintln s!"FAILED: the text read back from the Rust library is {repr text}"
      return 1
  | .error refusal =>
    IO.eprintln s!"FAILED: the command was refused: {repr refusal}"
    return 1
