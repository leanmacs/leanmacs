# Version control

What the editor asks of a version-control system, the status buffer that
shows it, a file at a revision, the gutter that marks a tracked file's
lines against `HEAD`, staging a hunk, and the message buffer that commits. The model is magit: every operation is a git command and its
parsed output, run as a job over the process service
([review-and-navigation.md](review-and-navigation.md), "Version control").
Git is one implementation of a small interface in the editor's own terms,
so jj, or an in-process library, is another.

Built in `lean/Editor/VersionControl.lean` (the interface),
`lean/Editor/VersionControl/Porcelain.lean` (the reader of git's status),
`lean/Editor/VersionControl/Git.lean` (the git implementation),
`lean/Editor/VersionControl/Model.lean` and
`lean/Editor/VersionControl/Contract.lean` (its model and its contract),
`lean/Editor/VersionControl/Status.lean` (the status buffer),
`lean/Editor/VersionControl/Show.lean` (`vc-show`),
`lean/Editor/VersionControl/Gutter.lean` (the gutter),
`lean/Editor/VersionControl/Hunk.lean` and
`lean/Editor/VersionControl/Stage.lean` (staging a hunk),
`lean/Editor/VersionControl/Commit.lean` (the message buffer) and
`lean/Editor/VersionControl/Compiled.lean` (their registrations).

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
| `fileAt revision path` | The path's content at the revision, or none when the revision does not have it or is not there; the empty revision is the index |
| `watched` | What to watch so as to see `HEAD` or the index move: a directory, the files in it whose change matters, and the trees in it under which any change matters |
| `stageHunk path hunk` | Nothing; `hunk`, of the file against the index, is applied to the index |
| `unstageHunk path hunk` | Nothing; the reverse of `hunk`, of the index against `HEAD`, is applied to the index |
| `commit message` | Nothing; `HEAD` is a new commit of the index with `message` |

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
- **A file at a revision** is its bytes decoded by the store's escape rule,
  so a byte that is not UTF-8 survives as its escape. `HEAD` on an unborn
  branch, an unknown revision and a path the revision lacks are all "not
  there": the editor has nothing to show in either case. A path that names
  a directory is refused. (The request is `fileAt` and not `show`, which is
  a keyword of Lean.)
- **What to watch** is neutral data: git names its common directory, with
  `HEAD` and `index` of the checkout's own git directory (a linked
  worktree's, under the common one), `packed-refs` and `refs` as a tree;
  jj would name its operation heads. A change matters at one of the files
  or under one of the trees, never at a lock file (`*.lock`), which a
  system writes and renames away while it moves `HEAD` or the index; a
  delivery that missed changes matters too. Objects and logs never do.
- **A hunk** (`LineHunk`) is a run of changed lines with the index's lines
  around it: the row in each text of its first context line, the context
  before, the lines removed, the lines added and the context after. Each
  line keeps its line feed, and only a text's last line may lack one,
  which is how "no newline at end of file" is carried. Its context always
  comes from the index, the text it is applied to: the old side when
  staging, the new side when unstaging. Lines that are not where the hunk
  says refuse it, and the index is as it was.
- **A commit** refused (nothing staged, a conflict, a hook that says no)
  is a refusal with everything the system printed, so a hook's output can
  be shown, not swallowed.
- **Errors are values**: the system could not be run (missing, denied,
  past its time or output limit), it ran and refused (its exit and its
  standard error), or what it printed cannot be read.

The interface grows by data, one request at a time, with the phase that
first uses it: a file at a revision and what to watch came with the gutter
marks, a hunk staged and unstaged and a commit with staging hunks, and the
branches, the worktrees and a diff between two revisions
come with worktree lifecycle. Each comes with its reply type, a clause of the model, a clause
of the git implementation and a property of the contract.

## The model and the contract

The model is a repository as a value: what is checked out, `HEAD`'s files,
the index (a file, or a conflict's three versions) and the working tree.
It also has named revisions (tags, each with its files) and its git and
common directories, which `fileAt` and `watched` answer from, and a
`commit` a test makes `HEAD` the index's files with, as a commit made
outside the editor does, and a pre-commit hook that refuses every commit,
printing what it is given. It applies a hunk where its rows say, exactly,
and refuses one whose lines are not there; git may apply a hunk at an
offset when its lines are found elsewhere, but the editor's hunks are made
from the index just read, so their rows are exact. It refuses a commit on
a conflict, then on its hook, then on an index equal to `HEAD`, as git
checks them, and keeps no message. Its status compares `HEAD` with the index and the
index with the working tree, path by path, and pairs renames as git's exact rename detection
does: each path added in the index, in path order, takes the first path
deleted in the index whose `HEAD` content is its content. An empty file is
paired too; git pairs it, and a property of the contract says so.

The model also prints its status as git prints it with the git
implementation's flags, so the real parser reads the model's status, and
it builds the job model whose process scripts answer the git
implementation's command lines in a repository: the status read, the
writes a test names (a hunk's apply exits 0 whatever it is fed, and a
commit too, unless the repository has a hook), both runs of `fileAt` for
each file of `HEAD`, of the index and of each named revision (an id made of the content alone, then its bytes), the
first run exiting 1 for each revision and path a test names missing, and
`watched`. A command no script names is refused as "not found", so a test
that asks for a missing path names it.

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
  stages, `--index-info`; each named revision a commit of its files alone,
  made with an index file of its own, `write-tree` and `commit-tree`, and
  tagged with `update-ref`; and each file written with the store's escapes
  turned back into their bytes, so a content may hold a byte that is not
  UTF-8), every child's git kept from the user's and the
  system's config (`GIT_CONFIG_NOSYSTEM` and the test's own `HOME`) and
  given, as the user's (`GIT_CONFIG_GLOBAL`), a config that asks for what
  the command line pins away: copies found by `status.renames` and
  `diff.renames`, no untracked files listed, a patch's whitespace fixed
  (`apply.whitespace=fix`) and its context matched loosely
  (`apply.ignoreWhitespace=change`), and a message's `#` lines stripped
  (`commit.cleanup=strip`); with a user, which no commit runs without,
  and signing off. A repository's hook is written as an executable
  `.git/hooks/pre-commit` run by `/bin/sh`, its first line printed on its
  standard output and the rest on its standard error. The editor runs git
  under the user's config, so the contract does too, under a hostile one.

