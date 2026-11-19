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
buffer's workspace and `workspace-current`),
`lean/Editor/Workspace/Lister.lean` (which command lists a workspace's
files), `lean/Editor/Workspace/FindFile.lean` (`find-file-in-workspace`)
and `lean/Editor/Workspace/Compiled.lean` (their registrations).

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

The search for a minor mode's markers within a workspace
(`Workspace.presentMarkers`, "A buffer's workspace") shares the marker
adapter's rule, and is held the same three ways by a contract of its own
(`Workspace.MarkerContract`), its model `World.presentMarkers`.

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

## Listing a workspace's files

Which command lists a workspace's files is a choice made in Lean, with an
order, as finding one is: `Workspace.lister settings workspace` answers it
as a value (`Workspace.Lister`: its origin, its program and arguments,
whether its records end in a NUL, and a prefix its records lose), and runs
nothing. The first that answers wins:

1. **Config, for the workspace's root**: `workspaceLister root program
   arguments (nul := …)` in `setup`, matched against the workspace's root
   with a trailing `/` aside.
2. **Config, for its project**: `projectLister identity program arguments
   (nul := …)`, which every workspace of the project shares. A root's
   lister is used before its project's, as the more specific declaration.
3. **Git**, for a workspace git found, run as the finder's git program in
   git's environment (`GIT_DIR` and `GIT_WORK_TREE` removed):

   ```
   git ls-files -z --cached --others --exclude-standard
   ```

   Git applies its own ignore rules, `.gitignore` at every level,
   `info/exclude` and the global excludes file, so the editor never
   reimplements them; untracked files that are not ignored are listed.
4. **The fallback**, for any other workspace and for none:

   ```
   find . -type f -not -path '*/.git/*' -print0
   ```

   Its records lose their leading `./`. `find` exits 1 when it meets a
   directory it cannot read (a root-owned one, or one macOS's privacy
   controls guard under `$HOME`) or an entry that vanishes while it walks,
   and still prints every other file, so the fallback declares 1 a partial
   listing (`Lister.partialListing`): the files it read are listed, not
   none. Git's lister and config's declare none, so any exit of theirs
   but 0 fails the source.

Each runs at the workspace's root, and no shell sees its arguments.

**Which adapter found a workspace is read from its branch**
(`Workspace.foundByGit`): only the git adapter gives a branch
(`Found.ofGit`), while config and the markers give none and a registered
workspace is not local, so a local workspace with a branch is one git
found. A workspace does not record its adapter: that would change the
finder's contract and its model for one bit the branch already carries. An
adapter that gives a branch without git (jj) changes the rule with it.

Config's listers are refused for a root that is not absolute, for a program
that names a relative path, which every process service refuses (a
project's own script runs as `sh` with the script as its argument), and
for one root or one project given a lister twice. An install replaces them
(`Registry.workspaceListers`), and the loop is told them in the workspace
settings (`Workspace.Settings.listers`, `RegistryRequest.workspaceSettings`).

No lister is chosen for a location that is not on this machine: the finder
refuses it first (below). The listers are Projectile's, as prior art:
`projectile-git-command`, `git ls-files -zco --exclude-standard`, and
`projectile-generic-command`, `find . -type f -print0`.

## `find-file-in-workspace`

A prompt over the files of a workspace, as Projectile's
`projectile-find-file` and consult's `consult-fd` are: its source,
`workspace-files`, in the category `workspace-file`, is a source a command
filters ([concurrency.md](concurrency.md), "Sources a command filters"),
whose lister is the workspace's (above) and whose filter is fzf, both run
at the root, in the source's job. Its candidates are paths relative to the
root.

- **What is searched.** A workspace location handed as the command's
  argument (`Location.arguments`) names the workspace the table has there;
  otherwise it is the workspace of the focused buffer. A buffer with no
  workspace is searched in its file's directory, or for a buffer with no
  file in the editor's working directory, as `:!` runs there: both ask
  the state's one rule (`EditorState.commandDirectoryOf`), with the
  fallback lister. Arguments that
  name no location, a count or a register a key hands, are ignored, and
  what follows a location is left for the typed text a later phase hands.
- **The label** names what is searched: `Find file in r@feature: `, the
  workspace's `name@branch`, or the directory searched for a buffer with no
  workspace.
- **Refusals.** A workspace whose location cannot both read files and run
  commands (`Location.can`) is refused, naming it:
  `find-file-in-workspace: r@main is reachable through ssh host at
  /srv/r, where files cannot be listed`. A location the table does not
  know is refused with `no workspace is known at …`. Either way no prompt
  opens and no process starts.
- **The prompt's place is the root, and its context the lister**
  (`prompt`'s `place` and `context`): the source's job reads both from its
  query, so which lister answered is recorded with the prompt, and a test
  or a message can name it (`Candidates.context`).
- **Accepting** runs the command again, as its own continuation, with the
  answer, `true` and the root: the answer, under the root, is opened by
  running `open-file` by name (`runCommand`), so config's override of
  `open-file` still applies, and the file opens in the window the prompt
  was asked from.
- **No key waits.** The command opens the prompt and returns; the lister
  and fzf run only in the source's job, on the pool, and a new text
  cancels it, which kills its child. Measured in
  [concurrency.md](concurrency.md), "A key in the workspace finder,
  measured".

Keys come with project navigation's phase 5; until then it runs by name.

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
  from (`BufferId.inheritWorkspace`), or none. A workspace's shell output
  buffer, `*shell output: <label>*`, is made with the workspace of the
  buffer `:!` ran in (`lean/Editor/Shell.lean`), so a `:!` typed in it
  runs in that workspace again; outside any workspace it is `*shell
  output*`, with none. A workspace's compilation buffer,
  `*compilation: <label>*` (`lean/Editor/Compile.lean`), is made with the
  workspace of the buffer `compile` ran in, so `compile`, `recompile` and
  `kill-compilation` in it act on that workspace; a directory scope's has
  no workspace and keeps its directory in its `compile-directory` local
  instead. Each is found by the number its scope keeps, never by its name.
- **Modes on markers.** Once a file's workspace is known, from the cache
  or from the find job's command, the job `find-mode-markers` looks for
  the registered compile contributions' marker files from the file's
  directory up to and including the workspace's root, and never above it,
  so one worktree's modes are found within that worktree; a file with no
  workspace looks in its own directory alone. A marker is there by the
  marker adapter's rule, a directory included. Each mode with a marker
  there is on, rooted at its nearest marker's directory, or an outermost
  mode's farthest within the workspace, which may be below the
  workspace's root; the buffer keeps them as its local `marker-modes`,
  nearest first, and has each as a minor mode
  ([keymaps-and-modes.md](keymaps-and-modes.md), "A buffer's modes"). With
  no contribution registered no job starts; the shipped `cargo-mode`,
  `lake-mode` and `mise-mode` are registered in every host.

## What lives where

| State | Where | Examples |
|---|---|---|
| What belongs to one checkout | The workspace's store, keyed by location (for a local workspace, its root) | Buffers, shell output, the compilation buffer, its last line, its run in flight and the on-modes it started with, its error list and current location (`compile`), the commands each mode's listing gave at its root, such as mise's tasks (`compile-listings`), running jobs |
| What belongs to the codebase whichever checkout is open | The project's store, keyed by identity | Command history (`:!` lines, `shell-history`; compile lines, `compile-history`) |
| What belongs to the buffers outside any workspace, which have no project either | The unscoped store, one for the editor (`Workspace.Table.unscoped`) | The `:!` history and the `*shell output*` buffer of such buffers; their compile history (`compile-history`), each directory scope's compile record by directory (`compile-directories`), and their modes' listings by mode and root (`compile-listings`) |

The stores are `Value` trees by name, as a buffer's locals are, so a
reload leaves them; they live as long as the session. The unscoped store
is read with `Workspace.Table.getUnscoped` and written with
`Workspace.setUnscoped`, and is never refused: it is always there.

What config gives a project, such as its commands and settings for a mode
(`projectCommands`), is not kept in any store: it is read by the project's
identity from config's latest as the loop is told it, so a reload's change
is read at once.

A command run for a buffer runs in its workspace's root, or, with no
workspace, in its file's directory, with no separator at its end. A
buffer with neither runs in the editor's working directory
(`EditorState.workingDirectory`), which each host sets once from its own
process's working directory: the window mode's and the headless mode's
alike. It is `/` until a host sets it. The rule is decided once, on the
state (`EditorState.workingDirectoryOf`, which `BufferId.workingDirectory`
forwards to, and `EditorState.commandDirectoryOf`, the directory it comes
to on this machine), and every command that runs something for a buffer,
`:!` and `find-file-in-workspace` among them, asks it. A feature declares a
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
  `World.find` and a contract property). Phase 1 (built): the status
  buffer's repository is the stored root of the workspace of the buffer it
  is opened from, read from the table; it defines no finder, and a buffer
  with no workspace opens no status buffer. Its record (the status
  buffer's number and the files last shown) is the workspace's
  (`VersionControl.statusStore`), and its read job is keyed by the
  workspace ([version-control.md](version-control.md)).
- `acp-agents`: a session's workspace, registered when it is not local.
- `shell-and-compile` phase 2 (built): `:!` runs in the workspace's root,
  or the file's directory, or the editor's working directory, and refuses
  to run for a location that cannot run commands; its history is the
  project's (`Shell.historyStore`), its output buffer and what it runs the
  workspace's (`Shell.outputStore`, `Shell.runningStore`), each in the
  unscoped store for a buffer outside any workspace.
- `shell-and-compile` phase 3 (built): `compile` runs in the workspace's
  root, and a buffer with no workspace uses its file's directory, or the
  editor's working directory, as a workspace of its own; it refuses a
  location that cannot run commands. Its record (the compilation buffer's
  number, the last line and the run in flight) is the workspace's
  (`Compile.store`), or the unscoped store's by directory
  (`Compile.directoryStore`); its history is the project's
  (`Compile.historyStore`). Its job is keyed by the workspace, so
  compiles in two worktrees run at once.
- `shell-and-compile` phase 4 (built): the locations a compilation's
  output gives and the current one are fields of that same record, so each
  workspace (or directory scope) has its own error list; `next-error` and
  `previous-error` step through the focused buffer's workspace's list, and
  a rerun resets that workspace's list only.
- `shell-and-compile` phase 5 (built): a compile contribution's markers
  are looked for from a buffer's file up to its workspace's root, which
  bounds them, so a marker above the root turns no mode on and each
  worktree finds its own; a mode's root may be below the workspace's root,
  and `compile` runs there, its output still in the workspace's
  compilation buffer. Config's commands and settings for a project, by its
  identity, are read from config's latest as the loop is told it
  (`RegistryRequest.compileHook`), not copied into the project's store, so
  every worktree of the codebase offers them, no other project does, and a
  reload's change is read at once.
  The on-modes a run started with are part of the workspace's record.
- `shell-and-compile` phase 6 (built): the shipped `cargo-mode`,
  `lake-mode` and `mise-mode` turn on per workspace, so two worktrees of
  one repository each have their own modes and roots. `mise-mode`'s tasks
  are listed in each worktree's own root and kept in that workspace's
  store (`compile-listings`), so each worktree offers its own tasks, while
  both share the project's compile history and config's commands for it.
- `project-navigation` phase 2 (built): `find-file-in-workspace` lists
  the focused buffer's workspace's files with the lister chosen for it,
  config's, git's or the fallback, and refuses a location that cannot read
  files (above).
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
