import Editor.Api
import Editor.Command.Call
import Editor.Job
import Editor.VersionControl.Git
import Editor.Workspace.Attach
import Editor.Workspace.FindFile
import Editor.Workspace.Projects

/-!
# `find-file-in-project`

A picker over the project's workspaces (`Editor/Workspace/Projects.lean`)
whose continuation is `find-file-in-workspace` (`Editor/Workspace/FindFile.lean`)
rooted at the workspace chosen. It lists every worktree of the focused
workspace's repository, those no file has been opened in among them, and
the table's other workspaces of the project.

## What is asked

`asked`, pure, decides it from the editor state, config's workspace
settings and the call:

- **A buffer with no workspace** has no project: the command says
  `find-file-in-project: <buffer> is in no project` (`noProject`) and opens
  nothing.
- **Otherwise** it asks of the buffer's workspace's project: the git
  program, the repository (the workspace's root when git found it,
  `Workspace.foundByGit`, else none, so a project found by config or by
  markers, or a workspace that is not local, runs no git), the project's
  name, the workspace's location and the table's workspaces of the
  project, each with its label.

## The command

- **Asking.** It opens the prompt `Find file in a workspace of <name>: `
  over the category `project-workspace`, the source `project-workspaces` by
  default, with what is asked as its sources' context and after `true` in
  its continuation, itself. A refused prompt is said in the echo area. It
  runs no process.
- **Accepting**, an answer then `true` then what is asked: a blank answer
  runs nothing, as `search-bindings` does. Otherwise it starts the unkeyed
  job `project-workspace-choose` (`chooseWork`), which lists the worktrees
  again, as the source did, and finishes with `chosen`. The prompt's
  answer is a candidate's text, its label, so the list is made again to
  map it to a location; it is the same pure `entries`, so it matches the
  listing unless git changed in between.
- **Choosing** (`chosen`): the entry whose text is the answer exactly,
  otherwise the first hit of the category's style over the texts, as
  `search-bindings` resolves its answer. None is said (`noMatch`).
  - A workspace the table has: `find-file-in-workspace` runs there. A
    registered workspace that is not local reaches its refusal so.
  - A worktree whose answer the table caches under the config generation:
    its workspace's, or `gone` when the cache says it is none.
  - Otherwise the unkeyed job `project-workspace-find` (`findWork`) runs the
    finder on the worktree's path, and its command (`found`) records the
    answer (`recordWorkspace`), as a file's open records it, so the
    workspace's identity, branch and store are the finder's. Then
    `find-file-in-workspace` runs at the root found, or the worktree is
    said to be gone: `find-file-in-project: <path> is not a repository any
    more`.
- **Running `find-file-in-workspace`** (`openAt`) goes by name
  (`runCommand`), with the location's arguments, in the window of the view
  that asked, so config's command in its place runs. A view that is gone
  runs nothing.

## The source and its jobs

`source` answers later, from the job `project-workspaces` (`answer`): it
decodes what is asked from the query's context, lists the repository's
worktrees through git (`VersionControl.worktrees`), when there is one, and
delivers one batch: each entry's text, annotated with its root. A git
failure throws, and the echo area says `project-workspaces: <why>`. It is
asked once (`reask := .never`); the category's style matches as the text
changes. No key waits on git: it runs only in the jobs.

## Where an addition goes

| Addition | Where |
|---|---|
| A key that runs it | A binding of `find-file-in-project`, in the input scheme's table |
| The typed text of the file finder | A trailing field of `ChooseOrder`, appended to the arguments `openAt` hands `find-file-in-workspace` after the location |
| Another kind of workspace list, jj's | A list `Projects.entries` takes, read beside `worktreesOf` |

Pinned by `ModelTest.findInProjectChecks`, on the loop's driver over the
models, by `ModelTest.sourceContractChecks`, and over the real hosts'
registry by `ConfigTest.shippedChecks`.
-/

namespace Editor.Workspace.FindInProject

/-- The name the command is registered under. -/
def name : String :=
  "find-file-in-project"

/-- The name the source is registered under. -/
def sourceName : String :=
  "project-workspaces"

/-- The name the source's job is registered under. -/
def job : String :=
  "project-workspaces"

/-- The name the job that lists the workspaces again on accept is
registered under. -/
def chooseJob : String :=
  "project-workspace-choose"

