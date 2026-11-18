import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Compile.Compiled
import Editor.Compile.Shipped
import Editor.Display.Model
import Editor.Ex.Compiled
import Editor.Ex.Line
import Editor.File.Model
import Editor.FileWatch.Model
import Editor.Floating
import Editor.InputScheme.Test
import Editor.InputScheme.Vim.Default
import Editor.Job.Model
import Editor.Json
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Minibuffer.Compiled
import Editor.Mode
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Role
import Editor.Scene
import Editor.Scroll
import Editor.Shell.Compiled
import Editor.State
import Editor.State.Request
import Editor.SyntaxTree.Model
import Editor.Text.Contract
import Editor.Watch.Model
import ModelTest.Workspace

/-!
# Model tests: shell, compile and project

The checks of the shell, compilation and its errors, locations and hooks,
project formats, JSON, listings, the project mode, read-only buffers and
excerpts.

Its lists of checks: `shellChecks`, `compileChecks`, `compileErrorChecks`,
`compileLocationChecks`, `compileHookChecks`, `projectFormatChecks`,
`jsonChecks`, `listingChecks`, `projectModeChecks`, `readOnlyChecks`,
`excerptBufferChecks`, `excerptDisplayChecks`.

The root module `ModelTest` describes each group and runs them all from
`checks`.
-/

namespace ModelTest

open Editor

/-- The jobs of the shell checks: the workspace driver checks', and the
shell's run job. -/
def shellJobs (name : String) : Option (List Argument → Work) :=
  if name == Shell.runJob then some Shell.runWork else workspaceJobs name

/-- `/bin/sh -c text` in `directory`: the child a `:!` line runs. -/
def shellCommand (directory : System.FilePath) (text : String) : Process.Command :=
  { program := "/bin/sh", arguments := #["-c", text], directory }

/-- A run of a shell checks' child that wrote `stdout` and `stderr` and
ended as `exit`. -/
def shellReply (stdout : String) (stderr : String := "") (exit : Process.Exit := .code 0) :
    Except ProcessError Process.Ran :=
  .ok { exit, stdout := stdout.toUTF8, stderr := stderr.toUTF8 }

/-- What each child of the shell checks does. -/
def shellScripts : Array Process.Script :=
  #[{ command := shellCommand "/r" "make", reply := shellReply "" },
    { command := shellCommand "/x" "make", reply := shellReply "" },
    { command := shellCommand "/home/ada" "make", reply := shellReply "" },
    { command := shellCommand "/r" "echo hi", reply := shellReply "hi\n" },
    { command := shellCommand "/r" "fail", reply := shellReply "hi\n" "" (.code 3) },
    { command := shellCommand "/r" "true", reply := shellReply "" },
    { command := shellCommand "/r" "build", reply := shellReply "l1\nl2\n" "warn" (.code 2) },
    { command := shellCommand "/r" "rebuild", reply := shellReply "again\nand again\n" },
    { command := shellCommand "/r" "warn", reply := shellReply "one\n" "careful\n" },
    { command := shellCommand "/w" "build", reply := shellReply "w1\nw2\n" },
    { command := shellCommand "/x" "ls -l", reply := shellReply "a.txt\nb.txt\n" },
    { command := shellCommand "/r" "sleep 40", reply := shellReply "", takes := 40000 },
    { command := shellCommand "/r" "sleep 10", reply := shellReply "", takes := 10000 },
    { command := shellCommand "/r" "sort", reply := shellReply "a\nb\nc\n" },
    { command := shellCommand "/r" "tac", reply := shellReply "a\nc\n" },
    { command := shellCommand "/r" "sort -u", reply := shellReply "a\nb\nc\nd\n" }]

