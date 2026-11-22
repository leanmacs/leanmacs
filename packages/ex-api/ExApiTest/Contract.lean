import Editor.Api
import Editor.Config.Packages
import Editor.Test.Driver
import Editor.Test.Hosted
import ExApi
import ShellApi

/-!
# The contract check of `ex-api`

What every implementation of the interface runs over its package. It
registers a command under each name the interface declares, so whatever
reaches one of those names finds it: the Vim scheme's `:`, and the loop,
the frame commands and the window commands, which run `quit`. And the
command `ex` does what other packages rely on, checked on the core's test
kit's driver (`Editor.Test.hostedDriver`, `lean/Editor/Test/Hosted.lean`)
over the package and a probe written here:

1. handed a line whose name is bound, it runs the bound command with the
   rest of the line: every package that binds an ex name relies on it;
2. handed a bang line, it runs `shell-api`'s `shell-command`
   (`ShellApi.commandName`) with the text after the `!` and the line as
   typed: the shell relies on it;
3. handed no line, it asks for one, with itself as the continuation: a
   key bound to it, as the Vim scheme's `:` is, relies on it.

It is a list of sentences, each with whether it holds, the shape the
fixture interface package `greeting-api` gives its own
(`tests/packages/greeting-api`), so that it needs nothing of an
implementation's test driver: a driver whose checks are of another type
turns each pair into one of its checks.
-/

namespace ExApiTest

open Editor
open Editor.Test

/-- The name of the probe's command. -/
def probeName : String :=
  "ex-contract-said"

/-- What the probe's commands say of the strings they were called with. -/
def probeText (name : String) (arguments : List String) : String :=
  s!"{name} was handed {arguments}"

/-- The strings among `call`'s arguments, in order. -/
def probeStrings (call : Call) : List String :=
  call.arguments.filterMap fun
    | .str text => some text
    | _ => none

/-- The probe: a package that registers a command under `probeName` and
one under `shell-api`'s `shell-command`, each of which says its name and
the strings it was called with, and binds the ex name `contract-say` to
the first, taking text. -/
def probe : Package :=
  { name := "ex-contract-probe"
    setup := do
      commandWith probeName fun call => message (probeText probeName (probeStrings call))
      commandWith ShellApi.commandName fun call =>
          message (probeText ShellApi.commandName (probeStrings call))
      exCommand "contract-say" probeName (takes := .text) }

/-- The echo area of a driver hosted over `package` and the probe once the
command `ExApi.name` has run with `arguments` and what it asked to be run
after it has; `none` if the driver could not be made. -/
def probed (package : Package) (arguments : List Argument) : Option (Option String) :=
  (hostedDriver #[package, probe]).map fun driver =>
    echoOf (hostedRan driver { command := ExApi.name, arguments })

/-- The checks of the contract over `package`: one for each name the
interface declares, then the three of the command `ex` (the module docs),
each with what must hold as a sentence. -/
def contractChecks (package : Package) : List (String × Bool) :=
  let registered := (Package.registered package).commands.map (·.name)
  ExApi.names.toList.map
      (fun name =>
        (s!"`{package.name}` registers a command under `{name}`, a name `ex-api` declares",
          registered.contains name)) ++
    [(s!"`{package.name}`'s `{ExApi.name}`, handed a line whose name is bound, runs the bound command with the rest of the line",
        probed package [.str "contract-say hello there"] ==
          some (some (probeText probeName ["hello there"]))),
      (s!"`{package.name}`'s `{ExApi.name}`, handed a bang line, runs `{ShellApi.commandName}` with the text after the bang and the line as typed",
        probed package [.str "!echo hi"] ==
          some (some (probeText ShellApi.commandName ["echo hi", "!echo hi"]))),
      (s!"`{package.name}`'s `{ExApi.name}`, handed no line, asks for one, with itself as the continuation",
        ((hostedDriver #[package, probe]).map fun driver =>
            (hostedRan driver { command := ExApi.name }).loop.state.prompt.map (·.continuation)) ==
          some (some { command := ExApi.name }))]

end ExApiTest
