# Version control

What the editor asks of a version-control system, and the status buffer
that shows it. The model is magit: every operation is a git command and its
parsed output, run as a job over the process service
([review-and-navigation.md](review-and-navigation.md), "Version control").
Git is one implementation of a small interface in the editor's own terms,
so jj, or an in-process library, is another.

Built in `lean/Editor/VersionControl.lean` (the interface),
`lean/Editor/VersionControl/Porcelain.lean` (the reader of git's status),
`lean/Editor/VersionControl/Git.lean` (the git implementation),
`lean/Editor/VersionControl/Model.lean` and
`lean/Editor/VersionControl/Contract.lean` (its model and its contract),
`lean/Editor/VersionControl/Status.lean` (the status buffer) and
`lean/Editor/VersionControl/Compiled.lean` (its registrations).

## The interface

A port of the `Program` kind, shaped like the clipboard's: a request type,
a reply type for each request, a pure model handler from a request and a
repository to a reply and a repository, and a real handler that answers each
request in `JobM`, run with `Program.runM` inside a job.

| Request | Reply |
|---|---|
| `status` | What is checked out (a branch, born or not, or detached) and every file that differs from it |
| `stage paths` | Nothing; the index holds each path as the working tree has it |
| `unstage paths` | Nothing; the index holds each path as `HEAD` has it |

- **Paths** are relative to the repository's root, `/`-separated, as UTF-8
  strings.
- **A file's state** is one of: a change staged against `HEAD` and a change
  in the working tree against the index, each `added`, `modified` or
  `deleted`, at least one of them there; a staged rename from an origin,
  with a change in the working tree since; untracked; or a conflict, of the
  seven kinds the index's base, ours and theirs name.
- **A status** holds its files sorted by path, then by state. A path
  appears once, except that a path removed from the index and still on
  disk is both a staged deletion and untracked. A rename only in the
  working tree (a file added with intent to add after a move) is no state
  of its own: it is the origin's unstaged deletion and the new path's
  unstaged addition, as git prints it with renames off.
- **Staging** a path that is gone removes it from the index, and staging a
  conflict resolves it to the working tree's content. A path in neither
  the index nor the working tree refuses the whole request, as git does,
  and nothing is staged.
- **Unstaging** a path `HEAD` lacks removes it from the index, an unborn
  branch's included.
- **Errors are values**: the system could not be run (missing, denied,
  past its time or output limit), it ran and refused (its exit and its
  standard error), or what it printed cannot be read.

The interface grows by data, one request at a time, with the phase that
first uses it: a file at a revision (`show`) with the gutter marks, and the
branches, the worktrees and a diff between two revisions with worktree
lifecycle. Each comes with its reply type, a clause of the model, a clause
of the git implementation and a property of the contract.

## The model and the contract

The model is a repository as a value: what is checked out, `HEAD`'s files,
the index (a file, or a conflict's three versions) and the working tree.
Its status compares `HEAD` with the index and the index with the working
tree, path by path, and pairs renames as git's exact rename detection
does: each path added in the index, in path order, takes the first path
deleted in the index whose `HEAD` content is its content. An empty file is
paired too; git pairs it, and a property of the contract says so.

The model also prints its status as git prints it with the git
implementation's flags, so the real parser reads the model's status, and
it builds the job model whose process scripts answer the git
implementation's command lines in a repository.

The contract is one list of properties, each a program over the port and
the repository it starts from, run three ways:

- against the model, by `model-test`;
- the git implementation's status read of each property's repository on
  that job model, by `model-test`: the process model's scripts are static,
  so only a read runs there;
- against the git implementation over the library's process service, by
  `contract-test`, in a temporary repository written out from the
  property's repository with git's own plumbing (`init`, `commit`,
  `hash-object`, `update-index` with `--cacheinfo` and, for a conflict's
  stages, `--index-info`), every child's git kept from the user's and the
  system's config (`GIT_CONFIG_NOSYSTEM` and the test's own `HOME`) and
  given, as the user's (`GIT_CONFIG_GLOBAL`), a config that asks for what
  the command line pins away: copies found by `status.renames` and
  `diff.renames`, and no untracked files listed. The editor runs git under
  the user's config, so the contract does too, under a hostile one.

Its first property is the adapter test that git and the model agree on a
repository with a staged, an unstaged, an untracked, a renamed and a
conflicted file.

## The git implementation

Each request is one `Process.runWithin` in the repository's root, so the
child gets its directory's environment and is killed with its process
group when its job is cancelled. No binding is added.

| Request | Command line |
|---|---|
| status | `git -c status.renames=true -c diff.renames=true status --porcelain=v2 -z --branch --untracked-files=all --find-renames` |
| stage | `git add --all -- <paths>` |
| unstage | `git reset -q -- <paths>` |

- git runs under the user's config, so each flag pins what that config
  could change: `-z` ends each record with a NUL and never quotes a path;
  `--branch` adds the headers that say what is checked out;
  `--untracked-files=all` lists untracked files one per file, so the
  status buffer has one line per file; `--find-renames` turns renames on.
  `--find-renames` leaves copies as the config says, and a config of
  `copies` in `status.renames`, or in `diff.renames` when the first is
  not set, makes git print copy records, so the two `-c`, which outrank
  every config file, pin detection at renames, never copies.
- `git reset` unstages on an unborn branch, where `git restore --staged`
  does not.
- The environment is the editor's less `GIT_DIR`, `GIT_WORK_TREE` and
  `GIT_INDEX_FILE`, so git answers for the root and its own index; with
  `GIT_OPTIONAL_LOCKS=0`, so a status read never takes the index lock, as
  magit's do, and a read cannot make a stage fail; and with
  `GIT_LITERAL_PATHSPECS=1`, so a path holding `*` or `:` is a path.
- The limits are named constants of policy: 16 MiB of each stream and
  30 s. A run past either is "could not run", never a parse of output cut
  short.

### Reading the status

The parser is pure and is tested on output git printed, checked in as
fixtures with the commands that made each repository. The output is
records ended by NUL; each must be UTF-8.

| Record | Read as |
|---|---|
| `# branch.head <name>`, `# branch.head (detached)` | The head; other headers are ignored |
| `1 XY sub mH mI mW hH hI path` | A change: `X` staged, `Y` unstaged; `.` none, `M` and `T` modified, `A` added, `D` deleted |
| `2 XY … Xscore path`, then the origin as the next record | A staged rename (`R` staged); or, as `.R`, a rename in the working tree, read as the origin's unstaged deletion, joined with its own record's staged change, and the path's unstaged addition. A copy (`C`) is refused: the command line pins copies off |
| `u XY … path` | A conflict: `UU`, `AA`, `DD`, `AU`, `UA`, `DU`, `UD` |
| `? path` | Untracked |

The path is the rest of the record after its fields, so spaces survive.
An unknown kind or `XY`, a short record, a rename with no origin and output
with no `branch.head` are refused, with the record quoted. Git lists
conflicts and untracked files after the other changes; the reader sorts
the files as a status holds them.

## The status buffer

`vc-status` opens magit's status buffer for the focused buffer's
workspace: a read-only buffer of generated text, `*vc-status: <label>*`,
in the major mode `vc-status`.

- **Its repository** is the root of the workspace of the buffer it is
  opened from, as [projects.md](projects.md) finds and stores it once,
  never sniffed again. It defines no finder. A buffer with no workspace
  opens no status buffer and says so; a workspace whose location cannot run
  commands is refused.
- **Its text** is a head line, `<label>: on <branch>` or `<label>:
  detached`, then one line per file, `<state>: <path> (<detail>)`, for
  example `staged: src/a.rs (modified)`, `renamed: new.rs (from old.rs)`,
  `conflicted: lib.rs (both modified)` or `untracked: notes.txt`; or `no
  changes`.
- **A read** is a job keyed by the workspace, so a second replaces the
  first. What it comes to replaces the buffer's text, each view keeping its
  cursor's row, or makes the buffer and shows it where the display rules
  say for the opener `vc-status`. A failure is said in the echo area, and a
  buffer already shown keeps its text.
- **The workspace's store** keeps the buffer's number, found by it and
  never by its name, and the files last shown, which the commands read the
  cursor's file from.

| Command | Role or suffix | What it does |
|---|---|---|
| `vc-status-visit` | `activate` | Opens the cursor's file under the root; a file gone from the working tree, or a row with no file, is said |
| `vc-status-toggle` | `toggle` | Stages an untracked, a conflicted or an unstaged file; unstages a staged one, a staged rename by both its paths |
| `vc-status-refresh` | `refresh` | Reads the status again, without showing the buffer again |
| `vc-status-stage` | leader `s` | Stages the cursor's file, or says there is nothing to stage |
| `vc-status-unstage` | leader `u` | Unstages the cursor's file, or says nothing is staged |

A stage or an unstage is a job of its own, unkeyed, which then starts the
keyed read, so the buffer shows the new state. The ex name `vc-status` runs
the command, and each scheme's role table puts the mode's keys on its
roles: the Vim scheme's `RET`, `TAB` and `g r`.

## Open questions

- **A config root below the top level.** The status buffer takes the
  workspace's root to be the repository's top level, which it is for every
  workspace git or a `.git` marker finds. A root config declares strictly
  inside a repository has git print paths relative to the top level, which
  the buffer would join to the wrong directory. Asking git for its prefix
  would be finding the repository again; the workspace could instead store
  its top level when the finder runs git.
- **Paths that are not UTF-8.** A path git prints that is not UTF-8 makes
  the whole status unreadable. Reading it as the store's escapes would keep
  the rest.
- **Index-lock contention.** Two writes at once, or a write while another
  program holds the index lock, fail with git's message, which is said; the
  second is not retried.
- **Status time on a large repository.** A process per read may be too slow
  on a large repository; an in-process library can sit behind the same
  interface, as the roadmap allows.
