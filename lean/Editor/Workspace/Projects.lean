import Editor.Invocation
import Editor.VersionControl
import Editor.Workspace

/-!
# The project's workspaces

What `find-file-in-project` (`Editor/Workspace/FindInProject.lean`) lists:
every checkout of the focused workspace's project, as plain values. All of
it is pure.

## What is asked

`Asked` is what the picker's source and its accept are handed: the git
program, the repository whose worktrees are listed (the current
workspace's root when git found it, otherwise none, and then no git runs),
the project's name, the current workspace's location, and the table's
workspaces of the project (`Known`), in table order, each with its label.
It travels as plain arguments (`Asked.toArguments`, `Asked.ofArguments?`):
the repository as `false`, or `true` and the root; each location as
`Location.arguments`, the known workspaces after their count.

## The entries

`entries` is the project's workspaces:

1. **One entry for each worktree**, in the reply's order, the main one
   first. A worktree the table knows (a `Known` at `.local` of the same
   path) takes the table's label and location. Any other is labelled by
   `Workspace.labelOf` with the project's name, its head as the branch
   (`Head.branch`) and `.local` of its path, and is not known.
2. **Then each known workspace no worktree matched**, in table order: a
   registered workspace that is not local, a separate clone of the same
   origin, or every workspace of a project git did not find.
3. **De-duplicated by location**: a location listed twice gives one entry.
4. **The current workspace last**: the entry at `Asked.current` is moved to
   the end.
5. **Its text is its label.** Where two entries share a label, each of them
   is `<label> (<annotation>)` instead, so every entry can be chosen, as a
   registered remote session on `main` beside the local `r@main` is.

Each entry's annotation is its root, for a location that has one, and
`Location.describe` otherwise. `resolveExact` takes the entry whose text is
an answer exactly.

## Where an addition goes

| Addition | Where |
|---|---|
| The typed text phase 4 hands | A trailing field of the choose order (`Editor/Workspace/FindInProject.lean`), appended after `Location.arguments` when `find-file-in-workspace` is run |
| A jj workspace list | A second list `entries` takes, beside `worktrees` |

Pinned by `ModelTest.projectWorkspaceChecks`, pure, and through the picker
by `ModelTest.findInProjectChecks`.
-/

namespace Editor.Workspace.Projects

/-- A workspace of the project the table has. -/
structure Known where
  /-- Its location, its key in the table. -/
  location : Location
  /-- Its label, the table's (`Workspace.label`). -/
  label : String
  deriving DecidableEq, Repr

/-- What the picker's source and its accept are handed ("What is asked", in
the module docs). -/
structure Asked where
  /-- The git program. -/
  git : String
  /-- The root whose worktrees are listed: the current workspace's, when git
  found it; none, and no git runs, otherwise. -/
  repository : Option System.FilePath
  /-- The project's name. -/
  name : String
  /-- The focused buffer's workspace's location. -/
  current : Location
  /-- The table's workspaces of the project, in table order, the current one
  among them. -/
  known : Array Known
  deriving DecidableEq, Repr

/-- One of the project's workspaces, as the picker lists it. -/
structure Entry where
  /-- Where it is. -/
  location : Location
  /-- What the prompt matches and answers: its label, or its label and its
  annotation where another entry has its label. -/
  text : String
  /-- Its root, or `Location.describe` for a location with none. -/
  annotation : String
  /-- Whether the table has it. -/
  known : Bool
  deriving DecidableEq, Repr

/-- `asked` as plain arguments ("What is asked", in the module docs). -/
def Asked.toArguments (asked : Asked) : List Argument :=
  let repository : List Argument :=
    match asked.repository with
    | some root => [.bool true, .str root.toString]
    | none => [.bool false]
  [.str asked.git] ++ repository ++ [.str asked.name] ++ asked.current.arguments ++
    [.nat asked.known.size] ++
    asked.known.toList.flatMap fun known => known.location.arguments ++ [.str known.label]

/-- The `count` known workspaces `arguments` start with, and the rest. -/
def knownOf? : Nat → List Argument → Option (List Known × List Argument)
  | 0, rest => some ([], rest)
  | count + 1, arguments => do
    let (location, rest) ← Location.of? arguments
    match rest with
    | .str label :: rest =>
      let (others, rest) ← knownOf? count rest
      return ({ location, label } :: others, rest)
    | _ =>
      none

/-- What `arguments` ask (`Asked.toArguments`), if they are that; anything
after them is ignored. -/
def Asked.ofArguments? (arguments : List Argument) : Option Asked := do
  let (git, arguments) ←
    match arguments with
    | .str git :: rest =>
      some (git, rest)
    | _ =>
      none
  let (repository, arguments) ←
    match arguments with
    | .bool true :: .str root :: rest =>
      some (some (root : System.FilePath), rest)
    | .bool false :: rest =>
      some (none, rest)
    | _ =>
      none
  let (name, arguments) ←
    match arguments with
    | .str name :: rest =>
      some (name, rest)
    | _ =>
      none
  let (current, arguments) ← Location.of? arguments
  let (known, _) ←
    match arguments with
    | .nat count :: rest =>
      knownOf? count rest
    | _ =>
      none
  return { git, repository, name, current, known := known.toArray }

/-- What is checked out in a worktree, as a workspace's branch. -/
def Head.branch : VersionControl.Head → Branch
  | .branch name => .named name
  | .detached => .detached

/-- What an entry at `location` is annotated with: its root, or how to
reach it for a location with none. -/
def annotationOf (location : Location) : String :=
  match location.root? with
  | some root => root.toString
  | none => location.describe

/-- Whether `location` is the local checkout at `path`. -/
def isAt (location : Location) (path : System.FilePath) : Bool :=
  match location with
  | .local root => Process.trimmed root == Process.trimmed path
  | _ => false

/-- The project's workspaces ("The entries", in the module docs): the
worktrees of the reply `worktrees`, then the table's other workspaces of the
project, one per location, the current one last, each told apart from any
other of its label. -/
def entries (asked : Asked) (worktrees : Array VersionControl.Worktree) : Array Entry :=
  let ofKnown (known : Known) : Entry :=
    { location := known.location, text := known.label
      annotation := annotationOf known.location
      known := true }
  let ofWorktree (worktree : VersionControl.Worktree) : Entry :=
    match asked.known.find? (isAt ·.location worktree.path) with
    | some known => ofKnown known
    | none =>
      let location := Location.local worktree.path
      { location, text := Workspace.labelOf asked.name (some (Head.branch worktree.head)) location
        annotation := annotationOf location
        known := false }
  let listed := worktrees.map ofWorktree ++ asked.known.map ofKnown
  let unique :=
    listed.foldl
      (fun (kept : Array Entry) entry =>
        if kept.any (·.location == entry.location) then kept else kept.push entry)
      #[]
  let ordered :=
    unique.filter (·.location != asked.current) ++ unique.filter (·.location == asked.current)
  ordered.map fun entry =>
    if (ordered.filter (·.text == entry.text)).size > 1 then
      { entry with text := s!"{entry.text} ({entry.annotation})" }
    else entry

/-- The entry whose text is `answer` exactly, if one is. -/
def resolveExact (entries : Array Entry) (answer : String) : Option Entry :=
  entries.find? (·.text == answer)

end Editor.Workspace.Projects
