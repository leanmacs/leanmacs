import Editor.Api
import Editor.Clipboard
import Editor.Command
import Editor.Command.Model
import Editor.Compile
import Editor.Compile.Contribution
import Editor.Compile.Errors
import Editor.Compile.Shipped
import Editor.Completion.Candidate
import Editor.Display
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.File
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Files
import Editor.Fuzzy
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job
import Editor.Job.Model
import Editor.Language
import Editor.Layout
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.ProjectMode
import Editor.ProjectMode.Format
import Editor.Role
import Editor.Scene
import Editor.Setup
import Editor.State
import Editor.State.Request
import Editor.Store
import Editor.SyntaxTree
import Editor.SyntaxTree.Model
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Keys
import Editor.Test.Models
import Editor.Test.Prompts
import Editor.Test.Shell
import Editor.Test.Workspace
import Editor.Text
import Editor.Text.Model
import Editor.UndoTree
import Editor.Value
import Editor.Watch
import Editor.Watch.Model
import Editor.Workspace
import Editor.Workspace.Attach
import Editor.Workspace.Model
import Editor.Workspace.Modes
import ModelTest.Check
import ModelTest.Support.Compile

/-!
# Model tests: `Editor/Compile.lean`

The model tests of `Editor/Compile.lean`: `compileChecks`,
`compileLocationChecks` and `compileHookChecks`. `compileHookChecks` are of the
compile hook, which `Editor/Workspace/Modes.lean` and `Editor/Compile.lean`
share; they are here with the other compile checks. The root module `ModelTest`
runs them; its module doc says what each shows.
-/

namespace ModelTest

open Editor
open Editor.Test

/-- The world of the compile checks: the workspace driver checks' world, and a
second clone of the same origin at `/clone/r`, on `main`. -/
def compileWorld : Workspace.World :=
  { workspaceWorld with
    repositories :=
      workspaceWorld.repositories.push
        { toplevel := "/clone/r", commonDir := "/clone/r/.git", origin := some workspaceOrigin }
    markerDirectories := workspaceWorld.markerDirectories.push "/clone/r/.git" }

/-- What `make` in `/r` does: writes `one`, pauses 100 ms, writes `two`,
pauses 100 ms and writes `three` on its standard error. -/
def makeSteps : Array Process.Step :=
  #[.write .out "one\n".toUTF8, .pause 100, .write .out "two\n".toUTF8, .pause 100,
    .write .err "three\n".toUTF8]

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

/-- The place of the workspace `/w`. -/
def placeW : Compile.Place :=
  .workspace (.local "/w")

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

