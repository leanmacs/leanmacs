import Editor
import Editor.Command.Append
import Editor.Headless
import Editor.Text.Real
import EditorCore.EditorPackage
import Greeting.EditorPackage

/-!
# The linked test of the package `greeting`

The root of an executable linked as the editor is linked, with the glue and
the Rust library (the core's `editorLinked` facet,
`lake build +GreetingTest.Linked:editorLinked`): the tests of the package
that need the real library. The gate builds it in `mise run lean` and runs
it in `mise run ffi-test` (`tools/package-set.sh`), in the package's
directory, with the toolchain's directory and the core's `.olean` directory
as its arguments.

It is one executable for both of what the core has two for
(`docs/design/packages.md`, "A package's tests and the gate's steps over
them"), and holds a check of each kind:

- **Against the Rust library**, as `ffi-test` and `contract-test` are the
  core's: a command over the text port's real binding (`libraryCheck`).
- **Of a config session on the real elaborator**, as `config-test` is the
  core's: the headless host, handed the packages a set that holds this
  package hands its editor, loads a config directory that binds a key to
  the package's command, and the key runs it (`configCheck`). The two
  directories it is handed are what that session elaborates on.

It imports the config base, `Editor`, for the link alone, as every root
that links the elaborator does: the elaborator imports the base's modules
from their `.olean` files at runtime, and each must already be linked into
the executable.
-/

/-- A command over the text port: it makes a text of the package's
greeting, appends to it and reads it back. -/
def greet : Editor.TextM String := do
  let text ← Editor.createText Greeting.helloText
  Editor.append text "!"
  text.read

/-- Runs `greet` against the Rust library, through the text port's real
binding: whether the text read back is the package's greeting with the
mark appended. It says what it found. -/
def libraryCheck : IO Bool := do
  match (← greet.runReal (← Editor.RealTexts.new)).1 with
  | .ok text =>
    if text == Greeting.helloText ++ "!" then
      IO.println s!"greeting linked test: the Rust library holds {repr text}"
      return true
    else
      IO.eprintln s!"FAILED: the text read back from the Rust library is {repr text}"
      return false
  | .error refusal =>
    IO.eprintln s!"FAILED: the command was refused: {repr refusal}"
    return false

/-- The packages a set that holds this Lake package hands its editor: the
core's, which this package requires, then its own, the order the
package-set build registers them in. -/
def setPackages : Array Editor.Package :=
  EditorCore.EditorPackage.packages ++ Greeting.EditorPackage.packages

/-- The config directory `configCheck` loads, from the package's directory,
where the gate runs this executable. -/
def configDirectory : String :=
  "tests/linked/config"

/-- The script `configCheck` runs: it loads the config, sends the keys the
config binds to the package's command, and asks for the scene. -/
def configScript : String :=
  "reload\nsettle\nkey c KeyC control\nkey g KeyG -\nscene\n"

/-- Starts the headless host over `setPackages` with the real elaborator,
the toolchain in `sysroot` and the core's `.olean` files in `oleans`, runs
`configScript` on the config in `configDirectory`, and says whether the
script ran to its end and a line of what the host printed holds the
package's greeting: config's key ran the package's command, so the session
elaborated config that names it and the host had registered it. -/
def configCheck (sysroot oleans : String) : IO Bool := do
  let printed ← IO.mkRef (#[] : Array String)
  let directives ← IO.ofExcept ((Editor.Headless.script configScript).mapError IO.userError)
  let shipped ←
    Editor.Headless.shipped setPackages #[`Editor] sysroot [oleans] configDirectory
        (fun line => printed.modify (·.push line)) .headless (fakeClock := true)
  let failure ←
    Editor.Headless.run
        { shipped with
          workingDirectory := ← IO.currentDir
          display := fun snapshots =>
            Editor.Headless.Host.Display.recorder Editor.Headless.cells snapshots }
        directives Editor.Headless.settlePatience
  let lines ← printed.get
  let greeted := lines.any fun line => (line.splitOn Greeting.helloText).length > 1
  if failure.isNone && greeted then
    IO.println
        "greeting linked test: config bound a key to greeting-hello and the config session ran it"
    return true
  else
    IO.eprintln
        s!"FAILED: the config session did not run greeting-hello for config's key; it printed {lines}"
    return false

/-- Runs both checks and exits 0 when both hold, 1 when one does not, and 2
for a command line that is not the two directories. The exit is explicit,
after the library's services are shut down and its queues quit, as the
headless mode's is: a task may still be blocked in the library. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | [sysroot, oleans] =>
    let library ← libraryCheck
    let config ← configCheck sysroot oleans
    (← IO.getStdout).flush
    Editor.Ffi.processesShutdown
    Editor.Ffi.watchesShutdown
    Editor.Ffi.quit
    IO.Process.exit (if library && config then 0 else 1)
  | _ =>
    IO.eprintln "usage: GreetingTest-Linked <sysroot> <core olean dir>"
    return 2