Its first property is the adapter test that git and the model agree on a
repository with a staged, an unstaged, an untracked, a renamed and a
conflicted file. The properties of a hunk take their hunks as the editor
does, from the texts the repository holds, through the model's line diff
and the pure core of hunks, so a property tests the interface and not a
diff engine; one of them is the adapter test that staging one hunk of a
file with two changed hunks stages that hunk alone. Others stage a hunk
after another is staged, one whose context overlaps another change, a
last line without a line feed and one that adds it, CRLF lines and an
added line ending in spaces, quoted paths and an empty index file; unstage
one of two staged hunks; and commit, on an unborn branch, with nothing
staged and under a hook that refuses.

## The git implementation

Each run is one `Process.runWithin` in the repository's root, or a fed
`Process.runWithInput` for a hunk and a commit, one a request but
`fileAt`, which is two, so the child gets its directory's
environment and is killed with its process group when its job is
cancelled. No binding is added.

| Request | Command line |
|---|---|
| status | `git -c status.renames=true -c diff.renames=true status --porcelain=v2 -z --branch --untracked-files=all --find-renames` |
| stage | `git add --all -- <paths>` |
| unstage | `git reset -q -- <paths>` |
| fileAt | `git rev-parse --verify --quiet <revision>:<path>`, then `git cat-file blob <id>` with the id it printed |
| watched | `git rev-parse --git-dir --git-common-dir` |
| stageHunk | `git -c apply.whitespace=nowarn -c apply.ignoreWhitespace=false apply --cached -`, fed the hunk's patch |
| unstageHunk | The same with `--reverse`, fed the patch of the hunk of the index against `HEAD` |
| commit | `git commit --file=- --cleanup=whitespace`, fed the message |

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
  short. So a file at a revision past 16 MiB is not read, and a buffer of
  one has no gutter: the editor thread never copies a huge old text.
