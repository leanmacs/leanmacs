import Editor.Extension
import Editor.Package
import Editor.Process.Environment
import EnvironmentApi

/-!
# The fakes of `environment-api`

Sources the core does not name, as data: `fakeSource`, a program run at a
path with no arguments in the directory it is given, over the environment
so far, printing `NAME=value` lines (`keyValues`, `linesOf`), so a check
sees the core composing sources whose output is no JSON; a directory source
over it (`fakeDirectory`), a base over it (`fakeBase`), and a package that
registers both (`fakePackage`). This library's model tests hold them to the
contract (`EnvironmentApiTest.Contract`, `ModelTest.environmentApiChecks`),
and the core's model tests compose layers from them.
-/

namespace EnvironmentApiTest

open Editor

/-- The variables of `bytes` read as `NAME=value` lines: the fake sources'
output, which is no JSON, so the core is seen composing sources it does not
name. -/
def keyValues (bytes : ByteArray) : Except String (Array (String × String)) := do
  let some text := String.fromUTF8? bytes | throw "it is not UTF-8"
  ((text.splitOn "\n").filter (!·.isEmpty)).toArray.mapM fun line =>
      match line.splitOn "=" with
      | [name, value] => pure (name, value)
      | _ => throw s!"the line {line} is not NAME=value"

/-- `variables` written as `NAME=value` lines, which `keyValues` reads. -/
def linesOf (variables : Array (String × String)) : String :=
  String.join (variables.toList.map fun (name, value) => s!"{name}={value}\n")

/-- A source the core does not name: `name`, run at `path` with no arguments
in the directory it is given, over the environment so far, printing
`NAME=value` lines; its result kept by the stamps of `stampNames`. -/
def fakeSource (name : String) (path : System.FilePath) (stampNames : Array String := #[]) :
    Process.Source :=
  { name, program := .at path
    command := fun executable directory environment =>
      { program := executable.toString, directory, environment }
    parse := keyValues, output := "NAME=value lines", stampNames }

/-- A directory source over `fakeSource name path stampNames`, in every
mode. -/
def fakeDirectory (name : String := "fake-directory")
    (path : System.FilePath := "/fake/bin/directory")
    (stampNames : Array String := #["fake.toml"]) : EnvironmentApi.DirectorySource :=
  { name, source := fun _ => some (fakeSource name path stampNames) }

/-- A base over `fakeSource name path`, looked up in `directory` in every
mode. -/
def fakeBase (name : String := "fake-base") (path : System.FilePath := "/fake/bin/base")
    (directory : System.FilePath := "/") : EnvironmentApi.BaseSource :=
  { name, base := fun _ => .lookup (fakeSource name path) directory }

/-- A package that registers `fakeDirectory` and `fakeBase`, with their
default names. -/
def fakePackage : Package :=
  { name := "fake-environment"
    setup := do
      Extension.add fakeDirectory
      Extension.add fakeBase }

end EnvironmentApiTest