/-- The name the job that finds a worktree not yet found is registered
under. -/
def findJob : String :=
  "project-workspace-find"

/-- The category of the prompt and of the source. -/
def category : String :=
  "project-workspace"

/-- What the command says in the buffer `buffer`, which has no
workspace. -/
def noProject (buffer : String) : String :=
  s!"{name}: {buffer} is in no project"

/-- What the source's job says when its query carries nothing asked. -/
def noProjectAsked : String :=
  s!"{sourceName}: asked with no project"

/-- What the command says when no workspace of the project `project`
matches `answer`. -/
def noMatch (project answer : String) : String :=
  s!"{name}: no workspace of {project} matches {answer}"

/-- What the command says of a worktree whose directory is in no
repository any more. -/
def gone (path : System.FilePath) : String :=
  s!"{name}: {path} is not a repository any more"

/-- The prompt's label for the project named `project`. -/
def promptLabel (project : String) : String :=
  s!"Find file in a workspace of {project}: "

/-- What `call` asks in `state`, with config's workspace `settings` ("What is
asked", in the module docs), or what the command says instead. -/
def asked (state : EditorState) (settings : Settings) (call : Call) :
    Except String Projects.Asked :=
  match state.workspaceOf? call.target.window.buffer with
  | none => .error (noProject call.target.buffer.name)
  | some (workspace, project) =>
    let known :=
      (state.workspaces.workspaces.map (·.1)).filterMap fun other =>
        if other.project.identity == project.identity then
          some { location := other.location, label := other.label }
        else none
    .ok {
        git := settings.git
        repository := if foundByGit workspace then workspace.location.root? else none
        name := project.name, current := workspace.location, known }

/-- The worktrees of what is asked: none with no repository, otherwise git's
list of them, or why it failed. -/
def worktreesOf (asked : Projects.Asked) : JobM (Except String (Array VersionControl.Worktree)) :=
  do
  match asked.repository with
  | none =>
    return .ok #[]
  | some root =>
    match ← Program.runM (VersionControl.Git.handler asked.git root) VersionControl.worktrees with
    | .ok worktrees =>
      return .ok worktrees
    | .error error =>
      return .error error.describe

/-- The source's job's answer ("The source and its jobs", in the module
docs): one batch of the project's workspaces. Throws `noProjectAsked` for a
query with nothing asked, and why git failed. -/
def answer (query : Completion.Query) (deliver : Array Completion.Candidate → JobM Unit) :
    JobM Unit := do
  let some asked := Projects.Asked.ofArguments? query.context | throw noProjectAsked
  match ← worktreesOf asked with
  | .error said =>
    throw said
  | .ok worktrees =>
    deliver <|
        (Projects.entries asked worktrees).map fun entry =>
          { text := entry.text, annotation := some entry.annotation }

/-- The source: of the category `project-workspace`, answered later, once, by
the job `project-workspaces`. -/
def source : Completion.Source :=
  Completion.Source.answeringLater sourceName category job

/-- What the accept's job is started with: the answer, the view that asked,
and what was asked. -/
structure ChooseOrder where
  /-- The prompt's answer. -/
  answer : String
  /-- The view the prompt was asked from. -/
  view : ViewId
  /-- What was asked. -/
  asked : Projects.Asked
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def ChooseOrder.arguments (order : ChooseOrder) : List Argument :=
  [.str order.answer, .nat order.view.index] ++ order.asked.toArguments

/-- The order `arguments` are, if they are one (`ChooseOrder.arguments`). -/
def ChooseOrder.ofArguments? : List Argument → Option ChooseOrder
  | .str answer :: .nat view :: rest =>
    (Projects.Asked.ofArguments? rest).map fun asked => { answer, view := ⟨view⟩, asked }
  | _ => none

/-- What the find of a worktree not yet found is started with: its directory,
the git program, config's roots, the config generation and the asking
view. -/
structure FindOrder where
  /-- The worktree's directory. -/
  path : System.FilePath
  /-- The git program. -/
  git : String
  /-- Config's workspace roots. -/
  roots : Array ConfigRoot := #[]
  /-- The config generation the answer is found under. -/
  generation : Nat
  /-- The view that asked. -/
  view : ViewId
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def FindOrder.arguments (order : FindOrder) : List Argument :=
  [.str order.path.toString, .str order.git, .nat order.generation, .nat order.view.index] ++
    order.roots.toList.flatMap rootArguments

