import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import Editor.Event
import Editor.Event.Queue
import Editor.Ex
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.Test.Opener
import Editor.Text
import FilesApi
import FilesApiTest.Fake

/-!
# Config tests: `Editor/Ex.lean`

The tests of `Editor/Ex.lean`: `exChecks`, through the headless host, and
`exScriptChecks`, scripts of ex lines run by `Headless.run`, which open and
write a file with the files feature's commands. The root
module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- What compiled code hands every host of the ex checks: the ex line's
commands and the `ex` package's ex names (`Ex.package.registered.commands`, `Ex.package.registered.ex`,
`Editor/Ex/Compiled.lean`), the kit's minibuffer's commands and its mode
(`Editor/Test/Minibuffer.lean`), `files-api`'s fake's commands
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
running. `false` if the commit was refused. -/
def Session.exLine (session : Session) (line : String) : IO Bool := do
  session.ask [.run Ex.name]
  unless ← Event.post (.commit line) do
    return false
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

/-- A config whose `setup` registers `mine`, which says `mine` in the echo
area, and binds the ex name `w` to it. -/
def ownWriteText : String :=
  "def setup : SetupM Unit := do
  command \"mine\" (message \"mine\")
  exCommand \"w\" \"mine\"
"

/-- The checks of the ex command line through the headless host
(`Editor/Headless.lean`), on the real queue, the real text binding and the
real elaborator, with the test scheme: the host is handed the ex line's
commands and the ex names that ship as compiled code registers them
(`Editor/Ex/Compiled.lean`), registers the ex bindings config's `setup`
makes, and reloads when a command asks. Each line is committed into the
minibuffer and accepted with the test scheme's key for the role the
minibuffer's mode fills (`Session.exLine`), so no check names a scheme's
key. They open and save no file. -/
def exChecks (context : Context) : List Check :=
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
            session.write "init.lean" emptyText
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

/-- The directives of one ex line of a script: the ex command run by its
name, which asks, `line` committed into the minibuffer, and the accept
key. -/
def exLineDirectives (line : String) : List Headless.Directive :=
  [.request (.run Ex.name), .commit line] ++ acceptKeys.map .key

/-- A script of `directives`, one a line, numbered from 1. -/
def scriptOf (directives : List Headless.Directive) : Array Headless.Line :=
  (directives.zipIdx.map fun (directive, index) => ⟨index + 1, directive⟩).toArray

/-- Runs `directives` as a script (`Headless.run`) against a host of its own
over the library's file service (`Stage.overFiles`), with an empty config
directory, that is handed what the executable is handed for the ex line,
the ex line's commands and the `ex` package's ex names, `files-api`'s fake
(`FilesApiTest.fake`: its commands, its jobs and its `FilesApi.Files` value,
which `wq` saves through), and the kit's minibuffer's commands and its mode
(`Editor/Test/Minibuffer.lean`) where the executable has the shipped ones. What `run`
answered, and every line the host printed. -/
def ranScript (context : Context) (directives : List Headless.Directive) :
    IO (Option Headless.Failure × Array String) :=
  IO.FS.withTempDir fun directory => do
    let stage ←
      Stage.overFiles context (Config.Directory.source directory)
          { packages := #[FilesApiTest.fake]
            commands :=
              Ex.package.registered.commands ++ Test.Minibuffer.package.registered.commands
            modes := Test.Minibuffer.package.registered.modes
            ex := Ex.package.registered.ex }
    let failure ← Headless.run stage.collaborators (scriptOf directives) patience
    return (failure, ← stage.output.get)

/-- The checks of a script that a command ends (`Editor/Headless.lean`,
"The driver, and the command line"), with `Headless.run` on scripts built
here, over the real elaborator, the real queue, the real text binding and
the library's file service, on a file each check writes in a temporary
directory of its own: the phase's first two acceptance criteria through the
host. They share the file checks' table of waits and completion pump, so
they run after them.

