import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Gate
import ConfigTest.Support.Shipped
import Editor.Api
import Editor.Appearance
import Editor.Clipboard.InProcess
import Editor.Command
import Editor.Command.Call
import Editor.Completion
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
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Counter
import Editor.Ffi.Events
import Editor.File
import Editor.FileWatch
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.InputScheme
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Fake
import Editor.Job.Jobs
import Editor.Job.Runner
import Editor.Job.Table
import Editor.Language
import Editor.Layout
import Editor.Loop
import Editor.Menu
import Editor.Mode
import Editor.ModeLine
import Editor.Package
import Editor.Process.Environment
import Editor.Program
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.SyntaxTree
import Editor.TabBar
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Linked.Shipped
import Editor.Test.Restore
import Editor.Text
import Editor.Text.Model
import Editor.Text.Real
import Editor.Window
import Editor.Window.Real
import Editor.Workspace
import FilesApiTest.Fake

/-!
# Config tests: `Editor/Headless.lean`

The tests of `Editor/Headless.lean`: `hostChecks`, `threadChecks` (with `Gate`),
`jobChecks`, `idleChecks`, `agreementChecks`, `scriptChecks`, `hostLoopChecks`,
`exScriptChecks`, `reloadEchoChecks`, `shippedChecks`, `watchReloadChecks`,
`environmentHostChecks`, `restoreOrderChecks` and `journalFailureChecks`. The
root module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- Runs `check` against a stepped host started over `elaborator` and
`source` (`staged`), with its output in a buffer `check` is handed. `false`
if the check did not hold or the host did not settle. -/
def hosted {β σ : Type} (context : Context) (elaborator : Config.Elaborator β σ)
    (source : Config.Source) (check : Driven → IO.Ref (Array String) → IO Bool) : IO Bool :=
  staged context elaborator source fun drive stage => check drive stage.output

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
        return registry.ownersByKind.size == 18 && registry.ownersByKind.all (·.isEmpty) &&
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
              unless ← host.settle hangGuard do
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

/-- `slowConfig` as modules held in memory (`memorySource`). -/
def slowModules : List (String × String) :=
  [("Config.Greet", greetText "v1"), ("Config.Slow", slowText), ("init", overSlow)]

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

