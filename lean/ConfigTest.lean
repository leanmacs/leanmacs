import ConfigFixture
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Headless

/-!
# Checks of the config session against the real elaborator

The `config-test` executable is linked exactly like `editor`, with the glue
object, the Rust archive and Lean's elaborator. `mise run ffi-test` runs it
as `config-test <sysroot> <olean dir>`: the Lean toolchain's directory and
the directory holding the package's `.olean` files. It reads nothing from the
environment or the working directory. It runs every check in `checks`, names
the ones that failed, and exits non-zero if any did.

The model tests (`ModelTest.lean`) pin the decisions of the config session on
fakes. The checks here pin what only real collaborators can show: that the
real elaborator behaves as the fake of its port assumes
(`elaboratorChecks`).

All the checks share one import of the base, made once in `main`: a second
import in one process about doubles its memory.

No check makes the process abort. In particular none evaluates a declaration
that reads an `initialize`d constant of config's, and none runs config that
recurses without bound.
-/

namespace ConfigTest

open Editor

/-- One behaviour, and how to observe it. -/
structure Check where
  /-- What must hold, as a sentence; printed when it does not. -/
  name : String
  /-- Observes the behaviour; `true` when it holds. -/
  run : IO Bool

/-- What every check is given. -/
structure Context where
  /-- The real elaborator, whose `base` hands back the one import the checks
  share. -/
  elaborator : Config.Elaborator Config.Elaborate.State
  /-- The base: the state after importing `Editor` and `ConfigFixture`. -/
  base : Config.Elaborate.State
  /-- What `ConfigFixture.bump` returned to compiled code before the base was
  imported. -/
  bumped : Nat
  /-- The next source id no host of this process has posted under. -/
  ids : IO.Ref UInt64

/-- Evaluates the constant `name` of `environment` as an `IO Nat`. It is
`unsafe` because evaluating a constant trusts the type it is given. -/
unsafe def evalProbeUnsafe (environment : Lean.Environment) (name : Lean.Name) :
    Except String (IO Nat) :=
  environment.evalConst (IO Nat) {} name

/-- The action the constant `name` of `environment` is, which must have the
type `IO Nat`; or why it could not be evaluated. -/
@[implemented_by evalProbeUnsafe]
opaque evalProbe (environment : Lean.Environment) (name : Lean.Name) : Except String (IO Nat)

/-- Elaborates the chunk called `name` on the base. -/
def onBase (context : Context) (name text : String) :
    IO (Config.ChunkResult Config.Elaborate.State) :=
  context.elaborator.chunk context.base { name, text }

/-- Whether a chunk was rejected: it left no state, and it has an error
diagnostic tagged with the chunk's name. -/
def rejected (name : String) (result : Config.ChunkResult Config.Elaborate.State) : Bool :=
  result.state.isNone &&
    result.diagnostics.any fun diagnostic =>
      diagnostic.source == name && diagnostic.severity == .error

/-- Whether asking for the `setup` program of a config made of the one chunk
`text` gives error diagnostics tagged `setup`, and no program. The chunk
itself must elaborate. -/
def setupRefused (context : Context) (text : String) : IO Bool := do
  let some state := (← onBase context "config.lean" text).state | return false
  match ← context.elaborator.setup state with
  | .ok _ =>
    return false
  | .error diagnostics =>
    return !diagnostics.isEmpty &&
        diagnostics.all fun diagnostic =>
          diagnostic.source == "setup" && diagnostic.severity == .error

/-- A config of one chunk: a command that makes a text and appends to it, and
the `setup` that registers it. -/
def greeting : String :=
  "def greet : EditorM Unit := do
  let text ← createText \"hello\"
  append text \", world\"

def setup : SetupM Unit := do
  command \"greet\" greet
"

