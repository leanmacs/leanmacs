import Editor.Job
import Editor.Process
import Editor.Process.Environment
import Editor.RealHost
import Editor.Test.Linked.Services
import EnvironmentApi
import EnvironmentApiTest.Fake
import LoginShell
import LoginShellTest.Check
import LoginShellTest.Linked.LoginShell.Contract

/-!
# Linked tests: a real login-shell base under a real directory source

`loginShellWiringChecks`, the one wiring check of a child's environment
built from a real base and a real directory source (`EnvironmentApi.lean`,
"Where each rule is pinned"): the login shell at the fixture shell under
`tests/login-shell`, and over it a directory source standing in for mise,
the library's fake (`EnvironmentApiTest.fakeDirectory`) at the fixture
`prepend`, which puts the directory its fixture config names before the
`PATH` it was given. A package may not import another implementation
package, so mise's own source cannot be registered here; the fixture
stands in for it. A real child started through `Process.run` gets the
prepended directory first and the shell's `PATH` after it. The linked
test's root, `LoginShellTest/Linked.lean`, runs it.

It works in a temporary directory of its own, removed only once the
process service has worked what was handed to it
(`Editor.Test.Linked.withFiles`); it sets no variable of the test process,
changes no working directory and runs no user's shell.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.LoginShellTest.Linked.LoginShell.Real : Editor.WiringSet :=
  .wiring "the library's process service"
    "a real login shell's variables reaching a real directory source's lookup, and a real child started over both; no fake runs a shell or a child"

namespace LoginShellTest.Linked

open Editor
open Editor.Test.Linked

/-- The one wiring check, criterion 4, over the library's process service
with the fixtures under `fixtures`. -/
def loginShellWiringChecks (services : Job.Services) (fixtures : System.FilePath) : List Check :=
  [{  name :=
        "criterion 4: with a directory source standing in for mise over the fixture login shell, a child started in a directory whose fixture config prepends a directory gets that directory first and the shell's PATH after it, and nothing is said"
      run :=
        Editor.Test.Linked.withFiles services (targets := [.processes]) fun directory => do
          let shell ← copyFixture fixtures directory "shell"
          let prepend ← copyFixture fixtures directory "prepend"
          let shellPath := s!"{directory}/shell-bin:/usr/bin:/bin"
          writeProfile directory shellPath
          IO.FS.writeFile (directory / "fixture-prepend") s!"{directory}/project-bin\n"
          let registered :=
            (EnvironmentApi.registered
                #[EnvironmentApiTest.fakeDirectory "prepend" prepend #["fixture-prepend"]]
                #[LoginShell.at shell directory] LoginShell.name).1
          let state ← IO.mkRef (({ host := .headless } : Process.Environments).install registered)
          let said ← IO.mkRef #[]
          let printenv : Process.Command :=
            { program := "/usr/bin/printenv", arguments := #["PATH"], directory }
          let printed ←
            ranTrue (sharing services state said) do
                match ← Process.run printenv 4096 with
                | .ok { exit := .code 0, stdout, .. } =>
                  return String.fromUTF8? stdout == some s!"{directory}/project-bin:{shellPath}\n"
                | _ =>
                  return false
          return printed && (← said.get).isEmpty }]

end LoginShellTest.Linked
