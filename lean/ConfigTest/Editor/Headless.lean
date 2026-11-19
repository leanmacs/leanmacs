import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import ConfigTest.Support.Syntax
import Editor.Api
import Editor.Appearance
import Editor.Buffers
import Editor.Clipboard.InProcess
import Editor.Command
import Editor.Command.Call
import Editor.Compile
import Editor.Compile.Contribution
import Editor.Compile.Listing
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Display
import Editor.Completion.Displays
import Editor.Completion.Paths
import Editor.Completion.Style
import Editor.Completion.Words
import Editor.Config.Diagnostic
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Owner
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Config.Stores
import Editor.Display
import Editor.DisplayRules
import Editor.Event
import Editor.Event.Queue
import Editor.Ex
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Counter
import Editor.Ffi.Events
import Editor.Ffi.Interrupt
import Editor.File
import Editor.FileWatch
import Editor.Files
import Editor.Files.Compiled
import Editor.Fuzzy
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Real
import Editor.Job.Runner
import Editor.Job.Table
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Menu.Compiled
import Editor.Minibuffer
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Process.Environment
import Editor.Program
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.TabCommands
import Editor.TabCommands.Compiled
import Editor.Text
import Editor.Text.Real
import Editor.Themes
import Editor.Watch
import Editor.Window
import Editor.WindowCommands.Compiled
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.FindFile
import Editor.Workspace.FindInProject
import Editor.Workspace.Modes

/-!
# Config tests: `Editor/Headless.lean`

The tests of `Editor/Headless.lean`: `hostChecks`, `threadChecks` (with `Gate`),
`jobChecks`, `agreementChecks`, `scriptChecks`, `hostLoopChecks`,
`exScriptChecks`, `reloadEchoChecks`, `shippedChecks`, `watchReloadChecks` and
`environmentHostChecks`. The root module `ConfigTest` runs them; its module doc
says what each shows.
-/

namespace ConfigTest

open Editor

/-- Runs `check` against a host started over `elaborator` and `source`, with
its output in a buffer `check` is handed, and stops the host. `false` if the
check did not hold or the host did not stop. -/
def hosted {σ : Type} (context : Context) (elaborator : Config.Elaborator σ)
    (source : Config.Source) (check : Headless.Host → IO.Ref (Array String) → IO Bool) : IO Bool :=
  staged context elaborator source fun host stage => check host stage.output

/-- A chunk whose `setup` registers `greet`. -/
def setupChunk : String :=
  "def setup : SetupM Unit := do\n  command \"greet\" greet\n"

/-- A config of two chunks: `greet`, which makes a text holding "v1", and the
`setup` that registers it. -/
def greetConfig : List (String × String) :=
  [("10-greet.lean", greetChunk "v1"), ("20-setup.lean", setupChunk)]

/-- A chunk that defines the command `greet`, which says `hello` in the echo
area. -/
def helloChunk : String :=
  "def greet : EditorM Unit := message \"hello\"\n"

/-- A config of two chunks: `greet`, which says `hello`, and the `setup`
that registers it. -/
def helloConfig : List (String × String) :=
  [("10-greet.lean", helloChunk), ("20-setup.lean", setupChunk)]

/-- A chunk with a store of one number at version 1, and a `setup` that
declares it and registers `bump`, which adds `step` to it. -/
def counterChunk (step : Nat) : String :=
  "structure Counter where
  n : Nat

