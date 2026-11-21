import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Syntax
import Editor.Api
import Editor.Appearance
import Editor.Clipboard.InProcess
import Editor.Command
import Editor.Command.Call
import Editor.Completion
import Editor.Completion.Display
import Editor.Completion.Style
import Editor.Config.Diagnostic
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Owner
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Config.Reload
import Editor.Config.Session
import Editor.Config.Stores
import Editor.Display
import Editor.DisplayRules
import Editor.Event
import Editor.Event.Queue
import Editor.Evil.Compiled
import Editor.Ex
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Counter
import Editor.Ffi.Events
import Editor.Ffi.Interrupt
import Editor.File
import Editor.FileWatch
import Editor.FrameCommands.Compiled
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Runner
import Editor.Job.Table
import Editor.Keymap
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Menu.Compiled
import Editor.Mode
import Editor.ModeLine
import Editor.Package
import Editor.Process.Environment
import Editor.Program
import Editor.ProjectMode
import Editor.ProjectMode.Listing
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.TabCommands
import Editor.TabCommands.Compiled
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Text
import Editor.Text.Model
import Editor.Text.Real
import Editor.Themes
import Editor.Themes.Compiled
import Editor.Watch
import Editor.Window
import Editor.WindowCommands.Compiled
import Editor.Workspace
import EditorCore.EditorPackage
import FilesApiTest.Fake

/-!
# Config tests: `Editor/Headless.lean`

The tests of `Editor/Headless.lean`: `hostChecks`, `threadChecks` (with `Gate`),
`jobChecks`, `agreementChecks`, `scriptChecks`, `hostLoopChecks`,
`exScriptChecks`, `reloadEchoChecks`, `shippedChecks`, `watchReloadChecks`,
`environmentHostChecks`, `restoreOrderChecks` and `journalFailureChecks`. The
root module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- Runs `check` against a host started over `elaborator` and `source`, with
its output in a buffer `check` is handed, and stops the host. `false` if the
check did not hold or the host did not stop. -/
def hosted {β σ : Type} (context : Context) (elaborator : Config.Elaborator β σ)
    (source : Config.Source) (check : Headless.Host → IO.Ref (Array String) → IO Bool) : IO Bool :=
  staged context elaborator source fun host stage => check host stage.output

/-- A config whose `setup` registers `greet`. -/
def setupText : String :=
  "def setup : SetupM Unit := do\n  command \"greet\" greet\n"

/-- The root of a config whose `greet` is in the config file
`Config/Greet.lean`: it imports that file, and goes on with `body`. -/
def overGreet (body : String) : String :=
  importing ["Config.Greet"] body

/-- A config of two files: `Config/Greet.lean`, whose `greet` makes a text
holding "v1", and the root, which imports it and whose `setup` registers
it. -/
def greetConfig : List (String × String) :=
  [("Config/Greet.lean", greetText "v1"), ("init.lean", overGreet setupText)]

/-- A config that defines the command `greet`, which says `hello` in the echo
area. -/
def helloText : String :=
  "def greet : EditorM Unit := message \"hello\"\n"

/-- A config of two files: `Config/Greet.lean`, whose `greet` says `hello`,
and the root, which imports it and whose `setup` registers it. -/
def helloConfig : List (String × String) :=
  [("Config/Greet.lean", helloText), ("init.lean", overGreet setupText)]

/-- A config with a store of one number at version 1, and a `setup` that
declares it and registers `bump`, which adds `step` to it. -/
def counterText (step : Nat) : String :=
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

/-- `counterText 1` with its store's version raised to 2 and no migration, so
the value written at version 1 is lost, and with a theorem left unproved,
which Lean warns about. -/
def unmigratedCounterText : String :=
  (counterText 1).replace "version := 1" "version := 2" ++ "\ntheorem unproved : 1 = 1 := sorry\n"

/-- A config with a store of one number and two commands over it: `bump`, which
adds one, and `broken`, which makes a text, then inserts into a text that
does not exist, which the library refuses, and would add a hundred. -/
def refusedText : String :=
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

/-- A config with three commands: `drop`, which makes three texts and releases
the second; `inside`, which makes a text and asks for the point of an offset
inside its two-byte character, which the library refuses; and `stale`, which
reads a snapshot that does not exist, which the library refuses too. -/
def releasingText : String :=
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

/-- A config with two commands, each of which applies a transaction the
library refuses: `short`, whose changes stop one byte short of its text, and
`astray`, whose selection after the changes has an end inside the text's
two-byte character. -/
def transactionText : String :=
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

/-- A config with two commands, each of which asks a text's log about a
revision the library refuses: `ahead`, which asks what changed since a
revision its text has not reached, and `behind`, which forgets its text's
first edit and then asks what changed since before it. -/
def logText : String :=
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

/-- A config with two commands that mark a text: `kept`, which marks its text
with an anchor, edits before it and reads it back where it went, and `lost`,
which gives its marker up and then asks for it. -/
def markerText : String :=
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

/-- A config with three commands that take an edit back: `undone`, which
applies the inverse of its edit and reads the text as it was made, at one
more revision; `dropped`, which drops that inverse and then asks for it; and
`elsewhere`, which asks for the inverse of an edit after it made another. -/
def inverseText : String :=
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

/-- The store of `counterText` with its type changed and its version raised
to 2: the number gets a label, and a number written at version 1 is migrated
with the label \"migrated\". -/
def labelledCounterText : String :=
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
         session.write "Config/Greet.lean" (greetText "v2")
         session.ask [.reload]
         session.ask [.run "greet", .show]
         return (← session.lines) ==
             #["reload 1: installed, 2 files, 1 commands", "run greet: ok", "commands: greet",
               "text 0: \"\"", "text 1: \"v1\"", "reload 2: installed, 2 files, 1 commands",
               "run greet: ok", "commands: greet", "text 0: \"\"", "text 1: \"v1\"",
               "text 2: \"v2\""] },
    { name :=
        "a host handed no packages starts with an empty registry and no menu bar: no command, job, binding, mode, ex name, theme, segment, language, contribution, source, style, display, at-point source or use, no style default, no store, no menu and no extension, and nothing is logged"
      run := do
        let stage ← Stage.new context context.elaborator (Config.Directory.source "no-config")
        let collaborators := { stage.collaborators with packages := #[] }
        let running ← Headless.Running.new collaborators
        let registry := running.config.registry
        return registry.ownersByKind.size == 19 && registry.ownersByKind.all (·.isEmpty) &&
            registry.styleDefaults.isEmpty &&
            registry.menuBar? == none &&
            (Headless.Running.keys collaborators running 0).menu == none &&
            running.config.packages.isEmpty &&
            running.config.cells.cells.isEmpty &&
            (← stage.log.get).isEmpty },
    { name :=
        "a host hands each package it refuses to its log, prefixed with package, and registers the others: of two packages of one name the second is refused, and the host starts with the first's command and the third's"
      run := do
        let saying (name said : String) : Package :=
          { name, setup := Editor.command said (message said) }
        let stage ← Stage.new context context.elaborator (Config.Directory.source "no-config")
        let collaborators :=
          { stage.collaborators with
            packages := #[saying "one" "first", saying "one" "again", saying "two" "third"] }
        let running ← Headless.Running.new collaborators
        return running.config.registry.names == #["first", "third"] &&
            running.config.packages == #["one", "two"] &&
            (← stage.log.get) == #[s!"package: {Package.namedTwice "one"}"] },
    { name := "a type error keeps the old config"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.write "Config/Greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.lines) ==
              #["reload 1: installed, 2 files, 1 commands", "reload 2: rejected",
                "diagnostic: Config/Greet.lean: error", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"v1\""] },
    { name := "a throwing setup keeps the old config"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.write "init.lean"
              (overGreet
                "def setup : SetupM Unit := do\n  command \"other\" greet\n  throw \"no thanks\"\n")
          session.ask [.reload]
          session.ask [.run "other", .show]
          -- The message is the one config threw, so the whole line is ours.
          return (← session.output.get) ==
              #["reload 1: installed, 2 files, 1 commands", "reload 2: rejected",
                "diagnostic: setup:0:0: error: no thanks", "run other: no such command",
                "commands: greet", "text 0: \"\""] },
    { name :=
        "a setup that registers a command name twice keeps the old config, and the diagnostic names the command"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.write "init.lean"
              (overGreet
                "def setup : SetupM Unit := do\n  command \"greet\" greet\n  command \"greet\" greet\n")
          session.ask [.reload]
          session.ask [.run "greet", .show]
          -- The message is the editor's own, so the whole line is pinned.
          return (← session.output.get) ==
              #["reload 1: installed, 2 files, 1 commands", "reload 2: rejected",
                "diagnostic: setup:0:0: error: the command `greet` is registered twice",
                "run greet: ok", "commands: greet", "text 0: \"\"", "text 1: \"v1\""] },
    { name := "a reload does not double-register"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          session.ask [.reload]
          session.write "Config/Greet.lean" (greetText "v1" ++ "\n-- changed\n")
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.lines) ==
              #["reload 1: installed, 2 files, 1 commands",
                "reload 2: installed, 2 files, 1 commands",
                "reload 3: installed, 2 files, 1 commands", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"v1\""] },
    { name := "a store value survives a reload"
      run :=
        withHost context [("init.lean", counterText 1)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump", .run "bump", .show]
          session.write "init.lean" (counterText 10)
          session.ask [.reload]
          session.ask [.show, .run "bump", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 1 commands", "run bump: ok", "run bump: ok",
                "commands: bump", "text 0: \"\"", "store counter v1: 2",
                "reload 2: installed, 1 files, 1 commands", "commands: bump", "text 0: \"\"",
                "store counter v1: 2", "run bump: ok", "commands: bump", "text 0: \"\"",
                "store counter v1: 12"] },
    { name := "a store migrates when a reload changes its type and raises its version"
      run :=
        withHost context [("init.lean", counterText 1)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump", .run "bump"]
          session.write "init.lean" labelledCounterText
          session.ask [.reload]
          session.ask [.show, .run "bump", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 1 commands", "run bump: ok", "run bump: ok",
                "reload 2: installed, 1 files, 1 commands", "commands: bump", "text 0: \"\"",
                "store counter v2: {n: 2, label: \"migrated\"}", "run bump: ok", "commands: bump",
                "text 0: \"\"", "store counter v2: {n: 3, label: \"migrated\"}"] },
    { name :=
        "a reload that installs prints the config's warnings, then a warning for the store value it lost"
      run :=
        withHost context [("init.lean", counterText 1)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump"]
          session.write "init.lean" unmigratedCounterText
          session.ask [.reload]
          session.ask [.show]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 1 commands", "run bump: ok",
                "reload 2: installed, 1 files, 1 commands", "diagnostic: init.lean: warning",
                "diagnostic: store counter: warning", "commands: bump", "text 0: \"\"",
                "store counter v2: 0"] },
    { name := "a config that declares initialize keeps the old config"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          -- No command of this config reads the constant, so a host that
          -- wrongly installed it would fail this check, not abort.
          session.write "Config/State.lean" "initialize table : IO.Ref Nat ← IO.mkRef 0\n"
          session.write "init.lean" (importing ["Config.Greet", "Config.State"] setupText)
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.lines) ==
              #["reload 1: installed, 2 files, 1 commands", "reload 2: rejected",
                "diagnostic: Config/State.lean: error", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"v1\""] },
    { name :=
        "a store command the library refuses is reported as refused: the store keeps its value, and the text the command made before the refusal stays"
      run :=
        withHost context [("init.lean", refusedText)] fun session => do
          session.ask [.reload]
          session.ask [.run "bump", .run "broken", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 2 commands", "run bump: ok",
                "run broken: refused: no such text", "commands: bump broken", "text 0: \"\"",
                "text 1: \"made before the refusal\"", "store counter v1: 1"] },
    { name :=
        "show lists no text a command released, and the texts made before and after it keep the index they were made with"
      run :=
        withHost context [("init.lean", releasingText)] fun session => do
          session.ask [.reload]
          session.ask [.run "drop", .show]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 3 commands", "run drop: ok",
                "commands: drop inside stale", "text 0: \"\"", "text 1: \"before\"",
                "text 3: \"after\""] },
    { name :=
        "a command refused for an offset that is no position, and one refused for a snapshot that does not exist, are each reported with that refusal's name"
      run :=
        withHost context [("init.lean", releasingText)] fun session => do
          session.ask [.reload]
          session.ask [.run "inside", .run "stale"]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 3 commands", "run inside: refused: bad position",
                "run stale: refused: no such snapshot"] },
    { name :=
        "a command whose transaction's changes do not fit, and one whose transaction's selection does not, are each reported with that refusal's name"
      run :=
        withHost context [("init.lean", transactionText)] fun session => do
          session.ask [.reload]
          session.ask [.run "short", .run "astray"]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 2 commands", "run short: refused: bad change",
                "run astray: refused: bad selection"] },
    { name :=
        "a command that asks a text's log about a revision it has not reached, and one that asks about a revision it has forgotten, are each reported with that refusal's name"
      run :=
        withHost context [("init.lean", logText)] fun session => do
          session.ask [.reload]
          session.ask [.run "ahead", .run "behind"]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 2 commands", "run ahead: refused: unknown revision",
                "run behind: refused: forgotten revision"] },
    { name :=
        "a command that marks a text reads its marker back where an edit moved it, and one that asks for a marker it gave up is reported with that refusal's name"
      run :=
        withHost context [("init.lean", markerText)] fun session => do
          session.ask [.reload]
          session.ask [.run "kept", .run "lost"]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 2 commands", "run kept: ok",
                "run lost: refused: no such marker"] },
    { name :=
        "a command that applies the inverse of its edit reads the text as it was, and one that asks for an inverse it dropped, and one whose text is not where the edit left it, are each reported with that refusal's name"
      run :=
        withHost context [("init.lean", inverseText)] fun session => do
          session.ask [.reload]
          session.ask [.run "undone", .run "dropped", .run "elsewhere"]
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 3 commands", "run undone: ok",
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
        "a config file that is not UTF-8 is a rejected reload whose one diagnostic line, at the import of it, names the file, and the old config stays"
      run :=
        withHost context greetConfig fun session => do
          session.ask [.reload]
          IO.FS.writeBinFile (session.directory / "Config" / "Bad.lean") notUtf8
          session.write "init.lean" (importing ["Config.Greet", "Config.Bad"] setupText)
          session.ask [.reload]
          session.ask [.run "greet"]
          let lines ← session.output.get
          let diagnostic := lines.getD 2 ""
          return lines.size == 4 && lines.getD 0 "" == "reload 1: installed, 2 files, 1 commands" &&
              lines.getD 1 "" == "reload 2: rejected" &&
              diagnostic.startsWith "diagnostic: init.lean:3:0: error: " &&
              namesOnOneLine diagnostic (session.directory / "Config" / "Bad.lean") &&
              lines.getD 3 "" == "run greet: ok" }]