- **A file at a revision is two plumbing runs, not `git show`.** `rev-parse
  --verify --quiet` exits 1 and says nothing when the revision does not
  have the path or is not there, so "not there" is told from a failure by
  the exit alone; `git show` tells them apart only in its message, and on a
  blob it applies the user's `textconv` filter, which plumbing never does
  (the contract runs under a hostile user config by design). A directory's
  id is a tree, which `cat-file blob` refuses.
- **A hunk's patch** is pure: a `diff --git` header and `---`/`+++` lines
  naming the path C-quoted, always, so a space, a quote or a byte past
  ASCII reads back as itself; one `@@ -o,oc +n,nc @@` line, a side's start
  its row plus one, or the row itself when its count is 0 (`-0,0` into an
  empty index file), as git prints it; then the context, removed, added
  and context lines, each that lacks a line feed followed by `\ No newline
  at end of file`. Staging's `n` is its `o`: nothing before the hunk
  changes. Unstaging's is the index's row, and `--reverse` has git match
  the `+` side, context and index lines, against the index. Its text is
  turned back into bytes by the store's rule, so an escape is its byte
  again.
- **Applying is strict.** The two `-c` pin what a user's config could
  change: `apply.whitespace=fix` would rewrite trailing spaces and a
  carriage return on an added line, and `apply.ignoreWhitespace=change`
  would match context loosely. Never `--unidiff-zero`, `--recount`,
  `-C<n>` or `--3way`: every context line must match the index exactly,
  or git refuses and the index is untouched, the main guard against a
  wrong patch. `--cached` never touches the working tree, so a wrong
  patch is undone by unstaging the whole file, and the file is never at
  risk.
- **The message reaches git on its standard input**, as git's message
  file: never an argument, so no length limit and no leading `-` read as
  an option, and no temporary file to write, clean up or race another
  commit for. `--cleanup=whitespace` is git's own default for a message
  from a file; pinning it stops a user's `commit.cleanup=strip` from
  dropping a line that starts with `#`, since the buffer has no comment
  template to strip.
- **A commit's environment** is the others' less `GIT_LITERAL_PATHSPECS`:
  git hands its environment to hooks, and a hook running `git diff --
  '*.rs'` must see a pattern. A commit passes no pathspec, so nothing is
  lost. `GIT_OPTIONAL_LOCKS=0` reaches hooks too, which is harmless.
- **A commit's time limit** is 10 minutes, not 30 s, because a pre-commit
  hook may run linters or tests, and a commit killed while its hook runs
  could leave `index.lock` behind. git gets no terminal and gives hooks no
  input, so a hook or a `gpg` pinentry that needs a terminal fails, and
  its output is shown; one that waits for input is killed at the limit.
- **A refused commit** carries git's standard error and then its standard
  output, each trimmed: git says `nothing to commit` on its standard
  output, and sends a hook's standard output to its standard error.
- **What to watch** reads its two lines, each resolved against the root
  when git prints it relative, so both are spelled as the root is and a
  watch's changes, spelled under its target, compare with them. Output
  that is not two lines is unreadable.

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
| `vc-status-visit` | `activate` | Opens the cursor's file under the root; a file gone from the working tree, or a row with no file, is said. A staged deletion the status also lists as untracked is still on disk, and opens; a conflict always opens, since the status cannot say its file is gone |
| `vc-status-toggle` | `toggle` | Stages an untracked, a conflicted or an unstaged file; unstages a staged one, a staged rename by both its paths |
| `vc-status-refresh` | `refresh` | Reads the status again, without showing the buffer again |
| `vc-status-stage` | leader `s` | Stages the cursor's file, or says there is nothing to stage |
| `vc-status-unstage` | leader `u` | Unstages the cursor's file, or says nothing is staged |

