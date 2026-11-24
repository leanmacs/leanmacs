import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Editor.Test.Opener
import Editor.Text
import Ex.Compiled
import ExTest.Check
import FilesApi
import FilesApiTest.Fake

/-!
# Linked tests: `Ex.lean`

The tests of `Ex.lean`: `exChecks`, through the headless host, and
`exScriptChecks`, ex lines typed as a script types them, which open and
write a file with `files-api`'s fake's commands, on a stepped stage over the
file fake. The root module
`ExTest.Linked` runs them; its module doc says what each shows. They were
the config test's (`ConfigTest.exChecks`, `ConfigTest.exScriptChecks`,
`lean/ConfigTest/Editor/Ex.lean`) while the ex line was two modules of the
core, and moved here with their sentences as they were.
-/

namespace ExTest.Linked

open Editor
open Editor.Test.Linked

/-- What compiled code hands every host of the ex checks: the ex line's
commands and the `ex` package's ex names (`Ex.package.registered.commands`, `Ex.package.registered.ex`,
`Ex/Compiled.lean`), the kit's minibuffer's commands and its mode
(`lean/Editor/Test/Minibuffer.lean`), `files-api`'s fake's commands
(`FilesApiTest.fake`), which two of the shipped names run, and `other`, written
here, which says `other`, on `C-c o`. It is handed no job: no check here
opens or saves a file. -/
def exCompiled : Compiled :=
  { commands :=
      Ex.package.registered.commands ++ Test.Minibuffer.package.registered.commands ++
        FilesApiTest.fake.registered.commands ++
        #[{ name := "other", action := .plain (message "other") }]
    modes := Test.Minibuffer.package.registered.modes
    ex := Ex.package.registered.ex
    bindings := #[bound "C-c o" "other"] }

/-- Runs `line` on the ex line: the ex command is run by its name, which
asks, `line` is committed into the minibuffer, and the accept key is
pressed. Waits until the editor thread has handled them and no reload is
running. `true`: a commit the queue refused throws. -/
def _root_.Editor.Test.Linked.Session.exLine (session : Session) (line : String) : IO Bool := do
  session.ask [.run Ex.name]
  session.commit line
  session.pressKeys acceptKeys
  return true

/-- A config whose `setup` registers two commands, `one` and `two`, each of
which says its name in the echo area, and binds `C-c t` to `command`. -/
def sayingText (command : String) : String :=
  "def setup : SetupM Unit := do
  command \"one\" (message \"one\")
  command \"two\" (message \"two\")
  bindKey \"C-c t\" \"" ++
    command ++
    "\"
"

/-- A config whose `setup` registers `greet-named`, a command that is given
its call and says `hello ` and its first argument in the echo area, and,
when `bound`, binds the ex name `greet` to it, taking text. -/
def greetExText (bound : Bool) : String :=
  "def setup : SetupM Unit := do
  commandWith \"greet-named\" fun call =>
    match call.arguments with
    | .str name :: _ => message s!\"hello {name}\"
    | _ => message \"hello\"
" ++
    if bound then "  exCommand \"greet\" \"greet-named\" (takes := .text)\n" else ""

/-- A config whose `setup` registers nothing. -/
def noSetupText : String :=
  "def setup : SetupM Unit := pure ()\n"

/-- A config whose `setup` registers `mine`, which says `mine` in the echo
area, and binds the ex name `w` to it. -/
def ownWriteText : String :=
  "def setup : SetupM Unit := do
  command \"mine\" (message \"mine\")
  exCommand \"w\" \"mine\"
"

/-- The checks of the ex command line through the headless host
(`lean/Editor/Headless.lean`), on the real queue, the real text binding and the
real elaborator, with the test scheme: the host is handed the ex line's
commands and the ex names that ship as compiled code registers them
(`Ex/Compiled.lean`), registers the ex bindings config's `setup`
makes, and reloads when a command asks. Each line is committed into the
minibuffer and accepted with the test scheme's key for the role the
minibuffer's mode fills (`Session.exLine`), so no check names a scheme's
key. They open and save no file. -/
def exChecks (context : HostContext) : List Check :=
  let installs (lines : Array String) : Array String :=
    lines.filter fun line => (line.splitOn ": installed").length == 2
  [{  name :=
        "criterion 3: a config binds a key to a command and the key runs it; the config's file is changed to bind the key to another command and the ex line reload is run: the host reloads, with no restart, and the key then runs the other command"
      run :=
        withHost context [("init.lean", sayingText "one")]
          (fun session => do
            session.ask [.reload]
            session.typed "C-c t"
            let first ← session.echo
            session.write "init.lean" (sayingText "two")
            unless ← session.exLine "reload" do
              return false
            let reloaded := installs (← session.lines)
            session.typed "C-c t"
            let second ← session.echo
            return first == "one".quote &&
                reloaded ==
                  #["reload 1: installed, 1 files, 2 commands",
                    "reload 2: installed, 1 files, 2 commands"] &&
                second == "two".quote)
          exCompiled },
    { name :=
        "criterion 4: config binds an ex name to a command of its own, and the name run on the ex line runs that command with the rest of the line; after a reload of a config without the binding the name is not an ex command, by the ex line's message"
      run :=
        withHost context [("init.lean", greetExText true)]
          (fun session => do
            session.ask [.reload]
            unless ← session.exLine "greet Ada" do
              return false
            let greeted ← session.echo
            session.write "init.lean" (greetExText false)
            unless ← session.exLine "reload" do
              return false
            let reloaded := installs (← session.lines)
            unless ← session.exLine "greet Ada" do
              return false
            let dropped ← session.echo
            return greeted == "hello Ada".quote && reloaded.size == 2 &&
                dropped == (Ex.unknown "greet").quote)
          exCompiled },
    { name :=
        "config's binding of an ex name a compiled binding has runs config's command in its place, and the compiled binding's command runs again once a reload drops config's"
      run :=
        withHost context [("init.lean", ownWriteText)]
          (fun session => do
            unless ← session.exLine "w" do
              return false
            let compiled ← session.echo
            session.ask [.reload]
            unless ← session.exLine "w" do
              return false
            let own ← session.echo
            session.write "init.lean" noSetupText
            unless ← session.exLine "reload" do
              return false
            unless ← session.exLine "w" do
              return false
            let again ← session.echo
            let noFile := s!"{Test.Opener.saveName}: scratch has no file"
            return compiled == noFile.quote && own == "mine".quote && again == noFile.quote)
          exCompiled },
    { name :=
        "criterion 5: a name nobody bound, run on the ex line, is said in the echo area of the scene, by the ex line's message, with the prompt closed, and the editor goes on: a key's command run after it runs"
      run :=
        withHost context []
          (fun session => do
            unless ← session.exLine "bogus now" do
              return false
            let unknown ← session.sceneLines
            session.typed "C-c o"
            let after ← session.echo
            return (unknown[0]?.map fun line =>
                    focuses line 0 &&
                      (line.splitOn s!", echo {(Ex.unknown "bogus").quote}, ").length == 2) ==
                  some true &&
                unknown.extract 1 == #[viewLine "" 0, statusOf] &&
                after == "other".quote &&
                !(← session.output.get).any (·.startsWith "loop: refused"))
          exCompiled }]

