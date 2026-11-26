import Editor.InputScheme
import Editor.ModuleLookup
import Editor.Test.Fixture.CommandLine
import Editor.Test.Fixture.Stepped

/-!
# The headless fixture harness: its edge

`fixture-test`'s `main`, which a package set's generated root calls
(`EditorSetFixtures`, written by the `editorFixtures` facet in
`lean/lakefile.lean`) with the set's packages, the input schemes they
supply, the config base and the fixture setups its Lake packages declare
(`<P>Test.FixtureSetups`), as the editor's root calls `Editor.Main.run`.
It reads the command line (`Editor/Test/Fixture/CommandLine.lean`), wires
the real pieces at the edge, and runs:

- the real tree over the repository's files (`realTree`), each root given
  made absolute against the working directory when it names a directory
  there, so the gate names roots from `lean/`;
- the `.olean` directories given, then those the build recorded beside the
  executable (`<executable>.oleans`, `ModuleLookup.recorded`), as the
  editor finds its own;
- the config files' module data in a temporary directory, removed at the
  end;
- `real-thread [--site <prefix>]`, before any of that, the real-thread set's
  listing (`RealThread.listed`), which wires nothing;
- the report on stdout, and the exit status: 0 when everything held, 1
  when something failed, 2 for a command line it does not take, after its
  usage on stderr.
-/

namespace Editor.Test.Fixture.Main

open Editor

/-- The harness, for the set's `packages`, the input `schemes` they supply
(the last is run, `SchemePackage.chosen?`), the config `base` and the
fixture `setups` the set's Lake packages declare, after the core's own
(`Setup.core`), over the command line `arguments` (the module docs). -/
def run (packages : Array Package) (schemes : Array SchemePackage) (base : Array Lean.Name)
    (setups : Array (String × Setup)) (arguments : List String) : IO UInt32 := do
  if let some site := readListing arguments then
    for line in RealThread.listed site do
      IO.println line
    return 0
  let invocation ←
    match read arguments with
    | .ok invocation =>
      pure invocation
    | .error reason =>
      unless reason.isEmpty do
        IO.eprintln s!"fixture-test: {reason}"
      IO.eprintln s!"usage: {usage}"
      return 2
  let some chosen := SchemePackage.chosen? schemes
    |
    IO.eprintln s!"fixture-test: {SchemePackage.noneInstalled}"
    return 1
  let appPath := (← IO.appPath).toString
  let readFile (path : System.FilePath) : IO (Option String) := do
    try
      return some (← IO.FS.readFile path)
    catch _ =>
      return none
  let recorded ← ModuleLookup.recorded appPath readFile
  let directories :=
    ModuleLookup.resolve appPath
      { sysroot := some invocation.sysroot, oleans := some invocation.oleans } recorded
  let repository ←
    try
      pure (← IO.FS.realPath invocation.repository).toString
    catch _ =>
      pure invocation.repository
  let files ← Config.Elaborate.ModuleFiles.temporary
  let harness : Harness chosen.scheme :=
    { packages, base, sysroot := invocation.sysroot, oleans := directories.oleans, repository
      latest := ← IO.mkRef none, files, setups := Setup.core ++ setups }
  let tree := realTree repository
  -- A root named from the working directory, as the gate names them, is
  -- made absolute, so it is read from the repository's root.
  let absolute (path : String) : IO String := do
    try
      pure (← IO.FS.realPath path).toString
    catch _ =>
      pure path
  let status ←
    try
      match invocation.command with
      | .run roots =>
        runRoots harness tree (← roots.mapM absolute)
      | .compared =>
        printCompared harness tree
      | .compare script file =>
        compare harness tree script file
    finally
      try
        files.remove
      catch _ =>
        pure ()
  (← IO.getStdout).flush
  return status

end Editor.Test.Fixture.Main