/-- The order `arguments` are, if they are one (`FindOrder.arguments`). -/
def FindOrder.ofArguments? : List Argument → Option FindOrder
  | .str path :: .str git :: .nat generation :: .nat view :: roots =>
    (rootsOf? roots).map fun roots => { path, git, roots, generation, view := ⟨view⟩ }
  | _ => none

/-- Runs `find-file-in-workspace` by name at `location`, in the window of
`view`; nothing when the view is gone, and said when no command has the
name. -/
def openAt (view : ViewId) (location : Location) : EditorM Unit := do
  let .ok target ← view.target | return
  unless ← runCommand FindFile.name { target, arguments := location.arguments } do
    message s!"{FindFile.name}: no such command"

/-- What an accept comes to ("Choosing", in the module docs), over the
project's workspaces `entries` listed again. -/
def chosen (order : ChooseOrder) (entries : Array Projects.Entry) : EditorM Unit := do
  let entry ←
    match Projects.resolveExact entries order.answer with
    | some entry =>
      pure (some entry)
    | none =>
      let hits ← matchByCategory category order.answer (entries.map (·.text))
      pure (hits[0]?.bind fun hit => entries[hit.index]?)
  let some entry := entry | message (noMatch order.asked.name order.answer)
  let state ← editorState
  if (state.workspaces.workspace? entry.location).isSome then
    openAt order.view entry.location
    return
  let .local path := entry.location | openAt order.view entry.location
  let (settings, generation) ← RegistryRequest.ask .workspaceSettings
  match state.workspaces.cached? path generation with
  | some (some location) =>
    openAt order.view location
  | some none =>
    message (gone path)
  | none =>
    let find : FindOrder :=
      { path, git := order.asked.git, roots := settings.roots, generation, view := order.view }
    if let .error refusal← startJob findJob find.arguments then
      message s!"{name}: {refusal.describe}"

/-- The accept's job: lists the project's workspaces again, as the source
did, and finishes with what the answer chooses (`chosen`), or says why git
failed. It fails only for arguments that are not a choose order. -/
def chooseWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ChooseOrder.ofArguments? arguments | throw s!"{chooseJob}: its arguments are not a choose order"
  match ← worktreesOf order.asked with
  | .error said =>
    return message s!"{name}: {said}"
  | .ok worktrees =>
    return chosen order (Projects.entries order.asked worktrees)

/-- The command a finished find hands the loop: the answer recorded, as a
file's open records it, then `find-file-in-workspace` run at the root found,
or the worktree said to be gone. -/
def found (order : FindOrder) (answer : Option Found) : EditorM Unit := do
  discard <| EditorState.ask (.recordWorkspace order.path order.generation answer)
  match answer with
  | some found =>
    openAt order.view (.local found.root)
  | none =>
    message (gone order.path)

/-- The find job: runs the finder on its order's path with its order's
settings, and finishes with `found`. It fails only for arguments that are
not a find order. -/
def findWork (arguments : List Argument) : Work := fun _ => do
  let some order :=
    FindOrder.ofArguments? arguments | throw s!"{findJob}: its arguments are not a find order"
  return found order (← find { roots := order.roots, git := order.git } order.path)

/-- `find-file-in-project` ("The command", in the module docs): with an
answer, `true` and what was asked, it chooses; otherwise it asks, or says
why not. -/
def command (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str answer :: .bool true :: rest =>
    let answer := answer.trimAscii.toString
    if answer.isEmpty then
      return
    let some asked := Projects.Asked.ofArguments? rest | message noProjectAsked
    let order : ChooseOrder := { answer, view := call.target.window.id, asked }
    if let .error refusal← startJob chooseJob order.arguments then
      message s!"{name}: {refusal.describe}"
  | _ =>
    let (settings, _) ← RegistryRequest.ask .workspaceSettings
    match asked (← editorState) settings call with
    | .error said =>
      message said
    | .ok asked =>
      let opened ←
        prompt (promptLabel asked.name)
            { command := name, arguments := .bool true :: asked.toArguments } ""
            [.category category [source]] (context := asked.toArguments)
      if let .error refusal := opened then
        message s!"{name}: {refusal.describe}"

end Editor.Workspace.FindInProject
