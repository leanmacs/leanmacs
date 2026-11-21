import ConfigTest.Check
import ConfigTest.Support.Configs
import ConfigTest.Support.Hosts
import ConfigTest.Support.Keys
import ConfigTest.Support.Lines
import Editor.Ex
import Editor.Files
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.Text

/-!
# Config tests: `Editor/Ex.lean`

The tests of `Editor/Ex.lean`: `exChecks`, through the headless host. The root
module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- Runs `line` on the ex line: the ex command is run by its name, which
asks, `line` is committed into the minibuffer, and the accept key is
pressed. Waits until the editor thread has handled them and no reload is
running. `true`: a commit the queue refused throws. -/
def Session.exLine (session : Session) (line : String) : IO Bool := do
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
            return compiled == (Files.noFile "scratch").quote && own == "mine".quote &&
                again == (Files.noFile "scratch").quote)
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

end ConfigTest
