import Editor.Api
import Editor.Command.Call
import Editor.Job
import Editor.Workspace.FindFile
import Editor.Workspace.Projects
import Editor.Workspace.Reach
import VcApi

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
  - Any other worktree is reached (`Editor/Workspace/Reach.lean`) with
    `continuation`: a cached answer at once, otherwise through the unkeyed
    job `project-workspace-find` (`findWork`), which runs the finder and
    records its answer, as a file's open records it, so the workspace's
    identity, branch and store are the finder's. Then
    `find-file-in-workspace` runs at the root found, or the worktree is
    said to be gone: `find-file-in-project: <path> is not a repository any
    more` (`gone`).
- **Running `find-file-in-workspace`** (`openAt`) goes by name
  (`runCommand`), with the location's arguments and then the typed text the
  picker carries, if any (`FindFile.typedArguments`), in the window of the
  view that asked, so config's command in its place runs. A view that is
  gone runs nothing.

## Stepping out of the finder

`find-file-in-another-workspace` (`escapeCommand`) is the escape from the
workspace finder (`Editor/Workspace/FindFile.lean`) to this picker. Compiled
code binds it to `C-x C-d` (`escapeKeys`, described `Find in another
workspace`) in the keymap of the prompt category `workspace-file` alone
(`Config.KeyBinding.category`), so the key holds only while the finder is
open, and config can bind another key there with `bindKey … (category :=
some "workspace-file")`.

1. With no prompt open it says `find-file-in-another-workspace: <no prompt
   is open>` and does nothing else.
2. In a prompt of another category, run by name or bound elsewhere, it says
   `notFinder` and leaves the prompt open.
3. Otherwise it reads the minibuffer's text, closes the finder
   (`cancelPrompt`, which cancels its job), and asks (`ask`) as the
   command does, from the view the finder was asked from. A buffer with no
   project is refused then, with the finder closed, so the message shows.
4. The typed text rides after what is asked in the picker's continuation,
   on the choose order (`ChooseOrder.typed`), and through a reach as an
   argument the order carries (`Reach.Order.carried`), to `openAt`. The
   picker's own input starts empty: the text is for the finder.

The escape asks directly, not by name: it belongs to this picker. The
finder it ends in is reached by name, so config's `find-file-in-workspace`
still applies. Going back from the picker to the first finder is not
built; `minibuffer-cancel` leaves the picker.

## The source and its jobs

`source` answers later, from the job `project-workspaces` (`answer`): it
decodes what is asked from the query's context, lists the repository's
worktrees through the version-control backend a set registers
(`VersionControl.worktrees`, over `VcApi.connect?`), when there is a
repository and a backend, and delivers one batch: each entry's text, annotated with its root. A git
failure throws, and the echo area says `project-workspaces: <why>`. It is
asked once (`reask := .never`); the category's style matches as the text
changes. No key waits on git: it runs only in the jobs.

## Where an addition goes

| Addition | Where |
|---|---|
| A key that runs it | A binding in the default config, under the leader (`config/default/Config/Leader.lean`, pinned by `ConfigTest.defaultConfigChecks`); the scheme binds none, as for `execute-command` |
| A key that steps out of the finder | A binding of `find-file-in-another-workspace` in the prompt category `workspace-file` |
| Another value carried from the finder | A trailing field of `ChooseOrder`, after the typed text, and an argument the reach carries |
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

/-- The worktrees of what is asked, through `connect`, the backend a set
registers (`VcApi.connect?`): none with no repository or no backend,
otherwise the backend's list of them, or why it failed. -/
def worktreesOf (connect : Option (String → System.FilePath → VersionControl.Handler))
    (asked : Projects.Asked) : JobM (Except String (Array VersionControl.Worktree)) := do
  match asked.repository, connect with
  | none, _ | _, none =>
    return .ok #[]
  | some root, some connect =>
    match ← Program.runM (connect asked.git root) VersionControl.worktrees with
    | .ok worktrees =>
      return .ok worktrees
    | .error error =>
      return .error error.describe

/-- The source's job's answer ("The source and its jobs", in the module
docs): one batch of the project's workspaces, through `connect`. Throws
`noProjectAsked` for a query with nothing asked, and why the backend
failed. -/
def answer (connect : Option (String → System.FilePath → VersionControl.Handler))
    (query : Completion.Query) (deliver : Array Completion.Candidate → JobM Unit) : JobM Unit := do
  let some asked := Projects.Asked.ofArguments? query.context | throw noProjectAsked
  match ← worktreesOf connect asked with
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
what was asked, and the text typed in the finder the picker was stepped
into from. -/
structure ChooseOrder where
  /-- The prompt's answer. -/
  answer : String
  /-- The view the prompt was asked from. -/
  view : ViewId
  /-- What was asked. -/
  asked : Projects.Asked
  /-- The text typed in the file finder stepped out of; empty for none. -/
  typed : String := ""
  deriving DecidableEq, Repr

/-- The order as the arguments a job is started with. -/
def ChooseOrder.arguments (order : ChooseOrder) : List Argument :=
  [.str order.answer, .nat order.view.index] ++ order.asked.toArguments ++
    FindFile.typedArguments order.typed

