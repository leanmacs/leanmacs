import ConfigTest.Editor.Headless
import ConfigTest.Support.Shipped
import Editor.InputScheme.Test
import Editor.RealHost
import Editor.Test.Linked.Services
import Editor.Test.Linked.Shipped
import Editor.Test.Linked.Syntax

/-!
# Config tests: `Editor/SyntaxTree/Real.lean`, the library's syntax service

A module of the wiring set (`AGENTS.md`, "Deterministic concurrency in
tests"; `docs/dev-practices/real-thread-checks.md`): the test module that
mirrors the real adapter's module, `RealSyntaxTree`.

**The real adapter.** The library's syntax service, whose `parsed` comes
back over the library's editor queue. **Why a real thread.** A stepped host
never pulls that queue, and a stray `parsed` would reach the next real host.

`realSyntaxChecks`: the script's `highlights`, which waits on the library's
delivery of the focused view's tree and prints the faces of its captures;
and a parse of a highlighted text the library delivers makes the real host
publish a scene; that a delivered parse publishes one
scene is the loop's, `ModelTest/Editor/Loop.lean` ("a parse delivered
leaves the state as it was ... and publishes one scene"). Its helpers,
`recordedStage`, `withRealRecordedSyntaxTree` and `registeredTestGrammars`,
are marked.

**The grammars.** The library compiles in no grammar, so each check first registers the grammars cargo builds for the
core's tests (`registeredTestGrammars`, over the process's one completion
pump), and its mode carries its own highlights query: a mode's own tree is
not resolved against a declaration, and a registered grammar ships none.
The TOML mode's is the query file in the test grammars' directory, the
same file the adapter ships, so the faces are the same.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.SyntaxTree.Real : Editor.WiringSet :=
  .wiring
    "the library's syntax service (RealSyntaxTree), whose parses come back over the library's queue"
    "a stepped host never pulls the library's queue, and a stray parsed would reach the next real host"

namespace ConfigTest

open Editor
open Editor.Test.Linked

/-- The mark of `registeredTestGrammars`: it runs a real background service
(`Editor/RealHost.lean`). -/
def registeredTestGrammars.realHost : Editor.RealHost :=
  .service

/-- Registers the test grammars of `context`'s directory on the library's
syntax service (`registerTestGrammars`), in a job on services over the
process's one completion pump (`HostContext.fileWaits`): `true` once every
one registered, and otherwise it throws why, which the check's failure
names (`saw`). -/
def registeredTestGrammars (context : Context) : IO Bool := do
  let services ← Services.over (← context.fileWaits)
  match ← registerTestGrammars context.testGrammars services.jobs with
  | .ok () =>
    return true
  | .error why =>
    saw false s!"the test grammars did not register: {why}"

/-- The mark of `recordedStage`: it runs a real background service (`Editor/RealHost.lean`). -/
def recordedStage.realHost : Editor.RealHost :=
  .service

-- inferred-waits W89: stays (A5: the stage of parseHighlightedTextLibraryCheck, whose subject is the library's deliveries over its own queue)
set_option linter.inferredWait false in
/-- The stage of a host over a config of `highlightText`, in `directory`,
whose syntax tree collaborator is the real binding over the library's syntax
service with every request recorded (`recordedRequest`) in the array handed
back, and which after an attach waits, with a bound, for the attached text's
tree to be delivered; how many scenes the host's display has had
published to it, read from the display the host's collaborator made, with no
request of the driver's; and a wait for the library to deliver a tree of the
text the first view of the last scene published shows (`Ffi.syntaxSettle`,
with `hangGuard`): whether it did. -/
def recordedStage (context : Context) (directory : System.FilePath) :
    IO
      (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
        IO.Ref (Array String) × IO Nat × IO Bool) :=
  do
  writeConfig directory [("init.lean", highlightText)]
  let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
  let asked ← IO.mkRef #[]
  let syntaxTree := recordingSyntaxTree asked
  let made : IO.Ref (Option (Headless.Host.Display × SnapshotReader)) ← IO.mkRef none
  let display (snapshots : SnapshotReader) : IO Headless.Host.Display := do
    let shown ← Headless.Host.Display.recorder Headless.cells snapshots
    made.set (some (shown, snapshots))
    return shown
  let published : IO Nat := do
    match ← made.get with
    | some (shown, _) =>
      shown.count.get
    | none =>
      return 0
  let settleShown : IO Bool := do
    let some (shown, snapshots) ← made.get | return false
    let some scene ← shown.last? | return false
    let some view := scene.views[0]? | return false
    let some found ← snapshots.find? view.snapshot | return false
    Ffi.syntaxSettle found hangGuard
  return ({ stage with
        collaborators :=
          { stage.collaborators with
            syntaxTree, display } },
      asked, published, settleShown)

/-- The mark of `withRealRecordedSyntaxTree`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withRealRecordedSyntaxTree.realHost : Editor.RealHost :=
  .loop

/-- A real host (`onRealStage`) over `recordedStage`'s stage, the real
syntax binding's, whose services record to a fake recorder
(`Job.FakeRecorder`, `recording`): handed the recorder, the stage's count of
published scenes and its wait for the shown text's tree. -/
def withRealRecordedSyntaxTree (context : Context)
    (check : RealSession → Job.FakeRecorder → IO Nat → IO Bool → IO Bool) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, _, published, settleShown) ← recordedStage context directory
    let recorder ← Job.FakeRecorder.new
    let stage := { stage with collaborators := recording stage.collaborators recorder }
    onRealStage stage fun host stage =>
        check (RealSession.ofStage host directory stage) recorder published settleShown

