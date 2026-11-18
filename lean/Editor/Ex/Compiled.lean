import Editor.Buffers
import Editor.Compile
import Editor.Config.Registry
import Editor.Ex
import Editor.Files
import Editor.VersionControl.Blame
import Editor.VersionControl.Commit
import Editor.VersionControl.Log
import Editor.VersionControl.Review
import Editor.VersionControl.Show
import Editor.VersionControl.Stage
import Editor.VersionControl.Status

/-!
# The ex line's commands and the ex names that ship, as compiled code registers them

What a host is handed so that it has the ex command line (`Editor/Ex.lean`):
the registrations of its commands, and the ex bindings that ship. A host
registers both for the owner `compiled` when its loop starts, before any
config (`Editor/Config/Registry.lean`, "Compiled commands", "Ex bindings"),
so they hold when config fails to load, a reload does not replace them, and
config's binding of a shipped ex name runs in its place until a reload
drops it.

- **`Ex.commands`**: each a command that is given what it was called with
  (`Action.call`).
  - `ex` opens the ex line, and runs the line it is answered
    (`Ex.exCommand`). A host must be handed the minibuffer's commands too
    (`Editor/Minibuffer/Compiled.lean`) for that prompt to be answered, and
    the shell's commands and job (`Editor/Shell/Compiled.lean`) for a `:!`
    line or a filter to run.
  - `quit` asks the editor to quit, and says a refusal in the echo area
    (`Ex.quitCommand`).
  - `save-and-quit` saves the buffer of the window it was called with and
    asks the editor to quit if the save started (`Ex.saveQuitCommand`). A
    host must be handed the save job too (`Files.jobs`).
  - `reload-config` asks for the config to be reloaded
    (`Ex.reloadCommand`).
- **`Ex.bindings`**: the ex names that ship. Each is bound to a command by
  its name, so a host must be handed that command too.
  - `w` runs `save-buffer` (`Editor/Files.lean`) and takes nothing: it
    saves the buffer of the window the line was asked from. `w` with an
    argument is refused by the ex line (`Ex.noArgument`): saving under
    another name is not built, and the save command would ignore the name.
  - `w!` runs `save-buffer` with `true`, the forced save, and takes
    nothing: it writes the buffer over whatever the file on disk now is,
    the "write mine over theirs" resolution of a file that changed under
    unsaved edits (`docs/design/agent-hosting.md`).
  - `e` runs `edit-file` and takes text: the rest of the line is the path,
    whole, spaces included, which it opens. `e` with no argument reads the
    window's file again, as Vim's does (`Files.reload`), refused while the
    buffer has unsaved changes; on a buffer with no file it asks for a
    path, as `open-file` does.
  - `e!` runs `edit-file` with `true` first, and takes text: with no
    argument the reload is forced, the file's text taken as one step that
    `u` undoes ("take theirs"); with a path it opens it as `e` does, since
    buffers persist and nothing is discarded. Only a leading `!` is
    parsed, as the shell's: `e!` and `w!` are names of their own
    (`Editor/Ex/Line.lean`), each a binding with fixed arguments
    (`Binding.arguments`).
  - `q` runs `quit` and takes nothing. It quits the editor, not the
    window the line was asked from: no shipped command splits a window.
  - `wq` runs `save-and-quit` and takes nothing.
  - `reload` runs `reload-config` and takes nothing.
  - `b` runs `switch-buffer` (`Editor/Buffers.lean`) and takes text: the
    rest of the line names the buffer, exactly or by fuzzy match. `b` with
    no argument runs it with none, which asks, by that command's own rule,
    as `e` does. Vim's `b` refuses a pattern that matches more than one
    buffer; this one takes the best match.
  - `ls` runs `list-buffers` and takes nothing.
  - `bd` runs `close-buffer` and takes text: the rest of the line is the
    name of the buffer to close, and with none it closes the buffer of the
    window the line was asked from.
  - `compile` runs `compile` (`Editor/Compile.lean`) and takes text: the
    rest of the line is the command line, run in the buffer's workspace;
    with none it asks for one. A host must be handed the compile mode's
    commands and job (`Editor/Compile/Compiled.lean`).
  - `compile-command` runs `compile-command` and takes text: the rest of
    the line chooses one of the buffer's on-modes' named commands, by its
    candidate or its bare name, and with none it asks for one.
  - `recompile` runs `recompile` and takes nothing: it reruns the
    workspace's last line.
  - `kill-compilation` runs `kill-compilation` and takes nothing.
  - `next-error` and `previous-error` run `next-error` and
    `previous-error` and take nothing: they step through the locations of
    the focused buffer's workspace's compilation. No global key binds
    them.
  - `vc-status` runs `vc-status` (`Editor/VersionControl/Status.lean`)
    and takes nothing: it opens the status buffer of the workspace of the
    buffer the line was asked from. A host must be handed the status
    buffer's commands, jobs and mode
    (`Editor/VersionControl/Compiled.lean`).
  - `vc-show` runs `vc-show` (`Editor/VersionControl/Show.lean`) and takes
    text, a revision and a path: it opens that file at that revision as a
    read-only buffer.
  - `vc-stage-hunk` and `vc-unstage-hunk` run the commands of those names
    (`Editor/VersionControl/Stage.lean`) and take nothing: they stage, or
    unstage, the hunk on the cursor's line of the focused file buffer. No
    key binds them; binding one is config's.
  - `vc-commit`, `vc-commit-accept` and `vc-commit-abort` run the commands
    of those names (`Editor/VersionControl/Commit.lean`) and take nothing:
    they open the message buffer, commit with its text, and give it up.
  - `vc-worktrees` runs `vc-worktrees`
    (`Editor/VersionControl/Worktrees.lean`) and takes nothing: it opens
    the worktree list of the focused buffer's workspace's repository.
  - `vc-review` runs `vc-review` (`Editor/VersionControl/Review.lean`) and
    takes text, a branch, or nothing for the main worktree's: it opens the
    review buffer of `HEAD`'s change against that branch.
  - `vc-review-since` runs `vc-review-since`
    (`Editor/VersionControl/Review.lean`) and takes nothing: it opens the
    change since the commit the last review recorded.
  - `vc-log` runs `vc-log` (`Editor/VersionControl/Log.lean`) and takes
    text, a revision, or nothing for `HEAD`: it opens the log buffer of
    that revision's commits.
  - `vc-blame` runs `vc-blame` (`Editor/VersionControl/Blame.lean`) and
    takes text, a revision, or nothing for `HEAD`: it opens the blame of the
    focused buffer's file at that revision.