/-- How a check controls elaboration: a decorator of the elaborator port that
holds one config file, `Config/Slow.lean` unless the check names another,
open until the check lets it go, and counts the files being elaborated.
Nothing here sleeps to let something else happen. -/
structure Gate where
  /-- The module of the config file the gate holds: `Config.Slow` unless
  the check names another. -/
  module : String := "Config.Slow"
  /-- Resolved by the check to let the held file go, for good. -/
  release : IO.Promise Unit
  /-- Whether an elaboration of the held file has arrived and waited. -/
  holding : IO.Ref Bool
  /-- How many files are being elaborated now. -/
  inProgress : IO.Ref Nat
  /-- The most files that were being elaborated at once. -/
  most : IO.Ref Nat

namespace Gate

/-- A gate that is shut, holding the config file of `module`. -/
def new (module : String := "Config.Slow") : IO Gate :=
  return { module, release := ← IO.Promise.new, holding := ← IO.mkRef false,
           inProgress := ← IO.mkRef 0, most := ← IO.mkRef 0 }

/-- Runs `elaborate`, the elaboration of `file`, behind the gate. -/
def through {σ : Type} (gate : Gate) (file : Config.SourceFile)
    (elaborate : IO (Config.FileResult σ)) : IO (Config.FileResult σ) := do
  let now ← gate.inProgress.modifyGet fun count => (count + 1, count + 1)
  gate.most.modify (max · now)
  try
    if file.module == gate.module then
      gate.holding.set true
      discard <| IO.wait gate.release.result?
    elaborate
  finally
    gate.inProgress.modify (· - 1)

/-- `elaborator` behind the gate: every elaboration of a file, the root's
too. -/
def around {β σ : Type} (gate : Gate) (elaborator : Config.Elaborator β σ) :
    Config.Elaborator β σ :=
  { elaborator with
    file := fun base handles file => gate.through file (elaborator.file base handles file),
    root := fun base handles file => gate.through file (elaborator.root base handles file) }

/-- Lets the held file go, now and from now on. -/
def «open» (gate : Gate) : IO Unit :=
  gate.release.resolve ()

end Gate

/-- `source`, counting in `reads` how many times its root is read: once for
each reload job. -/
def counting (reads : IO.Ref Nat) (source : Config.Source) : Config.Source :=
  { source with
    root := do
      reads.modify (· + 1)
      source.root }

/-- A config file that takes as long to elaborate as the check's gate says. -/
def slowText : String :=
  "def slow : Nat := 1\n"

/-- The root of `greetConfig` with `Config/Slow.lean` imported beside
`Config/Greet.lean`. -/
def overSlow : String :=
  importing ["Config.Greet", "Config.Slow"] setupText

/-- `greetConfig` with a third file, `Config/Slow.lean`, which the root
imports after `Config/Greet.lean`. -/
def slowConfig : List (String × String) :=
  [("Config/Greet.lean", greetText "v1"), ("Config/Slow.lean", slowText), ("init.lean", overSlow)]

/-- `elaborator`, noting in `elaborated` the module of each file it
elaborates, the root's too, in order. -/
def noting {β σ : Type} (elaborated : IO.Ref (Array String)) (elaborator : Config.Elaborator β σ) :
    Config.Elaborator β σ :=
  { elaborator with
    file := fun base handles file => do
      elaborated.modify (·.push file.module)
      elaborator.file base handles file,
    root := fun base handles file => do
      elaborated.modify (·.push file.module)
      elaborator.root base handles file }

/-- The text of a config file that defines the command `name`, which makes
a text holding `text`, after importing `imports`. -/
def makingFile (imports : List String) (name text : String) : String :=
  importing imports s!"def {name} : EditorM Unit := do\n  discard <| createText \"{text}\"\n"

/-- A config of four files in a directory: the root imports `Config.A` and
`Config.B` and registers a command of each file, and `Config.B` imports
`Config.C`. `versions` gives the text each of `a`, `b` and `c` makes. -/
def fourFileConfig (a b c : String) (extra : String := "") : List (String × String) :=
  [("Config/A.lean", makingFile [] "a" a), ("Config/B.lean", makingFile ["Config.C"] "b" b),
    ("Config/C.lean", makingFile [] "c" c),
    ("init.lean",
      importing ["Config.A", "Config.B"]
        ("def setup : SetupM Unit := do\n  command \"a\" a\n  command \"b\" b\n  command \"c\" c\n" ++
          extra))]

/-- The checks of config as modules through the headless host, with the
real elaborator over files in a temporary directory: which files a reload
elaborates after a change, a module that is not linked, and a base that
grows when a file first imports `Lean`. -/
def moduleHostChecks (context : Context) : List Check :=
  [{
      name :=
        "after a change to one config file, a reload elaborates that file and the files that import it, and no other: a file the root imports, a file another file imports, the root, and nothing changed",
      run := do
        let elaborated ← IO.mkRef #[]
        withHostOver context (fourFileConfig "a1" "b1" "c1") (noting elaborated) id fun session =>
            do
            let reloaded (files : List (String × String)) : IO (Array String) := do
              writeConfig session.directory files
              elaborated.set #[]
              session.ask [.reload]
              elaborated.get
            let first ← reloaded []
            let changedA ← reloaded [("Config/A.lean", makingFile [] "a" "a2")]
            let changedC ← reloaded [("Config/C.lean", makingFile [] "c" "c2")]
            let changedRoot ← reloaded (fourFileConfig "a2" "b1" "c2" "\n-- changed\n")
            let unchanged ← reloaded []
            session.ask [.run "a", .run "b", .run "c", .show]
            let lines ← session.lines
            return first == #["Config.A", "Config.C", "Config.B", "init"] &&
                changedA == #["Config.A", "init"] &&
                changedC == #["Config.C", "Config.B", "init"] &&
                changedRoot == #["init"] &&
                unchanged == #[] &&
                (lines.filter (·.startsWith "reload ")) ==
                  (Array.range 5).map
                    (fun index => s!"reload {index + 1}: installed, 4 files, 3 commands") &&
                lines.extract (lines.size - 4) lines.size ==
                  #["text 0: \"\"", "text 1: \"a2\"", "text 2: \"b1\"", "text 3: \"c2\""] },
    { name :=
        "an import of a config file under a name that differs from the file's in the case of its letters is rejected at the import, on a file system that ignores case as on one that does not, and the old config stays"
      run :=
        withHost context
          [("Config/Keys.lean", greetText "v1"), ("init.lean", importing ["Config.Keys"] setupText)]
          fun session => do
          session.ask [.reload]
          session.write "init.lean" (importing ["Config.keys"] setupText)
          session.ask [.reload]
          session.ask [.run "greet"]
          return (← session.lines) ==
              #["reload 1: installed, 2 files, 1 commands", "reload 2: rejected",
                "diagnostic: init.lean: error", "run greet: ok"] },
    { name :=
        "a root that imports a module that is not linked is rejected with a diagnostic at the import that names the module, and the old config stays"
      run :=
        withHost context [("init.lean", greetText "v1" ++ setupText)] fun session => do
          session.ask [.reload]
          session.write "init.lean" (importing ["Lake"] (greetText "v2" ++ setupText))
          session.ask [.reload]
          session.ask [.run "greet", .show]
          let output ← session.output.get
          return output ==
                #["reload 1: installed, 1 files, 1 commands", "reload 2: rejected",
                  s!"diagnostic: init.lean:2:0: error: {Config.notLinked "Lake" none}",
                  "run greet: ok", "commands: greet", "text 0: \"\"", "text 1: \"v1\""] &&
              ((Config.notLinked "Lake" none).splitOn "`Lake`").length == 2 },
    { name :=
        "a reload whose root first imports Lean installs: the base grows to hold it, and a command that uses it runs"
      run :=
        withHost context [("init.lean", greetText "v1" ++ setupText)] fun session => do
          session.ask [.reload]
          session.write "init.lean"
              (importing ["Lean"]
                  "def greet : EditorM Unit := do\n  discard <| createText (Lean.Json.arr #[Lean.Json.str \"v2\"]).compress\n" ++
                setupText)
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.output.get) ==
              #["reload 1: installed, 1 files, 1 commands",
                "reload 2: installed, 1 files, 1 commands", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"[\\\"v2\\\"]\""] }]

/-- The lines `event <source> 0` up to `event <source> <count - 1>`: what the
host prints for a script of `count` events fed from a Rust thread. -/
def eventLines (source count : Nat) : Array String :=
  (Array.range count).map fun code => s!"event {source} {code}"

