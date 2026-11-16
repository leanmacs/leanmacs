# Projects, workspaces and locations

Which codebase a buffer belongs to, and which checkout of it. Work in
several projects, and in several worktrees of one repository, must not
bleed together: one compilation buffer, one error list and one shell output
shared by everything is what this design exists to prevent. The shell and
compile features are the first that need it; every later feature that
scopes state by codebase or by checkout reads the same values.

Built in `lean/Editor/Workspace.lean` (the data and the table),
`lean/Editor/Workspace/Finder.lean` (the finder),
`lean/Editor/Workspace/Model.lean` and `lean/Editor/Workspace/Contract.lean`
(its model and its contract), `lean/Editor/Workspace/Attach.lean` (a
buffer's workspace and `workspace-current`) and
`lean/Editor/Workspace/Compiled.lean` (their registrations).

## Three layers

- **A project is a codebase.** It is identified by its repository, not by a
  path, by one rule:
  1. a name config declares for a root it declares (`declared`);
  2. otherwise the normalised URL of its `origin` remote (`remote`), so two
     clones of one repository, or a remote checkout of it, are one project;
  3. otherwise its common git directory (`commonDir`), so the worktrees of
     a repository with no remote are one project;
  4. otherwise, for a directory that is no repository, its root (`root`).

  Its name follows the same order: the declared name; the last component of
  the normalised origin; the last component of the directory that holds the
  common git directory; the root's last component.
- **A workspace is one checkout of a project**: its location, which holds
  its one root, set when it is first found and never derived again
  ([agent-hosting.md](agent-hosting.md), "Workspace identity is one stored
  root"); the branch checked out there, or none; and its project. The main
  checkout and each linked worktree of a repository are separate workspaces
  of one project. Two workspaces of one project are shown apart by their
  label, `name@branch`, or `name@<the root's last component>` when the
  checkout is detached or has no branch.
- **A location is where the workspace's files and commands are**:
  - `local root`: on this machine; files and processes go through the
    existing ports.
  - `reachable kind target root`: on a machine a command reaches, a
    Kubernetes pod (`kube`), a container (`docker`), a host (`ssh`).
    Modelled; no adapter is built.
  - `branchOnly remote branch`: somewhere the editor cannot reach, known only
    by the git remote and the branch its work comes back on, a remote agent
    session's. Checking that branch out makes a local workspace of the same
    project.

  A location says what it can do (`Location.can`): read files, run
  commands, watch files. Only `local` can do any of them. A feature asks
  the workspace's location and never assumes the local machine.

### Normalising an origin

`git@host:path`, `ssh://[user@]host[:port]/path` and
`http(s)://[user@]host/path` are each `host/path`, with the host lowercased
and a trailing `/` and `.git` dropped. So `git@github.com:o/r.git`,
`https://github.com/o/r`, `ssh://git@github.com/o/r.git` and
`https://github.com/o/r.git/` are one project, `github.com/o/r`. A remote
of no form this knows, a local path, keeps its path with the same tidying.

## The finder

`Workspace.find` answers "the workspace of this local directory". It is a
port with a pure model and a real implementation (`AGENTS.md`, "ports and
adapters"): the real one is a job over the existing process and file
requests, so it needs no new binding, and the model (`World.find`) is a
world of repositories, marker files and whether git is installed. One
contract (`Workspace.FinderContract`) holds both: `model-test` runs it
against the model and against the real finder on the job model of the
world, and `contract-test` against the real finder over the library's
process and file services, with the world written to a temporary directory
and a fixture standing in for git (`tests/workspaces/git`).

The adapters are tried in order; the first that answers wins.

1. **Config**: the deepest workspace root config declares
   (`workspace root (project)` in `setup`) that holds the directory. It is
   pure, and no process is run. A root that is not absolute, and one root
   declared twice, refuse the `setup`.
2. **Git**: in the directory,

   ```
   git rev-parse --path-format=absolute --show-toplevel --git-common-dir --abbrev-ref HEAD
   git remote get-url origin
   ```

   each through `Process.runWithin`, so it gets its directory's
   environment, with `GIT_DIR` and `GIT_WORK_TREE` removed, 64 KiB of
   output and 5 s at most. The top level is the root; the common directory
   and the origin identify the project; `HEAD` as the third line is a
   detached checkout. `--path-format=absolute` makes git print the common
   directory absolute in a main checkout too, where it otherwise prints
   `.git`; a relative one is still resolved against the directory. A status
   other than 0, a refusal (git missing is `notFound`), a run past its limit
   or output that is not three lines means git does not answer. An `origin`
   run that does not exit 0 means there is no `origin`.
3. **Markers**: the nearest directory, the one asked about or an ancestor,
   holding one of `.git`, `mise.toml`, `Cargo.toml`, `lakefile.lean` and
   `.project`, nearest first and then in that order, read through the file
   port's stamps. A main checkout's `.git` is a directory, which the stamp
   request refuses as `notAFile`: that counts as there. The workspace is its
   own project, identified by its root.

None answering is no workspace: features fall back to the file's directory
(`BufferId.workingDirectory`, `fileDirectory`), and say so where it matters.

**An unborn branch is a limitation.** In a repository with no commit,
`--abbrev-ref HEAD` fails, so git does not answer and the `.git` marker
does: the workspace is rooted right but is its own project, with no branch.

## A buffer's workspace

- **On open.** When a file opens into a buffer (`Files.opened`), the buffer
  is handed to `Workspace.attach`. The finder's answer for the file's
  directory is cached in the editor state, stamped with the config
  generation it was found under; a cached answer under the current
  generation is the buffer's at once and starts no job, so a second file of
  a directory asks git nothing. Otherwise the compiled job `find-workspace`
  runs the finder, and its command records the answer (the workspace and
  its project added, or a workspace found again keeping its root, its
  project and its store and taking its new branch) and gives the buffer its
  workspace, while the buffer still holds a file in that directory. A host
  that registers no find job finds none, and says nothing.
- **What the buffer keeps** is a buffer-local value (`"workspace"`): its
  workspace's location, encoded. The workspace itself is in the editor
  state's table, so a buffer never holds a second copy of what a workspace
  is.
- **The config generation** is a counter the registry bumps on every
  install (`Registry.generation`). A reload that installs is a new
  generation, so the next file opened asks git again: the cache is dropped
  as an install drops the cache of children's environments. Reloading a
  buffer from its file leaves its workspace.
- **A buffer with no file** takes the workspace of the buffer it was made
  from (`BufferId.inheritWorkspace`), or none. The buffers that are made
  from buffers, the shell output and the compilation buffer, arrive with
  the phases that make them.

## What lives where

| State | Where | Examples |
|---|---|---|
| What belongs to one checkout | The workspace's store, keyed by location (for a local workspace, its root) | Buffers, shell output, the compilation buffer and its error list, running jobs |
| What belongs to the codebase whichever checkout is open | The project's store, keyed by identity | Command history (`:!` and compile lines), the commands and settings config gives the project |

Both stores are `Value` trees by name, as a buffer's locals are, so a
reload leaves them; both live as long as the session. A feature declares a
`Store α` (`lean/Editor/Store.lean`) and reads and writes it through
`Workspace.Table.get` and `Workspace.set`, or `getOfProject` and
`Project.set`. They are compiled state that follows `Store`'s encoding, not
cells config declares.

## Registering a workspace that is not local

A non-local workspace is made, not found: a remote agent session, or a later
remote adapter, registers it with `Workspace.register location remote
branch` (`StateRequest.registerWorkspace`). Its project is its remote's, so
a remote session's workspace sits beside the local checkouts of the same
repository. A local location is refused: local workspaces are found.

## `workspace-current`

The compiled command `workspace-current` says the focused buffer's
workspace in the echo area: its label, its location, its branch and what
its location can do; its project's name and identity; and the project's
other open workspaces by label. A buffer with no workspace says so, with
the directory used instead, or that it has no file. Here a workspace is
open when the table has it: found or registered this session.

## Who uses it

- `navigation-and-windows` phase 3 (the project and file picker): the
  workspace root.
- `version-control`: worktree lifecycle makes workspaces; a jj adapter is a
  new step of the finder (a step of `Workspace.find`, a clause of
  `World.find` and a contract property).
- `acp-agents`: a session's workspace, registered when it is not local.
- `shell-and-compile` phases 2 to 6: `:!` and `compile` run in the
  workspace's root, and refuse to run locally for a location that cannot
  run commands; their history is the project's, their buffers the
  workspace's.
- Tasks `project-scoped-buffers-and-pickers` (scoping pickers by workspace)
  and `remote-workspace-execution` (running in a `reachable` location).

## Open questions

- **Branch staleness.** A workspace's branch is what git said when a file
  of it was last found. A checkout made afterwards in a terminal is not
  seen until the next find, which a cached directory does not make until
  a reload. A file watch on `HEAD`, or asking again on a timer, would fix
  it.
- **Symlinked paths.** A directory is matched as a string, as a buffer's
  path is. A file reached through a symbolic link is cached under that
  spelling, while git prints the real top level; two spellings of one
  directory ask git twice and agree on the workspace.
- **What "open" means.** `workspace-current` lists every workspace found or
  registered this session. Scoping by the workspaces with a live buffer is
  `project-scoped-buffers-and-pickers`.
