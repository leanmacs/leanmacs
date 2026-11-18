# Version control

What the editor asks of a version-control system, the status buffer that
shows it, a file at a revision, the gutter that marks a tracked file's
lines against `HEAD`, staging a hunk, the message buffer that commits, and
the worktrees, the branches and a branch's change against its base, with
the worktree list, the review buffer of a branch's change, and a branch's
history: its log, a file's blame, a commit's change, and the change since
the last review. The model is magit: every operation is a git command and its
parsed output, run as a job over the process service
([review-and-navigation.md](review-and-navigation.md), "Version control").
Git is one implementation of a small interface in the editor's own terms,
so jj, or an in-process library, is another.

Built in `lean/Editor/VersionControl.lean` (the interface),
`lean/Editor/VersionControl/Porcelain.lean` (the reader of git's status),
`lean/Editor/VersionControl/Plumbing.lean` (the readers of its worktree
list, branches, raw diff and blobs),
`lean/Editor/VersionControl/HistoryRead.lean` (the readers of its log,
blame and range-diff),
`lean/Editor/VersionControl/Git.lean` (the git implementation),
`lean/Editor/VersionControl/Model.lean` and
`lean/Editor/VersionControl/Contract.lean` (its model and its contract),
`lean/Editor/VersionControl/Status.lean` (the status buffer),
`lean/Editor/VersionControl/Show.lean` (`vc-show`),
`lean/Editor/VersionControl/Gutter.lean` (the gutter),
`lean/Editor/VersionControl/Hunk.lean` and
`lean/Editor/VersionControl/Stage.lean` (staging a hunk),
`lean/Editor/VersionControl/Commit.lean` (the message buffer),
`lean/Editor/VersionControl/Worktrees.lean` (the worktree list),
`lean/Editor/VersionControl/ReviewHunks.lean` and
`lean/Editor/VersionControl/Review.lean` (the review buffer),
`lean/Editor/VersionControl/Log.lean` (the log buffer),
`lean/Editor/VersionControl/Blame.lean` (the blame view),
`lean/Editor/VersionControl/Views.lean` (what those buffers share: a day,
the cursor's row, making a read-only buffer and showing it) and
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
| `worktrees` | Every worktree of the repository, each its path and what is checked out there: the main one first, then the linked ones in path order. A bare main repository is no worktree; a worktree whose directory is gone is still listed |
| `branches` | Every local branch's name, in byte order; an unborn branch has no commit and is not one |
| `changes revision against` | The merge base's id of `revision` and `against`, the id `revision` resolved to (its tip), and every path whose content differs between that base and `revision`, with both contents; against `""`, no base, every file of `revision` added. A name that is not a commit, or two with no merge base, refuse it |
| `addWorktree path branch start` | Nothing; a worktree at `path`, on a new branch `branch` made at `start`, or on the existing branch `branch` without a start |
| `removeWorktree path` | Nothing; the linked worktree at `path` and its directory are gone, its branch kept |
| `log revision limit` | `revision` and its first parents, newest first, at most `limit`: each its id, its parents and who wrote it (author, author time, subject). A name that is not a commit, an unborn `HEAD` among them, refuses it |
| `blame revision path` | Each line of `path` at `revision` with the commit that last changed it, and each such commit once with who wrote it; none when the revision lacks the path |
| `rangeDiff base old new` | The commits of `base..old` against those of `base..new`, paired as `git range-diff` pairs them (each side's index, and `=`, `!`, `<` or `>`), and the text it printed |

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
- **A branch's change is committed content only.** It is of `revision`
  against the merge base of `revision` and a branch the caller names, so
  `main`'s commits after the fork are not in it. An agent's uncommitted
  work is its worktree's status. The reply carries the merge base's id, so
  a consumer reads more at the base with `fileAt`. A change is of content:
  renames are off, so a moved file is its old path deleted and its new
  path added, and a change of mode alone, which keeps the content, is not
  listed. Content is decoded by the store's escape rule, as `fileAt`'s is,
  and a submodule's side reads `Subproject commit <id>`, as git prints it.
  A name that is not a commit is refused with status 1, `<name> is not a
  commit`, and two commits with no merge base with status 1, `<revision>
  and <against> have no merge base`, by the model and by git alike. The
  reply carries its tip, the id `revision` resolved to, so a consumer
  records the commit it read at. An empty `against` is no base: every file
  of `revision` is added and the base is empty, which is a root commit's
  change.
- **A log** is first-parent: a branch's own commits, magit's
  `--first-parent` view, deterministic, so the model matches git exactly.
  A merge is one entry; its change is against its first parent. Each entry
  has its id, its parents (the first first) and who wrote it: the
  author's name, the author time in seconds and the subject, git's `%s`,
  the message's first paragraph joined by spaces. The graph view waits.
- **A blame** is of the committed file at a revision, not of a buffer's
  unsaved text: a line is passed to the first parent, then each other in
  order, whose file has it unchanged, and stays with a commit none of whose
  parents has it. Each line has no line feed, since git's porcelain cannot
  tell a last line without one. Each commit a line names is listed once,
  in the order of its first line, with who wrote it.
- **A range-diff's reply is pairs and text.** The pairs, each side's
  commit by its 1-based index in its range (never an id, so no
  abbreviation length is pinned) and how they stand, are what the contract
  compares; the text, what git printed, the diff of each changed pair's
  diffs among it, is what a buffer shows.
- **Making a worktree** with a start makes the branch there; without one
  it checks out an existing local branch. A branch that exists (with a
  start), a missing branch or one checked out in another worktree (without
  one), or a path that is a worktree already, however it is spelled, or a
  directory that holds a file, refuses it and nothing changes: no branch
  is left behind. **Removing one** keeps its branch, and is refused for the main
  worktree, for a path that is no worktree, and for one holding a modified
  or untracked file. Neither has a command yet: agent dispatch calls them
  ([agent-hosting.md](agent-hosting.md)).
- **A name that starts with `-`** (a revision, `against`, a branch, a
  start, a range's base and tips), which a system could read as an option, and a worktree path that
  is not absolute are refused before anything runs, as `invalid`. One pure
  function, `Request.invalid?`, says so, and the model and git both call it
  first, so they cannot disagree.
- **Errors are values**: the system could not be run (missing, denied,
  past its time or output limit), it ran and refused (its exit and its
  standard error), what it printed cannot be read, or the request was
  refused before anything ran.

The interface grows by data, one request at a time, with the phase that
first uses it: a file at a revision and what to watch came with the gutter
marks, a hunk staged and unstaged and a commit with staging hunks, and the
worktrees, the branches, a branch's change and making and removing a
worktree with worktree lifecycle, and a log, a blame and a range-diff with
the history views. Each comes with its reply type, a clause
of the model, a clause of the git implementation and a property of the
contract.

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
checks them, and keeps the message's subject alone, as git's `%s` gives
it. Its status compares `HEAD` with the index and the
index with the working tree, path by path, and pairs renames as git's exact rename detection
does: each path added in the index, in path order, takes the first path
deleted in the index whose `HEAD` content is its content. An empty file is
paired too; git pairs it, and a property of the contract says so.

It also has a commit graph, its branches and its linked worktrees: the main
worktree's directory, commits besides `HEAD`'s by id (parents before
children), branches besides the checked-out one, `HEAD`'s parents and its
id, each linked worktree's directory, its branch or none for detached,
and whether it holds an untracked file, and the directories beside the
root that hold a file and are no worktree. A worktree's path is taken as
git takes it, `normal`: a trailing separator dropped and each `..`
resolved, which is git's answer while the directories hold no link. A name resolves to `HEAD`'s
commit (`HEAD`, or the checked-out branch while it is born), a branch's
commit, a tag (a parentless commit of its files) or a commit's id,
`HEAD`'s among them, and `fileAt` reads through that. Each commit says who
wrote it: unless it says otherwise, `a` at 2026-01-01T00:00:00Z, the
writer's fixed author and time, its subject its id (a tag's its name,
`HEAD`'s `head`), which is what the writer's messages are; a property
gives a commit another author or time. The merge base is the first of one commit's
ancestors, breadth-first, that is the other's: git's answer wherever the
merge base is unique, as in every property's graph; a criss-cross history
has several, and git picks one. A commit freezes `HEAD`'s commit into the
graph and makes `HEAD` a new commit whose parent it is, so a branch made
from `HEAD` before a commit stays where it was. Its log walks first
parents. Its blame hands each line down the graph as git's rule says,
through the model's line diff of each parent's text against the commit's:
git's answer when no rename or move is to be followed, as in every
property's graph; git also follows a file renamed whole, which the model
does not. Its range-diff takes each range as the ancestors of its tip that
are not the base's, merges dropped, oldest first, and pairs a new commit
`=` with the first old one of equal subject, author and patch (its change
against its first parent, hunks without row numbers), then `!` with the
first of equal subject. git pairs `!` by the cost of the diff of the two
patches under `--creation-factor`, so the two agree only where an amended
commit keeps its subject and most of its patch and two commits of
different subjects change different files, as in every property's graph.
It lists the pairs in git's order (range-diff.c's `output`). Making and removing a
worktree refuse with status 128 and git's message. git itself exits 255
when a new branch's name is taken, so the properties compare the exit only
where git's is 128.

The model also prints its status as git prints it with the git
implementation's flags, so the real parser reads the model's status, and
it builds the job model whose process scripts answer the git
implementation's command lines in a repository: the status read, the
writes a test names (a hunk's apply exits 0 whatever it is fed, and a
commit too, unless the repository has a hook), both runs of `fileAt` for
each file of `HEAD`, of the index and of each named revision (an id made of the content alone, then its bytes), the
first run exiting 1 for each revision and path a test names missing, and
`watched`, and the worktree list read, printed as git prints it with `-z`.
A command no script names is refused as "not found", so a test that asks
for a missing path names it.

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
  (`commit.cleanup=strip`), remote branches guessed for a new worktree
  (`worktree.guessRemote`) and every new branch tracking its start
  (`branch.autoSetupMerge=always`), neither of which may change what is
  made, and every commit but `HEAD`'s ignored by blame
  (`blame.ignoreRevsFile`); with a user, which no commit runs without, and
  signing off.
  The writer also writes the model's graph, each commit with
  `commit-tree` over its parents' real ids, `HEAD`'s over its parents
  with its branch pointed at it and the index read from it, each other
  branch with `update-ref`, and each linked worktree with `git worktree
  add` beside the repository, a dirty one given an untracked file, and
  each directory that holds a file beside it with one file. Each commit
  is written by its author at its time (`GIT_AUTHOR_NAME`,
  `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE`), the committer always `a`, so
  a commit by `b` has an author who is not its committer, and its message
  is its subject. The writer also writes `~/ignore-revs` naming every
  commit but `HEAD`'s, which the hostile config's `blame.ignoreRevsFile`
  names. The
  temporary directory is spelled with links resolved, as git spells a
  worktree's path. A repository's hook is written as an executable
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
staged, with a conflicted file (refused with status 128 before the hook
runs, as the model refuses it) and under a hook that refuses.

The properties of worktrees never write a path: each takes the main
worktree's path from the `worktrees` reply and names the others beside it,
so one program holds of the model's `/r` and of a temporary directory. One
is the adapter test that creating a worktree for a new branch and removing
it leaves the list as it was, with the worktree on its branch in between;
others list linked and detached worktrees, make one on an existing branch,
refuse each bad making and removal (a dirty worktree among them, under the
hostile config's `status.showUntrackedFiles=no`; an existing worktree's
path spelled with a trailing `/` or through `..`, and a directory that
holds a file, each leaving the branches as they were; and a tag's name or
a commit's id with no start, which git alone would detach at), refuse a leading `-` and
a relative path, list the branches, and take a branch's change against
`main`: each file changed since the fork with both contents and `main`'s
later commits not in it, a branch made from `HEAD` before a commit, a move
and a copy under a config asking for copies, a byte that is not UTF-8,
and the two refusals with their exit and message, so a drift between
model and git is caught.

The properties of a branch's history never compare an id with a written
one: ids come from replies, and authors, times and subjects are compared.
A log lists a branch's commits through a merge, each with its parents and
who wrote it, one of them by `b` a day later, and gives the two newest when
asked for two; a blame names each line's commit and its author through a
commit that changed one line, written by `b` and committed by `a`, so an
author read from the wrong commit, or the committer read for it, fails; its
changed line is close to the one it replaced, so it fails too if the
command line stops clearing `blame.ignoreRevsFile`, under which git would
hand that line to the parent. A range-diff pairs an amended last commit
`!`, a branch rebased past a commit of `main` on another file all `=`, and
a dropped commit and a gained one `<` then `>` in git's order. A change's
tip is its revision's commit, and a root commit's change against `""` is
its files added. Each refusal of a name that is not a commit has its exit
and message.

## The git implementation

Each run is one `Process.runWithin` in the repository's root, or a fed
`Process.runWithInput` for a hunk, a commit, a change's blobs and the empty
tree, one a request but `fileAt`, `changes`, `addWorktree`, `log`, `blame`
and `rangeDiff`, which run several, so the child gets its directory's
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
| worktrees | `git worktree list --porcelain -z` |
| branches | `git for-each-ref --format=%(refname) refs/heads/` |
| changes | `git rev-parse --verify --quiet <name>^{commit}` for each name, `git merge-base <R> <A>`, `git diff-tree -r -z --no-renames <M> <R>`, then `git cat-file --batch` fed each distinct blob id, one a line; against `""`, `git hash-object -t tree --stdin` fed nothing in place of the merge base |
| log | The name resolved, then `git rev-list --first-parent --max-count=<limit> --no-commit-header --encoding=UTF-8 --format=%H%x00%P%x00%an%x00%at%x00%s <id> --` |
| blame | The name resolved, `git rev-parse --verify --quiet <id>:<path>` (exit 1 is none), then `git blame --porcelain --ignore-revs-file= <id> -- <path>` |
| rangeDiff | Each name resolved, then `git range-diff --no-color --no-notes --creation-factor=60 <B> <O> <N>` |
| addWorktree | `git rev-parse --verify --quiet refs/heads/<branch>`; then `git worktree add --quiet -b <branch> <path> <start>`, and `git branch -D <branch>` when that exits non-zero, or `git worktree add --quiet <path> <branch>` |
| removeWorktree | `git -c status.showUntrackedFiles=normal worktree remove <path>` |

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
- **The worktree list** is read with `-z` (git 2.36 and later), which never
  quotes a path. A bare main repository's record is dropped, the linked
  worktrees after the first record are sorted by path, `branch
  refs/heads/<b>` is the branch and `detached` detached, and `locked`,
  `prunable` and attributes a later git may add are ignored.
- **The branches** are read as full ref names with `refs/heads/` stripped,
  never `%(refname:short)`, which git shortens differently when a tag
  shares a branch's name.
- **A change** resolves each name first, so the merge base and the diff are
  of one pair of commits even if a branch moves meanwhile. `diff-tree` is
  plumbing: no textconv, external diff or colour, and `--no-renames` also
  pins it against `diff.renames=copies`. `cat-file --batch`, without
  `--textconv` or `--filters`, prints raw blobs, each read by its size, so
  one holding a line feed or a NUL is whole; its output must name every id
  asked for, as a blob. `rev-parse` exiting 1 is `<name> is not a commit`,
  and `merge-base` exiting 1 with nothing printed is the no-merge-base
  refusal; the model gives the same. Every stream is held to 16 MiB, so
  the old and new contents together are; past it the request could not
  run, never a partial change.
- **A change against no base** hashes the empty tree with `git
  hash-object -t tree --stdin` fed nothing, so the id is the repository's
  own hash's, and diffs the revision against it: every file is added.
- **The history reads** resolve each name first, as a change does, so a
  name that is not a commit is refused with the same status and message.
  A log is `rev-list`, plumbing, so no `log.*` config
  (`log.showSignature`, `log.mailmap`, `log.decorate`) applies;
  `--no-commit-header` (git 2.33) leaves only the format, whose fields are
  separated by NULs, and `--encoding=UTF-8` pins `i18n.logOutputEncoding`.
  A blame first checks the path is there, as `fileAt` does, and clears a
  user's `blame.ignoreRevsFile` with an empty `--ignore-revs-file=`. A
  range-diff is git's three-argument form, `<base>..<old>` against
  `<base>..<new>`, on the resolved ids; `--no-color` and `--no-notes` pin
  its text, and `--creation-factor=60` pins git's default.
- **Making a worktree** first checks whether the branch is a local one:
  with a start, one that is refused before git runs, so a branch git
  makes later is known to be new; without one, one that is not is
  refused, since `git worktree add <path> <name>` would otherwise detach
  at a tag or commit of that name, or make a branch from a remote one.
  git makes a new branch before it checks the path, so when `worktree add
  -b` exits non-zero the implementation deletes the branch with `git
  branch -D`, and the reply is git's refusal. Rolling back rather than
  checking the path first is what makes this hold for every reason git
  refuses: a path compared as text misses a trailing `/`, a `..` or a
  link (`/var` against `/private/var` on macOS), and resolving paths
  would duplicate git's own rules for a non-empty directory. `-D`
  refuses a branch a worktree has checked out, so a worktree a failing
  `post-checkout` hook left made keeps its branch; a run that timed out
  or was cancelled deletes nothing.
- **Removing a worktree** pins `status.showUntrackedFiles=normal`: under a
  user's `no`, git does not see an untracked file and deletes it with the
  worktree. The hostile config of the contract sets `no`, and its
  property of a dirty worktree caught this.
- **Making and removing** run under the commit's environment and limit of
  their own, `worktreeTime` (10 minutes): checking out a large tree takes
  time, and git runs the `post-checkout` hook, which must see pathspecs as
  patterns. A hook that fails leaves the worktree made while git exits
  non-zero; the reply is git's refusal, and the list then shows it.
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

### Reading the history

The readers of a log, a blame and a range-diff are pure too, and tested on
fixtures git printed (`ModelTest.versionControlHistoryParserChecks`), text
decoded by the store's escape rule.

- **A log**: one record a line, five fields separated by NULs: the id, the
  parents separated by spaces (none for a root), the author's name, the
  author time and the subject. A record of another number of fields, a
  time that is not all digits and an empty id are refused.
- **A blame** (`--porcelain`): for each line a header `<id> <orig> <final>
  [<count>]`, then, the first time a commit is named, its headers, of which
  `author`, `author-time` and `summary` are read and the rest (the
  committer's, `previous`, `boundary`, `filename`) ignored, then a tab and
  the line. Lines are placed by their final number, which must be each of
  1 to n once, and the commits listed in the order of their first line. A
  commit whose line comes before its headers is refused. The fixture's
  author is not its committer, so a reader that took the committer would
  fail.
- **A range-diff**: a pair header is a line with fewer than four leading
  spaces, `<n|->: <id|-…> <=|!|<|>> <n|->: <id|-…> <subject>`, its numbers
  padded to the widest; a line with four leading spaces or more, and an
  empty line, are the diff of a pair's diffs. Any other line is refused. The
  reply's text is the whole output.

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
| `vc-status-stage` | localleader `s` | Stages the cursor's file, or says there is nothing to stage |
| `vc-status-unstage` | localleader `u` | Unstages the cursor's file, or says nothing is staged |
| `vc-worktrees` | localleader `w` | Opens the worktree list of the workspace's repository ("The worktree list") |

The suffixes are under the localleader, `SPC m` under the Vim scheme while
config sets no leader ([keymaps-and-modes.md](keymaps-and-modes.md),
"Roles"), so `SPC m s` stages.

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
- **A buffer with no unsaved changes is the saved file only while its
  file has not changed on disk.** When a check has found the file changed
  (`Buffer.File.changed`) and auto-reload has not reloaded it, the
  buffer's text is not what the working tree holds, and a hunk taken from
  it would put into the index lines no file has. Staging is then refused,
  `<path> changed on disk; reload it (:e) and try again` (`<path> is gone
  from disk; nothing staged` for a file that is gone), when the command
  runs and again when the index has been fetched, before anything is
  snapshotted. A buffer with unsaved changes over a changed file is
  refused by its save instead. Unstaging is not refused: its hunk is of
  the index against `HEAD`, and the buffer only places the cursor.
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
changes, the buffer is saved and that hunk alone is staged; and pressed
twice on one line before the first has staged, the first stages the hunk
and git refuses the second, which is said.

## The message buffer: `vc-commit`

magit's commit message buffer. `vc-commit` (the ex name, and the status
buffer's localleader `c`), under `vc-status`'s gate, shows the workspace's
message buffer if it has one, and otherwise makes `*vc-commit: <label>*`:
empty, editable, with no file, given the workspace, in the major mode
`vc-commit`, shown where the display rules say for the opener `vc-commit`,
and focused. Message conventions (a template, a summary's length,
trailers) are config's business: the buffer's text is the message, as it
is.

| Command | Suffix | What it does |
|---|---|---|
| `vc-commit-accept` | localleader `c` | Commits with the buffer's text, as magit's `C-c C-c`; refused outside the workspace's message buffer and while a commit runs |
| `vc-commit-abort` | localleader `k` | Closes the message buffer, as magit's `C-c C-k`; refused while a commit runs |

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

## The worktree list: `vc-worktrees`

`vc-worktrees` (the ex name, and the status buffer's localleader `w`) lists
every worktree of the focused buffer's workspace's repository, one per
row, in a read-only buffer `*vc-worktrees: <label>*` in the mode
`vc-worktrees`, kept in the workspace's store as the status buffer is.

- **Its text** is `<label>: worktrees`, then `<head>: <path>` per worktree,
  the head its branch or `detached`: `main: /r (this one)`, `feature:
  /w`, `detached: /d`. ` (this one)` marks the asking workspace's root.
- **Its read** is `vc-status`'s gate, then a job keyed by the workspace that
  asks `worktrees`; a failure is said, and a list replaces the kept
  buffer's text, each view keeping its row, or makes the buffer and shows
  it for the opener `vc-worktrees`.
- **`activate`** (`vc-worktrees-visit`) opens the status buffer of the
  worktree on the cursor's row: the asking workspace's own row reads its
  status at once; a path the table has a cached answer for under the
  current generation reads that workspace's; any other runs the workspace
  finder on the path as a job, records its answer as a file's open would,
  and then reads the status of the workspace found. Local workspaces are
  found, never registered, so the status buffer opened is the one opening
  a file in that worktree gives. A worktree whose directory is gone says
  `<path> is not a repository any more`. `refresh` reads the list again.

Pinned by `ModelTest.worktreeViewChecks` and `ModelTest.worktreeBufferChecks`
on the models, and `ContractTest.statusBufferChecks` over real git: the
list of a repository with a worktree on `feature` holding a changed file,
and visiting its row opens `*vc-status: repo@feature*` naming that file.

## The review buffer: `vc-review`

`vc-review` (the ex name, which takes text) opens a branch's change
against its base as an excerpt buffer
([text-and-display.md](text-and-display.md), "Buffers and excerpt
buffers"), hunk by hunk, each kept or reverted, with what was never on
screen drawn so ([review-and-navigation.md](review-and-navigation.md),
"What review needs"). It is the first consumer of `changes revision
against`. A review is of a scope (`ReviewScope`), which every entry point
sets and the whole pipeline carries: a branch against its base
(`vc-review`), `HEAD` since a commit an earlier review recorded
(`vc-review-since`), or one commit against its first parent (a visit from
the log or the blame), so each is the same `vc-review-read` →
`vc-review-diff` → build pipeline.

- **The command.** The text is the branch to review the focused buffer's
  repository's `HEAD` against; with none, the main worktree's branch
  (`worktrees`), and a detached main worktree is refused. Its gate is
  `vc-status`'s; a name that starts with `-` is refused before any job, as
  the interface refuses it (`Request.invalid?`).
- **The pipeline**: a job keyed by the workspace (`vc-review-read`) asks
  `changes "HEAD" <branch>` and loads each changed file with a new side;
  its command takes each file into its buffer without showing it
  (`Files.adopt`), leaving out and later naming a file whose load was
  refused, makes a read-only *old buffer* of each file at the merge base
  (`<path>@<base>`, as `vc-show`'s), snapshots both sides and starts
  `vc-review-diff`, which asks the diff service for each file's hunks.
  Its command groups and orders them, checks that no working buffer moved
  since its snapshot, and builds the buffer, releasing every snapshot on
  every path; a round that ends before the buffer is built removes the old
  buffers it made that no window shows.
- **Hunks and their excerpts.** A hunk is git's: each run of changed lines
  with 3 rows of context, runs whose context touches merged
  (`ReviewSpan.group`). It is one or two tracked excerpts under one
  header, `<path> @@ -a,b +c,d @@` in git's numbers: the base's removed
  lines, from the old buffer, and the hunk with its context, from the
  working file's buffer. So the new text is the working file, uncommitted
  edits included, and an edit typed in a new excerpt is that buffer's. The
  review buffer's own gutter marks added lines `+` and removed ones `-`.
- **Keep and revert** (the mode's leader `k` and `r`): keep records the
  decision; revert replaces the new excerpt with the hunk's old side,
  context included, as one edit through the excerpt text, so one
  transaction on the working buffer and one step of the review buffer,
  which `u` takes back. Each rewrites the header with `  kept` or
  `  reverted`. An undo of a revert leaves the decision `reverted`: the
  decision is what was chosen, not the text's state.
- **The order** is a Lean policy, never alphabetical (`orderFiles`): test
  files first, then, within each group, a file after every file it depends
  on, its text naming the other's module as a whole word, by Kahn's order;
  among files that are ready, the one whose shown hunks change more lines
  first, then the path. The text it reads is the one the review shows, the
  working buffer's, and the line counts are the shown hunks', so the order
  follows the diff the buffer shows whichever engine made it.
- **The status line**: the segment `review`, which version control
  registers and the default order lists, says `<k> kept · <r> reverted ·
  <n> not examined`; a hunk is not examined while one of its excerpts has
  never been on screen. The core's own `ModeLine.standard`, resolved over
  the shipped segments alone, leaves it out; a host's registry holds
  version control's segments, so a host draws it.
- **The record.** The live record (hunks, excerpts, decisions, branch,
  base, the read-only buffers it made, its scope, and `head`, the commit it
  was made at) is the review buffer's value `vc-review`. `head` is the id
  `HEAD`, or the commit reviewed, resolved to when the change was read
  (`Changes.tip`). Each round, with its `head` and each hunk's decision and
  what was viewed of its excerpts, is copied into the workspace's store
  (`reviewStore`), the last 20 kept: it outlives the buffer and a config
  reload, not a restart (task `review-record-on-disk`). Keep and revert
  rewrite the last round in place, its `head` with it. The store is at
  version 2: a version-1 cell's rounds migrate as recording no commit.
- **`refresh`** (`vc-review-refresh`) reads the change again, of the
  record's scope against its branch, into the same buffer, adds a round,
  and removes the last round's old buffers no window shows.
- **A commit's change** (`startCommitReview`, the one entry point the log's
  and the blame's visits call) is `changes <id> <first parent>`, whose
  merge base is the parent, so no new diff request, the parent asked of
  `log <id> 1`; a root commit's is `changes <id> ""`, its files added. Its
  new side is a read-only buffer of the commit's content,
  `<path>@<id8>`, not the working file, which is never taken in; its
  buffer is `*vc-review: <label> <id8>*`. Keep is recorded;
  `vc-review-revert` says `this review is of commit <id8>; nothing to
  revert`. It writes no round: rounds are reviews of a branch's work, and
  "since the last review" reads the last one.
- **Since the last review** (`vc-review-since`, the ex name of that name):
  `vc-review`'s gate, then the workspace's last round. None says `no review
  of <label> is recorded`, and an empty `head` (a round made before rounds
  held one) `the last review of <label> recorded no commit`. Otherwise its
  read asks `changes "HEAD" <head>`: `HEAD` still at `head` says `no change
  since <c8>`; a merge base equal to `head`, which it is exactly when the
  branch only moved forward, is a review buffer `*vc-review: <label> since
  <c8>*` of the commits since, over the working files as a branch's review
  is, whose round, against the same branch at the new `HEAD`, is the next
  one "since" reads; otherwise `HEAD` was rewritten past it, and
  `rangeDiff <branch> <head> HEAD` is shown as text in a read-only
  `*vc-range-diff: <label>*`, its first row `<label>: HEAD was rewritten
  since <c8>; its commits against <branch>`, for the opener
  `vc-review-since`, focused. No merge-base request is added: `changes`'
  base is the answer.

Pinned by `ModelTest.reviewHunkChecks`, `reviewOrderChecks` and
`reviewRecordChecks` (the pure core), `ModelTest.reviewBufferChecks` on the
models, the read run over the interface's model (`Model.readHandler`), and
`ContractTest.reviewBufferChecks` over real git: from a linked worktree,
`vc-review` with no text reviews against `main`, and reverting one hunk
makes that file's buffer hold the base's lines for it and leaves the
other. `ContractTest.historyBufferChecks` runs `vc-review-since` over real
git: after `vc-review` against `base` and a new commit it shows that
commit's hunk alone, and after the commit is amended it opens the
range-diff, which pairs the amended commit `!`.

## The log buffer: `vc-log`

`vc-log` (the ex name, which takes text: a revision, `HEAD` with none)
lists a branch's commits, newest first along first parents, in a read-only
buffer `*vc-log: <label> <revision>*` in the mode `vc-log`, magit's log.

- **Its text** is `<label>: log of <revision>`, then one row per commit,
  `<id8> <day> <subject> (<author>)`, the day the author time's date in UTC;
  `no commits` for none. It asks for 256 commits and one more, and when the
  one more is there shows 256 and a last row `more commits past 256`.
- **Its read** is `vc-status`'s gate, a name that starts with `-` refused
  before any job, then a job keyed by the workspace (`vc-log-read`) that
  asks `log`; a failure is said. A log replaces the text of the
  workspace's buffer of that name holding this log, each view keeping its
  row, or makes the buffer and shows it for the opener `vc-log`, focused.
  The buffer's value `vc-log` holds the root, the revision and each shown
  commit's id.
- **`activate`** (`vc-log-visit`) opens the cursor's commit's change as a
  review buffer ("The review buffer", a commit's change); a row with no
  commit says so. **`refresh`** (`vc-log-refresh`) reads the log again
  into the same buffer.

Pinned by `ModelTest.logViewChecks` and `ModelTest.logBufferChecks` on the
models, and `ContractTest.historyBufferChecks` over real git: `vc-log
feature` lists feature's two commits newest first, and visiting the older
one's row opens its change with its one header.

## Blame: `vc-blame`

`vc-blame` (the ex name, which takes text: a revision, `HEAD` with none)
shows each line of the focused buffer's file at that revision with the
commit that last changed it and that commit's author, in a read-only buffer
`*vc-blame: <path>@<revision>*` in the mode `vc-blame`.

- **It blames the committed file**, not the buffer's unsaved text. Its gate
  is `vc-show`'s: a buffer with no workspace, a location that cannot run
  commands and no file under the root are said, and a revision that starts
  with `-` is refused before any job. Its job is keyed by the root, the
  revision and the path; "not there" says `vc-blame: <path> is not in
  <revision>`.
- **Its text** has one row per line and no header row, so row r is line r:
  `<id8> <author> <day> | <line>`, the author cut at 16 characters and
  padded to the widest. The buffer's value `vc-blame` holds each row's
  commit.
- **`activate`** (`vc-blame-visit`) opens the row's commit's change as a
  review buffer.
- Which lines an agent wrote, as against a person, waits for provenance
  ([review-and-navigation.md](review-and-navigation.md), "History views").

Pinned by `ModelTest.blameViewChecks` and `ModelTest.blameBufferChecks` on
the models, where the changed line's row names its commit's author `b` and
the others `a`, and `ContractTest.historyBufferChecks` over real git, under
the hostile config whose `blame.ignoreRevsFile` names every commit but
`HEAD`'s: the changed line's row alone names `HEAD`'s commit and its author
`b`.

## Open questions

- **A worktree list per repository.** The list is kept per workspace, as
  the status buffer is, though every worktree of a repository lists the
  same rows. One per repository (per common directory, in the project's
  store) would share it.
- **Uncommitted work in a change.** `changes` is committed content; an
  agent's uncommitted work is its worktree's status and `fileAt` of the
  index. The review buffer diffs the base against the working file's
  buffer, so it shows uncommitted work on the files the branch changed,
  but not a file changed only in the working tree, which `changes` does
  not list. A working-tree side of `changes` would show those too.
- **The change's output limit.** One `cat-file --batch` holds every
  content of a change, under 16 MiB a stream; a larger change could not
  run. A larger named limit, or a read per file, would lift it.
- **Path spelling.** git spells a worktree's path with links resolved. The
  ` (this one)` mark and visiting the asking workspace's own row compare
  the stored root with that spelling, and miss it for a root spelled
  through a link; a find then runs, which is harmless.

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
- **Renames in blame.** git's blame follows a file renamed whole into a
  parent; the model does not, and no property renames one. A property that
  does needs the model to follow it.
- **The model's `!` pairing.** The model pairs a range-diff's changed
  commits by subject; git by the cost of the diff of their patches. They
  agree on the properties' graphs only; a model of git's cost and its
  assignment would agree everywhere.
- **The log's graph view.** The log is first-parent; a graph of every
  parent waits.
- **A range-diff of the review's hunks.** A rewritten branch's change since
  the last review is git's range-diff as text; the hunks of the diff of
  diffs as a review buffer, kept and reverted, would review it as the rest
  is.
- **Status time on a large repository.** A process per read may be too slow
  on a large repository; an in-process library can sit behind the same
  interface, as the roadmap allows.