This module is apart from `Editor/Ex.lean` because it names the registry,
which is the config session's: `Editor.lean` imports the commands, so that
config can call them, and not this.

Pinned by `ModelTest.exChecks`, on the models; by `ConfigTest.exChecks` and
`ConfigTest.exScriptChecks`, through the headless host; and on the
executable by the fixture `tests/headless/ex` and the two process checks
of the `ffi-test` task.
-/

namespace Editor.Ex

/-- The ex line's commands, as a host registers them for the owner
`compiled`. -/
def commands : Array Config.Registration :=
  #[{ name := name, action := .call exCommand }, { name := quitName, action := .call quitCommand },
    { name := saveQuitName, action := .call saveQuitCommand },
    { name := reloadName, action := .call reloadCommand }]

/-- The ex names that ship, as a host registers them for the owner
`compiled`. -/
def bindings : Array Binding :=
  #[{ name := "w", command := Files.saveName },
    { name := "w!", command := Files.saveName, arguments := [.bool true] },
    { name := "e", command := Files.editName, takes := .text },
    { name := "e!", command := Files.editName, takes := .text, arguments := [.bool true] },
    { name := "autoread", command := Files.autoReloadName, arguments := [.bool true] },
    { name := "noautoread", command := Files.autoReloadName, arguments := [.bool false] },
    { name := "q", command := quitName }, { name := "wq", command := saveQuitName },
    { name := "reload", command := reloadName },
    { name := "b", command := Buffers.switchName, takes := .text },
    { name := "ls", command := Buffers.listName },
    { name := "bd", command := Buffers.closeName, takes := .text },
    { name := "compile", command := Compile.compileName, takes := .text },
    { name := "compile-command", command := Compile.commandName, takes := .text },
    { name := "recompile", command := Compile.recompileName },
    { name := "kill-compilation", command := Compile.killName },
    { name := "next-error", command := Compile.nextName },
    { name := "previous-error", command := Compile.previousName },
    { name := "vc-status", command := VersionControl.statusName },
    { name := "vc-show", command := VersionControl.showName, takes := .text },
    { name := "vc-stage-hunk", command := VersionControl.stageHunkName },
    { name := "vc-unstage-hunk", command := VersionControl.unstageHunkName },
    { name := "vc-commit", command := VersionControl.commitName },
    { name := "vc-worktrees", command := VersionControl.worktreesName },
    { name := "vc-commit-accept", command := VersionControl.acceptName },
    { name := "vc-commit-abort", command := VersionControl.abortName },
    { name := "vc-review", command := VersionControl.reviewName, takes := .text },
    { name := "vc-review-since", command := VersionControl.reviewSinceName },
    { name := "vc-log", command := VersionControl.logName, takes := .text },
    { name := "vc-blame", command := VersionControl.blameName, takes := .text }]

/-- The ex line's completion sources, as a host registers them for the owner
`compiled`, so config can ask for them by name: the `:!` history, then the
ex names. -/
def sources : Array Completion.Source :=
  #[historySource, namesSource]

end Editor.Ex
