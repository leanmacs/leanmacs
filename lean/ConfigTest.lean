import ConfigFixture
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Headless
import Editor.Job.Fake

/-!
# Checks of the config session against the real elaborator

The `config-test` executable is linked exactly like `editor`, with the glue
object, the Rust archive and Lean's elaborator. `mise run ffi-test` runs it
as `config-test <sysroot> <olean dir>`: the Lean toolchain's directory and
the directory holding the package's `.olean` files. It reads nothing from the
environment or the working directory. It runs every check in `checks`, names
the ones that failed, and exits non-zero if any did.

The model tests (`ModelTest.lean`) pin the decisions of the config session on
fakes. The checks here pin what only real collaborators can show:

- `elaboratorChecks`: the real elaborator behaves as the fake of its port
  assumes, and compiled code and config share state;
- `directoryChecks`: the directory source, each check in a temporary
  directory of its own;
- `hostChecks`: the phase's acceptance tests through the headless host, with
  the real elaborator, the real queue and the real text binding, asserted on
  the lines the host prints;
- `threadChecks`: the editor answers events while a chunk elaborates, reloads
  are serialised, and a replaced config is not retained;
- `jobChecks`: jobs from config through the host: a handler receives a job's
  result on the editor thread, a reload that installs cancels the old
  config's jobs and a rejected one does not, and how each ending of a job is
  reported;
- `scriptChecks`: the headless mode's script and its driver.

A check controls time through a port, never by sleeping and hoping: a
decorator of the elaborator port (`Gate`) holds one chunk's elaboration open
until the check lets it go, and a host's jobs wait on a fake clock
(`Editor/Job/Fake.lean`) that only the check moves. Every wait is a poll with
a bound, so broken code fails a check within seconds instead of hanging the
executable. Each line a host emits is recorded with the thread that emitted
it, which is how a check sees that a handler ran on the editor thread.

All the checks share one import of the base, made once in `run`: a second
import in one process about doubles its memory. Hosts follow one another on
the process's one editor queue and never overlap: every check stops its host
before it returns.

No check makes the process abort. In particular none evaluates a declaration
that reads an `initialize`d constant of config's, and none runs config that
recurses without bound.

The executable also holds the benchmark (`Bench`, below), which the gate
builds and never runs.
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
        let (result, texts) ← run.runReal {}
        let some (some text) := texts.documents[0]? | return false
        return registrations.commands.size == 1 && registration.name == "greet" && result.isOk &&
            texts.documents.size == 1 &&
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

/-- Whether `message` is one line and names `path`. A message that will be
printed as one diagnostic line must hold the path on its first line. -/
def namesOnOneLine (message : String) (path : System.FilePath) : Bool :=
  (message.splitOn "\n").length == 1 && (message.splitOn path.toString).length > 1

/-- Bytes that are not UTF-8. -/
def notUtf8 : ByteArray :=
  ⟨#[0xff, 0xfe, 0xfd]⟩

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
    { name :=
        "a directory that does not exist cannot be read: the source throws one line that names the directory"
      run :=
        IO.FS.withTempDir fun directory => do
          let absent := directory / "absent"
          try
            discard <| chunksOf absent
            return false
          catch error =>
            return namesOnOneLine (toString error) absent },
    { name :=
        "a chunk that is not UTF-8 cannot be read: the source throws one line that names the file"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory [("good.lean", "kept")]
          IO.FS.writeBinFile (directory / "bad.lean") notUtf8
          try
            discard <| chunksOf directory
            return false
          catch error =>
            return namesOnOneLine (toString error) (directory / "bad.lean") },
    { name := "an empty directory is a config with no chunks"
      run := IO.FS.withTempDir fun directory => return (← chunksOf directory).isEmpty }]

/-- How long a check waits, in milliseconds, for something that should happen
at once. Only broken code takes this long, and the check then fails instead
of hanging. -/
def patience : Nat :=
  5000