Each script that opens a file has a `join` after the `e` line: the open is
a job, and without the wait the text would be committed into the scratch
buffer. The `wq` script has a `join` after the `wq` line too: the quit it
asks for waits for the save, so without the wait the `show` line would be
handled while the save runs, and the end of the script would stop the loop,
which cancels the save. -/
def exScriptChecks (context : Context) : List Check :=
  let listed (output : Array String) : Bool := output.any (·.startsWith "commands:")
  [{  name :=
        "criterion 1 through the host: a script that runs e on a file, joins, commits text, runs w, joins, runs q, and then has a show line: the script has no failure, the file holds the committed text before what it held, and the show line was not run"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          let (failure, output) ←
            ranScript context
                (exLineDirectives s!"e {path}" ++ [.join, .commit "x"] ++ exLineDirectives "w" ++
                  [.join] ++
                  exLineDirectives "q" ++
                  [.request .show])
          return failure == none && (← IO.FS.readBinFile path) == ("x" ++ noteText).toUTF8 &&
              endedOk output Test.Opener.saveJob &&
              !listed output },
    { name :=
        "criterion 2 through the host: the same script with wq in place of w, the join and q, and a join after it: the script has no failure, the file holds the buffer's text, and the show line was not run"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          let (failure, output) ←
            ranScript context
                (exLineDirectives s!"e {path}" ++ [.join, .commit "x"] ++ exLineDirectives "wq" ++
                  [.join, .request .show])
          return failure == none && (← IO.FS.readBinFile path) == ("x" ++ noteText).toUTF8 &&
              endedOk output Test.Opener.saveJob &&
              !listed output },
    { name :=
        "a script whose q is refused, for a file's buffer that was edited, runs its later lines: the show line prints the commands, the script has no failure, and the file is as it was"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
          let (failure, output) ←
            ranScript context
                (exLineDirectives s!"e {path}" ++ [.join, .commit "x"] ++ exLineDirectives "q" ++
                  [.request .show])
          return failure == none && listed output &&
              (← IO.FS.readBinFile path) == noteText.toUTF8 },
    { name :=
        "once a step said stop the host runs no further invocation: a command that asks for quit and then for the open command, with a path, to be run after it ends the loop at quit, and the open command never runs: the host prints the run alone and starts no job; with a command that says other in place of quit, the load job is started"
      run :=
        IO.FS.withTempDir fun files => do
          let path := files / "note.txt"
          IO.FS.writeBinFile path noteText.toUTF8
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
            let stage ← Stage.new context context.elaborator (memorySource []) compiled
            let host ← Headless.start stage.collaborators
            try
              host.send (.run name)
              let joined ← host.join patience
              let halted ← host.halt patience
              let output ← stage.output.get
              return if halted then some (joined, output) else none
            catch error =>
              discard <| host.halt patience
              throw error
          let left ← ran s!"hand-{Ex.quitName}"
          let went ← ran "hand-other"
          return left == some (.ended, #[s!"run hand-{Ex.quitName}: ok"]) &&
              (went.map fun (joined, output) =>
                  joined == .settled && output.contains "run hand-other: ok" &&
                    output.contains started) ==
                some true },
    { name :=
        "a wait on a host whose loop a command ended answers that the loop has ended, a settle and a join alike, which is no failure of a script, and halting the host then answers that it stopped"
      run := do
        let stage ← Stage.new context context.elaborator (memorySource []) exCompiled
        let host ← Headless.start stage.collaborators
        try
          host.send (.run Ex.quitName)
          let ended ← eventually (IO.hasFinished host.thread)
          let awaited ← host.await patience
          let joined ← host.join patience
          return ended && awaited == .ended && joined == .ended &&
              Headless.Wait.ended.failure (some 3) == none &&
              (← host.halt patience) &&
              (← stage.output.get) == #[s!"run {Ex.quitName}: ok"]
        catch error =>
          discard <| host.halt patience
          throw error }]

end ConfigTest
