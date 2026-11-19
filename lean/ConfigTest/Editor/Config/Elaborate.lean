import ConfigFixture
import ConfigTest.Check
import ConfigTest.Support.Hosts
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Real
import Editor.Config.Diagnostic
import Editor.Config.Elaborate
import Editor.Config.Modules
import Editor.Config.Registry
import Editor.Config.Session
import Editor.Display.Recorder
import Editor.Ffi.Document
import Editor.Ffi.Snapshot
import Editor.Headless
import Editor.Setup
import Editor.SyntaxTree
import Editor.Text
import Editor.Text.Real
import Editor.Value
import Editor.Watch

/-!
# Config tests: `Editor/Config/Elaborate.lean`

The tests of `Editor/Config/Elaborate.lean`: `elaboratorChecks`, with
`evalProbe`, `setupRefused` and `greeting`. The root module `ConfigTest` runs
them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- Evaluates the constant `name` of `environment` as an `IO Nat`. It is
`unsafe` because evaluating a constant trusts the type it is given. -/
unsafe def evalProbeUnsafe (environment : Lean.Environment) (name : Lean.Name) :
    Except String (IO Nat) :=
  environment.evalConst (IO Nat) {} name

/-- The action the constant `name` of `environment` is, which must have the
type `IO Nat`; or why it could not be evaluated. -/
@[implemented_by evalProbeUnsafe]
opaque evalProbe (environment : Lean.Environment) (name : Lean.Name) : Except String (IO Nat)

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
        return rejected "init.lean" result },
    { name :=
        "the base's modules are looked for in every directory the elaborator is given, in order: a module in the second of two directories is imported, and with that directory left out the import is refused, naming the module"
      run := do
        -- The first directory is an empty one of the check's own; the rest
        -- are the ones this executable was handed. The module is linked
        -- into this executable, so importing it runs no initialiser.
        let empty ← IO.FS.createTempDir
        try
          let imported (directories : List System.FilePath) : IO (Except String Unit) := do
            try
              discard <|
                  Config.Elaborate.importBase
                    { sysroot := context.sysroot, oleanDirs := directories
                      imports := #[`ConfigFixture] }
              return .ok ()
            catch error =>
              return .error (toString error)
          let found ← imported (empty :: context.oleanDirs)
          let refused ← imported [empty]
          return found.isOk &&
              match refused with
              | .error reason => (reason.splitOn "ConfigFixture").length > 1
              | .ok _ => false
        finally
          IO.FS.removeDirAll empty },
    { name :=
        "a base that cannot be imported is refused with one line that says what to do: it names the base module that has no .olean file, each directory searched, and that an executable with no <executable>.oleans record must be given every package's .olean directory, joined with a colon"
      run := do
        let empty ← IO.FS.createTempDir
        try
          let settings : Config.Elaborate.Settings :=
            { sysroot := context.sysroot, oleanDirs := [empty], imports := #[`ConfigFixture] }
          let refusal ←
            try
              discard <| (Config.Elaborate.elaborator settings).base
              pure none
            catch error =>
              pure (some (toString error))
          let some reason := refusal | return false
          let says (part : String) : Bool := (reason.splitOn part).length > 1
          return (reason.splitOn "\n").length == 1 && says "ConfigFixture" && says empty.toString &&
              says (System.FilePath.mk context.sysroot / "lib" / "lean").toString &&
              says "<executable>.oleans" &&
              says "joined with `:`" &&
              says "--oleans" &&
              (← Config.Elaborate.missing settings) == #[`ConfigFixture] &&
              -- With the module's directory searched too, none is missing.
              (←
                  Config.Elaborate.missing
                      { settings with oleanDirs := empty :: context.oleanDirs }) ==
                #[]
        finally
          IO.FS.removeDirAll empty }]

/-- The names of the commands the config an outcome built registers, in
order; none when it built none. -/
def builtCommands (outcome : Config.Modules.Outcome Config.Elaborate.Base Config.Elaborate.Handle) :
    Option (Array String) :=
  outcome.built.map (·.registrations.commands.map (·.name))

/-- The source, line and severity of each of an outcome's diagnostics. -/
def placed (outcome : Config.Modules.Outcome Config.Elaborate.Base Config.Elaborate.Handle) :
    Array (String × Nat × Config.Severity) :=
  outcome.diagnostics.map fun diagnostic =>
    (diagnostic.source, diagnostic.line, diagnostic.severity)

/-- The checks of the real elaborator of config as modules
(`Editor/Config/Elaborate.lean`): what only Lean's elaborator can show of a
config file as a module. The port's contract holds it to what the session
core rests on (`elaboratorContractChecks`). -/
def moduleElaboratorChecks (context : Context) : List Check :=
  let keys (body : String) : String × String := ("Config.Keys", configHeader ++ body)
  let root (imports body : String) : String × String := ("init", imports ++ configHeader ++ body)
  [{
      name :=
        "a file that imports Lean, a module of the base and a config file sees each, and the program the config file exports takes effect when the root's setup calls it",
      run := do
        let outcome ←
          buildModules context
              [keys
                  "namespace Config.Keys\ndef greeting : String := \"hello\"\ndef bindings : SetupM Unit :=\n  command \"from-keys\" (pure ())\nend Config.Keys\n",
                root "import Lean\nimport ConfigFixture\nimport Config.Keys\n"
                  "def viaLean : Lean.Json := Lean.Json.str Config.Keys.greeting\ndef probe : IO Nat := ConfigFixture.bump\ndef setup : SetupM Unit := do\n  Config.Keys.bindings\n  command viaLean.compress (pure ())\n"]
        return builtCommands outcome == some #["from-keys", "\"hello\""] &&
            outcome.diagnostics.isEmpty },
    { name :=
        "a setup a config file other than the root defines is not run: the root's own is, and the other's registrations are not in the config"
      run := do
        let outcome ←
          buildModules context
              [keys
                  "namespace Config.Keys\ndef setup : SetupM Unit :=\n  command \"never\" (pure ())\nend Config.Keys\n",
                root "import Config.Keys\n"
                  "def setup : SetupM Unit :=\n  command \"root\" (pure ())\n"]
        return builtCommands outcome == some #["root"] },
    { name :=
        "a root that defines no setup itself is refused with a diagnostic tagged setup that says only the root's is run, and names the module whose setup it can see when a file it imports defines one"
      run := do
        let alone ← buildModules context [root "" "def other : Nat := 1\n"]
        let imported ←
          buildModules context
              [keys "def setup : SetupM Unit :=\n  command \"never\" (pure ())\n",
                root "import Config.Keys\n" "def other : Nat := 1\n"]
        let message
          (outcome : Config.Modules.Outcome Config.Elaborate.Base Config.Elaborate.Handle) :
          String := ((outcome.diagnostics.map (·.message))[0]?).getD ""
        return alone.built.isNone && placed alone == #[("setup", 0, .error)] &&
            ((message alone).splitOn "the root itself defines").length == 2 &&
            ((message alone).splitOn "Config.Keys").length == 1 &&
            imported.built.isNone &&
            placed imported == #[("setup", 0, .error)] &&
            ((message imported).splitOn "`Config.Keys`").length == 2 },
    { name :=
        "a root whose setup has another type, or contains sorry, gives diagnostics tagged setup in place of a program"
      run := do
        let typed ← buildModules context [root "" "def setup : IO Unit := pure ()\n"]
        let sorried ← buildModules context [root "" "def setup : SetupM Unit := sorry\n"]
        let refused
          (outcome : Config.Modules.Outcome Config.Elaborate.Base Config.Elaborate.Handle) : Bool :=
          outcome.built.isNone &&
            outcome.diagnostics.any fun diagnostic =>
              diagnostic.source == "setup" && diagnostic.severity == .error
        return refused typed && refused sorried },
    { name :=
        "an open or a namespace of a config file does not reach the file that imports it, and its declarations do"
      run := do
        let hidden :=
          keys
            "namespace Hidden\ndef secret : Nat := 1\nend Hidden\nopen Hidden\ndef viaOpen : Nat := secret\n"
        let leaked ←
          buildModules context
              [hidden,
                root "import Config.Keys\n"
                  "def leak : Nat := secret\ndef setup : SetupM Unit := pure ()\n"]
        let qualified ←
          buildModules context
              [hidden,
                root "import Config.Keys\n"
                  "def fine : Nat := Hidden.secret + viaOpen\ndef setup : SetupM Unit := pure ()\n"]
        return leaked.built.isNone && placed leaked == #[("init.lean", 4, .error)] &&
            qualified.built.isSome },
    { name :=
        "a type error after a header is a diagnostic tagged with the file's path at the file's own line and column, in the root and in a config file"
      run := do
        let inRoot ←
          buildModules context
              [("init",
                  "import Editor\nimport Lean\n\nopen Editor\n\ndef fine : Nat := 1\ndef wrong : Nat := \"no\"\n")]
        let inFile ←
          buildModules context
              [keys "\ndef wrong : Nat := \"no\"\n",
                root "import Config.Keys\n" "def setup : SetupM Unit := pure ()\n"]
        let found (outcome : Config.Modules.Outcome Config.Elaborate.Base Config.Elaborate.Handle) :
          Array (String × Nat × Nat) :=
          outcome.diagnostics.map fun diagnostic =>
            (diagnostic.source, diagnostic.line, diagnostic.column)
        return inRoot.built.isNone && found inRoot == #[("init.lean", 7, 19)] &&
            inFile.built.isNone &&
            found inFile == #[("Config/Keys.lean", 4, 19)] },
    { name := "a file with only a warning elaborates, and the warning is a diagnostic at its line"
      run := do
        let outcome ←
          buildModules context
              [root "" "def later : Nat := sorry\ndef setup : SetupM Unit := pure ()\n"]
        return outcome.built.isSome && placed outcome == #[("init.lean", 3, .warning)] },
    { name :=
        "the imports of a header are read with the line and column each starts at, after a comment and indented too, and a file with no header has none"
      run := do
        let imports (text : String) : IO (Option (Array (String × Nat × Nat))) := do
          let found ← context.modules.imports { module := "init", path := "init.lean", text }
          return found.toOption.map
              (·.map fun wanted => (wanted.module, wanted.line, wanted.column))
        return (← imports "-- a comment\nimport Lean\n  import Config.Evil.Keys\n\ndef x := 1\n") ==
              some #[("Lean", 2, 0), ("Config.Evil.Keys", 3, 2)] &&
            (← imports "def x := 1\n") == some #[] &&
            (← imports "") == some #[] },
    { name :=
        "a file that starts with module is refused with a diagnostic at the keyword: config files are plain modules"
      run := do
        let outcome ←
          buildModules context
              [("init",
                  "module\n\nimport Editor\nopen Editor\ndef setup : SetupM Unit := pure ()\n")]
        return outcome.built.isNone && placed outcome == #[("init.lean", 1, .error)] &&
            outcome.diagnostics.all fun diagnostic =>
              (diagnostic.message.splitOn "`module`").length == 2 },
    { name := "a header that does not parse is a diagnostic tagged with the file's path"
      run := do
        let outcome ← buildModules context [("init", "import\ndef setup := 1\n")]
        return outcome.built.isNone &&
            outcome.diagnostics.all fun diagnostic =>
              diagnostic.source == "init.lean" && diagnostic.severity == .error },
    { name :=
        "a file that declares an initialised constant, or an initialiser alone, is rejected with a diagnostic tagged with its path, the root and a config file alike"
      run := do
        let inRoot ←
          buildModules context
              [root ""
                  "initialize counter : IO.Ref Nat ← IO.mkRef 0\ndef setup : SetupM Unit := pure ()\n"]
        let inFile ←
          buildModules context
              [keys "initialize IO.println \"hello\"\n",
                root "import Config.Keys\n" "def setup : SetupM Unit := pure ()\n"]
        return inRoot.built.isNone && placed inRoot == #[("init.lean", 0, .error)] &&
            inFile.built.isNone &&
            placed inFile == #[("Config/Keys.lean", 0, .error)] },
    { name :=
        "a module the base holds and a module of Lean in the toolchain are linked; a module of the toolchain outside Init, Std and Lean, a module of Lean that is not there, and a binding module the base does not hold are not"
      run := do
        let base ← context.modules.base none #[]
        let linked (module : String) : IO Bool := context.modules.linked base module
        return (← linked "Editor") && (← linked "ConfigFixture") && (← linked "Lean.Data.Json") &&
            (← linked "Std") &&
            !(← linked "Lake") &&
            !(← linked "Lean.NoSuchModule") &&
            !(← linked "Editor.Ffi") },
    { name :=
        "compiled code and a config file elaborated as a module share state: the root's program reads what compiled code wrote, and compiled code what it wrote"
      run := do
        let base ← context.modules.base none #[]
        let result ←
          context.modules.root base #[]
              { module := "init", path := "init.lean",
                text := "import ConfigFixture\ndef probe : IO Nat := ConfigFixture.bump\n" }
        let some (.root environment) := result.handle | return false
        let probe ← IO.ofExcept (evalProbe environment `probe)
        let before ← ConfigFixture.bump
        let fromConfig ← probe
        let after ← ConfigFixture.bump
        return fromConfig == before + 1 && after == before + 2 },
    { name :=
        "each version of a config file has module data in a file of its own: two elaborations of one module leave two files, and the first is not written again"
      run := do
        let base ← context.modules.base none #[]
        let version (text : String) : IO (Option System.FilePath) := do
          let result ←
            context.modules.file base #[]
                { module := "Config.Versions", path := "Config/Versions.lean", text }
          match result.handle with
          | some (.module _ file) =>
            return some file
          | _ =>
            return none
        let some first ← version "def one : Nat := 1\n" | return false
        let written ← IO.FS.readBinFile first
        let some second ← version "def two : Nat := 2\n" | return false
        return first != second && (← second.pathExists) && (← IO.FS.readBinFile first) == written }]

end ConfigTest
