import Editor.Api
import Editor.Command
import Editor.Command.Call
import Editor.Command.Model
import Editor.Completion
import Editor.Completion.AtPoint
import Editor.Completion.Candidate
import Editor.Config.Packages
import Editor.Display.Model
import Editor.DisplayRules
import Editor.Event
import Editor.Ex.Line
import Editor.File
import Editor.File.Cases
import Editor.File.Model
import Editor.FileWatch
import Editor.FileWatch.Model
import Editor.Fuzzy.Model
import Editor.InputScheme.Test
import Editor.Invocation
import Editor.Job.Contract
import Editor.Job.Model
import Editor.Language
import Editor.Loop.Driver
import Editor.Mode
import Editor.Process
import Editor.Process.Environment
import Editor.Process.Model
import Editor.Program
import Editor.Scene
import Editor.State
import Editor.Test.Completion
import Editor.Test.Driver
import Editor.Test.Files
import Editor.Test.Hosted
import Editor.Test.Keys
import Editor.Test.Listings
import Editor.Test.Loop
import Editor.Test.Minibuffer
import Editor.Test.Models
import Editor.Test.Opener
import Editor.Test.Prompts
import Editor.Test.Sources
import Editor.Text
import Editor.Value
import Editor.Workspace
import Ex.Compiled
import ExTest.Check
import FilesApi
import FilesApiTest.Fake
import ShellApi
import ShellApiTest.Fake

/-!
# The tests of `Ex.lean`

The tests of the ex command line: `exChecks`. The test driver
`ExTest/Model.lean` runs them; its module doc says what each shows.
-/

namespace ExTest

open Editor
open Editor.Test

/-- The ex bindings of the ex line's own checks, written here: `say` runs
the command `greet` of the prompt checks with the rest of the line, and
`plain` runs it and takes nothing; `ghost` is bound to a command nobody
registered, and `burst` to `boom`, which inserts and is then refused. -/
def exTestBindings : Array Ex.Binding :=
  #[{ name := "say", command := "greet", takes := .text }, { name := "plain", command := "greet" },
    { name := "ghost", command := "nobody" }, { name := "burst", command := "boom" }]

/-- What the ex prompt of a driver told of `bindings` holds once its
candidates are listed for `pattern`, with `chosen` as its choice: the
bound names, in the group of the source of the ex names, its category
`ex-line`, and of them what the fuzzy model answers for the pattern, each
with the ranges the style written for the core's tests gives it
(`marking`). -/
def exListed (pattern : String) (chosen : Option Nat := none)
    (bindings : Array Ex.Binding := exTestBindings) : Candidates :=
  let names := exNamesOf bindings
  let all := (offered names).map (·.inGroup Ex.namesSource.name)
  { all, category := some Ex.namesSource.category, listedFor := some pattern, place := rootPlace
    listed :=
      (FuzzyModel.rank pattern names).filterMap fun index =>
        (all[index]?).map fun candidate => .of candidate (markedSpans pattern candidate.text)
    chosen }