/-- What a check hands a host of its own: the collaborators, and what the
check keeps of them. The host's output goes to a buffer, with the thread
that emitted each line; its jobs wait on a fake clock the check moves; and it
posts under source ids no other host of this process has. -/
structure Stage (σ : Type) where
  /-- What the host is started with. -/
  collaborators : Headless.Collaborators σ
  /-- Every line the host has emitted, oldest first. -/
  output : IO.Ref (Array String)
  /-- The thread that emitted each line of `output`. -/
  threads : IO.Ref (Array UInt64)
  /-- The clock the host's jobs wait on. -/
  clock : Job.FakeClock

/-- A stage for a host over `elaborator` and `source`. Hosts follow one
another on one queue: each gets source ids of its own, so none takes a late
event of an earlier one for its own. -/
def Stage.new {σ : Type} (context : Context) (elaborator : Config.Elaborator σ)
    (source : Config.Source) : IO (Stage σ) := do
  let output ← IO.mkRef #[]
  let threads ← IO.mkRef #[]
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let requests ← context.ids.modifyGet fun next => (next, next + 3)
  return {
      collaborators :=
        { elaborator, source,
          emit := fun line => do
            threads.modify (·.push (← IO.getTID))
            output.modify (·.push line),
          services := { completions, timers := clock.timers }, requests, wakeups := requests + 1,
          jobs := requests + 2 },
      output, threads, clock }

/-- A host running for one check: the headless loop on the real queue and the
real text binding, over a config directory the check owns. -/
structure Session where
  /-- The host. -/
  host : Headless.Host
  /-- The config directory: a temporary directory of this check's. -/
  directory : System.FilePath
  /-- Every line the host has emitted, oldest first. -/
  output : IO.Ref (Array String)
  /-- The thread that emitted each line of `output`. -/
  threads : IO.Ref (Array UInt64)
  /-- The clock the host's jobs wait on, which the check moves. -/
  clock : Job.FakeClock

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

/-- Runs `check` against a host started on a stage of its own over
`elaborator` and `source`, and stops the host. `false` if the check did not
hold or the host did not stop. -/
def staged {σ : Type} (context : Context) (elaborator : Config.Elaborator σ)
    (source : Config.Source) (check : Headless.Host → Stage σ → IO Bool) : IO Bool := do
  let stage ← Stage.new context elaborator source
  let host ← Headless.start stage.collaborators
  try
    let held ← check host stage
    let stopped ← host.stop patience
    return held && stopped
  catch error =>
    discard <| host.halt patience
    throw error

/-- Runs `check` against a host started over `elaborator` and `source`, with
its output in a buffer `check` is handed, and stops the host. `false` if the
check did not hold or the host did not stop. -/
def hosted {σ : Type} (context : Context) (elaborator : Config.Elaborator σ)
    (source : Config.Source) (check : Headless.Host → IO.Ref (Array String) → IO Bool) : IO Bool :=
  staged context elaborator source fun host stage => check host stage.output

/-- Runs `check` against a host started on a fresh temporary directory
holding `files`, and stops the host. The host's elaborator is `around` the
real one and its source `through` the directory's: a check that controls
elaboration or counts reads passes a decorator. The directory is removed. -/
def withHostOver (context : Context) (files : List (String × String))
    (around : Config.Elaborator Config.Elaborate.State → Config.Elaborator Config.Elaborate.State)
    (through : Config.Source → Config.Source) (check : Session → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory files
    staged context (around context.elaborator) (through (Config.Directory.source directory))
        fun host stage =>
        check
          { host, directory, output := stage.output, threads := stage.threads,
            clock := stage.clock }

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
                "run greet: ok", "commands: greet", "text 0: \"v1\""] },
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
                "diagnostic: store counter: warning", "commands: bump", "store counter v2: 0"] },
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
                "text 0: \"v1\""] },
    { name :=
        "a store command the library refuses is reported as refused: the store keeps its value, and the text the command made before the refusal stays"
      run :=
        withHost context [("config.lean", refusedChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump", .run "broken", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 2 commands", "run bump: ok",
                "run broken: refused: no such text", "commands: bump broken",
                "text 0: \"made before the refusal\"", "store counter v1: 1"] },
    { name :=
        "show lists no text a command released, and the texts made before and after it keep the index they were made with"
      run :=
        withHost context [("config.lean", releasingChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "drop", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 chunks, 3 commands", "run drop: ok",
                "commands: drop inside stale", "text 0: \"before\"", "text 2: \"after\""] },
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
                  #["job 1 count: ok", "commands: greet", "text 0: \"v1\"", "text 1: \"v1\"",
                    "text 2: \"counted 42\""] &&
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
            working != Headless.Failure.describe 30000 (.unanswered (some 12))) }]