def counter : Store Counter :=
  { name := \"counter\", version := 1, initial := ⟨0⟩, encode := fun c => .nat c.n,
    decode := fun
      | .nat n => some ⟨n⟩
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun c => pure { c with n := c.n + " ++
    toString step ++
    " }
"

/-- `counterChunk 1` with its store's version raised to 2 and no migration, so
the value written at version 1 is lost, and with a theorem left unproved,
which Lean warns about. -/
def unmigratedCounterChunk : String :=
  (counterChunk 1).replace "version := 1" "version := 2" ++ "\ntheorem unproved : 1 = 1 := sorry\n"

/-- A chunk with a store of one number and two commands over it: `bump`, which
adds one, and `broken`, which makes a text, then inserts into a text that
does not exist, which the library refuses, and would add a hundred. -/
def refusedChunk : String :=
  "def counter : Store Nat :=
  { name := \"counter\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun n => pure (n + 1)
  counter.command \"broken\" fun n => do
    discard <| createText \"made before the refusal\"
    (⟨7⟩ : TextId).insert 0 \"x\"
    return n + 100
"

/-- A chunk with three commands: `drop`, which makes three texts and releases
the second; `inside`, which makes a text and asks for the point of an offset
inside its two-byte character, which the library refuses; and `stale`, which
reads a snapshot that does not exist, which the library refuses too. -/
def releasingChunk : String :=
  "def drop : EditorM Unit := do
  discard <| createText \"before\"
  let released ← createText \"released\"
  discard <| createText \"after\"
  released.release

def inside : EditorM Unit := do
  let text ← createText \"é\"
  discard <| text.pointOf 1

def stale : EditorM Unit := do
  discard <| (⟨7⟩ : SnapshotId).read

def setup : SetupM Unit := do
  command \"drop\" drop
  command \"inside\" inside
  command \"stale\" stale
"

/-- A chunk with two commands, each of which applies a transaction the
library refuses: `short`, whose changes stop one byte short of its text, and
`astray`, whose selection after the changes has an end inside the text's
two-byte character. -/
def transactionChunk : String :=
  "def short : EditorM Unit := do
  let text ← createText \"héllo\"
  discard <| text.apply { changes := #[.retain 5] }

def astray : EditorM Unit := do
  let text ← createText \"héllo\"
  discard <| text.apply { changes := #[.retain 6], after := some { ranges := #[⟨2, 2⟩] } }

def setup : SetupM Unit := do
  command \"short\" short
  command \"astray\" astray
"

/-- A chunk with two commands, each of which asks a text's log about a
revision the library refuses: `ahead`, which asks what changed since a
revision its text has not reached, and `behind`, which forgets its text's
first edit and then asks what changed since before it. -/
def logChunk : String :=
  "def ahead : EditorM Unit := do
  let text ← createText \"héllo\"
  discard <| text.changesSince 1

def behind : EditorM Unit := do
  let text ← createText \"héllo\"
  text.insert 0 \"x\"
  text.forget 1
  discard <| text.changesSince 0

def setup : SetupM Unit := do
  command \"ahead\" ahead
  command \"behind\" behind
"

/-- A chunk with two commands that mark a text: `kept`, which marks its text
with an anchor, edits before it and reads it back where it went, and `lost`,
which gives its marker up and then asks for it. -/
def markerChunk : String :=
  "def kept : EditorM Unit := do
  let text ← createText \"héllo\"
  let marker ← text.mark (.anchor { offset := 3, bias := .after })
  text.insert 0 \"x\"
  unless (← text.marker marker) == .anchor { offset := 4, bias := .after } do
    throw .badPosition

def lost : EditorM Unit := do
  let text ← createText \"héllo\"
  let marker ← text.mark (.anchor { offset := 3, bias := .after })
  text.unmark marker
  discard <| text.marker marker

def setup : SetupM Unit := do
  command \"kept\" kept
  command \"lost\" lost
"

/-- A chunk with three commands that take an edit back: `undone`, which
applies the inverse of its edit and reads the text as it was made, at one
more revision; `dropped`, which drops that inverse and then asks for it; and
`elsewhere`, which asks for the inverse of an edit after it made another. -/
def inverseChunk : String :=
  "def undone : EditorM Unit := do
  let text ← createText \"héllo\"
  text.insert 0 \"x\"
  let inverted ← text.applyInverse 1 1
  unless inverted.revision == 2 && (← text.read) == \"héllo\" do
    throw .badPosition

def dropped : EditorM Unit := do
  let text ← createText \"héllo\"
  text.insert 0 \"x\"
  text.dropInverses 1 1
  discard <| text.applyInverse 1 1

def elsewhere : EditorM Unit := do
  let text ← createText \"héllo\"
  text.insert 0 \"x\"
  text.insert 0 \"y\"
  discard <| text.applyInverse 1 1

def setup : SetupM Unit := do
  command \"undone\" undone
  command \"dropped\" dropped
  command \"elsewhere\" elsewhere
"

/-- The store of `counterChunk` with its type changed and its version raised
to 2: the number gets a label, and a number written at version 1 is migrated
with the label \"migrated\". -/
def labelledCounterChunk : String :=
  "structure Counter where
  n : Nat
  label : String

def counter : Store Counter :=
  { name := \"counter\", version := 2, initial := ⟨0, \"new\"⟩,
    encode := fun c => .record [(\"n\", .nat c.n), (\"label\", .str c.label)],
    decode := fun
      | .record [(\"n\", .nat n), (\"label\", .str label)] => some ⟨n, label⟩
      | _ => none,
    migrate := fun
      | 1, .nat n => some (.record [(\"n\", .nat n), (\"label\", .str \"migrated\")])
      | _, _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun c => pure { c with n := c.n + 1 }
"

/-- The checks of the headless host (`Editor/Headless.lean`) with the real
elaborator, the real queue and the real text binding: the phase's acceptance
tests, asserted on the lines the host emits. -/
def hostChecks (context : Context) : List Check :=
  [{ name := "reload replaces a command",
     run :=
       withHost context greetConfig fun session => do
         session.ask [.reload]
         session.ask [.run "greet", .show]
         session.write "10-greet.lean" (greetChunk "v2")
         session.ask [.reload]
         session.ask [.run "greet", .show]
         return (← session.lines) ==
             #["reload 1: installed, 2 chunks, 1 commands", "run greet: ok", "commands: greet",
               "text 0: \"\"", "text 1: \"v1\"", "reload 2: installed, 2 chunks, 1 commands",
               "run greet: ok", "commands: greet", "text 0: \"\"", "text 1: \"v1\"",
               "text 2: \"v2\""] },
    { name := "a type error keeps the old config"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.write "10-greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.lines) ==
              #["reload 1: installed, 2 chunks, 1 commands", "reload 2: rejected",
                "diagnostic: 10-greet.lean: error", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"v1\""] },
    { name := "a throwing setup keeps the old config"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.write "20-setup.lean"
              "def setup : SetupM Unit := do\n  command \"other\" greet\n  throw \"no thanks\"\n"
          session.ask [.reload]
          session.ask [.run "other", .show]
          -- The message is the one config threw, so the whole line is ours.
          return (← session.output.get) ==
              #["reload 1: installed, 2 chunks, 1 commands", "reload 2: rejected",
                "diagnostic: setup:0:0: error: no thanks", "run other: no such command",
                "commands: greet", "text 0: \"\""] },
    { name :=
        "a setup that registers a command name twice keeps the old config, and the diagnostic names the command"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.write "20-setup.lean"
              "def setup : SetupM Unit := do\n  command \"greet\" greet\n  command \"greet\" greet\n"
          session.ask [.reload]
          session.ask [.run "greet", .show]
          -- The message is the editor's own, so the whole line is pinned.
          return (← session.output.get) ==
              #["reload 1: installed, 2 chunks, 1 commands", "reload 2: rejected",
                "diagnostic: setup:0:0: error: the command `greet` is registered twice",
                "run greet: ok", "commands: greet", "text 0: \"\"", "text 1: \"v1\""] },
    { name := "a reload does not double-register"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.ask [.reload]
          session.write "10-greet.lean" (greetChunk "v1" ++ "\n-- changed\n")
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.lines) ==
              #["reload 1: installed, 2 chunks, 1 commands",
                "reload 2: installed, 2 chunks, 1 commands",
                "reload 3: installed, 2 chunks, 1 commands", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"v1\""] },
    { name := "a store value survives a reload"
      run :=
        withHost context [("config.lean", counterChunk 1)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump", .run "bump", .show]
          session.write "config.lean" (counterChunk 10)
          session.ask [.reload]
          session.ask [.show, .run "bump", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 1 commands", "run bump: ok", "run bump: ok",
                "commands: bump", "text 0: \"\"", "store counter v1: 2",
                "reload 2: installed, 1 chunks, 1 commands", "commands: bump", "text 0: \"\"",
                "store counter v1: 2", "run bump: ok", "commands: bump", "text 0: \"\"",
                "store counter v1: 12"] },
    { name := "a store migrates when a reload changes its type and raises its version"
      run :=
        withHost context [("config.lean", counterChunk 1)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump", .run "bump"]
          session.write "config.lean" labelledCounterChunk
          session.ask [.reload]
          session.ask [.show, .run "bump", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 1 commands", "run bump: ok", "run bump: ok",
                "reload 2: installed, 1 chunks, 1 commands", "commands: bump", "text 0: \"\"",
                "store counter v2: {n: 2, label: \"migrated\"}", "run bump: ok", "commands: bump",
                "text 0: \"\"", "store counter v2: {n: 3, label: \"migrated\"}"] },
    { name :=
        "a reload that installs prints the config's warnings, then a warning for the store value it lost"
      run :=
        withHost context [("config.lean", counterChunk 1)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump"]
          session.write "config.lean" unmigratedCounterChunk
          session.ask [.reload]
          session.ask [.show]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 1 commands", "run bump: ok",
                "reload 2: installed, 1 chunks, 1 commands", "diagnostic: config.lean: warning",
                "diagnostic: store counter: warning", "commands: bump", "text 0: \"\"",
                "store counter v2: 0"] },
    { name := "a chunk that declares initialize keeps the old config"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          -- No command of this config reads the constant, so a host that
          -- wrongly installed it would fail this check, not abort.
          session.write "15-state.lean" "initialize table : IO.Ref Nat ← IO.mkRef 0\n"
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.lines) ==
              #["reload 1: installed, 2 chunks, 1 commands", "reload 2: rejected",
                "diagnostic: 15-state.lean: error", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"v1\""] },
    { name :=
        "a store command the library refuses is reported as refused: the store keeps its value, and the text the command made before the refusal stays"
      run :=
        withHost context [("config.lean", refusedChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump", .run "broken", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 2 commands", "run bump: ok",
                "run broken: refused: no such text", "commands: bump broken", "text 0: \"\"",
                "text 1: \"made before the refusal\"", "store counter v1: 1"] },
    { name :=
        "show lists no text a command released, and the texts made before and after it keep the index they were made with"
      run :=
        withHost context [("config.lean", releasingChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "drop", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 3 commands", "run drop: ok",
                "commands: drop inside stale", "text 0: \"\"", "text 1: \"before\"",
                "text 3: \"after\""] },
    { name :=
        "a command refused for an offset that is no position, and one refused for a snapshot that does not exist, are each reported with that refusal's name"
      run :=
        withHost context [("config.lean", releasingChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "inside", .run "stale"]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 3 commands", "run inside: refused: bad position",
                "run stale: refused: no such snapshot"] },
    { name :=
        "a command whose transaction's changes do not fit, and one whose transaction's selection does not, are each reported with that refusal's name"
      run :=
        withHost context [("config.lean", transactionChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "short", .run "astray"]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 2 commands", "run short: refused: bad change",
                "run astray: refused: bad selection"] },
    { name :=
        "a command that asks a text's log about a revision it has not reached, and one that asks about a revision it has forgotten, are each reported with that refusal's name"
      run :=
        withHost context [("config.lean", logChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "ahead", .run "behind"]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 2 commands", "run ahead: refused: unknown revision",
                "run behind: refused: forgotten revision"] },
    { name :=
        "a command that marks a text reads its marker back where an edit moved it, and one that asks for a marker it gave up is reported with that refusal's name"
      run :=
        withHost context [("config.lean", markerChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "kept", .run "lost"]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 2 commands", "run kept: ok",
                "run lost: refused: no such marker"] },
    { name :=
        "a command that applies the inverse of its edit reads the text as it was, and one that asks for an inverse it dropped, and one whose text is not where the edit left it, are each reported with that refusal's name"
      run :=
        withHost context [("config.lean", inverseChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "undone", .run "dropped", .run "elsewhere"]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 3 commands", "run undone: ok",
                "run dropped: refused: no inverse", "run elsewhere: refused: not in state"] },
    { name :=
        "a config directory that does not exist is a rejected reload whose one diagnostic line names the directory"
      run :=
        IO.FS.withTempDir fun directory => do
          let absent := directory / "absent"
          hosted context context.elaborator (Config.Directory.source absent) fun host output => do
              host.send .reload
              unless ← host.settle patience do
                return false
              let lines ← output.get
              let diagnostic := lines.getD 1 ""
              return lines.size == 2 && lines.getD 0 "" == "reload 1: rejected" &&
                  diagnostic.startsWith "diagnostic: config:0:0: error: " &&
                  namesOnOneLine diagnostic absent },
    { name :=
        "a chunk that is not UTF-8 is a rejected reload whose one diagnostic line names the file, and the old config stays"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          IO.FS.writeBinFile (session.directory / "15-bad.lean") notUtf8
          session.ask [.reload]
          session.ask [.run "greet"]
          let lines ← session.output.get
          let diagnostic := lines.getD 2 ""
          return lines.size == 4 &&
              lines.getD 0 "" == "reload 1: installed, 2 chunks, 1 commands" &&
              lines.getD 1 "" == "reload 2: rejected" &&
              diagnostic.startsWith "diagnostic: config:0:0: error: " &&
              namesOnOneLine diagnostic (session.directory / "15-bad.lean") &&
              lines.getD 3 "" == "run greet: ok" }]

/-- How a check controls elaboration: a decorator of the elaborator port that
holds the chunk called `slow.lean` open until the check lets it go, and
counts the chunks being elaborated. Nothing here sleeps to let something
else happen. -/
structure Gate where
  /-- Resolved by the check to let `slow.lean` go, for good. -/
  release : IO.Promise Unit
  /-- Whether an elaboration of `slow.lean` has arrived and waited. -/
  holding : IO.Ref Bool
  /-- How many chunks are being elaborated now. -/
  inProgress : IO.Ref Nat
  /-- The most chunks that were being elaborated at once. -/
  most : IO.Ref Nat

namespace Gate

/-- A gate that is shut. -/
def new : IO Gate :=
  return { release := ← IO.Promise.new, holding := ← IO.mkRef false, inProgress := ← IO.mkRef 0,
           most := ← IO.mkRef 0 }

/-- `elaborator` behind the gate. -/
def around {σ : Type} (gate : Gate) (elaborator : Config.Elaborator σ) : Config.Elaborator σ :=
  { elaborator with
    chunk := fun before chunk => do
      let now ← gate.inProgress.modifyGet fun count => (count + 1, count + 1)
      gate.most.modify (max · now)
      try
        if chunk.name == "slow.lean" then
          gate.holding.set true
          discard <| IO.wait gate.release.result?
        elaborator.chunk before chunk
      finally
        gate.inProgress.modify (· - 1) }

/-- Lets `slow.lean` go, now and from now on. -/
def «open» (gate : Gate) : IO Unit :=
  gate.release.resolve ()

end Gate

/-- `source`, counting in `reads` how many times its chunks are read: once
for each reload job. -/
def counting (reads : IO.Ref Nat) (source : Config.Source) : Config.Source :=
  {
    chunks := do
      reads.modify (· + 1)
      source.chunks }

/-- A chunk that takes as long to elaborate as the check's gate says. -/
def slowChunk : String :=
  "def slow : Nat := 1\n"

/-- The lines `event <source> 0` up to `event <source> <count - 1>`: what the
host prints for a script of `count` events fed from a Rust thread. -/
def eventLines (source count : Nat) : Array String :=
  (Array.range count).map fun code => s!"event {source} {code}"

/-- A fake of the elaborator port whose every state holds a library handle, a
counter of its own: how many states are alive is how many counters the
library holds. -/
def handleElaborator : Config.Elaborator Ffi.Counter :=
  { base := Ffi.Counter.new 0,
    chunk := fun _ _ => return { diagnostics := #[], state := some (← Ffi.Counter.new 0) },
    setup := fun _ => return .ok (pure ()) }

/-- The checks of the editor thread and the reload job: what happens while a
chunk elaborates, that reloads are serialised, and that nothing of a
replaced config is kept. -/
def threadChecks (context : Context) : List Check :=
  [{
      name :=
        "the editor answers events while a slow chunk elaborates: 100 events from a Rust thread and a command of the old config",
      run := do
        let gate ← Gate.new
        withHostOver context greetConfig gate.around id fun session => do
            session.ask [.reload]
            session.write "slow.lean" slowChunk
            session.host.send .reload
            try
              -- The reload job is now inside the elaboration of `slow.lean`,
              -- and stays there until the gate opens.
              unless ← eventually gate.holding.get do
                return false
              unless ← Ffi.feedScript .editor 77 100 do
                return false
              session.host.send (.run "greet")
              -- With the job on the editor thread these lines never come while
              -- the chunk is held: the wait runs out and the check fails.
              let answered ←
                eventually do
                    let lines ← session.output.get
                    return lines.size == 102 && lines.contains "run greet: ok"
              let lines ← session.output.get
              -- The chunk is still being elaborated: all of that was answered
              -- while it was held.
              let held := (← gate.inProgress.get) == 1
              gate.open
              session.ask []
              let after ← session.output.get
              return answered && held &&
                  lines.extract 0 1 == #["reload 1: installed, 2 chunks, 1 commands"] &&
                  (lines.filter (·.startsWith "event ")) == eventLines 77 100 &&
                  !lines.any (·.startsWith "reload 2") &&
                  after.extract 102 after.size == #["reload 2: installed, 3 chunks, 1 commands"]
            finally
              gate.open },
    { name :=
        "reloads are serialised: requests made while a job runs make one more job, never two at once, and it reads the source afresh"
      run := do
        -- Seen to bite once by hand: a host that starts a job for every
        -- request, running or not, fails this.
        let gate ← Gate.new
        let reads ← IO.mkRef 0
        withHostOver context (greetConfig ++ [("slow.lean", slowChunk)]) gate.around
            (counting reads) fun session => do
            session.host.send .reload
            try
              unless ← eventually gate.holding.get do
                return false
              session.write "10-greet.lean" (greetChunk "v2")
              session.host.send .reload
              session.host.send .reload
              -- Both requests are on the queue before the gate opens, so the
              -- editor thread meets them before the job's outcome.
              gate.open
              -- Settle first: a request sent now would be handled before the
              -- reloads have finished.
              session.ask []
              session.ask [.run "greet", .show]
              return (← reads.get) == 2 && (← gate.most.get) == 1 &&
                  (← session.lines) ==
                    #["reload 1: installed, 3 chunks, 1 commands",
                      "reload 2: installed, 3 chunks, 1 commands", "run greet: ok",
                      "commands: greet", "text 0: \"\"", "text 1: \"v2\""]
            finally
              gate.open },
    { name :=
        "a replaced config is not retained: after 50 reloads the library holds the states of one loaded config, and none once the host has stopped"
      run := do
        -- Seen to bite once by hand: a host that pushes each outcome onto a
        -- list it keeps fails this.
        let before ← Ffi.Counter.live
        let chunks ← IO.mkRef (#[] : Array Config.SourceChunk)
        let loaded ←
          hosted context handleElaborator { chunks := chunks.get } fun host _ => do
              for round in [0:50] do
                -- The first chunk changes, so every chunk is elaborated again.
                chunks.set
                    #[{ name := "a", text := toString round }, { name := "b", text := "b" },
                      { name := "c", text := "c" }]
                host.send .reload
                unless ← host.settle patience do
                  return false
              -- The base and the states after three chunks. A finished job's
              -- task may still be going away, so this is polled.
              eventually do
                  return (← Ffi.Counter.live) == before + 4
        let freed ←
          eventually do
              return (← Ffi.Counter.live) == before
        return loaded && freed }]

/-- A chunk with three jobs, and the `setup` that registers them beside
`greet`: `count` sleeps 10 ms and its result, 42, is made into a text;
`boom` sleeps 10 ms and throws; and `bad` is `count` with a handler whose
command the library refuses. -/
def jobsChunk : String :=
  "def count : Unit → JobM Nat := fun _ => do
  sleep 10
  return 42

def boom : Unit → JobM Nat := fun _ => do
  sleep 10
  throw \"no thanks\"

def setup : SetupM Unit := do
  command \"greet\" greet
  job \"count\" count fun n => discard <| createText s!\"counted {n}\"
  job \"boom\" boom fun _ => pure ()
  job \"bad\" count fun _ => (⟨7⟩ : TextId).insert 0 \"x\"
"

/-- A config of two chunks: `greet`, which makes a text holding "v1", and a
`setup` that registers it and the jobs of `jobsChunk`. -/
def jobsConfig : List (String × String) :=
  [("10-greet.lean", greetChunk "v1"), ("20-setup.lean", jobsChunk)]

/-- A chunk whose `setup` registers the mode `json`, whose text is parsed
with the grammar `json` and drawn by the shipped default; the command
`edit`, which puts `, 2` before the last byte of the scratch buffer's text;
and the job `highlight`, which sleeps 10 ms and finishes with a command that
puts `[1, true]` in the scratch buffer's text and makes `json` its major
mode, through the scratch buffer's window. -/
def highlightChunk : String :=
  "def wait : Unit → JobM Nat := fun _ => do
  sleep 10
  return 1

def edit : EditorM Unit := do
  let text : TextId := ⟨0⟩
  let length := (← text.read).utf8ByteSize
  text.insert (length - 1) \", 2\"

def setup : SetupM Unit := do
  defineMode { name := \"json\", syntaxTree := some { grammar := \"json\" } }
  command \"edit\" edit
  job \"highlight\" wait fun _ => do
    (⟨0⟩ : TextId).insert 0 \"[1, true]\"
    discard <| (⟨0⟩ : ViewId).setMajorMode \"json\"
"

/-- Runs `check` against a host over a config of `highlightChunk`, whose
syntax tree collaborator is the real binding over the library's syntax
service with every request recorded (`recordedRequest`) in the array `check`
is handed, and which after an attach waits, with a bound, for the attached
text's tree to be delivered, and stops the host. `check` is handed too how many scenes the
host's display has had published to it, read from the display the host's
collaborator made, with no request of the driver's. `false` if the check
did not hold or the host did not stop. The directory is removed. -/
def withRecordedSyntaxTree (context : Context)
    (check : Session → IO.Ref (Array String) → IO Nat → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory [("10-setup.lean", highlightChunk)]
    let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
    let asked ← IO.mkRef #[]
    let syntaxTree := recordingSyntaxTree asked
    let made : IO.Ref (Option Headless.Host.Display) ← IO.mkRef none
    let display (snapshots : SnapshotReader) : IO Headless.Host.Display := do
      let shown ← Headless.Host.Display.recorder Headless.cells snapshots
      made.set (some shown)
      return shown
    let published : IO Nat := do
      match ← made.get with
      | some shown =>
        shown.count.get
      | none =>
        return 0
    onStage
        { stage with
          collaborators :=
            { stage.collaborators with
              syntaxTree, display } }
        fun host stage =>
        check
          { host, directory, output := stage.output, threads := stage.threads, clock := stage.clock
            watches := stage.watches, log := stage.log } asked published

/-- The thread that emitted the first line of the host's output that is
`line`, if there is one. -/
def Session.threadOf (session : Session) (line : String) : IO (Option UInt64) := do
  let lines ← session.output.get
  let threads ← session.threads.get
  return (lines.idxOf? line).bind fun index => threads[index]?

/-- The checks of jobs through the headless host (`Editor/Headless.lean`),
with the real elaborator, the real queue and the real text binding. The
host's jobs wait on a fake clock the check moves, so a job ends when the
check says, and never because time passed. -/
def jobChecks (context : Context) : List Check :=
  [{
      name :=
        "a handler receives a job's result on the editor thread: the job's line is printed by the thread that prints a command's, after the clock lets the job go, and the handler's text is there",
      run :=
        -- Seen to bite once by hand: a host that prints a job's line where
        -- the job ended, from the runner's `finished`, prints it from a pool
        -- thread, and the thread ids differ.
        withHost context jobsConfig fun session => do
          session.ask [.reload]
          session.ask [.run "greet", .spawn "count"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          -- The job is in its sleep: nothing has been said of its result, and
          -- the editor still answers.
          session.ask [.run "greet"]
          let waiting ← session.output.get
          session.clock.advance 10
          let joined ← session.host.join patience
          session.ask [.show]
          let command ← session.threadOf "run greet: ok"
          let handler ← session.threadOf "job 1 count: ok"
          return waiting ==
                #["reload 1: installed, 2 chunks, 1 commands", "run greet: ok",
                  "spawn count: job 1", "run greet: ok"] &&
              joined == .settled &&
              (← session.output.get) ==
                waiting ++
                  #["job 1 count: ok", "commands: greet", "text 0: \"\"", "text 1: \"v1\"",
                    "text 2: \"v1\"", "text 3: \"counted 42\""] &&
              command.isSome &&
              handler == command &&
              command != some (← IO.getTID) },
    { name :=
        "a reload cancels the old config's jobs when it installs: the job is cancelled before the reload is reported, its wait is withdrawn, and its handler never runs"
      run :=
        withHost context jobsConfig fun session => do
          session.ask [.reload]
          session.ask [.spawn "count"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          session.write "10-greet.lean" (greetChunk "v2")
          session.ask [.reload]
          let withdrawn ← session.clock.withdrawn
          -- Past the job's sleep: a job that was still there would end, and
          -- its handler would make a text.
          session.clock.advance 10
          session.ask [.show]
          return withdrawn.size == 1 && (← session.clock.waiting) == 0 &&
              (← session.output.get) ==
                #["reload 1: installed, 2 chunks, 1 commands", "spawn count: job 1",
                  "job 1 count: cancelled", "reload 2: installed, 2 chunks, 1 commands",
                  "commands: greet"] },
    { name :=
        "a rejected reload cancels nothing: the old config's job runs on, and its handler runs when it finishes"
      run :=
        withHost context jobsConfig fun session => do
          session.ask [.reload]
          session.ask [.spawn "count"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          session.write "10-greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
          session.ask [.reload]
          let stillWaiting := (← session.clock.waiting) == 1 && (← session.clock.withdrawn).isEmpty
          session.clock.advance 10
          let joined ← session.host.join patience
          return stillWaiting && joined == .settled &&
              (← session.lines) ==
                #["reload 1: installed, 2 chunks, 1 commands", "spawn count: job 1",
                  "reload 2: rejected", "diagnostic: 10-greet.lean: error", "job 1 count: ok"] },
    { name :=
        "a job that throws is reported as failed with its message, a handler whose command the library refuses as refused, and a name that is not registered as no such job"
      run :=
        withHost context jobsConfig fun session => do
          session.ask [.reload]
          session.ask [.spawn "boom", .spawn "bad", .spawn "nope"]
          unless ← eventually (return (← session.clock.waiting) == 2) do
            return false
          let spawned ← session.output.get
          session.clock.advance 10
          let joined ← session.host.join patience
          -- The two jobs end at one instant, in either order.
          let ended := ((← session.output.get).extract spawned.size).qsort (· < ·)
          return spawned ==
                #["reload 1: installed, 2 chunks, 1 commands", "spawn boom: job 1",
                  "spawn bad: job 2", "spawn nope: no such job"] &&
              joined == .settled &&
              ended == #["job 1 boom: failed: no thanks", "job 2 bad: refused: no such text"] },
    { name :=
        "a join that cannot finish fails, it does not hang: the failure names the join's line, and the loop cancels its jobs when it ends"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The clock is never moved, so the job never ends: the join runs
          -- out, after a fifth of a second, and `run` ends its loop.
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩, ⟨5, .join⟩,
                  ⟨6, .request .show⟩]
                200
          -- The loop has ended: the job it left is cancelled, with its wait.
          let cancelled ← eventually (return (← stage.clock.withdrawn).size == 1)
          return failure == some (.working (some 5)) && cancelled && (← stage.clock.waiting) == 0 &&
              (← stage.output.get) ==
                #["reload 1: installed, 2 chunks, 1 commands", "spawn count: job 1"] },
    { name :=
        "spawn and join are directives of a script, a spawn with no name is refused, and a join that ran out is described with its line"
      run :=
        let refusal (text : String) : String :=
          match Headless.script text with
          | .error message => message
          | .ok _ => ""
        let working := Headless.Failure.describe 30000 (.working (some 12))
        pure
          ((Headless.script "spawn count\n  join  \nspawn  two words\n").toOption ==
              some
                #[⟨1, .request (.spawn "count")⟩, ⟨2, .join⟩, ⟨3, .request (.spawn "two words")⟩] &&
            (refusal "reload\nspawn\n").startsWith "line 2: " &&
            (working.splitOn "line 12").length == 2 &&
            working != Headless.Failure.describe 30000 (.reloading (some 12)) &&
            working != Headless.Failure.describe 30000 (.unanswered (some 12))) },
    { name :=
        "a job's command that sets a mode with a syntax tree reaches the host's syntax tree: the refresh delay handed over, the text attached, the grammar's shipped query compiled and its text highlighted in the default faces, and the grammar's injections, text objects and indents asked for, none of which json ships"
      run :=
        -- Seen to bite once by hand: with `Running.ended` handing
        -- `Job.finishWith` no syntax tree, the job's command reaches
        -- `SyntaxTree.none`, the recorder sees nothing, and the echo area
        -- says the attach was refused.
        withRecordedSyntaxTree context fun session asked _ => do
          session.ask [.reload]
          session.ask [.spawn "highlight"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          session.clock.advance 10
          let joined ← session.host.join patience
          let scene ← session.sceneLines
          return joined == .settled && (← session.output.get).contains "job 1 highlight: ok" &&
              (← asked.get) ==
                #["refreshAfter 500", "attach json", "shippedQuery json highlights", "compile json",
                  "captureNames", ← shippedFaces "json", "release", "shippedQuery json injections",
                  "shippedQuery json textObjects", "shippedQuery json indents"] &&
              scene.any fun line =>
                line.startsWith "scene " && (line.splitOn "highlights:").length == 1 },
    { name :=
        "a parse of a highlighted text the library delivers makes the real host publish a scene, with no key pressed"
      run :=
        -- Seen to bite once by hand: a host whose `handle` returns at once
        -- for an event from the library's source publishes nothing for the
        -- parse, and the count stays at the edit's.
        withRecordedSyntaxTree context fun session _ published => do
          session.ask [.reload]
          session.ask [.spawn "highlight"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          session.clock.advance 10
          unless (← session.host.join patience) == .settled do
            return false
          let before ← published
          -- Sent with no marker after it, which would publish a scene of its
          -- own: the edit's command publishes one, and a publish beyond it is
          -- a delivered parse's.
          session.host.send (.run "edit")
          eventually (return (← published) > before + 1) }]

/-- A config of one chunk with one command, `forget`, which releases the
text of index 0: the text of the editor loop's scratch buffer, made with the
loop's frame, before any command runs. -/
def forgetConfig : List (String × String) :=
  [("10-forget.lean",
      "def forget : EditorM Unit := do
  (⟨0⟩ : TextId).release

def setup : SetupM Unit := do
  command \"forget\" forget
")]

/-- A scene of one focused view, number 2, of the snapshot 5, 64 pixels
across and 48 down in a frame 64 down: what `Headless.Running.agreement` is asked
of in `agreementChecks`. -/
def agreementScene : Scene :=
  { size := { width := 64, height := 64 }
    views :=
      #[{ id := ⟨2⟩, rect := { x := 0, y := 0, width := 64, height := 48 }, snapshot := ⟨5⟩
          scroll := { text := ⟨0⟩, index := 0 }, selections := #[]
          cursor := { shape := .block, face := ⟨"cursor.normal"⟩ }, decorations := #[]
          status := #[] }]
    focused := some ⟨2⟩, echo := "", pending := "", preedit := none }

/-- The rows of `agreementScene`'s view in the frame: three, from the byte
offset 10. -/
def agreementRows : Array Display.Row :=
  #[⟨10, 14⟩, ⟨15, 19⟩, ⟨20, 24⟩]

/-- A rows query of `agreementScene`'s view as the loop would ask it, from the
anchor 10 at the view's height, answered with `rows`. -/
def agreementAsked (rows : Array Display.Row) (snapshot : Nat := 5) (width : Nat := 64)
    (height : Nat := 48) (anchor : Nat := 10) : Headless.Asked :=
  { query := { snapshot := ⟨snapshot⟩, width, height, anchor }, rows }

/-- The checks of what `agree` says (`Headless.Running.agreement`), on scenes and
answers made here: the four things it can say of a focused view. -/
def agreementChecks (_ : Unit) : List Check :=
  [{  name :=
        "agree says agrees when the last rows query from the view's anchor, of its snapshot at its width, answered the frame's rows"
      run :=
        pure
          (Headless.Running.agreement agreementScene 10 #[agreementAsked agreementRows]
              (some agreementRows) ==
            "agree view 2: 3 rows asked from 10, 3 in the frame: agrees") },
    { name :=
        "agree says disagrees, with both sets of rows, when the last such query was asked at the whole height and answered one row more than the frame, though an earlier one agreed"
      run :=
        pure
          (Headless.Running.agreement agreementScene 10
              #[agreementAsked agreementRows,
                agreementAsked (agreementRows.push ⟨25, 29⟩) (height := 64)]
              (some agreementRows) ==
            "agree view 2: 4 rows asked from 10, 3 in the frame: disagrees: asked 10..14 15..19 20..24 25..29, frame 10..14 15..19 20..24") },
    { name :=
        "agree says there is no rows query when none names the view's snapshot, its width and its anchor, though each matches in the other two"
      run :=
        pure
          (Headless.Running.agreement agreementScene 10
              #[agreementAsked agreementRows (snapshot := 6),
                agreementAsked agreementRows (width := 56),
                agreementAsked agreementRows (anchor := 15)]
              (some agreementRows) ==
            "agree view 2: no rows query from 10") },
    { name := "agree says the frame has no such view when the frame shows no rows of it"
      run :=
        pure
          (Headless.Running.agreement agreementScene 10 #[agreementAsked agreementRows] none ==
            "agree view 2: the frame has no such view") }]

/-- The checks of the headless mode's script and its driver
(`Headless.script`, `Headless.run`). The command line itself is covered by
one run of the real executable on the fixture under `tests/headless`, in the
`ffi-test` task. -/
def scriptChecks (context : Context) : List Check :=
  [{  name :=
        "an advance directive is a number of milliseconds, with its line's number; one with no number, two or a part that is no number is refused with its line, and the error message of a line that is no directive lists it"
      run :=
        pure <|
          (Headless.script "scene\nadvance 240\n  advance  1  \n").toOption ==
              some #[⟨1, .request .scene⟩, ⟨2, .advance 240⟩, ⟨3, .advance 1⟩] &&
            (["advance", "advance 1 2", "advance soon", "advance -1"].all fun line =>
              match Headless.script ("scene\n" ++ line) with
              | .error message => message.startsWith "line 2: "
              | .ok _ => false) &&
            match Headless.script "scene\nwait 2" with
            | .error message => (message.splitOn "advance <milliseconds>").length == 2
            | .ok _ => false },
    { name :=
        "on a stage host, spawn count, advance by its sleep and join end with the job's line, ok; an advance with nothing due runs out as stalled, with its line and its milliseconds, and an advance on a host with no fake clock fails with its sentence"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let joined ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩,
                  ⟨4, .advance 10⟩, ⟨5, .join⟩]
                patience
          let output ← stage.output.get
          let stalled ← Stage.new context context.elaborator (Config.Directory.source directory)
          let ranOut ←
            Headless.run stalled.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .advance 5⟩] 200
          let real ← Stage.new context context.elaborator (Config.Directory.source directory)
          let refused ←
            Headless.run { real.collaborators with clock := none } #[⟨1, .settle⟩, ⟨2, .advance 1⟩]
                200
          return joined.isNone && output.contains "job 1 count: ok" &&
              ranOut == some (.stalled 3 5) &&
              (Headless.Failure.stalled 3 5).describe 200 ==
                "the advance on line 3 found no wait due within 5 ms on the clock within 200 ms" &&
              refused == some (.noClock 2) &&
              (Headless.Failure.noClock 2).describe 200 ==
                s!"the advance on line 2: {Headless.advanceNeedsClock}" },
    {
      name :=
        "a script is one directive a line, each with its line number, and blank lines and comments are skipped",
      run :=
        pure
          ((Headless.script
                "# a comment\nreload\n\n  settle  \nrun greet\nrun  two words\nshow\n").toOption ==
            some
              #[⟨2, .request .reload⟩, ⟨4, .settle⟩, ⟨5, .request (.run "greet")⟩,
                ⟨6, .request (.run "two words")⟩, ⟨7, .request .show⟩]) },
    { name :=
        "a line that is no directive, and a run with no name, are refused, with the number of the line"
      run :=
        let refusal (text : String) : String :=
          match Headless.script text with
          | .error message => message
          | .ok _ => ""
        pure
          ((refusal "reload\nrelaod\n").startsWith "line 2: " &&
            (refusal "# a comment\n\nreload\nrun\n").startsWith "line 4: " &&
            (refusal "settle now\n").startsWith "line 1: ") },
    { name :=
        "a key directive is a logical key, a physical key and modifiers: one character or a <Name>, a code or -, and modifiers joined with + or -"
      run :=
        pure
          ((Headless.script
                "key a KeyA shift+control\nkey <Escape> - -\nkey é - alt+super\n").toOption ==
            some
              #[⟨1,
                  .key
                    { logical := .character "a", physical := .code "KeyA"
                      modifiers := { shift := true, control := true } }⟩,
                ⟨2, .key { logical := .named .escape }⟩,
                ⟨3,
                  .key
                    { logical := .character "é",
                      modifiers := { alt := true, superKey := true } }⟩]) },
    { name :=
        "a key directive with a part missing or left over, a logical key of two characters, an empty name, or a modifier it does not know is refused"
      run :=
        pure
          (["key", "key a", "key a KeyA", "key a KeyA - more", "key ab KeyA -", "key <> - -",
                "key a KeyA shift+meta", "key a KeyA shift+"].all
            fun line =>
            match Headless.script line with
            | .error message => message.startsWith "line 1: "
            | .ok _ => false) },
    { name :=
        "agree, idle with a number of milliseconds, and journal are directives; agree asks the editor thread, and idle and journal are the driver's own"
      run :=
        pure
          ((Headless.script "agree\n  idle 1000\nidle 0\njournal\n").toOption ==
            some #[⟨1, .request .agree⟩, ⟨2, .idle 1000⟩, ⟨3, .idle 0⟩, ⟨4, .journal⟩]) },
    { name :=
        "an idle with no number, or one that is not a number, and an agree or a journal with anything after it, are refused, with the number of the line"
      run :=
        pure
          (["idle", "idle x", "idle 10 20", "idle -1", "agree 3", "journal now"].all fun line =>
            match Headless.script ("reload\n" ++ line) with
            | .error message => message.startsWith "line 2: "
            | .ok _ => false) },
    { name :=
        "a script that sends a key with modifiers prints that the key arrived with those modifiers, in order with what it asked for"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory greetConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩,
                  ⟨3,
                    .key
                      { logical := .character "a", physical := .code "KeyA"
                        modifiers := { shift := true, control := true } }⟩,
                  ⟨4, .request (.run "greet")⟩, ⟨5, .key { logical := .named .escape }⟩]
                patience
          return failure == none &&
              (← stage.output.get) ==
                #["reload 1: installed, 2 chunks, 1 commands", "key arrived: a KeyA shift+control",
                  "run greet: ok", "key arrived: <Escape> - -"] },
    { name :=
        "a real config that defines a segment and lists the mode line installs: the reload prints a line for the segment nobody registered, the echo area says it, and each status line is the listing's, in its order and on its sides"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory
              [("10-mode-line.lean",
                  "def setup : SetupM Unit := do\n  defineSegment \"greeting\" fun _ =>\n    #[{ text := \"hi\", face := ⟨\"mode-line.secondary\"⟩, padding := 4 }]\n  modeLine [\"buffer\", \"nope\"] [\"greeting\", \"line-column\"]\n")]
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .commit "ab"⟩, ⟨4, .request .scene⟩]
                patience
          let output ← stage.output.get
          return failure == none &&
              output.filter (fun line => !line.startsWith "scene " && !line.startsWith "view ") ==
                #["reload 1: installed, 1 chunks, 0 commands",
                  "segment: no segment is registered as `nope`",
                  "status 0 in mode-line.active: mode-line.buffer \"scratch\" +4 | mode-line.secondary \"hi\" +4, mode-line.secondary \"1:3\" +4"] &&
              output.any fun line =>
                line.startsWith "scene " &&
                  (line.splitOn
                        s!"echo {"reload: no segment is registered as `nope`".quote}").length ==
                    2 },
    { name :=
        "a script that runs to its end has no failure, and what it asked for was printed before the loop stopped"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory greetConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.run "greet")⟩,
                  ⟨4, .request .show⟩]
                patience
          return failure == none &&
              (← stage.output.get) ==
                #["reload 1: installed, 2 chunks, 1 commands", "run greet: ok", "commands: greet",
                  "text 0: \"\"", "text 1: \"v1\""] },
    { name :=
        "a script whose settle cannot be satisfied fails, it does not hang, and the failure names the settle's line and says a reload was still running"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeFiles directory (greetConfig ++ [("slow.lean", slowChunk)])
            let stage ←
              Stage.new context (gate.around context.elaborator) (Config.Directory.source directory)
            let output := stage.output
            try
              -- The reload is held open, so the settle runs out, after a
              -- fifth of a second. `run` then ends its loop at once, so the
              -- next host starts on a queue nobody else is pulling.
              let failure ←
                Headless.run stage.collaborators
                    #[⟨3, .request .reload⟩, ⟨7, .settle⟩, ⟨8, .request .show⟩] 200
              -- The reload was held at the gate, which is why nothing settled.
              -- The job outlives the loop, so on a slow machine it may only
              -- now be reaching the gate: this is polled.
              let held ← eventually gate.holding.get
              return failure == some (.reloading (some 7)) && held && (← output.get).isEmpty
            finally
              -- The job that was left behind ends; its wake-up is under this
              -- host's source id, which no later host is given.
              gate.open },
    { name :=
        "a script that ends while a reload cannot finish fails at its end, with a reload still running and no line"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeFiles directory (greetConfig ++ [("slow.lean", slowChunk)])
            let stage ←
              Stage.new context (gate.around context.elaborator) (Config.Directory.source directory)
            try
              let failure ← Headless.run stage.collaborators #[⟨1, .request .reload⟩] 200
              return failure == some (.reloading none)
            finally
              gate.open },
    { name :=
        "a wait that runs out says why: a reload is still running, or the editor thread has not answered"
      run := do
        -- A reload held at the gate: the editor thread reaches the marker,
        -- and the reload is what the wait is for.
        let gate ← Gate.new
        let reloading ←
          withHostOver context (greetConfig ++ [("slow.lean", slowChunk)]) gate.around id
              fun session => do
              session.host.send .reload
              try
                unless ← eventually gate.holding.get do
                  return false
                return (← session.host.await 200) == .reloading
              finally
                gate.open
        -- An editor thread held inside an event, by an output port that
        -- does not return until the check lets it: it never reaches the
        -- marker.
        let block ← IO.Promise.new
        let entered ← IO.mkRef false
        let stage ← Stage.new context context.elaborator { chunks := pure #[] }
        let host ←
          Headless.start (scheme := TestScheme.scheme)
              { stage.collaborators with
                emit := fun _ => do
                  entered.set true
                  discard <| IO.wait block.result? }
        try
          host.send .show
          let inside ← eventually entered.get
          let wait ← host.await 200
          block.resolve ()
          let stopped ← host.stop patience
          return reloading && inside && wait == .unanswered && stopped
        finally
          block.resolve ()
          discard <| host.halt patience },
    { name :=
        "a scene directive asks for the last scene, and a commit directive commits the rest of its line"
      run :=
        pure
          ((Headless.script "scene\ncommit hello\n  commit  two words  \ncommit é\n").toOption ==
            some
              #[⟨1, .request .scene⟩, ⟨2, .commit "hello"⟩, ⟨3, .commit "two words"⟩,
                ⟨4, .commit "é"⟩]) },
    { name := "a commit directive with no text is refused, with the number of its line"
      run :=
        pure
          (["commit", "commit   ", "scene now"].all fun line =>
            match Headless.script ("reload\n" ++ line) with
            | .error message => message.startsWith "line 2: "
            | .ok _ => false) },
    { name := "a resize directive is a width and a height, two numbers, with its line's number"
      run :=
        pure
          ((Headless.script "scene\nresize 640 480\n  resize  0   16  \n").toOption ==
            some #[⟨1, .request .scene⟩, ⟨2, .resize 640 480⟩, ⟨3, .resize 0 16⟩]) },
    { name :=
        "a resize directive with no number, with one, with three, or with a part that is no number is refused, with the number of its line"
      run :=
        pure
          (["resize", "resize 640", "resize 640 480 2", "resize wide 480", "resize -1 480",
                "resize 640 4.5"].all
            fun line =>
            match Headless.script ("scene\n" ++ line) with
            | .error message => message.startsWith "line 2: "
            | .ok _ => false) },
    { name :=
        "a script that resizes the frame and asks for the scene prints the scene in a frame of that size, with its one view in the whole of it above the bottom row, one 16-pixel cell of the recorder; a second resize is the next scene's size"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory greetConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .resize 640 480⟩, ⟨2, .request .scene⟩, ⟨3, .resize 320 200⟩,
                  ⟨4, .request .scene⟩]
                patience
          return failure == none &&
              (← stage.output.get) ==
                #["scene 640x480, focused 0, echo \"\", echo padding 8, preedit -, published 1, theme \"default\"",
                  "view 0 0,0 640x464: \"\", scroll 0, selections 0..0, padding 8 8", statusOf,
                  "scene 320x200, focused 0, echo \"\", echo padding 8, preedit -, published 3, theme \"default\"",
                  "view 0 0,0 320x184: \"\", scroll 0, selections 0..0, padding 8 8", statusOf] },
    { name :=
        "a script that commits text and asks for the scene prints the scene: its frame, and a view whose snapshot holds the text, read from the library, with the cursor after it"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory greetConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .scene⟩, ⟨2, .commit "héllo"⟩, ⟨3, .request .scene⟩,
                  ⟨4, .commit " world"⟩, ⟨5, .request .scene⟩]
                patience
          return failure == none &&
              (← stage.output.get) ==
                #["scene: none",
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 1, theme \"default\"",
                  "view 0 0,0 0x0: \"héllo\", scroll 0, selections 6..6, padding 8 8",
                  statusOf (modified := true) (cursor := ⟨0, 5⟩),
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 3, theme \"default\"",
                  "view 0 0,0 0x0: \"héllo world\", scroll 0, selections 12..12, padding 8 8",
                  statusOf (modified := true) (cursor := ⟨0, 11⟩)] },
    { name :=
        "a view's status line is printed as the view's id, its status face if it has one, and each field's face, quoted text and padding when it has one, the left fields and then, after a bar, the right ones; and as - for a status line with no field"
      run :=
        pure
          (Headless.statusLine ⟨3⟩
                #[{ text := "a \"b\"", face := ⟨"one"⟩ }, { text := "é", face := ⟨"two.three"⟩ }] ==
              "status 3: one \"a \\\"b\\\"\", two.three \"é\"" &&
            Headless.statusLine ⟨0⟩ #[] == "status 0: -" &&
            Headless.statusLine ⟨0⟩
                #[{ text := "INSERT", face := ⟨"badge"⟩, padding := 8 },
                  { text := "1:6", face := ⟨"pos"⟩, side := .right, padding := 4 },
                  { text := "●", face := ⟨"mark"⟩, padding := 4 },
                  { text := "All", face := ⟨"pos"⟩, side := .right }] ==
              "status 0: badge \"INSERT\" +8, mark \"●\" +4 | pos \"1:6\" +4, pos \"All\"" &&
            Headless.statusLine ⟨2⟩ #[{ text := "x", face := ⟨"r"⟩, side := .right }]
                (some ⟨"mode-line.inactive"⟩) ==
              "status 2 in mode-line.inactive: | r \"x\"") },
    { name :=
        "the scene prints each view's status line after the view's line, with the fields the loop gives the view: the buffer's name alone before anything is typed, and the modified field after it once text is committed"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory greetConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .key { logical := .named ⟨"F5"⟩ }⟩, ⟨2, .request .scene⟩, ⟨3, .commit "a"⟩,
                  ⟨4, .request .scene⟩]
                patience
          return failure == none && statusOf != statusOf (modified := true) &&
              (← stage.output.get) ==
                #["key arrived: <F5> - -",
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 1, theme \"default\"",
                  "view 0 0,0 0x0: \"\", scroll 0, selections 0..0, padding 8 8", statusOf,
                  "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 3, theme \"default\"",
                  "view 0 0,0 0x0: \"a\", scroll 0, selections 1..1, padding 8 8",
                  statusOf (modified := true) (cursor := ⟨0, 1⟩)] },
    { name :=
        "the scene is published again after a reload installs and after a job's command runs, once a frame exists"
      run :=
        withHost context jobsConfig fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "kept") do
            return false
          session.ask [.scene]
          session.ask [.spawn "count"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          session.clock.advance 10
          unless (← session.host.join patience) == .settled do
            return false
          session.ask [.reload]
          session.ask [.scene]
          -- Between the two scene requests the editor thread handles nine
          -- events, each followed by a scene: the first scene request, the
          -- spawn, the job's wake-up, the reload, the reload's wake-up, and
          -- the four markers the waits posted. Had the job's command or the
          -- reload's install published nothing, the count would be short.
          return (← session.lines) ==
              #["reload 1: installed, 2 chunks, 1 commands",
                "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 1, theme \"default\"",
                "view 0 0,0 0x0: \"kept\", scroll 0, selections 4..4, padding 8 8",
                statusOf (modified := true) (cursor := ⟨0, 4⟩), "spawn count: job 1",
                "job 1 count: ok", "reload 2: installed, 2 chunks, 1 commands",
                "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 10, theme \"default\"",
                "view 0 0,0 0x0: \"kept\", scroll 0, selections 4..4, padding 8 8",
                statusOf (modified := true) (cursor := ⟨0, 4⟩)] },
    { name :=
        "once a command has released the focused buffer's text, a commit is still followed by a scene: its echo is the refusal, and it has no view of that buffer"
      run :=
        withHost context forgetConfig fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "a") do
            return false
          session.ask [.scene, .run "forget"]
          unless ← Event.post (.commit "b") do
            return false
          session.ask [.scene]
          -- Between the two scene requests the editor thread handles four
          -- events, each followed by a scene: the first scene request, the
          -- run, the marker of the wait and the commit. Had the scenes
          -- after the release been refused, the count would be short.
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 1 commands",
                "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 1, theme \"default\"",
                "view 0 0,0 0x0: \"a\", scroll 0, selections 1..1, padding 8 8",
                statusOf (modified := true) (cursor := ⟨0, 1⟩), "run forget: ok",
                "scene 0x0, focused 0, echo \"refused: no such text\", echo padding 8, preedit -, published 5, theme \"default\""] },
    { name :=
        "a program of the editor loop that is refused is printed as refused and hands back nothing, and what it made before the refusal is kept; one that is not refused prints nothing and hands back its result"
      run := do
        let stage ← Stage.new context context.elaborator { chunks := pure #[] }
        let collaborators := stage.collaborators
        let running : Headless.Running Config.Elaborate.State TestScheme.scheme :=
          { texts := RealTexts.over collaborators.published
            display :=
              ← Headless.Host.Display.recorder Headless.cells collaborators.published.reader
            clipboard := (← Clipboard.InProcess.new).handle
            syntaxTree := SyntaxTree.none
            jobs := { services := collaborators.services }, mailbox := ← Job.Mailbox.new }
        let (refused, running) ←
          running.attempt collaborators do
              let made ← createText "made before the refusal"
              (⟨7⟩ : TextId).release
              return made
        let printed ← stage.output.get
        let (kept, _) ←
          running.attempt collaborators do
              (⟨0⟩ : TextId).read
        return refused == none && printed == #["loop: refused: no such text"] &&
            kept == some "made before the refusal" &&
            (← stage.output.get) == printed },
    { name := "a window's close request with nothing unsaved ends the host's loop"
      run := do
        let stage ← Stage.new context context.elaborator { chunks := pure #[] }
        let host ← Headless.start stage.collaborators
        try
          unless ← Event.post .closeRequested do
            return false
          let ended ← eventually (IO.hasFinished host.thread)
          return ended && (← host.halt patience)
        catch error =>
          discard <| host.halt patience
          throw error },
    { name := "each failure is described differently, and a settle's names its line"
      run :=
        let reloading := Headless.Failure.describe 30000 (.reloading (some 12))
        let atEnd := Headless.Failure.describe 30000 (.reloading none)
        let unanswered := Headless.Failure.describe 30000 (.unanswered (some 12))
        let unstopped := Headless.Failure.describe 30000 (.unanswered none)
        pure
          ([reloading, atEnd, unanswered, unstopped].eraseDups.length == 4 &&
            (reloading.splitOn "line 12").length == 2 &&
            (unanswered.splitOn "line 12").length == 2 &&
            (atEnd.splitOn "line").length == 1) }]

/-- The compiled command `split`: it splits the window it is called on. -/
def splitCommand : Config.Registration :=
  { name := "split"
    action :=
      .call fun call => do
        discard <| call.target.window.id.split }

/-- A chunk whose `setup` registers two jobs, a command and a key. `double`
takes one number, sleeps 10 ms, and its command inserts the double, in
brackets, at the cursor of view 0 and messages it. `spinner` sleeps 10 ms,
and its command inserts `spun` and then asks the scratch buffer's text its
revision a thousand million times. `ask`, on `C-c a`, starts `double` with
21. -/
def startingChunk : String :=
  "def setup : SetupM Unit := do
  jobWith \"double\"
      (fun arguments => do
        let [.nat n] := arguments | throw \"double takes one number\"
        sleep 10
        return 2 * n)
      fun n => do
        discard <| (⟨0⟩ : ViewId).insertAtSelections s!\"[{n}]\"
        message s!\"doubled to {n}\"
  job \"spinner\" (fun _ => sleep 10) fun _ => do
    discard <| (⟨0⟩ : ViewId).insertAtSelections \"spun\"
    for _ in [0:1000000000] do
      discard <| (⟨0⟩ : TextId).revision
  command \"ask\" (discard <| startJob \"double\" [.nat 21])
  bindKey \"C-c a\" \"ask\"
"

/-- A chunk whose `setup` registers a command `quitter`: it inserts `typed`
at the cursor of view 0, and then gives up, with a reason. -/
def givingUpChunk : String :=
  "def setup : SetupM Unit := do
  command \"quitter\" do
    discard <| (⟨0⟩ : ViewId).insertAtSelections \"typed\"
    giveUp \"no can do\"
"

/-- A chunk whose `setup` registers a command `stopper`: it inserts `typed`
at the cursor of view 0, and then breaks off, with a reason. -/
def breakingOffChunk : String :=
  "def setup : SetupM Unit := do
  command \"stopper\" do
    discard <| (⟨0⟩ : ViewId).insertAtSelections \"typed\"
    breakOff \"far enough\"
"

/-- A chunk whose `setup` registers two commands and a job. `copy` writes a
text to the clipboard. `paste` puts the text the clipboard holds in the
echo area, or says what it was answered instead. `courier` sleeps 10 ms, and
its command says the text the clipboard holds after `courier read`. -/
def clipboardChunk : String :=
  "def held : EditorM String := do
  match ← Clipboard.read with
  | .ok (some text) => return text
  | .ok none => return \"no text\"
  | .error .unavailable => return \"no clipboard\"

def setup : SetupM Unit := do
  command \"copy\" do
    match ← Clipboard.write \"kept by the host\" with
    | .ok () => message \"written\"
    | .error .unavailable => message \"no clipboard\"
  command \"paste\" do
    message (← held)
  job \"courier\" (fun _ => sleep 10) fun _ => do
    message s!\"courier read {← held}\"
"

/-- The checks of commands the headless host runs through its loop that no
key ran, and of the jobs commands start (`Editor/Headless.lean`), on the
real queue, the real text binding, the library's interrupt flag and the
real elaborator, with the test scheme. -/
def hostLoopChecks (context : Context) : List Check :=
  [{  name :=
        "the driver's run of a command goes through the loop: a command that splits its window leaves two views in the scene, and a run before any window event makes the frame"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "split", .run "stamp", .run "missing"]
            let (echo, views) ← session.scene
            return (← session.output.get).extract 0 3 ==
                  #["run split: ok", "run stamp: ok", "run missing: no such command"] &&
                echo == "missing: no such command".quote &&
                views ==
                  #["view 0 0,0 0x0: \"!\", scroll 0, selections 1..1, padding 8 8",
                    "view 1 0,0 0x0: \"!\", scroll 0, selections 1..1, padding 8 8"])
          { dispatchCompiled with commands := dispatchCompiled.commands.push splitCommand } },
    { name :=
        "the driver's run of a command that fails is rolled back and says so: the output names the refusal, the scene's echo is its error, and the view's text is that before the command"
      run :=
        withHost context []
          (fun session => do
            unless ← Event.post (.commit "abcd") do
              return false
            session.ask [.run "boom"]
            return (← session.output.get) == #["run boom: refused: bad range"] &&
                (← session.scene) == ("boom: refused: bad range".quote, #[viewLine "abcd" 4]))
          dispatchCompiled },
    { name :=
        "the driver's run of a command of config's that gives up is rolled back and printed so: the output says it gave up, with its reason, the scene's echo is its name and the reason with no refused, and the view's text is that before the command"
      run :=
        withHost context [("config.lean", givingUpChunk)] fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "abcd") do
            return false
          session.ask [.run "quitter"]
          return (← session.lines) ==
                #["reload 1: installed, 1 chunks, 1 commands", "run quitter: gave up: no can do"] &&
              (← session.scene) == ("quitter: no can do".quote, #[viewLine "abcd" 4]) },
    { name :=
        "the driver's run of a command of config's that breaks off keeps what the command did and is printed so: the output says it broke off, with its reason, the scene's echo is its name and the reason with no refused, and the view's text holds what the command inserted"
      run :=
        withHost context [("config.lean", breakingOffChunk)] fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "abcd") do
            return false
          session.ask [.run "stopper"]
          return (← session.lines) ==
                #["reload 1: installed, 1 chunks, 1 commands",
                  "run stopper: broke off: far enough"] &&
              (← session.scene) == ("stopper: far enough".quote, #[viewLine "abcdtyped" 9]) },
    { name :=
        "the host keeps a clipboard of its own: before a write a command of config's reads no text, after one command wrote a text the next reads it, and so does a finished job's command"
      run :=
        withHost context [("config.lean", clipboardChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "paste"]
          let (empty, _) ← session.scene
          session.ask [.run "copy"]
          let (written, _) ← session.scene
          session.ask [.run "paste"]
          let (pasted, _) ← session.scene
          session.ask [.spawn "courier"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          session.clock.advance 10
          let joined ← session.host.join patience
          return empty == "no text".quote && written == "written".quote &&
              pasted == "kept by the host".quote &&
              joined == .settled &&
              (← session.scene).1 == "courier read kept by the host".quote },
    { name :=
        "the driver's run of a command is guarded: with the interrupt key arrived the command that loops over requests is stopped, the output says it was interrupted, and the flag is down once the loop has taken the key"
      run :=
        withHost context []
          (fun session => do
            -- The loop has started, so the library knows the interrupt key:
            -- the press raises the flag as it arrives, whether the loop has
            -- begun the command by then or not.
            session.ask []
            session.host.send (.run "spin")
            session.host.press Watch.interruptKey
            unless ← session.host.settle patience do
              return false
            return ((← session.output.get).filter (·.startsWith "run ")) ==
                  #["run spin: interrupted"] &&
                !(← Ffi.interruptRaised) &&
                (← session.scene) == ("spin: interrupted".quote, #[viewLine "" 0]))
          dispatchCompiled },
    { name :=
        "a host that cannot make its frame says so for a run, with the refusal that stopped it, and runs nothing"
      run :=
        withRunning context
          (fun collaborators =>
            { collaborators with
              start := throw .noSuchText, commands := dispatchCompiled.commands })
          fun collaborators running stage => do
          let running ← running.run collaborators { command := "stamp" }
          return running.frame.isNone &&
              (← stage.output.get) == #["loop: refused: no such text", "run stamp: no frame"] },
    { name :=
        "a job's post runs on the editor thread as a command labelled with the job while the job still runs, and is printed; the post of a job removed before its event is taken is dropped, unprinted"
      run :=
        withRunning context
          (fun collaborators =>
            { collaborators with
              commands :=
                #[{ name := "mark"
                    action :=
                      .call fun call => do
                        if let [.str text] := call.arguments then
                          discard <| call.target.window.id.insertAtSelections text }]
              compiledJobs :=
                #[{ name := "poster"
                    work := fun _ =>
                      Work.of
                        (fun _ => do
                          post { command := "mark", arguments := [.str "p"] }
                          sleep 10)
                        fun _ => pure () }] })
          fun collaborators running stage => do
          let (first, running) ← running.startJob collaborators "poster"
          let some first := first | return false
          unless ← eventually (return (← running.mailbox.size) == 1) do
            return false
          let running := { running with jobs := ← running.jobs.cancel first }
          let running ← running.posted collaborators first
          let dropped := (← stage.output.get).isEmpty && (← running.mailbox.size) == 0
          let (second, running) ← running.startJob collaborators "poster"
          let some second := second | return false
          unless ← eventually (return (← running.mailbox.size) == 1) do
            return false
          let running ← running.posted collaborators second
          let live := running.jobs.has second
          running.show collaborators
          let output ← stage.output.get
          running.jobs.cancelAll
          return dropped && live && output[0]? == some s!"job {second} poster: ok" &&
              output.contains "text 0: \"p\"" },
    { name :=
        "a key's command starts a job with an argument: the host says it started, keys sent while the job sleeps are handled before its result, and once the clock lets it go its command runs after them, with the value the job computed in the text and in the scene's echo"
      run :=
        withHost context [("10-starting.lean", startingChunk)]
          (fun session => do
            session.ask [.reload]
            session.typed "C-c a"
            unless ← eventually (return (← session.clock.waiting) == 1) do
              return false
            session.typed "C-c s C-c s"
            let sleeping ← session.scene
            let before ← session.output.get
            session.clock.advance 10
            let joined ← session.host.join patience
            let after := (← session.output.get).extract before.size
            return before.contains "job 1 double: started" &&
                !before.any (·.startsWith "job 1 double: ok") &&
                sleeping == ("".quote, #[viewLine "!!" 2]) &&
                joined == .settled &&
                after == #["job 1 double: ok"] &&
                (← session.scene) == ("doubled to 42".quote, #[viewLine "!![42]" 6]))
          dispatchCompiled },
    { name :=
        "a finished job's command is guarded as a key's is: the interrupt key that arrives as it is delivered stops the command that loops over requests, the output says the job was interrupted, the view's text is that before the delivery, and the flag is down once the loop has taken the key"
      run :=
        withHost context [("10-starting.lean", startingChunk)] fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "ab") do
            return false
          session.ask [.spawn "spinner"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          -- The loop reads the clock just before a command it runs: held
          -- there, the editor thread is inside the delivery, and the
          -- job's command has not started.
          let arrivals ← session.clock.held
          let hold ← session.clock.holdReads
          session.clock.advance 10
          unless ← eventually (return (← session.clock.held) == arrivals + 1) do
            hold.resolve ()
            return false
          session.host.press Watch.interruptKey
          hold.resolve ()
          unless ← session.host.settle patience do
            return false
          return (← session.output.get).contains "job 1 spinner: interrupted" &&
              !(← Ffi.interruptRaised) &&
              (← session.scene) == ("job 1 spinner: interrupted".quote, #[viewLine "ab" 2]) },
    { name :=
        "a host is handed compiled jobs: a compiled command starts one before any config is loaded, a reload that installs does not cancel it, and once the clock lets it go its command runs"
      run :=
        withHost context [("10-empty.lean", emptyChunk)]
          (fun session => do
            session.ask [.run "rest"]
            unless ← eventually (return (← session.clock.waiting) == 1) do
              return false
            session.ask [.reload]
            let reloaded ← session.output.get
            session.clock.advance 10
            let joined ← session.host.join patience
            return reloaded ==
                  #["run rest: ok", "job 1 nap: started",
                    "reload 1: installed, 1 chunks, 0 commands"] &&
                joined == .settled &&
                (← session.output.get).extract reloaded.size == #["job 1 nap: ok"] &&
                (← session.scene) == ("".quote, #[viewLine "napped" 6]))
          nappingCompiled }]

/-- The directives of one ex line of a script: the ex command run by its
name, which asks, `line` committed into the minibuffer, and the accept
key. -/
def exLineDirectives (line : String) : List Headless.Directive :=
  [.request (.run Ex.name), .commit line] ++ acceptKeys.map .key

/-- A script of `directives`, one a line, numbered from 1. -/
def scriptOf (directives : List Headless.Directive) : Array Headless.Line :=
  (directives.zipIdx.map fun (directive, index) => ⟨index + 1, directive⟩).toArray

/-- Runs `directives` as a script (`Headless.run`) against a host of its own
over the library's file service (`Stage.overFiles`), with an empty config
directory, that is handed what the executable is handed for the ex line:
the ex line's commands and the ex names that ship, the minibuffer's
commands and its mode, and the file commands with their jobs. What `run`
answered, and every line the host printed. -/
def ranScript (context : Context) (directives : List Headless.Directive) :
    IO (Option Headless.Failure × Array String) :=
  IO.FS.withTempDir fun directory => do
    let stage ←
      Stage.overFiles context (Config.Directory.source directory)
          { commands := Ex.commands ++ Minibuffer.commands ++ Files.commands
            jobs := Files.jobs
            modes := Minibuffer.modes
            ex := Ex.bindings }
    let failure ← Headless.run stage.collaborators (scriptOf directives) patience
    return (failure, ← stage.output.get)

/-- The checks of a script that a command ends (`Editor/Headless.lean`,
"The driver, and the command line"), with `Headless.run` on scripts built
here, over the real elaborator, the real queue, the real text binding and
the library's file service, on a file each check writes in a temporary
directory of its own: the phase's first two acceptance criteria through the
host. They share the file checks' table of waits and completion pump, so
they run after them.

Each script that opens a file has a `join` after the `e` line: the open is
a job, and without the wait the text would be committed into the scratch
buffer. The `wq` script has a `join` after the `wq` line too: the quit it
asks for waits for the save, so without the wait the `show` line would be
handled while the save runs, and the end of the script would stop the loop,
which cancels the save. -/
def exScriptChecks (context : Context) : List Check :=
  let listed (output : Array String) : Bool := output.any (·.startsWith "commands:")
  [{  name :=
        "criterion 1 through the host: a script that runs e on a file, joins, commits text, runs w, joins, runs q, and then has a show line: the script has no failure, the file holds the committed text before what it held, and the show line was not run"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          let (failure, output) ←
            ranScript context
                (exLineDirectives s!"e {path}" ++ [.join, .commit "x"] ++ exLineDirectives "w" ++
                  [.join] ++
                  exLineDirectives "q" ++
                  [.request .show])
          return failure == none && (← IO.FS.readBinFile path) == ("x" ++ noteText).toUTF8 &&
              endedOk output Files.saveJob &&
              !listed output },
    { name :=
        "criterion 2 through the host: the same script with wq in place of w, the join and q, and a join after it: the script has no failure, the file holds the buffer's text, and the show line was not run"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          let (failure, output) ←
            ranScript context
                (exLineDirectives s!"e {path}" ++ [.join, .commit "x"] ++ exLineDirectives "wq" ++
                  [.join, .request .show])
          return failure == none && (← IO.FS.readBinFile path) == ("x" ++ noteText).toUTF8 &&
              endedOk output Files.saveJob &&
              !listed output },
    { name :=
        "a script whose q is refused, for a file's buffer that was edited, runs its later lines: the show line prints the commands, the script has no failure, and the file is as it was"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          let (failure, output) ←
            ranScript context
                (exLineDirectives s!"e {path}" ++ [.join, .commit "x"] ++ exLineDirectives "q" ++
                  [.request .show])
          return failure == none && listed output &&
              (← IO.FS.readBinFile path) == noteText.toUTF8 },
    { name :=
        "once a step said stop the host runs no further invocation: a command that asks for quit and then for the open command, with a path, to be run after it ends the loop at quit, and the open command never runs: the host prints the run alone and starts no job; with a command that says other in place of quit, the load job is started"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          let handing (first : String) : Config.Registration :=
            { name := s!"hand-{first}"
              action :=
                .plain do
                  Editor.invoke { command := first }
                  Editor.invoke { command := Files.openName, arguments := [.str path.toString] } }
          let compiled : Compiled :=
            { exCompiled with
              commands := exCompiled.commands ++ #[handing Ex.quitName, handing "other"]
              jobs := Files.jobs }
          let started := s!"job 1 {Files.loadJob}: started"
          let ran (name : String) : IO (Option (Headless.Wait × Array String)) := do
            let stage ← Stage.new context context.elaborator { chunks := pure #[] } compiled
            let host ← Headless.start stage.collaborators
            try
              host.send (.run name)
              let joined ← host.join patience
              let halted ← host.halt patience
              let output ← stage.output.get
              return if halted then some (joined, output) else none
            catch error =>
              discard <| host.halt patience
              throw error
          let left ← ran s!"hand-{Ex.quitName}"
          let went ← ran "hand-other"
          return left == some (.ended, #[s!"run hand-{Ex.quitName}: ok"]) &&
              (went.map fun (joined, output) =>
                  joined == .settled && output.contains "run hand-other: ok" &&
                    output.contains started) ==
                some true },
    { name :=
        "a wait on a host whose loop a command ended answers that the loop has ended, a settle and a join alike, which is no failure of a script, and halting the host then answers that it stopped"
      run := do
        let stage ← Stage.new context context.elaborator { chunks := pure #[] } exCompiled
        let host ← Headless.start stage.collaborators
        try
          host.send (.run Ex.quitName)
          let ended ← eventually (IO.hasFinished host.thread)
          let awaited ← host.await patience
          let joined ← host.join patience
          return ended && awaited == .ended && joined == .ended &&
              Headless.Wait.ended.failure (some 3) == none &&
              (← host.halt patience) &&
              (← stage.output.get) == #[s!"run {Ex.quitName}: ok"]
        catch error =>
          discard <| host.halt patience
          throw error }]

/-- A chunk whose `greet` does not elaborate: a number where `message` takes
a string, on its first line. -/
def brokenGreetChunk : String :=
  "def greet : EditorM Unit := message 7\n"

/-- Whether `echo`, quoted as a scene line has it, is a rejected reload's
error about the first line of `10-greet.lean`. The column and the message
are Lean's, so only their places are checked. -/
def isGreetError (echo : String) : Bool :=
  echo.startsWith "\"reload: 10-greet.lean:1:" && (echo.splitOn ": error: ").length == 2

/-- The checks of a reload's errors in the echo area (`Config.Report.echo`,
`Editor/Headless.lean`), through the host with the real elaborator over a
config directory. -/
def reloadEchoChecks (context : Context) : List Check :=
  [{  name :=
        "a rejected reload says its first error in the echo area and the old config's command still runs, what that command says replaces the error, and a reload that installs clears nothing"
      run :=
        withHost context helloConfig fun session => do
          session.ask [.reload]
          session.ask [.run "greet"]
          let said ← session.echo
          session.write "10-greet.lean" brokenGreetChunk
          session.ask [.reload]
          let rejected ← session.echo
          session.ask [.run "greet"]
          let replaced ← session.echo
          session.ask [.reload]
          let again ← session.echo
          session.write "10-greet.lean" helloChunk
          session.ask [.reload]
          let kept ← session.echo
          session.ask [.run "greet"]
          let after ← session.echo
          let lines ← session.lines
          return said == "\"hello\"" && isGreetError rejected && replaced == "\"hello\"" &&
              again == rejected &&
              kept == rejected &&
              after == "\"hello\"" &&
              lines.contains "reload 2: rejected" &&
              lines.contains "diagnostic: 10-greet.lean: error" &&
              lines.contains "reload 4: installed, 2 chunks, 1 commands" &&
              (lines.filter (· == "run greet: ok")).size == 3 },
    { name :=
        "a reload rejected before the frame is made is said in the echo area once the frame is made"
      run :=
        withHost context [("10-greet.lean", brokenGreetChunk)] fun session => do
          session.ask [.reload]
          let before ← session.scene
          session.host.resize 80 64
          session.ask []
          let made ← session.echo
          return before == ("", #[]) && isGreetError made }]

/-- The checks of what the executable's hosts are handed as compiled code
(`Headless.shippedOver`, which `Headless.shipped` makes them with), on the
registry a host starts with (`Headless.compiled`) and the test scheme's
keymap of its bindings. Its services are a fake clock's over a table of
waits of its own, which no pump reads: nothing here starts a job. -/
def shippedChecks (_ : Unit) : List Check :=
  [{  name :=
        "the executable's hosts start with the source files registered compiled in the category file, its job files, the style path, and the file category matched with path"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        return registry.sources.any
              (fun entry => entry.source.name == "files" && entry.owner == .compiled) &&
            registry.sourcesIn Completion.Paths.category == #["files"] &&
            registry.jobs.any
              (fun entry =>
                entry.registration.name == Completion.Paths.job && entry.owner == .compiled) &&
            (registry.style? "path").isSome &&
            (registry.matching.styleFor (some Completion.Paths.category)).name == "path" &&
            registry.matching.ownerFor (some Completion.Paths.category) == .compiled },
    { name :=
        "the executable's hosts start with find-file-in-workspace registered compiled, the source workspace-files registered compiled in the category workspace-file, which it alone is in, filtered and answered later by its job workspace-files, registered compiled"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        return (registry.find? Workspace.FindFile.name).any (·.owner == .compiled) &&
            registry.sources.any
              (fun entry =>
                entry.source.name == Workspace.FindFile.sourceName && entry.owner == .compiled &&
                  entry.source.filtered &&
                  entry.source.later.map (·.job) == some Workspace.FindFile.job) &&
            registry.sourcesIn Workspace.FindFile.category == #[Workspace.FindFile.sourceName] &&
            registry.jobs.any
              (fun entry =>
                entry.registration.name == Workspace.FindFile.job && entry.owner == .compiled) },
    { name :=
        "the executable's hosts start with find-file-in-project registered compiled, the source project-workspaces registered compiled in the category project-workspace, which it alone is in, answered later by its job project-workspaces, and that job, project-workspace-choose and project-workspace-find registered compiled"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let jobs :=
          [Workspace.FindInProject.job, Workspace.FindInProject.chooseJob,
            Workspace.FindInProject.findJob]
        return (registry.find? Workspace.FindInProject.name).any (·.owner == .compiled) &&
            registry.sources.any
              (fun entry =>
                entry.source.name == Workspace.FindInProject.sourceName &&
                  entry.owner == .compiled &&
                  entry.source.later.map (·.job) == some Workspace.FindInProject.job) &&
            registry.sourcesIn Workspace.FindInProject.category ==
              #[Workspace.FindInProject.sourceName] &&
            jobs.all fun name =>
              registry.jobs.any
                (fun entry => entry.registration.name == name && entry.owner == .compiled) },
    { name :=
        "the executable's hosts start with the source words registered compiled in the category word, its job words registered compiled, the at-point source words registered compiled, and a modeless buffer's at-point chain is words"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        return registry.sources.any
              (fun entry => entry.source.name == "words" && entry.owner == .compiled) &&
            registry.sourcesIn Completion.Words.category == #["words"] &&
            registry.jobs.any
              (fun entry =>
                entry.registration.name == Completion.Words.job && entry.owner == .compiled) &&
            registry.atPoints.any
              (fun entry => entry.atPoint.name == "words" && entry.owner == .compiled) &&
            registry.atPointNames none #[] == #["words"] &&
            registry.unknownAtPoints == #[] },
    { name :=
        "the executable's hosts start with the code mode and the languages rust, json, markdown, toml and lean, in that order, registered for the owner compiled"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        return registry.modes.any
              (fun entry => entry.mode.name == Language.codeName && entry.owner == .compiled) &&
            (registry.mode? Language.codeName).any (·.syntaxTreeOfLanguage) &&
            registry.languages.map (fun entry => (entry.language.name, entry.owner == .compiled)) ==
              #[("rust", true), ("json", true), ("markdown", true), ("toml", true),
                ("lean", true)] },
    { name :=
        "the executable's hosts start with C-s-f bound to toggle-fullscreen, s-m to minimise-window and s-q to quit, each registered for the owner compiled; with switch-buffer, list-buffers and close-buffer registered for it, and the ex names b, ls and bd bound to them"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let bound (text : String) : Option Invocation :=
          (registry.keymap TestScheme.scheme).find? (keysOf text)
        let compiled (name : String) : Bool := (registry.find? name).any (·.owner == .compiled)
        let ex (name : String) : Option String := (registry.ex? name).map (·.command)
        return bound "C-s-f" == some { command := "toggle-fullscreen" } &&
            bound "s-m" == some { command := "minimise-window" } &&
            bound "s-q" == some { command := Ex.quitName } &&
            compiled "toggle-fullscreen" &&
            compiled "minimise-window" &&
            compiled Ex.quitName &&
            [Buffers.switchName, Buffers.listName, Buffers.closeName].all compiled &&
            ex "b" == some Buffers.switchName &&
            ex "ls" == some Buffers.listName &&
            ex "bd" == some Buffers.closeName },
    { name :=
        "the executable's hosts start with every window command registered for the owner compiled, every command the Vim scheme's C-w table names among them"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let compiled (name : String) : Bool := (registry.find? name).any (·.owner == .compiled)
        return !WindowCommands.commands.isEmpty && WindowCommands.commands.all (compiled ·.name) &&
            Vim.Default.windowKeys.all (compiled ·.2) },
    { name :=
        "the executable's hosts start with every tab command registered for the owner compiled, every command the Vim scheme's tab table names among them"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let compiled (name : String) : Bool := (registry.find? name).any (·.owner == .compiled)
        return !TabCommands.commands.isEmpty && TabCommands.commands.all (compiled ·.name) &&
            Vim.Default.tabKeys.all (compiled ·.2) },
    { name :=
        "the executable's hosts start with the completion sources that ship registered for the owner compiled, so config can ask for each by name: the ex line's history and its names, the buffers, the tabs, the themes and the commands; and with the command prompt, execute-command, registered for that owner"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let compiled (name : String) : Bool :=
          registry.sources.any fun entry => entry.source.name == name && entry.owner == .compiled
        return [Ex.historySource.name, Ex.namesSource.name, Buffers.source.name,
                  TabCommands.source.name, Themes.source.name, ExecuteCommand.source.name].all
              (fun name => compiled name && (registry.source? name).isSome) &&
            (registry.find? ExecuteCommand.name).any (·.owner == .compiled) },
    { name :=
        "the executable's hosts start with the shipped completion styles, fuzzy and orderless, and the shipped completion display, minibuffer, registered for the owner compiled, and with the shipped sources of each shipped prompt's category the sources in the order of that prompt's defaults"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let compiled (name : String) : Bool :=
          registry.styles.any fun entry => entry.style.name == name && entry.owner == .compiled
        return ["fuzzy", "orderless"].all compiled &&
            Completion.Displays.shipped.all
              (fun display =>
                registry.displays.any fun entry =>
                  entry.display.name == display.name && entry.owner == .compiled) &&
            registry.displays.any (·.display.name == "minibuffer") &&
            registry.sourcesIn "ex-line" == #[Ex.historySource.name, Ex.namesSource.name] &&
            registry.sourcesIn "buffer" == #[Buffers.source.name] &&
            registry.sourcesIn "tab" == #[TabCommands.source.name] &&
            registry.sourcesIn "theme" == #[Themes.source.name] &&
            registry.sourcesIn ExecuteCommand.category == #[ExecuteCommand.source.name] },
    { name :=
        "the executable's hosts start with compile, recompile, compile-confirm, kill-compilation, compilation-output, next-error, previous-error and compile-goto-error, the job compile-run and the mode compilation registered for the owner compiled, and the ex names compile, which takes text, recompile, kill-compilation, next-error and previous-error bound to them"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let compiled (name : String) : Bool := (registry.find? name).any (·.owner == .compiled)
        return [Compile.compileName, Compile.recompileName, Compile.confirmName, Compile.killName,
                  Compile.outputName, Compile.nextName, Compile.previousName, Compile.gotoName].all
              compiled &&
            (registry.findJob? Compile.runJob).any (·.owner == .compiled) &&
            (registry.mode? Compile.modeName).isSome &&
            (registry.mode? Minibuffer.mode.name).isSome &&
            registry.ex? "compile" ==
              some { name := "compile", command := Compile.compileName, takes := .text } &&
            (registry.ex? "recompile").map (·.command) == some Compile.recompileName &&
            (registry.ex? "kill-compilation").map (·.command) == some Compile.killName &&
            (registry.ex? "next-error").map (·.command) == some Compile.nextName &&
            (registry.ex? "previous-error").map (·.command) == some Compile.previousName },
    { name :=
        "the executable's hosts start with compile-command registered for the owner compiled, and the ex name compile-command, which takes text, bound to it; no default key binds it"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        return (registry.find? Compile.commandName).any (·.owner == .compiled) &&
            registry.ex? "compile-command" ==
              some { name := "compile-command", command := Compile.commandName, takes := .text } &&
            !(registry.bindings.any (·.binding.command == Compile.commandName)) },
    { name :=
        "the executable's hosts start with the jobs find-mode-markers and compile-list registered for the owner compiled, beside find-workspace, and with cargo-mode, lake-mode and mise-mode as the compiled contributions, in that order"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        return (registry.findJob? Workspace.markerJob).any (·.owner == .compiled) &&
            (registry.findJob? Workspace.findJob).any (·.owner == .compiled) &&
            (registry.findJob? Compile.listJob).any (·.owner == .compiled) &&
            (registry.contributions.filter (·.owner == .compiled)).map (·.contribution.mode) ==
              #["cargo-mode", "lake-mode", "mise-mode"] },
    { name :=
        "the executable's hosts start with the command load-theme and the theme default, the built-in one, registered for the owner compiled"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        return (registry.find? Themes.loadName).any (·.owner == .compiled) &&
            registry.theme? Theme.defaultName ==
              some { name := "default", theme := Theme.builtin } &&
            registry.themes.all (·.owner == .compiled) },
    { name :=
        "the executable's hosts publish the standard menu bar, and bind s-o, s-s, s-z, s-Z, s-x, s-c, s-v and s-a to open-file, save-buffer, undo, redo, clipboard-cut, clipboard-copy, clipboard-paste and select-all for the owner compiled"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let bound (text : String) : Option Invocation :=
          (registry.keymap TestScheme.scheme).find? (keysOf text)
        let compiled (name : String) : Bool := (registry.find? name).any (·.owner == .compiled)
        return shipped.menu == some Menu.standard &&
            bound "s-o" == some { command := "open-file" } &&
            bound "s-s" == some { command := "save-buffer" } &&
            bound "s-z" == some { command := "undo" } &&
            bound "s-Z" == some { command := "redo" } &&
            bound "s-x" == some { command := "clipboard-cut" } &&
            bound "s-c" == some { command := "clipboard-copy" } &&
            bound "s-v" == some { command := "clipboard-paste" } &&
            bound "s-a" == some { command := "select-all" } &&
            ["open-file", "save-buffer", "undo", "redo", "clipboard-cut", "clipboard-copy",
                  "clipboard-paste", "select-all"].all
              compiled }]

/-- A chunk whose `setup` registers `greet` and the job `follow`, which
watches the made-up file `/watched/f`, waits for its next delivery, and
finishes with a command that makes a text holding `version`, the config's. -/
def followChunk (version : String) : String :=
  "def follow : Unit → JobM String := fun _ => do
  let .ok watch ← FileWatch.start (.file \"/watched/f\") { window := 0, bound := 8 }
    | throw \"the watch was refused\"
  let .ok _ ← FileWatch.next watch | throw \"the read was refused\"
  return \"" ++
    version ++
    "\"

def setup : SetupM Unit := do
  command \"greet\" greet
  job \"follow\" follow fun version => discard <| createText version
"

/-- A config of two chunks: `greet`, and a `setup` that registers it and the
job `follow` of version `v1`. -/
def followConfig : List (String × String) :=
  [("10-greet.lean", greetChunk "v1"), ("20-setup.lean", followChunk "v1")]

/-- The checks of a config's watches across a reload, through the headless
host over the fake watch service: after a reload installs, only the watches
the new config made deliver; a rejected reload leaves the old one's
watching. -/
def watchReloadChecks (context : Context) : List Check :=
  [{  name :=
        "after a reload installs, only the watches the new config made deliver: the old config's job is cancelled before the reload is reported, its watch ends, and the new config's job is told of the change and says the new version"
      run :=
        withHost context followConfig fun session => do
          session.ask [.reload]
          session.ask [.spawn "follow"]
          unless ← eventually (return (← session.watches.watching) == 1) do
            return false
          let firstWatch := ((← session.watches.started)[0]?.map (·.1.toNat)).getD 0
          session.write "20-setup.lean" (followChunk "v2")
          session.ask [.reload]
          let oldEnded ←
            eventually do
                return (← session.watches.watching) == 0 &&
                    (← session.watches.ended) == #[firstWatch]
          let afterReload ← session.output.get
          session.ask [.spawn "follow"]
          unless ← eventually (return (← session.watches.watching) == 1) do
            return false
          session.watches.change "/watched/f" #[.written]
          let joined ← session.host.join patience
          session.ask [.show]
          let lines ← session.output.get
          let later := lines.extract afterReload.size lines.size
          return oldEnded && joined == .settled &&
              afterReload ==
                #["reload 1: installed, 2 chunks, 1 commands", "spawn follow: job 1",
                  "job 1 follow: cancelled", "reload 2: installed, 2 chunks, 1 commands"] &&
              later.contains "job 2 follow: ok" &&
              later.contains "text 1: \"v2\"" &&
              !later.any (·.startsWith "job 1") },
    { name :=
        "a rejected reload leaves the old config's watch watching: its job is told of the change and says the old version"
      run :=
        withHost context followConfig fun session => do
          session.ask [.reload]
          session.ask [.spawn "follow"]
          unless ← eventually (return (← session.watches.watching) == 1) do
            return false
          session.write "10-greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
          session.ask [.reload]
          let stillWatching :=
            (← session.watches.watching) == 1 && (← session.watches.ended).isEmpty
          session.watches.change "/watched/f" #[.written]
          let joined ← session.host.join patience
          session.ask [.show]
          let lines ← session.lines
          return stillWatching && joined == .settled && lines.contains "reload 2: rejected" &&
              lines.contains "job 1 follow: ok" &&
              lines.contains "text 1: \"v1\"" }]

/-- Runs `check` against a host started on a fresh temporary directory
holding `files`, with the real elaborator, whose jobs share the environments
over a reference the check is handed, which reports as the executable's
host does (`Headless.reportedEnvironments`), and stops the host. The
directory is removed. -/
def withEnvironments (context : Context) (files : List (String × String))
    (check : Session → IO.Ref Process.Environments → Job.Environments → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory files
    let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
    let state ← IO.mkRef ({} : Process.Environments)
    let environments := Headless.reportedEnvironments state stage.collaborators.environment
    let collaborators :=
      { stage.collaborators with services := { stage.collaborators.services with environments } }
    onStage { stage with collaborators } fun host stage =>
        check
          { host, directory, output := stage.output, threads := stage.threads, clock := stage.clock,
            watches := stage.watches, log := stage.log }
          state environments

/-- A chunk whose `setup` sets the process environment to `setting`, written
as Lean. -/
def environmentChunk (setting : String) : String :=
  s!"def setup : SetupM Unit := do\n  processEnvironment {setting}\n"

/-- An entry of a lookup that failed, as a host's environments hold one. -/
def failedLookup : Process.Entry :=
  { stamps := #[], found := .failed (.exited 1 "not trusted") }

/-- The checks of the host's environments (`Editor/Headless.lean`, "A
child's environment"), over the headless host and the real elaborator: a
reload that installs puts config's setting in the state every job shares and
drops every entry, a rejected one changes neither, and a message the
environments report is the echo of the next scene. -/
def environmentHostChecks (context : Context) : List Check :=
  [{  name :=
        "an installed reload whose setup sets the process environment puts that setting in the host's environments and drops every entry; a rejected reload changes neither"
      run :=
        withEnvironments context [("10-setup.lean", environmentChunk ".inherited")]
          fun session state _ => do
          state.set { entries := #[("/p/d", failedLookup)] }
          session.ask [.reload]
          let installed ← state.get
          state.modify fun held => { held with entries := #[("/p/d", failedLookup)] }
          session.write "10-setup.lean" "def setup : SetupM Unit := oops"
          session.ask [.reload]
          let rejected ← state.get
          return installed.setting == .inherited && installed.entries.isEmpty &&
              rejected.setting == .inherited &&
              rejected.entries == #[(("/p/d" : System.FilePath), failedLookup)] },
    { name := "a config that does not set the process environment installs auto"
      run :=
        withEnvironments context [("10-setup.lean", "def setup : SetupM Unit := pure ()")]
          fun session state _ => do
          state.set { setting := .mise none }
          session.ask [.reload]
          return (← state.get).setting == .auto },
    { name := "a failed lookup the host's environments record is the echo of the next scene"
      run :=
        withEnvironments context [] fun session _ environments => do
          session.host.resize 160 96
          session.ask []
          environments.ask (.record "/p/d" failedLookup)
          let (echo, _) ← session.scene
          return echo == (Process.failureMessage "/p/d" (.exited 1 "not trusted")).quote }]

end ConfigTest