/-- `driver` once `compile` is asked, `line` typed in its prompt and the
prompt accepted. -/
def compiledLine (driver : TestDriver) (line : String) : TestDriver :=
  (fedTo driver (presses "C-k c" ++ [.commit line] ++ presses "C-e y")).1

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
            (candidatesOf asked).map (·.all.map (·.text)) == some #["make"] &&
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
            -- The split takes the next view id, past the candidate list's
            -- once that is drawn.
            let split := asking.loop.state.freshView
            asking.loop.state.frame.windows == #[⟨1⟩] && minibuffer == some ⟨2⟩ &&
              asking.loop.state.frame.focused == ⟨1⟩ &&
              stepped.loop.state.minibufferView? == minibuffer &&
              stepped.loop.state.frame.windows == #[⟨1⟩, split] &&
              !stepped.loop.state.isCandidateList split &&
              (showing stepped ⟨1⟩).map (·.buffer.name) == some "*compilation: r@main*" &&
              fileOf stepped split == some "/r/src/main.rs" &&
              headsOf stepped split == some #[135] &&
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
              (candidatesOf offered).map (·.all.map (·.text)) ==
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
              (candidatesOf asked).map (·.all.map (·.text)) ==
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
            (candidatesOf inR).map (·.all.map (·.text)) == some (cargo.push "lint (cargo-mode)") &&
              (shownWorkspace worktree).map (·.1.location) == some (.local "/w") &&
              shownOnModes worktree == some #[{ mode := "cargo-mode", root := "/w/crate" }] &&
              (candidatesOf inW).map (·.all.map (·.text)) ==
                some (cargo.push "lint (cargo-mode)") &&
              (candidatesOf inO).map (·.all.map (·.text)) == some cargo &&
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
              (candidatesOf asked).map (·.all.map (·.text)) ==
                some (cargo.push "lint (cargo-mode)") &&
              relinted.jobs.processes.started.back? ==
                some (shellCommand "/r/crate" "cargo clippy -D warnings") &&
              (candidatesOf askedAgain).map (·.all.map (·.text)) == some cargo },
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
              shownOnModes opened == some #[{ mode := "cargo-mode", root := "/r/crate" }] },
    { name :=
        "a setup that overrides one field of a shipped contribution, { Compile.cargoMode with commands := … }: over the shipped contributions the hook's cargo-mode has the setup's one command with the shipped marker, root rule and rustc format, and lake-mode and mise-mode follow"
      run :=
        let setup : SetupM Unit :=
          compileContribution
            { Compile.cargoMode with
              commands := #[{ name := "build", line := "cargo build --release" }] }
        let hook := (hookRegistry setup Compile.shipped).compileHook
        pure
          (hook.contributions.map (·.mode) == #["cargo-mode", "lake-mode", "mise-mode"] &&
            (hook.contributions[0]?.map fun cargo =>
                (cargo.commands.map (·.line), cargo.markers, cargo.outermost,
                  cargo.formats.map (·.name))) ==
              some (#["cargo build --release"], #["Cargo.toml"], true, #["rustc"])) },
    { name :=
        "a setup that registers a compile contribution with a format of its own, and project commands, installs them: the format reads its line and the project's commands are kept"
      run :=
        let atFormat : Compile.Format :=
          { name := "at"
            pattern :=
              [Compile.step
                  [{ atom := .literal "at " }, { atom := .noneOf [' '], into := some .file },
                    { atom := .literal " line " }, { atom := .digits, into := some .line }]] }
        let setup : SetupM Unit := do
          compileContribution
              { mode := "a-mode", markers := #["a.toml"]
                commands := #[{ name := "build", line := "make" }], formats := #[atFormat] }
          projectCommands (.remote "github.com/o/r") "a-mode" [("lint", "make lint")]
              [("profile", .str "dev")]
        let hook := (hookRegistry setup).compileHook
        pure
          (hook.contributions.map (·.mode) == #["a-mode"] &&
            (hook.contributions.map fun contribution =>
                contribution.formats.map fun format =>
                  (format.read? "at src/x.rs line 4").map fun reading =>
                    (reading.file, reading.line)) ==
              #[#[some ("src/x.rs", 4)]] &&
            hook.projects.map
                (fun entry => (entry.mode, entry.commands.map (·.line), entry.settings)) ==
              #[("a-mode", #["make lint"], [("profile", Value.str "dev")])]) }]

/-- `driver` in which `t-list` cannot be run in `/t2`: the program is not
found. -/
def compileListingRefusedIn (driver : TestDriver) : TestDriver :=
  withScript driver { command := tList "/t2", reply := .error (.notFound "t-list") }

/-- The checks of what the compile mode makes of a contribution's computed
commands (`Compile.commandCommand`, `Editor/Compile.lean`), on the loop's
driver over the world of the listing checks, with `t-mode`: which commands
`compile-command` offers and runs. That a listing runs, where what it gave
is kept and how a failure is said are the listing's
(`ModelTest.listingChecks`). -/
def compileListedChecks : List Check :=
  [{  name :=
        "compile-command offers the listed commands after the contribution's own, a listed name in place of its own: build runs t-build in /t, and sub, listed in sub, runs t-sub in /t/sub"
      run :=
        pure <|
          match compileListingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 1"
            let asked := pressedOn opened "C-k i"
            let built := drained (fedTo opened (exLine "compile-command build")).1
            let subbed := drained (fedTo opened (exLine "compile-command sub")).1
            (candidatesOf asked).map (·.all.map (·.text)) ==
                some #["build (t-mode)", "check (t-mode)", "fmt (t-mode)", "sub (t-mode)"] &&
              built.jobs.processes.started.back? == some (shellCommand "/t" "t-build") &&
              subbed.jobs.processes.started.back? == some (shellCommand "/t/sub" "t-sub") &&
              startedCount subbed (tList "/t") == 1 },
    { name :=
        "compile-command offers none of the commands of a listing that failed, and asking does not run the listing again"
      run :=
        pure <|
          match compileListingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 3"
            let asked := settledAfter opened "C-k i"
            (candidatesOf asked).map (·.all.map (·.text)) ==
                some #["build (t-mode)", "check (t-mode)"] &&
              startedCount asked (tList "/t2") == 1 },
    { name :=
        "compile-command offers none of the commands of a listing that could not be run, and asking does not run it again"
      run :=
        pure <|
          match compileListingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter (compileListingRefusedIn driver) "C-p 3"
            let asked := settledAfter opened "C-k i"
            (candidatesOf asked).map (·.all.map (·.text)) ==
                some #["build (t-mode)", "check (t-mode)"] &&
              startedCount asked (tList "/t2") == 1 },
    { name :=
        "in a directory holding t.toml and no repository compile-command offers and runs what t-mode's listing gave there, kept in the unscoped store"
      run :=
        pure <|
          match compileListingDriver with
          | none => false
          | some driver =>
            let opened := settledAfter driver "C-p 4"
            let asked := settledAfter opened "C-k i"
            let ran := drained (fedTo opened (exLine "compile-command u-only")).1
            startedCount asked (tList "/u") == 1 &&
              (candidatesOf asked).map (·.all.map (·.text)) ==
                some #["build (t-mode)", "check (t-mode)", "u-only (t-mode)"] &&
              ran.jobs.processes.started.back? == some (shellCommand "/u" "u-only") },
    { name :=
        "in a workspace whose location cannot run commands compile-command offers nothing, starts no listing and says where commands cannot run"
      run :=
        let reachable := Location.reachable "kube" "pod" "/app"
        pure <|
          match compileListingDriver with
          | none => false
          | some driver =>
            let waiting := settledBut (fedTo driver (presses "C-p 1")).1 Workspace.markerJob
            let moved := settledOn (pressedOn waiting "C-e k") []
            let asked := pressedOn moved "C-k i"
            (shownWorkspace moved).map (·.1.location) == some reachable &&
              startedCount asked (tList "/t") == 0 &&
              !(asked.pending.any (·.name == Compile.listJob)) &&
              asked.loop.state.prompt.isNone &&
              (echoOf asked).map (·.endsWith "where commands cannot run") == some true }]

end ModelTest