/-- The checks of the real elaborator (`Editor/Config/Elaborate.lean`): what
the session core's fake of the port assumes, and what only the real one can
show. -/
def elaboratorChecks (context : Context) : List Check :=
  [{
      name :=
        "compiled code and config share state: each reads what the other wrote, and the import did not run a linked module's initialiser again",
      run := do
        let result ← onBase context "probe.lean" "def probe : IO Nat := ConfigFixture.bump"
        let some state := result.state | return false
        let probe ← IO.ofExcept (evalProbe state.env `probe)
        let fromConfig ← probe
        let fromCompiled ← ConfigFixture.cell.get
        -- The cell starts at 100 and compiled code bumped it before the
        -- import: an import that ran the initialiser again would have reset it.
        return context.bumped == 101 && fromConfig == 102 && fromCompiled == 102 },
    { name :=
        "a chunk that names a binding to the Rust library is rejected: config cannot reach one"
      run := do
        let result ← onBase context "reach.lean" "def reach : UInt32 := Editor.Ffi.add 2 3"
        return rejected "reach.lean" result },
    { name := "a chunk elaborates on the state after the one before it"
      run := do
        let first ← onBase context "first.lean" "def one : Nat := 1"
        let some state := first.state | return false
        let second ←
          context.elaborator.chunk state
              { name := "second.lean", text := "def two : Nat := one + one" }
        let alone ← onBase context "second.lean" "def two : Nat := one + one"
        return second.state.isSome && rejected "second.lean" alone },
    { name := "an open or a namespace in one chunk does not reach the next, and its declarations do"
      run := do
        let first ←
          onBase context "first.lean"
              "namespace Hidden\ndef secret : Nat := 1\nend Hidden\nopen Hidden\ndef viaOpen : Nat := secret\nnamespace Unclosed"
        let some state := first.state | return false
        let leaked ←
          context.elaborator.chunk state
              { name := "second.lean", text := "def leak : Nat := secret" }
        let qualified ←
          context.elaborator.chunk state
              { name := "second.lean", text := "def fine : Nat := Hidden.secret + viaOpen" }
        let named ←
          context.elaborator.chunk state { name := "second.lean", text := "def here : Nat := 1" }
        let some after := named.state | return false
        let found ←
          context.elaborator.chunk after { name := "third.lean", text := "def there : Nat := here" }
        return rejected "second.lean" leaked && qualified.state.isSome && found.state.isSome },
    { name :=
        "a chunk with a type error gives an error diagnostic that names the chunk and a position, and no state"
      run := do
        let result ← onBase context "bad.lean" "def fine : Nat := 1\ndef broken : Nat := \"text\"\n"
        return result.state.isNone &&
            result.diagnostics.any fun diagnostic =>
              diagnostic.source == "bad.lean" && diagnostic.severity == .error &&
                diagnostic.line == 2 &&
                diagnostic.column == 20 &&
                !diagnostic.message.isEmpty },
    { name := "a chunk with only a warning elaborates, and the warning is a diagnostic"
      run := do
        let result ← onBase context "warn.lean" "theorem unproved : 1 = 1 := sorry"
        return result.state.isSome &&
            result.diagnostics.any fun diagnostic =>
              diagnostic.source == "warn.lean" && diagnostic.severity == .warning },
    { name := "a config with no setup gives diagnostics in place of a setup program"
      run := setupRefused context "def greet : EditorM Unit := pure ()" },
    { name := "a config whose setup has another type gives diagnostics in place of a setup program"
      run := setupRefused context "def setup : IO Unit := pure ()" },
    { name := "a config whose setup contains sorry gives diagnostics in place of a setup program"
      run := setupRefused context "def setup : SetupM Unit := sorry" },
    { name :=
        "a good config's setup program registers a command that runs against the Rust library, and the text it made reads back"
      run := do
        let some state := (← onBase context "config.lean" greeting).state | return false
        let .ok program ← context.elaborator.setup state | return false
        let .ok registrations := Config.Registrations.ofSetup program | return false
        let some registration := registrations.commands[0]? | return false
        let .plain run := registration.action | return false
        let (result, texts) ← run.runReal #[]
        let some text := texts[0]? | return false
        return registrations.commands.size == 1 && registration.name == "greet" && result.isOk &&
            texts.size == 1 &&
            (← text.read) == "hello, world" },
    { name := "a chunk that declares an initialised constant is rejected with a diagnostic"
      run := do
        let result ←
          onBase context "init.lean"
              "initialize table : IO.Ref Nat ← IO.mkRef 0\ndef setup : SetupM Unit := pure ()"
        return rejected "init.lean" result },
    { name := "a chunk that declares an initialiser with no constant is rejected with a diagnostic"
      run := do
        let result ←
          onBase context "init.lean"
              "initialize discard (IO.mkRef 0)\ndef setup : SetupM Unit := pure ()"
        return rejected "init.lean" result }]

/-- Writes each of `files`, a name and a text, into `directory`. -/
def writeFiles (directory : System.FilePath) (files : List (String × String)) : IO Unit :=
  for (name, text) in files do
    IO.FS.writeFile (directory / name) text

/-- The names and texts of the chunks the directory source reads from
`directory`. -/
def chunksOf (directory : System.FilePath) : IO (Array (String × String)) := do
  let chunks ← (Config.Directory.source directory).chunks
  return chunks.map fun chunk => (chunk.name, chunk.text)

/-- The checks of the directory source (`Editor/Config/Directory.lean`), each
in a fresh temporary directory of its own, which is removed with the check. -/
def directoryChecks (_ : Unit) : List Check :=
  [{ name := "the chunks of a directory are its .lean files, in the byte order of their names",
     run :=
       IO.FS.withTempDir fun directory => do
         writeFiles directory
             [("20-b.lean", "second"), ("a.lean", "fourth"), ("10-a.lean", "first"),
               ("B.lean", "third")]
         return (← chunksOf directory) ==
             #[("10-a.lean", "first"), ("20-b.lean", "second"), ("B.lean", "third"),
               ("a.lean", "fourth")] },
    { name := "other files, and directories whatever their names, are not chunks"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory
              [("chunk.lean", "kept"), ("notes.txt", "x"), ("old.lean.bak", "x"), ("lean", "x")]
          IO.FS.createDirAll (directory / "nested.lean")
          writeFiles (directory / "nested.lean") [("inner.lean", "x")]
          IO.FS.createDirAll (directory / "sub")
          writeFiles (directory / "sub") [("deeper.lean", "x")]
          return (← chunksOf directory) == #[("chunk.lean", "kept")] },
    { name := "a directory that does not exist cannot be read: the source throws"
      run :=
        IO.FS.withTempDir fun directory => do
          try
            discard <| chunksOf (directory / "absent")
            return false
          catch _ =>
            return true },
    { name := "an empty directory is a config with no chunks"
      run := IO.FS.withTempDir fun directory => return (← chunksOf directory).isEmpty }]

/-- How long a check waits, in milliseconds, for something that should happen
at once. Only broken code takes this long, and the check then fails instead
of hanging. -/
def patience : Nat :=
  5000

/-- A host running for one check: the headless loop on the real queue and the
real text binding, over a config directory the check owns. -/
structure Session where
  /-- The host. -/
  host : Headless.Host
  /-- The config directory: a temporary directory of this check's. -/
  directory : System.FilePath
  /-- Every line the host has emitted, oldest first. -/
  output : IO.Ref (Array String)

namespace Session

/-- Sends `requests` to the editor thread in order, and waits until it has
handled them and no reload is running. Throws if that takes longer than
`patience`. -/
def ask (session : Session) (requests : List Headless.Request) : IO Unit := do
  for request in requests do
    session.host.send request
  unless ← session.host.settle patience do
    throw (IO.userError "the editor thread did not settle")

/-- Replaces the text of the chunk called `name`, or adds it. -/
def write (session : Session) (name text : String) : IO Unit :=
  IO.FS.writeFile (session.directory / name) text

/-- A line as a check compares it. A diagnostic's position and message are
Lean's, so a diagnostic line is cut down to its source and its severity;
every other line is kept whole. -/
def comparable (line : String) : String :=
  match line.splitOn ": " with
  | "diagnostic" :: place :: severity :: _ =>
    s!"diagnostic: {(place.splitOn ":").headD ""}: {severity}"
  | _ => line

/-- Every line the host has emitted, as a check compares them. -/
def lines (session : Session) : IO (Array String) :=
  return (← session.output.get).map comparable

end Session

/-- Runs `check` against a host started over `elaborator` and `source`, with
its output in a buffer `check` is handed, and stops the host. `false` if the
check did not hold or the host did not stop. -/
def hosted {σ : Type} (context : Context) (elaborator : Config.Elaborator σ)
    (source : Config.Source) (check : Headless.Host → IO.Ref (Array String) → IO Bool) : IO Bool :=
  do
  let output ← IO.mkRef #[]
  -- Hosts follow one another on one queue: each gets source ids of its own,
  -- so none takes a late event of an earlier one for its own.
  let requests ← context.ids.modifyGet fun next => (next, next + 2)
  let host ←
    Headless.start
        { elaborator, source, emit := fun line => output.modify (·.push line), requests,
          wakeups := requests + 1 }
  try
    let held ← check host output
    let stopped ← host.stop patience
    return held && stopped
  catch error =>
    discard <| host.halt patience
    throw error

/-- Runs `check` against a host started on a fresh temporary directory
holding `files`, and stops the host. The host's elaborator is `around` the
real one and its source `through` the directory's: a check that controls
elaboration or counts reads passes a decorator. The directory is removed. -/
def withHostOver (context : Context) (files : List (String × String))
    (around : Config.Elaborator Config.Elaborate.State → Config.Elaborator Config.Elaborate.State)
    (through : Config.Source → Config.Source) (check : Session → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory files
    hosted context (around context.elaborator) (through (Config.Directory.source directory))
        fun host output => check { host, directory, output }

/-- Runs `check` against a host started on a fresh temporary directory
holding `files`, with the real elaborator, and stops the host. `false` if the
check did not hold or the host did not stop. The directory is removed. -/
def withHost (context : Context) (files : List (String × String)) (check : Session → IO Bool) :
    IO Bool :=
  withHostOver context files id id check

/-- A chunk that defines the command `greet`, which makes a text holding
`text`. -/
def greetChunk (text : String) : String :=
  "def greet : EditorM Unit := do\n  discard <| createText \"" ++ text ++ "\"\n"

/-- A chunk whose `setup` registers `greet`. -/
def setupChunk : String :=
  "def setup : SetupM Unit := do\n  command \"greet\" greet\n"

/-- A config of two chunks: `greet`, which makes a text holding "v1", and the
`setup` that registers it. -/
def greetConfig : List (String × String) :=
  [("10-greet.lean", greetChunk "v1"), ("20-setup.lean", setupChunk)]

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
               "text 0: \"v1\"", "reload 2: installed, 2 chunks, 1 commands", "run greet: ok",
               "commands: greet", "text 0: \"v1\"", "text 1: \"v2\""] },
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
                "text 0: \"v1\""] },
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
                "commands: greet"] },
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
                "text 0: \"v1\""] },
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
                "commands: bump", "store counter v1: 2",
                "reload 2: installed, 1 chunks, 1 commands", "commands: bump",
                "store counter v1: 2", "run bump: ok", "commands: bump", "store counter v1: 12"] },
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
                "reload 2: installed, 1 chunks, 1 commands", "commands: bump",
                "store counter v2: {n: 2, label: \"migrated\"}", "run bump: ok", "commands: bump",
                "store counter v2: {n: 3, label: \"migrated\"}"] },
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
                "text 0: \"v1\""] }]

/-- Polls `condition` until it holds; `false` if it still does not after
`patience` milliseconds. -/
def eventually (condition : IO Bool) : IO Bool :=
  Headless.within patience condition

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
                      "commands: greet", "text 0: \"v2\""]
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

/-- The checks of the headless mode's script and its driver
(`Headless.script`, `Headless.run`). The command line itself is covered by
one run of the real executable on the fixture under `tests/headless`, in the
`ffi-test` task. -/
def scriptChecks (context : Context) : List Check :=
  [{ name := "a script is one directive a line, and blank lines and comments are skipped",
     run :=
       pure
         ((Headless.script
               "# a comment\nreload\n\n  settle  \nrun greet\nrun  two words\nshow\n").toOption ==
           some
             #[.request .reload, .settle, .request (.run "greet"), .request (.run "two words"),
               .request .show]) },
    { name := "a line that is no directive, and a run with no name, are refused"
      run :=
        pure
          (!(Headless.script "reload\nrelaod\n").isOk && !(Headless.script "run\n").isOk &&
            !(Headless.script "settle now\n").isOk) },
    { name :=
        "a script that runs to its end gives status 0, and what it asked for was printed before the loop stopped"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory greetConfig
          let output ← IO.mkRef #[]
          let requests ← context.ids.modifyGet fun next => (next, next + 2)
          let status ←
            Headless.run
                { elaborator := context.elaborator, source := Config.Directory.source directory,
                  emit := fun line => output.modify (·.push line), requests,
                  wakeups := requests + 1 }
                #[.request .reload, .settle, .request (.run "greet"), .request .show] patience
          return status == 0 &&
              (← output.get) ==
                #["reload 1: installed, 2 chunks, 1 commands", "run greet: ok", "commands: greet",
                  "text 0: \"v1\""] },
    { name :=
        "a script whose settle cannot be satisfied gives status 1: a stuck script fails, it does not hang"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeFiles directory (greetConfig ++ [("slow.lean", slowChunk)])
            let output ← IO.mkRef #[]
            let requests ← context.ids.modifyGet fun next => (next, next + 2)
            try
              -- The reload is held open, so the settle runs out, after a
              -- fifth of a second. `run` then ends its loop at once, so the
              -- next host starts on a queue nobody else is pulling.
              let status ←
                Headless.run
                    { elaborator := gate.around context.elaborator,
                      source := Config.Directory.source directory,
                      emit := fun line => output.modify (·.push line), requests,
                      wakeups := requests + 1 }
                    #[.request .reload, .settle, .request .show] 200
              return status == 1 && (← gate.holding.get) && (← output.get).isEmpty
            finally
              -- The job that was left behind ends; its wake-up is under this
              -- host's source id, which no later host is given.
              gate.open }]

/-- Every check, in the order they run. -/
def checks (context : Context) : List Check :=
  elaboratorChecks context ++ directoryChecks () ++ hostChecks context ++ threadChecks context ++
    scriptChecks context

/-- Runs `checks` and returns the names of those that failed. A check that
throws has failed, and its error is reported with its name. -/
def failures (checks : List Check) : IO (List String) :=
  checks.filterMapM fun check => do
    try
      return if ← check.run then none else some check.name
    catch error =>
      return some s!"{check.name} ({error})"

/-- Imports the base once and runs every check: names on stderr the ones that
failed, and returns the exit status, 0 when all hold and 1 otherwise.

`sysroot` is the Lean toolchain's directory and `oleanDir` the directory
holding the package's `.olean` files. -/
def run (sysroot oleanDir : String) : IO UInt8 := do
  let real :=
    Config.Elaborate.elaborator { sysroot, oleanDir, imports := #[`Editor, `ConfigFixture] }
  -- Compiled code writes to the fixture's cell before the base is imported.
  let bumped ← ConfigFixture.bump
  let base ← real.base
  let context : Context :=
    { elaborator := { real with base := pure base }, base, bumped, ids := ← IO.mkRef 100 }
  let checks := checks context
  let failed ← failures checks
  for name in failed do
    IO.eprintln s!"FAILED: {name}"
  unless failed.isEmpty do
    return 1
  IO.println s!"config-test: {checks.length} checks passed"
  return 0

/-! ## The benchmark

Three subcommands measure the config session (`mise run config-bench`, which
runs each in a fresh process under `/usr/bin/time -l`). They are a measuring
tool: they assert nothing but that every reload installed, the gate builds
them and never runs them, and no number they print is an expected value.

Each loads config through the headless host, as the editor does, from a
source held in memory, so they touch no files. A time is from the request
for a reload to its report, on Lean's monotonic clock. -/

namespace Bench

/-- How long a measurement waits, in milliseconds, for one reload. -/
def patience : Nat :=
  120000

/-- A host to measure: its source is `chunks`, and it notes when each
reload's report is printed. -/
structure Rig where
  /-- The host. -/
  host : Headless.Host
  /-- The config the host's source holds. -/
  chunks : IO.Ref (Array Config.SourceChunk)
  /-- The last reload's report line, and the monotonic time, in nanoseconds,
  at which it was printed. -/
  reported : IO.Ref (Option (String × Nat))
  /-- Every other line the host printed since the last request: the
  diagnostics of a reload that went wrong. -/
  others : IO.Ref (Array String)

namespace Rig

/-- Starts a host over `elaborator` and a source in memory. -/
def start (elaborator : Config.Elaborator Config.Elaborate.State) : IO Rig := do
  let chunks ← IO.mkRef #[]
  let reported ← IO.mkRef none
  let others ← IO.mkRef #[]
  let emit (line : String) : IO Unit := do
    if line.startsWith "reload " then
      reported.set (some (line, ← IO.monoNanosNow))
    else
      others.modify (·.push line)
  let host ←
    Headless.start
        { elaborator, source := { chunks := chunks.get }, emit, requests := 1, wakeups := 2 }
  return { host, chunks, reported, others }

/-- Makes `config` the source's chunks, asks for a reload, and returns the
nanoseconds from the request to the report. Throws unless the reload was
installed. -/
def reload (rig : Rig) (config : Array Config.SourceChunk) : IO Nat := do
  rig.chunks.set config
  rig.reported.set none
  rig.others.set #[]
  let asked ← IO.monoNanosNow
  rig.host.send .reload
  unless ← rig.host.settle patience do
    throw (IO.userError "a reload did not finish")
  let some (line, printed) ← rig.reported.get | throw (IO.userError "a reload was not reported")
  unless (line.splitOn "installed").length > 1 do
    throw (IO.userError s!"{line}: {"; ".intercalate (← rig.others.get).toList}")
  return printed - asked

end Rig

/-- A config of one chunk of one line, which differs with `round`. -/
def oneLine (round : Nat) : Array Config.SourceChunk :=
  #[{ name := "one.lean",
      text := "def setup : SetupM Unit := command \"round" ++ toString round ++ "\" (pure ())\n" }]

/-- A config of one chunk of twenty lines, which differs with `round`. -/
def twentyLines (round : Nat) : Array Config.SourceChunk :=
  #[{ name := "twenty.lean",
      text :=
        "def greet : EditorM Unit := do
  let text ← createText \"hello\"
  append text \", world\"

def shout : EditorM Unit := do
  let text ← createText \"HELLO\"
  append text \"!\"

def twice (command : EditorM Unit) : EditorM Unit := do
  command
  command

def note (round : Nat) : EditorM Unit := do
  discard <| createText (toString round)

def setup : SetupM Unit := do
  command \"greet\" greet
  command \"shout\" shout
  command \"twice\" (twice greet)
  command \"note\" (note " ++
          toString round ++
          ")\n" }]

/-- A config of one chunk of fifty definitions, a theorem proved by `simp`
and a `setup`, which differs with `round`. -/
def fiftyDefinitions (round : Nat) : Array Config.SourceChunk :=
  let definitions :=
    (List.range 50).map fun index => s!"def f{index} (n : Nat) : Nat := n * {index} + {index}\n"
  #[{ name := "fifty.lean",
      text :=
        String.join definitions ++ "theorem f1_spec (n : Nat) : f1 n = n + 1 := by simp [f1]\n" ++
          s!"def round : Nat := {round}\n" ++
          "def setup : SetupM Unit := command \"round\" (pure ())\n" }]

/-- Nanoseconds as milliseconds with one decimal. -/
def milliseconds (nanoseconds : Nat) : String :=
  let tenths := (nanoseconds + 50000) / 100000
  s!"{tenths / 10}.{tenths % 10}"

/-- The median and the maximum of `times`, as milliseconds. -/
def medianAndMaximum (times : Array Nat) : String :=
  let sorted := times.qsort (· < ·)
  let median := (sorted.getD ((sorted.size - 1) / 2) 0 + sorted.getD (sorted.size / 2) 0) / 2
  s!"median {milliseconds median} ms, maximum {milliseconds (sorted.back?.getD 0)} ms"

/-- `bench-start`: imports the base with `modules`, then loads the twenty-line
config through a host, and prints how long each took. -/
def start (sysroot oleanDir : String) (modules : List String) : IO UInt8 := do
  let real :=
    Config.Elaborate.elaborator
      { sysroot, oleanDir, imports := (modules.map String.toName).toArray }
  let before ← IO.monoNanosNow
  let base ← real.base
  let imported := (← IO.monoNanosNow) - before
  let rig ← Rig.start { real with base := pure base }
  let first ← rig.reload (twentyLines 0)
  IO.println
      s!"bench-start {modules}: import {milliseconds imported} ms, first load {milliseconds first} ms"
  return 0

/-- `bench-reload`: twenty reloads of each of the three configs, each reload
with the text changed, and prints the median and the maximum of each. -/
def reload (sysroot oleanDir : String) : IO UInt8 := do
  let rig ← Rig.start (Config.Elaborate.elaborator { sysroot, oleanDir })
  -- The first load imports the base; it is not one of the twenty.
  discard <| rig.reload (oneLine 0)
  let configs :=
    [("one-line chunk", oneLine), ("20-line config", twentyLines),
      ("50 definitions and a simp proof", fiftyDefinitions)]
  for (name, config) in configs do
    let mut times := #[]
    for round in [1:21] do
      times := times.push (← rig.reload (config round))
    IO.println s!"bench-reload: {name}: {medianAndMaximum times}"
  return 0

/-- `bench-soak`: `count` reloads of the fifty-definition config, each with
the text changed, and prints the mean time of one. -/
def soak (sysroot oleanDir : String) (count : Nat) : IO UInt8 := do
  let rig ← Rig.start (Config.Elaborate.elaborator { sysroot, oleanDir })
  discard <| rig.reload (fiftyDefinitions 0)
  let mut total := 0
  for round in [1:count + 1] do
    total := total + (← rig.reload (fiftyDefinitions round))
  IO.println s!"bench-soak: {count} reloads, mean {milliseconds (total / count)} ms per reload"
  return 0

end Bench

/-- Reports a command line `main` does not understand; the exit status is 2. -/
def usage : IO UInt32 := do
  IO.eprintln
      "usage: config-test <sysroot> <olean dir> | config-test bench-start <sysroot> <olean dir> <module>... | config-test bench-reload <sysroot> <olean dir> | config-test bench-soak <sysroot> <olean dir> <count>"
  return 2

end ConfigTest

/-- `config-test <sysroot> <olean dir>` runs the checks: exits 0 when all
hold, and 1 after naming the ones that do not.

`bench-start`, `bench-reload` and `bench-soak` are the benchmark
(`ConfigTest.Bench`; `mise run config-bench`), which the gate never runs.

Any other command line is reported, with the exit status 2.

It exits explicitly: a failed check may have left a task parked in the
library, and a benchmark leaves its host's loop running; returning from
`main` would wait for either for ever. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [sysroot, oleanDir] =>
    IO.Process.exit (← ConfigTest.run sysroot oleanDir)
  | "bench-start" :: sysroot :: oleanDir :: module :: modules =>
    IO.Process.exit (← ConfigTest.Bench.start sysroot oleanDir (module :: modules))
  | ["bench-reload", sysroot, oleanDir] =>
    IO.Process.exit (← ConfigTest.Bench.reload sysroot oleanDir)
  | ["bench-soak", sysroot, oleanDir, count] =>
    match count.toNat? with
    | some count =>
      IO.Process.exit (← ConfigTest.Bench.soak sysroot oleanDir count)
    | none =>
      ConfigTest.usage
  | _ =>
    ConfigTest.usage
