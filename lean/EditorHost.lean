import Lean
import Editor

/-!
# Embedding API

Exported to C (and from there to Rust).

## Live reload by environment swapping

Lean environments are immutable values, and a declaration can't be
redefined. So instead of mutating one environment, config is an ordered
list of named *chunks* (think: files), and every reload builds a fresh
environment and swaps it in:

* `base` is the state right after `import Editor` (+ `open Editor`). It is
  never re-imported; reloads start from this value.
* Each chunk caches the elaborator state *after* it. Changing chunk `k`
  re-elaborates only chunks `k..n`, starting from chunk `k-1`'s cached state.
* A reload is atomic: if any re-elaborated chunk fails, the session keeps
  its previous chunks and state untouched.
* `eval` is a scratch REPL on top of the current state. Scratch definitions
  are discarded by the next reload (put things you want to keep in a chunk).

Old environments are freed by reference counting once nothing points to
them.
-/

open Lean Elab

namespace EditorHost

structure Chunk where
  name : String
  src : String
  /-- Elaborator state after this chunk. -/
  after : Command.State

structure Session where
  base : Command.State
  chunks : IO.Ref (Array Chunk)
  /-- Current state: last chunk's `after`, plus any scratch evals. -/
  state : IO.Ref Command.State

structure EvalResult where
  ok : Bool
  output : String

def defaultOpts : Options :=
  -- Elaborate synchronously so every message lands in the command state.
  ({} : Options).setBool `Elab.async false

/-- Elaborate `src` on top of `st`. Returns the new state, whether it
elaborated without errors, and the rendered messages. -/
def elabOn (st : Command.State) (fileName src : String) :
    IO (Command.State × Bool × String) := do
  let inputCtx := Parser.mkInputContext src fileName
  let fs ← IO.processCommands inputCtx {} { st with messages := {} }
  let cst := fs.commandState
  let rendered ← cst.messages.toList.mapM fun m => m.toString
  return (cst, !cst.messages.hasErrors, String.join rendered)

@[export editor_session_new]
def sessionNew (sysroot : String) (oleanDir : String) : IO Session := do
  initSearchPath ⟨sysroot⟩ [⟨oleanDir⟩]
  unsafe enableInitializersExecution
  let env ← importModules #[{ module := `Editor }] defaultOpts (loadExts := true)
  let (base, ok, out) ← elabOn (Command.mkState env {} defaultOpts) "<prelude>" "open Editor"
  unless ok do throw <| IO.userError s!"prelude failed:\n{out}"
  return { base, chunks := ← IO.mkRef #[], state := ← IO.mkRef base }

/-- Each chunk starts from the previous chunk's environment but with the
base scopes, so `open`/`namespace` don't leak between chunks — like files. -/
private def chunkStart (base : Command.State) (prev : Option Chunk) : Command.State :=
  match prev with
  | none => base
  | some c => { c.after with scopes := base.scopes }

/-- Re-elaborate `todo` on top of `kept`, then swap in the result if every
chunk succeeded. -/
private def rebuild (s : Session) (kept : Array Chunk) (todo : List (String × String)) :
    IO EvalResult := do
  let start ← IO.monoMsNow
  let mut chunks := kept
  let mut log := ""
  for (name, src) in todo do
    let (after, ok, out) ← elabOn (chunkStart s.base chunks.back?) name src
    log := log ++ out
    unless ok do
      return { ok := false,
               output := log ++ s!"reload aborted in chunk '{name}'; keeping previous state\n" }
    chunks := chunks.push { name, src, after }
  s.chunks.set chunks
  s.state.set (chunkStart s.base chunks.back?)
  let ms := (← IO.monoMsNow) - start
  return { ok := true,
           output := log ++ s!"re-elaborated {todo.length} of {chunks.size} chunk(s) in {ms} ms\n" }

/-- Add or replace the chunk called `name`. Replacing re-elaborates it and
every later chunk; a new chunk is appended. -/
@[export editor_session_set_chunk]
def sessionSetChunk (s : Session) (name src : String) : IO EvalResult := do
  let chunks ← s.chunks.get
  match chunks.findIdx? (·.name == name) with
  | none => rebuild s chunks [(name, src)]
  | some i =>
    let later := (chunks.extract (i + 1) chunks.size).toList.map fun c => (c.name, c.src)
    rebuild s (chunks.extract 0 i) ((name, src) :: later)

/-- Remove the chunk called `name`, re-elaborating every later chunk. -/
@[export editor_session_remove_chunk]
def sessionRemoveChunk (s : Session) (name : String) : IO EvalResult := do
  let chunks ← s.chunks.get
  match chunks.findIdx? (·.name == name) with
  | none => return { ok := false, output := s!"no chunk named '{name}'" }
  | some i =>
    let later := (chunks.extract (i + 1) chunks.size).toList.map fun c => (c.name, c.src)
    rebuild s (chunks.extract 0 i) later

/-- Elaborate scratch commands on top of the current state. -/
@[export editor_session_eval]
def sessionEval (s : Session) (src : String) : IO EvalResult := do
  let (st, ok, output) ← elabOn (← s.state.get) "<scratch>" src
  if ok then s.state.set st
  return { ok, output }

private def entryTypeOk (ty : Expr) : Bool :=
  ty == mkApp (mkConst ``Editor.EditorM) (mkConst ``Unit) ||
  ty == mkApp (mkConst ``IO) (mkConst ``Unit)

private unsafe def runUnsafe (s : Session) (name : String) : IO EvalResult := do
  let st ← s.state.get
  let n := name.toName
  let some info := st.env.find? n
    | return { ok := false, output := s!"unknown declaration '{name}'" }
  unless entryTypeOk info.type do
    return { ok := false, output := s!"'{name}' : {info.type}, expected EditorM Unit" }
  match st.env.evalConst (Editor.EditorM Unit) defaultOpts n with
  | .error e => return { ok := false, output := e }
  | .ok act =>
    try
      act
      return { ok := true, output := "" }
    catch e =>
      return { ok := false, output := s!"runtime error: {e}" }

@[implemented_by runUnsafe]
private opaque runSafe (s : Session) (name : String) : IO EvalResult

/-- Run a declaration of type `EditorM Unit` (a "command"). -/
@[export editor_session_run]
def sessionRun (s : Session) (name : String) : IO EvalResult :=
  runSafe s name

@[export editor_io_error_to_string]
def ioErrorToString (e : IO.Error) : String := toString e

@[export editor_result_ok]
def resultOk (r : EvalResult) : Bool := r.ok

@[export editor_result_output]
def resultOutput (r : EvalResult) : String := r.output

end EditorHost
