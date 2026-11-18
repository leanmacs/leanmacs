import ConfigTest.Check
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Registry
import Editor.Event
import Editor.Event.Queue
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Interrupt
import Editor.Files
import Editor.Files.Compiled
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Text
import Editor.Value

/-!
# Config tests: support: Configs

Chunks and what compiled code hands a host: the chunks the checks elaborate, the
chunks a config directory holds (`chunksOf`), the compiled commands they
dispatch, the minibuffer's commands and mode (`minibufferCompiled`), the
collaborators of a host of the test scheme, and the note file's text. Shared by
several test modules; it holds no checks of its own.
-/

namespace ConfigTest

open Editor

/-- The names and texts of the chunks the directory source reads from
`directory`. -/
def chunksOf (directory : System.FilePath) : IO (Array (String × String)) := do
  let chunks ← (Config.Directory.source directory).chunks
  return chunks.map fun chunk => (chunk.name, chunk.text)

/-- What compiled code hands every host of the prompt checks: the
minibuffer's commands and its mode, as the executable is handed them
(`Editor/Minibuffer/Compiled.lean`). -/
def minibufferCompiled : Compiled :=
  { commands := Minibuffer.commands, modes := Minibuffer.modes }

/-- Whether `message` is one line and names `path`. A message that will be
printed as one diagnostic line must hold the path on its first line. -/
def namesOnOneLine (message : String) (path : System.FilePath) : Bool :=
  (message.splitOn "\n").length == 1 && (message.splitOn path.toString).length > 1

/-- Bytes that are not UTF-8. -/
def notUtf8 : ByteArray :=
  ⟨#[0xff, 0xfe, 0xfd]⟩

/-- A chunk that defines the command `greet`, which makes a text holding
`text`. -/
def greetChunk (text : String) : String :=
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

/-- A chunk whose `setup` registers nothing. -/
def emptyChunk : String :=
  "def setup : SetupM Unit := pure ()\n"

/-- The collaborators of a host of the test scheme over the real elaborator. -/
abbrev TestCollaborators :=
  Headless.Collaborators Config.Elaborate.State TestScheme.scheme

/-- Hands `check` a host's state as its loop starts (`Headless.Running.new`),
with the collaborators `adjust` makes of those of a stage of its own over an
empty config directory, and the stage. The library is told the interrupt
key, as the host's loop tells it, but no loop runs: the check calls the
host's handlers itself, on its own thread. Afterwards the library has no
interrupt key and the flag is down, whatever the check did. The directory
is removed. -/
def withRunning (context : Context) (adjust : TestCollaborators → TestCollaborators)
    (check :
      TestCollaborators →
        Headless.Running Config.Elaborate.State TestScheme.scheme →
        Stage Config.Elaborate.State → IO Bool) :
    IO Bool :=
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

/-- What compiled code hands every host of the ex checks: the ex line's
commands and the ex names that ship (`Ex.commands`, `Ex.bindings`,
`Editor/Ex/Compiled.lean`), the minibuffer's commands and its mode, the
file commands, which two of the shipped names run, and `other`, written
here, which says `other`, on `C-c o`. It is handed no job: no check here
opens or saves a file. -/
def exCompiled : Compiled :=
  { commands :=
      Ex.commands ++ Minibuffer.commands ++ Files.commands ++
        #[{ name := "other", action := .plain (message "other") }]
    modes := Minibuffer.modes
    ex := Ex.bindings
    bindings := #[bound "C-c o" "other"] }

/-- A compiled command called `name`, written for the file checks, that runs
the compiled open command with `path` as its argument: the driver's `run`
hands a command no argument, so a check that opens a file hands its host a
command of this kind for each path. It looks the open command up among the
commands compiled code registers (`Files.commands`), so what runs is that
registration. -/
def opening (name : String) (path : System.FilePath) : Config.Registration :=
  { name
    action :=
      .call fun call => do
        let registered : Option Config.Action :=
          (Files.commands.find? (·.name == Files.openName)).map (·.action)
        match registered with
        | some (.call run) =>
          run { call with arguments := [.str path.toString] }
        | _ =>
          message "the open command is not a compiled command that is given its call" }

/-- Runs `check` against a host over the library's file service
(`Stage.overFiles`), with an empty config directory of its own, that is
handed the file commands and their jobs as compiled code registers them
(`Files.commands`, `Files.jobs`), the minibuffer's commands and its mode
(`Minibuffer.commands`, `Minibuffer.modes`), as the executable is, and,
for each name and path of `opens`, a command of that name that opens that
path (`opening`). Stops the host: `false` if the check did not hold or the
host did not stop. -/
def withFileHost (context : Context) (opens : List (String × System.FilePath))
    (check : Session → IO Bool) (extra : Array Config.Registration := #[]) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let stage ←
      Stage.overFiles context (Config.Directory.source directory)
          { commands :=
              Files.commands ++ Minibuffer.commands ++
                (opens.map fun (name, path) => opening name path).toArray ++
                extra
            jobs := Files.jobs
            modes := Minibuffer.modes }
    onStage stage fun host stage =>
        check
          { host, directory, output := stage.output, threads := stage.threads, clock := stage.clock,
            watches := stage.watches, log := stage.log }

/-- The text of the file `note.txt` of the file checks: two lines, with
two-byte characters. -/
def noteText : String :=
  "héllo\nwörld\n"

end ConfigTest
