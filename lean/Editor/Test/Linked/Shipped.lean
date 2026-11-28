import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Face
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.File.Model
import Editor.Headless
import Editor.Highlight
import Editor.InferredWait
import Editor.Job.Fake
import Editor.RealHost
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Host
import Editor.Test.Linked.Listings
import Editor.Test.Linked.Syntax

/-!
# The linked test kit: Shipped

A host made as the executable's hosts are made (`shippedStaged`, over
`Headless.shippedOver`), of the input scheme and the packages it is given
(a test of the core or of a package hands it the test scheme,
`TestScheme.scheme`; the Vim scheme's host is evil's,
`packages/evil/EvilTest/Linked/Support/Vim.lean`), stepped
(`withShippedHost`) or real (`withRealSyntaxHost`), and the real
syntax tree binding as a check observes it: each request recorded
(`recordingSyntaxTree`, `recordedRequest`), and the faces a test grammar's
highlights query draws (`testFaces`). A real syntax host is handed the
grammars the core's tests load (`TestGrammars`) and declares them, so its
`register-grammars` job registers them at the first install; a check waits
for that job's command (`Session.testGrammarsRegistered`) before it opens a
file. It holds no checks of its own.

Published for a package's linked tests, in the namespace
`Editor.Test.Linked`, beside the hosts (`Editor/Test/Linked/Host.lean`). It
names no package: a host's packages are the harness's
(`HostContext.packages`) unless a check hands others.
-/

namespace Editor.Test.Linked

open Editor

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

/-- `recordingSyntaxTree` is an inferred wait (`Editor/InferredWait.lean`):
it hands on `Ffi.syntaxSettle`, the real syntax service's readout, whose
fake is `FakeSyntaxService`. A check over the real binding says why with an
allow. -/
def recordingSyntaxTree.inferredWait : InferredWait :=
  .realEffect []

/-- The mark of `recordingSyntaxTree`: it runs a real background service (`Editor/RealHost.lean`). -/
def recordingSyntaxTree.realHost : RealHost :=
  .service

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
        discard (Ffi.syntaxSettle found Ffi.treeGuard)
    return reply

/-- The mark of `testFaces`: it compiles a query on the library's syntax
service, a real background service's (`Editor/RealHost.lean`). -/
def testFaces.realHost : RealHost :=
  .service

/-- The faces the captures of the highlights query in `grammars`' directory
for `grammar` are drawn in, by name, `-` for none, as `recordedRequest`
writes a highlight: by the shipped default over the language's `captures`,
none by default. Read from the directory and compiled by the library, on
which `grammar` is registered, so no check repeats its query. -/
def testFaces (grammars : TestGrammars) (grammar : String)
    (captures : List (String × Option FaceName) := []) : IO String := do
  let some names ←
    testQueryCaptureNames grammars grammar .highlights | return "none in the directory"
  let faces := Highlight.faces captures names
  return s!"highlight {", ".intercalate (faces.map fun face => (face.map (·.name)).getD "-").toList}"

/-- A Rust text for the syntax checks: a method in an `impl`, after a unit
struct. -/
def rustObjectsText : String :=
  "struct S;\n\nimpl S {\n    fn one(&self) -> u8 {\n        let x = 1;\n        x\n    }\n}\n"