/-- The made-up path of the file the ex script checks open, which only the
file fake's model holds. -/
def notePath : System.FilePath :=
  "/files/note.txt"

/-- Runs `check` against a host stepped on the check's thread over a stepped
stage (`Stage.stepped`), with an empty config directory, handed what the
executable is handed for the ex line, the ex line's commands and the `ex`
package's ex names, `files-api`'s fake (`FilesApiTest.fake`: its commands,
its jobs and its `FilesApi.Files` value, which `wq` saves through), and the
kit's minibuffer's commands and its mode (`lean/Editor/Test/Minibuffer.lean`)
where the executable has the shipped ones; its file fake holds `notePath`
with `noteText`. `check` is handed the session and a read of the bytes the
file fake holds at `notePath`. -/
def withExFileHost (context : HostContext) (check : Session → IO (Option ByteArray) → IO Bool) :
    IO Bool :=
  IO.FS.withTempDir fun directory => do
    let stage ←
      Stage.new context context.elaborator (Config.Directory.source directory)
          { packages := #[FilesApiTest.fake]
            commands :=
              Ex.package.registered.commands ++ Test.Minibuffer.package.registered.commands
            modes := Test.Minibuffer.package.registered.modes
            ex := Ex.package.registered.ex }
    let files :=
      ((({} : FileModel).withDirectory "/").withDirectory "/files").withFile notePath
        noteText.toUTF8
    let stage ← stage.stepped files
    let some fakes := stage.fakes | return false
    let bytes : IO (Option ByteArray) := do
      return ((← fakes.services.files.model).file? notePath).map (·.bytes)
    onStage stage fun drive stage => check (Session.ofStage drive directory stage) bytes