/-- A fake of the elaborator port whose base and every handle hold a library
handle, a counter of its own: how many of them are alive is how many
counters the library holds. A file's imports are its lines that start
with `import`, and every file elaborates. -/
def handleElaborator : Config.Elaborator Ffi.Counter Ffi.Counter :=
  {
    imports := fun file =>
      pure
        (.ok
          ((file.text.splitOn "\n").filterMap fun line =>
              if line.startsWith "import " then
                some { module := (line.drop 7).toString, line := 1, column := 0 }
              else none).toArray),
    base := fun earlier _ =>
      match earlier with
      | some base => pure base
      | none => Ffi.Counter.new 0,
    linked := fun _ _ => pure .absent,
    file := fun _ _ _ => return { diagnostics := #[], handle := some (← Ffi.Counter.new 0) },
    root := fun _ _ _ => return { diagnostics := #[], handle := some (← Ffi.Counter.new 0) },
    setup := fun _ => return .ok (pure ()) }

/-- The checks of the editor thread and the reload job: what happens while a
file elaborates, that reloads are serialised, and that nothing of a
replaced config is kept. -/
def threadChecks (context : Context) : List Check :=
  [{
      name :=
        "the editor answers events while a slow file elaborates: 100 events from a Rust thread and a command of the old config",
      run := do
        let gate ← Gate.new
        withHostOver context greetConfig gate.around id fun session => do
            session.ask [.reload]
            session.write "Config/Slow.lean" slowText
            session.write "init.lean" overSlow
            session.host.send .reload
            try
              -- The reload job is now inside the elaboration of `Config/Slow.lean`,
              -- and stays there until the gate opens.
              unless ← eventually gate.holding.get do
                return false
              unless ← Ffi.feedScript .editor 77 100 do
                return false
              session.host.send (.run "greet")
              -- With the job on the editor thread these lines never come while
              -- the file is held: the wait runs out and the check fails.
              let answered ←
                eventually do
                    let lines ← session.output.get
                    return lines.size == 102 && lines.contains "run greet: ok"
              let lines ← session.output.get
              -- The file is still being elaborated: all of that was answered
              -- while it was held.
              let held := (← gate.inProgress.get) == 1
              gate.open
              session.ask []
              let after ← session.output.get
              return answered && held &&
                  lines.extract 0 1 == #["reload 1: installed, 2 files, 1 commands"] &&
                  (lines.filter (·.startsWith "event ")) == eventLines 77 100 &&
                  !lines.any (·.startsWith "reload 2") &&
                  after.extract 102 after.size == #["reload 2: installed, 3 files, 1 commands"]
            finally
              gate.open },
    { name :=
        "reloads are serialised: requests made while a job runs make one more job, never two at once, and it reads the source afresh"
      run := do
        -- Seen to bite once by hand: a host that starts a job for every
        -- request, running or not, fails this.
        let gate ← Gate.new
        let reads ← IO.mkRef 0
        withHostOver context (slowConfig) gate.around (counting reads) fun session => do
            session.host.send .reload
            try
              unless ← eventually gate.holding.get do
                return false
              session.write "Config/Greet.lean" (greetText "v2")
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
                    #["reload 1: installed, 3 files, 1 commands",
                      "reload 2: installed, 3 files, 1 commands", "run greet: ok",
                      "commands: greet", "text 0: \"\"", "text 1: \"v2\""]
            finally
              gate.open },
    { name :=
        "a replaced config is not retained: after 50 reloads the library holds the base and the handles of one loaded config, and none once the host has stopped"
      run := do
        -- Seen to bite once by hand: a host that pushes each outcome onto a
        -- list it keeps fails this.
        let before ← Ffi.Counter.live
        let files ← IO.mkRef ([] : List (String × String))
        let loaded ←
          hosted context handleElaborator (sourceOver files.get) fun host _ => do
              for round in [0:50] do
                -- A file the root imports changes, so it and the root are
                -- elaborated again, and the other file is kept.
                files.set
                    [("init", "import Config.A\nimport Config.B\n"), ("Config.A", toString round),
                      ("Config.B", "b")]
                host.send .reload
                unless ← host.settle patience do
                  return false
              -- The base and the handles of three files. A finished job's
              -- task may still be going away, so this is polled.
              eventually do
                  return (← Ffi.Counter.live) == before + 4
        let freed ←
          eventually do
              return (← Ffi.Counter.live) == before
        return loaded && freed }]

/-- A config with three jobs, and the `setup` that registers them beside
`greet`: `count` sleeps 10 ms and its result, 42, is made into a text;
`boom` sleeps 10 ms and throws; and `bad` is `count` with a handler whose
command the library refuses. -/
def jobsText : String :=
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

/-- A config of two files: `greet`, which makes a text holding "v1", and a
`setup` that registers it and the jobs of `jobsText`. -/
def jobsConfig : List (String × String) :=
  [("Config/Greet.lean", greetText "v1"), ("init.lean", overGreet jobsText)]

/-- A config whose `setup` registers the mode `json`, whose text is parsed
with the grammar `json` and drawn by the shipped default; the command
`edit`, which puts `, 2` before the last byte of the scratch buffer's text;
and the job `highlight`, which sleeps 10 ms and finishes with a command that
puts `[1, true]` in the scratch buffer's text and makes `json` its major
mode, through the scratch buffer's window. -/
def highlightText : String :=
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

/-- Runs `check` against a host over a config of `highlightText`, whose
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
    writeConfig directory [("init.lean", highlightText)]
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
def _root_.Editor.Test.Linked.Session.threadOf (session : Session) (line : String) :
    IO (Option UInt64) := do
  let lines ← session.output.get
  let threads ← session.threads.get
  return (lines.idxOf? line).bind fun index => threads[index]?

/-- Runs `check` with a point to hold a thread at: the first thread to reach
it is held there, and let go `milliseconds` after it arrived, from a task of
its own, whatever the check's waits do; a thread that reaches it later
passes. The thread is let go, and that task waited for, before this
returns. -/
def holdingOnce {α : Type} (milliseconds : UInt32) (check : BaseIO Unit → IO α) : IO α := do
  let release ← IO.Promise.new
  let entered ← IO.mkRef false
  let releaser ←
    IO.asTask (prio := .dedicated) do
        if ← eventually entered.get then
          IO.sleep milliseconds
        release.resolve ()
  try
    check do
        unless ← entered.modifyGet fun entered => (entered, true) do
          discard <| IO.wait release.result?
  finally
    release.resolve ()
    discard <| IO.wait releaser

/-- Runs `check` on `collaborators` whose output port holds the editor thread
inside the first line `holds` accepts, and lets it go `milliseconds` after
it arrived (`holdingOnce`): the editor thread is inside an event for that
long, whatever the check's waits do. -/
def holdingLine {α β σ : Type} {scheme : InputScheme}
    (collaborators : Headless.Collaborators β σ scheme) (holds : String → Bool)
    (milliseconds : UInt32) (check : Headless.Collaborators β σ scheme → IO α) : IO α :=
  holdingOnce milliseconds fun hold =>
    check
      { collaborators with
        emit := fun line => do
          if holds line then
            hold
          collaborators.emit line }

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
                #["reload 1: installed, 2 files, 1 commands", "run greet: ok", "spawn count: job 1",
                  "run greet: ok"] &&
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
          session.write "Config/Greet.lean" (greetText "v2")
          session.ask [.reload]
          let withdrawn ← session.clock.withdrawn
          -- Past the job's sleep: a job that was still there would end, and
          -- its handler would make a text.
          session.clock.advance 10
          session.ask [.show]
          return withdrawn.size == 1 && (← session.clock.waiting) == 0 &&
              (← session.output.get) ==
                #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1",
                  "job 1 count: cancelled", "reload 2: installed, 2 files, 1 commands",
                  "commands: greet"] },
    { name :=
        "a rejected reload cancels nothing: the old config's job runs on, and its handler runs when it finishes"
      run :=
        withHost context jobsConfig fun session => do
          session.ask [.reload]
          session.ask [.spawn "count"]
          unless ← eventually (return (← session.clock.waiting) == 1) do
            return false
          session.write "Config/Greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
          session.ask [.reload]
          let stillWaiting := (← session.clock.waiting) == 1 && (← session.clock.withdrawn).isEmpty
          session.clock.advance 10
          let joined ← session.host.join patience
          return stillWaiting && joined == .settled &&
              (← session.lines) ==
                #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1",
                  "reload 2: rejected", "diagnostic: Config/Greet.lean: error",
                  "job 1 count: ok"] },
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
                #["reload 1: installed, 2 files, 1 commands", "spawn boom: job 1",
                  "spawn bad: job 2", "spawn nope: no such job"] &&
              joined == .settled &&
              ended == #["job 1 boom: failed: no thanks", "job 2 bad: refused: no such text"] },
    { name :=
        "a join that cannot finish fails, it does not hang: the failure names the join's line, and the loop cancels its jobs when it ends"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The clock is never moved, so the job never ends: the join runs
          -- out, after a fifth of a second, and `run` ends its loop. The
          -- reload must finish, so its settle has the long patience, and so
          -- have the editor thread's answers and the loop's end.
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settleWithin patience⟩,
                  ⟨3, .request (.spawn "count")⟩, ⟨5, .join⟩, ⟨6, .request .show⟩]
                200 (answer := patience)
          -- The loop has ended: the job it left is cancelled, with its wait.
          let cancelled ← eventually (return (← stage.clock.withdrawn).size == 1)
          let waiting ← stage.clock.waiting
          let output ← stage.output.get
          saw
              (failure == some (.working (some 5)) && cancelled && waiting == 0 &&
                output == #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1"])
              s!"failure={repr failure} cancelled={cancelled} waiting={waiting} output={output}" },
    { name :=
        "the shape of a short-patience script: the settle after a real reload has a patience of its own, so a reload slower than the join's patience still leaves the join to run out as working"
      run := do
        -- A guard on how the checks write their scripts, not on the driver.
        -- The reload is held at the gate for twice the join's patience, as
        -- a loaded runner's elaboration can be. Under a plain `settle`,
        -- which keeps the run's 200 ms, that fails the settle as reloading
        -- (`.reloading (some 2)`, seen with this check's first script); the
        -- driver does not and need not tell a slow reload from a stuck one.
        -- So a script that runs its waits on a short patience settles a
        -- real reload with a patience of its own (`settle <milliseconds>`),
        -- as this one and the join and dispose checks do. The fix is that
        -- shape, not the driver's: the driver as it was before a run had
        -- an `answer` passes this script too.
        let gate ← Gate.new (module := "Config.Greet")
        IO.FS.withTempDir fun directory => do
            writeConfig directory jobsConfig
            let stage ←
              Stage.new context (gate.around context.elaborator) (Config.Directory.source directory)
            let opener ←
              IO.asTask (prio := .dedicated) do
                  if ← eventually gate.holding.get then
                    IO.sleep 400
                  gate.open
            try
              let failure ←
                Headless.run stage.collaborators
                    #[⟨1, .request .reload⟩, ⟨2, .settleWithin patience⟩,
                      ⟨3, .request (.spawn "count")⟩, ⟨5, .join⟩, ⟨6, .request .show⟩]
                    200 (answer := patience)
              let held ← gate.holding.get
              let output ← stage.output.get
              saw
                  (failure == some (.working (some 5)) && held &&
                    output == #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1"])
                  s!"failure={repr failure} held={held} output={output}"
            finally
              gate.open
              discard <| IO.wait opener },
    { name :=
        "an editor thread held inside an event longer than a join's patience still makes the join run out as working: the editor thread's answer has a patience of its own"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The editor thread is held inside the spawn's line for twice the
          -- join's patience: the join's marker waits behind it.
          let failure ←
            holdingLine stage.collaborators (· == "spawn count: job 1") 400 fun collaborators =>
                Headless.run collaborators
                  #[⟨1, .request .reload⟩, ⟨2, .settleWithin patience⟩,
                    ⟨3, .request (.spawn "count")⟩, ⟨4, .join⟩]
                  200 (answer := patience)
          let output ← stage.output.get
          saw
              (failure == some (.working (some 4)) &&
                output == #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1"])
              s!"failure={repr failure} output={output}" },
    { name :=
        "spawn and join are directives of a script, join, restarted and indexed with an optional patience in seconds, a spawn with no name and a patience that is no number are refused, and a join that ran out is described with its line"
      run :=
        let refusal (text : String) : String :=
          match Headless.script text with
          | .error message => message
          | .ok _ => ""
        let working := Headless.Failure.describe 30000 (.working (some 12))
        pure
          ((Headless.script "spawn count\n  join  \nspawn  two words\n").toOption ==
              some
                #[⟨1, .request (.spawn "count")⟩, ⟨2, .join none⟩,
                  ⟨3, .request (.spawn "two words")⟩] &&
            (Headless.script "join 300\nrestarted\nrestarted 300\n").toOption ==
              some #[⟨1, .join (some 300)⟩, ⟨2, .restarted none⟩, ⟨3, .restarted (some 300)⟩] &&
            (Headless.script "indexed\nindexed 300\n").toOption ==
              some #[⟨1, .indexed none⟩, ⟨2, .indexed (some 300)⟩] &&
            (refusal "indexed soon\n").startsWith "line 1: " &&
            (refusal "join soon\n").startsWith "line 1: " &&
            (refusal "restarted x\n").startsWith "line 1: " &&
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

/-- A config of one file with one command, `forget`, which releases the
text of index 0: the text of the editor loop's scratch buffer, made with the
loop's frame, before any command runs. -/
def forgetConfig : List (String × String) :=
  [("init.lean",
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
(`Headless.script`, `Headless.run`, `Headless.runAndDispose`), and of what
the executable's hosts dispose of when they end (`Headless.shippedOver`).
The command line itself is covered by one run of the real executable on the
fixture under `tests/headless`, in the `ffi-test` task. -/
def scriptChecks (context : Context) : List Check :=
  [{  name :=
        "restarted is a directive with its line's number, refused with anything after it but a number of seconds, and the error message of a line that is no directive lists it; a run resumed past k restarteds runs the script from the line after the k-th"
      run :=
        let script :=
          #[⟨1, .request .scene⟩, ⟨2, .restarted⟩, ⟨3, .settle⟩, ⟨4, .restarted⟩,
            ⟨5, .request .show⟩]
        pure <|
          (Headless.script
                  "scene
 restarted 
").toOption ==
              some #[⟨1, .request .scene⟩, ⟨2, .restarted⟩] &&
            (match
              Headless.script
                "scene
restarted now" with
            | .error message => message.startsWith "line 2: "
            | .ok _ => false) &&
            (match
              Headless.script
                "scene
wait 2" with
            | .error message => (message.splitOn " restarted [<seconds>],").length == 2
            | .ok _ => false) &&
            Headless.resumed script 0 == script &&
            Headless.resumed script 1 == #[⟨3, .settle⟩, ⟨4, .restarted⟩, ⟨5, .request .show⟩] &&
            Headless.resumed script 2 == #[⟨5, .request .show⟩] &&
            Headless.resumed script 3 == #[] },
    { name :=
        "indexed and workspaces are directives with their lines' numbers, refused with anything after them as no directive, and the error message of a line that is no directive lists them"
      run :=
        pure <|
          (Headless.script "indexed\n  workspaces  \n").toOption ==
              some #[⟨1, .indexed⟩, ⟨2, .request .workspaces⟩] &&
            (["indexed now", "workspaces all"].all fun line =>
              match Headless.script ("scene\n" ++ line) with
              | .error message => message.startsWith "line 2: "
              | .ok _ => false) &&
            match Headless.script "scene\nwait 2" with
            | .error message =>
              (message.splitOn ", indexed [<seconds>],").length == 2 &&
                (message.splitOn " workspaces,").length == 2
            | .ok _ => false },
    { name :=
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
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let joined ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩,
                  ⟨4, .advance 10⟩, ⟨5, .join⟩]
                patience
          let output ← stage.output.get
          -- The advance's short patience is for it alone: the reload must
          -- finish, and the editor thread answer and the loop end.
          let stalled ← Stage.new context context.elaborator (Config.Directory.source directory)
          let ranOut ←
            Headless.run stalled.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settleWithin patience⟩, ⟨3, .advance 5⟩] 200
                (answer := patience)
          let stalledOutput ← stalled.output.get
          let real ← Stage.new context context.elaborator (Config.Directory.source directory)
          let refused ←
            Headless.run { real.collaborators with clock := none } #[⟨1, .settle⟩, ⟨2, .advance 1⟩]
                200 (answer := patience)
          saw
              (joined.isNone && output.contains "job 1 count: ok" &&
                ranOut == some (.stalled 3 5) &&
                (Headless.Failure.stalled 3 5).describe 200 ==
                  "the advance on line 3 found no wait due within 5 ms on the clock within 200 ms" &&
                refused == some (.noClock 2) &&
                (Headless.Failure.noClock 2).describe 200 ==
                  s!"the advance on line 2: {Headless.advanceNeedsClock}")
              s!"joined={repr joined} output={output} ranOut={repr ranOut} stalledOutput={stalledOutput} refused={repr refused}" },
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
        "a settle may give its own patience in milliseconds, one number: anything else after settle is refused, with the number of the line"
      run :=
        let refusal (text : String) : String :=
          match Headless.script text with
          | .error message => message
          | .ok _ => ""
        pure
          ((Headless.script "reload\nsettle 90000\nsettle\n").toOption ==
              some #[⟨1, .request .reload⟩, ⟨2, .settleWithin 90000⟩, ⟨3, .settle⟩] &&
            (refusal "reload\nsettle soon\n").startsWith "line 2: " &&
            (refusal "settle 1 2\n").startsWith "line 1: ") },
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
          writeConfig directory greetConfig
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
                #["reload 1: installed, 2 files, 1 commands", "key arrived: a KeyA shift+control",
                  "run greet: ok", "key arrived: <Escape> - -"] },
    { name :=
        "a real config that defines a segment and lists the mode line installs: the reload prints a line for the segment nobody registered, the echo area says it, and each status line is the listing's, in its order and on its sides"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory
              [("init.lean",
                  "def setup : SetupM Unit := do\n  defineSegment \"greeting\" fun _ =>\n    #[{ text := \"hi\", face := ⟨\"mode-line.secondary\"⟩, padding := 4 }]\n  modeLine [\"buffer\", \"nope\"] [\"greeting\", \"line-column\"]\n")]
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .commit "ab"⟩, ⟨4, .request .scene⟩]
                patience
          let output ← stage.output.get
          return failure == none &&
              output.filter (fun line => !line.startsWith "scene " && !line.startsWith "view ") ==
                #["reload 1: installed, 1 files, 0 commands",
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
          writeConfig directory greetConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.run "greet")⟩,
                  ⟨4, .request .show⟩]
                patience
          return failure == none &&
              (← stage.output.get) ==
                #["reload 1: installed, 2 files, 1 commands", "run greet: ok", "commands: greet",
                  "text 0: \"\"", "text 1: \"v1\""] },
    { name :=
        "a script whose settle cannot be satisfied fails, it does not hang, and the failure names the settle's line and says a reload was still running"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeConfig directory slowConfig
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
        "a settle with its own milliseconds waits that long, not the run's patience, and its failure says how long it waited"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeConfig directory slowConfig
            let stage ←
              Stage.new context (gate.around context.elaborator) (Config.Directory.source directory)
            try
              -- The reload is held open. The run's patience is a minute, so
              -- a failure now is the settle's own fifth of a second.
              let failure ←
                Headless.run stage.collaborators
                    #[⟨3, .request .reload⟩, ⟨7, .settleWithin 200⟩, ⟨8, .request .show⟩] 60000
              return failure == some (.waited 200 (.reloading (some 7)))
            finally
              gate.open },
    { name :=
        "a join with its own seconds waits that long, not the run's patience, and its failure says how long it waited"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The clock is never moved, so the job never ends. The run's
          -- patience is the long one, so a failure now is the join's own
          -- second.
          let failure ←
            Headless.run stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩,
                  ⟨5, .join (some 1)⟩, ⟨6, .request .show⟩]
                patience
          saw (failure == some (.waited 1000 (.working (some 5)))) s!"failure={repr failure}" },
    { name :=
        "a restarted with its own seconds waits that long for a hand-over, not the run's patience, and its failure says how long it waited"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- No restart is asked for, so none comes: its own patience of
          -- none at all runs out at once, where the run's would be long.
          let failure ← Headless.run stage.collaborators #[⟨1, .restarted (some 0)⟩] patience
          saw (failure == some (.waited 0 (.notRestarted 1))) s!"failure={repr failure}" },
    { name :=
        "a script that ends while a reload cannot finish fails at its end, with a reload still running and no line"
      run := do
        let gate ← Gate.new
        IO.FS.withTempDir fun directory => do
            writeConfig directory slowConfig
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
          withHostOver context slowConfig gate.around id fun session => do
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
        let stage ← Stage.new context context.elaborator (memorySource [])
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
          writeConfig directory greetConfig
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
          writeConfig directory greetConfig
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
          writeConfig directory greetConfig
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
              #["reload 1: installed, 2 files, 1 commands",
                "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 1, theme \"default\"",
                "view 0 0,0 0x0: \"kept\", scroll 0, selections 4..4, padding 8 8",
                statusOf (modified := true) (cursor := ⟨0, 4⟩), "spawn count: job 1",
                "job 1 count: ok", "reload 2: installed, 2 files, 1 commands",
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
              #["reload 1: installed, 1 files, 1 commands",
                "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, published 1, theme \"default\"",
                "view 0 0,0 0x0: \"a\", scroll 0, selections 1..1, padding 8 8",
                statusOf (modified := true) (cursor := ⟨0, 1⟩), "run forget: ok",
                "scene 0x0, focused 0, echo \"refused: no such text\", echo padding 8, preedit -, published 5, theme \"default\""] },
    { name :=
        "a program of the editor loop that is refused is printed as refused and hands back nothing, and what it made before the refusal is kept; one that is not refused prints nothing and hands back its result"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let collaborators := stage.collaborators
        let running : TestRunning :=
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
        let stage ← Stage.new context context.elaborator (memorySource [])
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
            (atEnd.splitOn "line").length == 1) },
    { name := "a wait that had its own patience is described with that patience, not the run's"
      run :=
        let waited := Headless.Failure.describe 30000 (.waited 90000 (.reloading (some 9)))
        pure
          (waited == Headless.Failure.describe 90000 (.reloading (some 9)) &&
            (waited.splitOn "90000 ms").length == 2 &&
            (waited.splitOn "30000 ms").length == 1) },
    { name :=
        "a wait's failure carries the patience that ran out when it is not the run's: the answer patience for an editor thread that did not answer, a settle's own milliseconds for any failure of its, and none for the run's own"
      run :=
        let line := some 1
        let failures :=
          [Headless.Wait.unanswered.failureIn line 60000 200,
            Headless.Wait.unanswered.failureIn line 30000 30000,
            Headless.Wait.reloading.failureIn line 30000 200,
            Headless.Wait.working.failureIn line 30000 200,
            Headless.Wait.reloading.failureIn line 30000 200 (own := some 90000),
            Headless.Wait.unanswered.failureIn line 30000 200 (own := some 90000),
            -- A settle <milliseconds> bounds its whole wait, the editor
            -- thread's answer too, so an answer that did not come names its
            -- milliseconds even when the run's answer and patience agree.
            Headless.Wait.unanswered.failureIn line 30000 30000 (own := some 90000),
            Headless.Wait.settled.failureIn line 30000 200,
            Headless.Wait.ended.failureIn line 30000 200,
            Headless.Wait.settled.failureIn line 30000 200 (own := some 90000),
            Headless.Wait.ended.failureIn line 30000 200 (own := some 90000)]
        let expected : List (Option Headless.Failure) :=
          [some (.waited 200 (.unanswered line)), some (.unanswered line), some (.reloading line),
            some (.working line), some (.waited 90000 (.reloading line)),
            some (.waited 90000 (.unanswered line)), some (.waited 90000 (.unanswered line)), none,
            none, none, none]
        saw
          (failures == expected &&
            Headless.Failure.within 200 30000 (.unanswered none) ==
              .waited 200 (.unanswered none) &&
            Headless.Failure.within 30000 30000 (.working line) == .working line)
          s!"failures={repr failures}" },
    { name :=
        "the headless mode's run disposes of its collaborators once its loop has ended: dispose is called once, after every line the script had the host print"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let (failure, _) ←
            Headless.runAndDispose stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩,
                  ⟨4, .advance 10⟩, ⟨5, .join⟩]
                patience
          let output ← stage.output.get
          return failure.isNone && output.contains "job 1 count: ok" &&
              (← stage.disposed.get) == #[output.size] },
    { name := "a run that fails disposes of its collaborators too, once, when its loop has ended"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The clock is never moved, so the join runs out. The reload must
          -- finish, and the editor thread answer and the loop end.
          let (failure, _) ←
            Headless.runAndDispose stage.collaborators
                #[⟨1, .request .reload⟩, ⟨2, .settleWithin patience⟩,
                  ⟨3, .request (.spawn "count")⟩, ⟨4, .join⟩]
                200 (answer := patience)
          let disposed ← stage.disposed.get
          let output ← stage.output.get
          saw (failure == some (.working (some 4)) && disposed == #[output.size])
              s!"failure={repr failure} disposed={disposed} output={output}" },
    { name :=
        "a run whose advance stalls while the editor thread is inside an event disposes only after its loop has ended"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        -- The editor thread is held inside the commands line for longer than
        -- the stall's patience and the halt after it together.
        let (failure, _) ←
          holdingLine stage.collaborators (·.startsWith "commands:") 1000 fun collaborators =>
              Headless.runAndDispose collaborators #[⟨1, .request .show⟩, ⟨2, .advance 5⟩] 200
                (answer := patience)
        let disposed ← stage.disposed.get
        let output ← stage.output.get
        saw
            (failure == some (.stalled 2 5) && disposed == #[output.size] &&
              output.any (·.startsWith "commands:"))
            s!"failure={repr failure} disposed={disposed} output={output}" },
    { name :=
        "a run whose join runs out while the editor thread is inside an event disposes only after its loop has ended"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        -- The editor thread is held inside the commands line for a second
        -- longer than its answer to the join may take: the join runs out
        -- unanswered with the line pending, and the halt after it waits
        -- for the loop to print the line, reach the join's marker and stop.
        let held := (patience + 1000).toUInt32
        let script : Array Headless.Line := #[⟨1, .request .show⟩, ⟨2, .join⟩]
        let (failure, _) ←
          holdingLine stage.collaborators (·.startsWith "commands:") held fun collaborators =>
              Headless.runAndDispose collaborators script 200 (answer := patience)
        let disposed ← stage.disposed.get
        let output ← stage.output.get
        saw
            (failure == some (.waited patience (.unanswered (some 2))) &&
              disposed == #[output.size] &&
              output.any (·.startsWith "commands:"))
            s!"failure={repr failure} disposed={disposed} output={output}" },
    { name :=
        "a run that reaches its script's end disposes only after its loop has ended, when the loop is slow to end"
      run :=
        IO.FS.withTempDir fun directory => do
          writeConfig directory jobsConfig
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          -- The script leaves its job in its wait, and the loop withdraws
          -- that wait as it ends, on its own thread: held there for longer
          -- than the run's patience, the loop ends that long after the
          -- script's end stopped it. A held line could not show this: the
          -- wait at the script's end waits for the editor thread's answer,
          -- so a line held before it is printed before the stop. The
          -- spawn's line waits for the job to be in its wait, so there is a
          -- wait to withdraw when the loop ends.
          let staged := stage.collaborators
          let timers := staged.services.timers
          let withdrew ← IO.mkRef false
          let order ← IO.mkRef #[]
          let (failure, _) ←
            holdingOnce 1000 fun hold =>
                Headless.runAndDispose
                  { staged with
                    emit := fun line => do
                      if line == "spawn count: job 1" then
                        discard <| eventually (return (← stage.clock.waiting) == 1)
                      staged.emit line
                    services :=
                      { staged.services with
                        timers :=
                          { timers with
                            cancel := fun id => do
                              hold
                              timers.cancel id
                              withdrew.set true } }
                    dispose := do
                      order.modify (·.push (← withdrew.get))
                      staged.dispose }
                  #[⟨1, .request .reload⟩, ⟨2, .settleWithin patience⟩,
                    ⟨3, .request (.spawn "count")⟩]
                  200 (answer := patience)
          let withdrawn ← stage.clock.withdrawn
          let disposed ← stage.disposed.get
          let output ← stage.output.get
          let order ← order.get
          saw
              (failure.isNone && withdrawn.size == 1 && order == #[true] &&
                disposed == #[output.size] &&
                output == #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1"])
              s!"failure={repr failure} withdrawn={withdrawn} withdrew before dispose={order} disposed={disposed} output={output}" },
    { name :=
        "the executable's hosts dispose of the directory of the config files' module data: their dispose removes it once it was made, through the module files, and removes nothing before"
      run :=
        IO.FS.withTempDir fun directory => do
          let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
          let removed ← IO.mkRef #[]
          let files ←
            Config.Elaborate.ModuleFiles.over (pure (directory / "modules")) fun made =>
                removed.modify (·.push made)
          let staged := stage.collaborators
          let shipped :=
            Headless.shippedOver #[] #[`Editor] "" [] directory.toString staged.emit staged.services
              staged.published staged.held files
          shipped.dispose
          let before ← removed.get
          discard <| files.directory
          shipped.dispose
          return before.isEmpty && (← removed.get) == #[directory / "modules"] }]

/-- The compiled command `split`: it splits the window it is called on. -/
def splitCommand : Config.Registration :=
  { name := "split"
    action :=
      .call fun call => do
        discard <| call.target.window.id.split }

/-- A config whose `setup` registers two jobs, a command and a key. `double`
takes one number, sleeps 10 ms, and its command inserts the double, in
brackets, at the cursor of view 0 and messages it. `spinner` sleeps 10 ms,
and its command inserts `spun` and then asks the scratch buffer's text its
revision a thousand million times. `ask`, on `C-c a`, starts `double` with
21. -/
def startingText : String :=
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

/-- A config whose `setup` registers a command `quitter`: it inserts `typed`
at the cursor of view 0, and then gives up, with a reason. -/
def givingUpText : String :=
  "def setup : SetupM Unit := do
  command \"quitter\" do
    discard <| (⟨0⟩ : ViewId).insertAtSelections \"typed\"
    giveUp \"no can do\"
"

/-- A config whose `setup` registers a command `stopper`: it inserts `typed`
at the cursor of view 0, and then breaks off, with a reason. -/
def breakingOffText : String :=
  "def setup : SetupM Unit := do
  command \"stopper\" do
    discard <| (⟨0⟩ : ViewId).insertAtSelections \"typed\"
    breakOff \"far enough\"
"

/-- A config whose `setup` registers two commands and a job. `copy` writes a
text to the clipboard. `paste` puts the text the clipboard holds in the
echo area, or says what it was answered instead. `courier` sleeps 10 ms, and
its command says the text the clipboard holds after `courier read`. -/
def clipboardText : String :=
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
        withHost context [("init.lean", givingUpText)] fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "abcd") do
            return false
          session.ask [.run "quitter"]
          return (← session.lines) ==
                #["reload 1: installed, 1 files, 1 commands", "run quitter: gave up: no can do"] &&
              (← session.scene) == ("quitter: no can do".quote, #[viewLine "abcd" 4]) },
    { name :=
        "the driver's run of a command of config's that breaks off keeps what the command did and is printed so: the output says it broke off, with its reason, the scene's echo is its name and the reason with no refused, and the view's text holds what the command inserted"
      run :=
        withHost context [("init.lean", breakingOffText)] fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "abcd") do
            return false
          session.ask [.run "stopper"]
          return (← session.lines) ==
                #["reload 1: installed, 1 files, 1 commands",
                  "run stopper: broke off: far enough"] &&
              (← session.scene) == ("stopper: far enough".quote, #[viewLine "abcdtyped" 9]) },
    { name :=
        "the host keeps a clipboard of its own: before a write a command of config's reads no text, after one command wrote a text the next reads it, and so does a finished job's command"
      run :=
        withHost context [("init.lean", clipboardText)] fun session => do
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
              start := throw .noSuchText, packages := #[dispatchCompiled.package] })
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
              packages :=
                #[Compiled.package
                    { commands :=
                        #[{ name := "mark"
                            action :=
                              .call fun call => do
                                if let [.str text] := call.arguments then
                                  discard <| call.target.window.id.insertAtSelections text }]
                      jobs :=
                        #[{ name := "poster"
                            work := fun _ =>
                              Work.of
                                (fun _ => do
                                  post { command := "mark", arguments := [.str "p"] }
                                  sleep 10)
                                fun _ => pure () }] }] })
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
        withHost context [("init.lean", startingText)]
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
        withHost context [("init.lean", startingText)] fun session => do
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
        "a host handed two packages has their commands in list order as its loop starts, with no reload asked, and runs one; after a reload config's command is listed after them"
      run :=
        let making (name : String) (commands : List String) : Package :=
          { name
            setup :=
              for command in commands do
                Editor.command command (discard <| createText s!"{name}'s {command}") }
        withHost context greetConfig
          (fun session => do
            session.ask [.show, .run "shared", .show]
            let started ← session.lines
            session.ask [.reload]
            session.ask [.show]
            return started ==
                  #["commands: a shared b", "run shared: ok", "commands: a shared b",
                    "text 0: \"\"", "text 1: \"second's shared\""] &&
                (← session.lines).extract started.size ==
                  #["reload 1: installed, 2 files, 1 commands", "commands: a shared b greet",
                    "text 0: \"\"", "text 1: \"second's shared\""])
          { packages := #[making "first" ["a", "shared"], making "second" ["shared", "b"]] } },
    { name :=
        "a host is handed compiled jobs: a compiled command starts one before any config is loaded, a reload that installs does not cancel it, and once the clock lets it go its command runs"
      run :=
        withHost context [("init.lean", emptyText)]
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
                    "reload 1: installed, 1 files, 0 commands"] &&
                joined == .settled &&
                (← session.output.get).extract reloaded.size == #["job 1 nap: ok"] &&
                (← session.scene) == ("".quote, #[viewLine "napped" 6]))
          nappingCompiled }]