A stage or an unstage is a job of its own, unkeyed, which then starts the
keyed read, so the buffer shows the new state. The ex name `vc-status` runs
the command, and each scheme's role table puts the mode's keys on its
roles: the Vim scheme's `RET`, `TAB` and `g r`.

## A file at a revision: `vc-show`

`vc-show` opens what a file held at a revision as a read-only buffer with
no file, magit's `magit-find-file`. It takes text: a revision and, after
one space, a path relative to the focused buffer's workspace root, spaces
kept; a revision alone is the focused buffer's file; no text is that file
at `HEAD`. A revision that starts with `-`, which git would read as an
option, a buffer with no workspace, a location that cannot run commands
and no file to name are refused before any job runs. Its job, keyed by the
root, the revision and the path, reads the file through `fileAt`; what it
comes to makes the buffer `<path>@<revision>`, or the first free name of
that, read-only, in the workspace, shown where the display rules say for
the opener `vc-show`, in the language its path's name gives; "not there"
says `vc-show: <path> is not in <revision>`. The ex name `vc-show` takes
text.

## Gutter marks

A buffer of a tracked file shows, in a column before its text, its lines
added, removed and changed against the file at `HEAD`, as a gutter in an
editor with git integration does.

- **Which buffers.** A file buffer whose workspace is a local root that
  can run commands and is a repository (it has a `Workspace.branch`, a
  detached `HEAD` included), with the file under the root, where
  the host registered the gutter's jobs (`VersionControl.gutterJobs`); the
  gate auto-reload uses. The column appears once `HEAD`'s content has
  arrived. A file `HEAD` lacks (untracked, new, an unborn branch) has no
  gutter and no column, and neither does one whose read failed: a gutter
  failure is not said, since nothing was asked. Excerpt buffers and
  buffers with no file have none.
- **The old text** is the file at `HEAD`, fetched once a buffer
  (`vc-gutter-head`) into a text of its own, of which one snapshot is held
  and the text released. Holding a snapshot rather than a string means the
  diff service reads it as it reads any snapshot, with no copy.
- **The watch.** One job a repository (`vc-gutter-refs`) asks `watched`,
  watches that directory recursively, coalesced over 100 ms and 256 paths,
  and for each delivery with a change that matters posts
  `vc-gutter-moved <root>` and waits again; it never finishes, so a commit
  made while it posts is seen at its next wait, with no window to re-arm
  in. A repository's last tracked buffer gone, its job is cancelled; a
  refused watch is not tried again while it has one. One recursive watch
  sees the churn of `objects/` too, filtered out by `Watched.matters`, and
  past 256 paths a delivery is one missed change, which counts: a large
  fetch or a gc costs at most one spurious fetch of `HEAD`.
- **Moved** makes each tracked buffer of the root stale, and the next
  publish fetches its file at `HEAD` again under a new epoch, so a reply of
  an older fetch is ignored. A move that comes while a fetch is in flight
  waits for that fetch's content, then fetches once more: one fetch a
  buffer at a time.
- **The diff** (`vc-gutter-diff`) is the hunks of the held snapshot against
  a snapshot of the buffer, worked off the editor thread by the diff
  service ([rust-library.md](rust-library.md), "Diff, as built"). One is
  in flight a buffer, with no debounce timer: the reconciler starts one
  when `HEAD`'s content is held, no fetch and no diff is in flight and the
  buffer's text is at a revision not diffed against it; an edit made
  meanwhile is diffed when it lands. That bounds the work and leaves no
  cancelled snapshot to clean up. With no diff started during a fetch, a
  diff's epoch names the head it reads, so a diff of an older epoch, which
  sets no mark and records no revision, is the only one that can find its
  head released by a newer fetch: snapshot ids are never used again, so it
  reads the text it was given or is refused, and either way is ignored.
