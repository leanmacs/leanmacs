import ConfigFixture
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Evil.Compiled
import Editor.Ex.Compiled
import Editor.Files.Compiled
import Editor.Headless
import Editor.InputScheme.Test
import Editor.Job.Fake
import Editor.Minibuffer.Compiled
import Editor.Themes.Compiled

/-!
# Checks of the config session against the real elaborator

The `config-test` executable is linked exactly like `editor`, with the glue
object, the Rust archive and Lean's elaborator. `mise run ffi-test` runs it
as `config-test <sysroot> <olean dir> <syntax fixtures>`: the Lean
toolchain's directory, the directory holding the package's `.olean` files,
and the directory of the syntax fixtures (`tests/syntax`), whose Rust
indent fixture the indent checks read. It reads nothing from the
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
- `shippedChecks`: what the executable's hosts are handed as compiled code
  (`Headless.shippedOver`): the registry they start with binds `C-s-f` to
  `toggle-fullscreen`, `s-m` to `minimise-window` and `s-q` to `quit`, all
  compiled, and registers the buffer commands with the ex names `b`, `ls`
  and `bd` bound to them;
- `scriptChecks`: the headless mode's script and its driver, and the editor
  loop through the host: a commit and the scene it prints, read from the
  library, a scene published after a reload's install and a job's command
  once the frame exists, the scene whose echo is the refusal once a command
  has released the focused buffer's text, the line the host prints for a
  program of the loop that is refused, and a window's close request with
  nothing unsaved ending the loop;
- `dispatchChecks`: keys through the host, with the test scheme and
  compiled commands and bindings written here: a compiled binding runs its
  command, a command that fails is rolled back and says so, the interrupt
  key stops a command that loops and stops nothing when none runs, config's
  command of a compiled command's name runs until a reload drops it, a
  reload rebinds a key, compiled bindings run when config fails to load,
  a command slower than the threshold is logged, on the fake clock, and a
  marked interrupt key no loop takes, one that cannot be read or one that
  arrives when the frame cannot be made, still has the flag lowered for it.
  Those last two run no loop: each pulls the key off the queue and hands it
  to the host's handler on its own thread (`withRunning`);
- `modeChecks`: modes through the host, with the test scheme: a role's key
  runs the command of a mode config defines, a store command among them,
  in a view of a buffer that has the mode, and once a reload drops the mode
  it runs the global binding; and a role's key runs the command of a mode
  compiled code hands the host (`Compiled.modes`), before any reload and
  after a reload of a config that defines none. The host's frame is made
  with the scratch buffer's major mode set (`Compiled.major`), since no
  command can set one yet, and the key pressed is the test scheme's for the
  role (`Session.pressKeys`), so no check names a scheme's key;
- `promptChecks`: prompts through the host, with the test scheme, the
  minibuffer's commands and its mode as compiled code hands them
  (`Minibuffer.commands`, `Minibuffer.modes`) and commands written here: a
  command asks, a commit is typed into the minibuffer and the scene shows
  it; the accept key runs the continuation's command with the answer and
  the cancel key does not; a job's result is delivered while a prompt is
  open, on the fake clock; the continuation is looked up when the answer
  arrives, across a reload; the answer's command runs before the next key;
  and it is looked up after the accepting command's write to a store was
  written back. The accept key and the cancel key are the test scheme's
  for the roles the minibuffer's mode fills;
- `exChecks`: the ex command line through the host, with the test scheme
  and the ex line's commands and the ex names that ship as compiled code
  hands them (`Ex.commands`, `Ex.bindings`): the ex line `reload` reloads
  the config with no restart, so a key config rebound runs the other
  command; an ex name config binds runs config's command, and is unknown
  after a reload without it; config's binding of a shipped name runs in
  its place until a reload drops it; and a name nobody bound is said in
  the scene's echo, with the editor going on. Each line is committed into
  the minibuffer and accepted with the test scheme's key for the role the
  minibuffer's mode fills;
- `exScriptChecks`: scripts that a command ends, with `Headless.run` on
  scripts built here, over the library's file service, so they run after
  `fileChecks` and share their table of waits and pump: `e` on a file in a
  temporary directory, a commit, `w`, a join and `q`, and the same with
  `wq` and a join after it, each leave the file holding the buffer's text
  and end the script with no failure and the `show` line after the quit
  not run; a `q` that is refused leaves the script running; and a wait on
  a host whose loop a command ended answers `ended`. They are apart from
  `scriptChecks`, which are defined before what these hosts are handed;
- `indentChecks`: `=` and the indented new lines through a host of the Vim
  scheme that ships, over the library's Rust grammar: `gg=G` on the
  mangled Rust indent fixture (`tests/syntax/rust/indent.rs`, read from the
  directory the third argument names) gives the fixture back, `=af`
  re-indents one function, one `u` undoes it and `.` repeats it, rows
  inside a string and a comment keep their indent, `RET` after an opening
  brace and `o`/`O` in a body start at the tree's level, and a buffer with
  no language or no indents query is as before;
- `evilChecks`: evil from config through the host, with the test scheme:
  a config that the real elaborator loads names the vocabulary the editor
  ships (`Evil.motions`) and hands it to evil's move command, as it is and
  with a motion of config's own added. It shows what `Editor.lean` lets
  config name; where a motion of the editor's leads is not said here;
- `reloadEchoChecks`: a rejected reload's first error is said in the echo
  area, while the old config runs; a reload that installs says nothing;
  and one rejected before the frame is made is said once it is;
- `faceChecks`: a face set in a config file reaches the next frame,
  through a host handed the display's real binding over the library's
  layout: the host's reload re-themes its display (`Config.retheme`), and
  the frame the library made of the next scene is compared with a second
  display's frame of the same scene in a theme written here; and a reload
  that makes `mode-line` taller sizes the next scene by the new heights,
  which `agree`, asked with no event between, shows;
- `cursorResolutionChecks`: the completeness check's model of a cursor's
  colours (`Themes.effective`) is the real layout's: for every shipped
  theme, and two whose cursor sets one colour alone, each cursor face's
  frame is the frame of a mirror theme that sets the modelled colours;
- `themeChecks`: named themes through a host over the display's real
  binding: `load-theme` switches the frame to the chosen theme with config's
  face over it, with no reload, and the scene line names the theme; and a
  config naming a theme nobody registered says so in the echo area;
- `fileChecks`: files through the host, over the library's file service.
  They are the checks whose hosts are over a real service, so they share
  one table of waits and the one completion pump, which the first of them
  starts, and they run last. Each has temporary directories of its own and
  writes its files' bytes itself.
  - A job from config loads a file, and its handler makes a text of it:
    the file's path is written into the config it loads.
  - The file commands and their jobs as compiled code registers them
    (`Files.commands`, `Files.jobs`): opening a file shows a buffer of its
    text, named by its base name; saving a modified buffer writes the
    buffer's text and clears the status line's modified field; opening a
    path that is open starts no load; open then save with no edit leaves
    the bytes of an LF file and of a CRLF file as they were, with the save
    seen to have written; a save of a file changed on disk leaves it and
    says so; and opening a path with no file says so and leaves the
    window. The driver's `run` hands a command no argument, so each host
    is handed a command, written here, that runs the compiled open command
    with a path (`opening`). The last runs the open command by its name,
    with no path: it asks for one, the path is committed into the
    minibuffer, and the accept key opens it. Each host is handed the
    minibuffer's commands and its mode for that.

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
  /-- The table of waits the hosts over the library's file service share,
  once the first of them has asked for it (`Context.fileWaits`); none until
  then. -/
  waits : IO.Ref (Option Job.Completions)
  /-- The directory of the syntax fixtures (`tests/syntax`), whose Rust
  fixtures the indent checks read. -/
  syntaxFixtures : System.FilePath

/-- The table of waits every host over the library's file service is staged
over, with the process's one completion pump running over it. It is made,
and the pump started on a dedicated task, the first time it is asked for,
and handed back as it is afterwards: a second pump would take the first
one's completions, so the checks of files share one table and one pump.
The executable exits explicitly, which a pump parked in its pull needs. -/
def Context.fileWaits (context : Context) : IO Job.Completions := do
  if let some completions← context.waits.get then
    return completions
  let completions ← Job.Completions.new
  discard <| IO.asTask (prio := .dedicated) (Job.pump completions)
  context.waits.set (some completions)
  return completions

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
        let table ← RealTexts.new
        let display ← DisplayRecorder.new Headless.cells table.snapshots.reader
        let (result, texts) ← run.runReal table display.handle
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
posts under source ids no other host of this process has. Its input scheme
is the test scheme, so no check names a shipped scheme's keys. -/
structure Stage (σ : Type) where
  /-- What the host is started with. -/
  collaborators : Headless.Collaborators σ TestScheme.scheme
  /-- Every line the host has emitted, oldest first. -/
  output : IO.Ref (Array String)
  /-- The thread that emitted each line of `output`. -/
  threads : IO.Ref (Array UInt64)
  /-- The clock the host's jobs wait on, and the loop times a command on. -/
  clock : Job.FakeClock
  /-- The watch service the host's jobs watch through: a fake over a model
  whose one directory is the made-up `/watched`. -/
  watches : Job.FakeFileWatches
  /-- Every entry the host has logged, oldest first. -/
  log : IO.Ref (Array String)

/-- What compiled code hands a host: its commands, its jobs, its key
bindings, its modes, its ex bindings, its themes, its languages, how long a command may take before it
is logged, and the major mode the scratch buffer starts in. -/
structure Compiled where
  /-- The compiled commands. -/
  commands : Array Config.Registration := #[]
  /-- The compiled jobs. -/
  jobs : Array Config.JobRegistration := #[]
  /-- The compiled key bindings. -/
  bindings : Array Config.KeyBinding := #[]
  /-- The compiled modes. -/
  modes : Array Mode := #[]
  /-- The compiled ex bindings. -/
  ex : Array Ex.Binding := #[]
  /-- The compiled themes. -/
  themes : Array NamedTheme := #[]
  /-- The compiled languages. -/
  languages : Array Language := #[]
  /-- How long a command may take before it is logged, in milliseconds. -/
  slowAfter : Nat := Loop.slowAfter
  /-- The major mode the scratch buffer starts in, if any: the host's frame
  is made with it set, so the mode's keys hold from the first key and no
  on-enter action runs. -/
  major : Option String := none