/-- `driver` with `script` ahead of the scripts it has, so its command does
what it says. -/
def withScript (driver : TestDriver) (script : Process.Script) : TestDriver :=
  { driver with
    jobs :=
      { driver.jobs with
        processes :=
          { driver.jobs.processes with scripts := #[script] ++ driver.jobs.processes.scripts } } }

/-- The compiled commands `registrations` as the dispatch checks run them. -/
def dispatchedOf (registrations : Array Config.Registration) : List (String × Dispatched) :=
  registrations.toList.filterMap fun registration =>
    match registration.action with
    | .call run =>
      some
        (registration.name, fun call => do
          run call
          return none)
    | _ => none

/-- The bindings of the shell checks (`shellKeys`). -/
def shellBindings : List (String × Invocation) :=
  workspaceBindings ++
    [("C-e e", invoke Ex.name), ("C-e y", invoke Minibuffer.acceptName), ("C-e k", invoke "kube"),
      ("C-e g", invoke Shell.interruptName), ("C-e u", invoke "undo"), ("C-e o", invoke "squat"),
      ("C-e s", invoke "split"), ("C-e c", invoke "close"), ("C-e x", invoke "drop"),
      ("C-o s", opens "/r/src/s.txt"), ("C-o t", opens "/r/src/t.txt")]

/-- The commands of the shell checks (`shellKeys`). -/
def shellCommands : List (String × Dispatched) :=
  workspaceCommands ++ dispatchedOf (Ex.commands ++ Minibuffer.commands ++ Shell.commands) ++
    [("kube", fun call => do
        let location := Location.reachable "kube" "pod" "/app"
        discard <| Workspace.register location workspaceOrigin
        Workspace.setBufferWorkspace call.target.window.buffer location
        return none),
      ("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("squat", fun (_ : Call) => do
        discard <| createBuffer "*shell output: r@main*"
        return none),
      ("split", fun call => do
        if let .ok made← call.target.window.id.split then
          discard <| made.focus
        return none),
      ("close", fun call => do
        discard <| call.target.window.id.close
        return none),
      ("drop", fun call => do
        let window := call.target.window
        if let .ok elsewhere← createBuffer "elsewhere" then
          discard <| window.id.show elsewhere
          discard <| window.buffer.remove
        return none)]

/-- The keys of the shell checks: the workspace driver checks', and `C-e e`
and `C-e y`, the ex line and its accept key (`exLine`); `C-e g` runs the
interrupt command, as `C-g` does under the Vim scheme; `C-e k` gives the
window's buffer a workspace registered as reachable through `kube`, which
cannot run commands; `C-e u` undoes in the window's buffer; `C-e o` makes
a buffer `*shell output: r@main*` that the shell did not make; `C-e s`
splits the window and focuses the new one, and `C-e c` closes the window;
`C-e x` shows a new buffer `elsewhere` in the window and removes the buffer
it showed; and `C-o s` and `C-o t` open `/r/src/s.txt` and
`/r/src/t.txt`. -/
def shellKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys shellBindings shellCommands

/-- A driver of the shell checks: the workspace driver's world, with the
shell's keys and jobs, and the children of `shellScripts`; `none` if
making the state was refused. -/
def shellDriver : Option TestDriver :=
  (workspaceDriver shellJobs shellKeys).map fun driver =>
    { driver with
      jobs :=
        { driver.jobs with
          processes :=
            { driver.jobs.processes with
              scripts := driver.jobs.processes.scripts ++ shellScripts } } }

/-- `driver` once the ex line `line` is run and every job it starts is
finished. -/
def shellRan (driver : TestDriver) (line : String) : TestDriver :=
  settledOn driver (exLine line)

/-- The text of the buffer `id` in `driver`'s text model. -/
def bufferText (driver : TestDriver) (id : BufferId) : Option String := do
  let buffer ← driver.loop.state.buffer? id
  (driver.model.texts.texts[buffer.text.index]?).join.map (·.contents)

/-- The text of the buffer called `name` in `driver`. -/
def namedText (driver : TestDriver) (name : String) : Option String := do
  bufferText driver (← driver.loop.state.findBuffer name)

/-- The names of `driver`'s buffers that are shell output buffers. -/
def outputBuffers (driver : TestDriver) : Array String :=
  (driver.loop.state.buffers.filterMap id).map (·.name) |>.filter (·.startsWith "*shell output")

/-- What the focused view of `driver` shows (`showing`). -/
def showingFocused (driver : TestDriver) : Option Showing :=
  showing driver driver.loop.state.frame.focused

/-- `driver` with `rules` as config's display rules, which the loop hands
the commands it runs (`Loop.Registered.displayRules`). -/
def withDisplayRules (driver : TestDriver) (rules : Array DisplayRule) : TestDriver :=
  { driver with
    keys :=
      { driver.keys with registered := { driver.keys.registered with displayRules := rules } } }

/-- The checks of `:!` (`Editor/Shell.lean`), on the loop's driver over the
editor's models, the job model and the process model, in the world of the
workspace driver checks: a main checkout `/r`, a linked worktree `/w` of one
project, and `/x` in none. -/
def shellChecks : List Check :=
  let main : Option Location := some (.local "/r")
  [{  name :=
        "criterion 3: `:!make` runs /bin/sh -c make in the buffer's workspace root; in a buffer with no workspace, in its file's directory; in one with neither, in the editor's working directory"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let inR := shellRan (settledAfter driver "C-o a") "!make"
            let inX := shellRan (settledAfter driver "C-o x") "!make"
            let scratch :=
              shellRan
                { driver with
                  loop :=
                    { driver.loop with
                      state := { driver.loop.state with workingDirectory := "/home/ada" } } }
                "!make"
            inR.jobs.processes.started.back? == some (shellCommand "/r" "make") &&
              inX.jobs.processes.started.back? == some (shellCommand "/x" "make") &&
              scratch.jobs.processes.started == #[shellCommand "/home/ada" "make"] },
    { name :=
        "criterion 4: one line of output and exit 0 puts the line in the echo area, and no output buffer is made; a status that is not 0 is said after the line, and no output says so"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let hi := shellRan opened "!echo hi"
            echoOf hi == some "hi" && outputBuffers hi == #[] &&
              (showing hi).map (·.buffer.name) == some "a.lean" &&
              echoOf (shellRan opened "!fail") == some "hi [exit 3]" &&
              echoOf (shellRan opened "!true") == some "!true: no output" },
    { name :=
        "criterion 5: two lines of output and anything on standard error open `*shell output: r@main*`, holding standard output, standard error and the exit status, with the workspace /r, shown where the display rules say: with none, in a new window at the end of the tiled list, focused, view 0 still showing a.lean; one line with standard error opens it too"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let built := shellRan opened "!build"
            let warned := shellRan opened "!warn"
            let frame := built.loop.state.frame
            match built.loop.state.findBuffer "*shell output: r@main*", showingFocused built with
            | some id, some shown =>
              shown.id == id && shown.text == some "l1\nl2\nwarn\n[exit 2]\n" &&
                frame.windows == #[⟨0⟩, frame.focused] &&
                frame.focused != ⟨0⟩ &&
                (showing built).map (·.buffer.name) == some "a.lean" &&
                (built.loop.state.workspaceOf? id).map (·.1.location) == some (.local "/r") &&
                namedText warned "*shell output: r@main*" == some "one\ncareful\n[exit 0]\n"
            | _, _ => false },
    { name :=
        "the output buffer goes where a display rule for `shell-command` says: one with the focused target shows it in the window the line was asked from; and a run while a window shows the output buffer reuses that window, whatever the rules say"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let ruled :=
              withDisplayRules driver #[{ opener := some Shell.commandName, target := .focused }]
            let inPlace := shellRan (settledAfter ruled "C-o a") "!build"
            let stacked := shellRan (settledAfter driver "C-o a") "!build"
            let again := shellRan stacked "!rebuild"
            inPlace.loop.state.frame.windows == #[⟨0⟩] &&
              (showing inPlace).map (·.buffer.name) == some "*shell output: r@main*" &&
              stacked.loop.state.frame.windows.size == 2 &&
              again.loop.state.frame.windows == stacked.loop.state.frame.windows &&
              again.loop.state.frame.focused == stacked.loop.state.frame.focused &&
              (showingFocused again).bind (·.text) == some "again\nand again\n[exit 0]\n" },
    { name :=
        "criterion 6: a second run in the workspace replaces the text of the same output buffer, and makes no second one"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let first := shellRan (settledAfter driver "C-o a") "!build"
            let second := shellRan (settledAfter first "C-o a") "!rebuild"
            let id := first.loop.state.findBuffer "*shell output: r@main*"
            id.isSome && second.loop.state.findBuffer "*shell output: r@main*" == id &&
              (showingFocused second).map (·.id) == id &&
              namedText second "*shell output: r@main*" == some "again\nand again\n[exit 0]\n" &&
              outputBuffers second == #["*shell output: r@main*"] },
    { name :=
        "a run after the kept output buffer was removed makes a new one, holding the new run's output, and the workspace keeps the new one's number"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let first := shellRan (settledAfter driver "C-o a") "!build"
            let removed := settledAfter first "C-e x"
            let second := shellRan (settledAfter removed "C-o a") "!rebuild"
            let state := second.loop.state
            match first.loop.state.findBuffer "*shell output: r@main*",
              state.findBuffer "*shell output: r@main*" with
            | some old, some made =>
              (removed.loop.state.buffer? old).isNone && made != old &&
                bufferText second made == some "again\nand again\n[exit 0]\n" &&
                (showingFocused second).map (·.id) == some made &&
                Shell.scopedValue state Shell.outputStore main == some made.index &&
                (state.workspaceOf? made).map (·.1.location) == some (.local "/r")
            | _, _ => false },
    { name :=
        "with a buffer the shell did not make holding the output buffer's name, a run makes `*shell output: r@main*<2>`, and leaves that buffer alone"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let squatted := settledAfter (settledAfter driver "C-o a") "C-e o"
            let ran := shellRan squatted "!build"
            let state := ran.loop.state
            match state.findBuffer "*shell output: r@main*<2>" with
            | some made =>
              bufferText ran made == some "l1\nl2\nwarn\n[exit 2]\n" &&
                namedText ran "*shell output: r@main*" == some "" &&
                (showingFocused ran).map (·.id) == some made &&
                Shell.scopedValue state Shell.outputStore main == some made.index
            | none => false },
    { name :=
        "output asked for from a view closed before the run ends is shown where the display rules say for the focused view: with none, in a new window at the end of the tiled list, focused, view 0 still showing a.lean"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let split := settledAfter (settledAfter driver "C-o a") "C-e s"
            let asked := (fedTo split (exLine "!build")).1
            let closed := (fedTo asked (presses "C-e c")).1
            let finished := asked.pending.foldl (fun driver job => (driver.finish job.id).1) closed
            let state := finished.loop.state
            split.loop.state.frame.focused != (⟨0⟩ : ViewId) && asked.pending.size == 1 &&
              (state.window? split.loop.state.frame.focused).isNone &&
              state.frame.windows == #[⟨0⟩, state.frame.focused] &&
              (showing finished).map (·.buffer.name) == some "a.lean" &&
              (showingFocused finished).map (·.buffer.name) == some "*shell output: r@main*" &&
              (showingFocused finished).bind (·.text) == some "l1\nl2\nwarn\n[exit 2]\n" },
    { name :=
        "criterion 7: in a buffer with no workspace, long output goes to `*shell output*` and the line to the editor-wide history; the project's history is left as it was"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let ran := shellRan (settledAfter (settledAfter driver "C-o a") "C-o x") "!ls -l"
            let table := ran.loop.state.workspaces
            namedText ran "*shell output*" == some "a.txt\nb.txt\n[exit 0]\n" &&
              (showingFocused ran).map (·.buffer.name) == some "*shell output*" &&
              table.getUnscoped Shell.historyStore == #["!ls -l"] &&
              table.getOfProject Shell.historyStore (.remote "github.com/o/r") == #[] },
    { name :=
        "criterion 8: runs in two worktrees of one repository open two output buffers, `*shell output: r@main*` and `*shell output: r@feature*`, each holding only its own run's output"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let inR := shellRan (settledAfter driver "C-o a") "!build"
            let inW := shellRan (settledAfter inR "C-o w") "!build"
            namedText inW "*shell output: r@main*" == some "l1\nl2\nwarn\n[exit 2]\n" &&
              namedText inW "*shell output: r@feature*" == some "w1\nw2\n[exit 0]\n" &&
              outputBuffers inW == #["*shell output: r@main*", "*shell output: r@feature*"] },
    { name :=
        "criterion 9: a `:!` line run in one worktree is offered first by the ex prompt in the other worktree's buffer, before the bound ex names; the history is the project's, newest first, each line once"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let ran := shellRan (shellRan (settledAfter driver "C-o a") "!make") "!echo hi"
            let again := shellRan ran "!make"
            let asked := (fedTo (settledAfter again "C-o w") (presses "C-e e")).1
            (candidatesOf asked).map (·.all.toList.take 2) == some ["!make", "!echo hi"] &&
              again.loop.state.workspaces.getOfProject Shell.historyStore
                  (.remote "github.com/o/r") ==
                #["!make", "!echo hi"] },
    { name :=
        "criterion 10: in a buffer of a workspace whose location cannot run commands, `:!` starts no job and no process, records nothing, and says why"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let kube := settledAfter (settledAfter driver "C-o a") "C-e k"
            let ran := shellRan kube "!ls"
            ran.jobs.processes.started == kube.jobs.processes.started && ran.next == kube.next &&
              echoOf ran ==
                some "!: r@app is reachable through kube pod at /app, where commands cannot run" &&
              ran.loop.state.workspaces.getOfProject Shell.historyStore
                  (.remote "github.com/o/r") ==
                #[] },
    { name :=
        "criterion 14: the interrupt while `:!sleep 10` runs cancels its job by the workspace's key: the step hands the key back, the job is no longer pending and finishing it delivers nothing, what the workspace runs is cleared, and the echo area says the line was interrupted; with nothing running it says Quit"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let running := (fedTo opened (exLine "!sleep 10")).1
            let (quit, steps) := fedTo running (presses "C-e g")
            let (after, delivered) :=
              match running.pending[0]? with
              | some job => quit.finish job.id
              | none => (quit, none)
            running.pending.map (·.key) == #[some "shell local /r"] &&
              Shell.scopedValue running.loop.state Shell.runningStore main == some "!sleep 10" &&
              steps.flatMap (fun step => (step.map (·.cancels)).getD #[]) == #["shell local /r"] &&
              quit.pending.isEmpty &&
              delivered.isNone &&
              Shell.scopedValue after.loop.state Shell.runningStore main == none &&
              echoOf after == some "!sleep 10: interrupted" &&
              echoOf (fedTo opened (presses "C-e g")).1 == some Shell.quitText },
    { name :=
        "criterion 14 on the job model: a run whose job is cancelled while its child runs ends cancelled, and its child is killed"
      run :=
        let order : Shell.Order :=
          { line := "!sleep 10", text := "sleep 10", directory := "/r", time := 30000, buffer := ⟨0⟩
            view := ⟨0⟩, scope := main }
        let model : JobModel :=
          { processes :=
              {
                scripts :=
                  #[{ command := shellCommand "/r" "sleep 10", reply := shellReply ""
                      takes := 10000 }] }
            cancelAt := some 1000 }
        let (outcome, after) := (Shell.runWork order.arguments ()).runModel model
        pure
          ((outcome matches .cancelled) &&
            after.processes.killed == #[shellCommand "/r" "sleep 10"]) },
    { name :=
        "criterion 15: a run past the time limit is killed and the echo area says so, naming the limit, 30 seconds by default or config's; what the workspace runs is cleared"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let running := (fedTo opened (exLine "!sleep 40")).1
            let ran := shellRan opened "!sleep 40"
            let limited :=
              { opened with
                keys :=
                  { opened.keys with
                    registered := { opened.keys.registered with shellTimeLimit := some 5000 } } }
            let short := shellRan limited "!sleep 40"
            Shell.scopedValue running.loop.state Shell.runningStore main == some "!sleep 40" &&
              echoOf ran == some "!sleep 40: the run did not end within 30000 ms and was killed" &&
              ran.jobs.processes.killed.contains (shellCommand "/r" "sleep 40") &&
              Shell.scopedValue ran.loop.state Shell.runningStore main == none &&
              echoOf short == some "!sleep 40: the run did not end within 5000 ms and was killed" },
    { name :=
        "criterion 2 on the loop: `:1,7!sort` on a buffer of three lines says that line 7 is past its end, and starts nothing"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o s"
            let ran := shellRan opened "1,7!sort"
            echoOf ran == some s!"1,7!sort: {Ex.pastEnd 7 3}" && ran.next == opened.next &&
              ran.jobs.processes.started == opened.jobs.processes.started &&
              (showing ran).bind (·.text) == some "b\nc\na\n" },
    { name :=
        "criterion 11: `:%!sort` over three unsorted lines feeds the child those lines and leaves them sorted, as one change that one undo takes back"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let sorted := shellRan (settledAfter driver "C-o s") "%!sort"
            let undone := settledAfter sorted "C-e u"
            sorted.jobs.processes.fed == #[(shellCommand "/r" "sort", "b\nc\na\n".toUTF8)] &&
              (showing sorted).bind (·.text) == some "a\nb\nc\n" &&
              echoOf sorted == some "3 lines filtered" &&
              (showing undone).bind (·.text) == some "b\nc\na\n" },
    { name :=
        "criterion 12: a filter that exits 1, writing to standard error, leaves the buffer unchanged and says the status and the first line of standard error"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let failing :=
              withScript driver
                { command := shellCommand "/r" "sort",
                  reply := shellReply "" "sort: bad\nmore\n" (.code 1) }
            let ran := shellRan (settledAfter failing "C-o s") "%!sort"
            (showing ran).bind (·.text) == some "b\nc\na\n" &&
              echoOf ran == some "%!sort: exit 1: sort: bad" },
    { name :=
        "criterion 13: a filter whose buffer is edited before its child ends leaves the edit alone, does not sort, and says it was dropped"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o s"
            let (asked, _) := fedTo opened (exLine "%!sort")
            let (edited, _) := fedTo asked [.commit "z"]
            let finished := asked.pending.foldl (fun driver job => (driver.finish job.id).1) edited
            asked.pending.size == 1 && (showing edited).bind (·.text) == some "zb\nc\na\n" &&
              (showing finished).bind (·.text) == some "zb\nc\na\n" &&
              echoOf finished == some "%!sort: dropped: the buffer changed while it ran" },
    { name :=
        "criterion 13: a filter whose buffer is removed before its child ends writes no text, and says it was dropped"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o s"
            let (asked, _) := fedTo opened (exLine "%!sort")
            let (removed, _) := fedTo asked (presses "C-e x")
            let finished := asked.pending.foldl (fun driver job => (driver.finish job.id).1) removed
            asked.pending.size == 1 && (removed.loop.state.findBuffer "s.txt").isNone &&
              finished.pending.isEmpty &&
              finished.model.texts.contents == removed.model.texts.contents &&
              echoOf finished == some "%!sort: dropped: the buffer changed while it ran" },
    { name :=
        "a filter of a range replaces only those lines; a last line with no line feed is fed with one, and the output's last line feed is dropped for it"
      run :=
        pure <|
          match shellDriver with
          | none => false
          | some driver =>
            let middle := shellRan (settledAfter driver "C-o s") "2,3!tac"
            let open' := shellRan (settledAfter driver "C-o t") "%!sort -u"
            middle.jobs.processes.fed == #[(shellCommand "/r" "tac", "c\na\n".toUTF8)] &&
              (showing middle).bind (·.text) == some "b\na\nc\n" &&
              echoOf middle == some "2 lines filtered" &&
              open'.jobs.processes.fed == #[(shellCommand "/r" "sort -u", "d\nb\nc\na\n".toUTF8)] &&
              (showing open').bind (·.text) == some "a\nb\nc\nd" },
    { name :=
        "`:!` with nothing after it says so and starts nothing; a `:!` whose job no one registered says the refusal and records nothing"
      run :=
        pure <|
          match shellDriver, workspaceDriver workspaceJobs shellKeys with
          | some driver, some unregistered =>
            let bare := shellRan driver "!"
            let opened := settledAfter unregistered "C-o a"
            let refused := shellRan opened "!make"
            echoOf bare == some Shell.noCommand && bare.next == driver.next &&
              echoOf refused == some (Shell.notStarted "!make" (.noSuchJob Shell.runJob)) &&
              refused.loop.state.workspaces.getOfProject Shell.historyStore
                  (.remote "github.com/o/r") ==
                #[]
          | _, _ => false },
    { name :=
        "what the echo area says of a run of one line or none, and what the output buffer holds of a longer one: a last carriage return and line feed is dropped, a signal is said, a byte that is not UTF-8 keeps its byte"
      run :=
        let ran (stdout stderr : ByteArray) (exit : Process.Exit := .code 0) : Process.Ran :=
          { exit, stdout, stderr }
        pure
          (Shell.echoText "!x" (ran "hi\r\n".toUTF8 .empty) == some "hi" &&
            Shell.echoText "!x" (ran .empty .empty (.signal 9)) ==
              some "!x: no output [killed by signal 9]" &&
            Shell.echoText "!x" (ran "a\nb".toUTF8 .empty) == none &&
            Shell.echoText "!x" (ran "a".toUTF8 "e".toUTF8) == none &&
            Shell.echoText "!x" (ran ⟨#[0x61, 0xFF]⟩ .empty) ==
              some ("a".push (File.escape 0xFF)) &&
            Shell.outputText (ran "a".toUTF8 "b\n".toUTF8 (.signal 15)) ==
              "a\nb\n[killed by signal 15]\n" &&
            Shell.outputText (ran ⟨#[0x61, 0xFF, 0x0A]⟩ .empty (.code 1)) ==
              ("a".push (File.escape 0xFF)) ++ "\n[exit 1]\n" &&
            Shell.outputText (ran .empty .empty) == "[exit 0]\n") },
    { name :=
        "a shell order crosses as arguments and back, with a scope's location of each kind and with none, with a filter's part and without, and arguments that are no order read as none; the run job started with them fails; each scope has its own job key"
      run :=
        let order : Shell.Order :=
          { line := "!make", text := "make", directory := "/r", time := 30000, buffer := ⟨2⟩
            view := ⟨0⟩ }
        let scopes : List (Option Location) :=
          [none, some (.local "/a b"), some (.reachable "kube" "pod" "/app"),
            some (.branchOnly "git@h:o/r" "x")]
        let filters : List (Option Shell.Filter) :=
          [none,
            some
              { start := 2, stop := 9, revision := 4, input := "a b\n", ended := false,
                lines := 2 }]
        pure
          (scopes.all
              (fun scope =>
                filters.all fun filter =>
                  Shell.Order.ofArguments?
                      { order with
                          scope, filter }.arguments ==
                    some
                      { order with
                        scope, filter }) &&
            [[], [.str "!make"], order.arguments ++ [.nat 1]].all
              (Shell.Order.ofArguments? · == none) &&
            ((Shell.runWork [.nat 1] ()).runModel {}).1 matches .failed _ &&
            Shell.keyOf (some (.local "/r")) == "shell local /r" &&
            Shell.keyOf none == "shell outside" &&
            Shell.keyOf (some (.local "/w")) != Shell.keyOf (some (.local "/r"))) }]

/-- The world of the compile checks: the workspace driver checks' world, and a
second clone of the same origin at `/clone/r`, on `main`. -/
def compileWorld : Workspace.World :=
  { workspaceWorld with
    repositories :=
      workspaceWorld.repositories.push
        { toplevel := "/clone/r", commonDir := "/clone/r/.git", origin := some workspaceOrigin }
    markerDirectories := workspaceWorld.markerDirectories.push "/clone/r/.git" }

/-- The jobs of the compile checks: the shell checks', the compile's run job
and its listing job. -/
def compileJobs (name : String) : Option (List Argument → Work) :=
  if name == Compile.runJob then some Compile.runWork
  else if name == Compile.listJob then some Compile.listWork else shellJobs name

/-- What `make` in `/r` does: writes `one`, pauses 100 ms, writes `two`,
pauses 100 ms and writes `three` on its standard error. -/
def makeSteps : Array Process.Step :=
  #[.write .out "one\n".toUTF8, .pause 100, .write .out "two\n".toUTF8, .pause 100,
    .write .err "three\n".toUTF8]

/-- Steps that write each of `lines` with a line feed on standard output,
pausing 100 ms between writes, so each is delivered, and posted, alone. -/
def linesSteps (lines : List String) : Array Process.Step :=
  (lines.toArray.map fun line => Process.Step.write .out (line ++ "\n").toUTF8).foldl
    (fun steps write => if steps.isEmpty then #[write] else steps ++ #[.pause 100, write]) #[]

/-- What `check` in `/r` writes: four locations of the general format, an
error with a column, a warning without, a note and an error whose path starts
`./`, with a help line after the first. -/
def checkLines : List String :=
  ["src/main.rs:12:5: error: expected one of", "  = help: add a semicolon",
    "src/lib.lean:3: warning: unused", "src/main.rs:2:7: note: defined here",
    "./src/b.lean:1:3: error: unknown identifier"]

/-- What `stream` in `/r` writes: a location, a help line, a location and a
plain line. -/
def streamLines : List String :=
  ["src/main.rs:12:5: error: expected one of", "  = help: add a semicolon",
    "src/lib.lean:3: warning: unused", "done"]

/-- The byte offset where the row `row` (from 1) of a compilation buffer
starts, whose header is `header` and whose rows after it are `lines`. -/
def rowStart (header : String) (lines : List String) (row : Nat) : Nat :=
  header.utf8ByteSize + 1 + ((lines.take (row - 1)).map (·.utf8ByteSize + 1)).sum

/-- The streaming children of the compile checks, `make` in `/r` exiting as
`exit`. -/
def compileStreams (exit : Process.Exit := .code 0) : Array Process.StreamScript :=
  #[{ command := shellCommand "/r" "make", steps := makeSteps, exit },
    { command := shellCommand "/w" "make"
      steps :=
        #[.write .out "w1\n".toUTF8, .pause 100, .write .out "w2\n".toUTF8, .pause 100,
          .write .out "w3\n".toUTF8] },
    { command := shellCommand "/w" "build", steps := #[.write .out "b1\n".toUTF8] },
    { command := shellCommand "/clone/r" "make", steps := #[.write .out "c1\n".toUTF8] },
    { command := shellCommand "/x" "make", steps := #[.write .out "x1\n".toUTF8] },
    { command := shellCommand "/r" "check", steps := linesSteps checkLines, exit := .code 1 },
    { command := shellCommand "/w" "check", steps := linesSteps ["src/main.rs:1:3: error: in w"] },
    { command := shellCommand "/x" "check", steps := linesSteps ["a.txt:1:1: error: here"] },
    { command := shellCommand "/r" "stream", steps := linesSteps streamLines },
    { command := shellCommand "/r" "gone",
      steps := linesSteps ["src/gone.rs:4:2: error: missing"] }]

/-- The place of the workspace `/r`. -/
def placeR : Compile.Place :=
  .workspace (.local "/r")

/-- The place of the workspace `/w`. -/
def placeW : Compile.Place :=
  .workspace (.local "/w")

/-- The bindings of the compile checks: the shell checks', and `C-k c`
(`compile`), `C-k m` (`compile` with `make`), `C-k r` (`recompile`), `C-k k`
(`kill-compilation`), `C-k t` (`insert-x`, which inserts `x` at the window's
cursors), `C-k 0` (`to-start`, which puts the window's cursor at offset 0),
`C-k o` (`focus-compilation`, which focuses the first view that shows a
compilation buffer), `C-k s` (`squat`, which makes a buffer
`*compilation: r@main (clone)*` the compile did not make), `C-k z` (a stale
`compilation-output` of `/r`'s first run), `C-k q`, which cancels the open
prompt, `C-o q`, which opens `/clone/r/src/a.lean`, and `C-k h` (`compile`
with `check`, asking nothing, so a new compilation buffer is in view 1,
below view 0). For stepping: `C-k n` (`next-error`), `C-k p`
(`previous-error`), `C-k e` (`compile-goto-error`), and `C-k g` and `C-k j`
(`to-point`, which puts the window's cursor at row 4, column 3, and at row
2, column 0), and `C-k b` (`zero-base`, which has every location `/r` keeps
count its columns from 0, as those of a format whose `columnBase` is 0
do). -/
def compileBindings : List (String × Invocation) :=
  shellBindings ++
    [("C-k c", invoke Compile.compileName),
      ("C-k m", { command := Compile.compileName, arguments := [.str "make"] }),
      ("C-k r", invoke "recompile"), ("C-k k", invoke Compile.killName),
      ("C-k t", invoke "insert-x"), ("C-k 0", invoke "to-start"),
      ("C-k o", invoke "focus-compilation"), ("C-k s", invoke "squat-clone"),
      ("C-k z",
        { command := Compile.outputName
          arguments := placeR.arguments ++ [.nat 1, .str "stale"] }),
      ("C-k q", invoke Minibuffer.cancelName), ("C-o q", opens "/clone/r/src/a.lean"),
      ("C-k h", { command := Compile.compileName, arguments := [.str "check"] }),
      ("C-k n", invoke Compile.nextName), ("C-k p", invoke Compile.previousName),
      ("C-k e", invoke Compile.gotoName),
      ("C-k g", { command := "to-point", arguments := [.nat 4, .nat 3] }),
      ("C-k j", { command := "to-point", arguments := [.nat 2, .nat 0] }),
      ("C-k b", invoke "zero-base")]

/-- The commands of the compile checks (`compileBindings`). -/
def compileCommands : List (String × Dispatched) :=
  let insertX : Dispatched := fun call => do
    call.target.insertAtSelections "x"
    return none
  let toStart : Dispatched := fun call => do
    discard <| call.target.window.id.select { ranges := #[⟨0, 0⟩] }
    return none
  let focusCompilation : Dispatched := fun _ => do
    let state ← editorState
    let shows (window : Window) : Bool :=
      (state.buffer? window.buffer).any (·.name.startsWith "*compilation")
    if let some window := state.windows.find? shows then
      discard <| window.id.focus
    return none
  let squat : Dispatched := fun _ => do
    discard <| createBuffer "*compilation: r@main (clone)*"
    return none
  let toPoint : Dispatched := fun call => do
    if let .nat row :: .nat column :: _ := call.arguments then
      let offset ← call.target.buffer.text.offsetOf ⟨row, column⟩
      discard <| call.target.window.id.select { ranges := #[⟨offset, offset⟩] }
    return none
  let zeroBase : Dispatched := fun _ => do
    let record := Compile.recordOf (← editorState) placeR
    Compile.setRecord placeR
        { record with locations := record.locations.map ({ · with columnBase := 0 }) }
    return none
  shellCommands ++ dispatchedOf Compile.commands ++
    [("insert-x", insertX), ("to-start", toStart), ("focus-compilation", focusCompilation),
      ("squat-clone", squat), ("to-point", toPoint), ("zero-base", zeroBase)]

/-- The keys of the compile checks over `bindings`, with the compile mode
and the ex names that ship registered: the active keymaps of a registry
holding the compile mode's modes, so the mode's roles are on their keys in
a compilation buffer as a host's registry puts them, then the keymap of
`bindings`. -/
def compileKeysOf (bindings : List (String × Invocation)) : Loop.Keys TestScheme.scheme :=
  let keys := dispatchKeys bindings compileCommands
  let registry := ({} : Config.Registry).replaceModes .compiled Compile.modes
  { keys with
    maps := fun state view =>
      registry.activeMaps TestScheme.scheme state view ++ keys.maps state view
    registered :=
      { keys.registered with
        entering := fun name => (Compile.modes.find? (·.name == name)).map ([·])
        ex := fun name => Ex.bindings.find? (·.name == name)
        exNames := Ex.bindings.map (·.name) } }

/-- The keys of the compile checks (`compileKeysOf`, `compileBindings`). -/
def compileKeys : Loop.Keys TestScheme.scheme :=
  compileKeysOf compileBindings

/-- The text of `/r/src/main.rs` in the compile checks: twelve lines, each
of ten characters, the second of two-byte ones, so a column counts
characters: row 11 starts at byte 131, and `12:5` is byte 135; `2:7` is
byte 23. -/
def mainText : String :=
  String.join ((List.range 12).map fun row => if row == 1 then "αβγδεζηθικ\n" else "abcdefghij\n")

/-- The files of the compile checks, each a path and a text. -/
def compileFiles : List (String × String) :=
  [("/r/src/a.lean", "a"), ("/w/src/b.lean", "w"), ("/x/a.txt", "x"), ("/clone/r/src/a.lean", "c"),
    ("/r/src/main.rs", mainText), ("/r/src/lib.lean", "one\ntwo\nthree\n"),
    ("/r/src/b.lean", "xyz123\n"), ("/w/src/main.rs", "wwwwww\n")]

/-- A driver of the compile checks: the world of `compileWorld`, with the
compile checks' keys and jobs, the files the keys open, and the children of
`compileStreams`, `make` in `/r` exiting as `exit`; `none` if making the
state was refused. -/
def compileDriver (exit : Process.Exit := .code 0)
    (registered : String → Option (List Argument → Work) := compileJobs) : Option TestDriver :=
  let model := compileWorld.jobModel "git" #["/r/src", "/w/src", "/x", "/clone/r/src"]
  let files :=
    compileFiles.foldl (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8)
      model.files
  (Loop.Driver.over compileKeys registered (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver =>
    { driver with
      jobs :=
        { model with
          files, processes := { model.processes with streams := compileStreams exit } } }

/-- The text of the buffer called `name` in `driver`. -/
def compiledText (driver : TestDriver) (name : String) : Option String :=
  namedText driver name

/-- `driver` with its editor clock, which commands read, at `milliseconds`. -/
def withClock (driver : TestDriver) (milliseconds : Nat) : TestDriver :=
  { driver with
    model := { driver.model with watch := { driver.model.watch with clock := milliseconds } } }

/-- `driver` once the oldest post held is delivered. -/
def postedNext (driver : TestDriver) : TestDriver :=
  match driver.posting[0]? with
  | some job => (driver.posted job.id).1
  | none => driver

/-- `driver` once the post held of the job of `key` is delivered. -/
def postedOf (driver : TestDriver) (key : String) : TestDriver :=
  match driver.posting.find? (·.key == some key) with
  | some job => (driver.posted job.id).1
  | none => driver

/-- `driver` once every post is delivered and every pending job finished,
oldest first, a post before a job's end; bounded. -/
def drained (driver : TestDriver) : TestDriver :=
  (List.range 64).foldl
    (fun driver _ =>
      match driver.posting[0]? with
      | some job => (driver.posted job.id).1
      | none =>
        match driver.pending[0]? with
        | some job => (driver.finish job.id).1
        | none => driver)
    driver

/-- `driver` once `compile` is asked, `line` typed in its prompt and the
prompt accepted. -/
def compiledLine (driver : TestDriver) (line : String) : TestDriver :=
  (fedTo driver (presses "C-k c" ++ [.commit line] ++ presses "C-e y")).1

/-- `driver` once `keys` are pressedOn, with nothing settled. -/
def pressedOn (driver : TestDriver) (keys : String) : TestDriver :=
  (fedTo driver (presses keys)).1

/-- The buffer called `name` in `driver`. -/
def compileBuffer (driver : TestDriver) (name : String) : Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer name)

/-- `driver` with the streaming children of `streams` scripted besides its
own. -/
def withStreams (driver : TestDriver) (streams : Array Process.StreamScript) : TestDriver :=
  { driver with
    jobs :=
      { driver.jobs with
        processes :=
          { driver.jobs.processes with streams := streams ++ driver.jobs.processes.streams } } }

/-- The last line of the buffer `*compilation: r@main*` in `driver`. -/
def compiledLastLine (driver : TestDriver) : Option String :=
  ((compiledText driver "*compilation: r@main*").map fun text =>
      ((text.splitOn "\n").filter (!·.isEmpty)).getLast?).join

/-- The compile checks (`Editor/Compile.lean`), on the loop's driver over the
editor's models, the job model and the process model, in the world of
`compileWorld`. -/
def compileChecks : List Check :=
  [{  name :=
        "criterion 1: compile with make in a buffer of /r starts /bin/sh -c make streaming in /r, and *compilation: r@main* holds the header and then each line as it is delivered, before the child ends"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let asked := compiledLine opened "make"
            let first := postedNext asked
            let second := postedNext first
            let done := drained (withClock second 1500)
            let name := "*compilation: r@main*"
            let state := done.loop.state
            asked.jobs.processes.started.back? == some (shellCommand "/r" "make") &&
              asked.posting.map (·.key) == #[some "compile local /r"] &&
              compiledText asked name == some "r@main in /r: make\n" &&
              compiledText first name == some "r@main in /r: make\none\n" &&
              (Compile.recordOf first.loop.state placeR).running.isSome &&
              compiledText second name == some "r@main in /r: make\none\ntwo\n" &&
              second.pending.size == 1 &&
              compiledText done name ==
                some "r@main in /r: make\none\ntwo\nthree\nCompilation finished after 1.5 s\n" &&
              (Compile.recordOf state placeR).running.isNone &&
              (compileBuffer done name).map (·.readOnly) == some true &&
              (compileBuffer done name).bind (·.major) == some Compile.modeName &&
              (state.findBuffer name).bind (fun id => (state.workspaceOf? id).map (·.1.location)) ==
                some (.local "/r") &&
              -- A new window at the end of the tiled list shows it: view 2,
              -- since the prompt's minibuffer had view 1.
              (state.findBuffer name).map (Compile.viewsOf state) == some #[⟨2⟩] &&
              state.frame.windows == #[⟨0⟩, ⟨2⟩] &&
              (showing done).map (·.buffer.name) == some "a.lean" &&
              state.frame.focused == ⟨0⟩ },
    { name :=
        "with no display rule that matches, the compilation buffer opens in a new window at the end of the tiled list, not beside the asking window, and the focus stays in the window compile was asked from; a recompile while a window shows it reuses that window"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            -- Views 0 and 1, view 0 focused.
            let split := settledAfter (settledAfter driver "C-o a") "C-e s"
            let back :=
              { split with
                loop :=
                  { split.loop with
                    state :=
                      { split.loop.state with
                        frame := { split.loop.state.frame with focused := ⟨0⟩ } } } }
            let ran := drained (pressedOn back "C-k m")
            let again := drained (pressedOn ran "C-k r")
            let name := "*compilation: r@main*"
            let state := ran.loop.state
            split.loop.state.frame.windows == #[⟨0⟩, ⟨1⟩] &&
              state.frame.windows == #[⟨0⟩, ⟨1⟩, ⟨2⟩] &&
              (showing ran ⟨2⟩).map (·.buffer.name) == some name &&
              state.frame.focused == ⟨0⟩ &&
              again.loop.state.frame.windows == state.frame.windows &&
              again.loop.state.frame.focused == ⟨0⟩ &&
              (showing again ⟨2⟩).map (·.buffer.name) == some name },
    { name :=
        "the compilation buffer has its mode before it is displayed, so a display rule for the compilation mode places it: one with the focused target shows it in the window compile was asked from"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ruled :=
              withDisplayRules driver
                #[{ mode := some Compile.modeName, target := .focused, focus := false }]
            let ran := drained (pressedOn (settledAfter ruled "C-o a") "C-k m")
            let name := "*compilation: r@main*"
            ran.loop.state.frame.windows == #[⟨0⟩] &&
              (showing ran).map (·.buffer.name) == some name &&
              (showing ran).bind (·.buffer.major) == some Compile.modeName },
    { name :=
        "a display rule that matches the compilation buffer keeps its own focus: one for compile that sends it to the stack, focused by default, focuses its new window"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ruled :=
              withDisplayRules driver #[{ opener := some Compile.compileName, target := .stack }]
            let ran := drained (pressedOn (settledAfter ruled "C-o a") "C-k m")
            let state := ran.loop.state
            state.frame.windows.size == 2 && state.frame.focused != ⟨0⟩ &&
              (showingFocused ran).map (·.buffer.name) == some "*compilation: r@main*" },
    { name :=
        "criterion 2: compiles in /r and /w run at once into two buffers, each holding only its own output, and kill-compilation in one leaves the other running"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let inR := pressedOn (settledAfter driver "C-o a") "C-k m"
            let both := pressedOn (settledAfter inR "C-o w") "C-k m"
            let mixed := postedOf (postedOf both "compile local /w") "compile local /r"
            -- `a.lean` is open: it is shown at once, and no job runs.
            let killed := pressedOn mixed "C-o a C-k k"
            let rest := drained killed
            both.posting.map (·.key) == #[some "compile local /r", some "compile local /w"] &&
              compiledText mixed "*compilation: r@main*" == some "r@main in /r: make\none\n" &&
              compiledText mixed "*compilation: r@feature*" == some "r@feature in /w: make\nw1\n" &&
              killed.posting.map (·.key) == #[some "compile local /w"] &&
              killed.jobs.processes.killed == #[shellCommand "/r" "make"] &&
              compiledText killed "*compilation: r@main*" ==
                some "r@main in /r: make\none\nCompilation killed after 0.0 s\n" &&
              compiledText rest "*compilation: r@feature*" ==
                some "r@feature in /w: make\nw1\nw2\nw3\nCompilation finished after 0.0 s\n" &&
              compiledText rest "*compilation: r@main*" ==
                compiledText killed "*compilation: r@main*" },
    { name :=
        "criterion 4: compile in a buffer of a workspace that cannot run commands starts no process, opens no prompt and says why"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let kube := settledAfter (settledAfter driver "C-o a") "C-e k"
            let asked := pressedOn kube "C-k c"
            let given := pressedOn kube "C-k m"
            let again := pressedOn kube "C-k r"
            asked.loop.state.prompt.isNone && asked.next == kube.next &&
              asked.jobs.processes.started == kube.jobs.processes.started &&
              echoOf asked ==
                some
                  "compile: r@app is reachable through kube pod at /app, where commands cannot run" &&
              given.next == kube.next &&
              echoOf given == echoOf asked &&
              again.loop.state.prompt.isNone &&
              again.next == kube.next &&
              echoOf again ==
                some
                  "recompile: r@app is reachable through kube pod at /app, where commands cannot run" },
    { name :=
        "criterion 3: a line compiled in /r is offered in /w's compile prompt history, while each recompile reruns its own workspace's last line"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let inR := drained (compiledLine (settledAfter driver "C-o a") "make")
            let asked := pressedOn (settledAfter inR "C-o w") "C-k c"
            let cancelled := pressedOn asked "C-k q"
            let inW := drained (compiledLine cancelled "build")
            let again :=
              drained (pressedOn (pressedOn (pressedOn inW "C-o a") "C-k r") "C-o w C-k r")
            let started := again.jobs.processes.started
            (candidatesOf asked).map (·.all) == some #["make"] &&
              (showing asked asked.loop.state.frame.focused).bind (·.text) == some "" &&
              cancelled.loop.state.prompt.isNone &&
              inW.jobs.processes.started.back? == some (shellCommand "/w" "build") &&
              started.extract (started.size - 2) started.size ==
                #[shellCommand "/r" "make", shellCommand "/w" "build"] &&
              inW.loop.state.workspaces.getOfProject Compile.historyStore
                  (.remote "github.com/o/r") ==
                #["build", "make"] },
    { name :=
        "criterion 6: recompile reruns the workspace's last line in its directory without a prompt, and another workspace's recompile runs its own last line; in the compilation buffer it reruns that buffer's"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let inR := drained (pressedOn (settledAfter driver "C-o a") "C-k m")
            let both := drained (pressedOn (settledAfter inR "C-o w") "C-k m")
            let inW := pressedOn both "C-k r"
            let inRAgain := pressedOn (drained inW) "C-o a C-k r"
            let fromBuffer := pressedOn (drained inRAgain) "C-k o C-k r"
            inW.loop.state.prompt.isNone &&
              inW.jobs.processes.started.back? == some (shellCommand "/w" "make") &&
              inRAgain.loop.state.prompt.isNone &&
              inRAgain.jobs.processes.started.back? == some (shellCommand "/r" "make") &&
              (showing fromBuffer fromBuffer.loop.state.frame.focused).map (·.buffer.name) ==
                some "*compilation: r@main*" &&
              fromBuffer.loop.state.prompt.isNone &&
              fromBuffer.jobs.processes.started.size == inRAgain.jobs.processes.started.size + 1 &&
              fromBuffer.jobs.processes.started.back? == some (shellCommand "/r" "make") &&
              echoOf (pressedOn (settledAfter driver "C-o a") "C-k r") ==
                some "recompile: nothing has been compiled in r@main" },
    { name :=
        "criterion 7: compile while the workspace's own one runs asks; yes kills the old child and empties the buffer, no leaves both alone"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let running := postedNext (pressedOn (settledAfter driver "C-o a") "C-k m")
            let asked := pressedOn running "C-k m"
            let refused := (fedTo asked ([.commit "n"] ++ presses "C-e y")).1
            let confirmed :=
              (fedTo (pressedOn refused "C-k m") ([.commit " Yes "] ++ presses "C-e y")).1
            let makes (driver : TestDriver) :=
              (driver.jobs.processes.started.filter (· == shellCommand "/r" "make")).size
            let name := "*compilation: r@main*"
            asked.loop.state.prompt.map (·.label) ==
                some "Kill the compilation running in r@main? (y or n) " &&
              refused.posting.map (·.id) == running.posting.map (·.id) &&
              compiledText refused name == compiledText running name &&
              makes refused == 1 &&
              echoOf refused == some "compile: left the compilation running in r@main" &&
              confirmed.jobs.processes.killed == #[shellCommand "/r" "make"] &&
              compiledText confirmed name == some "r@main in /r: make\n" &&
              makes confirmed == 2 &&
              confirmed.posting.map (·.key) == #[some "compile local /r"] &&
              confirmed.posting.map (·.id) != running.posting.map (·.id) },
    { name :=
        "criterion 5: the last line reads finished for exit 0, exited abnormally with code 2 for exit 2 and killed after kill-compilation, and the echo area says the same with r@main"
      run :=
        pure <|
          match compileDriver, compileDriver (.code 2) with
          | some driver, some failing =>
            let run (driver : TestDriver) :=
              drained (withClock (pressedOn (settledAfter driver "C-o a") "C-k m") 1500)
            let lastLineOf (driver : TestDriver) :=
              ((compiledText driver "*compilation: r@main*").map fun text =>
                  ((text.splitOn "\n").filter (!·.isEmpty)).getLast?).join
            let finished := run driver
            let failed := run failing
            let killed :=
              pressedOn
                (withClock (postedNext (pressedOn (settledAfter driver "C-o a") "C-k m")) 1500)
                "C-k k"
            lastLineOf finished == some "Compilation finished after 1.5 s" &&
              echoOf finished == some "r@main: Compilation finished after 1.5 s" &&
              lastLineOf failed == some "Compilation exited abnormally with code 2 after 1.5 s" &&
              echoOf failed ==
                some "r@main: Compilation exited abnormally with code 2 after 1.5 s" &&
              lastLineOf killed == some "Compilation killed after 1.5 s" &&
              echoOf killed == some "r@main: Compilation killed after 1.5 s"
          | _, _ => false },
    { name :=
        "the last line reads killed by signal 9 for a child a signal ended, stopped with the stream named for a line of standard output or of standard error longer than the bound, and could not start with the refusal for a child that cannot be started; the echo area says the same with r@main"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let long := ByteArray.mk (Array.replicate (Compile.lineBound + 1) 97)
            let scripted :=
              withStreams (settledAfter driver "C-o a")
                #[{ command := shellCommand "/r" "signalled"
                    steps := #[.write .out "one\n".toUTF8]
                    exit := .signal 9 },
                  { command := shellCommand "/r" "long-out", steps := #[.write .out long] },
                  { command := shellCommand "/r" "long-err", steps := #[.write .err long] }]
            let run (line : String) := drained (compiledLine scripted line)
            -- The process model's own words for a command it has no script
            -- for: the compile says them, whatever they are.
            let refusal : Option String :=
              match
                (ProcessModel.handle {} 0 none
                    (.start (shellCommand "/r" "absent") { bound := Compile.lineBound })).1 with
              | .error error => some error.describe
              | .ok _ => none
            let says (driver : TestDriver) (text : String) :=
              compiledLastLine driver == some text && echoOf driver == some s!"r@main: {text}"
            says (run "signalled") "Compilation killed by signal 9 after 0.0 s" &&
              says (run "long-out")
                s!"Compilation stopped: a line of standard output was longer than {Compile.lineBound} bytes after 0.0 s" &&
              says (run "long-err")
                s!"Compilation stopped: a line of standard error was longer than {Compile.lineBound} bytes after 0.0 s" &&
              refusal.any fun detail =>
                says (run "absent") s!"Compilation could not start: {detail} after 0.0 s" &&
                  (run "absent").jobs.processes.started == scripted.jobs.processes.started },
    { name :=
        "a line a child ends with a carriage return before its line feed is shown without it, on standard output and on standard error, and only one carriage return is dropped"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let scripted :=
              withStreams (settledAfter driver "C-o a")
                #[{ command := shellCommand "/r" "crlf"
                    steps := #[.write .out "a\r\nb\r\r\n".toUTF8, .write .err "e\r\n".toUTF8] }]
            compiledText (drained (compiledLine scripted "crlf")) "*compilation: r@main*" ==
              some "r@main in /r: crlf\na\nb\r\ne\nCompilation finished after 0.0 s\n" },
    { name :=
        "a child whose read of its streams failed ends the run as stopped with the failure's words, and a delivery of bytes gives no lines"
      run :=
        pure
          (Compile.How.ofEnd (.failed "the pipe broke") == .stopped "the pipe broke" &&
            Compile.lastLine (Compile.How.ofEnd (.failed "the pipe broke")) 1500 ==
              "Compilation stopped: the pipe broke after 1.5 s" &&
            Compile.linesOf (.bytes "a\r\n".toUTF8) == #[]) },
    -- Ordered as the plan review asked (review 2026-11-16-2327-c551): a
    -- first post makes the text `header\none\n` with both views following;
    -- only then is one view's cursor moved up, to a row before the last
    -- line, and the next post shows the other following from the old last
    -- line and the moved one left where it was.
    { name :=
        "criterion 8: a view of the compilation buffer with its cursor on the last line follows appended output, and one whose cursor was moved up does not"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let asked := pressedOn (settledAfter driver "C-o a") "C-k m"
            -- View 1 shows the compilation buffer; a split of it, view 2,
            -- shows it too and is focused.
            let twoViews := pressedOn asked "C-k o C-e s"
            let first := postedNext twoViews
            let moved := pressedOn first "C-k 0"
            let second := postedNext moved
            let name := "*compilation: r@main*"
            let header := "r@main in /r: make\n"
            let heads (driver : TestDriver) (view : ViewId) :=
              ((showing driver view).bind (·.cursors)).map (·.map (·.head))
            (showing twoViews ⟨1⟩).map (·.buffer.name) == some name &&
              (showing twoViews ⟨2⟩).map (·.buffer.name) == some name &&
              twoViews.loop.state.frame.focused == ⟨2⟩ &&
              compiledText first name == some (header ++ "one\n") &&
              heads first ⟨1⟩ == some #[header.utf8ByteSize] &&
              heads first ⟨2⟩ == some #[header.utf8ByteSize] &&
              heads moved ⟨2⟩ == some #[0] &&
              compiledText second name == some (header ++ "one\ntwo\n") &&
              heads second ⟨1⟩ == some #[header.utf8ByteSize + 4] &&
              heads second ⟨2⟩ == some #[0] },
    { name :=
        "a restart puts every view's cursor of the kept compilation buffer on the header line, so each follows the new run"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k m")
            let moved := pressedOn ran "C-k o C-e s C-k 0"
            let again := postedNext (pressedOn moved "C-k r")
            let header := "r@main in /r: make\n"
            let heads (driver : TestDriver) (view : ViewId) :=
              ((showing driver view).bind (·.cursors)).map (·.map (·.head))
            compiledText again "*compilation: r@main*" == some (header ++ "one\n") &&
              heads again ⟨1⟩ == some #[header.utf8ByteSize] &&
              heads again ⟨2⟩ == some #[header.utf8ByteSize] },
    { name :=
        "criterion 9: editing commands in a compilation buffer are refused as for a read-only buffer, and a committed text is dropped"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k m")
            let focused := pressedOn ran "C-k o"
            let inserted := pressedOn focused "C-k t"
            let undone := pressedOn focused "C-e u"
            let committed := (fedTo focused [.commit "z"]).1
            let name := "*compilation: r@main*"
            let text := compiledText ran name
            (showing focused focused.loop.state.frame.focused).map (·.buffer.name) == some name &&
              text.isSome &&
              compiledText inserted name == text &&
              echoOf inserted == some s!"insert-x: {name} is read-only" &&
              compiledText undone name == text &&
              echoOf undone == some s!"undo: {name} is read-only" &&
              compiledText committed name == text &&
              echoOf committed == some s!"{name} is read-only" },
    { name :=
        "criterion 10: two workspaces whose labels match get two compilation buffers with distinct names, and each compile writes to its own; a buffer that holds the second name gives a third"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let inR := drained (pressedOn (settledAfter driver "C-o a") "C-k m")
            let inClone := drained (pressedOn (settledAfter inR "C-o q") "C-k m")
            let squatted := pressedOn (settledAfter inR "C-o q") "C-k s"
            let pushed := drained (pressedOn squatted "C-k m")
            compiledText inClone "*compilation: r@main*" ==
                some "r@main in /r: make\none\ntwo\nthree\nCompilation finished after 0.0 s\n" &&
              compiledText inClone "*compilation: r@main (clone)*" ==
                some "r@main in /clone/r: make\nc1\nCompilation finished after 0.0 s\n" &&
              compiledText pushed "*compilation: r@main (clone)*<2>" ==
                some "r@main in /clone/r: make\nc1\nCompilation finished after 0.0 s\n" &&
              compiledText pushed "*compilation: r@main (clone)*" == some "" },
    { name :=
        "a directory-scope compile in /x/a.txt runs in /x into *compilation: x*, which keeps its directory"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o x") "C-k m")
            let state := ran.loop.state
            ran.jobs.processes.started.back? == some (shellCommand "/x" "make") &&
              compiledText ran "*compilation: x*" ==
                some "x in /x: make\nx1\nCompilation finished after 0.0 s\n" &&
              (state.findBuffer "*compilation: x*").bind (state.value? · Compile.directoryLocal) ==
                some (.str "/x") &&
              (Compile.recordOf state (.directory "/x")).last == some ("make", "/x") },
    { name :=
        "an empty answer to compile's prompt says compile: no command and starts nothing; with no compile-run registered the start is refused and said"
      run :=
        pure <|
          match compileDriver, compileDriver (registered := shellJobs) with
          | some driver, some unregistered =>
            let opened := settledAfter driver "C-o a"
            let empty := (fedTo opened (presses "C-k c C-e y")).1
            let refused := pressedOn (settledAfter unregistered "C-o a") "C-k m"
            (pressedOn opened "C-k c").loop.state.prompt.isSome &&
              echoOf empty == some Compile.noCommand &&
              empty.next == opened.next &&
              echoOf refused ==
                some (Compile.notStarted Compile.compileName (.noSuchJob Compile.runJob)) &&
              (refused.loop.state.findBuffer "*compilation: r@main*").isNone
          | _, _ => false },
    { name :=
        "a closed compilation buffer gets a new one on the next compile; a stale run's output changes nothing"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let first := drained (pressedOn (settledAfter driver "C-o a") "C-k m")
            let closed := pressedOn (pressedOn first "C-k o") "C-e x"
            let again := drained (pressedOn (settledAfter closed "C-o a") "C-k m")
            let stale := pressedOn again "C-k z"
            let name := "*compilation: r@main*"
            match first.loop.state.findBuffer name, again.loop.state.findBuffer name with
            | some old, some made =>
              (closed.loop.state.buffer? old).isNone && made != old &&
                compiledText again name ==
                  some "r@main in /r: make\none\ntwo\nthree\nCompilation finished after 0.0 s\n" &&
                (Compile.recordOf again.loop.state placeR).buffer == some made.index &&
                (Compile.recordOf again.loop.state placeR).runs == 2 &&
                compiledText stale name == compiledText again name
            | _, _ => false },
    { name :=
        "the ex line runs the compile commands: `:compile make` compiles make, `:compile` alone asks for the line, `:kill-compilation` kills the run and `:recompile` reruns it"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o a"
            let made := (fedTo opened (exLine "compile make")).1
            let killed := (fedTo made (exLine "kill-compilation")).1
            let again := (fedTo (drained killed) (exLine "recompile")).1
            let asked := (fedTo opened (exLine "compile")).1
            made.jobs.processes.started.back? == some (shellCommand "/r" "make") &&
              made.posting.map (·.key) == #[some "compile local /r"] &&
              killed.posting.isEmpty &&
              killed.jobs.processes.killed == #[shellCommand "/r" "make"] &&
              again.posting.map (·.key) == #[some "compile local /r"] &&
              again.jobs.processes.started.size == made.jobs.processes.started.size + 1 &&
              asked.loop.state.prompt.map (·.label) == some Compile.promptLabel },
    { name :=
        "the compilation mode fills the role refresh with recompile and activate with compile-goto-error, and neither next-item nor previous-item, so j and k stay motions under Vim"
      run :=
        pure
          (Compile.mode.roles.map (fun (role, command) => (role.name, command)) ==
              [(Role.refresh.name, Compile.recompileName),
                (Role.activate.name, Compile.gotoName)] &&
            Compile.mode.name == Compile.modeName) },
    { name :=
        "a compile order crosses as arguments and back with a place of each kind, arguments that are no order read as none, and the run job started with them fails; each place has its own job key"
      run :=
        let places : List Compile.Place :=
          [.workspace (.local "/a b"), .workspace (.reachable "kube" "pod" "/app"),
            .workspace (.branchOnly "git@h:o/r" "x"), .directory "/x"]
        pure
          (places.all
                        (fun place =>
                          let order : Compile.Order :=
                            { line := "make -j", directory := "/r", place, run := 3 }
                          Compile.Order.ofArguments? order.arguments == some order) &&
                      [[], [.str "make"], [.str "make", .str "/r", .nat 1, .str "directory"]].all
                        (Compile.Order.ofArguments? · == none) &&
                    ((Compile.runWork [.nat 1] ()).runModel {}).1 matches .failed _ &&
                  placeR.jobKey == "compile local /r" &&
                (Compile.Place.directory "/x").jobKey == "compile directory /x" &&
              Compile.elapsed 1500 == "1.5 s" &&
            Compile.elapsed 61049 == "61.0 s") }]

/-- The format `general` with a continuation: a following line that starts
with blanks continues a location. -/
def indentedFormat : Compile.Format :=
  { Compile.Format.general with
    name := "indented"
    continuation := some [{ pieces := [{ atom := .blanks }] }, { pieces := [{ atom := .rest }] }] }

/-- The format `t-lead` of the lead checks: a location line `  at
<file>:<line>`, maybe followed by ` note`, its severity, after a lead line
`<error|warning>: <message>` that gives its severity and message. -/
def leadFormat : Compile.Format :=
  { name := "t-lead"
    pattern :=
      [Compile.step
          [{ atom := .blanks }, { atom := .literal "at " },
            { atom := .noneOf [':', ' '], into := some .file }, { atom := .literal ":" },
            { atom := .digits, into := some .line }],
        Compile.optionalStep
          [{ atom := .literal " " }, { atom := .oneOf ["note"], into := some .severity }]]
    lead :=
      some
        [Compile.step
            [{ atom := .oneOf ["error", "warning"], into := some .severity },
              { atom := .literal ": " }, { atom := .rest, into := some .message }]] }

/-- The checks of error formats, the matcher, sites and `resolve`
(`Editor/Compile/Errors.lean`): pure, with no driver. -/
def compileErrorChecks : List Check :=
  let general := Compile.Format.general
  [{  name :=
        "a format with a lead makes the line before a location its site's first row, with the lead's severity and message; in one scan, across two with the previous line handed in, and with no lead before it a plain site"
      run :=
        let lines := #["warning: unused x", "  at a.rs:4"]
        let one := Compile.scan #[leadFormat] "/r" #[] 1 100 lines
        let two :=
          Compile.scan #[leadFormat] "/r" (Compile.scan #[leadFormat] "/r" #[] 1 100 #[lines[0]!]) 2
            118 #[lines[1]!] (previous := some lines[0]!)
        let bare := Compile.scan #[leadFormat] "/r" #[] 1 100 #["plain", "  at a.rs:4"]
        pure
          (one ==
              #[{ file := "/r/a.rs", line := 4, column := none, columnBase := 1
                  severity := .warning, format := "t-lead", first := 1, last := 2, start := 123
                  stop := 129, message := some "unused x" }] &&
            two == one &&
            bare.map (fun site => (site.first, site.last, site.severity, site.message)) ==
              #[(2, 2, .error, none)]) },
    { name :=
        "a lead whose row the last site covers is not joined to the next location, and a lead's severity yields to one the location line captured"
      run :=
        let earlier : Compile.Site :=
          { file := "/r/b.rs", line := 1, column := none, columnBase := 1, severity := .error
            format := "general", first := 1, last := 1, start := 0, stop := 6 }
        let covered :=
          Compile.scan #[leadFormat] "/r" #[earlier] 2 9 #["  at a.rs:4"] (previous :=
            some "error: e")
        let captured := Compile.scan #[leadFormat] "/r" #[] 1 0 #["error: e", "  at a.rs:4 note"]
        pure
          (covered.map
                (fun site => (site.format, site.first, site.last, site.severity, site.message)) ==
              #[("general", 1, 1, .error, none), ("t-lead", 2, 2, .error, none)] &&
            captured.map (fun site => (site.first, site.severity, site.message)) ==
              #[(1, .note, some "e")]) },
    { name :=
        "a site with a message crosses as a tree and back, and a site's tree with no message field, written before messages were kept, reads with none"
      run :=
        let site : Compile.Site :=
          { file := "/r/a.rs", line := 4, column := some 2, columnBase := 1, severity := .error
            format := "t-lead", first := 3, last := 5, start := 40, stop := 48
            message := some "mismatched types" }
        let older :=
          match ({ site with message := none } : Compile.Site).encode with
          | .record fields => Value.record (fields.filter (·.1 != "message"))
          | other => other
        pure
          (Compile.Site.decode site.encode == some site &&
            Compile.Site.decode older == some { site with message := none }) },
    { name :=
        "locations criterion 1: the general format reads src/main.rs:12:5: error: expected one of as src/main.rs, line 12, column 5, an error, and lib.lean:3: warning: unused with no column"
      run :=
        pure
          (general.read? "src/main.rs:12:5: error: expected one of" ==
              some
                { file := "src/main.rs", line := 12, column := some 5, severity := .error
                  start := 0, stop := 16 } &&
            general.read? "lib.lean:3: warning: unused" ==
              some
                { file := "lib.lean", line := 3, column := none, severity := .warning, start := 0
                  stop := 10 }) },
    { name :=
        "the general format reads a note as a note and a line with no severity word as an error, and the header, a help line, the last line and an empty line as no location"
      run :=
        pure
          ((general.read? "note.txt:7: note: here").map (·.severity) == some .note &&
            (general.read? "a.c:3: something").map (·.severity) == some .error &&
            ["r@main in /r: make", "  = help: add a semicolon", "Compilation finished after 1.5 s",
                  ""].all
              (general.read? · == none)) },
    { name :=
        "a location's start and stop are byte offsets: αβ.rs:3:4: error: x reads its location text as bytes 0 to 11, the bytes of its nine characters"
      run :=
        pure
          (general.read? "αβ.rs:3:4: error: x" ==
            some
              { file := "αβ.rs", line := 3, column := some 4, severity := .error, start := 0
                stop := 11 }) },
    { name :=
        "scan steps each line on by its bytes: after a line of two-byte characters the next location starts and stops at its bytes, and a location in a line of them stops at its bytes"
      run :=
        let lines := #["größe wär", "a.rs:1:2: error: x", "αβ.rs:3: warning: y"]
        pure
          ((Compile.scan #[Compile.Format.general] "/r" #[] 1 100 lines).map
              (fun site => (site.file.toString, site.first, site.start, site.stop)) ==
            #[("/r/a.rs", 2, 113, 121), ("/r/αβ.rs", 3, 132, 141)]) },
    { name :=
        "locations criterion 2: a format with a continuation joins a location line and its following indented line into one location, in one scan or across two; with the general format they stay apart, and a line that matches nothing stops the join"
      run :=
        let lines := #["a.rs:1:2: error: x", "    more", "b.rs:3: warning: y"]
        let joined := Compile.scan #[indentedFormat] "/r" #[] 1 100 lines
        let inTwo :=
          Compile.scan #[indentedFormat] "/r"
            (Compile.scan #[indentedFormat] "/r" #[] 1 100 #["a.rs:1:2: error: x"]) 2 119
            #["    more", "b.rs:3: warning: y"]
        let apart := Compile.scan #[general] "/r" #[] 1 100 lines
        let stopped :=
          Compile.scan #[indentedFormat] "/r" #[] 1 100 #["a.rs:1:2: error: x", "plain", "    more"]
        pure
          (joined ==
              #[{ file := "/r/a.rs", line := 1, column := some 2, columnBase := 1
                  severity := .error, format := "indented", first := 1, last := 2, start := 100
                  stop := 108 },
                { file := "/r/b.rs", line := 3, column := none, columnBase := 1
                  severity := .warning, format := "indented", first := 3, last := 3
                  start := 128, stop := 134 }] &&
            inTwo == joined &&
            apart.map (fun site => (site.first, site.last)) == #[(1, 1), (3, 3)] &&
            stopped.map (fun site => (site.first, site.last)) == #[(1, 1)]) },
    { name :=
        "locations criterion 6: a relative file resolves against the directory, with . and .. taken lexically, and an absolute one is kept"
      run :=
        pure
          (Compile.resolve "/r" "src/main.rs" == "/r/src/main.rs" &&
            Compile.resolve "/r" "./src/b.lean" == "/r/src/b.lean" &&
            Compile.resolve "/r" "../w/src/b.lean" == "/w/src/b.lean" &&
            Compile.resolve "/r/sub" "../src/a.lean" == "/r/src/a.lean" &&
            Compile.resolve "/r" "/abs/x.rs" == "/abs/x.rs") },
    { name := "a site crosses as a tree and back, with a column and without"
      run :=
        let site : Compile.Site :=
          { file := "/r/a.rs", line := 4, column := some 2, columnBase := 0, severity := .note
            format := "general", first := 3, last := 5, start := 40, stop := 48 }
        pure
          (Compile.Site.decode site.encode == some site &&
            Compile.Site.decode { site with column := none }.encode ==
              some { site with column := none } &&
            Compile.Site.decode (.str "a.rs") == none) },
    { name :=
        "a scope's record crosses as a tree and back with its locations and its current one, and a tree of the record's old shape, with neither, is none"
      run :=
        let site : Compile.Site :=
          { file := "/r/a.rs", line := 4, column := some 2, columnBase := 1, severity := .error
            format := "general", first := 1, last := 1, start := 20, stop := 28 }
        let record : Compile.Record :=
          { buffer := some 2, last := some ("make", "/r"), runs := 3
            locations :=
              #[site,
                { site with
                  first := 2, last := 2 }],
            current := some 1 }
        pure
          (Compile.Record.decode record.encode == some record &&
            Compile.Record.decode
                { record with
                    current := none, locations := #[] }.encode ==
              some
                { record with
                  current := none, locations := #[] } &&
            Compile.Record.decode
                (.record
                  [("buffer", .null), ("last", .null), ("runs", .nat 0), ("running", .null)]) ==
              none &&
            Compile.store.version == 3 &&
            Compile.directoryStore.version == 3) }]

/-- The decorations of the view `view` in the last scene `driver`
published. -/
def sceneDecorations (driver : TestDriver) (view : ViewId) : Option (Array Decoration) :=
  driver.model.display.scenes.back?.bind fun scene =>
    (scene.views.find? (·.id == view)).map (·.decorations)

/-- The editor's models, with the editor state answering the state requests
and changed by them, and, when `refuseSplits`, every split refused with
`noSuchWindow` and nothing changed: a fake written for the one check of a
visit whose split is refused, which no state refuses for a view that shows
a compilation buffer. -/
def splitsRefusedIf (refuseSplits : Bool) :
    (request : EditorRequest) →
      EditorState × EditorModel → request.Reply × (EditorState × EditorModel)
  | .state (.split view axis scroll selection), (state, model) =>
    if refuseSplits then (.error (.noSuchWindow view), (state, model))
    else
      let (reply, state) := state.handle (.split view axis scroll selection)
      (reply, (state, model))
  | .state request, (state, model) =>
    let (reply, state) := state.handle request
    (reply, (state, model))
  | request, (state, model) =>
    let (reply, model) := EditorModel.handle request model
    (reply, (state, model))

/-- The checks of the locations the compile mode finds in its output
(`Editor/Compile.lean`, "Locations"), on the loop's driver over the
editor's models, the job model and the process model, in the world of
`compileWorld`. -/
def compileLocationChecks : List Check :=
  let header := "r@main in /r: check"
  let rowAt := rowStart header checkLines
  let files (driver : TestDriver) (place : Compile.Place) : Array String :=
    (Compile.recordOf driver.loop.state place).locations.map (·.file.toString)
  let fileOf (driver : TestDriver) (view : ViewId) : Option String :=
    (showing driver view).bind fun shown => shown.buffer.file.map (·.path.toString)
  let headsOf (driver : TestDriver) (view : ViewId) : Option (Array Nat) :=
    ((showing driver view).bind (·.cursors)).map (·.map (·.head))
  let currentOf (driver : TestDriver) (place : Compile.Place) : Option Nat :=
    (Compile.recordOf driver.loop.state place).current
  [{  name :=
        "locations criterion 3: locations are found as lines arrive: after the first two of four output lines the first location exists while the run is in flight, and the second once the next arrives"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let asked := compiledLine (settledAfter driver "C-o a") "stream"
            let two := postedNext (postedNext asked)
            let done := drained two
            let name := "*compilation: r@main*"
            let streamHeader := "r@main in /r: stream"
            let first : Compile.Site :=
              { file := "/r/src/main.rs", line := 12, column := some 5, columnBase := 1
                severity := .error, format := "general", first := 1, last := 1
                start := streamHeader.utf8ByteSize + 1, stop := streamHeader.utf8ByteSize + 17 }
            let record := Compile.recordOf two.loop.state placeR
            let after := (Compile.recordOf done.loop.state placeR).locations
            compiledText two name ==
                some
                  (streamHeader ++
                    "\nsrc/main.rs:12:5: error: expected one of\n  = help: add a semicolon\n") &&
              record.locations == #[first] &&
              record.running.isSome &&
              -- The job holds its next post: the third line.
              two.posting.map (·.key) == #[some "compile local /r"] &&
              after.size == 2 &&
              after[0]? == some first &&
              (after[1]?.map fun site =>
                  (site.file.toString, site.line, site.column, site.severity, site.first)) ==
                some ("/r/src/lib.lean", 3, none, .warning, 3) },
    { name :=
        "locations criterion 6: a location's relative file resolves against the directory its compilation ran in: /r's against /r, ./ dropped, and a directory scope's against its directory"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let inR := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let inX := drained (pressedOn (settledAfter driver "C-o x") "C-k h")
            files inR placeR ==
                #["/r/src/main.rs", "/r/src/lib.lean", "/r/src/main.rs", "/r/src/b.lean"] &&
              files inX (.directory "/x") == #["/x/a.txt"] },
    { name :=
        "the compilation buffer's spans are its locations' text in their severities' faces, and the view showing it draws them"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let span (row length : Nat) (face : String) : Decoration :=
              { start := rowAt row, stop := rowAt row + length, face := ⟨face⟩ }
            let expected :=
              #[span 1 16 "compilation.error", span 3 14 "compilation.warning",
                span 4 15 "compilation.note", span 5 16 "compilation.error"]
            (compileBuffer ran "*compilation: r@main*").map (·.spans) == some expected &&
              expected[0]?.map (fun span => (span.start, span.stop)) == some (20, 36) &&
              (showing ran ⟨1⟩).map (·.buffer.name) == some "*compilation: r@main*" &&
              sceneDecorations ran ⟨1⟩ == some expected },
    { name :=
        "locations criterion 4: next-error from no location visits the first, opening its file with the cursor on its line and column; next-error and previous-error move one location each, and stop with a message at either end; with nothing compiled it says so"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let step (driver : TestDriver) (keys : String) := drained (pressedOn driver keys)
            let first := step ran "C-k n"
            let second := step first "C-k n"
            let back := step second "C-k p"
            let stopped := step back "C-k p"
            let fourth := step (step (step back "C-k n") "C-k n") "C-k n"
            let past := step fourth "C-k n"
            let unstepped := pressedOn (settledAfter driver "C-o a") "C-k n"
            fileOf first ⟨0⟩ == some "/r/src/main.rs" &&
              (showing first).bind (·.cursors) == some #[⟨135, 135⟩] &&
              currentOf first placeR == some 0 &&
              headsOf first ⟨1⟩ == some #[20] &&
              first.loop.state.frame.focused == ⟨0⟩ &&
              fileOf second ⟨0⟩ == some "/r/src/lib.lean" &&
              headsOf second ⟨0⟩ == some #[8] &&
              currentOf second placeR == some 1 &&
              headsOf second ⟨1⟩ == some #[rowAt 3] &&
              fileOf back ⟨0⟩ == some "/r/src/main.rs" &&
              headsOf back ⟨0⟩ == some #[135] &&
              currentOf back placeR == some 0 &&
              echoOf stopped == some "previous-error: no earlier locations in r@main" &&
              currentOf stopped placeR == some 0 &&
              fileOf stopped ⟨0⟩ == fileOf back ⟨0⟩ &&
              headsOf stopped ⟨0⟩ == headsOf back ⟨0⟩ &&
              fileOf fourth ⟨0⟩ == some "/r/src/b.lean" &&
              headsOf fourth ⟨0⟩ == some #[2] &&
              currentOf fourth placeR == some 3 &&
              echoOf past == some "next-error: no more locations in r@main" &&
              currentOf past placeR == some 3 &&
              fileOf past ⟨0⟩ == fileOf fourth ⟨0⟩ &&
              headsOf past ⟨0⟩ == headsOf fourth ⟨0⟩ &&
              echoOf unstepped == some "next-error: no locations in r@main" },
    { name :=
        "locations criterion 5: with compilations in two worktrees of one repository, next-error in a buffer of each visits that workspace's own first location, in its own checkout's file"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let inR := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let both := drained (pressedOn (settledAfter inR "C-o w") "C-k h")
            let inW := drained (pressedOn (settledAfter both "C-o w") "C-k n")
            let inRAfter := drained (pressedOn (settledAfter inW "C-o a") "C-k n")
            let again := pressedOn (settledAfter inRAfter "C-o w") "C-k n"
            fileOf inW ⟨0⟩ == some "/w/src/main.rs" && headsOf inW ⟨0⟩ == some #[2] &&
              fileOf inRAfter ⟨0⟩ == some "/r/src/main.rs" &&
              headsOf inRAfter ⟨0⟩ == some #[135] &&
              currentOf inRAfter placeR == some 0 &&
              currentOf inRAfter placeW == some 0 &&
              echoOf again == some "next-error: no more locations in r@feature" },
    { name :=
        "locations criterion 8: activate in a compilation buffer on a location's line visits that location and focuses its view; on a line with no location it says so and changes nothing"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let onThird := pressedOn ran "C-k o C-k g"
            let activated := drained (pressedOn onThird "RET")
            let nothing := drained (pressedOn activated "C-k o C-k j RET")
            onThird.loop.state.frame.focused == ⟨1⟩ &&
              fileOf activated ⟨0⟩ == some "/r/src/main.rs" &&
              headsOf activated ⟨0⟩ == some #[23] &&
              activated.loop.state.frame.focused == ⟨0⟩ &&
              currentOf activated placeR == some 2 &&
              headsOf activated ⟨1⟩ == some #[rowAt 4] &&
              echoOf nothing == some "compile-goto-error: no location on this line" &&
              currentOf nothing placeR == some 2 &&
              fileOf nothing ⟨0⟩ == fileOf activated ⟨0⟩ &&
              headsOf nothing ⟨0⟩ == headsOf activated ⟨0⟩ },
    { name :=
        "locations criterion 7: after activate on the third location, moving the compilation buffer's cursor by hand leaves the current location, and next-error visits the fourth, the focus staying in the compilation buffer"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let activated := drained (pressedOn ran "C-k o C-k g RET")
            let byHand := pressedOn activated "C-k o C-k 0"
            let next := drained (pressedOn byHand "C-k n")
            currentOf activated placeR == some 2 && currentOf byHand placeR == some 2 &&
              headsOf byHand ⟨1⟩ == some #[0] &&
              fileOf next ⟨0⟩ == some "/r/src/b.lean" &&
              headsOf next ⟨0⟩ == some #[2] &&
              currentOf next placeR == some 3 &&
              headsOf next ⟨1⟩ == some #[rowAt 5] &&
              next.loop.state.frame.focused == ⟨1⟩ },
    { name :=
        "locations criterion 9: a location whose file does not exist says so in the echo area and moves no cursor but the compilation buffer's, which is on the location"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let gone := drained (compiledLine (settledAfter driver "C-o a") "gone")
            let stepped := drained (pressedOn gone "C-k n")
            echoOf stepped == some (Files.notOpened "/r/src/gone.rs" .notFound) &&
              fileOf stepped ⟨0⟩ == some "/r/src/a.lean" &&
              headsOf stepped ⟨0⟩ == some #[0] &&
              (stepped.loop.state.findBuffer "gone.rs").isNone &&
              stepped.loop.state.frame.focused == ⟨0⟩ &&
              currentOf stepped placeR == some 0 &&
              (showing stepped ⟨2⟩).map (·.buffer.name) == some "*compilation: r@main*" &&
              headsOf stepped ⟨2⟩ == some #["r@main in /r: gone\n".utf8ByteSize] },
    { name :=
        "locations criterion 10: a recompile resets that workspace's list only, and its next next-error visits its new first location"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let inR := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let both := drained (pressedOn (settledAfter inR "C-o w") "C-k h")
            let steppedW := drained (pressedOn both "C-k n")
            let steppedR := drained (pressedOn (settledAfter steppedW "C-o a") "C-k n")
            let wBefore := Compile.recordOf steppedR.loop.state placeW
            let second :=
              withStreams steppedR
                #[{ command := shellCommand "/r" "check"
                    steps := linesSteps ["src/b.lean:1:2: error: second run"] }]
            let rerun := drained (pressedOn second "C-o a C-k r")
            let record := Compile.recordOf rerun.loop.state placeR
            let after := drained (pressedOn rerun "C-k n")
            currentOf steppedW placeW == some 0 && currentOf steppedR placeR == some 0 &&
              record.locations.map (fun site => (site.file.toString, site.first)) ==
                #[("/r/src/b.lean", 1)] &&
              record.current == none &&
              (compileBuffer rerun "*compilation: r@main*").map (·.spans) ==
                some #[{ start := 20, stop := 34, face := ⟨"compilation.error"⟩ }] &&
              Compile.recordOf rerun.loop.state placeW == wBefore &&
              fileOf after ⟨0⟩ == some "/r/src/b.lean" &&
              headsOf after ⟨0⟩ == some #[1] &&
              currentOf after placeR == some 0 },
    { name :=
        "the ex line steps as the keys do: :next-error visits the first location and :previous-error stops before it; compile-goto-error outside a compilation buffer says so; the test scheme's next-item key in a compilation buffer steps nothing"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let exNext := drained (fedTo ran (exLine "next-error")).1
            let exPrevious := drained (fedTo exNext (exLine "previous-error")).1
            let elsewhere := pressedOn (settledAfter driver "C-o a") "C-k e"
            let activated := drained (pressedOn ran "C-k o C-k g RET")
            let item := drained (pressedOn activated "C-k o C-n")
            fileOf exNext ⟨0⟩ == some "/r/src/main.rs" && headsOf exNext ⟨0⟩ == some #[135] &&
              currentOf exNext placeR == some 0 &&
              echoOf exPrevious == some "previous-error: no earlier locations in r@main" &&
              currentOf exPrevious placeR == some 0 &&
              echoOf elsewhere == some "compile-goto-error: a.lean is not a compilation buffer" &&
              currentOf item placeR == some 2 &&
              fileOf item ⟨0⟩ == fileOf activated ⟨0⟩ &&
              headsOf item ⟨0⟩ == headsOf activated ⟨0⟩ },
    { name :=
        "with the compilation buffer in the only view, next-error splits that view and visits the location in the new view, the focus staying in the compilation buffer; activate there visits in the new view and focuses it"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let only := pressedOn ran "C-e c"
            let stepped := drained (pressedOn only "C-k n")
            let activated := drained (pressedOn only "C-k g RET")
            only.loop.state.frame.windows == #[⟨1⟩] && only.loop.state.frame.focused == ⟨1⟩ &&
              stepped.loop.state.frame.windows == #[⟨1⟩, ⟨2⟩] &&
              (showing stepped ⟨1⟩).map (·.buffer.name) == some "*compilation: r@main*" &&
              fileOf stepped ⟨2⟩ == some "/r/src/main.rs" &&
              headsOf stepped ⟨2⟩ == some #[135] &&
              stepped.loop.state.frame.focused == ⟨1⟩ &&
              currentOf stepped placeR == some 0 &&
              activated.loop.state.frame.windows == #[⟨1⟩, ⟨2⟩] &&
              (showing activated ⟨1⟩).map (·.buffer.name) == some "*compilation: r@main*" &&
              fileOf activated ⟨2⟩ == some "/r/src/main.rs" &&
              headsOf activated ⟨2⟩ == some #[23] &&
              activated.loop.state.frame.focused == ⟨2⟩ &&
              currentOf activated placeR == some 2 },
    { name :=
        "with the compilation buffer in the only view and a prompt open, next-error from the compilation buffer never visits in the minibuffer's view: it splits the compilation buffer's view and visits in the new view"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let asking := pressedOn ran "C-e c C-k c C-k o"
            let stepped := drained (pressedOn asking "C-k n")
            let minibuffer := asking.loop.state.minibufferView?
            asking.loop.state.frame.windows == #[⟨1⟩] && minibuffer == some ⟨2⟩ &&
              asking.loop.state.frame.focused == ⟨1⟩ &&
              stepped.loop.state.minibufferView? == minibuffer &&
              stepped.loop.state.frame.windows == #[⟨1⟩, ⟨3⟩] &&
              (showing stepped ⟨1⟩).map (·.buffer.name) == some "*compilation: r@main*" &&
              fileOf stepped ⟨3⟩ == some "/r/src/main.rs" &&
              headsOf stepped ⟨3⟩ == some #[135] &&
              currentOf stepped placeR == some 0 },
    { name :=
        "the view a location is visited in, asked from the compilation buffer in the only view, is the asking view where the split is refused, and the new view split from it where it is not"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let only := pressedOn ran "C-e c"
            let compilation := only.loop.state.findBuffer "*compilation: r@main*"
            let visiting (refuseSplits : Bool) : Option ViewId :=
              (Program.run (port := editorPort) (splitsRefusedIf refuseSplits)
                  (Compile.visitingView ⟨1⟩ compilation).run
                  (only.loop.state, only.model)).1.toOption
            only.loop.state.frame.windows == #[⟨1⟩] && compilation.isSome &&
              visiting true == some ⟨1⟩ &&
              visiting false == some ⟨2⟩ },
    { name :=
        "a location whose format counts columns from 0 is visited at its printed column: 12:5 is byte 136 of main.rs, one on from where the general format puts it, and 2:7 is byte 25, seven two-byte characters into its row"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let based :=
              pressedOn (drained (pressedOn (settledAfter driver "C-o a") "C-k h")) "C-k b"
            let step (driver : TestDriver) (keys : String) := drained (pressedOn driver keys)
            let first := step based "C-k n"
            let third := step (step first "C-k n") "C-k n"
            (Compile.recordOf based.loop.state placeR).locations.map (·.columnBase) ==
                #[0, 0, 0, 0] &&
              fileOf first ⟨0⟩ == some "/r/src/main.rs" &&
              headsOf first ⟨0⟩ == some #[136] &&
              currentOf third placeR == some 2 &&
              fileOf third ⟨0⟩ == some "/r/src/main.rs" &&
              headsOf third ⟨0⟩ == some #[25] },
    { name :=
        "previous-error right after a compile, with no current location, stops with a message, leaves the current location none and visits nothing"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let ran := drained (pressedOn (settledAfter driver "C-o a") "C-k h")
            let back := drained (pressedOn ran "C-k p")
            currentOf ran placeR == none &&
              echoOf back == some "previous-error: no earlier locations in r@main" &&
              currentOf back placeR == none &&
              fileOf back ⟨0⟩ == some "/r/src/a.lean" &&
              headsOf back ⟨0⟩ == headsOf ran ⟨0⟩ &&
              headsOf back ⟨1⟩ == headsOf ran ⟨1⟩ }]

/-- The error format `name` of the hook checks: `at <file> line <line>`, which
the general format does not read. -/
def atFormat (name : String) : Compile.Format :=
  { name
    pattern :=
      [Compile.step
          [{ atom := .literal "at " }, { atom := .noneOf [' '], into := some .file },
            { atom := .literal " line " }, { atom := .digits, into := some .line }],
        Compile.step [{ atom := .rest }]] }

/-- `a-mode`'s formats in the hook checks. -/
def aFormats : Array Compile.Format :=
  #[atFormat "a-at"]

/-- `b-mode`'s formats in the hook checks: its own `at` format, then the
general one under another name. -/
def bFormats : Array Compile.Format :=
  #[atFormat "b-at", { Compile.Format.general with name := "b-general" }]

/-- `a-mode`'s commands in the hook checks, as `hookSetup` registers them by
default. -/
def aCommands : Array Compile.NamedCommand :=
  #[{ name := "build", line := "a-build" }, { name := "test", line := "a-test" }]

/-- The project commands of the hook checks: `lint` of `cargo-mode` for
`github.com/o/r`, as `cargo clippy`, with the setting `profile` `dev`. -/
def lintProject : SetupM Unit :=
  projectCommands (.remote "github.com/o/r") "cargo-mode" [("lint", "cargo clippy")]
    [("profile", .str "dev")]

/-- The config of the hook checks, in this order: `b-mode` on `b.toml`,
`a-mode` on `a.toml` with `aCommands` as its commands unless it is given
others, `marker-mode` on `marker.toml` and `cargo-mode` on `Cargo.toml`;
then `project`, by default `lintProject`. -/
def hookSetup (aCommands : Array Compile.NamedCommand := aCommands)
    (project : SetupM Unit := lintProject) : SetupM Unit := do
  compileContribution
      { mode := "b-mode", markers := #["b.toml"]
        commands :=
          #[{ name := "build", line := "b-build" }, { name := "check", line := "b-check" }]
        formats := bFormats }
  compileContribution
      { mode := "a-mode", markers := #["a.toml"], commands := aCommands, formats := aFormats }
  compileContribution
      { mode := "marker-mode", markers := #["marker.toml"]
        commands := #[{ name := "build", line := "m-build" }] }
  compileContribution
      { mode := "cargo-mode", markers := #["Cargo.toml"]
        commands :=
          #[{ name := "build", line := "cargo build" }, { name := "test", line := "cargo test" }] }
  project

/-- The registry of the hook checks: `setup`'s contributions and project
commands installed for config, over `compiled` for the owner `compiled`. -/
def hookRegistry (setup : SetupM Unit := hookSetup) (compiled : Array Compile.Contribution := #[]) :
    Config.Registry :=
  let base := ({} : Config.Registry).replaceContributions .compiled compiled
  match Config.Registrations.ofSetup setup with
  | .ok registrations =>
    { base.replaceContributions .config registrations.contributions with
      projectCommands := registrations.projectCommands }
  | .error _ => base

/-- The world of the hook checks: the compile checks' world, a repository
`/up/repo` with no origin, a repository `/o` of another origin, and the
marker files of `hookSetup`'s modes. -/
def hookWorld : Workspace.World :=
  { compileWorld with
    repositories :=
      compileWorld.repositories ++
        #[{ toplevel := "/up/repo", commonDir := "/up/repo/.git" },
          { toplevel := "/o", commonDir := "/o/.git", origin := some "git@github.com:o/other.git" }]
    markerDirectories :=
      compileWorld.markerDirectories ++ (#["/up/repo/.git", "/o/.git"] : Array System.FilePath)
    markers :=
      compileWorld.markers ++
        (#["/r/a/marker.toml", "/up/marker.toml", "/loose/marker.toml", "/loose2/marker.toml",
            "/r/hook/b.toml", "/r/hook/one/two/a.toml", "/r/crate/Cargo.toml",
            "/w/crate/Cargo.toml", "/o/Cargo.toml"] :
          Array System.FilePath) }

/-- Every directory a file of the hook checks opens in, each of which git is
scripted for: one git leaves unscripted would fall to the marker adapter,
which finds `Cargo.toml` as a root. -/
def hookDirectories : Array System.FilePath :=
  #["/r/src", "/w/src", "/x", "/clone/r/src", "/r/a/b/c", "/up/repo/src", "/loose/deep", "/loose2",
    "/r/hook/one/two/three/four", "/r/crate/src", "/w/crate/src", "/o/src"]

/-- The bindings of the hook checks: the compile checks', `C-k i`
(`compile-command`), and `C-o m`, `C-o u`, `C-o l`, `C-o 2`, `C-o h`, `C-o
g`, `C-o k`, `C-o 3` and `C-o 4`, which open the files of `hookFiles` in
that order. Test-scheme chords only. -/
def hookBindings : List (String × Invocation) :=
  compileBindings ++
    [("C-k i", invoke Compile.commandName), ("C-o m", opens "/r/a/b/c/x.txt"),
      ("C-o u", opens "/up/repo/src/u.txt"), ("C-o l", opens "/loose/deep/l.txt"),
      ("C-o 2", opens "/loose2/l.txt"), ("C-o h", opens "/r/hook/one/two/three/four/f.txt"),
      ("C-o g", opens "/r/hook/one/two/three/four/g.txt"), ("C-o k", opens "/r/crate/src/main.rs"),
      ("C-o 3", opens "/w/crate/src/main.rs"), ("C-o 4", opens "/o/src/main.rs")]

/-- The files of the hook checks, besides the compile checks'. -/
def hookFiles : List (String × String) :=
  [("/r/a/b/c/x.txt", "x"), ("/up/repo/src/u.txt", "u"), ("/loose/deep/l.txt", "l"),
    ("/loose2/l.txt", "l"), ("/r/hook/one/two/three/four/f.txt", "f"),
    ("/r/hook/one/two/three/four/g.txt", "g"), ("/r/crate/src/main.rs", "fn main() {}\n"),
    ("/w/crate/src/main.rs", "fn main() {}\n"), ("/o/src/main.rs", "fn main() {}\n")]

/-- The keys of the hook checks (`hookBindings`), with the loop told of
`registry`'s compile contributions. -/
def hookKeys (registry : Config.Registry) : Loop.Keys TestScheme.scheme :=
  let keys := compileKeysOf hookBindings
  { keys with registered := { keys.registered with compile := registry.compileHook } }

/-- The output both `a-build`s write: a line `a-mode`'s and `b-mode`'s `at`
formats read, and one the general format reads. -/
def hookLines : List String :=
  ["at src/x.rs line 4", "src/main.rs:1:1: error: x"]

/-- The streaming children of the hook checks, besides the compile
checks'. -/
def hookStreams : Array Process.StreamScript :=
  #[{ command := shellCommand "/r/hook/one/two" "a-build", steps := linesSteps hookLines },
    { command := shellCommand "/r" "a-build", steps := linesSteps hookLines },
    { command := shellCommand "/r/hook/one/two" "a-test", steps := linesSteps ["ok"] },
    { command := shellCommand "/r/hook" "b-check", steps := linesSteps ["ok"] },
    { command := shellCommand "/r/hook/one/two" "config-build", steps := linesSteps ["ok"] },
    { command := shellCommand "/r/crate" "cargo clippy", steps := linesSteps ["ok"] },
    { command := shellCommand "/r/crate" "cargo clippy -D warnings", steps := linesSteps ["ok"] }]

/-- A driver of the hook checks: the world of `hookWorld`, with the hook
checks' keys over `registry` and the compile checks' jobs, the files of both,
and the children of both; `none` if making the state was refused. -/
def hookDriver (registry : Config.Registry := hookRegistry) : Option TestDriver :=
  let model := hookWorld.jobModel "git" hookDirectories
  let files :=
    (compileFiles ++ hookFiles).foldl
      (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) model.files
  (Loop.Driver.over (hookKeys registry) compileJobs (EditorState.initial ⟨640, 480⟩)
        editorModel).toOption.map
    fun driver =>
    { driver with
      jobs :=
        { model with
          files, processes := { model.processes with streams := hookStreams ++ compileStreams } } }

/-- The on-modes of the buffer the view 0 of `driver` shows. -/
def shownOnModes (driver : TestDriver) : Option (Array Workspace.OnMode) := do
  return Workspace.onModesOf driver.loop.state (← showing driver).id

/-- The minor modes of the buffer the view 0 of `driver` shows. -/
def shownMinors (driver : TestDriver) : Option (Array String) :=
  (showing driver).map (·.buffer.minors)

/-- `driver` once `keys` are pressed and every job they start, and every job
those jobs' commands start, is finished, oldest first; with the names of the
jobs finished, in order. -/
def settledNames (driver : TestDriver) (keys : String) : TestDriver × Array String :=
  (List.range 8).foldl
    (fun (driver, names) _ =>
      match driver.pending[0]? with
      | some job => ((driver.finish job.id).1, names.push job.name)
      | none => (driver, names))
    ((fedTo driver (presses keys)).1, #[])

/-- The on-modes of `/r/hook/one/two/three/four` in the hook checks:
`a-mode` at `/r/hook/one/two`, then `b-mode` at `/r/hook`. -/
def hookModes : Array Workspace.OnMode :=
  #[{ mode := "a-mode", root := "/r/hook/one/two" }, { mode := "b-mode", root := "/r/hook" }]

/-- The locations a run of `a-build` in `/r/hook/one/two` with `hookModes`
finds, as each one's format and file: `a-mode`'s format reads the first
line, and `b-mode`'s copy of the general format the second. -/
def hookLocations : Array (String × String) :=
  #[("a-at", "/r/hook/one/two/src/x.rs"), ("b-general", "/r/hook/one/two/src/main.rs")]

/-- The locations `place` keeps in `driver`, as each one's format and
file. -/
def locationsOf (driver : TestDriver) (place : Compile.Place) : Array (String × String) :=
  (Compile.recordOf driver.loop.state place).locations.map fun site =>
    (site.format, site.file.toString)

/-- The registry of criterion 8 of the hook checks: config's `a-mode` with
the commands `build` and `test` as `config-build` and `config-test`, over a
compiled `a-mode` with `build` and `lint`. -/
def hookOverCompiled : Config.Registry :=
  hookRegistry
    (hookSetup
      #[{ name := "build", line := "config-build" }, { name := "test", line := "config-test" }])
    #[{ mode := "a-mode", markers := #["a.toml"]
        commands :=
          #[{ name := "build", line := "compiled-build" },
            { name := "lint", line := "compiled-lint" }] }]

/-- `driver` once the loop is told the compile hook of `hookSetup` with
`project` as its project commands, as a reload that changes them tells
it. -/
def toldProject (driver : TestDriver) (project : SetupM Unit) : TestDriver :=
  let compile := (hookRegistry (hookSetup aCommands project)).compileHook
  { driver with keys := { driver.keys with registered := { driver.keys.registered with compile } } }

/-- The settings `Compile.projectSettings` gives the project of `identity`
for the mode `mode`, run as the loop runs a command in `driver`; `none` if
it does not finish. -/
def settingsIn (driver : TestDriver) (identity : Project.Identity) (mode : String) :
    Option (List (String × Value)) :=
  let program : EditorM (Guarded (List (String × Value))) := do
    return (←
          (Compile.projectSettings identity mode).dispatched driver.keys.registered
              driver.loop.state).1
  match (program.runModel driver.model).1 with
  | .ok (.finished settings) => some settings
  | _ => none

/-- A driver of the hook checks (`hookDriver`) whose loop is also told of
the `code` mode and of the language `modelRs`, as a host registers them
beside its contributions, so an opened `.rs` file both chooses a language
and has its markers' minor modes turned on; `none` if making the state was
refused. -/
def hookLanguageDriver : Option TestDriver :=
  hookDriver.map fun driver =>
    let registered := driver.keys.registered
    { driver with
      keys :=
        { driver.keys with
          registered :=
            { registered with
              entering := fun name =>
                (registered.entering name).orElse fun _ =>
                  (Language.modes.find? (·.name == name)).map ([·])
              languages := [modelRs] } } }

/-- The checks of the compile hook (`Editor/Workspace/Modes.lean`,
`Editor/Compile.lean`, "The hook"), on the loop's driver over the editor's
models, the job model and the process model, in the world of `hookWorld`
with the contributions of `hookSetup`. -/
def compileHookChecks : List Check :=
  [{  name :=
        "hook criterion 1: a contribution registered in config with marker marker.toml turns marker-mode on in a buffer of /r/a/b/c/x.txt, two directories under /r/a/marker.toml, with /r/a as its root, and not in a buffer of /r/src/a.lean outside it"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let inside := settledAfter driver "C-o m"
            let outside := settledAfter driver "C-o a"
            (shownWorkspace inside).map (·.1.location) == some (.local "/r") &&
              shownMinors inside == some #["marker-mode"] &&
              shownOnModes inside == some #[{ mode := "marker-mode", root := "/r/a" }] &&
              (shownWorkspace outside).map (·.1.location) == some (.local "/r") &&
              shownMinors outside == some #[] &&
              shownOnModes outside == some #[] },
    { name :=
        "hook criterion 2: a marker above the buffer's workspace root turns no mode on: /up/marker.toml above the workspace /up/repo; /loose/marker.toml above /loose/deep/l.txt, which has no workspace and looks in its own directory alone; /loose2/marker.toml beside /loose2/l.txt turns marker-mode on with root /loose2"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let up := settledAfter driver "C-o u"
            let loose := settledAfter driver "C-o l"
            let beside := settledAfter driver "C-o 2"
            (shownWorkspace up).map (·.1.location) == some (.local "/up/repo") &&
              shownMinors up == some #[] &&
              shownOnModes up == some #[] &&
              (showing loose).map (·.buffer.name) == some "l.txt" &&
              (shownWorkspace loose).isNone &&
              shownMinors loose == some #[] &&
              shownOnModes loose == some #[] &&
              (shownWorkspace beside).isNone &&
              shownMinors beside == some #["marker-mode"] &&
              shownOnModes beside == some #[{ mode := "marker-mode", root := "/loose2" }] },
    { name :=
        "hook criterion 3: with a-mode's marker two directories above the file and b-mode's four, both inside /r, both modes are on, a-mode first with root /r/hook/one/two and b-mode with root /r/hook, though b-mode was registered first"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o h"
            shownOnModes opened ==
                some
                  #[{ mode := "a-mode", root := "/r/hook/one/two" },
                    { mode := "b-mode", root := "/r/hook" }] &&
              shownMinors opened == some #["a-mode", "b-mode"] },
    { name :=
        "with no compile contribution registered, opening a file starts no find-mode-markers job and gives the buffer no on-modes"
      run :=
        pure <|
          match compileDriver with
          | none => false
          | some driver =>
            let (opened, names) := settledNames driver "C-o a"
            names.contains Workspace.findJob && !names.contains Workspace.markerJob &&
              shownOnModes opened == some #[] &&
              shownMinors opened == some #[] },
    { name :=
        "a second file of a directory whose workspace is cached gets its on-modes from find-mode-markers, with no git run"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let first := settledAfter driver "C-o h"
            let (second, names) := settledNames first "C-o g"
            (showing second).map (·.buffer.name) == some "g.txt" &&
              second.jobs.processes.started == first.jobs.processes.started &&
              names.contains Workspace.markerJob &&
              !names.contains Workspace.findJob &&
              shownOnModes second == shownOnModes first &&
              shownMinors second == some #["a-mode", "b-mode"] },
    { name :=
        "hook criterion 4: in that set-up compile's prompt holds a-mode's first command, a-build; a line both a-mode's and b-mode's formats read is a-mode's location, and a line b-mode's format and the general one read is b-mode's"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let asked := pressedOn (settledAfter driver "C-o h") "C-k c"
            let ran := drained (pressedOn asked "C-e y")
            asked.loop.state.prompt.map (·.label) == some Compile.promptLabel &&
              (showing asked asked.loop.state.frame.focused).bind (·.text) == some "a-build" &&
              locationsOf ran placeR == hookLocations &&
              (Compile.formatsOf hookRegistry.compileContributions hookModes).map (·.name) ==
                #["a-at", "b-at", "b-general", "general"] },
    { name :=
        "hook criterion 5: on the process model, compile accepted with its default starts /bin/sh -c a-build in /r/hook/one/two, the header says r@main in /r/hook/one/two: a-build, and the output is in *compilation: r@main*, the workspace's buffer"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let ran := pressedOn (pressedOn (settledAfter driver "C-o h") "C-k c") "C-e y"
            let done := drained ran
            let name := "*compilation: r@main*"
            let state := done.loop.state
            ran.jobs.processes.started.back? == some (shellCommand "/r/hook/one/two" "a-build") &&
              ran.posting.map (·.key) == #[some "compile local /r"] &&
              (compiledText done name).map
                  (·.startsWith "r@main in /r/hook/one/two: a-build\nat src/x.rs line 4\n") ==
                some true &&
              (state.findBuffer name).bind (fun id => (state.workspaceOf? id).map (·.1.location)) ==
                some (.local "/r") },
    { name :=
        "hook criterion 7: a-mode's format finds at src/x.rs line 4, which the general format does not, in a compile from a buffer where a-mode is on, and not in one from /r/src/a.lean where it is off"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let off := drained (compiledLine (settledAfter driver "C-o a") "a-build")
            let on := drained (pressedOn (pressedOn (settledAfter driver "C-o h") "C-k c") "C-e y")
            off.jobs.processes.started.back? == some (shellCommand "/r" "a-build") &&
              locationsOf off placeR == #[("general", "/r/src/main.rs")] &&
              locationsOf on placeR == hookLocations },
    { name :=
        "hook criterion 8: config's contribution of a-mode replaces the compiled one's commands: compile defaults to config-build, and compile-command offers config's commands alone, its build running config-build"
      run :=
        pure <|
          match hookDriver hookOverCompiled with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o h"
            let asked := pressedOn opened "C-k c"
            let offered := pressedOn opened "C-k i"
            let built := (fedTo offered ([.commit "build (a-mode)"] ++ presses "C-e y")).1
            (showing asked asked.loop.state.frame.focused).bind (·.text) == some "config-build" &&
              (candidatesOf offered).map (·.all) ==
                some #["build (a-mode)", "test (a-mode)", "build (b-mode)", "check (b-mode)"] &&
              built.jobs.processes.started.back? ==
                some (shellCommand "/r/hook/one/two" "config-build") },
    { name :=
        "recompile reruns the last line in its directory with the run's modes, so a-mode's format still reads its lines, from the compilation buffer too; compile in the compilation buffer defaults to the run's line and runs in its first mode's root"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let first :=
              drained (pressedOn (pressedOn (settledAfter driver "C-o h") "C-k c") "C-e y")
            let again := drained (pressedOn first "C-k r")
            let fromBuffer := drained (pressedOn first "C-k o C-k r")
            let asked := pressedOn first "C-k o C-k c"
            let accepted := drained (pressedOn asked "C-e y")
            let runsThere (driver : TestDriver) :=
              driver.jobs.processes.started.back? ==
                  some (shellCommand "/r/hook/one/two" "a-build") &&
                (Compile.recordOf driver.loop.state placeR).modes == hookModes &&
                locationsOf driver placeR == hookLocations
            runsThere first && runsThere again &&
              again.jobs.processes.started.size == first.jobs.processes.started.size + 1 &&
              (showing fromBuffer fromBuffer.loop.state.frame.focused).map (·.buffer.name) ==
                some "*compilation: r@main*" &&
              runsThere fromBuffer &&
              (showing asked asked.loop.state.frame.focused).bind (·.text) == some "a-build" &&
              runsThere accepted &&
              accepted.jobs.processes.started.size == first.jobs.processes.started.size + 1 },
    { name :=
        "a compile record with on-modes crosses as a tree and back, in both stores, now at version 3; a tree of version 2's shape, with no modes, is none"
      run :=
        let record : Compile.Record :=
          { buffer := some 2, last := some ("a-build", "/r/hook/one/two"), runs := 1
            modes := hookModes }
        let older :=
          match record.encode with
          | .record fields => Value.record (fields.filter (·.1 != "modes"))
          | other => other
        pure
          (Compile.Record.decode record.encode == some record &&
            Compile.store.decode (Compile.store.encode record) == some record &&
            Compile.directoryStore.decode (Compile.directoryStore.encode #[("/x", record)]) ==
              some #[("/x", record)] &&
            Compile.Record.decode older == none &&
            Compile.store.version == 3 &&
            Compile.directoryStore.version == 3) },
    { name :=
        "a run asked while one is in flight carries its modes through the restart prompt: yes runs the line in the mode's root with them"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let running := pressedOn (pressedOn (settledAfter driver "C-o h") "C-k c") "C-e y"
            let asked := pressedOn (pressedOn running "C-k c") "C-e y"
            let confirmed := drained (fedTo asked ([.commit "y"] ++ presses "C-e y")).1
            let line := shellCommand "/r/hook/one/two" "a-build"
            asked.loop.state.prompt.map (·.label) ==
                some "Kill the compilation running in r@main? (y or n) " &&
              confirmed.jobs.processes.killed == #[line] &&
              (confirmed.jobs.processes.started.filter (· == line)).size == 2 &&
              (Compile.recordOf confirmed.loop.state placeR).modes == hookModes &&
              locationsOf confirmed placeR == hookLocations },
    { name :=
        "offers gives each on-mode's commands in on-mode order with the mode's root, replaces a contribution's command by a project's of the same name in place and appends a new name after, and offers nothing for a mode with no contribution, whose formats are none"
      run :=
        let contributions : Array Compile.Contribution :=
          #[{ mode := "a-mode", markers := #["a.toml"], commands := aCommands },
            { mode := "b-mode", markers := #["b.toml"]
              commands := #[{ name := "check", line := "b-check" }] }]
        let stored : Array Compile.ProjectCommands :=
          #[{ project := .remote "github.com/o/r", mode := "a-mode"
              commands :=
                #[{ name := "lint", line := "a-lint" }, { name := "build", line := "p-build" }] }]
        let modes : Array Workspace.OnMode :=
          #[{ mode := "a-mode", root := "/a" }, { mode := "gone-mode", root := "/g" },
            { mode := "b-mode", root := "/b" }]
        pure
          (Compile.offers contributions stored modes ==
              #[{ mode := "a-mode", name := "build", line := "p-build", root := "/a" },
                { mode := "a-mode", name := "test", line := "a-test", root := "/a" },
                { mode := "a-mode", name := "lint", line := "a-lint", root := "/a" },
                { mode := "b-mode", name := "check", line := "b-check", root := "/b" }] &&
            (Compile.offers contributions stored #[]).isEmpty &&
            (Compile.offers contributions #[] #[{ mode := "gone-mode", root := "/g" }]).isEmpty &&
            (Compile.formatsOf contributions #[{ mode := "gone-mode", root := "/g" }]).map
                (·.name) ==
              #["general"]) },
    { name :=
        "hook criterion 6: compile-command offers build (a-mode), test (a-mode), build (b-mode) and check (b-mode); test runs a-test in /r/hook/one/two, and check (b-mode) given whole runs b-check in /r/hook"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let asked := pressedOn (settledAfter driver "C-o h") "C-k i"
            let tested := drained (fedTo asked ([.commit "test"] ++ presses "C-e y")).1
            let checked :=
              drained
                (fedTo (pressedOn tested "C-k i") ([.commit "check (b-mode)"] ++ presses "C-e y")).1
            let name := "*compilation: r@main*"
            asked.loop.state.prompt.map (·.label) == some Compile.commandPromptLabel &&
              Compile.commandPromptLabel == "Mode command: " &&
              (showing asked asked.loop.state.frame.focused).bind (·.text) == some "" &&
              (candidatesOf asked).map (·.all) ==
                some #["build (a-mode)", "test (a-mode)", "build (b-mode)", "check (b-mode)"] &&
              tested.jobs.processes.started.back? ==
                some (shellCommand "/r/hook/one/two" "a-test") &&
              (compiledText tested name).map
                  (·.startsWith "r@main in /r/hook/one/two: a-test\nok\n") ==
                some true &&
              checked.jobs.processes.started.back? == some (shellCommand "/r/hook" "b-check") &&
              (compiledText checked name).map (·.startsWith "r@main in /r/hook: b-check\nok\n") ==
                some true },
    { name :=
        "compile-command in a buffer with no mode on says compile-command: no mode gives commands in r@main and opens no prompt; an answer that names no command says compile-command: no command make in r@main; an empty one says compile-command: no command; in a workspace that cannot run commands it says so"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let plain := pressedOn (settledAfter driver "C-o a") "C-k i"
            let opened := settledAfter driver "C-o h"
            let unknown :=
              (fedTo (pressedOn opened "C-k i") ([.commit "make"] ++ presses "C-e y")).1
            let empty := pressedOn (pressedOn opened "C-k i") "C-e y"
            let kube := pressedOn (settledAfter opened "C-e k") "C-k i"
            plain.loop.state.prompt.isNone &&
              echoOf plain == some "compile-command: no mode gives commands in r@main" &&
              echoOf unknown == some "compile-command: no command make in r@main" &&
              unknown.jobs.processes.started == opened.jobs.processes.started &&
              unknown.loop.state.prompt.isNone &&
              echoOf empty == some "compile-command: no command" &&
              empty.jobs.processes.started == opened.jobs.processes.started &&
              kube.loop.state.prompt.isNone &&
              echoOf kube ==
                some
                  "compile-command: r@app is reachable through kube pod at /app, where commands cannot run" },
    { name :=
        "the ex line runs compile-command: `:compile-command test` runs a-test in /r/hook/one/two with no prompt"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let ran := (fedTo (settledAfter driver "C-o h") (exLine "compile-command test")).1
            ran.jobs.processes.started.back? == some (shellCommand "/r/hook/one/two" "a-test") &&
              ran.loop.state.prompt.isNone },
    { name :=
        "hook criterion 9: lint, a command config gives cargo-mode for the project github.com/o/r, is offered in /r/crate and in its worktree /w/crate and not in /o of github.com/o/other; it runs cargo clippy in /r/crate, and its settings are read for that project and not the other"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let inR := pressedOn (settledAfter driver "C-o k") "C-k i"
            let worktree := settledAfter driver "C-o 3"
            let inW := pressedOn worktree "C-k i"
            let inO := pressedOn (settledAfter driver "C-o 4") "C-k i"
            let linted := (fedTo inR ([.commit "lint"] ++ presses "C-e y")).1
            let cargo := #["build (cargo-mode)", "test (cargo-mode)"]
            let dev : List (String × Value) := [("profile", .str "dev")]
            (candidatesOf inR).map (·.all) == some (cargo.push "lint (cargo-mode)") &&
              (shownWorkspace worktree).map (·.1.location) == some (.local "/w") &&
              shownOnModes worktree == some #[{ mode := "cargo-mode", root := "/w/crate" }] &&
              (candidatesOf inW).map (·.all) == some (cargo.push "lint (cargo-mode)") &&
              (candidatesOf inO).map (·.all) == some cargo &&
              linted.jobs.processes.started.back? ==
                some (shellCommand "/r/crate" "cargo clippy") &&
              settingsIn linted (.remote "github.com/o/r") "cargo-mode" == some dev &&
              settingsIn inO (.remote "github.com/o/other") "cargo-mode" == some [] },
    { name :=
        "a project's settings are read as soon as a file of it opens, in either worktree, before compile or compile-command runs there; another project's are none"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let inR := settledAfter driver "C-o k"
            let inW := settledAfter driver "C-o 3"
            let inO := settledAfter driver "C-o 4"
            let dev : List (String × Value) := [("profile", .str "dev")]
            (shownWorkspace inR).map (·.2.identity) == some (.remote "github.com/o/r") &&
              (shownWorkspace inW).map (·.2.identity) == some (.remote "github.com/o/r") &&
              settingsIn inR (.remote "github.com/o/r") "cargo-mode" == some dev &&
              settingsIn inW (.remote "github.com/o/r") "cargo-mode" == some dev &&
              settingsIn inO (.remote "github.com/o/other") "cargo-mode" == some [] },
    { name :=
        "a project's settings follow a reload at once, with no compile between: a changed setting reads the new value, and dropped ones read none"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o k"
            let linted :=
              drained (fedTo (pressedOn opened "C-k i") ([.commit "lint"] ++ presses "C-e y")).1
            let changed :=
              toldProject linted
                (projectCommands (.remote "github.com/o/r") "cargo-mode"
                  [("lint", "cargo clippy -D warnings")] [("profile", .str "release")])
            let dropped := toldProject changed (pure ())
            let r : Project.Identity := .remote "github.com/o/r"
            settingsIn linted r "cargo-mode" == some [("profile", .str "dev")] &&
              settingsIn changed r "cargo-mode" == some [("profile", .str "release")] &&
              settingsIn dropped r "cargo-mode" == some [] },
    { name :=
        "a reload that changes a project's commands is seen at the next compile-command: it offers lint and runs its new line; after a reload that drops them it offers no lint"
      run :=
        pure <|
          match hookDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o k"
            let linted :=
              drained (fedTo (pressedOn opened "C-k i") ([.commit "lint"] ++ presses "C-e y")).1
            let changed :=
              toldProject linted
                (projectCommands (.remote "github.com/o/r") "cargo-mode"
                  [("lint", "cargo clippy -D warnings")] [("profile", .str "release")])
            let asked := pressedOn changed "C-k i"
            let relinted := drained (fedTo asked ([.commit "lint"] ++ presses "C-e y")).1
            let dropped := toldProject relinted (pure ())
            let askedAgain := pressedOn dropped "C-k i"
            let cargo := #["build (cargo-mode)", "test (cargo-mode)"]
            linted.jobs.processes.started.back? == some (shellCommand "/r/crate" "cargo clippy") &&
              (candidatesOf asked).map (·.all) == some (cargo.push "lint (cargo-mode)") &&
              relinted.jobs.processes.started.back? ==
                some (shellCommand "/r/crate" "cargo clippy -D warnings") &&
              (candidatesOf askedAgain).map (·.all) == some cargo },
    { name :=
        "chooseOffer takes a whole candidate first, then the first offer of a bare name, and none for anything else; an offer is shown as its name and its mode"
      run :=
        let a : Compile.Offer :=
          { mode := "a-mode", name := "build", line := "a-build", root := "/a" }
        let b : Compile.Offer :=
          { mode := "b-mode", name := "build", line := "b-build", root := "/b" }
        let odd : Compile.Offer :=
          { mode := "b-mode", name := "build (a-mode)", line := "odd", root := "/b" }
        pure
          (Compile.chooseOffer #[a, b] "build" == some a &&
            Compile.chooseOffer #[a, b] "build (b-mode)" == some b &&
            Compile.chooseOffer #[a, b] " build (b-mode) " == some b &&
            Compile.chooseOffer #[odd, a] "build (a-mode)" == some a &&
            Compile.chooseOffer #[a, b] "make" == none &&
            Compile.chooseOffer #[a, b] "" == none &&
            a.candidate == "build (a-mode)") },
    { name :=
        "a run whose child writes a lead line, pauses, then writes its location keeps one site whose first row is the lead's, with the lead's message, as one post would"
      run :=
        let setup : SetupM Unit :=
          compileContribution
            { mode := "a-mode", markers := #["a.toml"], commands := aCommands
              formats := #[leadFormat] }
        let steps : Array Process.Step :=
          #[.write .out "warning: unused x\n".toUTF8, .pause 100,
            .write .out "  at a.rs:4\n".toUTF8]
        pure <|
          match hookDriver (hookRegistry setup) with
          | none => false
          | some driver =>
            let opened :=
              withStreams (settledAfter driver "C-o h")
                #[{ command := shellCommand "/r/hook/one/two" "a-build", steps }]
            let ran := drained (pressedOn (pressedOn opened "C-k c") "C-e y")
            ran.posting.isEmpty &&
              (Compile.recordOf ran.loop.state placeR).locations.map
                  (fun site => (site.file.toString, site.first, site.last, site.message)) ==
                #[("/r/hook/one/two/a.rs", 1, 2, some "unused x")] },
    { name :=
        "a marker order crosses as arguments and back, and arguments that are no order read as none; the marker job started with them fails"
      run :=
        let orders : List Workspace.MarkerOrder :=
          [{ buffer := ⟨1⟩, directory := "/r/src", bound := "/r", markers := #[] },
            { buffer := ⟨4⟩, directory := "/a b/é", bound := "/a b", markers := #["a.toml", "B"] }]
        pure
          (orders.all
              (fun order => Workspace.MarkerOrder.ofArguments? order.arguments == some order) &&
            [[], [.nat 1, .str "/r"], [.nat 1, .str "/r", .str "/r", .nat 0]].all
              (Workspace.MarkerOrder.ofArguments? · == none) &&
            ((Workspace.markerWork [.nat 1] ()).runModel {}).1 matches .failed _) },
    { name :=
        "opening /r/crate/src/main.rs under /r/crate/Cargo.toml gives its buffer the language model-rs and the major mode code, attached with that language's grammar, and, once the marker job's command runs after, the minor mode cargo-mode with root /r/crate: setting the major mode on open and turning the markers' minor modes on later leave each other alone"
      run :=
        pure <|
          match hookLanguageDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-o k"
            (showing opened).map (·.buffer.name) == some "main.rs" &&
              languageAndMajor opened == some (some "model-rs", some "code") &&
              opened.model.syntaxTree.attached.map (·.2) == #["json"] &&
              shownMinors opened == some #["cargo-mode"] &&
              shownOnModes opened == some #[{ mode := "cargo-mode", root := "/r/crate" }] }]

/-- What cargo prints of rustc's error in the probe crate, after its
`Compiling` line: the message, its location and the snippet under it. -/
def rustcLines : Array String :=
  #["error[E0308]: mismatched types", " --> src/main.rs:4:18", "  |", "4 |     let x: i32 = \"a\";",
    "  |            ---   ^^^ expected `i32`, found `&str`", "  |            |",
    "  |            expected due to this", "",
    "For more information about this error, try `rustc --explain E0308`.",
    "error: could not compile `probe` (bin \"probe\") due to 1 previous error"]

/-- The checks of the shipped error formats (`Editor/Compile/Shipped.lean`,
"The formats"): pure, with no driver. -/
def projectFormatChecks : List Check :=
  let general := Compile.Format.general
  [{  name :=
        "modes criterion 3: rustc's format finds error[E0308]: mismatched types followed by   --> src/main.rs:4:18 as one location at src/main.rs line 4 column 18, severity error, with the message mismatched types"
      run :=
        pure
          (Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0
              #["error[E0308]: mismatched types", "  --> src/main.rs:4:18"] ==
            #[{ file := "/c/src/main.rs", line := 4, column := some 18, columnBase := 1
                severity := .error, format := "rustc", first := 1, last := 2, start := 37
                stop := 53, message := some "mismatched types" }]) },
    { name :=
        "rustc's location line scanned alone after its lead in an earlier post gives the same site; a warning's lead gives a warning with its message; the snippet joins the site up to the blank line; and the general format reads none of rustc's lines"
      run :=
        let alone :=
          Compile.scan #[Compile.rustcFormat] "/c"
            (Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0 #["error[E0308]: mismatched types"]) 2
            31 #["  --> src/main.rs:4:18"] (previous := some "error[E0308]: mismatched types")
        let warned :=
          Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0
            #["warning: unused variable: `y`", " --> src/main.rs:2:9"]
        let whole := Compile.scan #[Compile.rustcFormat, general] "/c" #[] 1 0 rustcLines
        pure
          (alone ==
              Compile.scan #[Compile.rustcFormat] "/c" #[] 1 0
                #["error[E0308]: mismatched types", "  --> src/main.rs:4:18"] &&
            warned.map (fun site => (site.severity, site.line, site.column, site.message)) ==
              #[(.warning, 2, some 9, some "unused variable: `y`")] &&
            whole.map (fun site => (site.file.toString, site.first, site.last, site.message)) ==
              #[("/c/src/main.rs", 1, 7, some "mismatched types")] &&
            (rustcLines.push "   ::: src/lib.rs:3:5").all (general.read? · == none)) },
    { name :=
        "modes criterion 4: Lean's format finds error: ./Foo/Bar.lean:12:4: unknown identifier 'x' at Foo/Bar.lean line 12 column 4, counting columns from 0, and the same line with warning: as a warning"
      run :=
        let line := "error: ./Foo/Bar.lean:12:4: unknown identifier 'x'"
        let warning := "warning: ./Foo/Bar.lean:12:4: unknown identifier 'x'"
        pure
          (Compile.leanFormat.read? line ==
              some
                { file := "./Foo/Bar.lean", line := 12, column := some 4, severity := .error
                  start := 7, stop := 26, message := some "unknown identifier 'x'" } &&
            (Compile.scan #[Compile.leanFormat] "/l" #[] 1 0 #[line]).map
                (fun site => (site.file.toString, site.line, site.column, site.columnBase)) ==
              #[("/l/Foo/Bar.lean", 12, some 4, 0)] &&
            (Compile.leanFormat.read? warning).map (·.severity) == some .warning) },
    { name :=
        "Lean's format reads info: as a note and Lake's form with no ./, and reads none of Lake's other lines; the general format reads none of Lake's lines"
      run :=
        let lake :=
          #["✖ [2/4] Building Foo.Bar (156ms)", "error: Foo/Bar.lean:13:6: Unknown identifier `x`",
            "warning: Foo/Bar.lean:14:7: Variable name `y` is not explicitly referenced.",
            "info: Foo/Bar.lean:14:0: 1", "Some required targets logged failures:", "- Foo.Bar",
            "error: build failed"]
        pure
          ((Compile.leanFormat.read? "info: Foo/Bar.lean:14:0: 1").map (·.severity) == some .note &&
            (lake.filterMap Compile.leanFormat.read?).map
                (fun reading => (reading.file, reading.line, reading.severity)) ==
              #[("Foo/Bar.lean", 13, .error), ("Foo/Bar.lean", 14, .warning),
                ("Foo/Bar.lean", 14, .note)] &&
            (lake.push "error: ./Foo/Bar.lean:12:4: unknown identifier 'x'").all
              (general.read? · == none)) }]

/-- What `mise tasks ls --json` prints in `/m` in the project checks: three
tasks with the real listing's shape, `build` and `test` in `/m` and `lint`
in `/m/sub`, each with fields of every JSON kind besides its name and
directory. -/
def miseListing : String :=
  "[\n  {\n    \"name\": \"build\",\n    \"aliases\": [],\n    \"description\": \"\",\n    \"source\": \"/m/mise.toml\",\n    \"depends\": [],\n    \"dir\": \"/m\",\n    \"hide\": false,\n    \"raw\": false,\n    \"sources\": [],\n    \"outputs\": [],\n    \"shell\": null,\n    \"quiet\": false,\n    \"silent\": false,\n    \"tools\": {},\n    \"run\": [\"lake build\"],\n    \"file\": null\n  },\n  {\"name\": \"test\", \"dir\": \"/m\", \"depends\": [\"build\"], \"hide\": false, \"timeout\": 1.5e2, \"env\": {\"A\": \"1\"}, \"run\": [\"lake test\"]},\n  {\"name\": \"lint\", \"dir\": \"/m/sub\", \"depends\": [], \"hide\": false, \"usage\": {\"spec\": {\"args\": [[1, -2.5], true]}}}\n]\n"

/-- The checks of the JSON reader (`Editor/Json.lean`): pure. -/
def jsonChecks : List Check :=
  let parsed (text : String) : Option Json.Value := (Json.parse text.toUTF8).toOption
  let refusal (text : String) : Option String :=
    match Json.parse text.toUTF8 with
    | .error why => some why
    | .ok _ => none
  [{  name :=
        "the JSON reader reads nested arrays and objects in order, escapes, numbers as their text, true, false and null, with whitespace around them"
      run :=
        pure
          (parsed
                " {\"a\": [1, -2.50, 3e+2, {\"b\": null}], \"s\": \"x\\\"y\\u00e9\\n\", \"t\": true, \"f\": false, \"a\": []} " ==
              some
                (.object
                  #[("a",
                      .array
                        #[.number "1", .number "-2.50", .number "3e+2", .object #[("b", .null)]]),
                    ("s", .string "x\"yé\n"), ("t", .bool true), ("f", .bool false),
                    ("a", .array #[])]) &&
            (parsed "{\"a\": 1, \"a\": 2}").bind (·.field? "a") == some (.number "1") &&
            parsed "[]" == some (.array #[]) &&
            parsed "\"é\"" == some (.string "é")) },
    { name :=
        "the JSON reader refuses trailing text, an unclosed array, an unclosed object, a bare word, a number with no digits, an empty document and what is not UTF-8, saying why"
      run :=
        pure
          (refusal "[1] x" == some "there is more after the value" &&
            refusal "[1, 2" == some "an array is not closed" &&
            refusal "{\"a\": 1" == some "an object is not closed" &&
            refusal "nope" == some "nope is not a JSON value" &&
            refusal "-" == some "a number has no digits" &&
            refusal "  " == some "a value is missing" &&
            (match Json.parse (ByteArray.mk #[0xff]) with
            | .error why => why == "it is not UTF-8"
            | .ok _ => false)) },
    { name :=
        "mise's task list gives one command per task, mise run and the task's name, in the task's dir, in the order listed: build and test in /m, lint in /m/sub; an empty list gives none"
      run :=
        pure
          ((Compile.miseTasks miseListing.toUTF8).toOption.map
                (·.map fun command =>
                  (command.name, command.line, command.directory.map (·.toString))) ==
              some
                #[("build", "mise run build", some "/m"), ("test", "mise run test", some "/m"),
                  ("lint", "mise run lint", some "/m/sub")] &&
            (Compile.miseTasks "[]".toUTF8).toOption.map (·.size) == some 0) },
    { name :=
        "a task's name that is not a bare shell word is quoted: my task gives mise run 'my task', it's gives mise run 'it'\\''s; a name listed twice keeps its first, and a task with an empty dir has none"
      run :=
        let listing :=
          "[{\"name\": \"my task\", \"dir\": \"\"}, {\"name\": \"it's\"}, {\"name\": \"my task\", \"dir\": \"/x\"}, {\"name\": \"a:b/c@d%e+f=g,h_i-j.k\"}]"
        pure
          ((Compile.miseTasks listing.toUTF8).toOption.map
                (·.map fun command =>
                  (command.name, command.line, command.directory.map (·.toString))) ==
              some
                #[("my task", "mise run 'my task'", none), ("it's", "mise run 'it'\\''s'", none),
                  ("a:b/c@d%e+f=g,h_i-j.k", "mise run a:b/c@d%e+f=g,h_i-j.k", none)] &&
            Compile.shellWord "" == "''" &&
            Compile.shellWord "a$b" == "'a$b'") },
    { name :=
        "mise's task list is refused when it is not an array, a task is not an object, a task has no name or an empty one, or it is no JSON, saying why"
      run :=
        let refused (text : String) : Option String :=
          match Compile.miseTasks text.toUTF8 with
          | .error why => some why
          | .ok _ => none
        pure
          (refused "{}" == some "it is not an array" &&
            refused "[{\"name\": \"a\"}, 3]" == some "task 2 is not an object" &&
            refused "[{\"name\": \"a\"}, {\"dir\": \"/m\"}]" == some "task 2 has no name" &&
            refused "[{\"name\": \"\"}]" == some "task 1 has no name" &&
            refused "[{\"name\": 1}]" == some "task 1 has no name" &&
            refused "[" == some "a value is missing") }]

/-- What `t-mode`'s listing prints, read: one command a line, `name=line`
or `name=line=directory`. -/
def tRead (bytes : ByteArray) : Except String (Array Compile.NamedCommand) := do
  let some text := String.fromUTF8? bytes | throw "it is not UTF-8"
  ((text.splitOn "\n").filter (!·.isEmpty)).toArray.mapM fun line =>
      match line.splitOn "=" with
      | [name, line] => pure { name, line }
      | [name, line, directory] => pure { name, line, directory := some directory }
      | _ => throw s!"{line} is no command"

/-- The contribution of the listing checks: `t-mode` on `t.toml`, with the
commands `build` (`t-fixed-build`) and `check` (`t-check`), and its listing
`t-list`, read by `tRead`. -/
def tContribution : Compile.Contribution :=
  { mode := "t-mode", markers := #["t.toml"]
    commands :=
      #[{ name := "build", line := "t-fixed-build" }, { name := "check", line := "t-check" }]
    listing := some { program := "t-list", read := tRead } }

/-- The listing `t-list` in `directory`. -/
def tList (directory : System.FilePath) : Process.Command :=
  { program := "t-list", directory }

/-- The world of the listing checks: the repositories `/t` and `/t2`, each
holding `t.toml`, and `/u`, a directory holding `t.toml` in no
repository. -/
def listingWorld : Workspace.World :=
  { repositories :=
      #[{ toplevel := "/t", commonDir := "/t/.git" },
        { toplevel := "/t2", commonDir := "/t2/.git" }]
    markerDirectories := #["/t/.git", "/t2/.git"]
    markers := #["/t/t.toml", "/t2/t.toml", "/u/t.toml"] }

/-- The bindings of the listing checks: the hook checks', and `C-p 1`,
`C-p 2`, `C-p 3` and `C-p 4`, which open `/t/a.txt`, `/t/b.txt`,
`/t2/a.txt` and `/u/a.txt`. -/
def listingBindings : List (String × Invocation) :=
  hookBindings ++
    [("C-p 1", opens "/t/a.txt"), ("C-p 2", opens "/t/b.txt"), ("C-p 3", opens "/t2/a.txt"),
      ("C-p 4", opens "/u/a.txt")]

/-- What each run of the listing checks does: `t-list` in `/t` lists
`build`, `fmt` and `sub`, in `sub`; in `/t2` it fails; in `/u` it lists
`u-only`. -/
def listingScripts : Array Process.Script :=
  #[{ command := tList "/t", reply := shellReply "build=t-build\nfmt=t-fmt\nsub=t-sub=sub\n" },
    { command := tList "/t2", reply := shellReply "" "t-list: broken\nmore\n" (.code 3) },
    { command := tList "/u", reply := shellReply "u-only=u-only\n" }]

/-- The streaming children of the listing checks. -/
def listingStreams : Array Process.StreamScript :=
  #[{ command := shellCommand "/t" "t-build", steps := linesSteps ["ok"] },
    { command := shellCommand "/t/sub" "t-sub", steps := linesSteps ["ok"] },
    { command := shellCommand "/u" "u-only", steps := linesSteps ["ok"] }]

/-- A driver of the listing checks over `registry`, by default `t-mode`
registered in config: the world of `listingWorld`, with its bindings, the
compile checks' jobs, its files, runs and children; `none` if making the
state was refused. -/
def listingDriver (registry : Config.Registry := hookRegistry (compileContribution tContribution)) :
    Option TestDriver :=
  let model := listingWorld.jobModel "git" #["/t", "/t2", "/u"]
  let files :=
    [("/t/a.txt", "a"), ("/t/b.txt", "b"), ("/t2/a.txt", "a"), ("/u/a.txt", "a")].foldl
      (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) model.files
  let keys := compileKeysOf listingBindings
  let keys := { keys with registered := { keys.registered with compile := registry.compileHook } }
  (Loop.Driver.over keys compileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver =>
    { driver with
      jobs :=
        { model with
          files
          processes :=
            { model.processes with
              scripts := model.processes.scripts ++ listingScripts, streams := listingStreams } } }

/-- How many times `driver` has started `command`. -/
def startedCount (driver : TestDriver) (command : Process.Command) : Nat :=
  (driver.jobs.processes.started.filter (· == command)).size

/-- `driver` once every pending job not called `name` is finished, oldest
first, with those they start; bounded. -/
def settledBut (driver : TestDriver) (name : String) : TestDriver :=
  (List.range 8).foldl
    (fun driver _ =>
      match driver.pending.find? (·.name != name) with
      | some job => (driver.finish job.id).1
      | none => driver)
    driver

/-- The checks of a contribution's computed commands
(`Editor/Compile/Listing.lean`), on the loop's driver over the editor's
models, the job model and the process model, with `t-mode`. -/
def listingChecks : List Check :=
  [{  name :=
        "turning t-mode on runs its listing t-list in its root once, after find-mode-markers; a second file under the root starts compile-list again and runs nothing"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let (first, names) := settledNames driver "C-p 1"
            let (second, again) := settledNames first "C-p 2"
            shownOnModes first == some #[{ mode := "t-mode", root := "/t" }] &&
              names.filter (fun name => name == Workspace.markerJob || name == Compile.listJob) ==
                #[Workspace.markerJob, Compile.listJob] &&
              startedCount first (tList "/t") == 1 &&
              again.contains Compile.listJob &&
              startedCount second (tList "/t") == 1 &&
              (Compile.entriesOf second.loop.state (some (.local "/t"))).size == 1 },
    { name :=
        "compile-command offers the listed commands after the contribution's own, a listed name in place of its own: build runs t-build in /t, and sub, listed in sub, runs t-sub in /t/sub"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 1"
            let asked := pressedOn opened "C-k i"
            let built := drained (fedTo opened (exLine "compile-command build")).1
            let subbed := drained (fedTo opened (exLine "compile-command sub")).1
            (candidatesOf asked).map (·.all) ==
                some #["build (t-mode)", "check (t-mode)", "fmt (t-mode)", "sub (t-mode)"] &&
              built.jobs.processes.started.back? == some (shellCommand "/t" "t-build") &&
              subbed.jobs.processes.started.back? == some (shellCommand "/t/sub" "t-sub") &&
              startedCount subbed (tList "/t") == 1 },
    { name :=
        "offers puts a mode's listed commands after its own, a listed name in place of its own, and a project's command in place of a listed one; a listed directory resolves against the root and an absolute one is kept"
      run :=
        let listed (mode : String) (root : System.FilePath) : Array Compile.NamedCommand :=
          if mode == "t-mode" && root == "/t" then
            #[{ name := "build", line := "t-build" }, { name := "fmt", line := "t-fmt" },
              { name := "sub", line := "t-sub", directory := some "sub" },
              { name := "abs", line := "t-abs", directory := some "/elsewhere" }]
          else #[]
        let project : Array Compile.ProjectCommands :=
          #[{ project := .remote "github.com/o/r", mode := "t-mode"
              commands := #[{ name := "fmt", line := "p-fmt" }] }]
        let offer (name line : String) (root : System.FilePath := "/t") : Compile.Offer :=
          { mode := "t-mode", name, line, root }
        pure
          (Compile.offers #[tContribution] project #[{ mode := "t-mode", root := "/t" }] listed ==
              #[offer "build" "t-build", offer "check" "t-check", offer "fmt" "p-fmt",
                offer "sub" "t-sub" "/t/sub", offer "abs" "t-abs" "/elsewhere"] &&
            Compile.offers #[tContribution] #[] #[{ mode := "t-mode", root := "/t2" }] listed ==
              #[offer "build" "t-fixed-build" "/t2", offer "check" "t-check" "/t2"]) },
    { name :=
        "a listing that fails offers none of its commands and says why once, with its first line of standard error"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 3"
            let asked := settledAfter opened "C-k i"
            echoOf opened == some "t-mode in /t2: t-list exited with status 3: t-list: broken" &&
              (candidatesOf asked).map (·.all) == some #["build (t-mode)", "check (t-mode)"] &&
              startedCount asked (tList "/t2") == 1 },
    { name :=
        "a listing that could not be run, as mise is not found by an editor started from the Finder, offers none of its commands and says why once"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let refused : Process.Script :=
              { command := tList "/t2", reply := .error (.notFound "t-list") }
            let driver :=
              { driver with
                jobs :=
                  { driver.jobs with
                    processes :=
                      { driver.jobs.processes with
                        scripts := #[refused] ++ driver.jobs.processes.scripts } } }
            let opened := settledAfter driver "C-p 3"
            let asked := settledAfter opened "C-k i"
            echoOf opened ==
                some
                  "t-mode in /t2: t-list could not be run: the program or the directory is not there: t-list" &&
              (candidatesOf asked).map (·.all) == some #["build (t-mode)", "check (t-mode)"] &&
              startedCount asked (tList "/t2") == 1 },
    { name :=
        "each end of a listing's run has its own words: a status with its first line of standard error, a status whose first line is empty, a signal, output its read refuses, a run that ran out of time, and one that could not be run"
      run :=
        let order : Compile.ListOrder :=
          { place := none, mode := "mise-mode", root := "/m", generation := 0, markers := #[]
            held := none, program := "mise", programArguments := #["tasks", "ls", "--json"] }
        let say := Compile.outcomeOf order tRead
        pure
          (say (shellReply "" "not trusted\nmore\n" (.code 1)) ==
              .failed "mise tasks ls --json exited with status 1: not trusted" &&
            say (shellReply "" "" (.code 2)) ==
              .failed "mise tasks ls --json exited with status 2" &&
            say (shellReply "" "\nsecond\n" (.code 2)) ==
              .failed "mise tasks ls --json exited with status 2" &&
            say (shellReply "" "" (.signal 9)) ==
              .failed "mise tasks ls --json was ended by signal 9" &&
            say (shellReply "nope\n") ==
              .failed "mise tasks ls --json printed no list of commands: nope is no command" &&
            say (.error (.timedOut 10000)) ==
              .failed "mise tasks ls --json did not finish within 10000 ms and was killed" &&
            say (.error (.denied "Permission denied")) ==
              .failed
                "mise tasks ls --json could not be run: the system does not allow it: Permission denied" &&
            say (shellReply "a=b\n") == .listed #[{ name := "a", line := "b" }]) },
    { name :=
        "with t-mode dropped from the hook before its listing job's command runs, the command keeps no entry"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let waiting := settledBut (fedTo driver (presses "C-p 1")).1 Compile.listJob
            let dropped :=
              { waiting with
                keys :=
                  { waiting.keys with
                    registered := { waiting.keys.registered with compile := {} } } }
            let listed :=
              match dropped.pending.find? (·.name == Compile.listJob) with
              | some job => (dropped.finish job.id).1
              | none => dropped
            startedCount listed (tList "/t") == 1 &&
              (Compile.entriesOf listed.loop.state (some (.local "/t"))).isEmpty },
    { name :=
        "a file in a directory holding t.toml and no repository has t-mode on there: its listing runs there once, is kept in the unscoped store, and compile-command offers and runs what it lists"
      run :=
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 4"
            let asked := settledAfter opened "C-k i"
            let ran := drained (fedTo opened (exLine "compile-command u-only")).1
            (shownWorkspace opened).isNone &&
              shownOnModes opened == some #[{ mode := "t-mode", root := "/u" }] &&
              startedCount asked (tList "/u") == 1 &&
              (Compile.entriesOf opened.loop.state none).map
                  (fun entry => (entry.mode, entry.root.toString)) ==
                #[("t-mode", "/u")] &&
              (candidatesOf asked).map (·.all) ==
                some #["build (t-mode)", "check (t-mode)", "u-only (t-mode)"] &&
              ran.jobs.processes.started.back? == some (shellCommand "/u" "u-only") },
    { name :=
        "in a workspace whose location cannot run commands no listing is started when t-mode turns on, and compile-command offers nothing"
      run :=
        let reachable := Location.reachable "kube" "pod" "/app"
        pure <|
          match listingDriver with
          | none => false
          | some driver =>
            let waiting := settledBut (fedTo driver (presses "C-p 1")).1 Workspace.markerJob
            let moved := settledOn (pressedOn waiting "C-e k") []
            let asked := pressedOn moved "C-k i"
            !reachable.can.runCommands &&
              (shownWorkspace moved).map (·.1.location) == some reachable &&
              shownOnModes moved == some #[{ mode := "t-mode", root := "/t" }] &&
              startedCount asked (tList "/t") == 0 &&
              !(asked.pending.any (·.name == Compile.listJob)) &&
              asked.loop.state.prompt.isNone &&
              (echoOf asked).map (·.endsWith "where commands cannot run") == some true },
    { name :=
        "a listing order and an entry cross as arguments and as a tree and back, and arguments that are no order read as none; the listing job started with them fails"
      run :=
        let stamp : File.Stamp := { seconds := -3, nanoseconds := 4, size := 5 }
        let orders : List Compile.ListOrder :=
          [{ place := some (.local "/t"), mode := "t-mode", root := "/t/a", generation := 2,
             markers := #["t.toml", "u.toml"], held := some #[some stamp, none],
             program := "t-list", programArguments := #["a", "b c"] },
            { place := none, mode := "m", root := "/x", generation := 0, markers := #[],
              held := none
              program := "p", programArguments := #[] },
            { place := some (.reachable "kube" "pod" "/app"), mode := "m", root := "/app",
              generation := 1, markers := #["m.toml"], held := none, program := "p"
              programArguments := #["q"] }]
        let entries : Array Compile.Listing.Entry :=
          #[{ mode := "t-mode", root := "/t", generation := 1, stamps := #[some stamp, none],
              outcome :=
                .listed
                  #[{ name := "a", line := "x" },
                    { name := "b", line := "y", directory := some "s" }] },
            { mode := "u", root := "/u", generation := 0, stamps := #[], outcome := .failed "why" }]
        pure
          (orders.all (fun order => Compile.ListOrder.ofArguments? order.arguments == some order) &&
            [[], [.str "unscoped", .str "m"],
                  [.str "unscoped", .str "m", .str "/x", .nat 0, .nat 1],
                  [.str "workspace", .str "/t", .str "m", .str "/x", .nat 0, .nat 0, .bool false,
                    .str "p"]].all
              (Compile.ListOrder.ofArguments? · == none) &&
            Compile.listingStore.decode (Compile.listingStore.encode entries) == some entries &&
            Compile.listingStore.name == "compile-listings" &&
            ((Compile.listWork [.nat 1] ()).runModel {}).1 matches .failed _) }]

/-- The world of the project mode checks: repositories `/c` (Cargo), `/l`
(Lake), `/m` (mise, with a crate in `/m/crate`), `/mw`, a worktree of `/m`'s
repository on `feature`, and `/r2`, a Cargo workspace with a member crate in
`/r2/crates/m`; and their marker files. -/
def projectWorld : Workspace.World :=
  { repositories :=
      #[{ toplevel := "/c", commonDir := "/c/.git" }, { toplevel := "/l", commonDir := "/l/.git" },
        { toplevel := "/m", commonDir := "/m/.git" },
        { toplevel := "/mw", commonDir := "/m/.git", branch := some "feature" },
        { toplevel := "/r2", commonDir := "/r2/.git" }]
    markerDirectories := #["/c/.git", "/l/.git", "/m/.git", "/r2/.git"]
    markers :=
      #["/c/Cargo.toml", "/l/lakefile.lean", "/m/mise.toml", "/m/crate/Cargo.toml", "/mw/mise.toml",
        "/r2/Cargo.toml", "/r2/crates/m/Cargo.toml"] }

/-- The bindings of the project mode checks: the listing checks', and `C-p
c`, `C-p l`, `C-p m`, `C-p n`, `C-p w` and `C-p r`, which open
`/c/src/main.rs`, `/l/Foo/Bar.lean`, `/m/notes.txt`, `/m/crate/src/main.rs`,
`/mw/notes.txt` and `/r2/crates/m/src/main.rs`. Test-scheme chords only. -/
def projectBindings : List (String × Invocation) :=
  listingBindings ++
    [("C-p c", opens "/c/src/main.rs"), ("C-p l", opens "/l/Foo/Bar.lean"),
      ("C-p m", opens "/m/notes.txt"), ("C-p n", opens "/m/crate/src/main.rs"),
      ("C-p w", opens "/mw/notes.txt"), ("C-p r", opens "/r2/crates/m/src/main.rs")]

/-- `mise tasks ls --json` in `directory`, as `mise-mode` runs it. -/
def miseList (directory : System.FilePath) : Process.Command :=
  { program := "mise", arguments := #["tasks", "ls", "--json"], directory }

/-- What each run of the project mode checks does: the listing in `/m`
prints `miseListing`, and in `/mw` one task, `wt-only`. -/
def projectScripts : Array Process.Script :=
  #[{ command := miseList "/m", reply := shellReply miseListing },
    { command := miseList "/mw",
      reply := shellReply "[{\"name\": \"wt-only\", \"dir\": \"/mw\"}]\n" }]

/-- The streaming children of the project mode checks: each line they run,
writing `ok`. -/
def projectStreams : Array Process.StreamScript :=
  #[("/c", "cargo clippy"), ("/l", "lake test"), ("/m", "mise run build"), ("/m", "mise run test"),
        ("/m/sub", "mise run lint"), ("/m", "mise run fmt")].map
    fun (directory, line) => { command := shellCommand directory line, steps := linesSteps ["ok"] }

/-- The registry of the project mode checks: the shipped contributions,
for the owner `compiled`, and no config. -/
def projectRegistry : Config.Registry :=
  hookRegistry (pure ()) Compile.shipped

/-- A driver of the project mode checks over `registry`: the world of
`projectWorld`, with its bindings, the compile checks' jobs, its files, runs
and children; `none` if making the state was refused. -/
def projectDriver (registry : Config.Registry := projectRegistry) : Option TestDriver :=
  let model :=
    projectWorld.jobModel "git"
      #["/c/src", "/l/Foo", "/m", "/m/crate/src", "/mw", "/r2/crates/m/src"]
  let files :=
    [("/c/src/main.rs", "fn main() {}\n"), ("/l/Foo/Bar.lean", "x\n"), ("/m/notes.txt", "n\n"),
          ("/m/crate/src/main.rs", "fn main() {}\n"), ("/mw/notes.txt", "w\n"),
          ("/r2/crates/m/src/main.rs", "fn main() {}\n")].foldl
      (fun (files : FileModel) (path, text) => files.withFile path text.toUTF8) model.files
  let keys := compileKeysOf projectBindings
  let keys := { keys with registered := { keys.registered with compile := registry.compileHook } }
  (Loop.Driver.over keys compileJobs (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver =>
    { driver with
      jobs :=
        { model with
          files
          processes :=
            { model.processes with
              scripts := model.processes.scripts ++ projectScripts, streams := projectStreams } } }

/-- `driver` once the loop is told the next config generation, as a reload
tells it. -/
def reloaded (driver : TestDriver) : TestDriver :=
  { driver with
    keys :=
      { driver.keys with
        registered :=
          { driver.keys.registered with generation := driver.keys.registered.generation + 1 } } }

/-- The candidates `compile-command`'s prompt offers in `driver` once
`keys` are pressed and their jobs settled. -/
def offeredAfter (driver : TestDriver) (keys : String) : Option (Array String) :=
  (candidatesOf (settledAfter driver keys)).map (·.all)

/-- The checks of the shipped modes (`Editor/Compile/Shipped.lean`), on the
loop's driver over the editor's models, the job model and the process
model, in the world of `projectWorld`, with only the shipped contributions
registered. -/
def projectModeChecks : List Check :=
  [{  name :=
        "modes criterion 1: a buffer under a Cargo.toml has cargo-mode on with that root, one under a lakefile.lean lake-mode, one under a mise.toml mise-mode, and one in a Cargo crate inside a mise project both, the crate's first"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let modesOf (keys : String) :=
              let opened := settledAfter driver keys
              (shownOnModes opened, shownMinors opened)
            modesOf "C-p c" ==
                (some #[{ mode := "cargo-mode", root := "/c" }], some #["cargo-mode"]) &&
              modesOf "C-p l" ==
                (some #[{ mode := "lake-mode", root := "/l" }], some #["lake-mode"]) &&
              modesOf "C-p m" ==
                (some #[{ mode := "mise-mode", root := "/m" }], some #["mise-mode"]) &&
              modesOf "C-p n" ==
                (some
                    #[{ mode := "cargo-mode", root := "/m/crate" },
                      { mode := "mise-mode", root := "/m" }],
                  some #["cargo-mode", "mise-mode"]) },
    { name :=
        "lakefile.toml turns lake-mode on and .mise.toml mise-mode; cargo-mode's root is its outermost Cargo.toml, so in a member crate of /r2 it is /r2"
      run :=
        let markerModes := Compile.shipped.map (·.markerMode)
        pure <|
          Workspace.onModes markerModes "/x/a" "/x"
                #[("/x", "lakefile.toml"), ("/x/a", ".mise.toml")] ==
              #[{ mode := "mise-mode", root := "/x/a" }, { mode := "lake-mode", root := "/x" }] &&
            match projectDriver with
            | none => false
            | some driver =>
              shownOnModes (settledAfter driver "C-p r") ==
                some #[{ mode := "cargo-mode", root := "/r2" }] },
    { name :=
        "modes criterion 2: cargo-mode offers build, test and clippy as compile-command candidates, and clippy runs cargo clippy in /c; lake-mode offers build and test, and test runs lake test in /l"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let cargo := settledAfter driver "C-p c"
            let lake := settledAfter driver "C-p l"
            let clippy := (fedTo cargo (exLine "compile-command clippy")).1
            let tested := (fedTo lake (exLine "compile-command test")).1
            offeredAfter cargo "C-k i" ==
                some #["build (cargo-mode)", "test (cargo-mode)", "clippy (cargo-mode)"] &&
              clippy.jobs.processes.started.back? == some (shellCommand "/c" "cargo clippy") &&
              offeredAfter lake "C-k i" == some #["build (lake-mode)", "test (lake-mode)"] &&
              tested.jobs.processes.started.back? == some (shellCommand "/l" "lake test") },
    { name :=
        "the shipped contributions offer exactly cargo build, cargo test and cargo clippy in a Cargo root, and lake build and lake test in a Lake root, each in its mode's root"
      run :=
        let offer (mode name line : String) (root : System.FilePath) : Compile.Offer :=
          { mode, name, line, root }
        pure
          (Compile.offers Compile.shipped #[] #[{ mode := "cargo-mode", root := "/c" }] ==
              #[offer "cargo-mode" "build" "cargo build" "/c",
                offer "cargo-mode" "test" "cargo test" "/c",
                offer "cargo-mode" "clippy" "cargo clippy" "/c"] &&
            Compile.offers Compile.shipped #[] #[{ mode := "lake-mode", root := "/l" }] ==
              #[offer "lake-mode" "build" "lake build" "/l",
                offer "lake-mode" "test" "lake test" "/l"] &&
            (Compile.formatsOf Compile.shipped
                    #[{ mode := "cargo-mode", root := "/c" }, { mode := "mise-mode", root := "/m" },
                      { mode := "lake-mode", root := "/l" }]).map
                (·.name) ==
              #["rustc", "lean", "general"]) },
    { name :=
        "modes criterion 5: mise-mode turning on runs mise tasks ls --json in its root, once, after find-mode-markers, and offers mise run <task> for each task it lists, each in the task's dir"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let (opened, names) := settledNames driver "C-p m"
            let answered :=
              (fedTo (pressedOn opened "C-k i") ([.commit "test"] ++ presses "C-e y")).1
            let built := (fedTo opened (exLine "compile-command build")).1
            let linted := (fedTo opened (exLine "compile-command lint")).1
            let offer (name line : String) (root : System.FilePath) : Compile.Offer :=
              { mode := "mise-mode", name, line, root }
            names.filter (fun name => name == Workspace.markerJob || name == Compile.listJob) ==
                #[Workspace.markerJob, Compile.listJob] &&
              startedCount opened (miseList "/m") == 1 &&
              offeredAfter opened "C-k i" ==
                some #["build (mise-mode)", "test (mise-mode)", "lint (mise-mode)"] &&
              answered.jobs.processes.started.back? == some (shellCommand "/m" "mise run test") &&
              built.jobs.processes.started.back? == some (shellCommand "/m" "mise run build") &&
              linted.jobs.processes.started.back? == some (shellCommand "/m/sub" "mise run lint") &&
              Compile.offers Compile.shipped #[] #[{ mode := "mise-mode", root := "/m" }]
                  (Compile.listedCommands opened.loop.state (some (.local "/m"))) ==
                #[offer "build" "mise run build" "/m", offer "test" "mise run test" "/m",
                  offer "lint" "mise run lint" "/m/sub"] },
    { name :=
        "two worktrees list their own tasks: /mw runs its own listing in /mw and offers only wt-only, /m's offers are unchanged, and each listing is in its own workspace's store"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let inM := settledAfter driver "C-p m"
            let inW := settledAfter inM "C-p w"
            let back := settledAfter inW "C-p m"
            let state := back.loop.state
            (shownWorkspace inW).map (·.1.location) == some (.local "/mw") &&
              startedCount inW (miseList "/mw") == 1 &&
              offeredAfter inW "C-k i" == some #["wt-only (mise-mode)"] &&
              offeredAfter back "C-k i" ==
                some #["build (mise-mode)", "test (mise-mode)", "lint (mise-mode)"] &&
              (Compile.entriesOf state (some (.local "/m"))).map (·.root.toString) == #["/m"] &&
              (Compile.entriesOf state (some (.local "/mw"))).map (·.root.toString) == #["/mw"] &&
              (Compile.entriesOf state none).isEmpty },
    { name :=
        "modes criterion 6: a listing that fails offers no task and says why once: compile-command then says no mode gives commands, and its check runs nothing and says nothing; a list that is not one says so"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let failing :=
              withScript driver
                { command := miseList "/m", reply := shellReply "" "mise ERROR boom\n" (.code 1) }
            let opened := settledAfter failing "C-p m"
            let asked := pressedOn opened "C-k i"
            let settled := settledAfter opened "C-k i"
            let unread :=
              settledAfter
                (withScript driver { command := miseList "/m", reply := shellReply "{}" }) "C-p m"
            echoOf opened ==
                some
                  "mise-mode in /m: mise tasks ls --json exited with status 1: mise ERROR boom" &&
              asked.loop.state.prompt.isNone &&
              echoOf asked == some "compile-command: no mode gives commands in m@main" &&
              echoOf settled == some "compile-command: no mode gives commands in m@main" &&
              startedCount settled (miseList "/m") == 1 &&
              echoOf unread ==
                some
                  "mise-mode in /m: mise tasks ls --json printed no list of commands: it is not an array" },
    { name :=
        "modes criterion 7: after mise.toml's stamp changes, the next use of mise-mode lists the tasks again and the use after it offers the new list; with the stamps unchanged two uses list nothing, and after a reload the next use lists again"
      run :=
        pure <|
          match projectDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p m"
            let changed :=
              withScript (rewritten opened "/m/mise.toml" "[tasks.fmt]\n".toUTF8)
                { command := miseList "/m",
                  reply := shellReply "[{\"name\": \"fmt\", \"dir\": \"/m\"}]" }
            let used := settledAfter changed "C-k i"
            let again := settledAfter used "C-k q C-k i"
            let twice := settledAfter (settledAfter opened "C-k i") "C-k q C-k i"
            let afterReload := settledAfter (reloaded (settledAfter opened "C-k i C-k q")) "C-k i"
            startedCount used (miseList "/m") == 2 &&
              (candidatesOf used).map (·.all) ==
                some #["build (mise-mode)", "test (mise-mode)", "lint (mise-mode)"] &&
              (candidatesOf again).map (·.all) == some #["fmt (mise-mode)"] &&
              startedCount again (miseList "/m") == 2 &&
              startedCount twice (miseList "/m") == 1 &&
              startedCount afterReload (miseList "/m") == 2 }]

/-- The keys of the read-only checks: `C-r m` makes a buffer `ro` holding
`abc`, read-only, and shows it in the window; `C-r i` (`insert-x`) inserts
`x` at the window's cursors; `C-r d` (`delete-first`) deletes the first byte
of its text; `C-r u` (`undo`) undoes in the window's buffer; `C-r w`
(`write-w`) appends `w` to the buffer's text inside `writing`; and `C-r f`
(`write-fails`) appends `f` inside `writing` and is then refused there. -/
def readOnlyKeys : Loop.Keys TestScheme.scheme :=
  dispatchKeys
    [("C-r m", invoke "make-ro"), ("C-r i", invoke "insert-x"), ("C-r d", invoke "delete-first"),
      ("C-r u", invoke "undo"), ("C-r w", invoke "write-w"), ("C-r f", invoke "write-fails")]
    [("make-ro", fun call => do
        if let .ok made← createBuffer "ro" "abc" then
          discard <| made.setReadOnly true
          discard <| call.target.window.id.show made
        return none),
      ("insert-x", fun call => do
        call.target.insertAtSelections "x"
        return none),
      ("delete-first", fun call => do
        call.target.buffer.text.delete 0 1
        return none),
      ("undo", fun call => do
        discard <| call.target.window.buffer.undo
        return none),
      ("write-w", fun call => do
        call.target.window.buffer.writing do
            let text := call.target.buffer.text
            text.insert (← text.byteLength) "w"
        return none),
      ("write-fails", fun call => do
        call.target.window.buffer.writing do
            let text := call.target.buffer.text
            text.insert (← text.byteLength) "f"
            text.delete 9 99
        return none)]

/-- A driver of the read-only checks, with their keys and no job; `none` if
making the state was refused. -/
def readOnlyDriver : Option TestDriver :=
  (Loop.Driver.over readOnlyKeys (fun _ => none) (EditorState.initial ⟨640, 480⟩)
      editorModel).toOption

/-- The checks of read-only buffers (`Editor/State.lean`, "Buffers";
`Editor/Command/Dispatch.lean`, "Read-only buffers"), on the loop's driver
over the editor's models. -/
def readOnlyChecks : List Check :=
  [{  name :=
        "an insert, a delete and an undo in a read-only buffer each end the command as giving up: the text is as it was, the echo area says the buffer is read-only, and the buffer stays read-only"
      run :=
        pure <|
          match readOnlyDriver with
          | none => false
          | some driver =>
            let made := settledAfter driver "C-r m"
            let inserted := settledAfter made "C-r i"
            let deleted := settledAfter made "C-r d"
            let written := settledAfter made "C-r w"
            let undone := settledAfter written "C-r u"
            (showing made).bind (·.text) == some "abc" &&
              (showing made).map (·.buffer.readOnly) == some true &&
              (showing inserted).bind (·.text) == some "abc" &&
              echoOf inserted == some "insert-x: ro is read-only" &&
              (showing deleted).bind (·.text) == some "abc" &&
              echoOf deleted == some "delete-first: ro is read-only" &&
              (showing undone).bind (·.text) == some "abcw" &&
              echoOf undone == some "undo: ro is read-only" &&
              (showing undone).map (·.buffer.readOnly) == some true },
    { name :=
        "writing lets the owning command's own edit through and leaves the buffer read-only; a command refused inside writing is rolled back, the flag with it"
      run :=
        pure <|
          match readOnlyDriver with
          | none => false
          | some driver =>
            let made := settledAfter driver "C-r m"
            let written := settledAfter made "C-r w"
            let failed := settledAfter made "C-r f"
            (showing written).bind (·.text) == some "abcw" &&
              (showing written).map (·.buffer.readOnly) == some true &&
              (showing failed).bind (·.text) == some "abc" &&
              (showing failed).map (·.buffer.readOnly) == some true &&
              echoOf failed == some "write-fails: refused: bad range" },
    { name :=
        "a committed text into a read-only buffer is dropped, and the echo area says the buffer is read-only, with no command's name; into another buffer it is inserted"
      run :=
        pure <|
          match readOnlyDriver with
          | none => false
          | some driver =>
            let made := settledAfter driver "C-r m"
            let committed := (fedTo made [.commit "z"]).1
            let elsewhere := (fedTo driver [.commit "z"]).1
            (showing committed).bind (·.text) == some "abc" &&
              echoOf committed == some "ro is read-only" &&
              (showing elsewhere).bind (·.text) == some "z" }]

/-- The buffer called `name` in `driver`'s state, if there is one. -/
def excerptBufferNamed (driver : EvilDriver) (name : String) : Option Buffer := do
  driver.loop.state.buffer? (← driver.loop.state.findBuffer name)

/-- What the text of the buffer called `name` holds in `driver`'s text model,
read as a command reads it, so an excerpt text is caught up. -/
def excerptRead (driver : EvilDriver) (name : String) : Option String := do
  let buffer ← excerptBufferNamed driver name
  (buffer.text.read.runModel driver.model.texts).1.toOption

/-- The stamp of the file `one.txt` the excerpt buffer checks give source
buffer `one` (`excerptRegistrations`, `one-changed`). -/
def excerptStamp : File.Stamp :=
  ⟨0, 0, 14⟩

/-- The commands of the excerpt buffer checks, each a `Config.Registration`
evil's commands are handed beside: `make-ex` makes source buffers `one`
(`one\ntwo\nthree\n`) and `two` (`alpha\nbeta\n`) and an excerpt buffer `ex`
of the second row of the first and the first row of the second
(`two\n\nalpha\n`), and shows `ex` in the window; `edit-both` applies one
transaction to the window's text that inserts `X` in the first excerpt and
replaces the first byte of the second with `A`; `edit-both-fails` does that
and is then refused; `edit-one` inserts `Z` at the start of `one`'s text;
`show-one` shows `one` in the window; `two-ro` makes `two` read-only;
`make-unheld` makes an excerpt buffer `ex2` of a text no buffer holds and
shows it; `insert-x` inserts `x` at the window's cursors; `one-changed` has
`one` hold the file `one.txt`, at `excerptStamp`, and marks it changed on
disk, the user not told; `edit-redo` inserts `x` at the start of the
window's buffer and then redoes in it, saying `redo moved` unless the redo
answered nothing; `remove-one` removes `one`, which no window shows.
For the display checks (`excerptDisplayChecks`): `make-six` makes an
excerpt buffer `six` of six whole lines of two buffers, headed `h1` to
`h6`, and shows it; `make-overlap` gives `one` the span `4..7` in
`compilation.error`, makes an excerpt buffer `overlap` of `one` 0..8 and
4..14, which show `two` twice, gives it a span `0..1` of its own, sets the
last search to `w`, and shows it; `make-plain` shows a plain buffer `plain`
of `ex`'s text; and `float-five` floats a buffer `note`, unfocused, at the
position 5 of the window's view. -/
def excerptRegistrations : Array Config.Registration :=
  #[{ name := "make-ex"
      action :=
        .call fun call => do
          let .ok one ← createBuffer "one" "one\ntwo\nthree\n" | return
          let .ok two ← createBuffer "two" "alpha\nbeta\n" | return
          let .ok ex ←
            createExcerptBuffer "ex"
                #[{ buffer := one, start := 4, stop := 8, header := "one" },
                  { buffer := two, start := 0, stop := 6, header := "two" }] | return
          discard <| call.target.window.id.show ex },
    { name := "edit-both"
      action :=
        .call fun call =>
          discard <| call.target.buffer.text.apply TextContract.acrossBoth Origin.user },
    { name := "edit-both-fails"
      action :=
        .call fun call => do
          discard <| call.target.buffer.text.apply TextContract.acrossBoth Origin.user
          call.target.buffer.text.delete 9 99 },
    { name := "edit-one"
      action :=
        .call fun _ => do
          let some one ← findBuffer "one" | return
          discard <| one.insertAt 0 "Z" },
    { name := "show-one"
      action :=
        .call fun call => do
          let some one ← findBuffer "one" | return
          discard <| call.target.window.id.show one },
    { name := "two-ro"
      action :=
        .call fun _ => do
          let some two ← findBuffer "two" | return
          discard <| two.setReadOnly true },
    { name := "make-unheld"
      action :=
        .call fun call => do
          let free ← createText "free\n"
          let .ok ex ← createExcerptBufferOf "ex2" #[⟨free, 0, 5⟩] | return
          discard <| call.target.window.id.show ex },
    { name := "insert-x", action := .call fun call => call.target.insertAtSelections "x" },
    { name := "one-changed"
      action :=
        .call fun _ => do
          let some one ← findBuffer "one" | return
          discard <| one.attachFile "one.txt" excerptStamp .lf
          discard <| one.markChanged excerptStamp (some { excerptStamp with size := 15 }) false },
    { name := "edit-redo"
      action :=
        .call fun call => do
          discard <| call.target.window.buffer.insertAt 0 "x"
          let answer ← call.target.window.buffer.redo
          unless answer matches .ok none do
            message "redo moved" },
    { name := "remove-one"
      action :=
        .call fun _ => do
          let some one ← findBuffer "one" | return
          discard <| one.remove },
    { name := "make-six"
      action :=
        .call fun call => do
          let .ok first ← createBuffer "first" "one\ntwo\nthree\n" | return
          let .ok second ← createBuffer "second" "alpha\nbeta\nx\n" | return
          let ranges :=
            #[(first, 0, 4), (first, 4, 8), (first, 8, 14), (second, 0, 6), (second, 6, 11),
              (second, 11, 13)]
          let list :=
            ranges.mapIdx fun index (buffer, start, stop) =>
              { buffer, start, stop, header := s!"h{index + 1}" : BufferExcerpt }
          let .ok six ← createExcerptBuffer "six" list | return
          discard <| call.target.window.id.show six },
    { name := "make-overlap"
      action :=
        .call fun call => do
          let some one ← findBuffer "one" | return
          discard <| one.setSpans #[⟨4, 7, ⟨"compilation.error"⟩⟩]
          let .ok overlap ←
            createExcerptBuffer "overlap"
                #[{ buffer := one, start := 0, stop := 8 },
                  { buffer := one, start := 4, stop := 14 }] | return
          discard <| overlap.setSpans #[⟨0, 1, ⟨"own"⟩⟩]
          setLastSearch { pattern := "w", forward := true }
          discard <| call.target.window.id.show overlap },
    { name := "make-plain"
      action :=
        .call fun call => do
          let .ok plain ← createBuffer "plain" "two\n\nalpha\n" | return
          discard <| call.target.window.id.show plain },
    { name := "float-five"
      action :=
        .call fun call => do
          let .ok note ← createBuffer "note" "n" | return
          discard <| note.float (.position call.target.window.id 5) (focus := false) }]

/-- `driver` once the command `name` has run, as an invocation no key
yielded. -/
def excerptInvoked (driver : EvilDriver) (name : String) : EvilDriver :=
  (driver.stepped (driver.loop.invoke driver.handed { command := name })).1

/-- `driver` once each of `events` is taken off the queue, in order. -/
def excerptFed (driver : EvilDriver) (events : List Event) : EvilDriver :=
  events.foldl (fun driver event => (driver.feed { event, stamp := 0 }).1) driver

/-- A driver of the excerpt buffer checks: evil's keys and the commands of
`excerptRegistrations`, over an empty buffer, once `make-ex` has run, so
the window shows `ex` with its cursor at its start; `none` if making the
state was refused. -/
def excerptDriver : Option EvilDriver :=
  (evilDriver "|" (evilHanded excerptRegistrations)).map (excerptInvoked · "make-ex")

/-- The checks of excerpt buffers (`Editor/State.lean`, "Excerpt buffers";
`Editor/Command/Dispatch.lean`, "Read-only buffers and excerpt sources";
`Editor/Api.lean`, "Undo"), on the loop's driver over the editor's
models, with evil's keys. -/
def excerptBufferChecks : List Check :=
  [{  name :=
        "an edit typed in an excerpt buffer changes the source buffer's text at the mapped position, as one revision of the source traced to the user, and the excerpt buffer shows it"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let traced := do
              let one ← excerptBufferNamed typed "one"
              (one.text.trace 5 6 |>.runModel typed.model.texts).1.toOption
            excerptRead driver "ex" == some "two\n\nalpha\n" &&
              excerptRead typed "one" == some "one\ntXwo\nthree\n" &&
              excerptRead typed "ex" == some "tXwo\n\nalpha\n" &&
              excerptRead typed "two" == some "alpha\nbeta\n" &&
              traced == some #[⟨5, 6, .entry 1 Origin.user⟩] },
    { name :=
        "u in the excerpt buffer after a typed session restores the source buffer and the excerpt buffer, one step for the whole session, and C-r redoes it"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed :=
              evilFed (excerptFed (evilFed driver "l i") [.commit "X", .commit "Y"]) "<Escape>"
            let undone := evilFed typed "u"
            let redone := evilFed undone "C-r"
            excerptRead typed "one" == some "one\ntXYwo\nthree\n" &&
              excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead redone "one" == some "one\ntXYwo\nthree\n" &&
              excerptRead redone "ex" == some "tXYwo\n\nalpha\n" &&
              redone.loop.state.echo.isEmpty },
    { name :=
        "u in the excerpt buffer after the source was edited in its own buffer since is refused, saying so, and changes nothing"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let moved := excerptInvoked typed "edit-one"
            let undone := evilFed moved "u"
            excerptRead moved "one" == some "Zone\ntXwo\nthree\n" &&
              undone.loop.state.echo == Evil.sourceMovedSays "one" &&
              excerptRead undone "one" == some "Zone\ntXwo\nthree\n" &&
              excerptRead undone "ex" == some "tXwo\n\nalpha\n" },
    { name :=
        "C-r in the excerpt buffer after the source was edited in its own buffer since the undo is refused, saying so, and changes nothing"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let moved := excerptInvoked (evilFed typed "u") "edit-one"
            let redone := evilFed moved "C-r"
            excerptRead moved "one" == some "Zone\ntwo\nthree\n" &&
              redone.loop.state.echo == Evil.sourceMovedSays "one" &&
              excerptRead redone "one" == some "Zone\ntwo\nthree\n" &&
              excerptRead redone "ex" == some "two\n\nalpha\n" },
    { name :=
        "a redo in the excerpt buffer while an edit through it is pending answers nothing and keeps the edit, which the next u takes back"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let pending := excerptInvoked (evilFed typed "u") "edit-redo"
            let undone := evilFed pending "u"
            pending.loop.state.echo.isEmpty &&
              excerptRead pending "one" == some "one\nxtwo\nthree\n" &&
              excerptRead pending "ex" == some "xtwo\n\nalpha\n" &&
              excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" },
    { name :=
        "u in the excerpt buffer once a source buffer of its last step was removed says so, under the name the step recorded, and drops that step, so the next u undoes the older step over a live source"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let older := evilFed (excerptFed (evilFed driver "j j i") [.commit "Q"]) "<Escape>"
            let newer := evilFed (excerptFed (evilFed older "k k i") [.commit "X"]) "<Escape>"
            let removed := excerptInvoked newer "remove-one"
            let refused := evilFed removed "u"
            let undone := evilFed refused "u"
            let emptied := evilFed undone "u"
            excerptRead older "two" == some "Qalpha\nbeta\n" &&
              excerptRead newer "one" == some "one\nXtwo\nthree\n" &&
              (excerptBufferNamed removed "one").isNone &&
              refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              excerptRead refused "two" == some "Qalpha\nbeta\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead undone "two" == some "alpha\nbeta\n" &&
              emptied.loop.state.echo == Evil.nothingToUndo },
    { name :=
        "u in the excerpt buffer once one of the two sources of its last step was removed says so and drops that source from the step, so the next u undoes the step in the source left"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let removed := excerptInvoked (excerptInvoked driver "edit-both") "remove-one"
            let refused := evilFed removed "u"
            let undone := evilFed refused "u"
            excerptRead removed "two" == some "Alpha\nbeta\n" &&
              refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              excerptRead refused "two" == some "Alpha\nbeta\n" &&
              undone.loop.state.echo.isEmpty &&
              excerptRead undone "two" == some "alpha\nbeta\n" },
    { name :=
        "C-r in the excerpt buffer once the source buffer of the step to redo was removed says so and drops the step, so the next C-r has nothing to redo"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let removed := excerptInvoked (evilFed typed "u") "remove-one"
            let refused := evilFed removed "C-r"
            let emptied := evilFed refused "C-r"
            refused.loop.state.echo == Evil.sourceRemovedSays "one" &&
              emptied.loop.state.echo == Evil.nothingToRedo },
    { name := "u in the source buffer takes back an edit made through the excerpt buffer"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            let undone := evilFed (excerptInvoked typed "show-one") "u"
            excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" },
    { name :=
        "a command applying one transaction with an edit in each excerpt changes both source buffers, and one u restores both"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let edited := excerptInvoked driver "edit-both"
            let undone := evilFed edited "u"
            excerptRead edited "one" == some "one\ntXwo\nthree\n" &&
              excerptRead edited "two" == some "Alpha\nbeta\n" &&
              excerptRead undone "one" == some "one\ntwo\nthree\n" &&
              excerptRead undone "two" == some "alpha\nbeta\n" &&
              excerptRead undone "ex" == some "two\n\nalpha\n" &&
              undone.loop.state.echo.isEmpty },
    { name :=
        "a command that edits both sources through the excerpt buffer and then fails is rolled back in both, the echo area says the refusal and nothing more, and u then has nothing to undo"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let failed := excerptInvoked driver "edit-both-fails"
            let undone := evilFed failed "u"
            excerptRead failed "one" == some "one\ntwo\nthree\n" &&
              excerptRead failed "two" == some "alpha\nbeta\n" &&
              excerptRead failed "ex" == some "two\n\nalpha\n" &&
              failed.loop.state.echo == "edit-both-fails: refused: bad range" &&
              undone.loop.state.echo == Evil.nothingToUndo },
    { name :=
        "with source two read-only, a command editing both gives up saying so and neither source changes; a commit into the second excerpt is dropped saying so, and one into the first is inserted"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let readOnly := excerptInvoked driver "two-ro"
            let edited := excerptInvoked readOnly "edit-both"
            let second := excerptFed (evilFed readOnly "j j i") [.commit "Q"]
            let first := excerptFed (evilFed readOnly "i") [.commit "Q"]
            edited.loop.state.echo == "edit-both: two is read-only" &&
              excerptRead edited "one" == some "one\ntwo\nthree\n" &&
              excerptRead edited "two" == some "alpha\nbeta\n" &&
              second.loop.state.echo == "two is read-only" &&
              excerptRead second "two" == some "alpha\nbeta\n" &&
              excerptRead first "one" == some "one\nQtwo\nthree\n" },
    { name := "an excerpt over a text no buffer holds refuses an edit there, saying so"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let made := excerptInvoked driver "make-unheld"
            let edited := excerptInvoked made "insert-x"
            excerptRead made "ex2" == some "free\n" &&
              edited.loop.state.echo == "insert-x: ex2 reads a text no buffer holds" &&
              excerptRead edited "ex2" == some "free\n" },
    { name :=
        "a commit into an excerpt over a text no buffer holds is dropped, saying so, and changes nothing"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let made := excerptInvoked driver "make-unheld"
            let committed := excerptFed (evilFed made "i") [.commit "Q"]
            committed.loop.state.echo == EditorState.unheldReason "ex2" &&
              excerptRead committed "ex2" == some "free\n" },
    { name :=
        "with source one's file changed on disk unbeknown to the user, a command editing both sources through the excerpt buffer is superseded, saying so, and neither source changes; the change is then told, and the same command lands"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let changed := excerptInvoked driver "one-changed"
            let refused := excerptInvoked changed "edit-both"
            let landed := excerptInvoked refused "edit-both"
            refused.loop.state.echo == Files.changedOnDisk "one.txt" &&
              excerptRead refused "one" == some "one\ntwo\nthree\n" &&
              excerptRead refused "two" == some "alpha\nbeta\n" &&
              excerptRead refused "ex" == some "two\n\nalpha\n" &&
              excerptRead landed "one" == some "one\ntXwo\nthree\n" &&
              excerptRead landed "two" == some "Alpha\nbeta\n" },
    { name :=
        "with source one's file changed on disk unbeknown to the user, a commit into the first excerpt is dropped, saying so, and the change is then told, so the next commit is inserted"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let changed := excerptInvoked driver "one-changed"
            let refused := excerptFed (evilFed changed "i") [.commit "Q"]
            let landed := excerptFed refused [.commit "R"]
            refused.loop.state.echo == Files.changedOnDisk "one.txt" &&
              excerptRead refused "one" == some "one\ntwo\nthree\n" &&
              excerptRead refused "ex" == some "two\n\nalpha\n" &&
              excerptRead landed "one" == some "one\nRtwo\nthree\n" &&
              excerptRead landed "ex" == some "Rtwo\n\nalpha\n" },
    { name :=
        "the ranges a transaction changes are its runs of deletes and inserts in the text before, an insert's empty and changes that do nothing passed over"
      run :=
        pure <|
          Change.ranges TextContract.acrossBoth.changes == #[(1, 1), (5, 6)] &&
            Change.ranges #[.retain 2, .delete 0, .insert "", .retain 1] == #[] &&
            Change.ranges #[.delete 2, .insert "ab", .retain 3, .delete 1] == #[(0, 2), (5, 6)] &&
            Change.ranges #[.insert "a", .retain 0, .insert "b"] == #[(0, 0)] }]

/-- The header blocks `ex` of `excerptRegistrations` has, its headers `one`
and `two` before its excerpts' starts `first` and `second`. -/
def exHeaders (first second : Nat) : Array Block :=
  #[{ before := first, text := "one", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] },
    { before := second, text := "two", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] }]

/-- The view `view` of the last scene `driver` published. -/
def lastView (driver : EvilDriver) (view : ViewId := ⟨0⟩) : Option View := do
  (← driver.model.display.scenes.back?).views.find? (·.id == view)

/-- Of the window's view in the last scene of `driver`: its scroll anchor's
offset, the head of its selection's primary range, and whether the rows the
display model answers from its anchor, asked with its blocks, hold the
row of that head, also asked with them. -/
def blockedSeen (driver : EvilDriver) : Option (Nat × Nat × Bool) := do
  let shown ← lastView driver
  let #[marker] := shown.selections | none
  let program : EditorM (Nat × Nat × Bool) := do
    let .anchor anchor ← shown.scroll.text.marker shown.scroll | throw .noSuchMarker
    let .selection selection ← marker.text.marker marker | throw .noSuchMarker
    let some range := selection.ranges[selection.primary]? | throw .badSelection
    let area :=
      Scroll.Area.ofRect shown.snapshot shown.rect driver.model.display.cells.heights.status
        shown.padding shown.blocks
    let rows ← area.rows anchor.offset
    let own := (← area.rows range.head)[0]?
    return (anchor.offset, range.head, own.any rows.contains)
  (program.runModel driver.model).1.toOption

/-- The rectangle's top of the first view of the last scene of `driver`
that is not the window's: the float `float-five` opened. -/
def floatTop (driver : EvilDriver) : Option Nat := do
  let scene ← driver.model.display.scenes.back?
  return (← scene.views.find? (·.id != ⟨0⟩)).rect.y

/-- The checks of what a view of an excerpt buffer shows
(`Editor/ExcerptView.lean`; `Editor/Loop.lean`, "Decorations"; the follow
and the scroll commands over blocks, `Editor/Scroll.lean`, "Blocks"), on
the loop's driver over the editor's models, with evil's keys, and of the
pure functions that place what is drawn. -/
def excerptDisplayChecks : List Check :=
  [{  name :=
        "the headers of an excerpt list are a block in block-header before each excerpt's start, none for an empty header, zipped to the shorter of the list and the entries"
      run :=
        pure <|
          let placed : Array Excerpt.Placed := #[⟨0, 4, 4, 8⟩, ⟨5, 11, 0, 6⟩, ⟨12, 12, 3, 3⟩]
          let entries : Array Buffer.ExcerptEntry :=
            #[{ source := ⟨0⟩, header := "one" }, { source := ⟨1⟩ }]
          ExcerptView.headers placed entries ==
              #[{ before := 0, text := "one", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] }] &&
            ExcerptView.headers placed (entries.push { source := ⟨0⟩, header := "é" }) ==
              #[{ before := 0, text := "one", decorations := #[⟨0, 3, ExcerptView.headerFace⟩] },
                { before := 12, text := "é", decorations := #[⟨0, 2, ExcerptView.headerFace⟩] }] },
    { name :=
        "a source's spans are drawn at every excerpt of it, clipped to the excerpt and moved to where it is, and an empty excerpt draws none"
      run :=
        pure <|
          let face : FaceName := ⟨"f"⟩
          let overlap : Array Excerpt.Placed := #[⟨0, 8, 0, 8⟩, ⟨9, 19, 4, 14⟩]
          ExcerptView.translated overlap (fun _ => #[⟨4, 7, face⟩]) ==
              #[⟨4, 7, face⟩, ⟨9, 12, face⟩] &&
            ExcerptView.translated overlap (fun _ => #[⟨6, 10, face⟩]) ==
              #[⟨6, 8, face⟩, ⟨11, 15, face⟩] &&
            ExcerptView.translated #[⟨0, 0, 3, 3⟩, ⟨1, 3, 0, 2⟩] (fun _ => #[⟨0, 14, face⟩]) ==
              #[⟨1, 3, face⟩] &&
            ExcerptView.translated overlap
                (fun index => if index == 0 then #[] else #[⟨4, 5, face⟩]) ==
              #[⟨9, 10, face⟩] },
    { name :=
        "the published view of an excerpt buffer has a header block above each excerpt, read from the snapshot it shows: an edit before an excerpt in a source keeps them, and one typed in the first excerpt moves the second's"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let edited := excerptInvoked driver "edit-one"
            let typed := evilFed (excerptFed (evilFed driver "l i") [.commit "X"]) "<Escape>"
            (lastView driver).map (·.blocks) == some (exHeaders 0 5) &&
              (lastView edited).map (·.blocks) == some (exHeaders 0 5) &&
              (lastView typed).map (·.blocks) == some (exHeaders 0 6) &&
              -- A plain buffer's view has none.
              (lastView (excerptInvoked driver "show-one")).map (·.blocks) == some #[] },
    { name :=
        "a source buffer's span is drawn at the same text in every excerpt of it, under the excerpt buffer's own span and the search's matches, in that order"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let made := excerptInvoked driver "make-overlap"
            let error : FaceName := ⟨"compilation.error"⟩
            (lastView made).map (·.decorations) ==
              some
                #[⟨4, 7, error⟩, ⟨9, 12, error⟩, ⟨0, 1, ⟨"own"⟩⟩, ⟨5, 6, Loop.searchMatchFace⟩,
                  ⟨10, 11, Loop.searchMatchFace⟩] },
    { name :=
        "in a window four rows tall over six headed excerpts, after each of G, k and j across the headers, gg, C-f, C-b, C-d, C-u, z t, z z and z b, the rows the published view shows from its anchor, asked with its blocks, hold the cursor's row"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let six := viewResized (excerptInvoked driver "make-six") ⟨20, 4⟩
            let keys :=
              ["G", "k", "k", "k", "k", "k", "k", "j", "j", "j", "g g", "C-f", "C-f", "C-b", "C-d",
                "C-d", "C-u", "G", "z t", "z z", "z b", "g g", "z b", "j", "j", "z z"]
            let (_, held) :=
              keys.foldl
                (fun (driver, held) key =>
                  let fed := evilFed driver key
                  (fed, held && (blockedSeen fed).any (·.2.2)))
                (six, true)
            (lastView six).any (·.blocks.size == 6) && held },
    { name :=
        "the scroll commands ask the rows a view fits with its blocks: C-f from the start of six headed excerpts in four rows moves the anchor and the cursor two rows, the rows that fit with the headers, not four"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let six := viewResized (excerptInvoked driver "make-six") ⟨20, 4⟩
            -- `one` and the separator fit with the first header; `two`, at
            -- 5, is two rows down; without the headers `three`, at 10, is
            -- four rows down.
            (blockedSeen six).map (fun (anchor, head, _) => (anchor, head)) == some (0, 0) &&
              (blockedSeen (evilFed six "C-f")).map (fun (anchor, head, _) => (anchor, head)) ==
                some (5, 5) },
    { name :=
        "a float anchored at a position of an excerpt buffer's view sits lower by the header rows above the position than one over the same text with no header"
      run :=
        pure <|
          match excerptDriver with
          | none => false
          | some driver =>
            let blocked := floatTop (excerptInvoked driver "float-five")
            let plain := floatTop (excerptInvoked (excerptInvoked driver "make-plain") "float-five")
            -- `alpha`, at 5, is below both headers: two rows of one pixel.
            match blocked, plain with
            | some blocked, some plain => blocked == plain + 2
            | _, _ => false }]

end ModelTest
