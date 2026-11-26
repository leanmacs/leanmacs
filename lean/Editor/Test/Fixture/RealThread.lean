import Editor.RealHost
import Editor.Test.Fixture.Fixture

/-!
# The headless fixture harness: the real-thread set

The fixtures that keep running the CLI, `editor headless`, over a real loop
thread (row A3 of `docs/dev-practices/real-thread-checks.md`), declared
once: `entries`. Every other fixture of the three groups (`tests/headless`,
`tests/packages/*/tests/headless`, each package's `tests/headless`) runs on
the stepped host with the fakes by default, with nothing declared
(`docs/dev-practices/headless-mode.md`, "How the gate runs a fixture").

Each entry is keyed by its script's path from the repository's root, says
what it covers, names the gate step that runs it through the CLI (`site`),
and says why it is here (`Subject`):

- `runner`: the subject is the script runner over a real loop thread
  itself. The fixture has no real effect, so it is run both ways: the CLI
  over a real loop thread, and the harness stepped, and the two outputs
  are compared (`case_compare` in `tools/wiring-runs.sh`, through
  `fixture-test … compare`).
  A runner entry is always stepped too.
- `realEffect what`: the subject is a real effect, `what`: a process exec'd,
  a directory written, a real state directory read by the next process, a
  build's records beside an installed executable. Its CLI run covers it;
  `stepped` says whether the harness also runs it stepped, which it does
  only where the stepped output is its expected file too.

The harness acts on the value itself (`Editor/Test/Fixture/Stepped.lean`):
a discovered fixture whose entry is not stepped is skipped, its line naming
its site and what it covers; an entry under a root the run was handed that
names no discovered script fails the run; a script that aborts or waits for
a restart is refused stepped unless it has an entry. Model-test holds the
data well formed (`ModelTest/Editor/Test/Fixture/RealThread.lean`).

This module is of the wiring set (`wiringSet.Editor.Test.Fixture.RealThread`,
`docs/dev-practices/real-thread-checks.md`), so every CLI fixture run over
a real loop thread is found here: the CLI's runs happen in gate steps,
which a Lean linter cannot see. It references no mark. Pure: it imports
nothing that reaches `Lean` or the library; its declaration is plain data
(`Editor/RealHost.lean`).
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.Editor.Test.Fixture.RealThread : Editor.WiringSet :=
  .wiring "the headless CLI, editor headless, over a real loop thread"
    "the CLI runs in gate steps, which a Lean linter cannot see; the harness refuses stepped a script that has no entry and fails on a stale entry"

namespace Editor.Test.Fixture.RealThread

/-- Why a fixture keeps its CLI run over a real loop thread. -/
inductive Subject where
  /-- The script runner over a real loop thread is the subject: the fixture
  is run both ways and compared. -/
  | runner
  /-- A real effect is the subject: what it is. -/
  | realEffect (what : String)
  deriving DecidableEq, Repr

/-- An entry of the real-thread set. -/
structure Entry where
  /-- The fixture's script, from the repository's root. -/
  script : String
  /-- What its CLI run covers. -/
  covers : String
  /-- The gate step that runs it through the CLI. -/
  site : String
  /-- Why it is here. -/
  subject : Subject
  /-- Whether the harness also runs it stepped: always for a `runner`. -/
  stepped : Bool
  deriving DecidableEq, Repr

/-- A runner entry: stepped, and compared both ways in ffi-test. -/
def runner (script covers : String) : Entry :=
  { script, covers,
    site :=
      "ffi-test: wiring-runs.sh compare (the CLI over a real loop thread, compared with the stepped run by fixture-test compare)"
    subject := .runner, stepped := true }

/-- A real-effect entry of a fixture of `tests/headless` that runs only
through the CLI. -/
def cliOnly (script what site : String) : Entry :=
  { script, covers := what, site, subject := .realEffect what, stepped := false }

/-- The restore fixtures' entry: the journal and the index on a real state
directory. -/
def restore (script covers : String) : Entry :=
  cliOnly s!"tests/headless/restore/{script}" covers
    "ffi-test: the six restore lines (--state on a temporary directory, an abort's status 134, a second process)"

/-- The restart fixtures' entry: the exec of the next process. -/
def restart (script covers : String) : Entry :=
  cliOnly s!"tests/headless/restart/{script}" covers
    "ffi-test: the five restart lines (the launcher leanmacs, a probe of a real program, the exec)"

/-- The real-thread set: every fixture of the three groups that a `ci` task
runs through the CLI. -/
def entries : Array Entry :=
  #[runner "tests/headless/script"
      "the runner's reload, settle, run, show, spawn, advance and join over a real loop thread (A3)",
    runner "tests/headless/keys-script"
      "keys through the library's window input into a real loop (Host.press), against the memory queue's (A3)",
    runner "tests/headless/scene-script"
      "commit, the frame's first scene and the published count over a real loop thread, so the stepped scene count is the real one (A3)",
    runner "tests/headless/ex/script"
      "a command (q) that ends the real loop, the runner stopping at the wait that answered ended, and status 0 (A3)",
    { script := "tests/headless/bundle/script"
      covers :=
        "the staged bundle's and the app's editor finding the modules of its base from its own path"
      site := "bundle-test (tools/bundle-test.sh) and app-check (tools/app-check.sh)"
      subject :=
        .realEffect "the staged bundle's and the app's editor finding its modules from its own path"
      stepped := true },
    cliOnly "tests/headless/dispatch/script"
      "A4: the library's interrupt flag, raised as C-g arrives while spin runs; a stepped host tells the library no interrupt key"
      "ffi-test: the dispatch line",
    cliOnly "tests/headless/generate/script"
      "--generate writes lean-toolchain and lakefile.toml into the config directory"
      "ffi-test (tools/config-package-check.sh), bundle-test (tools/bundle-test.sh) and app-check (tools/app-check.sh)",
    cliOnly "tests/headless/milestone/script"
      "--render: the library's render loop, the CPU renderer and the real display binding (agree, idle, journal)"
      "ffi-test: the milestone line",
    cliOnly "tests/headless/open-file/script"
      "the open prompt over a real tree under /tmp, its last file, todo.md, in a mode attached to a grammar of the library's syntax service, which the syntax tree's model does not hold (it knows json alone), so a stepped run says the attach refused where the CLI's says nothing"
      "ffi-test: the open-file line",
    cliOnly "tests/headless/needs-rebuild/script"
      "the editor's records of its own set beside the executable (runningAt), on two sets' editors (expected, installed-expected)"
      "ffi-test: the two needs-rebuild lines",
    cliOnly "tests/headless/no-input-scheme/script"
      "the empty set's editor refusing to start before any host is made"
      "ffi-test: the no-input-scheme lines",
    restart "script"
      "the exec of the next process through the launcher and directly, the session handed over and restored",
    restart "probe-script" "a probe of a real program that fails, so no restart is handed over",
    restart "fallback-script"
      "the launcher's watcher starting its fallback when the next process ends before it restored the session",
    restore "abort-script"
      "the journal on a real state directory surviving an aborted process (status 134)",
    restore "restore-script" "the next process restoring the session an aborted one journalled",
    restore "changed-script" "a file changed on disk after an abort, restored beside the journal",
    restore "quit-script" "a quit's session ended in its index, and no journal left",
    restore "newer-script" "a state directory of a newer format left as it is, byte for byte",
    restore "layout-script" "the layout of the frame journalled before an abort",
    restore "layout-restore-script"
      "the layout restored by the next process, in the index's format 2",
    restore "stores-script" "the stores of a workspace journalled before an abort",
    restore "stores-restore-script" "the stores restored by the next process",
    { script := "packages/shipped-themes/tests/headless/shipped-themes/script"
      covers := "the staged bundle's editor loading the shipped themes from its own modules"
      site := "bundle-test (tools/bundle-test.sh)"
      subject := .realEffect "the staged bundle's editor", stepped := true },
    { script := "packages/shipped-themes/tests/headless/package-names/script"
      covers := "the staged bundle's editor naming the packages of its own set"
      site := "bundle-test (tools/bundle-test.sh)"
      subject := .realEffect "the staged bundle's editor", stepped := true },
    { script := "packages/compile/tests/headless/config/script"
      covers := "the staged bundle's editor running the compile mode's config"
      site := "bundle-test (tools/bundle-test.sh)"
      subject := .realEffect "the staged bundle's editor", stepped := true },
    { script := "tests/packages/greeting/tests/headless/hello/script"
      covers :=
        "a per-user install of the fixture set built with no .olean (:editorInstall), and the default set's editor answering no such command"
      site := "ffi-test: the editorInstall line and the default set's greeting-hello line"
      subject :=
        .realEffect
          "a per-user install of the fixture set built with no .olean (:editorInstall), and the default set's editor answering no such command"
      stepped := true }]