/-- A check of `jobChecks`, a declaration of its own. -/
def parseHighlightedTextLibraryCheck (context : Context) : Check :=
  { name :=
      "a parse of a highlighted text the library delivers makes the real host publish a scene, with no key pressed"
    run :=
      -- Seen to bite once by hand: a host whose `handle` returns at once
      -- for an event from the library's source publishes nothing for the
      -- parse, and the count stays at the edit's.
      -- Stays on a real host (row W6 of docs/dev-practices/inferred-waits.md,
      -- A5): the library's deliveries over its own queue are the subject.
      -- Its waits are its own job's: the job's park, its sleep's wait
      -- recorded (the recorder), and the job's end line.
      withRealRecordedSyntaxTree context fun session recorder published settleShown => do
        unless ← registeredTestGrammars context do
          return false
        session.ask [.reload]
        session.ask [.spawn "highlight"]
        -- hang guard: the highlight job's park on its sleep, recorded; only
        -- a hang reaches the bound.
        let parked ← recorder.reached (· matches .park _)
        unless (← Job.awaitWithin hangGuard parked).isSome do
          return false
        session.clock.advance 10
        unless ← session.outputReaches (·.contains "job 1 highlight: ok") do
          return false
        let before ← published
        -- Waited on with no marker that publishes: the edit's command
        -- publishes one scene, and a publish beyond it is a delivered
        -- parse's. Once the library has delivered a tree of the edited
        -- text (`syntaxSettle`), its `parsed` event is on the editor queue
        -- (the library queues it before it records the delivery), so a
        -- second wait that publishes nothing sees it handled.
        session.host.send (.run "edit")
        unless ← session.handled do
          return false
        unless ← settleShown do
          return false
        unless ← session.handled do
          return false
        return (← published) > before + 1 }

/-- A config that defines the mode `toml`, whose syntax tree is the TOML
grammar registered from the test grammars' directory, drawn with
`highlights`, and the command `open-toml`, which puts a TOML table in the
scratch text and sets the focused view's major mode to it. -/
def tomlText (highlights : String) : String :=
  "def openToml : EditorM Unit := do
  (⟨0⟩ : TextId).insert 0 \"[package]\\nname = \\\"x\\\"\\n\"
  discard <| (⟨0⟩ : ViewId).setMajorMode \"toml\"

