import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Face
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.File.Model
import Editor.Headless
import Editor.Highlight
import Editor.Job.Fake
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Test.Linked.Host
import Editor.Test.Linked.Listings

/-!
# The linked test kit: Shipped

A host made as the executable's hosts are made (`withVimHost`, over
`Headless.shippedOver`), handed the packages it is given, and the real
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

/-- Runs `check` against a host of the Vim scheme that ships, made over the
collaborators the executable's hosts are made of (`Headless.shippedOver`),
handed the package `listings`, so its listings are matched and shown by the
style and the display written for these tests whatever else registers one
(`Editor/Test/Linked/Listings.lean`), then `packages`: by default the
packages the harness's set hands its editor (`HostContext.packages`),
with the real elaborator, a config directory of `files` and the services of
a stage of its own; its syntax tree is the real binding over the library's
syntax service, which after an attach, and before a question of a text's
captures, waits, with a bound, for the text's tree to be delivered. Stops the host; `false` if the check did not
hold or the host did not stop. The directory is removed. -/
def withVimHost (context : HostContext) (files : List (String × String)) (check : Session → IO Bool)
    (fileModel : Option FileModel := none) (realFiles : Bool := false)
    (workingDirectory : System.FilePath := "/") (home : Option System.FilePath := none)
    (packages : Array Package := context.packages) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    writeConfig directory files
    let source := Config.Directory.source directory
    -- With `realFiles`, the jobs reach real files through the library's
    -- file service, as a file check's do (`Stage.overFiles`).
    let stage ←
      if realFiles then
        Stage.overFiles context source
      else
        Stage.new context context.elaborator source
    let staged := stage.collaborators
    -- With a model, the jobs reach its files and no real one.
    let services ←
      match fileModel with
      | some model =>
        do
          let faked ← Job.FakeFiles.new staged.services.completions model
          pure { staged.services with files := faked.files }
      | none =>
        pure staged.services
    let shipped :=
      Headless.shippedOver (#[listingsPackage] ++ packages) #[`Editor] "" [] "" staged.emit services
        staged.published staged.held (← Config.Elaborate.ModuleFiles.temporary)
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
        posts := staged.posts, pauseEvents := staged.pauseEvents, log := staged.log, syntaxTree
        clock := staged.clock, workingDirectory, home }
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

end Editor.Test.Linked