/-- The entry of `script`, if it has one. -/
def entry? (script : String) : Option Entry :=
  entries.find? (·.script == script)

/-- What is wrong with the set as data: an entry named twice, a runner
entry not stepped, a real effect that does not say what, an entry with no
`covers` or no `site`. Empty when it is well formed. -/
def problems (set : Array Entry := entries) : Array String :=
  Id.run do
    let mut found := #[]
    for index in [0:set.size] do
      let some entry := set[index]? | continue
      if (set.toList.take index).any (·.script == entry.script) then
        found := found.push s!"{entry.script} is named twice"
      if entry.covers.isEmpty then
        found := found.push s!"{entry.script} says nothing it covers"
      if entry.site.isEmpty then
        found := found.push s!"{entry.script} names no site"
      match entry.subject with
      | .runner =>
        unless entry.stepped do
          found := found.push s!"{entry.script} is a runner entry that is not stepped"
      | .realEffect what =>
        if what.isEmpty then
          found := found.push s!"{entry.script} is a real effect that does not say what"
    return found

/-- The entries of `set` whose site begins with `prefix_`, or all of them
with none, each as `<script>\t<site>`, in the set's order: what
`fixture-test real-thread [--site <prefix>]` prints. -/
def listed (prefix_ : Option String) (set : Array Entry := entries) : Array String :=
  (set.filter fun entry => prefix_.all (entry.site.startsWith ·)).map fun entry =>
    s!"{entry.script}\t{entry.site}"

/-- The runner entries, which ffi-test runs both ways and compares. -/
def compared : Array Entry :=
  entries.filter (·.subject == .runner)

end Editor.Test.Fixture.RealThread