/-- A stage for a host over `elaborator` and `source`, with what `compiled`
hands it. Hosts follow one another on one queue: each gets source ids of its
own, so none takes a late event of an earlier one for its own. Its jobs wait
in a table of waits of its own, unless it is handed one (`waits`), as a
stage over a real service is. -/
def Stage.new {σ : Type} (context : Context) (elaborator : Config.Elaborator σ)
    (source : Config.Source) (compiled : Compiled := {}) (waits : Option Job.Completions := none) :
    IO (Stage σ) := do
  let output ← IO.mkRef #[]
  let threads ← IO.mkRef #[]
  let log ← IO.mkRef #[]
  let completions ←
    match waits with
    | some completions =>
      pure completions
    | none =>
      Job.Completions.new
  let clock ← Job.FakeClock.new completions
  let watches ← Job.FakeFileWatches.new completions { directories := #["/watched"] }
  let requests ← context.ids.modifyGet fun next => (next, next + 5)
  return {
      collaborators :=
        { elaborator, source,
          emit := fun line => do
            threads.modify (·.push (← IO.getTID))
            output.modify (·.push line),
          services := { completions, timers := clock.timers, fileWatches := watches.fileWatches }
          published := ← Snapshots.new, held := ← Job.HeldSnapshots.new, requests,
          wakeups := requests + 1, jobs := requests + 2, environment := requests + 3
          posts := requests + 4
          commands := compiled.commands, compiledJobs := compiled.jobs,
          bindings := compiled.bindings, modes := compiled.modes, ex := compiled.ex,
          themes := compiled.themes, languages := compiled.languages,
          log := fun entry => log.modify (·.push entry), slowAfter := compiled.slowAfter,
          start := do
            let loop ← Loop.start TestScheme.scheme ⟨0, 0⟩
            match compiled.major with
            | some name =>
              return { loop with state := (loop.state.setMajorMode ⟨0⟩ name).2 }
            | none =>
              return loop },
      output, threads, clock, watches, log }

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
  /-- The watch service the host's jobs watch through, which the check
  tells of changes. -/
  watches : Job.FakeFileWatches
  /-- Every entry the host has logged, oldest first. -/
  log : IO.Ref (Array String)

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

/-- Runs `check` against a host started on `stage`, and stops the host.
`false` if the check did not hold or the host did not stop. -/
def onStage {σ : Type} (stage : Stage σ) (check : Headless.Host → Stage σ → IO Bool) : IO Bool := do
  let host ← Headless.start stage.collaborators
  try
    let held ← check host stage
    let stopped ← host.stop patience
    return held && stopped
  catch error =>
    discard <| host.halt patience
    throw error

/-- Runs `check` against a host started on a stage of its own over
`elaborator` and `source`, with what `compiled` hands it, and stops the
host. `false` if the check did not hold or the host did not stop. -/
def staged {σ : Type} (context : Context) (elaborator : Config.Elaborator σ)
    (source : Config.Source) (check : Headless.Host → Stage σ → IO Bool)
    (compiled : Compiled := {}) : IO Bool := do
  onStage (← Stage.new context elaborator source compiled) check

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
    (through : Config.Source → Config.Source) (check : Session → IO Bool)
    (compiled : Compiled := {}) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory files
    staged context (around context.elaborator) (through (Config.Directory.source directory))
        (fun host stage =>
          check
            { host, directory, output := stage.output, threads := stage.threads,
              clock := stage.clock, watches := stage.watches, log := stage.log })
        compiled

/-- Runs `check` against a host started on a fresh temporary directory
holding `files`, with the real elaborator, and stops the host. `false` if the
check did not hold or the host did not stop. The directory is removed. -/
def withHost (context : Context) (files : List (String × String)) (check : Session → IO Bool)
    (compiled : Compiled := {}) : IO Bool :=
  withHostOver context files id id check compiled

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

/-- Asks the host for the scene, and returns every line it printed for it:
the scene's line, then each view's line followed by its status line. -/
def Session.sceneLines (session : Session) : IO (Array String) := do
  let before := (← session.output.get).size
  session.ask [.scene]
  return (← session.output.get).extract before

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

/-- A syntax tree request as `withRecordedSyntaxTree` records it: its
constructor, with the grammar or language and the kind it names, and a
highlight's faces by name, `-` for none. -/
def recordedRequest : SyntaxTreeRequest → String
  | .grammars => "grammars"
  | .attach _ grammar => s!"attach {grammar}"
  | .detach _ => "detach"
  | .compile grammar _ => s!"compile {grammar}"
  | .captureNames _ => "captureNames"
  | .captures .. => "captures"
  | .release _ => "release"
  | .shippedQuery grammar kind => s!"shippedQuery {grammar} {kind.name}"
  | .highlight _ _ faces =>
    s!"highlight {", ".intercalate (faces.map fun face => (face.map (·.name)).getD "-").toList}"
  | .inject .. => "inject"
  | .injectLanguage _ name .. => s!"injectLanguage {name}"
  | .keep _ kind _ => s!"keep {kind.name}"
  | .capturesOf _ kind .. => s!"capturesOf {kind.name}"
  | .refreshAfter milliseconds => s!"refreshAfter {milliseconds}"

/-- The real syntax tree binding over the library's syntax service, with
every request recorded (`recordedRequest`) in `asked`, which after an
attach waits, with a bound, for the attached text's tree to be delivered. -/
def recordingSyntaxTree (asked : IO.Ref (Array String)) (snapshots : SnapshotReader) :
    IO SyntaxTreeHandler := do
  let real ← RealSyntaxTree.new snapshots
  return fun request => do
    asked.modify (·.push (recordedRequest request))
    let reply ← real.handle request
    -- An attach waits for the attached text's tree, so the highlighter
    -- set after it sees no delivery of that parse, and no `parsed`
    -- event of it is left for a later check's host to take.
    if let .attach snapshot _ := request then
      if let some found← snapshots.find? snapshot then
        discard (Ffi.syntaxSettle found 5000)
    return reply

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

/-- The faces the captures of the library's shipped highlights query for
`grammar` are drawn in, by name, `-` for none, as `recordedRequest` writes a
highlight: by the shipped default over the language's `captures`, none by
default. Read from the library, so no check repeats its query. -/
def shippedFaces (grammar : String) (captures : List (String × Option FaceName) := []) :
    IO String := do
  let .ok source ← Ffi.syntaxShippedQuery grammar 0 | return "none shipped"
  let .ok query ← Ffi.SyntaxQuery.new grammar source | return "does not compile"
  let faces := Highlight.faces captures (← query.captureNames)
  return s!"highlight {", ".intercalate (faces.map fun face => (face.map (·.name)).getD "-").toList}"

/-- The Rust text of `rustObjectsChunk`: a method in an `impl`, after a
unit struct. -/
def rustObjectsText : String :=
  "struct S;\n\nimpl S {\n    fn one(&self) -> u8 {\n        let x = 1;\n        x\n    }\n}\n"

/-- A chunk whose `setup` defines the mode `rust-test`, whose text is
parsed with the grammar `rust` and drawn by the shipped default, and the
command `rust-buffer`, which puts `rustObjectsText` in the scratch buffer's
text, places the cursor inside the method's body, at `let`, and only then
makes `rust-test` its major mode, so the text is attached at its last
revision. -/
def rustObjectsChunk : String :=
  "def rustText : String := " ++ rustObjectsText.quote ++
    "

def rustBuffer : EditorM Unit := do
  let text : TextId := ⟨0⟩
  text.insert 0 rustText
  let cursor := ((rustText.splitOn \"let x\").headD \"\").utf8ByteSize
  discard <| (⟨0⟩ : ViewId).select { ranges := #[⟨cursor, cursor⟩], shape := .inclusive }
  discard <| (⟨0⟩ : ViewId).setMajorMode \"rust-test\"

def setup : SetupM Unit := do
  defineMode { name := \"rust-test\", syntaxTree := some { grammar := \"rust\" } }
  command \"rust-buffer\" rustBuffer
"

/-- Runs `check` against a host of the Vim scheme that ships, made over the
collaborators the executable's hosts are made of (`Headless.shippedOver`),
with the real elaborator, a config directory of `files` and the services of
a stage of its own; its syntax tree is the real binding over the library's
syntax service, which after an attach, and before a question of a text's
captures, waits, with a bound, for the text's tree to be delivered. Stops the host; `false` if the check did not
hold or the host did not stop. The directory is removed. -/
def withVimHost (context : Context) (files : List (String × String)) (check : Session → IO Bool) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory files
    let source := Config.Directory.source directory
    let stage ← Stage.new context context.elaborator source
    let staged := stage.collaborators
    let shipped :=
      Headless.shippedOver "" "" "" staged.emit staged.services staged.published staged.held
    let syntaxTree (snapshots : SnapshotReader) : IO SyntaxTreeHandler := do
      let real ← RealSyntaxTree.new snapshots
      return fun request => do
        -- A question of the captures waits for its snapshot's tree, so keys
        -- that edit and then ask are answered of a delivered tree.
        if let .capturesOf snapshot .. := request then
          if let some found← snapshots.find? snapshot then
            discard (Ffi.syntaxSettle found 5000)
        let reply ← real.handle request
        if let .attach snapshot _ := request then
          if let some found← snapshots.find? snapshot then
            discard (Ffi.syntaxSettle found 5000)
        return reply
    let collaborators :=
      { shipped with
        elaborator := context.elaborator, source, requests := staged.requests
        wakeups := staged.wakeups, jobs := staged.jobs, environment := staged.environment
        log := staged.log, syntaxTree }
    let host ← Headless.start collaborators
    try
      let held ←
        check {
              host, directory, output := stage.output, threads := stage.threads,
              clock := stage.clock
              watches := stage.watches, log := stage.log }
      let stopped ← host.stop patience
      return held && stopped
    catch error =>
      discard <| host.halt patience
      throw error

/-- The byte offset of the first occurrence of `needle` in `text`; none
when it does not hold it. -/
def offsetOf (text needle : String) : Option Nat :=
  match text.splitOn needle with
  | before :: _ :: _ => some before.utf8ByteSize
  | _ => none

/-- The view line of the last scene the host printed. -/
def lastViewLine (lines : Array String) : String :=
  (lines.filter (·.startsWith "view 0 ")).back?.getD ""

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

/-- The status line the host prints for the view `view`, selected, of a
buffer called `name`, modified or not, opened from `file` or from none, of
which the test scheme reports nothing, with its cursor at `cursor` (a row
and a column in cells) in a text of `lines` rows, and with its file found
changed on disk by a check when `changed`: what the host prints
(`Headless.statusLine`) of the fields the shipped mode line gives such a
view (`ModeLine.standard`). So a check that compares a host's whole output
repeats neither the mode line's faces and texts nor the host's form. Each
call site passes the cursor its printed `selections` imply and the rows its
text has, since the line:col and the position segments read them. The
scratch buffer is the default: the loop's frame is made with it, and its
name is the editor state's to choose. -/
def statusOf (view : Nat := 0) (name : String := "scratch") (modified : Bool := false)
    (cursor : Point := ⟨0, 0⟩) (lines : Nat := 1) (file : Option System.FilePath := none)
    (changed : Bool := false) : String :=
  let saved := UndoTree.new ⟨0⟩ 0
  -- A file whose change on disk a check found has the changed mark,
  -- whatever its stamps; with no path given, it has none to show.
  let path := if changed then some (file.getD "") else file
  let buffer : Buffer :=
    { name, text := ⟨0⟩, history := if modified then saved.record 1 else saved
      file :=
        path.map fun path =>
          { path, stamp := { seconds := 0, nanoseconds := 0, size := 0 }
            changed := if changed then some { found := none, told := true } else none } }
  Headless.statusLine ⟨view⟩ (ModeLine.standard.fields { buffer, cursor := some cursor, lines })

/-- Whether `output` has a line that says a job registered under `name`
ended ok, whatever its id: the loop's own checks of files shift the ids of
the jobs a command starts. -/
def endedOk (output : Array String) (name : String) : Bool :=
  output.any fun line => line.startsWith "job " && line.endsWith s!" {name}: ok"

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
                  "status 0: mode-line.buffer \"scratch\" +4 | mode-line.secondary \"hi\" +4, mode-line.secondary \"1:3\" +4"] &&
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

/-- The keys the key string `text` names; none when it is refused. -/
def keysOf (text : String) : List Key :=
  (Key.parse text).toOption.getD []

namespace Session

/-- Sends a press of each key the key string `text` names, in order, as the
window would report them. -/
def type (session : Session) (text : String) : IO Unit := do
  for key in keysOf text do
    session.host.press key

/-- Sends a press of each key the key string `text` names, and waits until
the editor thread has handled them. Throws if that takes longer than
`patience`. -/
def typed (session : Session) (text : String) : IO Unit := do
  session.type text
  session.ask []

/-- Sends a press of each of `keys`, in order, and waits until the editor
thread has handled them. Throws if that takes longer than `patience`. -/
def pressKeys (session : Session) (keys : List Key) : IO Unit := do
  for key in keys do
    session.host.press key
  session.ask []

/-- Asks the host for the scene, and returns what it printed of it: the echo
area's text, quoted as the scene line has it, and each view's line. -/
def scene (session : Session) : IO (String × Array String) := do
  let before := (← session.output.get).size
  session.ask [.scene]
  let printed := (← session.output.get).extract before
  -- The echo's text is between `, echo ` and `, echo padding `.
  let echo :=
    match printed[0]?.map (·.splitOn ", echo padding ") with
    | some (head :: _) =>
      match head.splitOn ", echo " with
      | _ :: rest => ", echo ".intercalate rest
      | [] => ""
    | _ => ""
  return (echo, printed.filter (·.startsWith "view "))

/-- Asks the host to show its commands, texts and stores, and returns the
lines it printed for them. -/
def shown (session : Session) : IO (Array String) := do
  let before := (← session.output.get).size
  session.ask [.show]
  return (← session.output.get).extract before

end Session

/-- A compiled command called `name` that replaces what the focused window's
selection covers with `text`. -/
def inserting (name text : String) : Config.Registration :=
  { name,
    action :=
      .call fun call => do
        Loop.insert call.target text }

/-- A compiled command called `name` that makes a text holding `text`. -/
def making (name text : String) : Config.Registration :=
  { name, action := .plain (discard <| createText text) }

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

/-- The binding of the keys the key string `text` names to the command
`command`. -/
def bound (text command : String) : Config.KeyBinding :=
  { keys := keysOf text, command }

/-- What compiled code hands the hosts of the dispatch checks: `stamp`, which
inserts `!` at the cursor, on `C-c s`; `boom` on `C-c b`; and `spin` on
`C-c l`. -/
def dispatchCompiled : Compiled :=
  { commands := #[inserting "stamp" "!", boomCommand, spinCommand]
    bindings := #[bound "C-c s" "stamp", bound "C-c b" "boom", bound "C-c l" "spin"] }

/-- What compiled code hands a host whose compiled `stamp` makes a text
holding `compiled`, on `C-c s`. -/
def stampCompiled : Compiled :=
  { commands := #[making "stamp" "compiled"], bindings := #[bound "C-c s" "stamp"] }

/-- A chunk whose `setup` registers a command `stamp` that makes a text
holding `config`. -/
def stampChunk : String :=
  "def setup : SetupM Unit := do\n  command \"stamp\" (discard <| createText \"config\")\n"

/-- A chunk whose `setup` registers nothing. -/
def emptyChunk : String :=
  "def setup : SetupM Unit := pure ()\n"

/-- A chunk with two commands, `one` and `two`, each of which makes a text
holding its name, and a `setup` that binds `C-c t` to `command`. -/
def bindingChunk (command : String) : String :=
  "def setup : SetupM Unit := do
  command \"one\" (discard <| createText \"one\")
  command \"two\" (discard <| createText \"two\")
  bindKey \"C-c t\" \"" ++
    command ++
    "\"
"

/-- A chunk with a store of one number, a command `bump` over it that adds
one, and a `setup` that binds `C-c u` to it. -/
def boundCounterChunk : String :=
  "def counter : Store Nat :=
  { name := \"counter\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun n => pure (n + 1)
  bindKey \"C-c u\" \"bump\"
"

/-- The line of a view 0 that fills a frame of no size, showing `text` with
its one cursor at `cursor`. -/
def viewLine (text : String) (cursor : Nat) : String :=
  s!"view 0 0,0 0x0: {text.quote}, scroll 0, selections {cursor}..{cursor}, padding 8 8"

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

/-- A press of the interrupt key as the library hands it to a host: posted as
the window would report it, which raises the flag when the library has been
told the key, and pulled back off the editor queue, marked. What an earlier
host left on the queue is pulled past: the press is behind it, so no pull
waits. `none` when the press was not queued, or the queues were quit. -/
def interruptPulled : IO (Option Ffi.Event) := do
  unless ← Event.post (.key Watch.interruptKey true "") do
    return none
  repeat
    let event ← Ffi.nextEvent .editor
    if event.kind == .quit then
      return none
    if event.source.kind == .window && event.kind == .key then
      return some event
  return none

/-- The checks of key dispatch through the headless host, on the real queue,
the real text binding, the library's interrupt flag and the real elaborator,
with the test scheme and compiled commands and bindings written here. -/
def dispatchChecks (context : Context) : List Check :=
  [{  name :=
        "a key a compiled binding binds runs its compiled command for the focused window, and the scene shows its effect"
      run :=
        withHost context []
          (fun session => do
            session.typed "C-c s"
            return (← session.scene) == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled },
    { name :=
        "a command that fails after editing: the scene's echo is its error, the view's text and its selection are those before the command, and the next key runs its command"
      run :=
        withHost context []
          (fun session => do
            unless ← Event.post (.commit "abcd") do
              return false
            let before ← session.scene
            session.typed "C-c b"
            let failed ← session.scene
            session.typed "C-c s"
            let after ← session.scene
            return before == ("".quote, #[viewLine "abcd" 4]) &&
                failed == ("boom: refused: bad range".quote, #[viewLine "abcd" 4]) &&
                after == ("".quote, #[viewLine "abcd!" 5]))
          dispatchCompiled },
    { name :=
        "the interrupt key arrives while a command loops over requests: the command stops, the scene's echo says so, the view's text is that before the command, and the next key runs its command"
      run :=
        withHost context []
          (fun session => do
            session.type "C-c l"
            -- The loop has taken the key that runs the command: it is in the
            -- command, or about to be.
            unless ← eventually (return (← session.output.get).contains "key arrived: l - -") do
              return false
            session.host.press Watch.interruptKey
            unless ← session.host.settle patience do
              return false
            let interrupted ← session.scene
            let lowered ← Ffi.interruptRaised
            session.typed "C-c s"
            let after ← session.scene
            return interrupted == ("spin: interrupted".quote, #[viewLine "" 0]) && !lowered &&
                after == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled },
    { name :=
        "the interrupt key arrives while no command is running: the flag is down once the loop has taken it, and the next key's command runs to its end"
      run :=
        withHost context []
          (fun session => do
            session.host.press Watch.interruptKey
            session.ask []
            let lowered ← Ffi.interruptRaised
            session.typed "C-c s"
            return !lowered && (← session.scene) == ("".quote, #[viewLine "!" 1]))
          dispatchCompiled },
    { name :=
        "config registers a command under a compiled command's name: the key bound to the name runs config's command, and after a reload without the registration it runs the compiled one"
      run :=
        withHost context [("10-stamp.lean", stampChunk)]
          (fun session => do
            session.ask [.reload]
            session.typed "C-c s"
            let overridden ← session.shown
            session.write "10-stamp.lean" emptyChunk
            session.ask [.reload]
            session.typed "C-c s"
            let dropped ← session.shown
            return overridden == #["commands: stamp", "text 0: \"\"", "text 1: \"config\""] &&
                dropped ==
                  #["commands: stamp", "text 0: \"\"", "text 1: \"config\"",
                    "text 2: \"compiled\""] &&
                ((← session.lines).filter (·.startsWith "reload ")) ==
                  #["reload 1: installed, 1 chunks, 1 commands",
                    "reload 2: installed, 1 chunks, 0 commands"])
          stampCompiled },
    { name :=
        "a reload binds a key to a different command: the key then runs the new command, and the old one does not run again"
      run :=
        withHost context [("10-bind.lean", bindingChunk "one")] fun session => do
          session.ask [.reload]
          session.typed "C-c t"
          session.write "10-bind.lean" (bindingChunk "two")
          session.ask [.reload]
          session.typed "C-c t"
          return (← session.shown) ==
              #["commands: one two", "text 0: \"\"", "text 1: \"one\"", "text 2: \"two\""] },
    { name :=
        "config fails to load: the reload is rejected, and the key a compiled binding binds still runs its compiled command; and it runs it with no reload asked at all"
      run := do
        let rejected ←
          withHost context [("10-bad.lean", "def setup : SetupM Unit := \"not a setup\"\n")]
              (fun session => do
                session.ask [.reload]
                session.typed "C-c s"
                let shown ← session.shown
                return ((← session.lines).filter (!·.startsWith "key arrived")).extract 0 2 ==
                      #["reload 1: rejected", "diagnostic: 10-bad.lean: error"] &&
                    shown == #["commands: stamp", "text 0: \"\"", "text 1: \"compiled\""])
              stampCompiled
        let unasked ←
          withHost context []
              (fun session => do
                session.typed "C-c s"
                return (← session.shown) ==
                    #["commands: stamp", "text 0: \"\"", "text 1: \"compiled\""])
              stampCompiled
        return rejected && unasked },
    { name :=
        "a key bound from config to a command over a store runs it, and what it wrote is written back: two presses leave the store at 2"
      run :=
        withHost context [("10-counter.lean", boundCounterChunk)] fun session => do
          session.ask [.reload]
          session.typed "C-c u C-c u"
          return (← session.shown).contains "store counter v1: 2" },
    { name :=
        "a command that takes longer than the threshold on the fake clock produces one log entry with its name and how long it took, on the log and not on the output; a press with the clock not moved adds none"
      run :=
        withHost context []
          (fun session => do
            -- The loop reads the clock just before the command and just
            -- after it. Each reading is held, so the clock is moved between
            -- the two and at no other time.
            let first ← session.clock.holdReads
            session.type "C-c s"
            unless ← eventually (return (← session.clock.held) == 1) do
              return false
            let second ← session.clock.holdReads
            first.resolve ()
            unless ← eventually (return (← session.clock.held) == 2) do
              return false
            session.clock.advance 60
            second.resolve ()
            session.ask []
            let once ← session.log.get
            session.typed "C-c s"
            return once == #["slow command: stamp took 60 ms"] && (← session.log.get) == once &&
                !(← session.output.get).any (·.startsWith "slow command"))
          { dispatchCompiled with slowAfter := 50 } },
    { name :=
        "the driver's run of a compiled command that is given its call makes the frame before the first window event and runs it for the focused window, as it does once a window event has arrived"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "stamp", .run "missing"]
            unless ← Event.post (.commit "a") do
              return false
            session.ask [.run "stamp"]
            return (← session.output.get) ==
                  #["run stamp: ok", "run missing: no such command", "run stamp: ok"] &&
                (← session.scene) == ("".quote, #[viewLine "!a!" 3]))
          dispatchCompiled },
    { name :=
        "a window key the library marked as the interrupt key that cannot be read is dropped, and the flag is lowered for it, since it has been taken off the queue"
      run :=
        withRunning context id fun collaborators running stage => do
          let some pulled ← interruptPulled | return false
          let raised ← Ffi.interruptRaised
          -- A word past the key's: the mark is still on it, and it no longer
          -- reads as a key.
          let unreadable := { pulled with words := pulled.words.push 0 }
          let running ← running.handle collaborators unreadable
          return raised && (Event.ofFfi unreadable).toOption.isNone && running.frame.isNone &&
              (← stage.output.get).isEmpty &&
              !(← Ffi.interruptRaised) },
    { name :=
        "a key the library marked as the interrupt key that arrives when the host cannot make its frame is dropped, the refusal is printed, and the flag is lowered for it, since it has been taken off the queue"
      run :=
        withRunning context (fun collaborators => { collaborators with start := throw .noSuchText })
          fun collaborators running stage => do
          let some pulled ← interruptPulled | return false
          let raised ← Ffi.interruptRaised
          let running ← running.handle collaborators pulled
          return raised && running.frame.isNone &&
              (← stage.output.get).back? == some "loop: refused: no such text" &&
              !(← Ffi.interruptRaised) }]

/-- A chunk with a store of one number and a command `bump` over it that
adds one, and a `setup` that declares both and, when `withMode`, defines the
mode `listing`, which fills the role `next-item` with `bump`. -/
def listingChunk (withMode : Bool) : String :=
  "def counter : Store Nat :=
  { name := \"counter\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun n => pure (n + 1)
" ++
    if withMode then "  defineMode { name := \"listing\", roles := [(Role.nextItem, \"bump\")] }\n"
    else ""

/-- The keys of the role `next-item` under the test scheme. -/
def nextItemKeys : List Key :=
  (TestScheme.scheme.roleKey Role.nextItem).getD []

/-- What compiled code hands the host of the mode checks: `global`, which
makes a text holding `compiled`, bound to the keys of `next-item`, and the
scratch buffer in the major mode `listing`, which only config defines. -/
def listingCompiled : Compiled :=
  { commands := #[making "global" "compiled"]
    bindings := #[{ keys := nextItemKeys, command := "global" }]
    major := some "listing" }

/-- What compiled code hands the host of the compiled mode's check: `global`
as in `listingCompiled`, the mode `compiled-listing`, which fills the role
`next-item` with `mode-next`, a command that makes a text holding `mode`,
and the scratch buffer in that mode. -/
def compiledListing : Compiled :=
  { listingCompiled with
    commands := listingCompiled.commands.push (making "mode-next" "mode")
    modes := #[{ name := "compiled-listing", roles := [(Role.nextItem, "mode-next")] }]
    major := some "compiled-listing" }

/-- The checks of modes through the headless host, with the test scheme and
the real elaborator: a mode config defines holds while config defines it.
The key a check presses is the test scheme's for a role, so no check names
a scheme's key. -/
def modeChecks (context : Context) : List Check :=
  [{  name :=
        "a role's key runs the command of the mode config defines in a view of a buffer that has the mode, a store command among them; once a reload drops the mode it runs the global binding, and the store is as it was"
      run :=
        withHost context [("10-listing.lean", listingChunk true)]
          (fun session => do
            session.ask [.reload]
            session.pressKeys nextItemKeys
            let first ← session.shown
            session.write "10-listing.lean" (listingChunk false)
            session.ask [.reload]
            session.pressKeys nextItemKeys
            let second ← session.shown
            return nextItemKeys.length > 0 && first.contains "store counter v1: 1" &&
                !first.any (·.endsWith "\"compiled\"") &&
                second.contains "store counter v1: 1" &&
                second.any (·.endsWith "\"compiled\""))
          listingCompiled },
    { name :=
        "a role's key runs the command of a mode compiled code hands the host in a view of a buffer that has the mode, before any reload and after a reload of a config that defines no mode"
      run :=
        withHost context [("10-listing.lean", listingChunk false)]
          (fun session => do
            session.pressKeys nextItemKeys
            let first ← session.shown
            session.ask [.reload]
            session.pressKeys nextItemKeys
            let second ← session.shown
            let made (shown : Array String) (text : String) :=
              (shown.filter (·.endsWith text.quote)).size
            return nextItemKeys.length > 0 && made first "mode" == 1 &&
                made first "compiled" == 0 &&
                second.contains "store counter v1: 0" &&
                made second "mode" == 2 &&
                made second "compiled" == 0)
          compiledListing }]

/-- The compiled command `split`: it splits the window it is called on along
rows. -/
def splitCommand : Config.Registration :=
  { name := "split"
    action :=
      .call fun call => do
        discard <| call.target.window.id.split .rows }

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

/-- The keys of the role `activate` under the test scheme: the minibuffer's
accept key, since its mode fills that role with the accept command. -/
def acceptKeys : List Key :=
  (TestScheme.scheme.roleKey Role.activate).getD []

/-- The keys of the role `quit` under the test scheme: the minibuffer's
cancel key. -/
def cancelKeys : List Key :=
  (TestScheme.scheme.roleKey Role.quit).getD []

/-- What compiled code hands every host of the prompt checks: the
minibuffer's commands and its mode, as the executable is handed them
(`Editor/Minibuffer/Compiled.lean`). -/
def minibufferCompiled : Compiled :=
  { commands := Minibuffer.commands, modes := Minibuffer.modes }

/-- What compiled code hands the hosts of the prompt checks that load no
config: the minibuffer's commands and its mode, and commands written here.

- `ask` asks `Name: ` with the initial value `Ada` and the continuation
  `greet`.
- `greet` is given its call: it inserts its first argument at the cursor of
  the window it is called with and says `hello ` and that argument in the
  echo area.
- `other`, on `C-c o`, says `other`.
- `rest-and-ask` starts the job `nap` of `nappingCompiled`, whose command
  inserts `napped` in view 0, and then asks as `ask` does. -/
def promptCompiled : Compiled :=
  let asks : EditorM Unit := discard <| prompt "Name: " { command := "greet" } "Ada"
  { minibufferCompiled with
    commands :=
      Minibuffer.commands ++
        #[{ name := "ask", action := .plain asks },
          { name := "greet"
            action :=
              .call fun call => do
                let name :=
                  match call.arguments with
                  | .str name :: _ => name
                  | _ => "nobody"
                call.target.insertAtSelections name
                message s!"hello {name}" },
          { name := "other", action := .plain (message "other") },
          { name := "rest-and-ask"
            action :=
              .plain do
                discard <| startJob "nap"
                asks }]
    jobs := nappingCompiled.jobs
    bindings := #[bound "C-c o" "other"] }

/-- A chunk whose `setup` registers `greet` as a command that is given its
call, which says `label` and its first argument in the echo area, and
`ask`, which asks `Name: ` with the initial value `Ada` and the continuation
`greet`. -/
def greetWithChunk (label : String) : String :=
  "def setup : SetupM Unit := do
  commandWith \"greet\" fun call =>
    match call.arguments with
    | .str name :: _ => message s!\"" ++
    label ++
    " {name}\"
    | _ => message \"" ++
    label ++
    "\"
  command \"ask\" (discard <| prompt \"Name: \" { command := \"greet\" } \"Ada\")
"

/-- A chunk whose `setup` registers `ask` as in `greetWithChunk`, and no
`greet`. -/
def askOnlyChunk : String :=
  "def setup : SetupM Unit := do
  command \"ask\" (discard <| prompt \"Name: \" { command := \"greet\" } \"Ada\")
"

/-- A chunk with a store of one number and three commands: `bump`, over the
store, adds one; `bump-accept`, over the store, accepts the open prompt and
adds one; and `ask` asks `Name: ` with the continuation `bump`. -/
def bumpAcceptChunk : String :=
  "def counter : Store Nat :=
  { name := \"counter\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  counter.declare
  counter.command \"bump\" fun n => pure (n + 1)
  counter.command \"bump-accept\" fun n => do
    discard acceptPrompt
    pure (n + 1)
  command \"ask\" (discard <| prompt \"Name: \" { command := \"bump\" })
"

/-- The line of the minibuffer's view, view 1 in a frame of no size, showing
`text` with its one cursor at `cursor`. -/
def minibufferLine (text : String) (cursor : Nat) : String :=
  s!"view 1 0,0 0x0: {text.quote}, scroll 0, selections {cursor}..{cursor}, padding 8 0"

/-- The status line of the minibuffer's view, view 1, while a prompt
labelled `label` is open: what the host prints (`Headless.statusLine`) of
the one field the loop gives that view, the label in the prompt's face
(`Loop.promptFace`). So a check repeats neither the face nor the host's
form. -/
def promptStatus (label : String := "Name: ") : String :=
  Headless.statusLine ⟨1⟩ #[{ text := label, face := Loop.promptFace }]

/-- Whether the scene line `line` names `view` as the focused view. -/
def focuses (line : String) (view : Nat) : Bool :=
  (line.splitOn s!", focused {view}, ").length == 2

/-- The checks of prompts through the headless host (`Editor/Headless.lean`),
on the real queue, the real text binding and the real elaborator, with the
test scheme: the host is handed the minibuffer's commands and its mode
(`Editor/Minibuffer/Compiled.lean`), and runs the answer's command of an
accepted prompt before its next event. The accept key and the cancel key
are the test scheme's keys for the roles the minibuffer's mode fills, so no
check names a scheme's key. -/
def promptChecks (context : Context) : List Check :=
  [{  name :=
        "a command asks for a prompt and a text is committed: the scene has the window's view and the minibuffer's, whose line holds the initial value and the committed text and whose status line is the prompt text, the minibuffer's view is the focused one, and show lists the minibuffer's text; after the accept key the echo area is the continuation's with the answer, which it inserted in the asking window, there is one view, with the focus, and the minibuffer's text is listed no more"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask"]
            unless ← Event.post (.commit "!") do
              return false
            let asking ← session.sceneLines
            let listed ← session.shown
            session.pressKeys acceptKeys
            let accepted ← session.sceneLines
            let after ← session.shown
            return !acceptKeys.isEmpty && (asking[0]?.map (focuses · 1)) == some true &&
                asking.extract 1 ==
                  #[viewLine "" 0, statusOf, minibufferLine "Ada!" 4, promptStatus] &&
                listed.contains "text 1: \"Ada!\"" &&
                (accepted[0]?.map fun line =>
                    focuses line 0 &&
                      (line.splitOn s!", echo {"hello Ada!".quote}, ").length == 2) ==
                  some true &&
                accepted.extract 1 ==
                  #[viewLine "Ada!" 4, statusOf (modified := true) (cursor := ⟨0, 4⟩)] &&
                !after.any (·.startsWith "text 1: ") &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          promptCompiled },
    { name :=
        "the cancel key in place of the accept key: the continuation's command does not run, the echo area is empty, there is one view, the window's, as it was and with the focus, and the minibuffer's text is listed no more; the scene published after that one has an empty echo area too, so the library refused neither the release of the minibuffer's text nor, after it, that of the snapshot the last scene named"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask"]
            unless ← Event.post (.commit "!") do
              return false
            session.pressKeys cancelKeys
            let cancelled ← session.sceneLines
            -- The scene request was followed by a scene of its own: a
            -- release the cancel's publish was refused would be in its
            -- echo area.
            let later ← session.sceneLines
            let after ← session.shown
            let quiet (line : String) : Bool :=
              focuses line 0 && (line.splitOn s!", echo {"".quote}, ").length == 2
            return !cancelKeys.isEmpty && cancelKeys != acceptKeys &&
                cancelled[0]?.map quiet == some true &&
                later[0]?.map quiet == some true &&
                later.extract 1 == cancelled.extract 1 &&
                cancelled.extract 1 == #[viewLine "" 0, statusOf] &&
                !after.any (·.startsWith "text 1: ") &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          promptCompiled },
    { name :=
        "a job completes while a prompt is open, on the fake clock: once the clock lets it go the host prints that its command ran, the window shows what that command inserted, and the scene still has the minibuffer's view, with the focus; the accept key afterwards runs the continuation's command"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "rest-and-ask"]
            unless ← eventually (return (← session.clock.waiting) == 1) do
              return false
            let before ← session.output.get
            session.clock.advance 10
            let joined ← session.host.join patience
            let delivered := (← session.output.get).extract before.size
            let waiting ← session.sceneLines
            session.pressKeys acceptKeys
            let (echo, views) ← session.scene
            return before == #["run rest-and-ask: ok", "job 1 nap: started"] &&
                joined == .settled &&
                delivered == #["job 1 nap: ok"] &&
                (waiting[0]?.map (focuses · 1)) == some true &&
                waiting.extract 1 ==
                  #[viewLine "napped" 6, statusOf (modified := true) (cursor := ⟨0, 6⟩),
                    minibufferLine "Ada" 3, promptStatus] &&
                echo == "hello Ada".quote &&
                views == #[viewLine "nappedAda" 9])
          promptCompiled },
    { name :=
        "the continuation is looked up when the answer arrives: config registers it as a command that is given its call, a prompt is asked for, config is reloaded with another command of the name, and the accept key runs the new one with the answer; asked for again and reloaded with a config that registers none, the accept key leaves no such command in the echo area, by the continuation's name, and the prompt closed"
      run :=
        withHost context [("10-greet.lean", greetWithChunk "one")]
          (fun session => do
            session.ask [.reload]
            session.ask [.run "ask"]
            session.write "10-greet.lean" (greetWithChunk "two")
            session.ask [.reload]
            let asking ← session.scene
            session.pressKeys acceptKeys
            let renamed ← session.scene
            session.ask [.run "ask"]
            session.write "10-greet.lean" askOnlyChunk
            session.ask [.reload]
            session.pressKeys acceptKeys
            let dropped ← session.scene
            return asking == ("".quote, #[viewLine "" 0, minibufferLine "Ada" 3]) &&
                renamed == ("two Ada".quote, #[viewLine "" 0]) &&
                dropped == ("greet: no such command".quote, #[viewLine "" 0]))
          minibufferCompiled },
    { name :=
        "the accept key and a key bound to another command, sent one after the other with no wait between: the continuation's command ran, since the window holds what it inserted, and it ran before the second key was handled, since the echo area is the other command's"
      run :=
        withHost context []
          (fun session => do
            session.ask [.run "ask"]
            for key in acceptKeys do
              session.host.press key
            session.type "C-c o"
            session.ask []
            return (← session.scene) == ("other".quote, #[viewLine "Ada" 3]))
          promptCompiled },
    { name :=
        "the answer's command is a step of its own, looked up after the accepting command's write was written back: with a store, a command over it that accepts the open prompt and adds one, and a continuation over it that adds one, the store holds two after the accept"
      run :=
        withHost context [("10-bump.lean", bumpAcceptChunk)]
          (fun session => do
            session.ask [.reload]
            session.ask [.run "ask", .run "bump-accept"]
            let shown ← session.shown
            return shown.contains "store counter v1: 2" &&
                (← session.scene) == ("".quote, #[viewLine "" 0]))
          minibufferCompiled }]

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

/-- Runs `line` on the ex line: the ex command is run by its name, which
asks, `line` is committed into the minibuffer, and the accept key is
pressed. Waits until the editor thread has handled them and no reload is
running. `false` if the commit was refused. -/
def Session.exLine (session : Session) (line : String) : IO Bool := do
  session.ask [.run Ex.name]
  unless ← Event.post (.commit line) do
    return false
  session.pressKeys acceptKeys
  return true

/-- The echo area's text of the scene the host prints, quoted as the scene
line has it. -/
def Session.echo (session : Session) : IO String :=
  return (← session.scene).1

/-- A chunk whose `setup` registers two commands, `one` and `two`, each of
which says its name in the echo area, and binds `C-c t` to `command`. -/
def sayingChunk (command : String) : String :=
  "def setup : SetupM Unit := do
  command \"one\" (message \"one\")
  command \"two\" (message \"two\")
  bindKey \"C-c t\" \"" ++
    command ++
    "\"
"

/-- A chunk whose `setup` registers `greet-named`, a command that is given
its call and says `hello ` and its first argument in the echo area, and,
when `bound`, binds the ex name `greet` to it, taking text. -/
def greetExChunk (bound : Bool) : String :=
  "def setup : SetupM Unit := do
  commandWith \"greet-named\" fun call =>
    match call.arguments with
    | .str name :: _ => message s!\"hello {name}\"
    | _ => message \"hello\"
" ++
    if bound then "  exCommand \"greet\" \"greet-named\" (takes := .text)\n" else ""

/-- A chunk whose `setup` registers `mine`, which says `mine` in the echo
area, and binds the ex name `w` to it. -/
def ownWriteChunk : String :=
  "def setup : SetupM Unit := do
  command \"mine\" (message \"mine\")
  exCommand \"w\" \"mine\"
"

/-- The checks of the ex command line through the headless host
(`Editor/Headless.lean`), on the real queue, the real text binding and the
real elaborator, with the test scheme: the host is handed the ex line's
commands and the ex names that ship as compiled code registers them
(`Editor/Ex/Compiled.lean`), registers the ex bindings config's `setup`
makes, and reloads when a command asks. Each line is committed into the
minibuffer and accepted with the test scheme's key for the role the
minibuffer's mode fills (`Session.exLine`), so no check names a scheme's
key. They open and save no file. -/
def exChecks (context : Context) : List Check :=
  let installs (lines : Array String) : Array String :=
    lines.filter fun line => (line.splitOn ": installed").length == 2
  [{  name :=
        "criterion 3: a config binds a key to a command and the key runs it; the config's file is changed to bind the key to another command and the ex line reload is run: the host reloads, with no restart, and the key then runs the other command"
      run :=
        withHost context [("10-setup.lean", sayingChunk "one")]
          (fun session => do
            session.ask [.reload]
            session.typed "C-c t"
            let first ← session.echo
            session.write "10-setup.lean" (sayingChunk "two")
            unless ← session.exLine "reload" do
              return false
            let reloaded := installs (← session.lines)
            session.typed "C-c t"
            let second ← session.echo
            return first == "one".quote &&
                reloaded ==
                  #["reload 1: installed, 1 chunks, 2 commands",
                    "reload 2: installed, 1 chunks, 2 commands"] &&
                second == "two".quote)
          exCompiled },
    { name :=
        "criterion 4: config binds an ex name to a command of its own, and the name run on the ex line runs that command with the rest of the line; after a reload of a config without the binding the name is not an ex command, by the ex line's message"
      run :=
        withHost context [("10-setup.lean", greetExChunk true)]
          (fun session => do
            session.ask [.reload]
            unless ← session.exLine "greet Ada" do
              return false
            let greeted ← session.echo
            session.write "10-setup.lean" (greetExChunk false)
            unless ← session.exLine "reload" do
              return false
            let reloaded := installs (← session.lines)
            unless ← session.exLine "greet Ada" do
              return false
            let dropped ← session.echo
            return greeted == "hello Ada".quote && reloaded.size == 2 &&
                dropped == (Ex.unknown "greet").quote)
          exCompiled },
    { name :=
        "config's binding of an ex name a compiled binding has runs config's command in its place, and the compiled binding's command runs again once a reload drops config's"
      run :=
        withHost context [("10-setup.lean", ownWriteChunk)]
          (fun session => do
            unless ← session.exLine "w" do
              return false
            let compiled ← session.echo
            session.ask [.reload]
            unless ← session.exLine "w" do
              return false
            let own ← session.echo
            session.write "10-setup.lean" emptyChunk
            unless ← session.exLine "reload" do
              return false
            unless ← session.exLine "w" do
              return false
            let again ← session.echo
            return compiled == (Files.noFile "scratch").quote && own == "mine".quote &&
                again == (Files.noFile "scratch").quote)
          exCompiled },
    { name :=
        "criterion 5: a name nobody bound, run on the ex line, is said in the echo area of the scene, by the ex line's message, with the prompt closed, and the editor goes on: a key's command run after it runs"
      run :=
        withHost context []
          (fun session => do
            unless ← session.exLine "bogus now" do
              return false
            let unknown ← session.sceneLines
            session.typed "C-c o"
            let after ← session.echo
            return (unknown[0]?.map fun line =>
                    focuses line 0 &&
                      (line.splitOn s!", echo {(Ex.unknown "bogus").quote}, ").length == 2) ==
                  some true &&
                unknown.extract 1 == #[viewLine "" 0, statusOf] &&
                after == "other".quote &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          exCompiled }]

/-- A chunk with a motion of its own, `to-second`, which answers the offset
1 from anywhere, and a `setup` that registers two commands that are given
their call. Each runs evil's move command (`Evil.move`) over a vocabulary
the chunk names: `own` over the one the editor ships (`Evil.motions`) with
`to-second` added, by `to-second`'s name, and `first-shipped` over the one
the editor ships as it is, by the name its first entry has. So the chunk
names no motion of the editor's, and says nothing of where one leads. -/
def vocabularyChunk : String :=
  "def toSecond : Vocabulary.Motion :=
  { name := \"to-second\", target := fun _ _ => pure { head := 1 } }

def setup : SetupM Unit := do
  commandWith \"own\" fun call =>
    Evil.move (Evil.motions.push toSecond) { call with arguments := [.str \"to-second\"] }
  commandWith \"first-shipped\" fun call =>
    Evil.move Evil.motions
      { call with arguments := [.str ((Evil.motions[0]?.map (·.name)).getD \"\")] }
"

/-- A chunk whose `setup` registers three commands that are given their
call, over the tables the editor ships, each named by the chunk and none
restated: `delete-word` moves to the line's start (`Evil.move`) and runs
evil's operate command (`Evil.operate Evil.operators Evil.motions Evil.objects`) with
the arguments the Vim scheme compiles `d w` to; `again` hands evil's repeat
command (`Evil.repeat`) that same change, as the scheme's repeat key would,
which the repeat command has the registry's operate command run; and `back`
is evil's undo (`Evil.undo`). The names of the operator, the motions and
the command are read off the editor's own entries. -/
def operatorsChunk : String :=
  "def deleteWord : List Argument :=
  [.str Evil.delete.name, .str \"motion\", .str Evil.wordForward.name, .nat 0, .str \"\"]

def setup : SetupM Unit := do
  commandWith \"delete-word\" fun call => do
    Evil.move Evil.motions { call with arguments := [.str Evil.lineStart.name] }
    Evil.operate Evil.operators Evil.motions Evil.objects { call with arguments := deleteWord }
  commandWith \"again\" fun call =>
    Evil.repeat
      { call with
        arguments := [.bool false, .str \"\", .str Vim.operateCommand] ++ deleteWord }
  commandWith \"back\" Evil.undo
"

/-- A chunk with an operator of its own, `erase`, which is the editor's
`delete` under another name, and a `setup` that registers evil's operate
command again, under the name the editor registers it (`Vim.operateCommand`),
over the operators the editor ships and `erase`. `erase-word` runs the
operate command over those tables, from the line's start, with the
arguments the Vim scheme compiles `erase` over `w` to, and `again` hands
evil's repeat command that same change, as the scheme's repeat key would. -/
def ownOperatorChunk : String :=
  "def erase : Vocabulary.Operator :=
  { Evil.delete with name := \"erase\" }

def eraseWord : List Argument :=
  [.str erase.name, .str \"motion\", .str Evil.wordForward.name, .nat 0, .str \"\"]

def setup : SetupM Unit := do
  commandWith Vim.operateCommand
    (Evil.operate (Evil.operators.push erase) Evil.motions Evil.objects)
  commandWith \"erase-word\" fun call => do
    Evil.move Evil.motions { call with arguments := [.str Evil.lineStart.name] }
    Evil.operate (Evil.operators.push erase) Evil.motions Evil.objects
      { call with arguments := eraseWord }
  commandWith \"again\" fun call =>
    Evil.repeat
      { call with
        arguments := [.bool false, .str \"\", .str Vim.operateCommand] ++ eraseWord }
"

/-- The checks of evil from config through the headless host
(`Editor/Headless.lean`), on the real queue, the real text binding and the
real elaborator, with the test scheme: what `Editor.lean` lets config name
of evil (`Editor/Evil.lean`, `Editor/Evil/Motions.lean`,
`Editor/Evil/Operators.lean`, `Editor/Evil/Repeat.lean`,
`Editor/Evil/Undo.lean`). Where a motion leads and what an operator takes
are evil's, pinned by `ModelTest.evilMotionChecks` and
`ModelTest.evilOperatorChecks`, and are not said here. -/
def evilChecks (context : Context) : List Check :=
  [{  name :=
        "config names the vocabulary the editor ships and hands it to evil's move command: a command of config's that moves by a motion of config's own, added to that vocabulary, puts the cursor where that motion says, and one that moves by the name of the vocabulary's first entry runs to its end and says nothing in the echo area, so the entry was found"
      run :=
        withHost context [("10-vocabulary.lean", vocabularyChunk)] fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "hello") do
            return false
          let committed ← session.scene
          session.ask [.run "own"]
          let own ← session.scene
          session.ask [.run "first-shipped"]
          let (echo, _) ← session.scene
          let lines ← session.lines
          return committed == ("".quote, #[viewLine "hello" 5]) &&
              own == ("".quote, #[viewLine "hello" 1]) &&
              echo == "".quote &&
              lines.contains "reload 1: installed, 1 chunks, 2 commands" &&
              lines.contains "run own: ok" &&
              lines.contains "run first-shipped: ok" },
    { name :=
        "config names the operators the editor ships and hands them, with the motions, to evil's operate command: a command of config's that runs it with the arguments of d w from the line's start deletes a word; one that hands the repeat command the same change deletes the next, with the operate command the host was handed as compiled code; and one that runs evil's undo gives that word back"
      run :=
        withHost context [("10-operators.lean", operatorsChunk)]
          (fun session => do
            session.ask [.reload]
            unless ← Event.post (.commit "one two three") do
              return false
            session.ask [.run "delete-word"]
            let deleted ← session.scene
            session.ask [.run "again"]
            let again ← session.scene
            session.ask [.run "back"]
            let back ← session.scene
            let lines ← session.lines
            return deleted == ("".quote, #[viewLine "two three" 0]) &&
                again == ("".quote, #[viewLine "three" 0]) &&
                back == ("".quote, #[viewLine "two three" 0]) &&
                lines.contains "run delete-word: ok" &&
                lines.contains "run again: ok" &&
                lines.contains "run back: ok")
          { commands := Evil.commands } },
    { name :=
        "the repeat command replays a change with the command the registry holds for its name: with config's operate command registered over the operators that ship and one of config's own, in place of the compiled one, a change made with config's operator is replayed with it, and deletes the next word"
      run :=
        withHost context [("10-operators.lean", ownOperatorChunk)]
          (fun session => do
            session.ask [.reload]
            unless ← Event.post (.commit "one two three") do
              return false
            session.ask [.run "erase-word"]
            let erased ← session.scene
            session.ask [.run "again"]
            let again ← session.scene
            let lines ← session.lines
            return erased == ("".quote, #[viewLine "two three" 0]) &&
                again == ("".quote, #[viewLine "three" 0]) &&
                lines.contains "run erase-word: ok" &&
                lines.contains "run again: ok")
          { commands := Evil.commands } }]

/-- The checks of the syntax tree's text objects through a host of the Vim
scheme that ships (`withVimHost`), with the real elaborator, the real text
binding and the library's syntax service: what keys select and delete in a
Rust buffer. Which node an object is, is `Editor/Evil/TreeObjects.lean`'s,
pinned by `ModelTest.treeObjectRuleChecks` and `ModelTest.evilObjectChecks`
and, over the library, by `ContractTest`. -/
def treeObjectChecks (context : Context) : List Check :=
  [{  name :=
        "in a Rust buffer v a f selects the enclosing function, from its fn through its closing brace, through the host's loop and the library's syntax tree; and <Escape> d a f then deletes it, its lines whole"
      run :=
        -- Seen to bite once by hand: with `a-function` taken out of
        -- `Evil.objects`, `v a f` leaves the cursor's one cell selected.
        withVimHost context [("10-objects.lean", rustObjectsChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "rust-buffer"]
          let before := lastViewLine (← session.sceneLines)
          session.typed "v a f"
          let selected := lastViewLine (← session.sceneLines)
          session.typed "<Escape> d a f"
          let deleted := lastViewLine (← session.sceneLines)
          let some fnAt := offsetOf rustObjectsText "fn one" | return false
          let some closing := offsetOf rustObjectsText "}\n}\n" | return false
          let some letAt := offsetOf rustObjectsText "let x" | return false
          -- `d` over a charwise span from a line's indent to the end of a
          -- later line takes the lines whole, Vim's exception for `d`.
          let without := "struct S;\n\nimpl S {\n}\n"
          return (before.splitOn s!"selections {letAt}..{letAt},").length == 2 &&
              (selected.splitOn s!"selections {fnAt}..{closing},").length == 2 &&
              (deleted.splitOn s!"{without.quote}, scroll").length == 2 },
    { name :=
        "in a Rust buffer v i f from a method's fn line, in the function and outside its body, selects inside the body's braces, its lines whole, through the host's loop and the library's syntax tree"
      run :=
        withVimHost context [("10-objects.lean", rustObjectsChunk)] fun session => do
          session.ask [.reload]
          session.ask [.run "rust-buffer"]
          session.typed "k v i f"
          let selected := lastViewLine (← session.sceneLines)
          let some letAt := offsetOf rustObjectsText "        let x" | return false
          let some closing := offsetOf rustObjectsText "\n    }\n}" | return false
          unless (selected.splitOn s!"selections {letAt}..{closing},").length == 2 do
            throw (IO.userError selected)
          return true }]

/-- The rows of the Rust indent fixture (`tests/syntax/rust/indent.rs`) inside
its multi-line string and block comment, which the indent rule keeps: found
by their content, never by their number. -/
def indentKept : List String :=
  ["not indented by the rule\";", "       comment */"]

/-- `source` with the indentation of its rows mangled: a row of `kept`, and
the last, empty after the final line feed, stays as it is; a blank row
becomes three spaces; any other row loses its leading blanks and gains, by
its number, nothing, two spaces, a tab or six spaces. Made in code from the
fixture, so no second fixture can drift from it. -/
def mangledRust (source : String) (kept : List String) : String :=
  let lines := source.splitOn "\n"
  "\n".intercalate <|
    lines.zipIdx.map fun (line, row) =>
      if kept.contains line || row + 1 == lines.length then line
      else
        let content := (line.dropWhile fun char => char == ' ' || char == '\t').toString
        if content.isEmpty then "   " else ["", "  ", "\t", "      "].getD (row % 4) "" ++ content

/-- The byte offset of the first occurrence of `needle` in `text`, or 0 when
it holds none. -/
def cursorAt (text needle : String) : Nat :=
  (offsetOf text needle).getD 0

/-- The texts the indent checks load, each with where the cursor goes and
the language its buffer is set to, if any (`indentChunk`): the mangled Rust
fixture `mangled`, and texts written here. -/
def indentFixtures (mangled : String) : List (String × String × Nat × Option String) :=
  let twoFns :=
    "struct S;\n\nfn one() {\nlet a = 1;\n        a\n}\n\nfn two() {\nlet b = 2;\n        b\n}\n"
  let mid := "fn main() {\n    x();\n}\n"
  let nested := "impl S {\n    fn one(&self) {"
  [("mangled", mangled, 0, some "rust"), ("two-fns", twoFns, cursorAt twoFns "let b", some "rust"),
    ("strings", "fn f() {\nlet s = \"a\n   b\";\n/* c\n     d */\n        s\n}\n", 0, some "rust"),
    ("closed", "fn main() {\n    let x = 1;\n}\n", 0, some "rust"),
    ("eof", "fn main() {", 0, some "rust"),
    ("nested-eof", nested, cursorAt nested "fn one", some "rust"),
    ("mid", mid, cursorAt mid "x()", some "rust"),
    ("method", rustObjectsText, cursorAt rustObjectsText "let x", some "rust"),
    ("method-closing", rustObjectsText, cursorAt rustObjectsText "}\n}\n", some "rust"),
    ("plain", "    ab", 5, none), ("json", "[\n  1\n]", 4, some "json")]

/-- A chunk whose `setup` registers, for each of `indentFixtures mangled`,
the command `load-<name>`: it puts the fixture's text in the scratch
buffer's text, in place of what it held, and the cursor where the fixture
says, and then, for a fixture with a language, records the language and
makes `code` the buffer's major mode, so the text is parsed as the language
says. -/
def indentChunk (mangled : String) : String :=
  let commands :=
    (indentFixtures mangled).map fun (name, text, cursor, language) =>
      let language :=
        match language with
        | some name => s!"(some {name.quote})"
        | none => "none"
      s!"  command {("load-" ++ name).quote} (load {text.quote} {cursor} {language})"
  "def load (contents : String) (cursor : Nat) (language : Option String) : EditorM Unit := do
  let text : TextId := ⟨0⟩
  text.delete 0 (← text.byteLength)
  text.insert 0 contents
  discard <| (⟨0⟩ : ViewId).select { ranges := #[⟨cursor, cursor⟩], shape := .inclusive }
  if let some language := language then
    discard <| (⟨0⟩ : BufferId).setLanguage (some language)
    discard <| (⟨0⟩ : ViewId).setMajorMode \"code\"

def setup : SetupM Unit := do
" ++
    "\n".intercalate commands ++
    "\n"

/-- Runs `check` against a host of the Vim scheme that ships
(`withVimHost`) over `indentChunk` of the mangled Rust indent fixture, with
the config loaded: handed the fixture's text and the mangled one. -/
def withIndentHost (context : Context) (check : Session → String → String → IO Bool) : IO Bool := do
  let source ← IO.FS.readFile (context.syntaxFixtures / "rust" / "indent.rs")
  let mangled := mangledRust source indentKept
  withVimHost context [("10-indent.lean", indentChunk mangled)] fun session => do
      session.ask [.reload]
      check session source mangled

/-- Whether the view line `line` shows the text `text` and one selection
from `anchor` to `head`. -/
def showsText (line text : String) (anchor head : Nat) : Bool :=
  (line.splitOn s!"{text.quote}, scroll").length == 2 &&
    (line.splitOn s!"selections {anchor}..{head},").length == 2

/-- The view line after `load-<name>` and then the keys `keys`. -/
def Session.loadedAndTyped (session : Session) (name keys : String) : IO String := do
  session.ask [.run ("load-" ++ name)]
  session.typed keys
  return lastViewLine (← session.sceneLines)

/-- The checks of `=` and of indented new lines through a host of the Vim
scheme that ships (`withVimHost`), with the real elaborator, the real text
binding and the library's syntax service with Rust's shipped indents query,
each through keys: the acceptance criteria of `=` and of `RET`, `o` and
`O` in a Rust buffer, and in a buffer with no language and one whose
language has no indents query. Which level a row gets is
`Editor/Indent.lean`'s, pinned by `ModelTest`'s indent checks and, over the
library, by `ContractTest`. -/
def indentChecks (context : Context) : List Check :=
  [{  name :=
        "in a Rust buffer whose indentation was mangled, g g = G gives text equal to the rustfmt-formatted fixture it came from, with the cursor on the first row's first non-blank, through the host's loop and the library's syntax tree; the rows inside its multi-line string and block comment, which the rule would indent by four spaces, keep theirs"
      run :=
        withIndentHost context fun session source mangled => do
          let line ← session.loadedAndTyped "mangled" "g g = G"
          let leading (row : String) := (row.takeWhile (· == ' ')).toString
          unless showsText line source 0 0 do
            throw (IO.userError line)
          return mangled != source &&
              indentKept.all (fun row => (source.splitOn ("\n" ++ row ++ "\n")).length == 2) &&
              indentKept.all (leading · != "    ") },
    { name :=
        "= keeps the leading whitespace of a row inside a multi-line string and inside a block comment, and re-indents the rows around them"
      run :=
        withIndentHost context fun session _ _ => do
          let line ← session.loadedAndTyped "strings" "g g = G"
          let indented := "fn f() {\n    let s = \"a\n   b\";\n    /* c\n     d */\n    s\n}\n"
          unless showsText line indented 0 0 do
            throw (IO.userError line)
          return true },
    { name :=
        "in a Rust buffer, = a f inside the second of two mangled functions re-indents exactly that function's rows: the first function and the struct above keep their mangled indentation byte for byte"
      run :=
        withIndentHost context fun session _ _ => do
          let line ← session.loadedAndTyped "two-fns" "= a f"
          let indented :=
            "struct S;\n\nfn one() {\nlet a = 1;\n        a\n}\n\nfn two() {\n    let b = 2;\n    b\n}\n"
          let some at_ := offsetOf indented "fn two" | return false
          unless showsText line indented at_ at_ do
            throw (IO.userError line)
          return true },
    { name :=
        "in a Rust buffer, one = a f is undone by one u, which gives back the whole mangled text, and . then re-indents the other function, leaving the first as u left it"
      run :=
        withIndentHost context fun session _ _ => do
          discard <| session.loadedAndTyped "two-fns" "= a f u"
          let undone := lastViewLine (← session.sceneLines)
          session.typed "g g j j j ."
          let repeated := lastViewLine (← session.sceneLines)
          let mangled :=
            "struct S;\n\nfn one() {\nlet a = 1;\n        a\n}\n\nfn two() {\nlet b = 2;\n        b\n}\n"
          let some letB := offsetOf mangled "let b" | return false
          let indented :=
            "struct S;\n\nfn one() {\n    let a = 1;\n    a\n}\n\nfn two() {\nlet b = 2;\n        b\n}\n"
          let some fnOne := offsetOf indented "fn one" | return false
          unless showsText undone mangled letB letB && showsText repeated indented fnOne fnOne do
            throw (IO.userError s!"{undone} / {repeated}")
          return true },
    { name :=
        "in a Rust buffer, A RET after an opening brace starts the new line one indent unit deeper than the brace's line: above a closing brace, at the text's end with none, and two deep in a method of an impl at the text's end"
      run :=
        withIndentHost context fun session _ _ => do
          let closed ← session.loadedAndTyped "closed" "A RET"
          session.typed "<Escape>"
          let eof ← session.loadedAndTyped "eof" "A RET"
          session.typed "<Escape>"
          let nested ← session.loadedAndTyped "nested-eof" "A RET"
          let closedText := "fn main() {\n    \n    let x = 1;\n}\n"
          let nestedText := "impl S {\n    fn one(&self) {\n        "
          unless
            showsText closed closedText 16 16 && showsText eof "fn main() {\n    " 16 16 &&
              showsText nested nestedText nestedText.utf8ByteSize nestedText.utf8ByteSize do
            throw (IO.userError s!"{closed} / {eof} / {nested}")
          return true },
    { name :=
        "in a Rust function body, o opens a row at the body's level, and typing if a { and RET there starts the next row a level deeper, though the if is not closed"
      run :=
        withIndentHost context fun session _ _ => do
          let line ← session.loadedAndTyped "mid" "o i f SPC a SPC { RET"
          let typed := "fn main() {\n    x();\n    if a {\n        "
          unless showsText line (typed ++ "\n}\n") typed.utf8ByteSize typed.utf8ByteSize do
            throw (IO.userError line)
          return true },
    { name :=
        "in a Rust method's body, o and O on a statement start the new row at the body's level, and O on the method's closing brace does too"
      run :=
        withIndentHost context fun session _ _ => do
          let below ← session.loadedAndTyped "method" "o"
          session.typed "<Escape>"
          let above ← session.loadedAndTyped "method" "O"
          session.typed "<Escape>"
          let closing ← session.loadedAndTyped "method-closing" "O"
          let opened (needle : String) : Option (String × Nat) := do
            let at_ ← offsetOf rustObjectsText needle
            let bar := at_ + needle.utf8ByteSize + 8
            return ((rustObjectsText.take (at_ + needle.length)).toString ++ "        \n" ++
                  (rustObjectsText.drop (at_ + needle.length)).toString,
                bar)
          let some (belowText, belowBar) := opened "let x = 1;\n" | return false
          let some (aboveText, aboveBar) := opened "u8 {\n" | return false
          let some (closingText, closingBar) := opened "        x\n" | return false
          unless
            showsText below belowText belowBar belowBar &&
              showsText above aboveText aboveBar aboveBar &&
              showsText closing closingText closingBar closingBar do
            throw (IO.userError s!"{below} / {above} / {closing}")
          return true },
    { name :=
        "in a buffer with no language = = leaves the text and says the buffer has no syntax tree, and A RET, o and O insert bare line breaks as before; in a JSON buffer, whose language has no indents query, = = says so and A RET inserts a bare line break"
      run :=
        withIndentHost context fun session _ _ => do
          let plain ← session.loadedAndTyped "plain" "= ="
          let (plainEcho, _) ← session.scene
          session.typed "A RET <Escape> o <Escape> O <Escape>"
          let opened := lastViewLine (← session.sceneLines)
          let json ← session.loadedAndTyped "json" "= ="
          let (jsonEcho, _) ← session.scene
          session.typed "A RET"
          let broken := lastViewLine (← session.sceneLines)
          let said (refusal : SyntaxTreeError) :=
            s!"{Vim.operateCommand}: {Evil.cannotIndent refusal}".quote
          unless
            showsText plain "    ab" 5 5 && plainEcho == said .notAttached &&
              (opened.splitOn s!"{"    ab\n\n\n".quote}, scroll").length == 2 &&
              showsText json "[\n  1\n]" 4 4 &&
              jsonEcho == said .noQuery &&
              showsText broken "[\n  1\n\n]" 6 6 do
            throw (IO.userError s!"{plain} {plainEcho} / {opened} / {json} {jsonEcho} / {broken}")
          return true }]

/-- A chunk whose `setup` registers two jobs that each load a file and whose
handler makes a text of what was loaded: `open`, of `note.txt` in
`directory`, and `missing`, of a file that is not there. A load that is
refused is thrown, as the refusal's description. -/
def openChunk (directory : System.FilePath) : String :=
  "def openFile (path : String) : Unit → JobM JobSnapshotId := fun _ => do
  match ← File.load path 1000 with
  | .ok file => return file.snapshot
  | .error error => throw error.describe

def setup : SetupM Unit := do
  job \"open\" (openFile " ++
    (directory / "note.txt").toString.quote ++
    ") fun loaded => discard loaded.toText
  job \"missing\" (openFile " ++
    (directory / "missing.txt").toString.quote ++
    ") fun loaded => discard loaded.toText
"

/-- A stage for a host whose jobs reach real files: one over the real
elaborator and `source`, with what `compiled` hands it, whose services have
the library's file service, its diff service and its watch service, as the
executable wires them, over the table of waits the file checks share
(`Context.fileWaits`), which the one completion pump runs over. Its clock is
still a fake one: the watch service coalesces on the library's own. -/
def Stage.overFiles (context : Context) (source : Config.Source) (compiled : Compiled := {}) :
    IO (Stage Config.Elaborate.State) := do
  let completions ← context.fileWaits
  let stage ← Stage.new context context.elaborator source compiled (some completions)
  let collaborators := stage.collaborators
  let refusedDiffs ← Job.RefusedDiffs.new
  let watches ← Job.RealWatches.new
  return { stage with
      collaborators :=
        { collaborators with
          services :=
            { collaborators.services with
              fileWatches := Job.realFileWatches completions watches
              files := Job.realFiles completions collaborators.published.reader collaborators.held
              diffs :=
                Job.realDiffs completions collaborators.published.reader collaborators.held
                  refusedDiffs } } }

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

/-- Runs the command called `name` through the host and waits for the jobs
it started: whether the wait settled. -/
def Session.ran (session : Session) (name : String) : IO Bool := do
  session.ask [.run name]
  return (← session.host.join patience) == .settled

/-- Asks the host for the scene, and returns the echo area's text, quoted as
the scene line has it, and every line it printed after the scene's: each
view's line, followed by its status line. -/
def Session.viewsAndStatus (session : Session) : IO (String × Array String) := do
  let before := (← session.output.get).size
  let (echo, _) ← session.scene
  return (echo, (← session.output.get).extract (before + 1))

/-- The stamp of the file at `path`, as the file system has it: when it was
last modified, and how long it is. -/
def stampOf (path : System.FilePath) : IO File.Stamp := do
  let metadata ← path.metadata
  return {
      seconds := metadata.modified.sec, nanoseconds := metadata.modified.nsec.toNat
      size := metadata.byteSize.toNat }

/-- The text of the file `note.txt` of the file checks: two lines, with
two-byte characters. -/
def noteText : String :=
  "héllo\nwörld\n"

/-- The status line of view 0 on `noteText` opened from `path`, called
`note.txt`, its cursor on the first row at `column`: two rows, the empty one
after the final line break not counted (`statusOf`). -/
def noteStatus (path : System.FilePath) (modified : Bool := false) (column : Nat := 0)
    (changed : Bool := false) : String :=
  statusOf (name := "note.txt") (modified := modified) (cursor := ⟨0, column⟩) (lines := 2) (file :=
    some path) (changed := changed)

/-- A chunk whose `setup` registers `language-report`, which says in the
echo area the language and the major mode of the buffer the focused window
shows, each `none` when it has none (`rust code`, `none none`), and then
runs `more`, lines of a `do` block indented by two spaces. -/
def languageReportChunk (more : String := "") : String :=
  "def report : EditorM Unit := do
  let state ← editorState
  match state.target? state.frame.focused with
  | some target =>
    message (target.buffer.language.getD \"none\" ++ \" \" ++ target.buffer.major.getD \"none\")
  | none => message \"no window\"

def setup : SetupM Unit := do
  command \"language-report\" report
" ++
    more

/-- Lines of a `setup` that define a language `rust` over the shipped one,
whose highlights query is its own, `(identifier) @variable`. -/
def rustOverride : String :=
  "  defineLanguage
    { Language.rust with
      syntaxTree := { Language.rust.syntaxTree with highlights := some \"(identifier) @variable\" } }
"

/-- Runs `check` against a host over the library's file service
(`Stage.overFiles`), with a config directory of its own holding
`languageReportChunk` with `more` lines of its `setup`, that is handed the file commands and
their jobs, the minibuffer's commands and its mode, the `code` mode and the
languages that ship (`Language.modes`, `Language.shipped`), as the
executable is, and, for each name and path of `opens`, a command of that
name that opens that path (`opening`). Its syntax tree is the real binding
with every request recorded in the array `check` is handed
(`recordingSyntaxTree`). The config is loaded before `check` runs. Stops the
host: `false` if the check did not hold or the host did not stop. -/
def withLanguageHost (context : Context) (more : String) (opens : List (String × System.FilePath))
    (check : Session → IO.Ref (Array String) → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeFiles directory [("10-report.lean", languageReportChunk more)]
    let asked ← IO.mkRef #[]
    let stage ←
      Stage.overFiles context (Config.Directory.source directory)
          { commands :=
              Files.commands ++ Minibuffer.commands ++
                (opens.map fun (name, path) => opening name path).toArray
            jobs := Files.jobs
            modes := Minibuffer.modes ++ Language.modes
            languages := Language.shipped }
    onStage
        { stage with
          collaborators := { stage.collaborators with syntaxTree := recordingSyntaxTree asked } }
        fun host stage => do
        let session : Session :=
          { host, directory, output := stage.output, threads := stage.threads, clock := stage.clock,
            watches := stage.watches, log := stage.log }
        session.ask [.reload]
        check session asked

/-- What the host's `language-report` says of the focused buffer once the
command `name` has opened its file: its language and its major mode,
quoted as the scene line has the echo area, or none when the open's jobs
did not settle. -/
def reportedAfter (session : Session) (name : String) : IO (Option String) := do
  unless ← session.ran name do
    return none
  session.ask [.run "language-report"]
  return some (← session.scene).1

/-- Whether no line of the host's scene says a highlights refusal. -/
def noHighlightsRefusal (session : Session) : IO Bool := do
  return (← session.sceneLines).all fun line => (line.splitOn "highlights:").length == 1

/-- The requests the entry of a buffer's mode makes of the syntax tree
port before its injections, for a language parsed with `grammar` and
highlighted with the grammar's shipped query, its captures mapped by
`captures` over the shipped default, as `recordedRequest` writes them. -/
def shippedHighlightRequests (grammar : String) (captures : List (String × Option FaceName) := []) :
    IO (Array String) :=
  return #["refreshAfter 500", s!"attach {grammar}", s!"shippedQuery {grammar} highlights",
      s!"compile {grammar}", "captureNames", ← shippedFaces grammar captures, "release"]

/-- The checks of a file's language through the headless host
(`Editor/Files.lean`, "Open"; `Editor/Language.lean`): the file commands
and the languages that ship as compiled code registers them, on real files,
with the real elaborator and the real syntax binding. They share the file
checks' table of waits (`Stage.overFiles`). -/
def languageChecks (context : Context) : List Check :=
  [{  name :=
        "opening a .rs file gives its buffer the language rust and the major mode code, and its text is attached with rust and highlighted with Rust's shipped query in the default faces, with no refusal said"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "main.rs"
          IO.FS.writeFile path "fn main() {\n    let x = 1;\n}\n"
          withLanguageHost context "" [("open-rs", path)] fun session asked => do
              let report ← reportedAfter session "open-rs"
              let requests ← asked.get
              return report == some "rust code".quote &&
                  requests.extract 0 7 == (← shippedHighlightRequests "rust") &&
                  (← noHighlightsRefusal session) },
    { name :=
        "opening a .json file and a .md file gives each buffer that language and the major mode code, and highlights its text with that grammar's shipped query; Markdown's inline grammar is injected"
      run :=
        IO.FS.withTempDir fun files => do
          let json := files / "data.json"
          let markdown := files / "notes.md"
          IO.FS.writeFile json "{\"a\": [1, true]}\n"
          IO.FS.writeFile markdown "# Title\n\nSome *text* here.\n"
          let jsonHeld ←
            withLanguageHost context "" [("open-json", json)] fun session asked => do
                let report ← reportedAfter session "open-json"
                return report == some "json code".quote &&
                    (← asked.get).extract 0 7 == (← shippedHighlightRequests "json") &&
                    (← noHighlightsRefusal session)
          let markdownHeld ←
            withLanguageHost context "" [("open-md", markdown)] fun session asked => do
                let report ← reportedAfter session "open-md"
                let requests ← asked.get
                return report == some "markdown code".quote &&
                    requests.extract 0 7 == (← shippedHighlightRequests "markdown") &&
                    requests.contains "injectLanguage markdown_inline" &&
                    (← noHighlightsRefusal session)
          return jsonHeld && markdownHeld },
    { name :=
        "opening a .toml file and a file named Cargo.lock gives each buffer the language toml and the major mode code, and highlights its text with TOML's shipped query, keys and table headers in the type face, strings in the string face, brackets in the punctuation face and booleans in the constant face, with no refusal said"
      run :=
        IO.FS.withTempDir fun files => do
          let toml := files / "mise.toml"
          let lock := files / "Cargo.lock"
          IO.FS.writeFile toml "[tools]\nrust = \"1.91\"\nenabled = true\n"
          IO.FS.writeFile lock "version = 4\n\n[[package]]\nname = \"cc\"\n"
          let expected ← shippedHighlightRequests "toml" Language.toml.syntaxTree.captures
          let faces := ((expected[5]?.getD "").replace "highlight " "").splitOn ", "
          let drawn :=
            ["syntax.type", "syntax.string", "syntax.punctuation", "syntax.operator",
                  "syntax.constant"].all
              faces.contains
          let opened (name : String) (path : System.FilePath) : IO Bool :=
            withLanguageHost context "" [(name, path)] fun session asked => do
              let report ← reportedAfter session name
              return report == some "toml code".quote && (← asked.get).extract 0 7 == expected &&
                  (← noHighlightsRefusal session)
          return drawn && (← opened "open-toml" toml) && (← opened "open-lock" lock) },
    { name :=
        "opening a file whose name matches no language gives its buffer no language and no major mode, and asks the syntax tree port nothing"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "notes.txt"
          IO.FS.writeFile path "plain\n"
          withLanguageHost context "" [("open-txt", path)] fun session asked => do
              let report ← reportedAfter session "open-txt"
              return report == some "none none".quote && (← asked.get).isEmpty },
    { name :=
        "a major mode with no syntax tree set over the code mode of an opened .rs file detaches its text"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "main.rs"
          IO.FS.writeFile path "fn main() {\n    let x = 1;\n}\n"
          let plain :=
            "  defineMode { name := \"plain\" }
  command \"to-plain\" (do discard <| (← editorState).frame.focused.setMajorMode \"plain\")
"
          withLanguageHost context plain [("open-rs", path)] fun session asked => do
              unless (← reportedAfter session "open-rs") == some "rust code".quote do
                return false
              let opened := (← asked.get).size
              session.ask [.run "to-plain", .run "language-report"]
              let report := (← session.scene).1
              let requests ← asked.get
              return report == "rust plain".quote &&
                  (requests.extract opened requests.size).contains "detach" },
    { name :=
        "config's language rust, over the shipped one, with its own highlights query, is the one an opened .rs file is highlighted with: its query is compiled in place of the shipped one, and its one capture drawn in its default face"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "main.rs"
          IO.FS.writeFile path "fn main() {\n    let x = 1;\n}\n"
          withLanguageHost context rustOverride [("open-rs", path)] fun session asked => do
              let report ← reportedAfter session "open-rs"
              let requests ← asked.get
              return report == some "rust code".quote &&
                  requests.extract 0 6 ==
                    #["refreshAfter 500", "attach rust", "compile rust", "captureNames",
                      "highlight syntax.variable", "release"] &&
                  !requests.contains "shippedQuery rust highlights" &&
                  (← noHighlightsRefusal session) }]

/-- The checks of files through the headless host (`Editor/Headless.lean`),
with the real elaborator, the real queue, the real text binding and the
library's file service: the checks of this executable whose hosts are over a
real service. They share one table of waits and one completion pump over it
(`Context.fileWaits`, `Stage.overFiles`), started by the first of them. No
other check of the gated run starts a pump, so none takes these checks'
completions.

The first is a job from config. The others are the file commands and their
jobs as compiled code registers them (`Editor/Files/Compiled.lean`), on real
files: each check writes its files' bytes itself, in a temporary directory
it makes, and hands its host the paths (`withFileHost`). -/
def fileChecks (context : Context) : List Check :=
  [{
      name :=
        "a job loads a file through the host and its handler makes a text of it, with its two-byte character: the job's line says ok, show prints the text, and the library then holds no snapshot more than before but the one of the loop's scene; a job whose file is not there fails with the refusal's description",
      run :=
        IO.FS.withTempDir fun files =>
          IO.FS.withTempDir fun config => do
            IO.FS.writeBinFile (files / "note.txt") "héllo\n".toUTF8
            writeFiles config [("10-open.lean", openChunk files)]
            let stage ← Stage.overFiles context (Config.Directory.source config)
            let snapshots ← Ffi.Snapshot.live
            let host ← Headless.start stage.collaborators
            try
              let ask (requests : List Headless.Request) : IO Unit := do
                for request in requests do
                  host.send request
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              ask [.reload]
              ask [.spawn "open"]
              let opened ← host.join patience
              ask [.spawn "missing"]
              let missed ← host.join patience
              ask [.show]
              -- The loop delivered the job's command, so it has a frame: the
              -- one snapshot more is the one its scene holds of the scratch
              -- buffer's text, which is text 0.
              let freed ← eventually (return (← Ffi.Snapshot.live) == snapshots + 1)
              let stopped ← host.stop patience
              return opened == .settled && missed == .settled && freed && stopped &&
                  (← stage.collaborators.held.size) == 0 &&
                  (← stage.output.get) ==
                    #["reload 1: installed, 1 chunks, 0 commands", "spawn open: job 1",
                      "job 1 open: ok", "spawn missing: job 2",
                      "job 2 missing: failed: nothing is at the path", "commands:", "text 0: \"\"",
                      "text 1: \"héllo\\n\""]
            catch error =>
              discard <| host.halt patience
              throw error },
    { name :=
        "the open command on a file in a temporary directory: the host says the load job started and ended, and the focused view shows a buffer whose text is the file's, with its cursor at the start, and whose status line is the file's base name alone"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              let joined ← session.ran "open-note"
              let (echo, lines) ← session.viewsAndStatus
              return joined &&
                  (← session.output.get).extract 0 3 ==
                    #["run open-note: ok", s!"job 1 {Files.loadJob}: started",
                      s!"job 1 {Files.loadJob}: ok"] &&
                  echo == "".quote &&
                  lines == #[viewLine noteText 0, noteStatus path] },
    { name :=
        "the save command on a modified buffer: after a commit the view's status line has the modified field, and once the save job has ended the file's bytes are the buffer's text, the echo area says the file was written, and the status line has the name alone"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              unless ← Event.post (.commit "x") do
                return false
              -- The commit was the buffer's first edit, which starts a check
              -- of its file: its lines are printed before the scene is asked.
              unless (← session.host.join patience) == .settled do
                return false
              let (_, edited) ← session.viewsAndStatus
              let saved ← session.ran Files.saveName
              let (echo, lines) ← session.viewsAndStatus
              return saved &&
                  edited ==
                    #[viewLine ("x" ++ noteText) 1,
                      noteStatus path (modified := true) (column := 1)] &&
                  endedOk (← session.output.get) Files.saveJob &&
                  (← IO.FS.readBinFile path) == ("x" ++ noteText).toUTF8 &&
                  echo == (Files.wrote path).quote &&
                  lines == #[viewLine ("x" ++ noteText) 1, noteStatus path (column := 1)] },
    { name :=
        "opening a path that is open starts no second load and makes no second text: the open command a second time prints its own line alone, and show lists the texts it listed before"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              let shown ← session.shown
              let before := (← session.output.get).size
              let again ← session.ran "open-note"
              let printed := (← session.output.get).extract before
              let (_, lines) ← session.viewsAndStatus
              return again && printed == #["run open-note: ok"] && (← session.shown) == shown &&
                  (shown.filter (·.startsWith "text ")).size == 2 &&
                  lines == #[viewLine noteText 0, noteStatus path] },
    { name :=
        "open then save with no edit writes the file and leaves its bytes as they were, for a file whose lines end in line feeds and one whose lines end in CRLF: each save job ends ok, the echo area says the file was written, and the bytes read back are the bytes the check wrote"
      run :=
        IO.FS.withTempDir fun files => do
          let cases : List (String × System.FilePath × ByteArray × Nat) :=
            [("open-lf", files / "lf.txt", "one\ntwo\n".toUTF8, 2),
              ("open-crlf", files / "crlf.txt", "one\r\ntwo\r\n".toUTF8, 4)]
          for (_, path, bytes, _) in cases do
            IO.FS.writeBinFile path bytes
          withFileHost context (cases.map fun (name, path, _, _) => (name, path)) fun session => do
              let mut held := true
              for (name, path, bytes, job) in cases do
                let opened ← session.ran name
                let saved ← session.ran Files.saveName
                let (echo, _) ← session.viewsAndStatus
                held :=
                  held && opened && saved && echo == (Files.wrote path).quote &&
                    (← session.output.get).contains s!"job {job} {Files.saveJob}: ok" &&
                    (← IO.FS.readBinFile path) == bytes
              return held },
    { name :=
        "a save of a buffer whose file changed on disk after it was loaded leaves the file as it is: the file's bytes are the ones written behind the editor, the view's status line still has the modified field, and the echo area says the changed-on-disk refusal with the stamp the file now has"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              -- Another length, so the change is seen whatever the file
              -- system's clock.
              let other := "another program wrote this, at another length\n".toUTF8
              IO.FS.writeBinFile path other
              let found ← stampOf path
              unless ← Event.post (.commit "x") do
                return false
              let saved ← session.ran Files.saveName
              let (echo, lines) ← session.viewsAndStatus
              -- The commit was the buffer's first edit, which starts a check:
              -- it finds the file changed, so the status line has the
              -- changed field too.
              return saved && (← IO.FS.readBinFile path) == other &&
                  lines ==
                    #[viewLine ("x" ++ noteText) 1,
                      noteStatus path (modified := true) (column := 1) (changed := true)] &&
                  echo == (Files.notSaved path (.changed (some found))).quote },
    { name :=
        "the open command on a path with no file: the echo area says the refusal, and the focused view still shows the buffer it showed, with its text, its cursor and its name"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "missing.txt"
          withFileHost context [("open-missing", path)] fun session => do
              unless ← Event.post (.commit "kept") do
                return false
              let joined ← session.ran "open-missing"
              let (echo, lines) ← session.viewsAndStatus
              return joined && (← session.output.get).contains s!"job 1 {Files.loadJob}: ok" &&
                  echo == (Files.notOpened path .notFound).quote &&
                  lines == #[viewLine "kept" 4, statusOf (modified := true) (cursor := ⟨0, 4⟩)] },
    { name :=
        "the open command with no path asks for one and opens the answer: run by its name, with the path of a file in a temporary directory committed into the minibuffer and the accept key pressed, the host says the load job started and ended, the prompt is closed, and the view the command was asked from shows the file's text in a buffer called by its base name"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          withFileHost context [] fun session => do
              session.ask [.run Files.openName]
              unless ← Event.post (.commit path.toString) do
                return false
              let asking ← session.sceneLines
              session.pressKeys acceptKeys
              let joined := (← session.host.join patience) == .settled
              let (echo, lines) ← session.viewsAndStatus
              let output ← session.output.get
              return joined && !acceptKeys.isEmpty &&
                  asking.extract 1 ==
                    #[viewLine "" 0, statusOf,
                      minibufferLine path.toString path.toString.utf8ByteSize,
                      promptStatus Files.openPrompt] &&
                  output.contains s!"run {Files.openName}: ok" &&
                  output.filter (·.startsWith "job ") ==
                    #[s!"job 1 {Files.loadJob}: started", s!"job 1 {Files.loadJob}: ok"] &&
                  echo == "".quote &&
                  lines == #[viewLine noteText 0, noteStatus path] }]

/-- A compiled command called `name`, written for the reload checks, that
puts the cursor of the window it is called with at the byte `offset`, in the
shape the window's selection has. -/
def placing (name : String) (offset : Nat) : Config.Registration :=
  { name
    action :=
      .call fun call => do
        let current ← call.target.selection
        call.target.select
            { current with
              ranges := #[⟨offset, offset⟩], primary := 0 } }

/-- The checks of reloading a buffer from its file (`Files.reload`,
`Editor/Files.lean`) through the headless host, on real files, with the
library's file and diff services. -/
def reloadChecks (context : Context) : List Check :=
  [{  name :=
        "criterion 1: a file rewritten behind its buffer is reloaded by e: the reload job ends ok, show prints the new text, the scene's view shows it with the cursor on the same character of the unchanged second row, and the status line has neither the modified field nor any other"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          let (old, new) := ("one\ntwo\nthree\n", "one, and more\ntwo\nthree\n")
          IO.FS.writeBinFile path old.toUTF8
          withFileHost context [("open-note", path)] (extra := #[placing "cursor" 6]) fun session =>
              do
              unless ← session.ran "open-note" do
                return false
              -- Row 1, column 2: the "o" of "two".
              session.ask [.run "cursor"]
              let (_, placed) ← session.viewsAndStatus
              IO.FS.writeBinFile path new.toUTF8
              let reloaded ← session.ran Files.editName
              let (echo, lines) ← session.viewsAndStatus
              session.ask [.show]
              let output ← session.output.get
              -- The first line grew by ten bytes, so the "o" is at 16: on
              -- row 1, column 2, of three rows, before and after.
              let status :=
                statusOf (name := "note.txt") (cursor := ⟨1, 2⟩) (lines := 3) (file := some path)
              return reloaded && placed == #[viewLine old 6, status] &&
                  output.contains s!"job 2 {Files.reloadJob}: ok" &&
                  output.contains s!"text 1: {new.quote}" &&
                  echo == "".quote &&
                  lines == #[viewLine new 16, status] }]

/-- Rewrites the file at `path` with `text` from another process, as agents
and editors write: a temporary file beside it, renamed over it. Waits for
the process to exit; whether it exited with 0. -/
def rewriteFromOutside (path : System.FilePath) (text : String) : IO Bool := do
  let child ←
    IO.Process.output
        { cmd := "/bin/sh"
          args :=
            #["-c", "printf '%s' \"$2\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"", "sh", path.toString,
              text] }
  return child.exitCode == 0

/-- Polls the scene every 10 ms, with `settle` and no fixed sleep as the
assertion, until `done` holds of its view and status lines or `bound`
milliseconds have passed: how long it took, and the lines it last saw. -/
def Session.within (session : Session) (bound : Nat) (done : Array String → Bool) :
    IO (Option Nat × Array String) := do
  let start ← IO.monoMsNow
  let mut lines := #[]
  repeat
    let (_, seen) ← session.viewsAndStatus
    lines := seen
    let took := (← IO.monoMsNow) - start
    if done seen then
      return (some took, lines)
    if took > bound then
      break
    IO.sleep 10
  return (none, lines)

/-- The checks of auto-reload through the headless host on real files, with
the library's watch service (`Editor/Loop.lean`, "Auto-reload"): criteria 9
and 10. Measured on 2026-11-16 on macOS (FSEvents), over six runs: the
rewrite was shown 66 to 83 ms after the other process exited, a median of
about 80 ms, and the edited buffer marked in 78 to 84 ms; the 50 ms
coalescing window is most of it. The bound is a second, and every wait is
polled, never a fixed sleep. -/
def autoReloadChecks (context : Context) : List Check :=
  [{  name :=
        "criteria 9 and 10 on real files: with auto-reload on, another process's rewrite of an unmodified buffer's file is shown within a second; once the buffer is edited, another rewrite leaves its text and marks its status line within a second"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          let (old, new, again) := ("one\ntwo\n", "one\ntwo\nthree\n", "rewritten again\n")
          IO.FS.writeBinFile path old.toUTF8
          withFileHost context [("open-note", path)] fun session => do
              unless ← session.ran "open-note" do
                return false
              -- With no argument the command toggles: off, so on.
              session.ask [.run Files.autoReloadName]
              let armed ←
                eventually do
                    return (← session.output.get).any fun line =>
                        line.startsWith "job " && line.endsWith s!" {Files.followJob}: started"
              unless armed do
                return false
              unless ← rewriteFromOutside path new do
                return false
              let (shown, saw) ← session.within 1000 (·.contains (viewLine new 0))
              unless shown.isSome do
                throw (IO.userError s!"the rewrite was not shown within a second: {saw}")
              unless ← Event.post (.commit "x") do
                return false
              unless ← rewriteFromOutside path again do
                return false
              let edited := "x" ++ new
              let (marked, last) ←
                session.within 1000 fun lines =>
                    lines ==
                      #[viewLine edited 1,
                        statusOf (name := "note.txt") (modified := true) (cursor := ⟨0, 1⟩)
                          (lines := 3) (file := some path) (changed := true)]
              unless marked.isSome do
                throw (IO.userError s!"the edited buffer was not marked within a second: {last}")
              return (← IO.FS.readBinFile path) == again.toUTF8 }]

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

/-- A config of one chunk whose `setup` is `body`, a line of Lean. -/
def faceChunk (body : String) : String :=
  s!"def setup : SetupM Unit := do\n  {body}\n"

/-- The checks that a face set in config reaches the frame: a config
directory of real files, the real elaborator, a host whose reloads re-theme
its display, the display's real binding and the library's layout. What a
face looks like in
a frame is layout's rule, so a frame is compared with another frame: the
one a second display, which the check makes itself, lays out of the same
scene in a theme written here. That display is handed the same themes in
the same order, since a frame's text names fonts by the ids its shaper gave
them. No colour, size or frame text is written here. -/
def faceChecks (context : Context) : List Check :=
  [{
      name :=
        "changing a face in config and reloading changes the next frame, to the frame the built-in theme followed by config's definition gives: a colour, then a size; a rejected reload leaves the frame as it was; and a config that sets no face gives the built-in theme's frame",
      run :=
        IO.FS.withTempDir fun directory => do
          let write (body : String) : IO Unit :=
            writeFiles directory [("10-faces.lean", faceChunk body)]
          let over (attributes : Face) : Theme :=
            Theme.builtin ++ #[{ name := ⟨"default"⟩, face := attributes }]
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The host's display: the real binding over the library's layout
          -- in cells 8 by 16, which the check keeps to read its frame and the
          -- scene the host last published.
          let library ← Ffi.Display.newCells 8 16
          let made ← IO.mkRef (none : Option Headless.Host.Display)
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                let display ←
                  Headless.Host.Display.real (← RealDisplay.over library snapshots Theme.builtin)
                made.set (some display)
                return display }
          -- The second display, over the same table of snapshots, handed the
          -- themes the host's is handed, in the same order.
          let mirror ←
            RealDisplay.over (← Ffi.Display.newCells 8 16) collaborators.published.reader
                Theme.builtin
          onStage { stage with collaborators } fun host _ => do
              -- Names the first of `parts` that does not hold.
              let holds (parts : List (String × Bool)) : IO Unit := do
                if let some (part, _) := parts.find? (!·.2) then
                  throw (IO.userError part)
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              -- The host's frame of the last scene it published, and the
              -- second display's frame of that scene, in `theme` when it is
              -- given and in the theme it last had otherwise.
              let frames (theme : Option Theme) : IO (String × String) := do
                let some display ← made.get | throw (IO.userError "the host made no display")
                let some scene ← display.last? | throw (IO.userError "the host published no scene")
                if let some theme := theme then
                  mirror.setTheme theme
                mirror.publish scene
                return (← library.frameText, ← mirror.display.frameText)
              let reload : IO Unit := do
                host.send .reload
                settled
              -- The frame is made, with a view of some size and a text in
              -- it, in the built-in theme.
              host.resize 160 96
              unless ← Event.post (.commit "let x = 1") do
                return false
              settled
              let (plain, plainMirror) ← frames none
              holds [("the first frame is the built-in theme's", plain == plainMirror)]
              -- (a) A face set in config is in the first frame after the reload.
              write "face \"default\" { foreground := some (Color.rgb 200 0 0) }"
              reload
              let (red, redMirror) ← frames (over { foreground := some (Color.rgb 200 0 0) })
              holds
                  [("(a) the frame after the reload differs", red != plain),
                    ("(a) and is the one config's face gives", red == redMirror)]
              -- (b), (c) Changed in the file and reloaded, it changes the frame,
              -- to the one the changed face gives.
              write "face \"default\" { foreground := some (Color.rgb 0 200 0) }"
              reload
              let (green, greenMirror) ← frames (over { foreground := some (Color.rgb 0 200 0) })
              holds
                  [("(b) the frame after a changed colour differs", green != red),
                    ("(c) and is the one the changed face gives", green == greenMirror)]
              -- (d) An attribute that changes shaping.
              write "face \"default\" { size := some 32 }"
              reload
              let (large, largeMirror) ← frames (over { size := some 32 })
              holds
                  [("(d) the frame after a changed size differs", large != green),
                    ("(d) and is the one the size gives", large == largeMirror)]
              -- (e) A chunk that does not elaborate: rejected, and no face moved.
              write "face \"default\" { size := some 8 }\n\ndef broken : Nat := \"not a number\""
              reload
              -- Its error is in the echo area now, so the scene is not the one
              -- before; its frame is the one that scene gives in the faces
              -- before.
              let (kept, keptMirror) ← frames none
              holds
                  [("(e) after a rejected reload the frame is the one the faces before give",
                      kept == keptMirror)]
              -- (f) A config that sets no face: the built-in theme again.
              write "pure ()"
              reload
              let (unset, unsetMirror) ← frames Theme.builtin
              let lines ← stage.output.get
              holds
                  [("(f) its frame is the built-in theme's", unset == unsetMirror),
                    ("(f) which is not the frame before", unset != large),
                    ("every reload but (e) installed and (e) was rejected",
                      (lines.filter (·.startsWith "reload ")).map (·.endsWith "rejected") ==
                        #[false, false, false, true, false])]
              return true },
    {
      name :=
        "a real config that sets the frame padding to 12 installs, and the next scene's views are padded 12 and the library's frame draws its rows 12 in; rewritten to 0 and reloaded in the same host, with no restart, the views are padded 0 and no row is drawn in from the view's edge",
      run :=
        IO.FS.withTempDir fun directory => do
          let write (points : Nat) : IO Unit :=
            writeFiles directory [("10-padding.lean", faceChunk s!"framePadding {points}")]
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The host's display: the real binding over the library's layout in
          -- cells 8 by 16, at scale 1, which the check keeps to read its frame
          -- and the scene the host last published.
          let library ← Ffi.Display.newCells 8 16
          let made ← IO.mkRef (none : Option Headless.Host.Display)
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                let display ←
                  Headless.Host.Display.real (← RealDisplay.over library snapshots Theme.builtin)
                made.set (some display)
                return display }
          onStage { stage with collaborators } fun host _ => do
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              let reload : IO Unit := do
                host.send .reload
                settled
              -- The paddings of the views of the last scene, and the frame.
              let shown : IO (Array Padding × String) := do
                let some display ← made.get | throw (IO.userError "the host made no display")
                let some scene ← display.last? | throw (IO.userError "the host published no scene")
                return (scene.views.map (·.padding), ← library.frameText)
              write 12
              host.resize 160 96
              unless ← Event.post (.commit "let x = 1") do
                return false
              reload
              let (twelve, padded) ← shown
              write 0
              reload
              let (zero, plain) ← shown
              let lines ← stage.output.get
              return twelve == #[{ across := 12, down := 12 }] &&
                  (padded.splitOn "  row x 12 y 12 ").length > 1 &&
                  zero == #[{}] &&
                  (plain.splitOn "  row x ").length == 1 &&
                  (lines.filter (·.startsWith "reload ")).all (·.endsWith "commands") },
    {
      name :=
        "a reload that makes mode-line taller sizes the scene published after it by the new heights: agree, asked with no event between the reload and it, says the last rows query about the focused view gave the rows of the frame, as it did before the reload",
      run :=
        IO.FS.withTempDir fun directory => do
          -- `top` puts the cursor at the text's start, so that no follow
          -- scrolls the view: `agree` compares rows from one anchor.
          let top : Config.Registration :=
            { name := "top"
              action :=
                .call fun call => call.target.select { ranges := #[⟨0, 0⟩], shape := .exclusive } }
          let stage ←
            Stage.new context context.elaborator (Config.Directory.source directory)
                { commands := #[top] }
          -- The host's display: the real binding over the library's layout
          -- in cells 8 by 16, in the built-in theme.
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                Headless.Host.Display.real
                    (← RealDisplay.over (← Ffi.Display.newCells 8 16) snapshots Theme.builtin) }
          onStage { stage with collaborators } fun host _ => do
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              -- What `agree` says now.
              let agreement : IO String := do
                host.send .agree
                settled
                return (← stage.output.get).back?.getD ""
              -- A view of some rows, over a text of more lines than it shows.
              host.resize 160 96
              let text := "\n".intercalate ((List.range 20).map toString)
              unless ← Event.post (.commit text) do
                return false
              host.send (.run "top")
              settled
              let before ← agreement
              writeFiles directory
                  [("10-faces.lean", faceChunk "face \"mode-line\" { size := some 32 }")]
              host.send .reload
              settled
              let after ← agreement
              let lines ← stage.output.get
              if !(before.endsWith ": agrees" && after.endsWith ": agrees") then
                throw (IO.userError s!"before the reload: {before}; after it: {after}")
              return lines.any (·.startsWith "reload 1: installed") }]

/-- The themes whose cursors `cursorResolutionChecks` lay out, each with
what it is called in a failure: every shipped theme, and two built-in themes
whose `cursor.normal` is redefined to set one colour alone, a background or
a foreground, so the other falls through to the default face's. -/
def resolutionThemes : Array (String × Theme) :=
  let alone (face : Face) : Theme :=
    (Theme.builtin.filter (·.name != ⟨"cursor.normal"⟩)).push { name := ⟨"cursor.normal"⟩, face }
  Themes.shipped.map (fun named => (named.name, named.theme)) ++
    #[("a background alone", alone { background := some (Color.rgb 200 0 0) }),
      ("a foreground alone", alone { foreground := some (Color.rgb 0 200 0) })]

/-- The contract check of the completeness check's model of a cursor's
colours (`Themes.effective`, `Editor/Themes/Check.lean`) against the real
layout. For each theme of `resolutionThemes` and each cursor face the check
holds (`Themes.cursorFaces`), a scene of one view whose block cursor is in
that face is laid out through the display's real binding twice: in the theme
as written, and in a mirror of it whose last definition sets that face's
foreground and background to the colours the model says it has. The two
frames must be equal, and a mirror with the two colours the other way round
must give another frame, so the cursor's paint is in the frame compared. No
frame text is read: what a frame says is layout's. -/
def cursorResolutionChecks (_ : Unit) : List Check :=
  [{
      name :=
        "the completeness check's colours of each cursor face, in every shipped theme and in themes whose cursor sets one colour alone, are the ones the real layout paints it in",
      run := do
        let document ← Ffi.Document.new "ab\ncd"
        let .ok selection ←
          document.mark
              (.selection
                {
                  ranges :=
                    #[{ anchor := 0,
                        head := 0 }] }) | throw (IO.userError "the cursor's marker was refused")
        let .ok top ←
          document.mark
              (.anchor
                { offset := 0,
                  bias := .before }) | throw (IO.userError "the scroll marker was refused")
        let table ← Snapshots.new
        let snapshot ← table.add (← document.snapshot)
        let scene (face : FaceName) : Scene :=
          { size := { width := 64, height := 64 }
            views :=
              #[{ id := ⟨1⟩, rect := { x := 0, y := 0, width := 64, height := 48 }, snapshot
                  scroll := { text := ⟨0⟩, index := top.toNat }
                  selections := #[{ text := ⟨0⟩, index := selection.toNat }]
                  cursor := { shape := .block, face }, decorations := #[], status := #[] }]
            focused := some ⟨1⟩, echo := "", pending := "", preedit := none }
        -- The frame text of `scene face` laid out in `theme`, by a display
        -- of its own.
        let frame (theme : Theme) (face : FaceName) : IO String := do
          let real ← RealDisplay.over (← Ffi.Display.newCells 8 16) table.reader theme
          real.publish (scene face)
          real.display.frameText
        let mut failed : Array String := #[]
        for (called, theme) in resolutionThemes do
          for face in Themes.cursorFaces do
            let (foreground, background) := Themes.effective theme face
            let mirror (foreground background : Option Color) : Theme :=
              theme.push { name := face, face := { foreground, background } }
            let written ← frame theme face
            let modelled ← frame (mirror foreground background) face
            let swapped ← frame (mirror background foreground) face
            unless
              foreground.isSome && background.isSome && written == modelled && written != swapped do
              failed := failed.push s!"{called}: {face.name}"
        -- The document is held until here, past the last publish.
        discard document.read
        if !failed.isEmpty then
          throw (IO.userError s!"the model is not layout's for {failed}")
        return true }]

/-- What compiled code hands the hosts of the theme checks: the command that
loads a theme and the themes that ship (`Editor/Themes/Compiled.lean`), and
the minibuffer's commands and its mode, which its prompt is answered with. -/
def themeCompiled : Compiled :=
  { commands := Themes.commands ++ Minibuffer.commands, modes := Minibuffer.modes
    themes := Themes.shipped }

/-- The face `default` of the theme `second` the theme checks' config
defines: a background of its own. -/
def secondDefault : Face :=
  { background := some (Color.rgb 0 90 0) }

/-- The face `keyword` the theme checks' config sets. -/
def keywordFace : Face :=
  { foreground := some (Color.rgb 200 0 0) }

/-- The checks of named themes through a host: a config directory of real
files, the real elaborator, the display's real binding and the library's
layout. As in `faceChecks`, a frame is compared with the frame a second
display, handed the same themes in the same order, lays out of the same
scene in a theme written here. -/
def themeChecks (context : Context) : List Check :=
  [{  name :=
        "criteria 3 and 4: the theme command switches the theme the display draws in with no reload, to the frame the chosen theme followed by config's own face gives, and the scene line names the theme it was drawn in"
      run :=
        IO.FS.withTempDir fun directory => do
          writeFiles directory
              [("10-themes.lean",
                  "def setup : SetupM Unit := do\n  defineTheme \"second\" #[{ name := ⟨\"default\"⟩, face := { background := some (Color.rgb 0 90 0) } }]\n  face \"keyword\" { foreground := some (Color.rgb 200 0 0) }\n")]
          let configured : Theme := #[{ name := ⟨"keyword"⟩, face := keywordFace }]
          let stage ←
            Stage.new context context.elaborator (Config.Directory.source directory) themeCompiled
          let library ← Ffi.Display.newCells 8 16
          let made ← IO.mkRef (none : Option Headless.Host.Display)
          let collaborators :=
            { stage.collaborators with
              display := fun snapshots => do
                let display ←
                  Headless.Host.Display.real (← RealDisplay.over library snapshots Theme.builtin)
                made.set (some display)
                return display }
          let mirror ←
            RealDisplay.over (← Ffi.Display.newCells 8 16) collaborators.published.reader
                Theme.builtin
          onStage { stage with collaborators } fun host _ => do
              let holds (parts : List (String × Bool)) : IO Unit := do
                if let some (part, _) := parts.find? (!·.2) then
                  throw (IO.userError part)
              let settled : IO Unit := do
                unless ← host.settle patience do
                  throw (IO.userError "the editor thread did not settle")
              let frames (theme : Theme) : IO (String × String) := do
                let some display ← made.get | throw (IO.userError "the host made no display")
                let some scene ← display.last? | throw (IO.userError "the host published no scene")
                mirror.setTheme theme
                mirror.publish scene
                return (← library.frameText, ← mirror.display.frameText)
              let sceneLine : IO String := do
                host.send .scene
                settled
                return ((← stage.output.get).filter (·.startsWith "scene ")).back?.getD ""
              host.send .reload
              settled
              host.resize 160 96
              unless ← Event.post (.commit "let x = 1") do
                return false
              settled
              let (plain, plainMirror) ← frames (Theme.builtin ++ configured)
              let before ← sceneLine
              host.send (.run Themes.loadName)
              settled
              unless ← Event.post (.commit "second") do
                return false
              for key in acceptKeys do
                host.press key
              settled
              let (switched, switchedMirror) ←
                frames (#[{ name := ⟨"default"⟩, face := secondDefault }] ++ configured)
              let after ← sceneLine
              let lines ← stage.output.get
              holds
                  [("the frame after the reload is the default theme's with config's face",
                      plain == plainMirror),
                    ("the frame after the switch differs", switched != plain),
                    ("and is the one the second theme with config's face gives",
                      switched == switchedMirror),
                    (s!"the scene before names the default theme: {before}",
                      before.endsWith ", theme \"default\""),
                    (s!"the scene after names the second theme: {after}",
                      after.endsWith ", theme \"second\""),
                    ("there was one reload",
                      (lines.filter (·.startsWith "reload ")) ==
                        #["reload 1: installed, 1 chunks, 0 commands"])]
              return true },
    { name :=
        "criterion 6: a config that names a theme nobody registered says so in the echo area, naming the theme, before the frame is made and after, and its report says so; the theme in force stays"
      run :=
        withHost context
          [("10-themes.lean", "def setup : SetupM Unit := do\n  useTheme \"nope\"\n")] (compiled :=
          themeCompiled) fun session => do
          session.ask [.reload]
          session.host.resize 80 64
          session.ask []
          let made ← session.echo
          session.ask [.say "cleared"]
          let cleared ← session.echo
          session.ask [.reload]
          let again ← session.echo
          let lines ← session.lines
          let said := "reload: no theme is registered as `nope`".quote
          let scene := (lines.filter (·.startsWith "scene ")).back?.getD ""
          return made == said && cleared == "cleared".quote && again == said &&
              (lines.filter (· == "theme: no theme is registered as `nope`")).size == 2 &&
              scene.endsWith ", theme \"default\"" }]

/-- The checks of what the executable's hosts are handed as compiled code
(`Headless.shippedOver`, which `Headless.shipped` makes them with), on the
registry a host starts with (`Headless.compiled`) and the test scheme's
keymap of its bindings. Its services are a fake clock's over a table of
waits of its own, which no pump reads: nothing here starts a job. -/
def shippedChecks (_ : Unit) : List Check :=
  [{  name :=
        "the executable's hosts start with the code mode and the languages rust, json, markdown and toml, in that order, registered for the owner compiled"
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
              #[("rust", true), ("json", true), ("markdown", true), ("toml", true)] },
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
        "the executable's hosts start with compile, recompile, compile-confirm, kill-compilation and compilation-output, the job compile-run and the mode compilation registered for the owner compiled, and the ex names compile, which takes text, recompile and kill-compilation bound to them"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let shipped :=
          Headless.shippedOver "" "" "" (fun _ => pure ()) { completions, timers := clock.timers }
            (← Snapshots.new) (← Job.HeldSnapshots.new)
        let registry := Headless.compiled shipped
        let compiled (name : String) : Bool := (registry.find? name).any (·.owner == .compiled)
        return [Compile.compileName, Compile.recompileName, Compile.confirmName, Compile.killName,
                  Compile.outputName].all
              compiled &&
            (registry.findJob? Compile.runJob).any (·.owner == .compiled) &&
            (registry.mode? Compile.modeName).isSome &&
            (registry.mode? Minibuffer.mode.name).isSome &&
            registry.ex? "compile" ==
              some { name := "compile", command := Compile.compileName, takes := .text } &&
            (registry.ex? "recompile").map (·.command) == some Compile.recompileName &&
            (registry.ex? "kill-compilation").map (·.command) == some Compile.killName },
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

/-- Every check, in the order they run. -/
def checks (context : Context) : List Check :=
  elaboratorChecks context ++ directoryChecks () ++ hostChecks context ++ threadChecks context ++
    jobChecks context ++
    treeObjectChecks context ++
    indentChecks context ++
    watchReloadChecks context ++
    agreementChecks () ++
    shippedChecks () ++
    scriptChecks context ++
    dispatchChecks context ++
    hostLoopChecks context ++
    modeChecks context ++
    promptChecks context ++
    exChecks context ++
    evilChecks context ++
    reloadEchoChecks context ++
    faceChecks context ++
    cursorResolutionChecks () ++
    themeChecks context ++
    environmentHostChecks context ++
    fileChecks context ++
    languageChecks context ++
    reloadChecks context ++
    autoReloadChecks context ++
    exScriptChecks context

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
def run (sysroot oleanDir : String) (syntaxFixtures : System.FilePath) : IO UInt8 := do
  let real :=
    Config.Elaborate.elaborator { sysroot, oleanDir, imports := #[`Editor, `ConfigFixture] }
  -- Compiled code writes to the fixture's cell before the base is imported.
  let bumped ← ConfigFixture.bump
  let base ← real.base
  let context : Context :=
    { elaborator := { real with base := pure base }, base, bumped, ids := ← IO.mkRef 100
      waits := ← IO.mkRef none, syntaxFixtures }
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
    Headless.start (scheme := TestScheme.scheme)
        { elaborator, source := { chunks := chunks.get }, emit,
          services := { completions, timers := clock.timers }, published := ← Snapshots.new,
          held := ← Job.HeldSnapshots.new, requests := 1, wakeups := 2, jobs := 3, environment := 4,
          posts := 5 }
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

/-- `bench-modules`: imports the base with `modules` and prints the name of
every module the import read, one a line and unescaped, so that
`tools/stage-bundle.sh --closure` can map each to its files. -/
def modules (sysroot oleanDir : String) (modules : List String) : IO UInt8 := do
  let environment ←
    Config.Elaborate.importBase
        { sysroot, oleanDir, imports := (modules.map String.toName).toArray }
  for name in environment.allImportedModuleNames do
    IO.println (name.toString (escape := false))
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
    let requests ← ids.modifyGet fun next => (next, next + 5)
    reloads.set #[]
    let host ←
      Headless.start (scheme := TestScheme.scheme)
          { elaborator, source := { chunks := pure jobsConfig }, emit,
            services := { completions, timers := counted }, published := ← Snapshots.new,
            held := ← Job.HeldSnapshots.new, requests, wakeups := requests + 1,
            jobs := requests + 2, environment := requests + 3, posts := requests + 4 }
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
      "usage: config-test <sysroot> <olean dir> <syntax fixtures> | config-test bench-start <sysroot> <olean dir> <module>... | config-test bench-modules <sysroot> <olean dir> <module>... | config-test bench-reload <sysroot> <olean dir> | config-test bench-soak <sysroot> <olean dir> <count> | config-test bench-jobs <sysroot> <olean dir> <samples>"
  return 2

end ConfigTest

/-- `config-test <sysroot> <olean dir> <syntax fixtures>` runs the checks:
exits 0 when all hold, and 1 after naming the ones that do not. The third
argument is the directory of the syntax fixtures (`tests/syntax`), which the
indent checks read.

`bench-start`, `bench-reload` and `bench-soak` are the benchmark
(`ConfigTest.Bench`; `mise run config-bench`), which the gate never runs.
`bench-modules` lists the modules an import set reads, for
`mise run module-bench` and the gate's `bundle-test`.
`bench-jobs` is the job benchmark (`ConfigTest.Bench.jobs`;
`mise run job-bench`), which the gate never runs either.

Any other command line is reported, with the exit status 2.

It exits explicitly: a failed check may have left a task parked in the
library, and a benchmark leaves its host's loop running; returning from
`main` would wait for either for ever. -/
def main (args : List String) : IO UInt32 := do
  match args with
  | "bench-start" :: sysroot :: oleanDir :: module :: modules =>
    IO.Process.exit (← ConfigTest.Bench.start sysroot oleanDir (module :: modules))
  | "bench-modules" :: sysroot :: oleanDir :: module :: modules =>
    IO.Process.exit (← ConfigTest.Bench.modules sysroot oleanDir (module :: modules))
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
  | [sysroot, oleanDir, syntaxFixtures] =>
    IO.Process.exit (← ConfigTest.run sysroot oleanDir syntaxFixtures)
  | _ =>
    ConfigTest.usage