/-- What a step of the ex checks is handed. The commands are the ones
compiled code registers for the ex line (`Ex.package.registered.commands`),
`files-api`'s fake's (`FilesApiTest.fake.registered.commands`) and
the kit's minibuffer's (`Test.Minibuffer.package.registered.commands`,
`lean/Editor/Test/Minibuffer.lean`), and those `extra` registers (`shell-api`'s
fake, for the bang lines' checks), each under the
name it is registered under, and then the commands of the prompt checks:
`greet`, which says what it was called with, `boom`, `other` and the test
scheme's self-insert. The ex bindings a command is told of are `bindings`,
the latest of a name, and the ex names it is told of are theirs
(`exNamesOf`): both are filled from the one list, so that no name is told
without its binding.

One keymap, the same for every view: `C-e e` runs the ex command, `C-e V`
runs it with the arguments the Vim scheme gives a command a key is bound
to, a count and a register, `C-e l` runs it with the line `say hello there`
as its first argument, `C-e y` and `C-e n` run the minibuffer's accept and
cancel commands, `C-e t` runs its command that moves to the next
candidate, and `C-e o` runs `other`. The extension points are answered as
`files-api`'s fake registers them, so `save-and-quit` saves through its
`FilesApi.Files` value. Prompts are matched and shown by the
style and the display written for the core's tests (`marking`,
`windowed`). -/
def exKeys (bindings : Array Ex.Binding := exTestBindings) (extra : Array Package := #[]) :
    Loop.Keys TestScheme.scheme :=
  let compiled : List (String × Dispatched) :=
    (Ex.package.registered.commands ++ Test.Minibuffer.package.registered.commands ++
          FilesApiTest.fake.registered.commands ++
          extra.flatMap (·.registered.commands)).toList.filterMap
      fun registration =>
      match registration.action with
      | .call run =>
        some
          (registration.name, fun call => do
            run call
            return none)
      | _ => none
  {
    dispatchKeys
      [("C-e e", invoke Ex.name), ("C-e V", { command := Ex.name, arguments := [.nat 0, .str ""] }),
        ("C-e l", { command := Ex.name, arguments := [.str "say hello there"] }),
        ("C-e y", invoke Test.Minibuffer.acceptName), ("C-e n", invoke Test.Minibuffer.cancelName),
        ("C-e t", invoke Test.Minibuffer.nextName), ("C-e o", invoke "other")]
      (compiled ++ promptCommands) with
    matching := markingMatching,
    displaying := windowedDisplaying
    registered :=
      { ex := fun name => bindings.findRev? (·.name == name), exNames := exNamesOf bindings
        extensions := (hostedRegistry #[FilesApiTest.fake]).extensionsAt } }

/-- A driver of the ex checks over the initial state, told of the ex
bindings `bindings`, with the jobs of `files-api`'s fake's opener, its load
and its save, with `files-api`'s hooks as their runners
(`Opener.jobsWith FilesApi.runOpened FilesApi.runSaved`; the fake's
`check-files` and `follow-file` are left out, as the file command checks'
jobs leave the files feature's out), and the files of the file command
checks, with the commands `extra` registers (`exKeys`); `none` if making
the state was refused. -/
def exDriver (bindings : Array Ex.Binding := exTestBindings) (extra : Array Package := #[]) :
    Option TestDriver :=
  (Loop.Driver.over (exKeys bindings extra) (Opener.jobsWith FilesApi.runOpened FilesApi.runSaved)
        (EditorState.initial ⟨640, 480⟩) editorModel).toOption.map
    fun driver => { driver with jobs := { files := commandFiles } }

/-- The echo area of each scene `after` recorded that `before` had not. -/
def echoesSince (before after : TestDriver) : Array String :=
  (after.model.display.scenes.map (·.echo)).extract before.model.display.scenes.size

/-- The ex command called with the line `line` as its first argument, a
string, in view 0 of `driver`, as one step (`Loop.invoke`): the driver after
it, with what it answered run, and the invocations the step answered, which
are what the line asked to be run after it, or `none` for a step that was
refused. -/
def exRan (driver : TestDriver) (line : String) : TestDriver × Option (Array Invocation) :=
  let (after, stepped) :=
    driver.stepped
      (driver.loop.invoke driver.handed { command := Ex.name, arguments := [.str line] })
  (after, stepped.toOption.map (·.answered))

/-- A driver of the ex checks told of the `ex` package's ex names, with
`shell-api`'s fake registered (`ShellApiTest.fake`), and with the file
`lf.txt`, of three lines, open in view 0 by the ex line `e` and its path,
its load finished, so that its cursor is on its first line. -/
def exShellLines : Option TestDriver :=
  (exDriver Ex.package.registered.ex #[ShellApiTest.fake]).map fun driver =>
    ((fedTo driver (exLine s!"e {inFiles "lf.txt"}")).1.finish 1).1

/-- A driver of the ex checks told of the `ex` package's ex names
(`Ex.package.registered.ex`), with the file `note.txt` open in view 0 by the ex line
`e` and its path, its load finished. The load is job 1. -/
def exNoteOpen : Option TestDriver :=
  (exDriver Ex.package.registered.ex).map fun driver =>
    ((fedTo driver (exLine s!"e {inFiles "note.txt"}")).1.finish 1).1

/-- The checks of the ex command line (`Ex.lean`,
`Ex/Compiled.lean`), on the loop's driver over the editor's models,
the model of files and the test scheme: the ex command opens a prompt and
runs its answer as the command the line's name is bound to. Each message is
read from the function that makes it. Then the completion sources'
contract (`lean/Editor/Completion/Contract.lean`) over the ex line's two
sources, its `:!` history and its names, on the kit's runner
(`lean/Editor/Test/Sources.lean`), and that the names' source answers something
on its fixture. -/
def exChecks : List Check :=
  let closed (driver : TestDriver) : Bool :=
    let state := driver.loop.state
    state.prompt == none && state.frame.focused == ⟨0⟩ && state.outbox.answered.isEmpty &&
      state.wellFormed
  let hello : List Argument := [.str "hello there"]
  [{      name :=
            "the ex command opens a prompt labelled with the ex line's label, whose continuation is the ex command itself, with the focus in the minibuffer's view; called with a count and a register first, as a key under the Vim scheme calls it, it asks the same"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let asked (keys : String) :=
                  let (asking, _) := fedTo driver (presses keys)
                  asking.loop.state.prompt.map
                        (fun asking => (asking.label, asking.continuation)) ==
                      some (Ex.label, { command := Ex.name }) &&
                    asking.loop.state.minibufferView? == some asking.loop.state.frame.focused &&
                    asking.loop.state.frame.focused != ⟨0⟩ &&
                    asking.loop.state.wellFormed
                asked "C-e e" && asked "C-e V" },
        { name :=
            "a line typed on the ex line and accepted runs the command its name is bound to, with the rest of the line as its first argument, a string, in the view the line was asked from and with no keys; the accept key is three steps, the accept command, the ex command and the bound command, each with a scene"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
                let (accepted, _) := fedTo typed (presses "C-e y")
                minibufferText typed == some "say hello there" &&
                  promptEcho accepted == greeted hello &&
                  closed accepted &&
                  echoesSince typed accepted == #["", "", "", greeted hello] },
        { name :=
            "criterion 5: a name nobody bound leaves the ex line's message for it in the echo area, with the prompt closed, and the editor goes on: the next key's command runs"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (unknown, _) := fedTo driver (exLine "nope 1 2")
                let (after, _) := fedTo unknown (presses "C-e o")
                promptEcho unknown == Ex.unknown "nope" && closed unknown &&
                  echoOf unknown == some (Ex.unknown "nope") &&
                  promptEcho after == "other" },
        { name :=
            "an argument for an ex name that takes nothing leaves the ex line's message for it in the echo area and runs nothing; the name alone runs its command with no arguments"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (refused, _) := fedTo driver (exLine "plain hello")
                let (ran, _) := fedTo driver (exLine "plain")
                promptEcho refused == Ex.noArgument "plain" && closed refused &&
                  !(echoesSince driver refused).contains (greeted hello) &&
                  promptEcho ran == greeted [] },
        { name :=
            "a range before an ex name, which no shipped name takes, leaves the ex line's message for it in the echo area and runs nothing; a range alone, which would go to a line in Vim, says that is not built"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (refused, _) := fedTo driver (exLine "3,5plain")
                let (spaced, _) := fedTo driver (exLine "% plain")
                let (alone, _) := fedTo driver (exLine "3")
                promptEcho refused == Ex.noRange "plain" && closed refused &&
                  !(echoesSince driver refused).contains (greeted []) &&
                  promptEcho spaced == Ex.noRange "plain" &&
                  promptEcho alone == Ex.rangeAlone &&
                  closed alone },
        { name :=
            "an empty line and a line of white space run nothing and leave the echo area empty, with the prompt closed"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (empty, _) := fedTo driver (presses "C-e e C-e y")
                let (blank, _) := fedTo driver (exLine "   ")
                promptEcho empty == "" && closed empty && promptEcho blank == "" && closed blank },
        { name :=
            "an ex name bound to a command nobody registered says there is no such command, by the command's name"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (ran, _) := fedTo driver (exLine "ghost")
                promptEcho ran == "nobody: no such command" && closed ran },
        { name :=
            "a command an ex line runs that is refused is rolled back, and the echo area says the refusal under the command's own name, not the ex command's"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (ran, _) := fedTo driver (exLine "burst")
                promptEcho ran == "boom: refused: bad range" && driverText ran == some "" &&
                  closed ran },
        { name :=
            "a key fed after the accept key is handled after the command the line runs: the scenes show the bound command's message before the other command's"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
                let (after, _) := fedTo typed (presses "C-e y C-e o")
                echoesSince typed after == #["", "", "", greeted hello, greeted hello, "other"] },
        { name :=
            "the ex command called with a string as its first argument runs that line and opens no prompt"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (ran, steps) := fedTo driver (presses "C-e l")
                promptEcho ran == greeted hello && closed ran &&
                  steps.map (·.map (·.answered)) ==
                    #[some #[], some #[{ command := "greet", arguments := hello }]] &&
                  ran.model.display.scenes.all (·.views.size == 1) },
        { name :=
            "the ex command while a prompt is open says the refusal after its own name and leaves that prompt open, with what was typed"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say"])
                let (again, _) := fedTo typed (presses "C-e e")
                (typed.loop.state.minibufferView?).map
                      (fun view => promptEcho again == Ex.notAsking (.alreadyOpen view)) ==
                    some true &&
                  again.loop.state.prompt == typed.loop.state.prompt &&
                  again.loop.state.prompt.isSome &&
                  minibufferText again == some "say" },
        { name := "cancelling the ex line runs nothing: the prompt is closed and no command is run"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (cancelled, steps) :=
                  fedTo driver (presses "C-e e" ++ [.commit "say hello there"] ++ presses "C-e n")
                promptEcho cancelled == "" && closed cancelled &&
                  steps.all (·.all (·.answered.isEmpty)) &&
                  !(echoesSince driver cancelled).contains (greeted hello) },
        { name :=
            "the ex name e with a path: once the load is finished the view the line was asked from shows a buffer with the file's text, holding the file's path; before that it shows the scratch buffer"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let path := inFiles "note.txt"
                let (asked, _) := fedTo driver (exLine s!"e {path}")
                let (opened, _) := asked.finish 1
                (showing asked).map (·.id) == some ⟨0⟩ && asked.pending.size == 1 && closed asked &&
                  (showing opened).bind (·.text) == some FileCases.noteText &&
                  (heldFile opened).map (·.path) == some path &&
                  closed opened },
        { name :=
            "the ex name e with no argument runs files-api's edit command with no path: on files-api's fake, which asks for no path, the echo area says the fake's no-path text, and no load is started"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let (asking, _) := fedTo driver (exLine "e")
                echoOf asking == some Opener.noPath && asking.pending.isEmpty },
        { name :=
            "the ex name w after an edit starts a save, which is in flight until its job is finished: the file then holds the buffer's text, the buffer is not modified, and the echo area says the file was written"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let text := "x" ++ FileCases.noteText
                let (saving, _) := fedTo opened ([.commit "x"] ++ exLine "w")
                let (saved, _) := saving.finish 2
                (heldFile saving).bind (·.saving) != none && saving.pending.size == 1 &&
                  (showing saving).map (·.buffer.isModified) == some true &&
                  (showing saved).bind (·.text) == some text &&
                  bytesOf saved path == some (FileModel.encode text) &&
                  (showing saved).map (·.buffer.isModified) == some false &&
                  echoOf saved == some s!"wrote {path}" },
        { name :=
            "the ex name w with an argument says it takes none, by the ex line's message, and starts no save: the file is as it was and the buffer is still modified"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let (refused, _) := fedTo opened ([.commit "x"] ++ exLine "w other.txt")
                promptEcho refused == Ex.noArgument "w" && refused.pending.isEmpty &&
                  (heldFile refused).bind (·.saving) == none &&
                  bytesOf refused path == some FileCases.noteBytes &&
                  statusOf refused == some (namedModified "note.txt") },
        { name :=
            "the ex name w in the scratch buffer says the buffer has no file, by files-api's fake's save command's message, and starts nothing"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let (refused, _) := fedTo driver (exLine "w")
                promptEcho refused == s!"{Opener.saveName}: scratch has no file" &&
                  refused.pending.isEmpty &&
                  closed refused },
        { name :=
            "the ex name q in an editor with nothing modified stops the driver; and so does q after text was typed in the scratch buffer alone, which holds no file"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let (fresh, _) := fedTo driver (exLine "q")
                let (typed, _) := fedTo driver ([.commit "typed"] ++ exLine "q")
                !driver.stopped && fresh.stopped && typed.stopped &&
                  driverText typed == some "typed" },
        { name :=
            "the ex name q while a file's buffer is modified says the quit command's refusal, with the buffer's name, and the editor goes on: the driver has not stopped and the next key's command runs"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let (refused, _) := fedTo opened ([.commit "x"] ++ exLine "q")
                let (after, _) := fedTo refused (presses "C-e o")
                promptEcho refused == Ex.notQuitting (.unsaved "note.txt") && !refused.stopped &&
                  !refused.loop.state.quitting &&
                  closed refused &&
                  promptEcho after == "other" },
        { name :=
            "criterion 1 on the models: w and then q with the save not yet finished does not stop the driver until the save is finished, and then the file holds the buffer's text"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let text := "x" ++ FileCases.noteText
                let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "w" ++ exLine "q")
                let (left, _) := asked.finish 2
                asked.pending.size == 1 && !asked.stopped && asked.loop.state.quitting &&
                  promptEcho asked == "" &&
                  left.stopped &&
                  bytesOf left path == some (FileModel.encode text) &&
                  (showing left).map (·.buffer.isModified) == some false },
        { name := "the ex name q with an argument says it takes none and does not stop the driver"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let (refused, _) := fedTo driver (exLine "q now")
                promptEcho refused == Ex.noArgument "q" && !refused.stopped &&
                  !refused.loop.state.quitting },
        { name :=
            "criterion 2 on the models: the ex name wq on a modified buffer of a file starts the save and asks to quit: the driver has not stopped while the save is not finished, and once it is finished the file holds the buffer's text and the driver has stopped"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let text := "x" ++ FileCases.noteText
                let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "wq")
                let (left, _) := asked.finish 2
                asked.pending.size == 1 && (heldFile asked).bind (·.saving) != none &&
                  !asked.stopped &&
                  asked.loop.state.quitting &&
                  left.stopped &&
                  bytesOf left path == some (FileModel.encode text) &&
                  (showing left).map (·.buffer.isModified) == some false },
        { name :=
            "the ex name wq on a buffer of a file that is not modified saves it all the same and stops the driver once the save is finished, with the file's bytes as they were"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let (asked, _) := fedTo opened (exLine "wq")
                let (left, _) := asked.finish 2
                asked.pending.size == 1 && !asked.stopped && left.stopped &&
                  bytesOf left path == some FileCases.noteBytes &&
                  stampOf left path != stampOf opened path },
        { name :=
            "the ex name w and then wq with the save not yet finished: the save command starts no second save, the quit is asked and waits for the one save, and the driver stops once it is finished, with the buffer's text in the file"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let text := "x" ++ FileCases.noteText
                let (asked, _) := fedTo opened ([.commit "x"] ++ exLine "w" ++ exLine "wq")
                let (left, _) := asked.finish 2
                asked.pending.size == 1 && !asked.stopped && asked.loop.state.quitting &&
                  left.stopped &&
                  bytesOf left path == some (FileModel.encode text) &&
                  (showing left).map (·.buffer.isModified) == some false },
        { name :=
            "the ex name w, an edit, and then wq with the save not yet finished: no second save is started and the quit is refused with the buffer's name, by the quit command's message, which is what the echo area says; the driver does not stop when the save is finished, the file holds the text from before the edit, and the buffer is still modified"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let (asked, _) :=
                  fedTo opened ([.commit "x"] ++ exLine "w" ++ [.commit "y"] ++ exLine "wq")
                let (saved, _) := asked.finish 2
                asked.pending.size == 1 && !asked.stopped && !asked.loop.state.quitting &&
                  promptEcho asked == Ex.notQuitting (.unsaved "note.txt") &&
                  !saved.stopped &&
                  !saved.loop.state.quitting &&
                  bytesOf saved path == some (FileModel.encode ("x" ++ FileCases.noteText)) &&
                  (showing saved).map (·.buffer.isModified) == some true },
        { name :=
            "the ex name wq in the scratch buffer says the buffer has no file, by files-api's fake's save command's message, starts nothing and does not ask to quit"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let (refused, _) := fedTo driver ([.commit "typed"] ++ exLine "wq")
                promptEcho refused == s!"{Opener.saveName}: scratch has no file" &&
                  refused.pending.isEmpty &&
                  !refused.stopped &&
                  !refused.loop.state.quitting },
        { name :=
            "the ex name wq with no files implementation says so under save-and-quit's name, starts nothing and does not ask to quit"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let bare := { opened with keys := withoutExtension FilesApi.Files opened.keys }
                let (refused, _) := fedTo bare ([.commit "x"] ++ exLine "wq")
                promptEcho refused == FilesApi.noImplementation Ex.saveQuitName &&
                  refused.pending.isEmpty &&
                  !refused.stopped &&
                  !refused.loop.state.quitting },
        { name :=
            "the ex name wq with the file changed behind the editor: the save is refused, the echo area says so by the save command's message, the quit is withdrawn and the driver has not stopped; a later q is refused, the buffer being still modified"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let changed := rewritten opened path JobContract.otherFile
                let (asked, _) := fedTo changed ([.commit "x"] ++ exLine "wq")
                let (refused, _) := asked.finish 2
                let (later, _) := fedTo refused (exLine "q")
                asked.loop.state.quitting && !refused.stopped && !refused.loop.state.quitting &&
                  echoOf refused == some (Opener.notSaved path (.changed (stampOf changed path))) &&
                  bytesOf refused path == some JobContract.otherFile &&
                  promptEcho later == Ex.notQuitting (.unsaved "note.txt") &&
                  !later.stopped },
        { name :=
            "the ex name wq on a buffer that is not modified, with the file changed behind the editor: the save is refused, the echo area says so by the save command's message, the quit is withdrawn and the driver has not stopped; and so with w and then q in place of wq"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "note.txt"
                let changed := rewritten opened path JobContract.otherFile
                [exLine "wq", exLine "w" ++ exLine "q"].all fun lines =>
                  let (asked, _) := fedTo changed lines
                  let (refused, _) := asked.finish 2
                  asked.loop.state.quitting && !asked.stopped &&
                    (showing asked).map (·.buffer.isModified) == some false &&
                    !refused.stopped &&
                    !refused.loop.state.quitting &&
                    echoOf refused ==
                      some (Opener.notSaved path (.changed (stampOf changed path))) &&
                    bytesOf refused path == some JobContract.otherFile },
        { name :=
            "the ex name wq while another file's buffer has unsaved changes starts this buffer's save and is refused the quit, with the other buffer's name: the file is written and the driver has not stopped"
          run :=
            pure <|
              match exNoteOpen with
              | none => false
              | some opened =>
                let path := inFiles "crlf.txt"
                let (second, _) := fedTo opened ([.commit "x"] ++ exLine s!"e {path}")
                let (second, _) := second.finish 2
                let (asked, _) := fedTo second ([.commit "y"] ++ exLine "wq")
                let (saved, _) := asked.finish 3
                (showing second).map (·.buffer.name) == some "crlf.txt" &&
                  promptEcho asked == Ex.notQuitting (.unsaved "note.txt") &&
                  asked.pending.size == 1 &&
                  !asked.loop.state.quitting &&
                  !saved.stopped &&
                  (bytesOf saved path).map (·.size) == some (mostlyCrlf.size + 1) &&
                  echoOf saved == some s!"wrote {path}" &&
                  bytesOf saved (inFiles "note.txt") == some FileCases.noteBytes },
        { name :=
            "the ex name reload asks for the config to be reloaded: the driver counts one reload, and two once the line is typed twice; with an argument it says it takes none and asks for none"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let (once, _) := fedTo driver (exLine "reload")
                let (twice, _) := fedTo once (exLine "reload")
                let (refused, _) := fedTo driver (exLine "reload now")
                driver.reloads == 0 && once.reloads == 1 && twice.reloads == 2 && closed twice &&
                  !twice.stopped &&
                  promptEcho once == "" &&
                  promptEcho refused == Ex.noArgument "reload" &&
                  refused.reloads == 0 },
        { name :=
            "the ex prompt offers the `:!` lines of its view's buffer's scope first, in the history's order, newest first, before the ex names that are bound: with two lines in the unscoped history the prompt's first candidates are those two, and the bound names follow; with no history it offers the names alone"
          run :=
            let seeding : Package :=
              { name := "seeding"
                setup :=
                  commandWith "seed-history" fun _ =>
                    Workspace.setUnscoped Shell.historyStore #["!make", "!echo hi"] }
            let bindings := exTestBindings.push { name := "seed", command := "seed-history" }
            pure <|
              match exDriver bindings #[seeding] with
              | none => false
              | some driver =>
                let names := bindings.map (·.name)
                let texts (driver : TestDriver) : Option (Array String) :=
                  (candidatesOf (fedTo driver (presses "C-e e")).1).map (·.all.map (·.text))
                let seeded := (fedTo driver (exLine "seed")).1
                texts driver == some names &&
                  texts seeded == some (#["!make", "!echo hi"] ++ names) },
        { name :=
            "the ex prompt's candidates are the ex names that are bound, each once, listed for the empty line when it opens; a typed letter lists the names the fuzzy model answers for it, and the scene shows them after the ex line's label"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (asking, _) := fedTo driver (presses "C-e e")
                let (typed, _) := fedTo asking (presses "s")
                let names := exTestBindings.map (·.name)
                candidatesOf asking == some (exListed "") &&
                  (candidatesOf asking).map (·.all.map (·.text)) == some names &&
                  (candidatesOf asking).map (·.listed.size) == some names.size &&
                  candidatesOf typed == some (exListed "s") &&
                  (candidatesOf typed).map (·.listed.size) == some 3 &&
                  ((pickShown typed).map fun fields => fields.map (·.text)) ==
                    some (#[Ex.label] ++ (exListed "s").listed.map (·.text)) },
        { name :=
            "in the ex prompt, text that is no name is typed, the key that moves to the next candidate and the accept key are pressed: the command the first listed name is bound to runs, as the whole name typed and accepted runs it, and not as the typed text alone does, which is no ex name"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (typed, _) := fedTo driver (presses "C-e e p l")
                let (chosen, _) := fedTo typed (presses "C-e t")
                let (ran, _) := fedTo chosen (presses "C-e y")
                let (whole, _) := fedTo driver (exLine "plain")
                let (bare, _) := fedTo typed (presses "C-e y")
                candidatesOf typed == some (exListed "pl") &&
                  (candidatesOf typed).map (·.listed.map (·.text)) == some #["plain"] &&
                  candidatesOf chosen == some (exListed "pl" (some 0)) &&
                  minibufferText chosen == some "pl" &&
                  promptEcho ran == promptEcho whole &&
                  promptEcho ran == greeted [] &&
                  closed ran &&
                  promptEcho bare == Ex.unknown "pl" },
        { name :=
            "an ex line with an argument matches no name, so the scene lists none, and the accept key runs the line as typed"
          run :=
            pure <|
              match exDriver with
              | none => false
              | some driver =>
                let (typed, _) := fedTo driver (presses "C-e e" ++ [.commit "say hello there"])
                let (moved, _) := fedTo typed (presses "C-e t")
                let (ran, _) := fedTo moved (presses "C-e y")
                candidatesOf typed == some (exListed "say hello there") &&
                  (candidatesOf typed).map (·.listed.map (·.text)) == some #[] &&
                  ((pickShown typed).map fun fields => fields.map (·.text)) == some #[Ex.label] &&
                  candidatesOf moved == candidatesOf typed &&
                  promptEcho ran == greeted hello &&
                  closed ran },
        { name :=
            "with the ex package's ex names, the letter e lists the name e first, which is the letter, and then e!, autoread, noautoread and reload, the order they are bound in, and no other; the name chosen and accepted runs, so the prompt closes"
          run :=
            pure <|
              match exDriver Ex.package.registered.ex with
              | none => false
              | some driver =>
                let (typed, _) := fedTo driver (presses "C-e e e")
                let (opening, _) := fedTo typed (presses "C-e t C-e y")
                candidatesOf typed == some (exListed "e" none Ex.package.registered.ex) &&
                  (candidatesOf typed).map (·.listed.map (·.text)) ==
                    some #["e", "e!", "autoread", "noautoread", "reload"] &&
                  opening.loop.state.prompt == none &&
                  echoOf opening == some Opener.noPath },
        { name :=
            "a bang line with no range hands shell-command, and nothing else, the command's text and then the line as typed, trimmed, both strings; on shell-api's fake, typed on the ex line, the fake says it ran that line"
          run :=
            pure <|
              match exShellLines with
              | none => false
              | some driver =>
                let (ran, answered) := exRan driver "  !make  check "
                let (typed, _) := fedTo driver (exLine "!make check")
                answered ==
                    some
                      #[{ command := ShellApi.commandName
                          arguments := [.str "make  check", .str "!make  check"] }] &&
                  promptEcho ran == ShellApiTest.ranText "!make  check" &&
                  promptEcho typed == ShellApiTest.ranText "!make check" &&
                  closed typed },
        { name :=
            "a bang line with a range hands shell-filter, and nothing else, the range's first and last line resolved against the view's buffer and cursor, then the command's text and the line as typed: on a buffer of three lines with the cursor on the first, .,$ is lines 1 to 3, . is line 1, $ is line 3, 2,3 is lines 2 to 3 and % is 1 to 3; on shell-api's fake the fake says it filters nothing"
          run :=
            pure <|
              match exShellLines with
              | none => false
              | some driver =>
                let filtered (line : String) (first last : Nat) : Bool :=
                  let (ran, answered) := exRan driver line
                  answered ==
                      some
                        #[{ command := ShellApi.filterName
                            arguments := [.nat first, .nat last, .str "sort -r", .str line] }] &&
                    promptEcho ran == "the fake shell filters nothing" &&
                    ran.pending.isEmpty
                (showing driver).map (·.buffer.name) == some "lf.txt" &&
                  filtered ".,$!sort -r" 1 3 &&
                  filtered ".!sort -r" 1 1 &&
                  filtered "$!sort -r" 3 3 &&
                  filtered "2,3!sort -r" 2 3 &&
                  filtered "%!sort -r" 1 3 },
        { name :=
            "a bang line whose range resolves to no lines says the line as typed and why, by the range's own message, in the echo area, and hands the shell nothing: past the end of the buffer, backwards, and line 0"
          run :=
            pure <|
              match exShellLines with
              | none => false
              | some driver =>
                let refused (line why : String) : Bool :=
                  let (ran, answered) := exRan driver line
                  answered == some #[] && promptEcho ran == s!"{line}: {why}" && ran.pending.isEmpty
                refused "2,5!sort" (Ex.pastEnd 5 3) && refused "4!sort" (Ex.pastEnd 4 3) &&
                  refused "3,2!sort" (Ex.backwards 3 2) &&
                  refused "0,2!sort" Ex.lineZero },
        { name :=
            "a bang line with nothing after the bang, with a range or none, says there is no command, by shell-api's message, and hands the shell nothing; and so with no shell registered, where it is ex that says it"
          run :=
            pure <|
              match exShellLines, exDriver Ex.package.registered.ex with
              | some shell, some bare =>
                let refused (driver : TestDriver) (line : String) : Bool :=
                  let (ran, answered) := exRan driver line
                  answered == some #[] && promptEcho ran == ShellApi.noCommand
                ["!", "!   ", "%!", ".,$! "].all fun line => refused shell line && refused bare line
              | _, _ => false },
        { name :=
            "the ex package binds none of Vim's ex names for marks: marks, delmarks, mark, k, lockmarks and keepmarks are not ex names, as evil's recorded departures say of the ex line"
          run :=
            let names := exNamesOf Ex.package.registered.ex
            pure
              (!names.isEmpty &&
                ["marks", "delmarks", "mark", "k", "lockmarks", "keepmarks"].all
                  (!names.contains ·)) }] ++
      ((sourceContract Ex.historySource ++ sourceContract Ex.namesSource).map fun (name, held) =>
        { name, run := pure held }) ++
    [{  name := "the ex names' source answers something on the contract's fixture"
        run := pure (answersSomething Ex.namesSource) }]

end ExTest
