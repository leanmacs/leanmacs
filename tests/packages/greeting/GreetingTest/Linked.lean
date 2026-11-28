import Editor
import Editor.Command.Append
import Editor.InputScheme.Test
import Editor.Test.Linked.Host
import Editor.Test.Linked.Shipped
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
as its arguments.

It is one executable for both of what the core has two for
(`docs/design/packages.md`, "A package's tests and the gate's steps over
them"), and holds a check of each kind, and one of the package's own `initialize`
(`initializeCheck`): it ran in this executable, linked as the editor is:

- **Against the Rust library**, as `ffi-test` and `contract-test` are the
  core's: a command over the text port's real binding (`libraryCheck`).
- **Of a config session on the real elaborator**, as `config-test` is the
  core's: a host of the linked test kit stepped on the check's thread
  (`Editor.Test.Linked.withShippedHost`), handed the packages a set that
  holds this package hands its editor, loads a config directory that binds
  a key to the package's command, and the key runs it (`configCheck`). The
  two directories it is handed are what that session elaborates on. It
  needs no real loop thread: the fixture `tests/headless/hello` runs this
  package's command stepped on the fixture set's harness.

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

/-- The packages this Lake package hands a set's editor: its own. The
core's Lake package, which it requires, hands a set none. -/
def setPackages : Array Editor.Package :=
  Greeting.EditorPackage.packages

/-- The config directory `configCheck` loads, from the package's directory,
where the gate runs this executable. -/
def configDirectory : String :=
  "tests/linked/config"

/-- The key the config binds to the package's command, `C-c g`, as the
window would report its presses. -/
def configKeys : List Editor.Key :=
  [{ logical := .character "c", physical := .code "KeyC", modifiers := { control := true } },
    { logical := .character "g", physical := .code "KeyG" }]

/-- Runs a host of the linked test kit, stepped on the check's thread over
the fakes (`Editor.Test.Linked.withShippedHost`), over `setPackages` with
the real elaborator, the toolchain in `sysroot` and the core's `.olean`
files in `oleans`, on the config in `configDirectory`: it loads the config,
presses the keys the config binds to the package's command and asks for the
scene, and says whether the host settled and a line of what it printed
holds the package's greeting: config's key ran the package's command, so
the session elaborated config that names it and the host had registered
it. -/
def configCheck (sysroot oleans : String) : IO Bool :=
  Editor.Test.Linked.HostContext.run sysroot oleans setPackages fun context => do
    let files ← Editor.Test.Linked.configFiles configDirectory
    let printed ← IO.mkRef (#[] : Array String)
    let held ←
      Editor.Test.Linked.withShippedHost Editor.TestScheme.scheme context files fun session => do
          session.ask [.reload]
          for key in configKeys do
            session.press key
          session.ask [.scene]
          let lines ← session.output.get
          printed.set lines
          return lines.any fun line => (line.splitOn Greeting.helloText).length > 1
    let lines ← printed.get
    if held then
      IO.println
          "greeting linked test: config bound a key to greeting-hello and the config session ran it"
      return true
    else
      IO.eprintln
          s!"FAILED: the config session did not run greeting-hello for config's key; it printed {lines}"
      return false

/-- Whether the package's `initialize` ran in this executable, which is
linked as the editor is: the ref it sets (`Greeting.initialized`) holds
`true`. It says what it found. -/
def initializeCheck : IO Bool := do
  if ← Greeting.initialized.get then
    IO.println "greeting linked test: the package's initialize ran in the linked executable"
    return true
  else
    IO.eprintln "FAILED: the package's initialize did not run in the linked executable"
    return false

/-- The root's check set (`Editor.CheckGroup`), over the toolchain's
directory and the core's `.olean` directory: the three checks, each saying
whether it held, in the order they run, in a plain group, since it holds no
module of the wiring set. -/
def checks : List (Editor.CheckGroup (String × String) (IO Bool)) :=
  [.plain fun (sysroot, oleans) => [initializeCheck, libraryCheck, configCheck sysroot oleans]]

/-- The usage, on stderr, and status 2. -/
def usage : IO UInt32 := do
  IO.eprintln
      "usage: GreetingTest-Linked <sysroot> <core olean dir> <test grammars dir> [--wiring], or GreetingTest-Linked wiring-modules"
  return 2

/-- Runs the three checks and exits 0 when all hold, 1 when one does not, and
2 for a command line that is not the two directories and the test grammars' directory, with `--wiring` after
them or not. Its check set (`checks`) holds no module of the wiring set, so
with `--wiring` it selects no check and exits 0, building no host
(`Editor.CheckGroup.running`), and `wiring-modules` prints none. The exit is
explicit, after the library's services are shut down and its queues quit,
as the headless mode's is: a task may still be blocked in the library. -/
def main (arguments : List String) : IO UInt32 := do
  match arguments with
  | ["wiring-modules"] =>
    for module in Editor.CheckGroup.modules checks do
      IO.println module
    return 0
  | sysroot :: oleans :: _ :: rest =>
    match Editor.CheckGroup.Mode.ofArguments? rest with
    | some mode =>
      Editor.CheckGroup.running mode checks do
          let held ← (Editor.CheckGroup.select mode checks (sysroot, oleans)).mapM id
          (← IO.getStdout).flush
          Editor.Ffi.processesShutdown
          Editor.Ffi.watchesShutdown
          Editor.Ffi.quit
          IO.Process.exit (if held.all id then 0 else 1)
    | none =>
      usage
  | _ =>
    usage
