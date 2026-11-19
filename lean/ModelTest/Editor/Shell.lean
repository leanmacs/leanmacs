import Editor.Api
import Editor.Command
import Editor.Command.Dispatch
import Editor.Command.Model
import Editor.Completion.Candidate
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.File
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Loop
import Editor.Loop.Driver
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Scene
import Editor.Shell
import Editor.State
import Editor.Test.Driver
import Editor.Test.Keys
import Editor.Test.Loop
import Editor.Test.Prompts
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Text.Model
import Editor.Workspace
import ModelTest.Check

/-!
# Model tests: `Editor/Shell.lean`

The model tests of `Editor/Shell.lean`: `shellChecks`. The root module
`ModelTest` runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

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

/-- The names of `driver`'s buffers that are shell output buffers. -/
def outputBuffers (driver : TestDriver) : Array String :=
  (driver.loop.state.buffers.filterMap id).map (·.name) |>.filter (·.startsWith "*shell output")

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
            (candidatesOf asked).map (·.all.toList.take 2 |>.map (·.text)) ==
                some ["!make", "!echo hi"] &&
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

end ModelTest