- **Carrying.** Between an edit and the diff that follows it the marks are
  carried through the text's log from the revision they were made at to
  the one a view shows ([text-and-display.md](text-and-display.md),
  "Decorations, as built"), so they follow every edit at once and the
  diff replaces them within milliseconds. Markers per hunk were rejected:
  many markers a buffer, moved on every edit, for a result replaced that
  soon.
- **The marks.** Lines added are `+` in `diff.added` over them, lines
  changed `~` in `diff.changed`, and lines removed an empty `-` in
  `diff.removed` at the start of the line after them; glyphs that read on
  a grid of cells.
- **The reconciler** runs after each publish, beside auto-reload's, and
  is pure but for the text port, where it takes the diffs' snapshots: it
  keeps the tracked buffers and the watched repositories in step with what
  is wanted, starts the fetches, the diffs and the watches, and for a
  buffer no longer wanted (closed, its path changed) cancels its jobs,
  releases its snapshots and takes its gutter away. It runs the git
  program of the workspace settings the loop is told of
  (`Loop.Registered.workspaceSettings`), the one `vc-status`, `vc-show`
  and the workspace finder ask for, so one repository is never read by
  two gits.

Pinned by `ModelTest.gutterChecks` on the models (`Repository.commit` and
the driver's touch of the parked watch for a commit made outside the
editor) and `ConfigTest.gutterChecks` over real git, the library's watch
service and its diff engine.

## Staging a hunk: `vc-stage-hunk` and `vc-unstage-hunk`