/-- The checks of the headless mode's script and its driver
(`Headless.script`, `Headless.run`). The command line itself is covered by
one run of the real executable on the fixture under `tests/headless`, in the
`ffi-test` task. -/
def scriptChecks (context : Context) : List Check :=
  [{
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
                  "text 0: \"v1\""] },
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
          Headless.start
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

/-- Every check, in the order they run. -/
def checks (context : Context) : List Check :=
  elaboratorChecks context ++ directoryChecks () ++ hostChecks context ++ threadChecks context ++
    jobChecks context ++
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
  -- The configs measured here start no job: the clock is never asked.
  let completions ← Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let host ←
    Headless.start
        { elaborator, source := { chunks := chunks.get }, emit,
          services := { completions, timers := clock.timers }, requests := 1, wakeups := 2,
          jobs := 3 }
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

/-! ### The job benchmark

`bench-jobs` measures the latency of the editor loop while jobs run
(`mise run job-bench`). Like the others it is a measuring tool: the gate
builds it and never runs it, and no number it prints is an expected value.

Each row runs a headless host on the real elaborator, the real queue and the
library's timer service, with the pool warmed and the pump running, as the
editor's headless mode does. A sample is one `run noop`: the driver reads
the monotonic clock, posts the request, and the output port reads the clock
again on the editor thread when `run noop: ok` is printed; the driver waits
for that before the next sample.

A row has a host of its own, and its jobs are ended by ending that host,
whose loop cancels them. A reload cannot end them: Lean's frontend
elaborates on pool tasks, so while a job computes on every pool thread a
reload does not get to elaborate, and never installs. Seen when this
benchmark still ended a row with a reload: with one job fewer than the pool
has threads the reload went through, and with one a thread it had not
finished after 45 seconds (`docs/design/concurrency.md`, "Reload"). -/

/-- The config the job benchmark loads: a command that does nothing, a job
that sleeps a millisecond in a loop, and a job that computes for ever, with a
reading of the clock every 100,000 iterations. A cancelled job ends at its
next request, so the reading is what lets the computing job be ended. -/
def jobsConfig : Array Config.SourceChunk :=
  #[{ name := "jobs.lean",
      text :=
        "partial def ticker (token : Unit) : JobM Unit := do
  sleep 1
  ticker token

def churn (seed : Nat) : Nat := Id.run do
  let mut value := seed
  for index in [0:100000] do
    value := (value * 1103515245 + index) % 2147483648
  return value

partial def spin (seed : Nat) : JobM Unit := do
  let value := churn seed
  let instant ← now
  spin (value + instant % 2)

def setup : SetupM Unit := do
  command \"noop\" (pure ())
  job \"ticker\" ticker fun _ => pure ()
  job \"spin\" (fun _ => spin 1) fun _ => pure ()
" }]

/-- What the samples of one row came to, in nanoseconds. -/
structure Row where
  /-- What ran while the row was measured. -/
  name : String
  /-- The median latency. -/
  median : Nat
  /-- The 99th percentile. -/
  high : Nat
  /-- The largest sample. -/
  maximum : Nat
  /-- What to say after the numbers, if anything. -/
  note : String := ""

/-- The row of `times`, which need not be sorted. -/
def Row.of (name : String) (times : Array Nat) (note : String := "") : Row :=
  let sorted := times.qsort (· < ·)
  { name, median := (sorted.getD ((sorted.size - 1) / 2) 0 + sorted.getD (sorted.size / 2) 0) / 2,
    high := sorted.getD (min (sorted.size * 99 / 100) (sorted.size - 1)) 0,
    maximum := sorted.back?.getD 0, note }

/-- Nanoseconds as microseconds with one decimal. -/
def microseconds (nanoseconds : Nat) : String :=
  let tenths := (nanoseconds + 50) / 100
  s!"{tenths / 10}.{tenths % 10}"

