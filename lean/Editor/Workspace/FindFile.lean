import Editor.Api
import Editor.Command.Call
import Editor.Completion.Filtering
import Editor.Files
import Editor.Job
import Editor.Workspace
import Editor.Workspace.Lister

/-!
# `find-file-in-workspace`

The finder of a workspace's files: a prompt over a source a command
filters (`Editor/Completion/Filtering.lean`), whose lister is the one
`Workspace.lister` chooses for the workspace (`Editor/Workspace/Lister.lean`)
and whose filter is fzf, both run at the workspace's root, in the source's
job. Its candidates are paths relative to the root.

## What is searched

`searched`, pure, decides it from the editor state, config's workspace
settings and the call:

- **A location as the command's argument** (`Location.arguments`, the
  first arguments): the workspace the table has there, refused with
  `noSuchWorkspace` when it has none. What follows the location is left
  for the typed text a later phase hands, and ignored.
- **Otherwise the workspace of the buffer of the window it was called
  with.**
- **A workspace whose location cannot both read files and run commands**
  (`Location.can`) is refused with `cannotList`, which names it; no prompt
  opens and no process is started.
- **Otherwise its root** is searched, its label (`Workspace.label`,
  `name@branch`) names it, and its lister is `Workspace.lister`'s.
- **A buffer with no workspace** is searched in the directory a command
  run for it would use, which the state decides for `:!` too
  (`EditorState.commandDirectoryOf`, `Editor/State.lean`): its file's
  directory, or the editor's working directory for a buffer with no file. The directory is its label, and the
  fallback lists it.
- **Other arguments**, such as a count and a register a Vim key hands a
  command, are ignored.

## The command