/-- A root that imports `Lean` and defines `greet`, which makes a text of a
value of Lean's own (`Lean.Json`): a config file that first imports `Lean`
makes the base grow for it. -/
def leanGreetText : String :=
  importing ["Lean"]
    "def greet : EditorM Unit := do\n  discard <| createText (Lean.Json.arr #[Lean.Json.str \"v2\"]).compress\n"

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
          session.write "init.lean" (leanGreetText ++ setupText)
          session.ask [.reload]
          session.ask [.run "greet", .show]
          return (← session.output.get) ==
              #["reload 1: installed, 1 files, 1 commands",
                "reload 2: installed, 1 files, 1 commands", "run greet: ok", "commands: greet",
                "text 0: \"\"", "text 1: \"[\\\"v2\\\"]\""] },
    { name :=
        "a settle after a reload whose root first imports Lean waits for the reload's end: the reload is held at the gate until the settle is waiting on it, and the settle answers once it has installed"
      run := do
        -- The gate holds the root, `init`, before the real elaboration of
        -- its `import Lean`, and opens only once the settle has blocked on
        -- the running reload: the elaboration then runs for however long
        -- it takes, and only a hang would reach the settle's guard. No
        -- guard is 0, and the loop's end keeps its own.
        let gate ← Gate.new (module := "init")
        let said ← IO.mkRef (#[] : Array String)
        let held ←
          withHostOver context [("init.lean", leanGreetText ++ setupText)] gate.around id
              (waitHung := fun line => said.modify (·.push line)) (waitBlocked := fun what => do
              if what == "running work" then
                gate.open)
              fun session => do
              -- Opened as the body ends too, so a failing run leaves no
              -- reload held for the loop's end to wait on.
              try
                session.ask [.reload]
                session.ask [.run "greet"]
                let output ← session.output.get
                return output == #["reload 1: installed, 1 files, 1 commands", "run greet: ok"]
              finally
                gate.open
        let said ← said.get
        let holding ← gate.holding.get
        saw (held && said.isEmpty && holding) s!"held={held} said={said} holding={holding}" }]

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
  [{  name :=
        "reloads are serialised: requests made while a job runs make one more job, never two at once, and it reads the source afresh"
      run := do
        -- Seen to bite once by hand: a host that starts a job for every
        -- request, running or not, fails this.
        let gate ← Gate.new
        let reads ← IO.mkRef 0
        withHostOver context (slowConfig) gate.around (counting reads) fun session => do
            session.send .reload
            try
              unless ← session.handled do
                return false
              unless (← Job.awaitWithin hangGuard gate.arrived.result?).isSome do
                return false
              session.write "Config/Greet.lean" (greetText "v2")
              session.send .reload
              session.send .reload
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
                unless ← host.settle hangGuard do
                  return false
              -- The base and the handles of three files. A finished job's
              -- task may still be going away, so its free is waited on, and
              -- the count then read once.
              return (← Ffi.Counter.awaitLive (before + 4) hangGuard) &&
                  (← Ffi.Counter.live) == before + 4
        let freed ← Ffi.Counter.awaitLive before hangGuard
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

/-- Runs `check` against a stepped host over a config of `highlightText`,
on a stepped stage (`Stage.stepped`) whose syntax tree is the stage's fake
of the syntax service (`Stage.fakeSyntaxService`), with every request the
host hands it recorded (`recordedRequest`) in the array the check is handed:
the requests are the subject, and the fake records them on the check's
thread, its deliveries stepped with the session (`Session.step`). -/
def withRecordedSyntaxTree (context : Context) (check : Session → IO.Ref (Array String) → IO Bool) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory [("init.lean", highlightText)]
    let stage ← (← Stage.new context context.elaborator (Config.Directory.source directory)).stepped
    let (stage, fake) ← stage.fakeSyntaxService
    let asked ← IO.mkRef #[]
    let recorded : SyntaxTreeHandler := fun request => do
      asked.modify (·.push (recordedRequest request))
      fake.handle request
    let stage :=
      { stage with
        collaborators := { stage.collaborators with syntaxTree := fun _ => pure recorded } }
    onStage stage fun drive stage => check (Session.ofStage drive directory stage) asked

/-- The thread that emitted the first line of the host's output that is
`line`, if there is one. -/
def _root_.Editor.Test.Linked.Session.threadOf (session : Session) (line : String) :
    IO (Option UInt64) := do
  let lines ← session.output.get
  let threads ← session.threads.get
  return (lines.idxOf? line).bind fun index => threads[index]?

/-- Runs `check` with `hold`, which holds the first thread that calls it until
`letGo`, and `letGo`; lets go before it returns, whatever `check` did. A
thread that calls `hold` after the first, or after `letGo`, passes. No sleep
and no task of its own: what lets go is an event the check names. -/
def holdingUntil {α : Type} (check : BaseIO Unit → BaseIO Unit → IO α) : IO α := do
  let release ← IO.Promise.new
  let entered ← IO.mkRef false
  try
    check
        (do
          unless ← entered.modifyGet fun entered => (entered, true) do
            discard <| IO.wait release.result?)
        (release.resolve ())
  finally
    release.resolve ()

/-- `stage`'s collaborators, with the editor thread held (`hold`) inside the
first line of the host's output that starts with `commands:`, which a
`show` prints, and `entered` resolved as it gets there. -/
def heldAtCommands {β σ : Type} (stage : Stage β σ) (hold : BaseIO Unit)
    (entered : IO.Promise Unit) : Headless.Collaborators β σ TestScheme.scheme :=
  { stage.collaborators with
    emit := fun line => do
      if line.startsWith "commands:" then
        entered.resolve ()
        hold
      stage.collaborators.emit line }

/-- `collaborators`, with the editor thread held (`hold`) inside each line of
the host's output that `holds` accepts. -/
def heldAtLine {β σ : Type} {scheme : InputScheme}
    (collaborators : Headless.Collaborators β σ scheme) (holds : String → Bool)
    (hold : BaseIO Unit) : Headless.Collaborators β σ scheme :=
  { collaborators with
    emit := fun line => do
      if holds line then
        hold
      collaborators.emit line }

/-- The script of a run that reaches its end with a job in its wait: a reload
of `jobsConfig`, settled, and a spawn of `count`. -/
def jobScript : Array Headless.Line :=
  #[⟨1, .request .reload⟩, ⟨2, .settle⟩, ⟨3, .request (.spawn "count")⟩]

/-- The job `count` of `jobsText`, written in Lean: it sleeps 10 ms and its
result, 42, is made into a text. A host handed it has a job to spawn with no
config to elaborate. -/
def countJob : Config.JobRegistration :=
  { name := "count"
    work := fun _ =>
      Work.of
        (fun _ => do
          sleep 10
          return 42)
        fun n => discard <| createText s!"counted {n}" }

/-- A job `load` written in Lean: it loads a file that is not there and
finishes with a command that does nothing. On a file service whose
completions are held, it waits in its load for good. -/
def loadJob : Config.JobRegistration :=
  { name := "load"
    work := fun _ => Work.of (fun _ => File.load "/nowhere/at-all" 100) fun _ => pure () }

/-- Runs `check` with a hold for the editor thread (`hold`) and a wait's
`waitBlocked` hook (`blocked`) that meet: the hold, called on the editor
thread inside an event, lets the thread go once a wait has said it blocks
on the editor thread's answer (`"answer"`), and a wait that says so while
the thread is held lets it go. Whichever comes first, the thread is let go
once both have happened, and never by time. `letGo` lets it go whatever
happened, for a backstop; it is let go before this returns. -/
def meetingAnswer {α : Type} (check : BaseIO Unit → (String → IO Unit) → BaseIO Unit → IO α) :
    IO α := do
  let release ← IO.Promise.new
  -- Whether the editor thread has reached the hold, and whether a wait has
  -- blocked on its answer.
  let met ← IO.mkRef (false, false)
  try
    check
        (do
          let blocked ← met.modifyGet fun (_, blocked) => (blocked, (true, blocked))
          unless blocked do
            discard <| IO.wait release.result?)
        (fun what => do
          if what == "answer" then
            let entered ← met.modifyGet fun (entered, _) => (entered, (entered, true))
            if entered then
              release.resolve ())
        (release.resolve ())
  finally
    release.resolve ()

/-- `Headless.awaitIndexed` over a wait the check scripts: the waits answer
`answers` in turn, and `unanswered` once they have run out, and each
`working` reads `progress`. What it answered, and the kinds of the waits it
asked for, in order. No host and no thread: the loop alone. -/
def scriptedIndexed (answers : Array Headless.Wait) (progress : Headless.Progress)
    (clock : Option Job.FakeClock) : IO (Headless.Wait × Array String) := do
  let asked ← IO.mkRef (#[] : Array String)
  let answer ←
    Headless.awaitIndexed
        (fun kind => do
          let n ← asked.modifyGet fun asked => (asked.size, asked.push kind.what)
          return answers.getD n .unanswered)
        (pure progress) clock
  return (answer, ← asked.get)

/-- A fake clock with one wait in its sleep, due at `Restore.writeDelay`: an
index write's sleep, as `awaitIndexed` sees it. -/
def writeAsleep : IO Job.FakeClock := do
  let clock ← Job.FakeClock.new (← Job.Completions.new)
  clock.start 1 Restore.writeDelay
  return clock

/-- A config whose job `nap` sleeps 10 ms on the clock, and whose command
`start-nap` starts it: a background job, one the script did not spawn. -/
def napConfig : List (String × String) :=
  [("init.lean",
      "def nap : Unit → JobM Nat := fun _ => do
  sleep 10
  return 1

def setup : SetupM Unit := do
  job \"nap\" nap fun _ => pure ()
  command \"start-nap\" (discard <| startJob \"nap\")
")]

/-- A check of `jobChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def handlerReceivesJobResultCheck (context : Context) : Check :=
  {
    name :=
      "a handler receives a job's result on the editor thread: the job's line is printed by the thread that prints a command's, after the clock lets the job go, and the handler's text is there",
    run :=
      -- Seen to bite once by hand: a host that prints a job's line where
      -- the job ended, from the runner's `finished`, prints it from a pool
      -- thread, and the thread ids differ.
      withHost context jobsConfig fun session => do
        session.ask [.reload]
        session.ask [.run "greet", .spawn "count"]
        session.step
        unless (← session.clock.waiting) == 1 do
          return false
        -- The job is in its sleep: nothing has been said of its result, and
        -- the editor still answers.
        session.ask [.run "greet"]
        let waiting ← session.output.get
        session.clock.advance 10
        session.step
        session.ask [.show]
        let command ← session.threadOf "run greet: ok"
        let handler ← session.threadOf "job 1 count: ok"
        return waiting ==
              #["reload 1: installed, 2 files, 1 commands", "run greet: ok", "spawn count: job 1",
                "run greet: ok"] &&
            (← session.output.get) ==
              waiting ++
                #["job 1 count: ok", "commands: greet", "text 0: \"\"", "text 1: \"v1\"",
                  "text 2: \"v1\"", "text 3: \"counted 42\""] &&
            command.isSome &&
            handler == command &&
            command == some (← IO.getTID) }

/-- A check of `jobChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def reloadCancelsOldConfigCheck (context : Context) : Check :=
  { name :=
      "a reload cancels the old config's jobs when it installs: the job is cancelled before the reload is reported, its wait is withdrawn, and its handler never runs"
    run :=
      withHost context jobsConfig fun session => do
        session.ask [.reload]
        session.ask [.spawn "count"]
        session.step
        unless (← session.clock.waiting) == 1 do
          return false
        session.write "Config/Greet.lean" (greetText "v2")
        session.ask [.reload]
        let withdrawn ← session.clock.withdrawn
        -- Past the job's sleep: a job that was still there would end, and
        -- its handler would make a text.
        session.clock.advance 10
        session.step
        session.ask [.show]
        return withdrawn.size == 1 && (← session.clock.waiting) == 0 &&
            (← session.output.get) ==
              #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1",
                "job 1 count: cancelled", "reload 2: installed, 2 files, 1 commands",
                "commands: greet"] }

/-- A check of `jobChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def rejectedReloadCancelsNothingCheck (context : Context) : Check :=
  { name :=
      "a rejected reload cancels nothing: the old config's job runs on, and its handler runs when it finishes"
    run :=
      withHost context jobsConfig fun session => do
        session.ask [.reload]
        session.ask [.spawn "count"]
        session.step
        unless (← session.clock.waiting) == 1 do
          return false
        session.write "Config/Greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
        session.ask [.reload]
        let stillWaiting := (← session.clock.waiting) == 1 && (← session.clock.withdrawn).isEmpty
        session.clock.advance 10
        session.step
        return stillWaiting &&
            (← session.lines) ==
              #["reload 1: installed, 2 files, 1 commands", "spawn count: job 1",
                "reload 2: rejected", "diagnostic: Config/Greet.lean: error", "job 1 count: ok"] }

/-- A check of `jobChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def jobThrowsReportedFailedCheck (context : Context) : Check :=
  { name :=
      "a job that throws is reported as failed with its message, a handler whose command the library refuses as refused, and a name that is not registered as no such job"
    run :=
      withHost context jobsConfig fun session => do
        session.ask [.reload]
        session.ask [.spawn "boom", .spawn "bad", .spawn "nope"]
        session.step
        unless (← session.clock.waiting) == 2 do
          return false
        let spawned ← session.output.get
        session.clock.advance 10
        session.step
        -- The two jobs end at one instant, in either order.
        let ended := ((← session.output.get).extract spawned.size).qsort (· < ·)
        return spawned ==
              #["reload 1: installed, 2 files, 1 commands", "spawn boom: job 1", "spawn bad: job 2",
                "spawn nope: no such job"] &&
            ended == #["job 1 boom: failed: no thanks", "job 2 bad: refused: no such text"] }

/-- A check of `jobChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def jobCommandSetsModeCheck (context : Context) : Check :=
  { name :=
      "a job's command that sets a mode with a syntax tree reaches the host's syntax tree: the refresh delay handed over, the text attached, the grammar's shipped query compiled and its text highlighted in the default faces, and the grammar's injections, text objects and indents asked for, none of which json ships"
    run :=
      -- Seen to bite once by hand: with `Running.ended` handing
      -- `Job.finishWith` no syntax tree, the job's command reaches
      -- `SyntaxTree.none`, the recorder sees nothing, and the echo area
      -- says the attach was refused. The requests are the subject, so the
      -- syntax tree is the stage's fake (`withRecordedSyntaxTree`).
      withRecordedSyntaxTree context fun session asked => do
        session.ask [.reload]
        session.ask [.spawn "highlight"]
        session.step
        unless (← session.clock.waiting) == 1 do
          return false
        session.clock.advance 10
        session.step
        let scene ← session.sceneLines
        return (← session.output.get).contains "job 1 highlight: ok" &&
            (← asked.get) ==
              #["refreshAfter 500", "attach json", "shippedQuery json highlights", "compile json",
                "captureNames",
                -- The faces of the syntax model's json query's captures, which
                -- the fake answers, in the shipped defaults.
                "highlight syntax.string, syntax.string, syntax.number, syntax.constant", "release",
                "shippedQuery json injections", "shippedQuery json textObjects",
                "shippedQuery json indents"] &&
            scene.any fun line =>
              line.startsWith "scene " && (line.splitOn "highlights:").length == 1 }

/-- The checks of jobs through the headless host (`Editor/Headless.lean`),
with the real elaborator, the real queue and the real text binding. The
host's jobs wait on a fake clock the check moves, so a job ends when the
check says, and never because time passed. -/
def jobChecks (context : Context) : List Check :=
  [handlerReceivesJobResultCheck context, reloadCancelsOldConfigCheck context,
    rejectedReloadCancelsNothingCheck context, jobThrowsReportedFailedCheck context,
    { name :=
        "an indexed's wait at idle with a write of the index in its sleep and no other job running moves the clock past the write's delay once and waits again"
      run := do
        let clock ← writeAsleep
        let (answer, asked) ←
          scriptedIndexed #[.working, .settled] { indexing := true, background := 0 } (some clock)
        let now ← clock.now
        saw (answer == .settled && asked == #["indexed", "indexed"] && now == Restore.writeDelay)
            s!"answer={repr answer} asked={asked} now={now}" },
    { name :=
        "an indexed's wait at idle with a background job running answers working, the clock not moved, even with a write of the index in its sleep"
      run := do
        let clock ← writeAsleep
        let (answer, asked) ←
          scriptedIndexed #[.working, .settled] { indexing := true, background := 1 } (some clock)
        let now ← clock.now
        saw (answer == .working && asked == #["indexed"] && now == 0)
            s!"answer={repr answer} asked={asked} now={now}" },
    { name := "an indexed's wait at idle on a host with no fake clock answers working"
      run := do
        let (answer, asked) ←
          scriptedIndexed #[.working, .settled] { indexing := true, background := 0 } none
        saw (answer == .working && asked == #["indexed"]) s!"answer={repr answer} asked={asked}" },
    { name :=
        "spawn, join and installed are directives of a script, join, restarted and indexed with an optional patience in seconds, a spawn with no name, an installed with anything after it and a patience that is no number are refused, the error message of a line that is no directive lists installed, and a join that ran out is described with its line"
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
            (Headless.script "reload\n installed \n").toOption ==
              some #[⟨1, .request .reload⟩, ⟨2, .installed⟩] &&
            (refusal "installed now\n").startsWith "line 1: " &&
            ((refusal "wait\n").splitOn " installed,").length == 2 &&
            (refusal "indexed soon\n").startsWith "line 1: " &&
            (refusal "join soon\n").startsWith "line 1: " &&
            (refusal "restarted x\n").startsWith "line 1: " &&
            (refusal "reload\nspawn\n").startsWith "line 2: " &&
            (working.splitOn "line 12").length == 2 &&
            working != Headless.Failure.describe 30000 (.reloading (some 12)) &&
            working != Headless.Failure.describe 30000 (.unanswered (some 12))) },
    jobCommandSetsModeCheck context]

/-- `host`'s activity count once it reads `running`, waited for on the
count's own changes (`Job.Activity.changedSince`), never on time. The bound
is a hang guard: past it this throws a hang. -/
def countReaches (host : Headless.Host) (running : Nat) : IO Job.Activity.Seen := do
  unless host.activity.tracked do
    throw <| IO.userError "the host keeps no count of its activity"
  repeat
    let seen ← host.activitySeen
    if seen.running == running then
      return seen
    let some () ← Job.awaitWithin hangGuard (← host.activity.changedSince seen.epoch) |
      throw <|
          IO.userError
            s!"a hang: the host's count stayed at {seen.running}, not {running}, for {hangGuard.ms} ms"
  throw <| IO.userError "unreachable"

/-- `collaborators`, with the editor thread held (`hold`) inside the first line
of the host's output that `holds` accepts, and `entered` resolved as it gets
there, before the line is printed. -/
def enteringLine {β σ : Type} {scheme : InputScheme}
    (collaborators : Headless.Collaborators β σ scheme) (holds : String → Bool) (hold : BaseIO Unit)
    (entered : IO.Promise Unit) : Headless.Collaborators β σ scheme :=
  { collaborators with
    emit := fun line => do
      if holds line then
        entered.resolve ()
        hold
      collaborators.emit line }

/-- Waits for `entered`, a promise the check's hold resolves: a hang thrown
past `hangGuard`. -/
def reached (entered : IO.Promise Unit) (what : String) : IO Unit := do
  let some _ ←
    Job.awaitWithin hangGuard
        entered.result? | throw <| IO.userError s!"a hang: {what} had not been reached within {hangGuard.ms} ms"

/-- A job that sleeps 10 ms on the clock, reads the clock, and ends: `once`
makes a text of its reading. -/
def readingJob : Config.JobRegistration :=
  { name := "once"
    work := fun _ =>
      Work.of
        (fun _ => do
          sleep 10
          now)
        fun n => discard <| createText s!"read {n}" }

/-- A config whose `setup` defines the at-point source `paused`, asked by
itself after a pause of 240 ms and answering nothing, and uses it in every
buffer: a typed key arms its pause on the host's clock, and no session
opens. -/
def pausedAtPointText : String :=
  "def setup : SetupM Unit := do
  defineAtPoint { name := \"paused\", pause := some 240, ask := fun _ => pure none }
  useAtPoint \"paused\"
"

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

/-- A check of `scriptChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def scenePublishedAgainReloadCheck (context : Context) : Check :=
  { name :=
      "the scene is published again after a reload installs and after a job's command runs, once a frame exists"
    run :=
      withHost context jobsConfig fun session => do
        session.ask [.reload]
        session.commit "kept"
        session.ask [.published, .scene]
        session.ask [.spawn "count"]
        session.step
        unless (← session.clock.waiting) == 1 do
          return false
        session.clock.advance 10
        session.step
        session.ask [.reload]
        session.ask [.published, .scene]
        -- Between the first published request and the second the editor
        -- thread handles nine events, each followed by a scene: the first
        -- published and scene requests, the spawn, the job's wake-up, the
        -- reload, the reload's wake-up, and the three markers the asks'
        -- settles posted (a step drains with no marker). Had the
        -- job's command or the reload's install published nothing, the
        -- count would be short. Nothing outside idle publishes here: the
        -- host has no syntax tree and no poster of its own.
        return (← session.lines) ==
            #["reload 1: installed, 2 files, 1 commands", "published 1",
              "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
              "view 0 0,0 0x0: \"kept\", scroll 0, selections 4..4, padding 8 8",
              statusOf (modified := true) (cursor := ⟨0, 4⟩), "spawn count: job 1",
              "job 1 count: ok", "reload 2: installed, 2 files, 1 commands", "published 10",
              "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
              "view 0 0,0 0x0: \"kept\", scroll 0, selections 4..4, padding 8 8",
              statusOf (modified := true) (cursor := ⟨0, 4⟩)] }

/-- The checks of the headless mode's script and its driver
(`Headless.script`, `Headless.run`, `Headless.runAndDispose`), and of what
the executable's hosts dispose of when they end (`Headless.shippedOver`).
The command line itself is covered by one run of the real executable on the
fixture under `tests/headless`, in the `ffi-test` task. -/
def scriptChecks (context : Context) : List Check :=
  [{  name :=
        "the script runner reaches its host only through the Driven port: over a hand-written hosting, every request, input and wait reaches the port in order, and abort calls the run's onAbort and ends the script there, never the process"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource [])
        let calls ← IO.mkRef (#[] : Array String)
        let note (call : String) : IO Unit := calls.modify (·.push call)
        let driven :=
          Headless.Driven.over (fun request => note s!"send {repr request}")
            (fun event =>
              note
                (match event with
                | .key .. => "input key"
                | .commit text => s!"input commit {text}"
                | .resize .. => "input resize"
                | _ => "input other"))
            (fun _ kind _ line _ _ => do
              note s!"wait {kind.what} {line}"
              return .settled)
            (pure {}) (pure none) none fun _ _ => pure none
        let hosting : Headless.Hosting _ _ TestScheme.scheme :=
          {
            hosted := fun _ body => do
              note "bracket"
              let ran ← body driven
              note "bracket ends"
              return .ok (ran, .ok ()) }
        let script ←
          IO.ofExcept
              ((Headless.script
                    "reload\nkey a KeyA -\ncommit é\nresize 10 20\nsettle\njoin\nabort\nshow\n").mapError
                IO.userError)
        let (failure, plan) ←
          Headless.runOn hosting stage.collaborators script hangGuard (onAbort := note "abort")
        let seen ← calls.get
        saw
            (failure.isNone && plan.isNone &&
              seen ==
                #["bracket", "send Editor.Headless.Request.reload", "input key", "input commit é",
                  "input resize", "wait settle (some 5)", "wait join (some 6)", "abort",
                  "bracket ends"])
            s!"failure={repr failure} calls={seen}" },
    { name :=
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
        "agree, idle and journal are directives, each with nothing after it; agree asks the editor thread, and idle and journal are the driver's own"
      run :=
        pure
          ((Headless.script "agree\n  idle\njournal\n").toOption ==
            some #[⟨1, .request .agree⟩, ⟨2, .idle⟩, ⟨3, .journal⟩]) },
    { name :=
        "an idle with anything after it, its old milliseconds among them, and an agree or a journal with anything after it, are refused, with the number of the line, and an idle's refusal names idle"
      run :=
        pure
          ((["idle 1000", "idle 0", "idle x", "idle 10 20", "agree 3", "journal now"].all
              fun line =>
              match Headless.script ("reload\n" ++ line) with
              | .error message => message.startsWith "line 2: "
              | .ok _ => false) &&
            match Headless.script "idle 1000" with
            | .error message => (message.splitOn "expected idle, with nothing after it").length == 2
            | .ok _ => false) },
    { name :=
        "a scene directive asks for the last scene, a published directive for how many scenes have been published, and a commit directive commits the rest of its line"
      run :=
        pure
          ((Headless.script
                "scene\ncommit hello\n  commit  two words  \ncommit é\n published \n").toOption ==
            some
              #[⟨1, .request .scene⟩, ⟨2, .commit "hello"⟩, ⟨3, .commit "two words"⟩,
                ⟨4, .commit "é"⟩, ⟨5, .request .published⟩]) },
    { name := "a commit directive with no text is refused, with the number of its line"
      run :=
        pure
          (["commit", "commit   ", "scene now", "published 3"].all fun line =>
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
    scenePublishedAgainReloadCheck context,
    { name :=
        "once a command has released the focused buffer's text, a commit is still followed by a scene: its echo is the refusal, and it has no view of that buffer"
      run :=
        withHost context forgetConfig fun session => do
          session.ask [.reload]
          session.commit "a"
          session.ask [.published, .scene, .run "forget"]
          session.commit "b"
          session.ask [.published, .scene]
          -- Between the two published requests the editor thread handles
          -- five events, each followed by a scene: the first published and
          -- scene requests, the run, the marker of the wait and the commit.
          -- Had the scenes after the release been refused, the count would
          -- be short. Nothing outside idle publishes here.
          return (← session.lines) ==
              #["reload 1: installed, 1 files, 1 commands", "published 1",
                "scene 0x0, focused 0, echo \"\", echo padding 8, preedit -, theme \"default\"",
                "view 0 0,0 0x0: \"a\", scroll 0, selections 1..1, padding 8 8",
                statusOf (modified := true) (cursor := ⟨0, 1⟩), "run forget: ok", "published 6",
                "scene 0x0, focused 0, echo \"refused: no such text\", echo padding 8, preedit -, theme \"default\""] },
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
        leavingLibraryQueue <|
            Headless.withStepped stage.collaborators stage.memory (guard := hangGuard) (grace :=
              some hangGuard) fun stepped => do
              stepped.input .closeRequested
              return (← stepped.await hangGuard) == .ended },
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
    { name :=
        "a run that gave up on a hung loop is described differently from every other failure, with its guard and its grace"
      run :=
        let line := some 3
        let hung := Headless.Failure.describe 30000 (.hung 30000 5000)
        let others :=
          [Headless.Failure.reloading line, .reloading none, .working line, .working none,
                .unanswered line, .unanswered none, .stalled 3 5, .noClock 3, .notRestarted 3,
                .notInstalled 3, .waited 90000 (.unanswered none)].map
            (Headless.Failure.describe 30000)
        saw
          (!others.contains hung && (hung.splitOn "30000 ms").length == 2 &&
            (hung.splitOn "5000 ms").length == 2)
          s!"hung={hung}" },
    { name :=
        "a join or an advance that reached its guard with work still running is described as a hang, with its line or at the script's end, and with its guard"
      run :=
        let line := Headless.Failure.describe 30000 (.busy (some 3))
        let atEnd := Headless.Failure.describe 30000 (.busy none)
        saw
          (line.startsWith "a hang:" && atEnd.startsWith "a hang:" && line != atEnd &&
            (line.splitOn "line 3").length == 2 &&
            (line.splitOn "30000 ms").length == 2 &&
            (atEnd.splitOn "30000 ms").length == 2 &&
            line != Headless.Failure.describe 30000 (.working (some 3)))
          s!"line={line} atEnd={atEnd}" },
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
            Headless.Wait.ended.failureIn line 30000 200 (own := some 90000),
            Headless.Wait.busy.failureIn line 30000 200,
            Headless.Wait.busy.failureIn line 30000 200 (own := some 90000)]
        let expected : List (Option Headless.Failure) :=
          [some (.waited 200 (.unanswered line)), some (.unanswered line), some (.reloading line),
            some (.working line), some (.waited 90000 (.reloading line)),
            some (.waited 90000 (.unanswered line)), some (.waited 90000 (.unanswered line)), none,
            none, none, none, some (.busy line), some (.waited 90000 (.busy line))]
        saw
          (failures == expected &&
            Headless.Failure.ranOut 200 30000 (.unanswered none) ==
              .waited 200 (.unanswered none) &&
            Headless.Failure.ranOut 30000 30000 (.working line) == .working line)
          s!"failures={repr failures}" },
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
            Headless.shippedOver TestScheme.scheme #[] #[`Editor] "" [] directory.toString
              staged.emit staged.services staged.published staged.held files
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

/-- A check of `hostLoopChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def hostKeepsClipboardOwnCheck (context : Context) : Check :=
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
        session.step
        unless (← session.clock.waiting) == 1 do
          return false
        session.clock.advance 10
        session.step
        return empty == "no text".quote && written == "written".quote &&
            pasted == "kept by the host".quote &&
            (← session.scene).1 == "courier read kept by the host".quote }

/-- A check of `hostLoopChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def keyCommandStartsJobCheck (context : Context) : Check :=
  { name :=
      "a key's command starts a job with an argument: the host says it started, keys sent while the job sleeps are handled before its result, and once the clock lets it go its command runs after them, with the value the job computed in the text and in the scene's echo"
    run :=
      withHost context [("init.lean", startingText)]
        (fun session => do
          session.ask [.reload]
          session.typed "C-c a"
          session.step
          unless (← session.clock.waiting) == 1 do
            return false
          session.typed "C-c s C-c s"
          let sleeping ← session.scene
          let before ← session.output.get
          session.clock.advance 10
          session.step
          let after := (← session.output.get).extract before.size
          return before.contains "job 1 double: started" &&
              !before.any (·.startsWith "job 1 double: ok") &&
              sleeping == ("".quote, #[viewLine "!!" 2]) &&
              after == #["job 1 double: ok"] &&
              (← session.scene) == ("doubled to 42".quote, #[viewLine "!![42]" 6]))
        dispatchCompiled }

/-- A check of `hostLoopChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def hostHandedCompiledJobsCheck (context : Context) : Check :=
  { name :=
      "a host is handed compiled jobs: a compiled command starts one before any config is loaded, a reload that installs does not cancel it, and once the clock lets it go its command runs"
    run :=
      withHost context [("init.lean", emptyText)]
        (fun session => do
          session.ask [.run "rest"]
          session.step
          unless (← session.clock.waiting) == 1 do
            return false
          session.ask [.reload]
          let reloaded ← session.output.get
          session.clock.advance 10
          session.step
          return reloaded ==
                #["run rest: ok", "job 1 nap: started",
                  "reload 1: installed, 1 files, 0 commands"] &&
              (← session.output.get).extract reloaded.size == #["job 1 nap: ok"] &&
              (← session.scene) == ("".quote, #[viewLine "napped" 6]))
        nappingCompiled }

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
            session.commit "abcd"
            session.ask [.run "boom"]
            return (← session.output.get) == #["run boom: refused: bad range"] &&
                (← session.scene) == ("boom: refused: bad range".quote, #[viewLine "abcd" 4]))
          dispatchCompiled },
    { name :=
        "the driver's run of a command of config's that gives up is rolled back and printed so: the output says it gave up, with its reason, the scene's echo is its name and the reason with no refused, and the view's text is that before the command"
      run :=
        withHost context [("init.lean", givingUpText)] fun session => do
          session.ask [.reload]
          session.commit "abcd"
          session.ask [.run "quitter"]
          return (← session.lines) ==
                #["reload 1: installed, 1 files, 1 commands", "run quitter: gave up: no can do"] &&
              (← session.scene) == ("quitter: no can do".quote, #[viewLine "abcd" 4]) },
    { name :=
        "the driver's run of a command of config's that breaks off keeps what the command did and is printed so: the output says it broke off, with its reason, the scene's echo is its name and the reason with no refused, and the view's text holds what the command inserted"
      run :=
        withHost context [("init.lean", breakingOffText)] fun session => do
          session.ask [.reload]
          session.commit "abcd"
          session.ask [.run "stopper"]
          return (← session.lines) ==
                #["reload 1: installed, 1 files, 1 commands",
                  "run stopper: broke off: far enough"] &&
              (← session.scene) == ("stopper: far enough".quote, #[viewLine "abcdtyped" 9]) },
    hostKeepsClipboardOwnCheck context,
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
          -- A post's invocation is in the mailbox before its event is pushed
          -- onto the stage's memory queue: each push is waited on, and the
          -- mailbox read after the next push is armed, so no push is missed,
          -- a cancelled job's wake-up among them.
          let mailbox := running.mailbox
          let posted : IO Bool := do
            repeat
              let next ← stage.memory.arrived
              if (← mailbox.size) == 1 then
                return true
              if (← Job.awaitWithin hangGuard next).isNone then
                return false
            return false
          let (first, running) ← running.startJob collaborators "poster"
          let some first := first | return false
          unless ← posted do
            return false
          let running := { running with jobs := ← running.jobs.cancel first }
          let running ← running.posted collaborators first
          let dropped := (← stage.output.get).isEmpty && (← running.mailbox.size) == 0
          let (second, running) ← running.startJob collaborators "poster"
          let some second := second | return false
          unless ← posted do
            return false
          let running ← running.posted collaborators second
          let live := running.jobs.has second
          running.show collaborators
          let output ← stage.output.get
          running.jobs.cancelAll
          return dropped && live && output[0]? == some s!"job {second} poster: ok" &&
              output.contains "text 0: \"p\"" },
    { name :=
        "a job's post made after its check's withRunning has returned lands on the stage's memory queue, never the library's editor queue, where the next host would take it"
      run := do
        -- Seen to bite once by hand: with withRunning's collaborators on the
        -- library's queue, the post held past the bracket lands there, the
        -- memory queue stays empty, and the next stepped check sees the
        -- library's queue grow.
        let kept : IO.Ref (Option (Job.FakeClock × IO.Promise Unit × Job.Jobs × TestStage)) ←
          IO.mkRef none
        let started ←
          withRunning context
              (fun collaborators =>
                { collaborators with
                  packages :=
                    #[Compiled.package
                        {
                          jobs :=
                            #[{ name := "late"
                                work := fun _ =>
                                  Work.of
                                    (fun _ => do
                                      discard now
                                      post { command := "mark", arguments := [.str "p"] }
                                      sleep 10)
                                    fun _ => pure () }] }] })
              fun collaborators running stage => do
              -- The job's first read of the clock is held until the bracket
              -- has returned: its post comes after.
              let held ← stage.clock.holdReads
              let (id, running) ← running.startJob collaborators "late"
              kept.set (some (stage.clock, held, running.jobs, stage))
              return id.isSome
        let some (clock, held, jobs, stage) ← kept.get | return false
        held.resolve ()
        -- The job starts its sleep only once its post is pushed.
        let sleeping ← clock.arrivedAt (.started 1)
        let posted := (← Job.awaitWithin hangGuard sleeping.result?).isSome
        let queued ← stage.memory.size
        jobs.cancelAll
        saw (started && posted && queued == 1)
            s!"started={started} posted={posted} queued on the stage's memory queue={queued}" },
    keyCommandStartsJobCheck context,
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
    hostHandedCompiledJobsCheck context]

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
          session.resize 80 64
          session.ask []
          let made ← session.echo
          return before == ("", #[]) && isGreetError made }]

/-- The checks of what the executable's host (`Headless.shippedOver`) starts
its loop with: the state directory it is handed. What its registry holds is
not this list's. The core's Lake package registers no package, so a host
starts from what `Config.State.ofPackages` makes of the packages its set
hands it: that it makes nothing of none is `hostChecks`' here and
`ModelTest.packageChecks`', and what a package registers is that package's
own tests'. Nothing here starts a host or a job. -/
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
          (Headless.shippedOver TestScheme.scheme #[] #[`Editor] "" [] "" (fun _ => pure ())
              services published held files stateDirectory).hosting
        let given := ((over (some "/state")).start.runModel {}).1
        let none_ := ((over none).start.runModel {}).1
        return (match given, none_ with
          | .ok given, .ok none_ =>
            given.state.stateDirectory == some "/state" && none_.state.stateDirectory == none &&
              given.state.workingDirectory == "/"
          | _, _ => false) }]

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

/-- A check of `watchReloadChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def reloadInstallsWatchesNewCheck (context : Context) : Check :=
  { name :=
      "after a reload installs, only the watches the new config made deliver: the old config's job is cancelled before the reload is reported, its watch ends, and the new config's job is told of the change and says the new version"
    run :=
      withHost context followConfig fun session => do
        session.ask [.reload]
        session.ask [.spawn "follow"]
        session.step
        unless (← session.watches.watching) == 1 do
          return false
        let firstWatch := ((← session.watches.started)[0]?.map (·.1.toNat)).getD 0
        session.write "init.lean" (overGreet (followText "v2"))
        session.ask [.reload]
        -- The jobs table let the old job go at the cancel; its end, which
        -- ends its watch, runs on a step of the fake scheduler, so once
        -- stepped to rest it has ended. Read once.
        session.step
        let oldEnded :=
          (← session.watches.watching) == 0 && (← session.watches.ended) == #[firstWatch]
        let afterReload ← session.output.get
        session.ask [.spawn "follow"]
        session.step
        unless (← session.watches.watching) == 1 do
          return false
        session.watches.change "/watched/f" #[.written]
        let joined ← session.stepUntil (·.contains "job 2 follow: ok")
        session.ask [.show]
        let lines ← session.output.get
        let later := lines.extract afterReload.size lines.size
        return oldEnded && joined &&
            afterReload ==
              #["reload 1: installed, 2 files, 1 commands", "spawn follow: job 1",
                "job 1 follow: cancelled", "reload 2: installed, 2 files, 1 commands"] &&
            later.contains "job 2 follow: ok" &&
            later.contains "text 1: \"v2\"" &&
            !later.any (·.startsWith "job 1") }

/-- A check of `watchReloadChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def rejectedReloadLeavesOldCheck (context : Context) : Check :=
  { name :=
      "a rejected reload leaves the old config's watch watching: its job is told of the change and says the old version"
    run :=
      withHost context followConfig fun session => do
        session.ask [.reload]
        session.ask [.spawn "follow"]
        session.step
        unless (← session.watches.watching) == 1 do
          return false
        session.write "Config/Greet.lean" "def greet : EditorM Unit := \"not a command\"\n"
        session.ask [.reload]
        let stillWatching := (← session.watches.watching) == 1 && (← session.watches.ended).isEmpty
        session.watches.change "/watched/f" #[.written]
        let joined ← session.stepUntil (·.contains "job 1 follow: ok")
        session.ask [.show]
        let lines ← session.lines
        return stillWatching && joined && lines.contains "reload 2: rejected" &&
            lines.contains "job 1 follow: ok" &&
            lines.contains "text 1: \"v1\"" }

/-- The checks of a config's watches across a reload, through the headless
host over the fake watch service: after a reload installs, only the watches
the new config made deliver; a rejected reload leaves the old one's
watching. -/
def watchReloadChecks (context : Context) : List Check :=
  [reloadInstallsWatchesNewCheck context, rejectedReloadLeavesOldCheck context]

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
    -- The report goes to the queue the stepped host drains: the stage's.
    let environments :=
      Headless.reportedEnvironments state stage.collaborators.environment
        (stage.memory.queue Headless.Posted.toFfi)
    let collaborators :=
      { stage.collaborators with services := { stage.collaborators.services with environments } }
    onStage { stage with collaborators } fun drive stage =>
        check (Session.ofStage drive directory stage) state environments

/-- A config whose `setup` sets the process environment to `setting`, written
as Lean. -/
def environmentText (setting : String) : String :=
  s!"def setup : SetupM Unit := do\n  processEnvironment {setting}\n"

/-- An entry of a lookup that failed, as a host's environments hold one. -/
def failedLookup : Process.Entry :=
  { stamps := #[], found := .failed (.exited 1 "not trusted") }

/-- What a host's environments hold before a reload in the checks: an entry
of a directory and source, and one of a base. -/
def heldEntries : Array (Process.Slot × Process.Entry) :=
  #[(.directory "/p/d" "mise", failedLookup), (.base "login", failedLookup)]

/-- The checks of the host's environments (`Editor/Headless.lean`, "A
child's environment"), over the headless host and the real elaborator: a
reload that installs puts the layers of config's setting in the state every
job shares and drops every entry, the base's included, a rejected one
changes neither, and a message the environments report is the echo of the
next scene. -/
def environmentHostChecks (context : Context) : List Check :=
  let window : Process.Host := .window (some "/u")
  [{  name :=
        "an installed reload whose setup sets the process environment puts that setting's layers in the host's environments and drops every entry, the base's included; a rejected reload changes neither"
      run :=
        withEnvironments context [("init.lean", environmentText ".inherited")]
          fun session state _ => do
          -- In the window mode, where auto would give the mise source.
          state.set
              { host := window, sources := (Process.Setting.mise none).sources window
                entries := heldEntries }
          session.ask [.reload]
          let installed ← state.get
          state.modify fun held => { held with entries := heldEntries }
          session.write "init.lean" "def setup : SetupM Unit := oops"
          session.ask [.reload]
          let rejected ← state.get
          return installed.host == window && installed.sources.base matches .inherited &&
              installed.sources.directories.isEmpty &&
              installed.entries.isEmpty &&
              rejected.sources.directories.isEmpty &&
              rejected.entries == heldEntries },
    { name := "a config that does not set the process environment installs auto"
      run :=
        withEnvironments context [("init.lean", "def setup : SetupM Unit := pure ()")]
          fun session state _ => do
          state.set { host := window, sources := (Process.Setting.mise none).sources window }
          session.ask [.reload]
          let sources := (← state.get).sources
          return sources.base matches .inherited &&
              sources.directories.map (fun source => (source.name, source.program)) ==
                #[("mise", .firstOf (Process.miseCandidates (some "/u")) .skip)] },
    { name := "a failed lookup the host's environments record is the echo of the next scene"
      run :=
        withEnvironments context [] fun session _ environments => do
          session.resize 160 96
          session.ask []
          environments.ask (.record (.directory "/p/d" "mise") failedLookup)
          let (echo, _) ← session.scene
          return echo ==
              (Process.failureMessage (.directory "/p/d" "mise") (.exited 1 "not trusted")).quote }]

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

/-- The stage of a host over a config directory `directory` holding `files`,
with the real elaborator, the packages `files` and `restore`, the state
directory `/state`, and a fake file service over `journalledModel`, which
is handed back with it. -/
def restoreStage (context : Context) (directory : System.FilePath)
    (files : List (String × String)) :
    IO (Stage Config.Elaborate.Base Config.Elaborate.Handle × Job.FakeFiles) := do
  writeConfig directory files
  let stage ←
    Stage.new context context.elaborator (Config.Directory.source directory)
        { packages := #[FilesApiTest.fake, Test.Restore.package] }
  let fake ← Job.FakeFiles.new stage.collaborators.services.completions journalledModel
  let stage :=
    { stage with
      collaborators :=
        { stage.collaborators with
          stateDirectory := some restoreState
          services := { stage.collaborators.services with files := fake.files } } }
  return (stage, fake)

/-- Runs `check` against a stepped host over `restoreStage`'s stage, with its
output and the fake file service. -/
def withRestoreHost (context : Context) (files : List (String × String))
    (check : Driven → IO.Ref (Array String) → Job.FakeFiles → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, fake) ← restoreStage context directory files
    onStage stage fun drive stage => check drive stage.output fake

/-- The state directory of the stepped restore checks' hosts: a made-up
path, which only the fake files' model holds. -/
def stateDirectory : System.FilePath :=
  "/state"

/-- `model` with the directories a session under `state` is kept in:
`state` itself, its session directory and its journals directory. -/
def stateFiles (state : System.FilePath) (model : FileModel := {}) : FileModel :=
  ((model.withDirectory state).withDirectory (Restore.sessionDirectory state)).withDirectory
    (Restore.journalsDirectory state)

/-- A stepped stage (`Stage.stepped`) for a host over a config directory
holding `files`, with the packages `files` (its fake) and `restore`: its
fake files hold `model`, the state directory `stateDirectory` and a
journalled buffer of run 1 in it, whose base holds `hello`; its session
journal is the recording fake (`Stage.recordingJournal`), handed back. -/
def restoreFilesStage (context : Context) (directory : System.FilePath)
    (files : List (String × String)) (restore : Package) (model : FileModel := {}) :
    IO (Stage Config.Elaborate.Base Config.Elaborate.Handle × Headless.RecordingJournal) := do
  writeConfig directory files
  let state := stateDirectory
  let model :=
    ((stateFiles state model).withFile (Restore.basePath state 1 0 1) "hello".toUTF8).withFile
      (Restore.logPath state 1 0 1) journalledLog
  let stage ←
    Stage.new context context.elaborator (Config.Directory.source directory)
        { packages := #[FilesApiTest.fake, restore] }
  (← stage.stepped model).recordingJournal state

/-- Runs `check` against a stepped host over `restoreFilesStage`'s stage,
with the state directory. -/
def withRestoreFiles (context : Context) (files : List (String × String))
    (check : Session → System.FilePath → IO Bool) (restore : Package := Test.Restore.package)
    (model : FileModel := {}) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, _) ← restoreFilesStage context directory files restore model
    onStage stage fun drive stage => check (Session.ofStage drive directory stage) stateDirectory

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

/-- Runs `check` against a stepped host (`Stage.stepped`) over a config
directory holding `files`, with the packages `files` (its fake), `restore`
and `packages`, whose fake files hold what `model` holds, the state
directory `stateDirectory` among it, and whose session journal is the
recording fake: once the host has ended, `model` holds what its fake files
held then, so the next host over it starts where this one ended, as a
restart does. -/
def withStateHost (context : Context) (model : IO.Ref FileModel) (files : List (String × String))
    (packages : Array Package) (check : Session → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    let stage ←
      Stage.new context context.elaborator (Config.Directory.source directory)
          { packages := #[FilesApiTest.fake, Test.Restore.package] ++ packages }
    let stage ← stage.stepped (stateFiles stateDirectory (← model.get))
    let (stage, _) ← stage.recordingJournal stateDirectory
    let held ← onStage stage fun drive stage => check (Session.ofStage drive directory stage)
    if let some fakes := stage.fakes then
      model.set (← fakes.services.files.model)
    return held

/-- Steps the session until the host has written the session index: the
session stepped to rest (`Session.step`), and while the host says the index
is being written (`Progress.indexing`), the write's delay moved past on the
stage's clock (its next deadline) and the session stepped again. Whether the
index is written; `false` when it is still being written with nothing on
the clock to move. -/
partial def stepIndexed (session : Session) : IO Bool := do
  session.step
  unless (← session.drive.progress).indexing do
    return true
  let some deadline ← session.clock.nextDeadline | return false
  session.clock.advance (deadline - (← session.clock.now))
  stepIndexed session

/-- The text of the highest run's index under `state` in `model`, if it
holds one. -/
def lastIndex (model : FileModel) (state : System.FilePath) : Option String :=
  let indexes :=
    model.contents.filterMap fun (path, bytes) =>
      if path.parent == some (Restore.sessionDirectory state) then
        (Restore.runOfIndex? (path.fileName.getD "")).map (·, bytes)
      else none
  let best :=
    indexes.foldl
      (fun found (run, bytes) =>
        match found with
        | some (other, _) => if run > other then some (run, bytes) else found
        | none => some (run, bytes))
      none
  best.map fun (_, bytes) => String.fromUTF8! bytes

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

/-- A stepped host (`Stage.stepped`) over a config directory holding `files`,
with the packages `files` (its fake) and `restore`, the state directory
`stateDirectory` in its fake files, a launch whose running executable
passes the probe (the stepped process fake scripted with that reply), and
the session journal's recording fake, whose failure readout answers one
more failure of one path at each read once `failing` is set, so it is said
once and counted at every read: what `check` is handed, with the flag; and
the host is stopped. -/
def withFailingJournal (context : Context) (files : List (String × String))
    (check : Session → IO.Ref Bool → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    let running : System.FilePath := "/A.app/Contents/MacOS/editor"
    let stage ←
      Stage.new context context.elaborator (Config.Directory.source directory)
          { packages := #[FilesApiTest.fake, Test.Restore.package] }
    let stage ←
      stage.stepped (stateFiles stateDirectory)
          {
            scripts :=
              #[{ command := Restore.probeCommand running
                  reply :=
                    .ok { exit := .code 0, stdout := "probe: ok\n".toUTF8, stderr := .empty } }] }
    let (stage, fake) ← stage.recordingJournal stateDirectory
    let failing ← IO.mkRef false
    let journal : Headless.Journal :=
      { fake.journal with
        failures := do
          let taken ← fake.failures
          if ← failing.get then
            return taken.push ("/journal/full", "the disk is full")
          return taken }
    let stage :=
      { stage with
        collaborators :=
          { stage.collaborators with
            journal, launch := { running := some running, shipped := some running } } }
    onStage stage fun drive stage => check (Session.ofStage drive directory stage) failing

/-- A check of `restoreOrderChecks`, a declaration of its own. -/
def handJournalOrderFailedCheck (context : Context) : Check :=
  { name :=
      "a hand-over after a journal order failed since the restart began is given up: restart-abandon says the failure, and the loop goes on with no plan"
    run :=
      withFailingJournal context greetConfig fun session failing => do
        session.send (.restore none)
        unless ← session.settle do
          return false
        failing.set true
        session.send (.run Editor.restartName)
        -- The debounced index write sleeps on the stage's clock, which
        -- nothing moves, so the steps are for the save's own end line.
        let saved ← session.stepUntil (·.any (·.endsWith s!"{Restore.restartSaveJob}: ok"))
        unless saved do
          return false
        session.send .scene
        unless ← session.settle do
          return false
        let lines ← session.output.get
        let progress ← session.drive.progress
        return progress.handOver.isNone && (← session.drive.ended?).isNone &&
            lines.any fun line =>
              echoes
                "restart: a journal write failed (/journal/full); the session was not handed over"
                line }

/-- A check of `restoreOrderChecks`, a declaration of its own. -/
def restoreWhoseJobFailsCheck (context : Context) : Check :=
  { name :=
      "a restore whose job fails releases the requests it held, in order: the file given is opened, the text said, and reload 1 installed, so setup has run; and await answers settled"
    run :=
      let notes := stateDirectory / "notes.txt"
      withRestoreFiles context helloConfig (restore := failingRestore) (model :=
        ({} : FileModel).withFile notes "notes".toUTF8) fun session _ => do
        session.send (.restore none)
        session.send (.open notes.toString)
        session.send (.say "held words")
        session.send .reload
        let waited ← session.settle
        session.step
        session.send .scene
        session.send .show
        unless ← session.settle do
          return false
        let lines ← session.output.get
        let failed :=
          firstLine? lines fun line =>
            line.startsWith "job " && (line.splitOn s!" {Restore.restoreJob}: failed").length == 2
        let installed := firstLine? lines (·.startsWith "reload 1: installed")
        let opened :=
          lines.any fun line => line.startsWith "text " && line.endsWith s!": {"notes".quote}"
        let said := lines.any (echoes "held words")
        let registered :=
          lines.any fun line => line.startsWith "commands:" && (line.splitOn " ").contains "greet"
        return waited && opened && said && registered &&
            match failed, installed with
            | some failed, some installed => failed < installed
            | _, _ => false }

/-- The checks of the restore at start-up in the host (`Editor/Headless.lean`,
"Restoring a session"), on the real elaborator: it runs before the start-up
reload, which it holds, and `await` waits for it; a restore whose job fails
releases what it held. Each is on a stepped stage (`Stage.stepped`): the
session's files are the stage's fake files, under the made-up state
directory `stateDirectory`, and its journal the recording fake, so a
restart's next host starts over the fake files the last one ended with
(`withStateHost`), and the index is read from them (`lastIndex`). -/
def restoreOrderChecks (context : Context) : List Check :=
  [{  name :=
        "a restore that names the index a restart handed over holds the start-up reload as an unnamed one does: its second half runs before reload 1 is installed"
      run :=
        withRestoreFiles context greetConfig fun session state => do
          session.send (.restore (some (Restore.indexPath state 1)))
          session.send .reload
          unless ← session.settle do
            return false
          let lines ← session.output.get
          -- The journal orders the restore's edits handed are worked, so the
          -- stage's fakes are quiescent at the bracket.
          session.step
          let restored :=
            firstLine? lines fun line =>
              line.startsWith "job " && (line.splitOn s!" {Restore.filesJob}: ok").length == 2
          let installed := firstLine? lines (·.startsWith "reload 1: installed")
          return match restored, installed with
            | some restored, some installed => restored < installed
            | _, _ => false },
    handJournalOrderFailedCheck context,
    { name :=
        "a host with a session and a config restores first: the restore's second half has run, and the buffer it restored is there, before reload 1 is installed"
      run :=
        withRestoreFiles context greetConfig fun session _ => do
          session.send (.restore none)
          session.send .reload
          unless ← session.settle do
            return false
          session.send .show
          unless ← session.settle do
            return false
          let lines ← session.output.get
          -- The journal orders the restore's edits handed are worked, so the
          -- stage's fakes are quiescent at the bracket.
          session.step
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
          -- The restore's takes are held, so the restore is running work:
          -- the await blocks on it, and that is when the takes are let go,
          -- with no `reload 1` line printed yet. No guard lets anything go.
          let early ← IO.mkRef (none : Option Bool)
          let said ← IO.mkRef (#[] : Array String)
          let waited ←
            host.await hangGuard (waitHung := fun line => said.modify (·.push line)) (waitBlocked :=
                fun what => do
                if what == "running work" && (← early.get).isNone then
                  early.set (some ((← output.get).any (·.startsWith "reload 1")))
                  hold.resolve ())
          hold.resolve ()
          let late := (← output.get).any (·.startsWith "reload 1: installed")
          let early ← early.get
          let said ← said.get
          saw (waited == .settled && early == some false && late && said.isEmpty)
              s!"waited={repr waited} early={early} late={late} said={said}" },
    restoreWhoseJobFailsCheck context,
    { name :=
        "the index's write ends on the check's steps: once the host has a change to keep, stepping does not write the index while its delay is to come; with the delay moved past on the clock, a step writes it into the fake files"
      run := do
        let model ← IO.mkRef ({} : FileModel)
        withStateHost context model [] #[countedPackage 1] fun session => do
            session.send (.restore none)
            session.send (.run "bump-counted")
            unless ← session.settle do
              return false
            session.step
            let early := (← session.drive.progress).indexing
            let written ← stepIndexed session
            let some fakes := session.fakes | return false
            let index := lastIndex (← fakes.services.files.model) stateDirectory
            saw (early && written && index.isSome)
                s!"indexing before the delay {early}, written {written}, the index {index}" },
    { name :=
        "a package's declared store kept across a restart, end to end: bumped twice and left uncleanly, the next host shows it before any reload, since packages register before the restore; a host handed the package at version 2 shows it migrated"
      run := do
        let model ← IO.mkRef ({} : FileModel)
        let first ←
          withStateHost context model [] #[countedPackage 1] fun session => do
              session.send (.restore none)
              session.send (.run "bump-counted")
              session.send (.run "bump-counted")
              unless ← session.settle do
                return false
              stepIndexed session
        let shown (version : Nat) (line : String) :=
          withStateHost context model [] #[countedPackage version] fun session => do
            session.send (.restore none)
            session.send .show
            unless ← session.settle do
              return false
            return (← session.output.get).contains line
        let second ← shown 1 "store counted v1: 2"
        let third ← shown 2 "store counted v2: 4"
        return first && second && third },
    { name :=
        "a config's store kept across a restart: the start-up reload restores it; a config whose setup throws keeps it parked, and the index written after still lists it; a later good reload claims it"
      run := do
        let model ← IO.mkRef ({} : FileModel)
        let first ←
          withStateHost context model keptConfig #[] fun session => do
              session.send (.restore none)
              session.send .reload
              unless ← session.settle do
                return false
              session.send (.run "bump-kept")
              session.send (.run "bump-kept")
              unless ← session.settle do
                return false
              stepIndexed session
        let restored ←
          withStateHost context model keptConfig #[] fun session => do
              session.send (.restore none)
              session.send .reload
              unless ← session.settle do
                return false
              session.send .show
              unless ← session.settle do
                return false
              return (← session.output.get).contains "store kept v1: 2"
        let thrown ←
          withStateHost context model throwingConfig #[] fun session => do
              session.send (.restore none)
              session.send .reload
              unless ← session.settle do
                return false
              unless ← stepIndexed session do
                return false
              let some fakes := session.fakes | return false
              let index := lastIndex (← fakes.services.files.model) stateDirectory
              return index.any fun text => (text.splitOn "\"name\":\"kept\"").length == 2
        let claimed ←
          withStateHost context model keptConfig #[] fun session => do
              session.send (.restore none)
              session.send .reload
              unless ← session.settle do
                return false
              session.send .show
              unless ← session.settle do
                return false
              return (← session.output.get).contains "store kept v1: 2"
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

/-- The stage of a host with no config and the command `step`, whose journal
is `keptFailures` over a cell handed back with it, empty. -/
def journalStage (context : Context) (directory : System.FilePath) :
    IO (Stage Config.Elaborate.Base Config.Elaborate.Handle × IO.Ref (Array (String × String))) :=
  do
  let failed ← IO.mkRef #[]
  let stage ←
    Stage.new context context.elaborator (Config.Directory.source directory)
        { commands := #[stepCommand] }
  return ({ stage with
        collaborators := { stage.collaborators with journal := keptFailures failed } },
      failed)

/-- Runs `check` against a stepped host over `journalStage`'s stage. -/
def withJournalHost (context : Context)
    (check : Session → IO.Ref (Array (String × String)) → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, failed) ← journalStage context directory
    onStage stage fun drive stage => check (Session.ofStage drive directory stage) failed

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

/-- A job registered as `restore` that does nothing: with it registered the
loop's journal reconciler is enabled (`Restore.journalOrders`), and no check
of `journalOrderChecks` starts it. -/
def idleRestoreJob : Config.JobRegistration :=
  { name := Restore.restoreJob, work := fun _ => Work.of (fun _ => pure ()) fun _ => pure () }

/-- The commands of `journalOrderChecks`: `journal-run` gives the session its
run number, 1, and says the restore done, as a restore that found nothing
would; `journal-unmodify` undoes the window's buffer until its history is
at its saved head, so it is journalled no longer. -/
def journalOrderCommands : Array Config.Registration :=
  #[{ name := "journal-run"
      action :=
        .call fun _ => do
          let state ← editorState
          Restore.setKept
              { state.restore with
                run := some 1, restored := true } },
    { name := "journal-unmodify"
      action :=
        .call fun call => do
          let buffer := call.target.window.buffer
          for _ in [0:16] do
            let .ok true ← buffer.isModified | return
            discard <| buffer.undo }]

/-- An order as `journalOrderChecks` compares it: its kind and its path. -/
def orderShape (order : Restore.Order) : String × String :=
  match order.request with
  | .save _ path _ => ("save", path.toString)
  | .append path _ => ("append", path.toString)
  | .remove path => ("remove", path.toString)
  | _ => ("other", order.path)

/-- The checks of the host's hand-off of the session journal's orders
(`Running.journaled`, `Collaborators.journal`), on a stepped host over the
journal's recording fake (`Stage.recordingJournal`): the orders are compared
by kind and path, computed with the reconciler's own path functions, never
by their bytes, which `ModelTest.restoreChecks` pin. -/
def journalOrderChecks (context : Context) : List Check :=
  [{  name :=
        "the host hands the session journal its base, edit-record and remove orders in order, on its own thread, and the journal's drain ends only on the check's step: a scratch buffer typed into twice and undone to unmodified gives the base's save, the header's append, one record's append, then the base's and the log's removes"
      run := do
        let stage ←
          Stage.new context context.elaborator (memorySource [])
              { jobs := #[idleRestoreJob], commands := journalOrderCommands }
        let state : System.FilePath := "/state"
        let (stage, fake) ← stage.recordingJournal state
        let thread ← IO.getTID
        onStage stage fun drive _ => do
            drive.send (.run "journal-run")
            unless ← drive.settle hangGuard do
              return false
            drive.commit "a"
            unless ← drive.settle hangGuard do
              return false
            drive.commit "b"
            unless ← drive.settle hangGuard do
              return false
            drive.send (.run "journal-unmodify")
            unless ← drive.settle hangGuard do
              return false
            let orders := (← fake.orders).map orderShape
            -- The scratch buffer, buffer 0, in run 1, at the first generation
            -- the reconciler gives a journal.
            let generation := ({} : Restore.Kept).nextGeneration
            let base := (Restore.basePath state 1 0 generation).toString
            let log := (Restore.logPath state 1 0 generation).toString
            let expected :=
              #[("save", base), ("append", log), ("append", log), ("remove", base), ("remove", log)]
            let threads ← fake.orderThreads
            let drain ← fake.journal.drained
            let early ← IO.hasFinished drain
            fake.stepAll
            let ended ← Job.awaitWithin hangGuard drain
            saw
                (orders == expected && threads.all (· == thread) && !early && ended == some true &&
                  (← fake.quiescent))
                s!"orders {orders}, handed on {threads} (the check's thread {thread}); the drain ended before the step {early}, after it {ended}" }]

end ConfigTest
