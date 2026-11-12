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

/-- Runs `check` against a host started on a fresh temporary directory
holding `files`, with the real elaborator, and stops the host. `false` if the
check did not hold or the host did not stop. The directory is removed. -/
def withHost (context : Context) (files : List (String × String)) (check : Session → IO Bool) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory files
    let output ← IO.mkRef #[]
    -- Hosts follow one another on one queue: each gets source ids of its
    -- own, so none takes a late event of an earlier one for its own.
    let requests ← context.ids.modifyGet fun next => (next, next + 2)
    let host ←
      Headless.start
          { elaborator := context.elaborator, source := Config.Directory.source directory,
            emit := fun line => output.modify (·.push line), requests, wakeups := requests + 1 }
    try
      let held ← check { host, directory, output }
      let stopped ← host.stop patience
      return held && stopped
    catch error =>
      discard <| host.halt patience
      throw error

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

/-- Every check, in the order they run. -/
def checks (context : Context) : List Check :=
  elaboratorChecks context ++ directoryChecks () ++ hostChecks context

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

end ConfigTest

/-- `config-test <sysroot> <olean dir>` runs the checks: exits 0 when all
hold, and 1 after naming the ones that do not. Any other command line is
reported, with the exit status 2.

It exits explicitly: a failed check may have left a task parked in the
library, and returning from `main` would wait for it for ever. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | [sysroot, oleanDir] =>
    IO.Process.exit (← ConfigTest.run sysroot oleanDir)
  | _ =>
    IO.eprintln "usage: config-test <sysroot> <olean dir>"
    return 2