- **Asking.** It opens the prompt `Find file in <label>: ` over the
  category `workspace-file`, the source `workspace-files` by default, with
  the root as the place its sources read names under and the lister as
  their context (`prompt`'s `place` and `context`, `Completion.Query`).
  Which lister answered is so recorded with the prompt
  (`Candidates.context`, decoded by `Lister.ofArguments?`). A refused
  prompt is said in the echo area. The command returns once the prompt is
  open: it runs no process.
- **Accepting.** It is its own continuation, with `true` and the root
  after the answer. The answer, under the root, or as it is when it is
  absolute, is opened by running `open-file` by name (`runCommand`), so a
  command config registers under that name opens it in place of the
  compiled one; the file opens in the window the prompt was asked from.

## The source and its job

`source` is a filtering source (`Completion.Filtering.source`) of the
category `workspace-file`, answered by the job `workspace-files`
(`answer`): it decodes the lister from the query's context and the root
from its place, runs the lister at the root and fzf over its output with
the typed text (`found`), and delivers the first matches, each made
relative (`Lister.relative`), as one batch. A lister's exit in its
`partialListing`, `find`'s 1 past a directory it cannot read, still
answers what it listed. A failure throws, naming the
program and the lister's origin, and the echo area says
`workspace-files: <message>`. A new text cancels the job, which kills its
child. So no key waits on the lister or the filter: they run only in the
job, on the pool.

## Where an addition goes

| Addition | Where |
|---|---|
| A key that runs it | A binding of `find-file-in-workspace`, in the input scheme's table |
| The typed text as an argument | The arguments after the location in `searched` |
| A lister for a remote location | A step of `Workspace.lister`, and `searched` no longer refusing it |

Pinned by `ModelTest.findFileChecks`, on the loop's driver over the
models, by `ModelTest.sourceContractChecks`, and over the real hosts'
registry by `ConfigTest.shippedChecks`.
-/

namespace Editor.Workspace.FindFile

/-- The name the command is registered under. -/
def name : String :=
  "find-file-in-workspace"

/-- The name the source is registered under. -/
def sourceName : String :=
  "workspace-files"

/-- The name the source's job is registered under. -/
def job : String :=
  "workspace-files"

/-- The category of the prompt and of the source, so config can pick its
display and its style as for any category. -/
def category : String :=
  "workspace-file"

/-- What is searched: the root the lister runs at, the label naming it, and
the lister. -/
structure Searched where
  /-- The root: an absolute path on this machine. -/
  root : System.FilePath
  /-- What names it in the prompt's label: the workspace's label, or the
  directory searched. -/
  label : String
  /-- The command that lists its files. -/
  lister : Lister
  deriving DecidableEq, Repr

/-- What the command says when no workspace is known at `location`. -/
def noSuchWorkspace (location : Location) : String :=
  s!"{name}: no workspace is known at {location.describe}"

/-- What the command says of `workspace`, whose location cannot read files
and run commands. -/
def cannotList (workspace : Workspace) : String :=
  s!"{name}: {workspace.label} is {workspace.location.describe}, where files cannot be listed"

/-- What the source's job says when its query carries no lister or no
root. -/
def noWorkspaceAsked : String :=
  s!"{sourceName}: asked with no workspace to list"

/-- What is searched in `workspace` ("What is searched", in the module
docs): its root, its label and its lister; refused with `cannotList` when
its location cannot read files and run commands. -/
def ofWorkspace (settings : Settings) (workspace : Workspace) : Except String Searched :=
  let can := workspace.location.can
  match workspace.location.root? with
  | some root =>
    if can.readFiles && can.runCommands then
      .ok { root, label := workspace.label, lister := lister settings (some workspace) }
    else .error (cannotList workspace)
  | none => .error (cannotList workspace)

/-- What `call` searches in `state`, with config's workspace `settings`
("What is searched", in the module docs), or what the command says
instead. -/
def searched (state : EditorState) (settings : Settings) (call : Call) : Except String Searched :=
  match Location.of? call.arguments with
  | some (location, _) =>
    match state.workspaces.workspace? location with
    | some workspace => ofWorkspace settings workspace
    | none => .error (noSuchWorkspace location)
  | none =>
    let buffer := call.target.window.buffer
    match state.workspaceOf? buffer with
    | some (workspace, _) => ofWorkspace settings workspace
    | none =>
      let directory := state.commandDirectoryOf buffer
      .ok { root := directory, label := directory.toString, lister := lister settings none }

/-- The prompt's label for a search labelled `label`. -/
def promptLabel (label : String) : String :=
  s!"Find file in {label}: "

/-- The filtering of `lister` at `root`: the lister's command there, its
partial-listing statuses, and `filter`, fzf at the root reading the
lister's records by default. -/
def filtering (lister : Lister) (root : System.FilePath)
    (filter : Process.Command :=
      Completion.Filtering.fzf root (if lister.nul then .nul else .newline)) :
    Completion.Filtering :=
  { lister := lister.command root, filter, separator := if lister.nul then .nul else .newline
    partialListing := lister.partialListing }

/-- The matches `filtering` answers for `text`, each made relative to the
root by `lister` (`Lister.relative`); or why not, naming the lister's
origin. -/
def found (filtering : Completion.Filtering) (lister : Lister) (text : String) :
    JobM (Except String (Array String)) := do
  match ← filtering.found text with
  | .error message =>
    return .error s!"{message}, listing with the {lister.origin.name} lister"
  | .ok records =>
    return .ok (records.map lister.relative)

/-- The source's job's answer ("The source and its job", in the module
docs): the lister from the query's context, the root from its place, and
one batch of the matches for its text. Throws `noWorkspaceAsked` for a
query with no lister or no root, and why the lister or the filter failed. -/
def answer (query : Completion.Query) (deliver : Array Completion.Candidate → JobM Unit) :
    JobM Unit := do
  let some lister := Lister.ofArguments? query.context | throw noWorkspaceAsked
  let some root := query.place.directory | throw noWorkspaceAsked
  match ← found (filtering lister root) lister query.text with
  | .error message =>
    throw message
  | .ok records =>
    deliver (records.map Completion.Candidate.ofText)

/-- The source: filtered, of the category `workspace-file`, answered later by
the job `workspace-files`. -/
def source : Completion.Source :=
  Completion.Filtering.source sourceName category job

/-- `find-file-in-workspace` ("The command", in the module docs): with an
answer, `true` and a root, it opens the answer under the root through
`open-file`; otherwise it opens the prompt over what `searched` answers,
or says why not. -/
def command (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str answer :: .bool true :: .str root :: _ =>
    let answered : System.FilePath := answer
    -- One separator between the root and the answer, the root `/` too.
    let path := if answered.isAbsolute then answered else Process.inDirectory root answer
    unless ← runCommand Files.openName { call with arguments := [.str path.toString] } do
      message s!"{Files.openName}: no such command"
  | _ =>
    let (settings, _) ← RegistryRequest.ask .workspaceSettings
    let state ← editorState
    match searched state settings call with
    | .error said =>
      message said
    | .ok searched =>
      let opened ←
        prompt (promptLabel searched.label)
            { command := name, arguments := [.bool true, .str searched.root.toString] } ""
            [.category category [source]] (place :=
            some { directory := some searched.root, home := state.home }) (context :=
            searched.lister.toArguments)
      if let .error refusal := opened then
        message s!"{name}: {refusal.describe}"

end Editor.Workspace.FindFile