def setup : SetupM Unit := do
  defineMode { name := \"toml\", syntaxTree := some { grammar := \"toml\", highlights := some " ++
    highlights.quote ++
    " } }
  command \"open-toml\" openToml
"

/-- A check of `realSyntaxChecks`, a declaration of its own. -/
def highlightsDirectiveCheck (context : Context) : Check :=
  { name :=
      "a real host's script that opens a TOML file in the code mode and asks highlights prints the faces of its table header, keys and values at their ranges, after the library delivered its tree; on a buffer with no syntax tree it prints none"
    run :=
      -- Wiring only: the directive waits on the library's delivery of the
      -- focused view's tree and reads its captures through the real
      -- binding. That it is read, and refused stepped, is
      -- `scriptChecks`' and `ModelTest.fixtureSetupChecks`', and so is what
      -- the driver does with each answer of the tree's delivery. The first
      -- `highlights`, on a text not attached, holds that the real delivery
      -- (`Headless.TreeDelivery.real`) tells it from a hang, which would
      -- fail the run as `undelivered`: seen to bite once by hand, with the
      -- attachment probe answering attached for every text.
      IO.FS.withTempDir fun directory => do
        unless ← registeredTestGrammars context do
          return false
        let some highlights := (← context.testGrammars.queriesOf "toml").highlights | return false
        writeConfig directory [("init.lean", tomlText highlights)]
        let stage ← Stage.new context context.elaborator (Config.Directory.source directory)
        let syntaxTree (snapshots : SnapshotReader) : IO SyntaxTreeHandler := do
          return (← RealSyntaxTree.new snapshots).handle
        let collaborators := { stage.collaborators with syntaxTree }
        let script ←
          IO.ofExcept
              ((Headless.script
                    "reload\nresize 160 64\nsettle\nhighlights\nrun open-toml\nsettle\nhighlights\n").mapError
                IO.userError)
        let (failure, _) ←
          Headless.runOn
              (Headless.Hosting.real hangGuard (some hangGuard) IO.eprintln fun _ => pure ())
              collaborators script hangGuard
        let lines := (← stage.output.get).filter (·.startsWith "highlights ")
        saw
            (failure.isNone &&
              lines ==
                #["highlights 0: none",
                  "highlights 0: syntax.punctuation 0..1 syntax.type 1..8 syntax.punctuation 8..9 syntax.property 10..20 syntax.type 10..14 syntax.operator 15..16 syntax.string 17..20"])
            s!"failure={repr failure} lines={lines}" }

-- inferred-waits W89: stays (A5: the stage of a real syntax host, whose subject is the library's syntax service; nothing is waited on)
set_option linter.inferredWait false in
/-- A check of `realSyntaxChecks`, a declaration of its own. -/
def realSyntaxStageCheck (context : Context) : Check :=
  { name :=
      "the stage of a real syntax host, whose jobs register its grammars and read their queries over the library's services, is a stage over the library's services: a stepped stage refuses it"
    run :=
      IO.FS.withTempDir fun directory => do
        let (stage, _) ←
          shippedStagedReal TestScheme.scheme context context.testGrammars directory [] none "/"
              none id #[]
        let refused ←
          try
            discard <| stage.stepped
            pure false
          catch _ =>
            pure true
        saw refused "Stage.stepped took the real syntax host's stage" }

/-- A check of `realSyntaxChecks`, a declaration of its own. -/
def registerTestGrammarsRefusalCheck (context : Context) : Check :=
  { name :=
      "registering the test grammars from a directory that holds no library answers the first grammar's library, its symbol and the library's refusal"
    run :=
      IO.FS.withTempDir fun directory => do
        let grammars : TestGrammars := { directory }
        let services ← Services.over (← context.fileWaits)
        let answer ← registerTestGrammars grammars services.jobs
        let library := (grammars.library "json").toString
        let expected :=
          s!"{library} (tree_sitter_json): {(GrammarError.refused .notFound).describe}"
        let said :=
          match answer with
          | .error why => why
          | .ok () => "registered"
        saw (said == expected) s!"{said}, not {expected}" }

-- inferred-waits W89: stays (A5: a real syntax host's registration of its test grammars over the library's syntax service, its subject)
set_option linter.inferredWait false in
/-- A check of `realSyntaxChecks`, a declaration of its own. -/
def refusedTestGrammarsSaidCheck (context : Context) : Check :=
  { name :=
      "a real syntax host whose test grammars' directory holds no library ends its register-grammars job ok, and the wait for the test grammars' registration answers the refusal naming the grammar"
    run :=
      IO.FS.withTempDir fun empty =>
        withRealSyntaxTestHost context { directory := empty } [] fun session => do
          session.ask [.reload]
          match ← session.testGrammarsRegistered with
          | .error why =>
            saw ((why.splitOn "grammar `json`: the grammar was refused:").length > 1) why
          | .ok () =>
            saw false "the wait answered the test grammars registered" }

/-- The checks of the library's syntax service under a real host. -/
def realSyntaxChecks (context : Context) : List Check :=
  [parseHighlightedTextLibraryCheck context, highlightsDirectiveCheck context,
    realSyntaxStageCheck context, registerTestGrammarsRefusalCheck context,
    refusedTestGrammarsSaidCheck context]

end ConfigTest
