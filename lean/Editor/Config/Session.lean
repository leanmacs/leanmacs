import Editor.Config.Diagnostic
import Editor.Config.Registry

/-!
# The config session: what one reload builds

Lean environments are immutable and a declaration cannot be redefined. So a
config is an ordered list of named *chunks* (in practice, files), each
elaborated on the state the one before it left, and a reload builds a new
config from the chunks as they now are. `build` is one reload, from reading
the source to the registrations of the new config's `setup`. It installs
nothing: it returns an `Outcome`, and the reducer (`Editor/Config/Reload.lean`)
decides what becomes of it.

The decisions are here, in plain Lean with no elaborator in it:

- **What is elaborated.** Each chunk caches the state after it. The chunks a
  reload keeps are the longest run, from the first, whose names and texts are
  what the source now holds (`plan`); every chunk after that is elaborated
  again, the first of them on the cached state before it.
- **The base is imported once.** A reload that is handed the base does not
  import it, and every outcome hands the base back, whether the config was
  built or not.
- **All or nothing.** A chunk that fails ends the reload: no later chunk is
  elaborated and `setup` is not run.
- **`setup` runs last, here.** The config's `setup` program is produced from
  the state after the last chunk and run against the collecting handler
  (`Registrations.ofSetup`), on the thread that runs `build`. A `setup` that
  throws, or registers something that is refused, rejects the reload.
- **Failure is data.** A rejected outcome carries diagnostics. A port that
  throws is a rejected outcome too, with a diagnostic that names what was
  being done.

## The ports

`build` reaches the outside through two ports, each a record of functions:

- `Elaborator σ` turns text into state. Its real adapter is the only module
  that imports Lean's elaborator (`Editor/Config/Elaborate.lean`), and `σ` is
  then the elaborator's state. The core never looks inside a `σ`.
- `Source` is where the chunks come from. Its real adapter reads a directory
  (`Editor/Config/Directory.lean`).

The model tests run `build` on hand-written fakes of both
(`ModelTest.sessionChecks`). `config-test` checks each real adapter against
what those fakes assume.
-/

namespace Editor.Config

/-- A chunk as the source holds it. -/
structure SourceChunk where
  /-- The chunk's name: what a diagnostic about it is tagged with. -/
  name : String
  /-- The chunk's Lean source. -/
  text : String
  deriving DecidableEq, Repr

/-- A chunk of a config that was built: its source, and the elaborator's
state after it. -/
structure Chunk (σ : Type) where
  /-- The chunk's name. -/
  name : String
  /-- The chunk's Lean source. -/
  text : String
  /-- The state after this chunk: what the next chunk is elaborated on. -/
  after : σ

/-- The port a config's source is read through. -/
structure Source where
  /-- The chunks as they now are, in the order they are elaborated. Throws
  when they cannot be read. -/
  chunks : IO (Array SourceChunk)

/-- What elaborating one chunk gave. -/
structure ChunkResult (σ : Type) where
  /-- What the elaborator had to say: errors, and warnings as well. -/
  diagnostics : Array Diagnostic
  /-- The state after the chunk; `none` when the chunk failed, and then
  `diagnostics` holds an error. -/
  state : Option σ

/-- The port config is elaborated through. A `σ` is the elaborator's state
after some chunks. -/
structure Elaborator (σ : Type) where
  /-- Imports the base: the state the first chunk is elaborated on. Throws
  when it cannot. -/
  base : IO σ
  /-- Elaborates one chunk on the state before it. -/
  chunk : σ → SourceChunk → IO (ChunkResult σ)
  /-- The `setup` program of a config whose last chunk left this state, or
  why there is none. -/
  setup : σ → IO (Except (Array Diagnostic) (SetupM Unit))

/-- What a reload does with the chunks that are loaded. -/
structure Plan (σ : Type) where
  /-- The loaded chunks that are kept as they are, with their states. -/
  kept : Array (Chunk σ)
  /-- The chunks to elaborate, in order, after the kept ones. -/
  todo : Array SourceChunk

/-- What a reload does, given the chunks that are `loaded` and the chunks the
source now holds. -/
def plan {σ : Type} (loaded : Array (Chunk σ)) (source : Array SourceChunk) : Plan σ :=
  let same :=
    (loaded.zip source).takeWhile fun (chunk, wanted) =>
      chunk.name == wanted.name && chunk.text == wanted.text
  { kept := same.map (·.1), todo := source.extract same.size source.size }

/-- A config that a reload built. -/
structure Built (σ : Type) where
  /-- Its chunks, each with the state after it. -/
  chunks : Array (Chunk σ)
  /-- What its `setup` registers. -/
  registrations : Registrations

/-- What one reload came to. -/
structure Outcome (σ : Type) where
  /-- The base, if the reload was given it or imported it. -/
  base : Option σ
  /-- What the reload has to say: the errors that rejected it, and warnings. -/
  diagnostics : Array Diagnostic
  /-- The config, if every chunk elaborated and its `setup` was accepted;
  `none` when the reload is rejected. -/
  built : Option (Built σ)

/-- The diagnostic that `source` failed with `message`, about no place in
particular. -/
def failure (source message : String) : Diagnostic :=
  { source, severity := .error, message }

/-- One reload: reads the source, elaborates the chunks that changed, and
runs the new config's `setup`. `base` is the base if an earlier reload
imported it, and `loaded` the chunks of the config that is installed. -/
def build {σ : Type} (elaborator : Elaborator σ) (source : Source) (base : Option σ)
    (loaded : Array (Chunk σ)) : IO (Outcome σ) := do
  let base ←
    match base with
    | some base => pure base
    | none =>
      try
        elaborator.base
      catch error =>
        return { base := none, diagnostics := #[failure "base" (toString error)], built := none }
  let wanted ←
    try
      source.chunks
    catch error =>
      return { base := some base, diagnostics := #[failure "config" (toString error)], built := none }
  let steps := plan loaded wanted
  let mut chunks := steps.kept
  let mut diagnostics := #[]
  for chunk in steps.todo do
    let before := (chunks.back?.map (·.after)).getD base
    let result ←
      try
        elaborator.chunk before chunk
      catch error =>
        pure { diagnostics := #[failure chunk.name (toString error)], state := none }
    diagnostics := diagnostics ++ result.diagnostics
    match result.state with
    | none => return { base := some base, diagnostics, built := none }
    | some after => chunks := chunks.push { chunk with after }
  let some last := chunks.back?
    | return { base := some base, diagnostics,
               built := some { chunks := #[], registrations := {} } }
  let program ←
    try
      elaborator.setup last.after
    catch error =>
      pure (.error #[failure "setup" (toString error)])
  match program with
  | .error problems =>
    return { base := some base, diagnostics := diagnostics ++ problems, built := none }
  | .ok setup =>
    match Registrations.ofSetup setup with
    | .error message =>
      return { base := some base, diagnostics := diagnostics.push (failure "setup" message),
               built := none }
    | .ok registrations =>
      return { base := some base, diagnostics, built := some { chunks, registrations } }

end Editor.Config