/-- A row as a line of the report: its name, padded, then the median, the
99th percentile and the maximum. -/
def Row.line (row : Row) : String :=
  let label := row.name ++ ":"
  s!"  {label.pushn ' ' (36 - label.length)}{microseconds row.median} / {microseconds row.high} / {microseconds row.maximum}{row.note}"

/-- What the 99th percentile of a loaded row must stay under, in nanoseconds:
100 µs. -/
def highBound : Nat :=
  100000

/-- Whether a loaded row is within the bound the job system was accepted
against, as an observation about one run: its median is at most twice the
larger of the two idle medians, and its 99th percentile is under 100 µs. The
maximum is not judged: one scheduling delay sets it. -/
def Row.withinBound (row before after : Row) : Bool :=
  row.median ≤ 2 * max before.median after.median && row.high < highBound

/-- A compiled job that reads the clock `count` times and finishes. -/
def readings (count : Nat) : Work := fun _ => do
  for _ in [0:count] do
    discard now
  return pure ()

/-- `bench-jobs`: the latency of the editor loop, over `samples` samples a
row, while nothing runs, while 64 jobs each sleep a millisecond in a loop,
while one interpreted job a pool thread computes, while two a pool thread
do, and while nothing runs again; then the cost of a `now` request in a
compiled job. Each row has a host of its own, and its jobs are ended by
ending that host.

Of two computing jobs a pool thread, half run and half wait in the pool's
queue: a job that never waits keeps its thread. -/
def jobs (sysroot oleanDir : String) (samples : Nat) : IO UInt8 := do
  let pool := (← Job.Pool.warm Job.Pool.size 200).size
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  let real := Job.realTimers completions
  -- The clock, counting its waits and its readings: how the driver knows
  -- that jobs have got going, and how many completions went through the pump.
  let waits ← IO.mkRef 0
  let reads ← IO.mkRef 0
  let counted : Job.Timers :=
    { real with
      now := do
        reads.modify (· + 1)
        real.now,
      start := fun id deadline => do
        waits.modify (· + 1)
        real.start id deadline }
  let slot ← IO.mkRef (none : Option (IO.Promise Nat))
  let reloads ← IO.mkRef #[]
  let emit (line : String) : IO Unit := do
    if line == "run noop: ok" then
      let ran ← IO.monoNanosNow
      if let some sample← slot.get then
        sample.resolve ran
    else
      if line.startsWith "reload " || line.startsWith "diagnostic: " then
        reloads.modify (·.push line)
  -- The base is imported once, here, and every host is handed it.
  let adapter := Config.Elaborate.elaborator { sysroot, oleanDir }
  let base ← adapter.base
  let elaborator := { adapter with base := pure base }
  let ids ← IO.mkRef (1 : UInt64)
  -- One row: a host of its own that loads the config and starts `count` jobs
  -- called `job`; `going` waits until they are under way; then the samples.
  -- Returns the samples, how many waits were started while they were taken,
  -- and how long taking them took. The host is ended whatever happens, which
  -- cancels its jobs, and the row is over when every pool thread is free.
  let row (job : String) (count : Nat) (going : IO Unit) : IO (Array Nat × Nat × Nat) := do
    -- Hosts follow one another on one queue: each has source ids of its own.
    let requests ← ids.modifyGet fun next => (next, next + 3)
    reloads.set #[]
    let host ←
      Headless.start
          { elaborator, source := { chunks := pure jobsConfig }, emit,
            services := { completions, timers := counted }, requests, wakeups := requests + 1,
            jobs := requests + 2 }
    try
      host.send .reload
      unless ← host.settle patience do
        throw (IO.userError "the config did not load")
      let lines ← reloads.get
      unless lines.any fun line => (line.splitOn "installed").length > 1 do
        throw (IO.userError ("the config was not installed: " ++ "; ".intercalate lines.toList))
      for _ in [0:count] do
        host.send (.spawn job)
      unless ← host.settle patience do
        throw (IO.userError "the editor thread did not answer")
      going
      let waitsBefore ← waits.get
      let began ← IO.monoNanosNow
      let mut times := #[]
      for _ in [0:samples] do
        let sample ← IO.Promise.new
        slot.set (some sample)
        let asked ← IO.monoNanosNow
        host.send (.run "noop")
        let some ran ← IO.wait sample.result? | throw (IO.userError "a sample was lost")
        times := times.push (ran - asked)
      return (times, (← waits.get) - waitsBefore, (← IO.monoNanosNow) - began)
    finally
      discard <| host.halt patience
      discard <| Job.Pool.warm pool 5000
  -- Waits until the clock has been read `count` more times: so many jobs
  -- have reached a request, so the pool is computing.
  let computing (count : Nat) : IO Unit := do
    let before ← reads.get
    unless ← Headless.within patience (return (← reads.get) >= before + count) do
      throw (IO.userError "the computing jobs did not get going")
  let idle := Row.of "idle" (← row "ticker" 0 (pure ())).1
  let (sleepingTimes, completed, elapsed) ← row "ticker" 64 (pure ())
  let sleeping :=
    Row.of "64 jobs each sleeping 1 ms" sleepingTimes
      s!"   ({completed * 1000000000 / max elapsed 1} completions a second through the pump)"
  let one := Row.of s!"{pool} interpreted jobs computing" (← row "spin" pool (computing pool)).1
  let two :=
    Row.of s!"{2 * pool} interpreted jobs computing" (← row "spin" (2 * pool) (computing pool)).1
  let again := Row.of "idle again" (← row "ticker" 0 (pure ())).1
  -- The cost of a request that needs no wait, in a compiled job on the
  -- library's clock.
  let count := 1000000
  let finished ← IO.Promise.new
  let started ← IO.monoNanosNow
  discard <|
      Job.spawn { completions, timers := real } (readings count) do
        finished.resolve (← IO.monoNanosNow)
  let some ended ← IO.wait finished.result? | throw (IO.userError "the reading job was lost")
  let rows := [idle, sleeping, one, two, again]
  let loaded := [sleeping, one, two]
  IO.println s!"pool: {pool} threads; {samples} samples a row"
  IO.println
      "latency of the editor loop, from posting `run noop` to the editor thread having run it, in µs: median / 99th percentile / maximum"
  for row in rows do
    IO.println row.line
  IO.println
      s!"a `now` request answered by the library: {(ended - started) / count} ns each (mean of {count} in one job)"
  IO.println
      ("within bound (median within twice the larger idle median, 99th percentile under 100 µs): " ++
        "; ".intercalate
          (loaded.map fun row =>
            s!"{row.name}: {if row.withinBound idle again then "yes" else "no"}"))
  let late := rows.filter (·.maximum > 1000000)
  unless late.isEmpty do
    IO.println ("maximum over 1 ms: " ++ ", ".intercalate (late.map (·.name)))
  (← IO.getStdout).flush
  return 0

