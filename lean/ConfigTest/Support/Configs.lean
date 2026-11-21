import ConfigTest.Check
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Event
import Editor.Event.Queue
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Interrupt
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Mode
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Minibuffer
import Editor.Text
import EditorCore.EditorPackage

/-!
# Config tests: support: Configs

Config texts and what compiled code hands a host: the texts the checks
elaborate, the compiled commands they
dispatch, the minibuffer's commands and mode (`minibufferCompiled`), the
collaborators of a host of the test scheme, and the note file's text. Shared by
several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The package named `name` of the core's Lake package, as the executable's
hosts are handed it (`EditorCore.EditorPackage.packages`), so that a check
of the core whose host needs a feature's package takes it from that list,
naming no module of the feature; one that registers nothing when the list
has none of that name. -/
def shippedPackage (name : String) : Package :=
  (EditorCore.EditorPackage.packages.find? (·.name == name)).getD { name, setup := pure () }

/-- What compiled code hands every host of the prompt checks: the kit's
minibuffer's commands and its mode (`Test.Minibuffer.package`,
`Editor/Test/Minibuffer.lean`), where the executable is handed the
package that ships. -/
def minibufferCompiled : Compiled :=
  { commands := Test.Minibuffer.package.registered.commands,
    modes := Test.Minibuffer.package.registered.modes }

/-- Whether `message` is one line and names `path`. A message that will be
printed as one diagnostic line must hold the path on its first line. -/
def namesOnOneLine (message : String) (path : System.FilePath) : Bool :=
  (message.splitOn "\n").length == 1 && (message.splitOn path.toString).length > 1

/-- Bytes that are not UTF-8. -/
def notUtf8 : ByteArray :=
  ⟨#[0xff, 0xfe, 0xfd]⟩

/-- A config that defines the command `greet`, which makes a text holding
`text`. -/
def greetText (text : String) : String :=
  "def greet : EditorM Unit := do\n  discard <| createText \"" ++ text ++ "\"\n"

/-- A compiled command called `name` that replaces what the focused window's
selection covers with `text`. -/
def inserting (name text : String) : Config.Registration :=
  { name,
    action :=
      .call fun call => do
        Loop.insert call.target text }

/-- The compiled command `boom`: it replaces what the selection covers with
`boom`, and then deletes a range the text does not have, which the library
refuses. -/
def boomCommand : Config.Registration :=
  { name := "boom"
    action :=
      .call fun call => do
        Loop.insert call.target "boom"
        call.target.buffer.text.delete 9 99 }

/-- The compiled command `spin`: it replaces what the selection covers with
`spin`, and then asks the text its revision a thousand million times. -/
def spinCommand : Config.Registration :=
  { name := "spin"
    action :=
      .call fun call => do
        Loop.insert call.target "spin"
        for _ in [0:1000000000] do
          discard <| call.target.buffer.text.revision }

/-- What compiled code hands the hosts of the dispatch checks: `stamp`, which
inserts `!` at the cursor, on `C-c s`; `boom` on `C-c b`; and `spin` on
`C-c l`. -/
def dispatchCompiled : Compiled :=
  { commands := #[inserting "stamp" "!", boomCommand, spinCommand]
    bindings := #[bound "C-c s" "stamp", bound "C-c b" "boom", bound "C-c l" "spin"] }

/-- A config whose `setup` registers nothing. -/
def emptyText : String :=
  "def setup : SetupM Unit := pure ()\n"

/-- The collaborators of a host of the test scheme over the real elaborator. -/
abbrev TestCollaborators :=
  Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle TestScheme.scheme

/-- A stage over the real elaborator. -/
abbrev TestStage :=
  Stage Config.Elaborate.Base Config.Elaborate.Handle

/-- A host's state over the real elaborator and the test scheme. -/
abbrev TestRunning :=
  Headless.Running Config.Elaborate.Base Config.Elaborate.Handle TestScheme.scheme

/-- Hands `check` a host's state as its loop starts (`Headless.Running.new`),
with the collaborators `adjust` makes of those of a stage of its own over an
empty config directory, and the stage. The library is told the interrupt
key, as the host's loop tells it, but no loop runs: the check calls the
host's handlers itself, on its own thread. Afterwards the library has no
interrupt key and the flag is down, whatever the check did. The directory
is removed. -/
def withRunning (context : Context) (adjust : TestCollaborators → TestCollaborators)
    (check : TestCollaborators → TestRunning → TestStage → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
    let collaborators := adjust stage.collaborators
    unless ← Event.setInterruptKey (some collaborators.interruptKey) do
      return false
    try
      check collaborators (← Headless.Running.new collaborators) stage
    finally
      discard <| Event.setInterruptKey none
      -- A check whose host did not lower the flag leaves it down for the
      -- next: one key was posted, and a lower with none counted is nothing.
      Ffi.interruptLower

/-- What compiled code hands the host of the compiled job check: the job
`nap`, which sleeps 10 ms on the job clock and whose command inserts
`napped` at the cursor of view 0, and the command `rest`, which starts
it. -/
def nappingCompiled : Compiled :=
  { commands := #[{ name := "rest", action := .plain (discard <| startJob "nap") }]
    jobs :=
      #[{ name := "nap"
          work := fun _ =>
            Work.of (fun _ => sleep 10) fun _ =>
              discard <| (⟨0⟩ : ViewId).insertAtSelections "napped" }] }

end ConfigTest