Stage, or unstage, the hunk on the cursor's line of a file buffer of a
tracked file (the gutter's gate), magit's `s` and `u` on a hunk. The ex
names run them, and no key binds them: binding one is config's.

- **A stageable hunk** is a hunk of the saved file against the index (its
  content read through `fileAt` of the empty revision, by plumbing, so no
  `textconv`), diffed by the library: not one of the gutter's, which are
  of the buffer against `HEAD`. So staging one hunk is right when other
  hunks of the file are staged already. Staging from a buffer with unsaved
  changes saves it first: the fetch is the save's follow-up job
  (`Files.save`'s `after`), started once the file is written, and a
  refused save starts nothing. A buffer edited after its save, before its
  hunks are taken, stages nothing and says so.
- **An unstageable hunk** is a hunk of the index against `HEAD`. The
  cursor's line of the buffer is carried to a line of the index across
  the hunks of the index against the buffer, and the hunk picked there.
  Unstaging saves nothing: the file's content plays no part in it.
- **The hunk on a line** is one whose lines overlap it, or else a removal
  just before it, where the gutter draws its `-`, or a removal at the
  end on the last line. Its context is 3 lines, git's default, from the
  index, clamped at its ends. Over the diff line limit the middle of a
  file is one hunk, so the hunk on a line may be all of it.
- **The pipeline** is a command and three jobs, each job's command the
  next step: `vc-hunk-fetch` reads the index's content (and `HEAD`'s, to
  unstage); its command makes each a text, snapshots it and releases the
  text, snapshots the buffer, and starts `vc-hunk-diff`, which asks for
  the hunks; its command picks the hunk, reads only its lines and their
  context from the snapshots, releases every snapshot on every path, and
  starts `vc-hunk-apply`, which applies it. What that comes to is said,
  `staged a hunk of <path>` or the refusal, and the workspace's kept
  status buffer, if it has one, is read again. The gutter is against
  `HEAD`, which staging does not move.
- **None of the jobs is keyed.** A keyed restart would cancel a job whose
  command releases snapshots, and cancelling an apply could kill git
  holding the index's lock. A second press while the first runs is safe:
  its patch's context no longer matches, git refuses it, and that is said.
- **Hunks are picked in file buffers only.** The status buffer's rows are
  files, and gives whole-file stage and unstage; hunk sections in it,
  magit's expandable hunks, need a view model of rows to hunks and a diff
  per file shown, which belong with the change view of worktree lifecycle.
- **Untracked, conflicted and deleted files** have no hunk to stage: each
  is said, and the whole-file commands stage them.

Pinned by `ModelTest.hunkChecks` (the pure core and the exact patch text),
`ModelTest.stageHunkChecks` on the models, and
`ContractTest.statusBufferChecks` over real git and the library's diff
engine: on a line of the second of two hunks, in a buffer with unsaved
changes, the buffer is saved and that hunk alone is staged.

## The message buffer: `vc-commit`

magit's commit message buffer. `vc-commit` (the ex name, and the status
buffer's leader `c`), under `vc-status`'s gate, shows the workspace's
message buffer if it has one, and otherwise makes `*vc-commit: <label>*`:
empty, editable, with no file, given the workspace, in the major mode
`vc-commit`, shown where the display rules say for the opener `vc-commit`,
and focused. Message conventions (a template, a summary's length,
trailers) are config's business: the buffer's text is the message, as it
is.

| Command | Suffix | What it does |
|---|---|---|
| `vc-commit-accept` | leader `c` | Commits with the buffer's text, as magit's `C-c C-c`; refused outside the workspace's message buffer and while a commit runs |
| `vc-commit-abort` | leader `k` | Closes the message buffer, as magit's `C-c C-k`; refused while a commit runs |

- **Accepting** reads the text and its revision, records the commit as in
  flight in the workspace's store, and starts the unkeyed job
  `vc-commit-run`, which asks for the commit.
- **A commit made** closes the message buffer if its text is still at the
  revision accepted, and otherwise keeps it and says so; it says
  `vc-commit: committed <first line>`, and reads the kept status buffer
  again. The gutter's watch sees `HEAD` move.
- **A refusal of git's** (nothing staged, a conflict, a hook) writes
  everything git printed into the read-only `*vc-commit-output: <label>*`,
  in place of its text, shown for the opener `vc-commit` without the
  focus, and keeps the message buffer with its text, to be fixed and
  accepted again. The echo area names the output buffer. A run that could
  not happen is said in the echo area only.
- **Accept and abort are the mode's locals**, not roles: they are actions
  of one mode family (`lean/Editor/Role.lean`, "The rule for adding a
  role").
- **The workspace's store** keeps the message buffer's number, the output
  buffer's, and whether a commit is in flight, as the shell keeps what it
  runs.

Pinned by `ModelTest.commitBufferChecks` on the models (the bytes
`git commit --file=-` is fed are the buffer's text) and
`ContractTest.statusBufferChecks` over real git: the commit's message is
the buffer's text, and a pre-commit hook's lines on both streams are shown
with `HEAD` as it was. A commit run by the checks has git's user from the
hostile config, never guessed from the host's name.

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
  second is not retried. A commit killed past its time limit, or on quit
  while its hook runs, can leave `index.lock`, and the next write then
  says git's message.
- **Files git converts on add.** A hunk is of the raw saved file against
  the raw index blob. Under `core.autocrlf`, `eol` or `text` attributes,
  or a clean filter (LFS), every line may differ, and a staged hunk
  carries unconverted bytes into the index. Not guarded yet; one more run
  (`git ls-files --eol`, `check-attr`) could refuse such a file.
- **Hunks in the status buffer**, magit's expandable sections, wait for
  the change view's row model.
- **The message from a file on disk.** It is git's message file on
  standard input. A file under the git directory, written by the job file
  service, would do the same with more to clean up.
- **A file opened through a link.** The workspace's root is git's top
  level, which git spells with links resolved; a file opened by a path
  through a link (a temporary directory on macOS) is not under that
  spelling of the root, so it has no gutter and `vc-show` with no path
  finds no file. Resolving both, or storing the root as the open spelled
  it, would cover it.
- **Status time on a large repository.** A process per read may be too slow
  on a large repository; an in-process library can sit behind the same
  interface, as the roadmap allows.
