# workspace

A default package: the workspaces. When a file opens, it finds the
workspace the file is in (by config's roots, by git, or by a marker file)
and attaches it to the buffer at `files-api`'s `Opened` hook, then turns on
the minor modes the workspace's markers name and runs the compile mode's
listing for them. It registers `workspace-current`, which says a buffer's
workspace; `find-file-in-workspace`, a prompt over the workspace's files,
listed by git or `find` and filtered by fzf; `find-file-in-project`, a
picker over the project's worktrees that opens that finder in the one
chosen; `find-file-in-another-workspace`, bound to `C-x C-d` in the
finder, which steps out to the picker; their sources and jobs; and the
value of the interface library `project-api` (`ProjectApi.Workspaces`),
through which version control, the working sets and the shell reach the
workspace at a path. An editor without it attaches no workspace to any
buffer, and `compile-list` has no work.

Its design record is in [packages.md](../../docs/design/packages.md),
"The default packages of the features-as-packages roadmap's phase 6", and
what a workspace is in [projects.md](../../docs/design/projects.md).

## Its source, in reading order

1. [`lakefile.toml`](lakefile.toml): the Lake package `workspace`. It
   requires the core, `editor-core`, by path (`../../lean`), declares the
   library `Workspace`, the test library `WorkspaceTest` and the test
   driver `workspace-test`, and turns every Lean linter on with warnings as
   errors.
2. [`Workspace/EditorPackage.lean`](Workspace/EditorPackage.lean): the
   entry module. It imports `Workspace.Compiled`.

   ```lean
   def packages : Array Editor.Package :=
     #[Editor.Workspace.package]
   ```
3. [`Workspace/Compiled.lean`](Workspace/Compiled.lean): the `Package`
   value, `Editor.Workspace.package`, named `workspace`: the commands, the
   escape's binding, the jobs, the sources, the attach at `Opened` and the
   `ProjectApi.Workspaces` value.
4. [`Workspace/Finder.lean`](Workspace/Finder.lean): finding a directory's
   workspace, by config's roots, git and markers, over the core's job port.
5. [`Workspace/Attach.lean`](Workspace/Attach.lean): the find job, the
   attach at `Opened`, and `workspace-current`.
6. [`Workspace/Modes.lean`](Workspace/Modes.lean): the mode marker search
   and the minor modes it turns on, through the core's
   `Workspace.turnOnModes`.
7. [`Workspace/Reach.lean`](Workspace/Reach.lean): reaching the workspace at
   a path the table has no answer for, the `ProjectApi.Workspaces` value.
8. [`Workspace/Lister.lean`](Workspace/Lister.lean),
   [`Workspace/FindFile.lean`](Workspace/FindFile.lean): which command lists
   a workspace's files, and `find-file-in-workspace` over it.
9. [`Workspace/Projects.lean`](Workspace/Projects.lean),
   [`Workspace/FindInProject.lean`](Workspace/FindInProject.lean): the
   project's workspaces, and `find-file-in-project` over them.

The workspace data (`lean/Editor/Workspace.lean`, `Editor.Workspace`) and
what a search covers (`lean/Editor/SearchRoot.lean`) are the core's. The
declarations here keep their names, `Editor.Workspace.…`, from when they
were modules of the core.

## Its tests

- **The test driver**, [`WorkspaceTest/Model.lean`](WorkspaceTest/Model.lean),
  run by `lake test`: the workspace's model checks, one module under
  [`WorkspaceTest/Workspace/`](WorkspaceTest/Workspace) for each module of
  the library, on the workspace's test kit,
  [`WorkspaceTest/Kit.lean`](WorkspaceTest/Kit.lean), and the finder
  checks' driver,
  [`WorkspaceTest/Support/FindFile.lean`](WorkspaceTest/Support/FindFile.lean);
  and the finder's contract, held by its pure model
  ([`WorkspaceTest/Finder/`](WorkspaceTest/Finder)).
- **The linked test**, [`WorkspaceTest/Linked.lean`](WorkspaceTest/Linked.lean),
  run by the package steps in `mise run ffi-test`: the finder, its contract
  and the listers over the library's process and file services, with
  [`tests/workspaces/git`](tests/workspaces) standing in for git and
  [`tests/completion/filter`](tests/completion) for fzf. With the argument
  `bench-workspace-files` it runs the finder's benchmark instead
  (`mise run find-file-bench`), never part of the gate.
- It has no headless fixture of its own. The core's
  `tests/headless/finder-session` and the others that open files in a
  workspace run on the default set's editor.

## Dropping it

`:package-remove workspace` rebuilds your editor without it; no buffer then
has a workspace, and the commands that reach one through `project-api` say
there is no implementation
([installing-packages.md](../../docs/packages/installing-packages.md)).
