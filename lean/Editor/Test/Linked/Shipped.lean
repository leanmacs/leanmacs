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
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Host
import Editor.Test.Linked.Listings

/-!
# The linked test kit: Shipped

A host made as the executable's hosts are made (`shippedStaged`, over
`Headless.shippedOver`), of the input scheme and the packages it is given
(a test of the core or of a package hands it the test scheme,
`TestScheme.scheme`; the Vim scheme's host is evil's,
`packages/evil/EvilTest/Linked/Support/Vim.lean`), stepped
(`withShippedHost`) or real (`withRealShippedHost`), and the real
syntax tree binding as a check observes it: each request recorded
(`recordingSyntaxTree`, `recordedRequest`), and the faces the library's
shipped highlights query draws (`shippedFaces`). It holds no checks of its
own.

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

/-- A Rust text for the syntax checks: a method in an `impl`, after a unit
struct. -/
def rustObjectsText : String :=
  "struct S;\n\nimpl S {\n    fn one(&self) -> u8 {\n        let x = 1;\n        x\n    }\n}\n"

/-- What a host of the input scheme `scheme` is made of, for
`withShippedHost` and `withRealShippedHost`: a stage of its own over a
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
through. -/
private def shippedStagedWith (scheme : InputScheme) (context : HostContext)
    (directory : System.FilePath) (files : List (String × String)) (fileModel : Option FileModel)
    (workingDirectory : System.FilePath) (home : Option System.FilePath)
    (emitting : (String → IO Unit) → String → IO Unit) (packages : Array Package) (stepped : Bool)
    (syntaxTree :
      Stage Config.Elaborate.Base Config.Elaborate.Handle →
        IO
          (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
            (SnapshotReader → IO SyntaxTreeHandler))) :
    IO
      (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
        Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme) :=
  do
  writeConfig directory files
  let source := Config.Directory.source directory
  let stage ← Stage.new context context.elaborator source
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

/-- `shippedStagedReal` is an inferred wait (`Editor/InferredWait.lean`): it
hands on `Ffi.syntaxSettle`, the real syntax service's readout. -/
def shippedStagedReal.inferredWait : InferredWait :=
  .realEffect []

/-- `shippedStagedWith` with the real syntax tree binding over the
library's syntax service, which after an attach, and before a question of a
text's captures, waits, with a bound, for the text's tree to be delivered:
for a check whose subject is the library's syntax service, on a real
host (A5 of `docs/dev-practices/real-thread-checks.md`). -/
def shippedStagedReal (scheme : InputScheme) (context : HostContext) (directory : System.FilePath)
    (files : List (String × String)) (fileModel : Option FileModel)
    (workingDirectory : System.FilePath) (home : Option System.FilePath)
    (emitting : (String → IO Unit) → String → IO Unit) (packages : Array Package) :
    IO
      (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
        Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle scheme) :=
  shippedStagedWith scheme context directory files fileModel workingDirectory home emitting packages
    false fun stage => do
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
  refuseFakes stage "withRealShippedHost"
  Headless.withHost collaborators (guard := hangGuard) (grace := some hangGuard) fun host => do
      let held ← check (RealSession.ofStage host directory stage)
      let wait ← host.await hangGuard
      return held && (wait == .settled || wait == .ended)

/-- `withShippedHost` with a real host, in its bracket (`Headless.withHost`),
which returns once its loop has ended; its syntax tree is the stage's fake
of the syntax service, which no one steps: a real host's check whose
subject is not the library's syntax service. -/
def withRealShippedHost (scheme : InputScheme) (context : HostContext)
    (files : List (String × String)) (check : RealSession → IO Bool)
    (fileModel : Option FileModel := none) (workingDirectory : System.FilePath := "/")
    (home : Option System.FilePath := none) (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  IO.FS.withTempDir fun directory =>
    realShipped
      (shippedStaged scheme context directory files fileModel workingDirectory home emitting
        packages)
      directory check

/-- `withRealSyntaxHost` is an inferred wait (`Editor/InferredWait.lean`):
its host's syntax tree is the real binding (`shippedStagedReal`). -/
def withRealSyntaxHost.inferredWait : InferredWait :=
  .realEffect []

/-- `withRealShippedHost` with the real syntax tree binding over the
library's syntax service (`shippedStagedReal`): for a check whose subject is
the library's syntax service (A5). -/
def withRealSyntaxHost (scheme : InputScheme) (context : HostContext)
    (files : List (String × String)) (check : RealSession → IO Bool)
    (fileModel : Option FileModel := none) (workingDirectory : System.FilePath := "/")
    (home : Option System.FilePath := none) (packages : Array Package := context.packages)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  IO.FS.withTempDir fun directory =>
    realShipped
      (shippedStagedReal scheme context directory files fileModel workingDirectory home emitting
        packages)
      directory check

end Editor.Test.Linked