/-- A config whose `greet` does not elaborate: a number where `message` takes
a string, on its first line. -/
def brokenGreetText : String :=
  "def greet : EditorM Unit := message 7\n"

/-- Whether `echo`, quoted as a scene line has it, is a rejected reload's
error about the first line of `Config/Greet.lean` after its header, the
file's third. The column and the message are Lean's, so only their places
are checked. -/
def isGreetError (echo : String) : Bool :=
  echo.startsWith "\"reload: Config/Greet.lean:3:" && (echo.splitOn ": error: ").length == 2

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
          session.write "Config/Greet.lean" brokenGreetText
          session.ask [.reload]
          let rejected ← session.echo
          session.ask [.run "greet"]
          let replaced ← session.echo
          session.ask [.reload]
          let again ← session.echo
          session.write "Config/Greet.lean" helloText
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
              lines.contains "diagnostic: Config/Greet.lean: error" &&
              lines.contains "reload 4: installed, 2 files, 1 commands" &&
              (lines.filter (· == "run greet: ok")).size == 3 },
    { name :=
        "a reload rejected before the frame is made is said in the echo area once the frame is made"
      run :=
        withHost context
          [("Config/Greet.lean", brokenGreetText), ("init.lean", overGreet setupText)]
          fun session => do
          session.ask [.reload]
          let before ← session.scene
          session.host.resize 80 64
          session.ask []
          let made ← session.echo
          return before == ("", #[]) && isGreetError made }]

/-- The registry a host of the executable starts with: the one the packages
of the core's Lake package make (`Config.State.ofPackages` of
`EditorCore.EditorPackage.packages`), which is what `Headless.Running.new`
starts from for a host handed them. -/
def shippedRegistry : Config.Registry :=
  let (state, _) : Config.State Config.Elaborate.Base Config.Elaborate.Handle × Array String :=
    Config.State.ofPackages EditorCore.EditorPackage.packages
  state.registry

/-- The owner of what the package called `name` registers, by its name as
text (`Package.owner`): what the shipped checks compare an entry's owner
with for the features that are moving out of the core, so this module
imports none of their modules. -/
def owned (name : String) : Config.Owner :=
  { name }

/-- The checks of what the executable's hosts start with: the registry the
packages that ship make (`shippedRegistry`), each entry for the owner named
after its package, and the test scheme's keymap of its bindings. Nothing
here starts a host or a job. -/
def shippedChecks (_ : Unit) : List Check :=
  [{  name :=
        "the headless host handed a state directory starts its loop with it, as its working directory and home, and one handed none starts with none"
      run := do
        let completions ← Job.Completions.new
        let clock ← Job.FakeClock.new completions
        let services : Job.Services := { completions, timers := clock.timers }
        let published ← Snapshots.new
        let held ← Job.HeldSnapshots.new
        -- The module files' directory is made only when a config file is
        -- written, and no config is loaded here.
        let files ← Config.Elaborate.ModuleFiles.temporary
        let over (stateDirectory : Option System.FilePath) :=
          (Headless.shippedOver #[] #[`Editor] "" [] "" (fun _ => pure ()) services published held
              files stateDirectory).hosting
        let given := ((over (some "/state")).start.runModel {}).1
        let none_ := ((over none).start.runModel {}).1
        return (match given, none_ with
          | .ok given, .ok none_ =>
            given.state.stateDirectory == some "/state" && none_.state.stateDirectory == none &&
              given.state.workingDirectory == "/"
          | _, _ => false) },
    { name :=
        "the executable's hosts start with nothing of the at-point package: no command at-point-complete, at-point-next, at-point-previous, at-point-tab, at-point-backtab, at-point-return, at-point-quit, at-point-triggered or at-point-paused, no source words and none in the category word, no job words, no at-point source, and a modeless buffer's at-point chain is empty, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return ["at-point-complete", "at-point-next", "at-point-previous", "at-point-tab",
                  "at-point-backtab", "at-point-return", "at-point-quit", "at-point-triggered",
                  "at-point-paused"].all
              (fun name => (registry.find? name).isNone) &&
            !registry.sources.any (·.source.name == "words") &&
            registry.sourcesIn "word" == #[] &&
            !registry.jobs.any (·.registration.name == "words") &&
            registry.atPoints.isEmpty &&
            registry.atPointNames none #[] == #[] &&
            registry.unknownAtPoints == #[] },
    { name :=
        "the executable's hosts start with nothing of the languages package: no mode code and no language is registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return (registry.mode? "code").isNone && registry.languages.isEmpty },
    { name :=
        "the executable's hosts start with nothing of the mode-line package: of the segments the default listing names, the packages of the core's Lake package register version control's review alone, and none of state, buffer, modified, changed, directory, pending-keys, major-mode, line-column and position"
      run := do
        let registry := shippedRegistry
        return registry.segments.map (·.segment.name) == #["review"] },
    { name :=
        "the executable's hosts start with C-s-f bound to toggle-fullscreen, s-m to minimise-window and s-q to quit, the first two commands the frame-commands package's and quit the ex package's, and the three bindings the frame-commands package's; and the ex names b, ls and bd bound to switch-buffer, list-buffers and close-buffer"
      run := do
        let registry := shippedRegistry
        let bound (text : String) : Option Invocation :=
          (registry.keymap TestScheme.scheme).find? (keysOf text)
        let ownedBy (package : Package) (name : String) : Bool :=
          (registry.find? name).any (·.owner == package.owner)
        let frameKeys :=
          (registry.bindings.filter (·.owner == FrameCommands.package.owner)).map
            (·.binding.command)
        let ex (name : String) : Option String := (registry.ex? name).map (·.command)
        return bound "C-s-f" == some { command := "toggle-fullscreen" } &&
            bound "s-m" == some { command := "minimise-window" } &&
            bound "s-q" == some { command := Ex.quitName } &&
            ownedBy FrameCommands.package "toggle-fullscreen" &&
            ownedBy FrameCommands.package "minimise-window" &&
            ownedBy Ex.package Ex.quitName &&
            frameKeys == #["toggle-fullscreen", "minimise-window", Ex.quitName] &&
            ex "b" == some "switch-buffer" &&
            ex "ls" == some "list-buffers" &&
            ex "bd" == some "close-buffer" },
    { name :=
        "the executable's hosts start with every window command registered by the window-commands package, every command the Vim scheme's C-w table names among them"
      run := do
        let registry := shippedRegistry
        let compiled (name : String) : Bool :=
          (registry.find? name).any (·.owner == WindowCommands.package.owner)
        return !WindowCommands.package.registered.commands.isEmpty &&
            WindowCommands.package.registered.commands.all (compiled ·.name) &&
            Vim.Default.windowKeys.all (compiled ·.2) },
    { name :=
        "the executable's hosts start with every tab command registered by the tab-commands package, every command the Vim scheme's tab table names among them"
      run := do
        let registry := shippedRegistry
        let compiled (name : String) : Bool :=
          (registry.find? name).any (·.owner == TabCommands.package.owner)
        return !TabCommands.package.registered.commands.isEmpty &&
            TabCommands.package.registered.commands.all (compiled ·.name) &&
            Vim.Default.tabKeys.all (compiled ·.2) },
    { name :=
        "the executable's hosts start with the completion sources that ship each registered by its package, so config can ask for each by name: the ex line's history and its names, the tabs and the themes"
      run := do
        let registry := shippedRegistry
        let ownedBy (package : String) (name : String) : Bool :=
          registry.sources.any fun entry =>
            entry.source.name == name && entry.owner == ({ name := package } : Config.Owner)
        return [(Ex.package.name, Ex.historySource.name), (Ex.package.name, Ex.namesSource.name),
                (TabCommands.package.name, TabCommands.source.name),
                (Themes.package.name, Themes.source.name)].all
            fun (package, name) => ownedBy package name && (registry.source? name).isSome },
    { name :=
        "the executable's hosts start with nothing of the files package: no command open-file, save-buffer, edit-file, reload-buffer or auto-reload-mode, no job load-file, save-file, reload-file, check-files or follow-file, no source files, no source in the category file, and no value of files-api's Files, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return ["open-file", "save-buffer", "edit-file", "reload-buffer", "auto-reload-mode"].all
              (fun name => (registry.find? name).isNone) &&
            ["load-file", "save-file", "reload-file", "check-files", "follow-file"].all
              (fun name => (registry.findJob? name).isNone) &&
            (registry.source? "files").isNone &&
            registry.sourcesIn "file" == #[] &&
            !(registry.extensions.any (·.owner == owned "files")) },
    { name :=
        "the executable's hosts start with nothing of the shell package: no command shell-command, shell-filter or keyboard-quit, no job shell-run, no codec shell-history, and no codec or value of an interface registered by the shell, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return ["shell-command", "shell-filter", "keyboard-quit"].all
              (fun name => (registry.find? name).isNone) &&
            (registry.findJob? "shell-run").isNone &&
            !registry.codecs.any
                (fun (owner, codec) => owner == owned "shell" || codec.name == "shell-history") &&
            !(registry.extensions.any (·.owner == owned "shell")) },
    { name :=
        "the executable's hosts start with nothing of the project-search package: no command project-search, project-search-found, project-search-symbol or project-search-visit, no mode project-search, no job project-search or project-search-load, and no value of an interface, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return ["project-search", "project-search-found", "project-search-symbol",
                  "project-search-visit"].all
              (fun name => (registry.find? name).isNone) &&
            (registry.mode? "project-search").isNone &&
            ["project-search", "project-search-load"].all
              (fun name => (registry.findJob? name).isNone) &&
            !(registry.extensions.any (·.owner == owned "project-search")) },
    { name :=
        "the executable's hosts start with nothing of the working-set package: no command working-set-add, working-set-open, working-set-visit, working-set-remove, working-set-note or working-set-refresh, no mode working-set, no job working-set-files, working-set-load, working-set-write or working-set-save, and no value of an interface, files-api's Opened and Saved and buffers-api's Closing among them, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return ["working-set-add", "working-set-open", "working-set-visit", "working-set-remove",
                  "working-set-note", "working-set-refresh"].all
              (fun name => (registry.find? name).isNone) &&
            (registry.mode? "working-set").isNone &&
            ["working-set-files", "working-set-load", "working-set-write", "working-set-save"].all
              (fun name => (registry.findJob? name).isNone) &&
            !(registry.extensions.any (·.owner == owned "working-set")) },
    { name :=
        "the executable's hosts start with nothing of the workspace package: no command workspace-current, find-file-in-workspace, find-file-in-project or find-file-in-another-workspace, no job find-workspace, find-mode-markers, compile-list, workspace-files, project-workspaces, project-workspace-choose or project-workspace-find, no source workspace-files or project-workspaces, no source in the category workspace-file or project-workspace, no binding of find-file-in-another-workspace and none of C-x in the global keymap, and no value of an interface, project-api's Workspaces or files-api's Opened among them, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        let global : Keymap Invocation := registry.keymap TestScheme.scheme
        return ["workspace-current", "find-file-in-workspace", "find-file-in-project",
                  "find-file-in-another-workspace"].all
              (fun name => (registry.find? name).isNone) &&
            ["find-workspace", "find-mode-markers", Compile.listJob, "workspace-files",
                  "project-workspaces", "project-workspace-choose", "project-workspace-find"].all
              (fun name => (registry.findJob? name).isNone) &&
            (registry.source? "workspace-files").isNone &&
            (registry.source? "project-workspaces").isNone &&
            registry.sourcesIn "workspace-file" == #[] &&
            registry.sourcesIn "project-workspace" == #[] &&
            !registry.bindings.any (·.binding.command == "find-file-in-another-workspace") &&
            global.find? (keysOf "C-x") == none &&
            !global.continues (keysOf "C-x") &&
            !(registry.extensions.any (·.owner == owned "workspace")) },
    { name :=
        "the executable's hosts start with nothing of the buffers package: no command switch-buffer, list-buffers or close-buffer, no source buffers, no source in the category buffer, and no value of buffers-api's Buffers, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return ["switch-buffer", "list-buffers", "close-buffer"].all
              (fun name => (registry.find? name).isNone) &&
            (registry.source? "buffers").isNone &&
            registry.sourcesIn "buffer" == #[] &&
            !(registry.extensions.any (·.owner == owned "buffers")) },
    { name :=
        "the executable's hosts start with nothing of the execute-command package: no command execute-command, no source commands, and no source in the category command, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return (registry.find? "execute-command").isNone && (registry.source? "commands").isNone &&
            registry.sourcesIn "command" == #[] },
    { name :=
        "the executable's hosts start with nothing of the binding-search package: no command search-bindings, no source bindings, and no source in the category binding, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return (registry.find? "search-bindings").isNone && (registry.source? "bindings").isNone &&
            registry.sourcesIn "binding" == #[] },
    { name :=
        "the executable's hosts start with nothing of the completion package: no style, fuzzy, orderless or path among them, and no display, minibuffer among them, registered by a package of the core's Lake package, so every prompt, the file prompt's among them, is matched with the core's own style and drawn with the core's own display, the owner compiled's"
      run := do
        let registry := shippedRegistry
        let style := registry.styleEntry (some "file")
        let display := registry.displayEntry (some "file")
        return registry.styles.isEmpty && registry.displays.isEmpty &&
            ["fuzzy", "orderless", "path"].all (fun name => (registry.style? name).isNone) &&
            (registry.display? "minibuffer").isNone &&
            style.style.name == Completion.Style.unregistered.name &&
            style.owner == .compiled &&
            (registry.styleEntry none).style.name == Completion.Style.unregistered.name &&
            display.display.name == Completion.Display.unregistered.name &&
            display.owner == .compiled },
    { name :=
        "the executable's hosts start with the shipped sources of each shipped prompt's category the sources in the order of that prompt's defaults"
      run := do
        let registry := shippedRegistry
        return registry.sourcesIn "ex-line" == #[Ex.historySource.name, Ex.namesSource.name] &&
            registry.sourcesIn "tab" == #[TabCommands.source.name] &&
            registry.sourcesIn "theme" == #[Themes.source.name] },
    { name :=
        "the executable's hosts start with nothing of the compile mode: no command, ex name, job, mode or contribution of it is registered by a package of the core's Lake package, and compile as an ex name is not bound"
      run := do
        let registry := shippedRegistry
        let names :=
          ["compile", "compile-command", "recompile", "compile-confirm", "kill-compilation",
            "compilation-output", "next-error", "previous-error", "compile-goto-error"]
        return names.all (fun name => (registry.find? name).isNone) &&
            names.all (fun name => (registry.ex? name).isNone) &&
            (registry.findJob? "compile-run").isNone &&
            (registry.mode? "compilation").isNone &&
            registry.contributions.isEmpty },
    { name :=
        "the executable's hosts start with nothing of the minibuffer package: no command minibuffer-accept, minibuffer-cancel, minibuffer-next, minibuffer-previous, minibuffer-insert, minibuffer-delete-backward, minibuffer-delete-to-start, minibuffer-ask or minibuffer-candidates, and no mode minibuffer, the one the minibuffer's buffer is made with, registered by a package of the core's Lake package"
      run := do
        let registry := shippedRegistry
        return ["minibuffer-accept", "minibuffer-cancel", "minibuffer-next", "minibuffer-previous",
                  "minibuffer-insert", "minibuffer-delete-backward", "minibuffer-delete-to-start",
                  "minibuffer-ask", "minibuffer-candidates"].all
              (fun name => (registry.find? name).isNone) &&
            (registry.mode? "minibuffer").isNone &&
            (registry.mode? Prompt.mode).isNone },
    { name :=
        "the executable's hosts start with the command load-theme and the theme default, the built-in one, registered by the themes package, and no other theme: the packages of the core's Lake package ship no palette"
      run := do
        let registry := shippedRegistry
        return (registry.find? Themes.loadName).any (·.owner == Themes.package.owner) &&
            registry.theme? Theme.defaultName ==
              some { name := "default", theme := Theme.builtin } &&
            registry.themes.map (fun entry => (entry.named.name, entry.owner.name)) ==
              #[("default", "themes")] },
    { name :=
        "the executable's hosts publish the standard menu bar, and bind s-o, s-s, s-z, s-Z, s-x, s-c, s-v and s-a to open-file, save-buffer, undo, redo, clipboard-cut, clipboard-copy, clipboard-paste and select-all for the menu package, the edit commands the evil package's"
      run := do
        let registry := shippedRegistry
        let bound (text : String) : Option Invocation :=
          (registry.keymap TestScheme.scheme).find? (keysOf text)
        let ownedBy (package : Package) (name : String) : Bool :=
          (registry.find? name).any (·.owner == package.owner)
        let menuKeys :=
          (registry.bindings.filter (·.owner == Menu.package.owner)).map (·.binding.command)
        return registry.menuBar? == some (registry.menuOf Menu.standard) &&
            registry.menus.all (·.owner == Menu.package.owner) &&
            menuKeys ==
              #["open-file", "save-buffer", "undo", "redo", "clipboard-cut", "clipboard-copy",
                "clipboard-paste", "select-all"] &&
            bound "s-o" == some { command := "open-file" } &&
            bound "s-s" == some { command := "save-buffer" } &&
            bound "s-z" == some { command := "undo" } &&
            bound "s-Z" == some { command := "redo" } &&
            bound "s-x" == some { command := "clipboard-cut" } &&
            bound "s-c" == some { command := "clipboard-copy" } &&
            bound "s-v" == some { command := "clipboard-paste" } &&
            bound "s-a" == some { command := "select-all" } &&
            ["undo", "redo", "clipboard-cut", "clipboard-copy", "clipboard-paste", "select-all"].all
              (ownedBy Evil.package) }]

/-- A config whose `setup` registers `greet` and the job `follow`, which
watches the made-up file `/watched/f`, waits for its next delivery, and
finishes with a command that makes a text holding `version`, the config's. -/
def followText (version : String) : String :=
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

/-- A config of two files: `greet`, and a `setup` that registers it and the
job `follow` of version `v1`. -/
def followConfig : List (String × String) :=
  [("Config/Greet.lean", greetText "v1"), ("init.lean", overGreet (followText "v1"))]

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
          session.write "init.lean" (overGreet (followText "v2"))
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
                #["reload 1: installed, 2 files, 1 commands", "spawn follow: job 1",
                  "job 1 follow: cancelled", "reload 2: installed, 2 files, 1 commands"] &&
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
          session.write "Config/Greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
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
    writeConfig directory files
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

/-- A config whose `setup` sets the process environment to `setting`, written
as Lean. -/
def environmentText (setting : String) : String :=
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
        withEnvironments context [("init.lean", environmentText ".inherited")]
          fun session state _ => do
          state.set { entries := #[("/p/d", failedLookup)] }
          session.ask [.reload]
          let installed ← state.get
          state.modify fun held => { held with entries := #[("/p/d", failedLookup)] }
          session.write "init.lean" "def setup : SetupM Unit := oops"
          session.ask [.reload]
          let rejected ← state.get
          return installed.setting == .inherited && installed.entries.isEmpty &&
              rejected.setting == .inherited &&
              rejected.entries == #[(("/p/d" : System.FilePath), failedLookup)] },
    { name := "a config that does not set the process environment installs auto"
      run :=
        withEnvironments context [("init.lean", "def setup : SetupM Unit := pure ()")]
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

/-- The state directory of the restore checks, in the fake file service's
model. -/
def restoreState : System.FilePath :=
  "/state"

/-- The log of one journal by hand, of a buffer `note` whose base is
`hello`: it adds ` world`. -/
def journalledLog : ByteArray :=
  (Restore.Journal.Record.header { name := "note" }).bytes ++
    (Restore.Journal.Record.edits #[{ start := 5, stop := 5, inserted := " world" }]).bytes

/-- A model of files holding that journal, under `/state`. -/
def journalledModel : FileModel :=
  let model := (({} : FileModel).makeDirectory (Restore.journalsDirectory restoreState)).2
  (model.withFile (Restore.basePath restoreState 1 0 1) "hello".toUTF8).withFile
    (Restore.logPath restoreState 1 0 1) journalledLog

/-- Runs `check` against a host over a config directory holding `files`,
with the real elaborator, the packages `files` and `restore`, the state
directory `/state`, and a fake file service over `journalledModel`, which
the check is handed; and stops the host. -/
def withRestoreHost (context : Context) (files : List (String × String))
    (check : Headless.Host → IO.Ref (Array String) → Job.FakeFiles → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    let stage ←
      Stage.new context context.elaborator (Config.Directory.source directory)
          { packages := #[FilesApiTest.fake, Restore.package] }
    let fake ← Job.FakeFiles.new stage.collaborators.services.completions journalledModel
    let stage :=
      { stage with
        collaborators :=
          { stage.collaborators with
            stateDirectory := some restoreState
            services := { stage.collaborators.services with files := fake.files } } }
    onStage stage fun host stage => check host stage.output fake

/-- Runs `check` against a host over a config directory holding `files`,
with the real elaborator, the package `files` and the package `restore`
(or the one the check hands in its place), the library's file service
(`Stage.overFiles`) and journal, and a temporary state directory holding
that journal on disk, which the check is handed; and stops the host. -/
def withRestoreFiles (context : Context) (files : List (String × String))
    (check : Headless.Host → IO.Ref (Array String) → System.FilePath → IO Bool)
    (restore : Package := Restore.package) : IO Bool :=
  IO.FS.withTempDir fun directory =>
    IO.FS.withTempDir fun state => do
      writeConfig directory files
      IO.FS.createDirAll (Restore.journalsDirectory state)
      IO.FS.writeBinFile (Restore.basePath state 1 0 1) "hello".toUTF8
      IO.FS.writeBinFile (Restore.logPath state 1 0 1) journalledLog
      let stage ←
        Stage.overFiles context (Config.Directory.source directory)
            { packages := #[FilesApiTest.fake, restore] }
      let stage :=
        { stage with
          collaborators :=
            { stage.collaborators with
              stateDirectory := some state
              journal := Headless.Journal.real stage.collaborators.published.reader } }
      onStage stage fun host stage => check host stage.output state

/-- A package that declares the store `counted` of a number, at `version`,
whose migration doubles a version-1 number, keeps it across a restart, and
registers `bump-counted`, which adds one. -/
def countedPackage (version : Nat) : Package :=
  let counted : Store Nat :=
    { name := "counted", version, initial := 0, encode := .nat
      decode := fun
        | .nat n => some n
        | _ => none
      migrate := fun old tree =>
        match old, tree with
        | 1, .nat n => some (.nat (2 * n))
        | _, _ => none }
  { name := "counter"
    setup := do
      counted.declare
      counted.keptAcrossRestart
      counted.command "bump-counted" fun n => pure (n + 1) }

/-- A config that declares the store `kept` of a number, keeps it across a
restart, and registers `bump-kept`, which adds one. -/
def keptConfig : List (String × String) :=
  [("init.lean",
      "def kept : Store Nat :=
  { name := \"kept\", version := 1, initial := 0, encode := .nat,
    decode := fun
      | .nat n => some n
      | _ => none }

def setup : SetupM Unit := do
  kept.declare
  kept.keptAcrossRestart
  kept.command \"bump-kept\" fun n => pure (n + 1)
")]

/-- A config whose `setup` throws, as one that cannot go on might. -/
def throwingConfig : List (String × String) :=
  [("init.lean", "def setup : SetupM Unit := throw \"no config today\"\n")]

/-- Runs `check` against a host over a config directory holding `files`,
with the real elaborator, the packages `files`, `restore` and `packages`,
the library's file service and journal, and the state directory `state`,
which outlives it; and stops the host, uncleanly: its session is left to
the next. -/
def withStateHost (context : Context) (state : System.FilePath) (files : List (String × String))
    (packages : Array Package)
    (check : Headless.Host → Stage Config.Elaborate.Base Config.Elaborate.Handle → IO Bool) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    let stage ←
      Stage.overFiles context (Config.Directory.source directory)
          { packages := #[FilesApiTest.fake, Restore.package] ++ packages }
    let stage :=
      { stage with
        collaborators :=
          { stage.collaborators with
            stateDirectory := some state
            journal := Headless.Journal.real stage.collaborators.published.reader } }
    onStage stage fun host stage => check host stage

/-- Waits until the host has written the session index: each write's delay
moved past on the stage's clock, until neither a write nor a save is
running. A write the host started after the last one rendered, for a change
its publish had not seen yet, is waited for too. -/
def indexWritten {β σ : Type} (host : Headless.Host) (stage : Stage β σ) : IO Bool := do
  for _ in [0:4] do
    unless ← Headless.within patience (stage.clock.dueWithin Restore.writeDelay) do
      return false
    stage.clock.advance Restore.writeDelay
    if (← host.waitWhile 300 (fun progress => progress.indexing) .working) == .settled then
      return true
  return false

/-- The text of the highest run's index under `state`, if there is one. -/
def lastIndex (state : System.FilePath) : IO (Option String) := do
  let names :=
    (← (Restore.sessionDirectory state).readDir).filterMap fun entry =>
      Restore.runOfIndex? entry.fileName
  let some run := names.foldl (fun found run => some ((found.getD run).max run)) none | return none
  return some (← IO.FS.readFile (Restore.indexPath state run))

/-- The index of the first line of `lines` that `holds`, if one does. -/
def firstLine? (lines : Array String) (holds : String → Bool) : Option Nat :=
  lines.findIdx? holds

/-- A package that stands in for `restore`: its job `restore` fails at once,
as a restore that cannot go on might. -/
def failingRestore : Package :=
  { name := "failing-restore"
    setup := workJob Restore.restoreJob fun _ _ => throw "the session cannot be read" }

/-- Whether `line` is a scene's line whose echo area says `text`. -/
def echoes (text : String) (line : String) : Bool :=
  line.startsWith "scene " && (line.splitOn s!", echo {text.quote}, echo padding ").length == 2

/-- A host over a config directory holding `files`, with the packages
`files` and `restore`, the library's file service, a temporary state
directory, a launch whose running executable passes the probe (the process
service a fake over that reply), and a journal whose failure readout
answers one more failure of one path at each read once `failing` is set, so
it is said once and counted at every read: what `check` is handed, with
the flag; and the host is stopped. -/
def withFailingJournal (context : Context) (files : List (String × String))
    (check : Headless.Host → IO.Ref (Array String) → IO.Ref Bool → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory =>
    IO.FS.withTempDir fun state => do
      writeConfig directory files
      let stage ←
        Stage.overFiles context (Config.Directory.source directory)
            { packages := #[FilesApiTest.fake, Restore.package] }
      let running : System.FilePath := "/A.app/Contents/MacOS/editor"
      let processes ←
        Job.FakeProcesses.new stage.collaborators.services.completions
            {
              scripts :=
                #[{ command := Restore.probeCommand running
                    reply :=
                      .ok { exit := .code 0, stdout := "probe: ok\n".toUTF8, stderr := .empty } }] }
      let failing ← IO.mkRef false
      let real := Headless.Journal.real stage.collaborators.published.reader
      let journal : Headless.Journal :=
        { real with
          failures := do
            let taken ← real.failures
            if ← failing.get then
              return taken.push ("/journal/full", "the disk is full")
            return taken }
      let stage :=
        { stage with
          collaborators :=
            { stage.collaborators with
              stateDirectory := some state, journal
              launch := { running := some running, shipped := some running }
              services := { stage.collaborators.services with processes := processes.processes } } }
      onStage stage fun host stage => check host stage.output failing

/-- The checks of the restore at start-up in the host (`Editor/Headless.lean`,
"Restoring a session"), on the real elaborator: it runs before the start-up
reload, which it holds, and `await` waits for it; a restore whose job fails
releases what it held. The first and the last are over the library's file
service and share `fileChecks`' table of waits, so these run after them. -/
def restoreOrderChecks (context : Context) : List Check :=
  [{  name :=
        "a restore that names the index a restart handed over holds the start-up reload as an unnamed one does: its second half runs before reload 1 is installed"
      run :=
        withRestoreFiles context greetConfig fun host output state => do
          host.send (.restore (some (Restore.indexPath state 1)))
          host.send .reload
          unless ← host.settle patience do
            return false
          let lines ← output.get
          let restored :=
            firstLine? lines fun line =>
              line.startsWith "job " && (line.splitOn s!" {Restore.filesJob}: ok").length == 2
          let installed := firstLine? lines (·.startsWith "reload 1: installed")
          return match restored, installed with
            | some restored, some installed => restored < installed
            | _, _ => false },
    { name :=
        "a hand-over after a journal order failed since the restart began is given up: restart-abandon says the failure, and the loop goes on with no plan"
      run :=
        withFailingJournal context greetConfig fun host output failing => do
          host.send (.restore none)
          unless ← host.settle patience do
            return false
          failing.set true
          host.send (.run Editor.restartName)
          -- The debounced index write sleeps on the stage's clock, which
          -- nothing moves, so the wait is for the save's command.
          let saved ←
            Headless.within patience do
                return (← output.get).any (·.endsWith s!"{Restore.restartSaveJob}: ok")
          unless saved do
            return false
          host.send .scene
          unless ← host.settle patience do
            return false
          let lines ← output.get
          let progress ← host.progress.get
          return progress.handOver.isNone && !(← IO.hasFinished host.thread) &&
              lines.any fun line =>
                echoes
                  "restart: a journal write failed (/journal/full); the session was not handed over"
                  line },
    { name :=
        "a host with a session and a config restores first: the restore's second half has run, and the buffer it restored is there, before reload 1 is installed"
      run :=
        withRestoreFiles context greetConfig fun host output _ => do
          host.send (.restore none)
          host.send .reload
          unless ← host.settle patience do
            return false
          host.send .show
          unless ← host.settle patience do
            return false
          let lines ← output.get
          let restored :=
            firstLine? lines fun line =>
              line.startsWith "job " && (line.splitOn s!" {Restore.filesJob}: ok").length == 2
          let installed := firstLine? lines (·.startsWith "reload 1: installed")
          let shown := firstLine? lines fun line => (line.splitOn "\"hello world\"").length == 2
          return match restored, installed, shown with
            | some restored, some installed, some _ => restored < installed
            | _, _, _ => false },
    { name :=
        "a reload sent while the restore is in flight is held, and await does not answer settled, until the restore has finished"
      run :=
        withRestoreHost context greetConfig fun host output fake => do
          let hold ← fake.holdTakes
          host.send (.restore none)
          host.send .reload
          let waited ← host.await 300
          let early := (← output.get).any (·.startsWith "reload 1")
          hold.resolve ()
          let settled ← host.settle patience
          let late := (← output.get).any (·.startsWith "reload 1: installed")
          return waited == .reloading && !early && settled && late },
    { name :=
        "a restore whose job fails releases the requests it held, in order: the file given is opened, the text said, and reload 1 installed, so setup has run; and await answers settled"
      run :=
        withRestoreFiles context helloConfig (restore := failingRestore) fun host output state => do
          let notes := state / "notes.txt"
          IO.FS.writeFile notes "notes"
          host.send (.restore none)
          host.send (.open notes.toString)
          host.send (.say "held words")
          host.send .reload
          let waited ← host.await patience
          let joined ← host.join patience
          host.send .scene
          host.send .show
          unless ← host.settle patience do
            return false
          let lines ← output.get
          let failed :=
            firstLine? lines fun line =>
              line.startsWith "job " && (line.splitOn s!" {Restore.restoreJob}: failed").length == 2
          let installed := firstLine? lines (·.startsWith "reload 1: installed")
          let opened :=
            lines.any fun line => line.startsWith "text " && line.endsWith s!": {"notes".quote}"
          let said := lines.any (echoes "held words")
          let registered :=
            lines.any fun line => line.startsWith "commands:" && (line.splitOn " ").contains "greet"
          return waited == .settled && joined == .settled && opened && said && registered &&
              match failed, installed with
              | some failed, some installed => failed < installed
              | _, _ => false },
    { name :=
        "a package's declared store kept across a restart, end to end: bumped twice and left uncleanly, the next host shows it before any reload, since packages register before the restore; a host handed the package at version 2 shows it migrated"
      run :=
        IO.FS.withTempDir fun state => do
          let first ←
            withStateHost context state [] #[countedPackage 1] fun host stage => do
                host.send (.restore none)
                host.send (.run "bump-counted")
                host.send (.run "bump-counted")
                unless ← host.settle patience do
                  return false
                indexWritten host stage
          let shown (version : Nat) (line : String) :=
            withStateHost context state [] #[countedPackage version] fun host stage => do
              host.send (.restore none)
              host.send .show
              unless ← host.settle patience do
                return false
              return (← stage.output.get).contains line
          let second ← shown 1 "store counted v1: 2"
          let third ← shown 2 "store counted v2: 4"
          return first && second && third },
    { name :=
        "a config's store kept across a restart: the start-up reload restores it; a config whose setup throws keeps it parked, and the index written after still lists it; a later good reload claims it"
      run :=
        IO.FS.withTempDir fun state => do
          let first ←
            withStateHost context state keptConfig #[] fun host stage => do
                host.send (.restore none)
                host.send .reload
                unless ← host.settle patience do
                  return false
                host.send (.run "bump-kept")
                host.send (.run "bump-kept")
                unless ← host.settle patience do
                  return false
                indexWritten host stage
          let restored ←
            withStateHost context state keptConfig #[] fun host stage => do
                host.send (.restore none)
                host.send .reload
                unless ← host.settle patience do
                  return false
                host.send .show
                unless ← host.settle patience do
                  return false
                return (← stage.output.get).contains "store kept v1: 2"
          let thrown ←
            withStateHost context state throwingConfig #[] fun host stage => do
                host.send (.restore none)
                host.send .reload
                unless ← host.settle patience do
                  return false
                unless ← indexWritten host stage do
                  return false
                let index ← lastIndex state
                return index.any fun text => (text.splitOn "\"name\":\"kept\"").length == 2
          let claimed ←
            withStateHost context state keptConfig #[] fun host stage => do
                host.send (.restore none)
                host.send .reload
                unless ← host.settle patience do
                  return false
                host.send .show
                unless ← host.settle patience do
                  return false
                return (← stage.output.get).contains "store kept v1: 2"
          return first && restored && thrown && claimed }]

/-- A journal (`Headless.Journal`) whose orders do nothing and whose
failures are what the check put in `failed` since the host last took them,
as the library's file service keeps them. -/
def keptFailures (failed : IO.Ref (Array (String × String))) : Headless.Journal where
  failures := failed.modifyGet fun held => (held, #[])

/-- A command that does nothing: a step of the loop, after which the host
takes the journal's failures. -/
def stepCommand : Config.Registration :=
  { name := "step", action := .plain (pure ()) }

/-- Runs `check` against a host with no config and the command `step`,
whose journal is `keptFailures` over a cell the check is handed, empty;
and stops the host. -/
def withJournalHost (context : Context)
    (check : Session → IO.Ref (Array (String × String)) → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let failed ← IO.mkRef #[]
    let stage ←
      Stage.new context context.elaborator (Config.Directory.source directory)
          { commands := #[stepCommand] }
    let stage :=
      { stage with collaborators := { stage.collaborators with journal := keptFailures failed } }
    onStage stage fun host stage =>
        check
          { host, directory, output := stage.output, threads := stage.threads, clock := stage.clock,
            watches := stage.watches, log := stage.log }
          failed

/-- The checks of the journal's failures in the host (`Editor/Headless.lean`,
"Restoring a session", `Running.journalFailed`): what the file service kept
of the orders it was handed is taken after each step, and said once for each
path, in the echo area and to the log. -/
def journalFailureChecks (context : Context) : List Check :=
  [{  name :=
        "the journal's failures are taken after a step and said once for each path, in the echo area and to the log; a later failure of a path already said is taken and not said"
      run :=
        withJournalHost context fun session failed => do
          failed.set #[("/state/a", "denied"), ("/state/a", "gone"), ("/state/b", "denied")]
          session.ask [.run "step"]
          let taken := (← failed.get).isEmpty
          let (echo, _) ← session.scene
          let logged := (← session.log.get).filter (·.startsWith "journal: ")
          failed.set #[("/state/a", "denied again"), ("/state/c", "full")]
          session.ask [.run "step"]
          let takenAgain := (← failed.get).isEmpty
          let (echoAgain, _) ← session.scene
          let loggedAgain := (← session.log.get).filter (·.startsWith "journal: ")
          return taken && echo == "journal: /state/b: denied".quote &&
              logged == #["journal: /state/a: denied", "journal: /state/b: denied"] &&
              takenAgain &&
              echoAgain == "journal: /state/c: full".quote &&
              loggedAgain == logged.push "journal: /state/c: full" }]

end ConfigTest
