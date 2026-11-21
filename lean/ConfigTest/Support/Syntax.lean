import ConfigTest.Check
import ConfigTest.Support.Hosts
import Editor.Completion
import Editor.Config.Directory
import Editor.Config.Elaborate
import Editor.Config.Registry
import Editor.Config.Session
import Editor.Ex.Line
import Editor.Face
import Editor.Ffi.Snapshot
import Editor.Ffi.Syntax
import Editor.File.Model
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.Highlight
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Job.Fake
import Editor.Job.Runner
import Editor.Language
import Editor.Loop
import Editor.Mode
import Editor.Scene
import Editor.SyntaxTree
import Editor.SyntaxTree.Real
import Editor.Text
import Editor.Text.Real
import EditorCore.EditorPackage

/-!
# Config tests: support: Syntax

The real syntax tree binding in a host: a recorded syntax tree request, the
faces of the library's shipped highlights, the Rust objects' text, and a host of
the Vim scheme that ships (`vimStaged`), stepped (`withVimHost`) or real
(`withRealVimHost`). Shared by several test modules; it
holds no checks of its own.
-/

namespace ConfigTest

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

/-- The Rust text of `rustObjectsConfig`: a method in an `impl`, after a
unit struct. -/
def rustObjectsText : String :=
  "struct S;\n\nimpl S {\n    fn one(&self) -> u8 {\n        let x = 1;\n        x\n    }\n}\n"

/-- What a host of the Vim scheme that ships is made of, for `withVimHost`
and `withRealVimHost`: a stage of its own over a config directory of
`files` in `directory`, and collaborators made over the collaborators the
executable's hosts are made of (`Headless.shippedOver`), handed the packages
of the core's Lake package (`EditorCore.EditorPackage.packages`), with the
real elaborator and the stage's services and source ids; its syntax tree is
the real binding over the library's syntax service, which after an attach,
and before a question of a text's captures, waits, with a bound, for the
text's tree to be delivered. With `realFiles`, the jobs reach real files
through the library's file service, as a file check's do
(`Stage.overFiles`); with a model, they reach its files and no real one. A
check that holds the editor thread at a line hands `emitting`, which the
host's output goes through. -/
def vimStaged (context : Context) (directory : System.FilePath) (files : List (String × String))
    (fileModel : Option FileModel) (realFiles : Bool) (workingDirectory : System.FilePath)
    (home : Option System.FilePath) (emitting : (String → IO Unit) → String → IO Unit) :
    IO
      (Stage Config.Elaborate.Base Config.Elaborate.Handle ×
        Headless.Collaborators Config.Elaborate.Base Config.Elaborate.Handle Vim.Default.scheme) :=
  do
  writeConfig directory files
  let source := Config.Directory.source directory
  let stage ←
    if realFiles then
      Stage.overFiles context source
    else
      Stage.new context context.elaborator source
  let staged := stage.collaborators
  let services ←
    match fileModel with
    | some model =>
      do
        let faked ← Job.FakeFiles.new staged.services.completions model
        pure { staged.services with files := faked.files }
    | none =>
      pure staged.services
  let shipped :=
    Headless.shippedOver EditorCore.EditorPackage.packages #[`Editor] "" [] ""
      (emitting staged.emit) services staged.published staged.held
      (← Config.Elaborate.ModuleFiles.temporary)
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
      clock := staged.clock, loopStarted := staged.loopStarted, workingDirectory, home }
  return (stage, collaborators)

/-- Runs `check` against a host of the Vim scheme that ships (`vimStaged`),
stepped on the check's own thread (`stepping`, over the stage's memory
queue). `false` if the check did not hold or the host did not settle after
it. The directory is removed. -/
def withVimHost (context : Context) (files : List (String × String)) (check : Session → IO Bool)
    (fileModel : Option FileModel := none) (realFiles : Bool := false)
    (workingDirectory : System.FilePath := "/") (home : Option System.FilePath := none)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, collaborators) ←
      vimStaged context directory files fileModel realFiles workingDirectory home emitting
    stepping collaborators stage.memory fun drive => check (Session.ofStage drive directory stage)

/-- `withVimHost` with a real host, in its bracket (`Headless.withHost`),
which returns once its loop has ended. -/
def withRealVimHost (context : Context) (files : List (String × String))
    (check : RealSession → IO Bool) (fileModel : Option FileModel := none)
    (realFiles : Bool := false) (workingDirectory : System.FilePath := "/")
    (home : Option System.FilePath := none)
    (emitting : (String → IO Unit) → String → IO Unit := id) : IO Bool :=
  IO.FS.withTempDir fun directory => do
    let (stage, collaborators) ←
      vimStaged context directory files fileModel realFiles workingDirectory home emitting
    Headless.withHost collaborators (guard := patience) (grace := some hangGuard) fun host => do
        let held ← check (RealSession.ofStage host directory stage)
        let wait ← host.await patience
        return held && (wait == .settled || wait == .ended)

end ConfigTest