/-- What a host of the input scheme `scheme` is made of, for
`withShippedHost` and `withRealSyntaxHost`: a stage of its own over a
config directory of `files` in `directory`, and collaborators made over the
collaborators the executable's hosts are made of (`Headless.shippedOver`),
handed the package `listings`, so its listings are matched and shown by the
style and the display written for these tests whatever else registers one
(`Editor/Test/Linked/Listings.lean`), then `packages`, with the
real elaborator and the stage's services and source ids; its syntax tree is
what `syntaxTree` makes of the stage. With a model, the jobs reach its
files and no real one. With `stepped`, the stage is stepped (`Stage.stepped`, over the model's
files if there is one): its jobs and services are fakes the check steps,
and its loop's end steps the jobs it cancels. A check that holds the
editor thread at a line hands `emitting`, which the host's output goes
through. Its jobs wait in a table of waits of the stage's own, unless it
is handed one (`waits`), as a stage whose jobs reach a real service is. -/
private def shippedStagedWith (scheme : InputScheme) (context : HostContext)
    (directory : System.FilePath) (files : List (String × String)) (fileModel : Option FileModel)
    (workingDirectory : System.FilePath) (home : Option System.FilePath)
    (emitting : (String → IO Unit) → String → IO Unit) (packages : Array Package) (stepped : Bool)
    (syntaxTree :
      Stage Config.Elaborate.Base Config.Elaborate.Handle →
        IO
          (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
            (SnapshotReader → IO SyntaxTreeHandler)))
    (waits : Option Job.Completions := none) :
    IO
      (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
        Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme) :=
  do
  writeConfig directory files
  let source := Config.Directory.source directory
  let stage ← Stage.new context context.elaborator source (waits := waits)
  let stage ←
    if stepped then
      stage.stepped (fileModel.getD {})
    else
      pure stage
  let (stage, syntaxTree) ← syntaxTree stage
  let staged := stage.collaborators
  let services ←
    match fileModel, stepped with
    | some model, false =>
      do
        let faked ← Job.FakeFiles.new staged.services.completions model
        pure { staged.services with files := faked.files }
    | _, _ =>
      pure staged.services
  let shipped :=
    Headless.shippedOver scheme (#[listingsPackage] ++ packages) #[`Editor] "" [] ""
      (emitting staged.emit) services staged.published staged.held
      (← Config.Elaborate.ModuleFiles.temporary)
  let collaborators :=
    { shipped with
      elaborator := context.elaborator, source, requests := staged.requests
      wakeups := staged.wakeups, jobs := staged.jobs, environment := staged.environment
      posts := staged.posts, pauseEvents := staged.pauseEvents, log := staged.log, syntaxTree
      clock := staged.clock, loopStarted := staged.loopStarted, workingDirectory, home }
  -- A stepped stage's loop's end steps the jobs it cancels.
  let collaborators :=
    if stage.fakes.isSome then { collaborators with endCancelled := staged.endCancelled }
    else collaborators
  return (stage, collaborators)

/-- `shippedStagedWith` with the stage's fake of the syntax service
(`Stage.fakeSyntaxService`) as its syntax tree, which the session's steps
step on a stepped stage: the default of every shipped host, whose subject
is not the library's syntax service. -/
def shippedStaged (scheme : InputScheme) (context : HostContext) (directory : System.FilePath)
    (files : List (String × String)) (fileModel : Option FileModel)
    (workingDirectory : System.FilePath) (home : Option System.FilePath)
    (emitting : (String → IO Unit) → String → IO Unit) (packages : Array Package)
    (stepped : Bool := false) :
    IO
      (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
        Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme) :=
  shippedStagedWith scheme context directory files fileModel workingDirectory home emitting packages
    stepped fun stage => do
    let (stage, fake) ← stage.fakeSyntaxService
    return (stage, fun _ => pure fake.handle)

/-- `model` with each query file of `grammars`' directory in it, at its own
path: what a real syntax host's `register-grammars` job reads its queries
from when the check hands the host a model of files. -/
def TestGrammars.inFileModel (grammars : TestGrammars) (model : FileModel) : IO FileModel := do
  let mut model := model
  for (name, _) in TestGrammars.names do
    for (file, _) in Language.Grammar.queryFiles do
      let path := grammars.queries name / file
      if ← path.pathExists then
        model := model.withFile path (← IO.FS.readBinFile path)
  return model

/-- `shippedStagedReal` is an inferred wait (`Editor/InferredWait.lean`): it
hands on `Ffi.syntaxSettle`, the real syntax service's readout. -/
def shippedStagedReal.inferredWait : InferredWait :=
  .realEffect []

/-- The mark of `shippedStagedReal`: it runs a real background service (`Editor/RealHost.lean`). -/
def shippedStagedReal.realHost : RealHost :=
  .service

/-- `shippedStagedWith` with the real syntax tree binding over the
library's syntax service, which after an attach, and before a question of a
text's captures, waits, with a bound, for the text's tree to be delivered:
for a check whose subject is the library's syntax service, on a real
host (A5 of `docs/dev-practices/real-thread-checks.md`). The host is handed
the test grammars' declarations beside `packages` (`TestGrammars.package`):
the library hides its compiled-in grammars, so its `register-grammars` job
registers them from `grammars`' directory at the first install, through the
library's grammar registrations, over the table of waits the one completion
pump runs over (`HostContext.fileWaits`), and reads their queries through
the library's file service (`Stage.withRealFilesAndGrammars`, which
`Stage.overFiles` builds on too, and which marks the stage one over the
library's services), or, when the
check hands a model of files, from that model, given the query files
(`TestGrammars.inFileModel`). -/
def shippedStagedReal (scheme : InputScheme) (context : HostContext) (grammars : TestGrammars)
    (directory : System.FilePath) (files : List (String × String)) (fileModel : Option FileModel)
    (workingDirectory : System.FilePath) (home : Option System.FilePath)
    (emitting : (String → IO Unit) → String → IO Unit) (packages : Array Package) :
    IO
      (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
        Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme) :=
  do
  let completions ← context.fileWaits
  let fileModel ←
    match fileModel with
    | some model =>
      some <$> grammars.inFileModel model
    | none =>
      pure none
  shippedStagedWith scheme context directory files fileModel workingDirectory home emitting
      (packages.push grammars.package) false (waits := some completions) fun stage => do
      let stage ← stage.withRealFilesAndGrammars completions
      let syntaxTree (snapshots : SnapshotReader) : IO SyntaxTreeHandler := do
        let real ← RealSyntaxTree.new snapshots
        return fun request => do
          -- A question of the captures waits for its snapshot's tree, so keys
          -- that edit and then ask are answered of a delivered tree.
          if let .capturesOf snapshot .. := request then
            if let some found← snapshots.find? snapshot then
              discard (Ffi.syntaxSettle found Ffi.treeGuard)
          let reply ← real.handle request
          if let .attach snapshot _ := request then
            if let some found← snapshots.find? snapshot then
              discard (Ffi.syntaxSettle found Ffi.treeGuard)
          return reply
      return (stage, syntaxTree)

/-- Runs `check` against a host of the input scheme `scheme`
(`shippedStaged`), of `packages`: by default the packages the harness's set
hands its editor (`HostContext.packages`); stepped on the check's own thread
(`stepping`, over the stage's memory queue), over a stepped stage
(`Stage.stepped`).
`false` if the check did not hold or the host did not settle after it. The
directory is removed. -/
def withShippedHost (scheme : InputScheme) (context : HostContext) (files : List (String × String))
    (check : Session → IO Bool) (fileModel : Option FileModel := none)
    (workingDirectory : System.FilePath := "/") (home : Option System.FilePath := none)
    (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, collaborators) ←
      shippedStaged scheme context directory files fileModel workingDirectory home emitting packages
          (stepped := true)
    stepping collaborators stage.memory (fun drive => check (Session.ofStage drive directory stage))
        (fakes := stage.fakes)

/-- A real host over `staged`, in its bracket (`Headless.withHost`), which
returns once its loop has ended. -/
private def realShipped {scheme : InputScheme}
    (staged :
      IO
        (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
          Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme))
    (directory : System.FilePath) (check : RealSession → IO Bool) : IO Bool := do
  let (stage, collaborators) ← staged
  refuseFakes stage "withRealSyntaxHost"
  Headless.withHost collaborators (guard := hangGuard) (grace := some hangGuard) fun host => do
      let held ← check (RealSession.ofStage host directory stage)
      let wait ← host.await hangGuard
      return held && (wait == .settled || wait == .ended)

/-- `withRealSyntaxHost` is an inferred wait (`Editor/InferredWait.lean`):
its host's syntax tree is the real binding (`shippedStagedReal`). -/
def withRealSyntaxHost.inferredWait : InferredWait :=
  .realEffect []

/-- The mark of `withRealSyntaxHost`: it runs a real editor loop thread (`Editor/RealHost.lean`). -/
def withRealSyntaxHost.realHost : RealHost :=
  .loop

/-- `withShippedHost` with a real host, in its bracket (`Headless.withHost`),
which returns once its loop has ended, and the real syntax tree binding
over the library's syntax service (`shippedStagedReal`), declaring the test
grammars of `grammars`' directory: for a check whose subject is the
library's syntax service (A5). The check waits for their registration's
command (`Session.testGrammarsRegistered`) before it opens a file. -/
def withRealSyntaxHost (scheme : InputScheme) (context : HostContext) (grammars : TestGrammars)
    (files : List (String × String)) (check : RealSession → IO Bool)
    (fileModel : Option FileModel := none) (workingDirectory : System.FilePath := "/")
    (home : Option System.FilePath := none) (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  IO.FS.withTempDir fun directory =>
    realShipped
      (shippedStagedReal scheme context grammars directory files fileModel workingDirectory home
        emitting packages)
      directory check

/-- Waits until the host's `register-grammars` job has ended with its
command (its line `job <n> register-grammars: ok`), which the first install
of a host that declares the test grammars starts (`withRealSyntaxHost`): by
then each is registered and the languages' trees resolve with their
queries. An event the host's output reaches, with the hang guard as a guard
against a hang only. -/
def Session.testGrammarsRegistered (session : Session) : IO Bool :=
  session.outputReaches fun lines => lines.any (·.endsWith s!" {Language.Grammar.jobName}: ok")

end Editor.Test.Linked