/-- A check of `exScriptChecks`, a declaration of its own. -/
def stepSaidStopHostCheck (context : HostContext) : Check :=
  { name :=
      "once a step said stop the host runs no further invocation: a command that asks for quit and then for the open command, with a path, to be run after it ends the loop at quit, and the open command never runs: the host prints the run alone and starts no job; with a command that says other in place of quit, the load job is started"
    run := do
      let path := notePath
      let handing (first : String) : Config.Registration :=
        { name := s!"hand-{first}"
          action :=
            .plain do
              Editor.invoke { command := first }
              Editor.invoke
                  { command := FilesApi.openFileName, arguments := [.str path.toString] } }
      let compiled : Compiled :=
        { exCompiled with
          commands := exCompiled.commands ++ #[handing Ex.quitName, handing "other"]
          jobs := FilesApiTest.fake.registered.jobs }
      let started := s!"job 1 {Test.Opener.loadJob}: started"
      let ran (name : String) : IO (Option (Headless.Wait × Array String)) := do
        -- A stepped stage: the load job is held in the fake scheduler,
        -- and its started line is the editor thread's, printed as the
        -- run is handled, so the drain alone shows it; the loop's end
        -- steps the job it cancels.
        let stage ← (← Stage.new context context.elaborator (memorySource []) compiled).stepped
        leavingLibraryQueue <|
            Headless.withStepped stage.collaborators stage.memory (guard := hangGuard) (grace :=
              some hangGuard) fun stepped => do
              stepped.send (.run name)
              let handled ← (Driven.ofStepped stepped).handled hangGuard
              let output ← stage.output.get
              return some (handled, output)
      let left ← ran s!"hand-{Ex.quitName}"
      let went ← ran "hand-other"
      return left == some (.ended, #[s!"run hand-{Ex.quitName}: ok"]) &&
          (went.map fun (handled, output) =>
              handled == .settled && output.contains "run hand-other: ok" &&
                output.contains started) ==
            some true }

-- inferred-waits W35: stays (A2: a settle's and a join's answer on a host whose loop has ended are the subject)
set_option linter.inferredWait false in
/-- A check of `exScriptChecks`, a declaration of its own so that the allow
above it covers it alone. -/
def waitHostWhoseLoopCheck (context : HostContext) : Check :=
  { name :=
      "a wait on a host whose loop a command ended answers that the loop has ended, a settle and a join alike, which is no failure of a script, and halting the host then answers that it stopped"
    run := do
      let stage ← Stage.new context context.elaborator (memorySource []) exCompiled
      Headless.withHost stage.collaborators (guard := hangGuard) fun host => do
          host.send (.run Ex.quitName)
          let ended := (← Job.awaitWithin hangGuard host.thread).isSome
          let awaited ← host.await hangGuard
          let joined ← host.join hangGuard
          return ended && awaited == .ended && joined == .ended &&
              Headless.Wait.ended.failure (some 3) == none &&
              (← host.halt hangGuard) &&
              (← stage.output.get) == #[s!"run {Ex.quitName}: ok"] }

/-- The checks of ex lines that a command ends the loop with
(`lean/Editor/Headless.lean`, "The driver, and the command line"), typed as
a script of them types them (`Session.exLine`), on a stepped stage over the
file fake (`withExFileHost`), with the real elaborator and the real text
binding: the phase's first two acceptance criteria through the host. Each
open and save is stepped until its own job's end line; the file's bytes are
read from the fake's model. -/
def exScriptChecks (context : HostContext) : List Check :=
  let listed (output : Array String) : Bool := output.any (·.startsWith "commands:")
  let path := notePath
  let endedWell (ended : Option (Except IO.Error Unit)) : Bool :=
    match ended with
    | some (.ok ()) => true
    | _ => false
  [{  name :=
        "criterion 1 through the host: e on a file, then once it is open text committed, w, and once the save has ended q, and then a show: the loop ends at q with no error, the file holds the committed text before what it held, and the show is not run"
      run :=
        withExFileHost context fun session bytes => do
          discard <| session.exLine s!"e {path}"
          unless ← session.stepUntil (endedOk · Test.Opener.loadJob) do
            return false
          session.commit "x"
          discard <| session.exLine "w"
          unless ← session.stepUntil (endedOk · Test.Opener.saveJob) do
            return false
          session.send (.run Ex.name)
          session.commit "q"
          -- The quit ends the loop: the keys are pressed with no settle.
          for key in acceptKeys do
            session.press key
          discard <| session.handled
          session.send .show
          discard <| session.handled
          let ended ← session.drive.ended?
          return endedWell ended && (← bytes) == some ("x" ++ noteText).toUTF8 &&
              !listed (← session.output.get) },
    { name :=
        "criterion 2 through the host: the same with wq in place of w and q: the quit waits for the save, so once the save has ended the loop has ended with no error, the file holds the buffer's text, and the show is not run"
      run :=
        withExFileHost context fun session bytes => do
          discard <| session.exLine s!"e {path}"
          unless ← session.stepUntil (endedOk · Test.Opener.loadJob) do
            return false
          session.commit "x"
          session.send (.run Ex.name)
          session.commit "wq"
          for key in acceptKeys do
            session.press key
          unless ← session.stepUntil (endedOk · Test.Opener.saveJob) do
            return false
          discard <| session.handled
          session.send .show
          discard <| session.handled
          let ended ← session.drive.ended?
          return endedWell ended && (← bytes) == some ("x" ++ noteText).toUTF8 &&
              !listed (← session.output.get) },
    { name :=
        "a q refused for a file's buffer that was edited leaves the loop running: the show then prints the commands, and the file is as it was"
      run :=
        withExFileHost context fun session bytes => do
          discard <| session.exLine s!"e {path}"
          unless ← session.stepUntil (endedOk · Test.Opener.loadJob) do
            return false
          session.commit "x"
          discard <| session.exLine "q"
          session.ask [.show]
          return listed (← session.output.get) && (← session.drive.ended?).isNone &&
              (← bytes) == some noteText.toUTF8 },
    stepSaidStopHostCheck context, waitHostWhoseLoopCheck context]
