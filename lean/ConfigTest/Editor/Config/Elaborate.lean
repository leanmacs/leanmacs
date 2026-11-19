import ConfigFixture
import ConfigTest.Check
import ConfigTest.Support.Hosts
import Editor.Clipboard
import Editor.Command
import Editor.Command.Call
import Editor.Command.Real
import Editor.Config.Diagnostic
import Editor.Config.Elaborate
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
          IO.FS.removeDirAll empty }]

end ConfigTest
