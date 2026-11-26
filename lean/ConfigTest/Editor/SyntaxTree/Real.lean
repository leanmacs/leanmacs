import ConfigTest.Editor.Headless
import Editor.RealHost

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
`recordedStage` and `withRealRecordedSyntaxTree`, are marked.
-/

/-- This module is of the wiring set (`Editor/RealHost.lean`). -/
def wiringSet.ConfigTest.Editor.SyntaxTree.Real : Editor.WiringSet :=
  .wiring
    "the library's syntax service (RealSyntaxTree), whose parses come back over the library's queue"
    "a stepped host never pulls the library's queue, and a stray parsed would reach the next real host"

namespace ConfigTest

open Editor
open Editor.Test.Linked

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

/-- A config that defines the mode `toml`, whose syntax tree is the
compiled-in TOML grammar, and the command `open-toml`, which puts a TOML
table in the scratch text and sets the focused view's major mode to it. -/
def tomlText : String :=
  "def openToml : EditorM Unit := do
  (⟨0⟩ : TextId).insert 0 \"[package]\\nname = \\\"x\\\"\\n\"
  discard <| (⟨0⟩ : ViewId).setMajorMode \"toml\"

def setup : SetupM Unit := do
  defineMode { name := \"toml\", syntaxTree := some { grammar := \"toml\" } }
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
      -- `scriptChecks`' and `ModelTest.fixtureSetupChecks`'.
      IO.FS.withTempDir fun directory => do
        writeConfig directory [("init.lean", tomlText)]
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

/-- The checks of the library's syntax service under a real host. -/
def realSyntaxChecks (context : Context) : List Check :=
  [parseHighlightedTextLibraryCheck context, highlightsDirectiveCheck context]

end ConfigTest