/-- The order `arguments` are, if they are one (`ChooseOrder.arguments`). -/
def ChooseOrder.ofArguments? : List Argument → Option ChooseOrder
  | .str answer :: .nat view :: rest =>
    (Projects.Asked.split? rest).map fun (asked, rest) =>
      { answer, view := ⟨view⟩, asked, typed := FindFile.typedOf rest }
  | _ => none

/-- Runs `find-file-in-workspace` by name at `location`, with `typed` typed
into its input, in the window of `view`; nothing when the view is gone, and
said when no command has the name. -/
def openAt (view : ViewId) (location : Location) (typed : String := "") : EditorM Unit := do
  let .ok target ← view.target | return
  unless
    ←
      runCommand FindFile.name
          { target, arguments := location.arguments ++ FindFile.typedArguments typed } do
    message s!"{FindFile.name}: no such command"

/-- What reaching a worktree not yet found comes to ("Choosing", in the module
docs): `find-file-in-workspace` run at the workspace's root with the typed
text the order carried, or the worktree said to be gone; its find runs under
`project-workspace-find`. -/
def continuation : Reach.Continuation :=
  { job := findJob, name, gone
    reached := fun order location => openAt order.view location (FindFile.typedOf order.carried) }

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
    openAt order.view entry.location order.typed
    return
  let .local path := entry.location | openAt order.view entry.location order.typed
  Reach.reach continuation path order.asked.git order.view (carried :=
      FindFile.typedArguments order.typed)

/-- The accept's job: lists the project's workspaces again, as the source
did, and finishes with what the answer chooses (`chosen`), or says why git
failed. It fails only for arguments that are not a choose order. The
worktrees are listed through `connect`, as the source's are. -/
def chooseWork (connect : Option (String → System.FilePath → VersionControl.Handler))
    (arguments : List Argument) : Work := fun _ => do
  let some order :=
    ChooseOrder.ofArguments? arguments | throw s!"{chooseJob}: its arguments are not a choose order"
  match ← worktreesOf connect order.asked with
  | .error said =>
    return message s!"{name}: {said}"
  | .ok worktrees =>
    return chosen order (Projects.entries order.asked worktrees)

/-- The find job of a worktree not yet found: `Reach.work` handing on to
`continuation`. -/
def findWork : List Argument → Work :=
  Reach.work continuation

/-- Asks for a workspace of the project of the buffer `call` was called for
("Asking", in the module docs), with `typed`, the text typed in a file
finder stepped out of, carried in the continuation for the finder the
choice opens; the picker's own input starts empty. Says why not when it
cannot. -/
def ask (call : Call) (typed : String := "") : EditorM Unit := do
  let (settings, _) ← RegistryRequest.ask .workspaceSettings
  match asked (← editorState) settings call with
  | .error said =>
    message said
  | .ok asked =>
    let opened ←
      prompt (promptLabel asked.name)
          { command := name
            arguments := .bool true :: asked.toArguments ++ FindFile.typedArguments typed } ""
          [.category category [source]] (context := asked.toArguments)
    if let .error refusal := opened then
      message s!"{name}: {refusal.describe}"

/-- `find-file-in-project` ("The command", in the module docs): with an
answer, `true` and what was asked, it chooses; otherwise it asks, or says
why not. -/
def command (call : Call) : EditorM Unit := do
  match call.arguments with
  | .str answer :: .bool true :: rest =>
    let answer := answer.trimAscii.toString
    if answer.isEmpty then
      return
    let some (asked, rest) := Projects.Asked.split? rest | message noProjectAsked
    let order : ChooseOrder :=
      { answer, view := call.target.window.id, asked, typed := FindFile.typedOf rest }
    if let .error refusal← startJob chooseJob order.arguments then
      message s!"{name}: {refusal.describe}"
  | _ =>
    ask call

/-- The name the escape from the workspace finder is registered under. -/
def escapeName : String :=
  "find-file-in-another-workspace"

/-- The escape's default key, in the workspace finder's prompt category. -/
def escapeKeys : List Key :=
  [Key.chord { logical := .character "x", modifiers := { control := true } },
    Key.chord { logical := .character "d", modifiers := { control := true } }]

/-- The escape's description for the key hints. -/
def escapeDesc : String :=
  "Find in another workspace"

/-- What the escape says when the open prompt is not the workspace finder's. -/
def notFinder : String :=
  s!"{escapeName}: the open prompt is not a workspace's file finder"

/-- `find-file-in-another-workspace` ("Stepping out of the finder", in the
module docs): closes the open workspace finder and asks for a workspace of
the project of the buffer it was asked from, carrying the text typed in
it. -/
def escapeCommand (_ : Call) : EditorM Unit := do
  let state ← editorState
  let some open_ := state.prompt | message s!"{escapeName}: {PromptRefusal.notOpen.describe}"
  if open_.candidates.category != some FindFile.category then
    message notFinder
    return
  let typed ←
    match state.target? open_.view with
    | some minibuffer =>
      minibuffer.buffer.text.read
    | none =>
      pure ""
  discard cancelPrompt
  let .ok target ← open_.asker.target | return
  ask { target, arguments := [] } typed

end Editor.Workspace.FindInProject