end Bench

/-- Reports a command line `main` does not understand; the exit status is 2. -/
def usage : IO UInt32 := do
  IO.eprintln
      "usage: config-test <sysroot> <olean dir> | config-test bench-start <sysroot> <olean dir> <module>... | config-test bench-reload <sysroot> <olean dir> | config-test bench-soak <sysroot> <olean dir> <count> | config-test bench-jobs <sysroot> <olean dir> <samples>"
  return 2

end ConfigTest

/-- `config-test <sysroot> <olean dir>` runs the checks: exits 0 when all
hold, and 1 after naming the ones that do not.

`bench-start`, `bench-reload` and `bench-soak` are the benchmark
(`ConfigTest.Bench`; `mise run config-bench`), which the gate never runs.
`bench-jobs` is the job benchmark (`ConfigTest.Bench.jobs`;
`mise run job-bench`), which the gate never runs either.

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
  | ["bench-jobs", sysroot, oleanDir, samples] =>
    match samples.toNat? with
    | some samples =>
      -- A benchmark that fails leaves tasks running, so it says why and
      -- exits here: an error that left `main` would wait for them for ever.
      let status ←
        try
          ConfigTest.Bench.jobs sysroot oleanDir samples
        catch error =>
          IO.eprintln s!"config-test: bench-jobs: {error}"
          pure 1
      IO.Process.exit status
    | none =>
      ConfigTest.usage
  | _ =>
    ConfigTest.usage
