import ConfigTest.Check
import ConfigTest.Support.Hosts
import ConfigTest.Support.Lines
import Editor.Completion
import Editor.Config.Packages
import Editor.Config.Registry
import Editor.Event
import Editor.Event.Queue
import Editor.Evil.Compiled
import Editor.Ex.Line
import Editor.Face
import Editor.Fuzzy.Real
import Editor.Headless
import Editor.Language
import Editor.Loop
import Editor.Mode

/-!
# Config tests: `Editor/Evil.lean`

The tests of `Editor/Evil.lean`: `evilChecks`, through the headless host. The
root module `ConfigTest` runs them; its module doc says what each shows.
-/

namespace ConfigTest

open Editor

/-- A config with a motion of its own, `to-second`, which answers the offset
1 from anywhere, and a `setup` that registers two commands that are given
their call. Each runs evil's move command (`Evil.move`) over a vocabulary
the config names: `own` over the one the editor ships (`Evil.motions`) with
`to-second` added, by `to-second`'s name, and `first-shipped` over the one
the editor ships as it is, by the name its first entry has. So the config
names no motion of the editor's, and says nothing of where one leads. -/
def vocabularyText : String :=
  "def toSecond : Vocabulary.Motion :=
  { name := \"to-second\", target := fun _ _ => pure { head := 1 } }

def setup : SetupM Unit := do
  commandWith \"own\" fun call =>
    Evil.move (Evil.motions.push toSecond) { call with arguments := [.str \"to-second\"] }
  commandWith \"first-shipped\" fun call =>
    Evil.move Evil.motions
      { call with arguments := [.str ((Evil.motions[0]?.map (·.name)).getD \"\")] }
"

/-- A config whose `setup` registers three commands that are given their
call, over the tables the editor ships, each named by the config and none
restated: `delete-word` moves to the line's start (`Evil.move`) and runs
evil's operate command (`Evil.operate Evil.operators Evil.motions Evil.objects`) with
the arguments the Vim scheme compiles `d w` to; `again` hands evil's repeat
command (`Evil.repeat`) that same change, as the scheme's repeat key would,
which the repeat command has the registry's operate command run; and `back`
is evil's undo (`Evil.undo`). The names of the operator, the motions and
the command are read off the editor's own entries. -/
def operatorsText : String :=
  "def deleteWord : List Argument :=
  [.str Evil.delete.name, .str \"motion\", .str Evil.wordForward.name, .nat 0, .str \"\"]

def setup : SetupM Unit := do
  commandWith \"delete-word\" fun call => do
    Evil.move Evil.motions { call with arguments := [.str Evil.lineStart.name] }
    Evil.operate Evil.operators Evil.motions Evil.objects { call with arguments := deleteWord }
  commandWith \"again\" fun call =>
    Evil.repeat
      { call with
        arguments := [.bool false, .str \"\", .str Vim.operateCommand] ++ deleteWord }
  commandWith \"back\" Evil.undo
"

/-- A config with an operator of its own, `erase`, which is the editor's
`delete` under another name, and a `setup` that registers evil's operate
command again, under the name the editor registers it (`Vim.operateCommand`),
over the operators the editor ships and `erase`. `erase-word` runs the
operate command over those tables, from the line's start, with the
arguments the Vim scheme compiles `erase` over `w` to, and `again` hands
evil's repeat command that same change, as the scheme's repeat key would. -/
def ownOperatorText : String :=
  "def erase : Vocabulary.Operator :=
  { Evil.delete with name := \"erase\" }

def eraseWord : List Argument :=
  [.str erase.name, .str \"motion\", .str Evil.wordForward.name, .nat 0, .str \"\"]

def setup : SetupM Unit := do
  commandWith Vim.operateCommand
    (Evil.operate (Evil.operators.push erase) Evil.motions Evil.objects)
  commandWith \"erase-word\" fun call => do
    Evil.move Evil.motions { call with arguments := [.str Evil.lineStart.name] }
    Evil.operate (Evil.operators.push erase) Evil.motions Evil.objects
      { call with arguments := eraseWord }
  commandWith \"again\" fun call =>
    Evil.repeat
      { call with
        arguments := [.bool false, .str \"\", .str Vim.operateCommand] ++ eraseWord }
"

/-- The checks of evil from config through the headless host
(`Editor/Headless.lean`), on the real queue, the real text binding and the
real elaborator, with the test scheme: what `Editor.lean` lets config name
of evil (`Editor/Evil.lean`, `Editor/Evil/Motions.lean`,
`Editor/Evil/Operators.lean`, `Editor/Evil/Repeat.lean`,
`Editor/Evil/Undo.lean`). Where a motion leads and what an operator takes
are evil's, pinned by `ModelTest.evilMotionChecks` and
`ModelTest.evilOperatorChecks`, and are not said here. -/
def evilChecks (context : Context) : List Check :=
  [{  name :=
        "config names the vocabulary the editor ships and hands it to evil's move command: a command of config's that moves by a motion of config's own, added to that vocabulary, puts the cursor where that motion says, and one that moves by the name of the vocabulary's first entry runs to its end and says nothing in the echo area, so the entry was found"
      run :=
        withHost context [("init.lean", vocabularyText)] fun session => do
          session.ask [.reload]
          unless ← Event.post (.commit "hello") do
            return false
          let committed ← session.scene
          session.ask [.run "own"]
          let own ← session.scene
          session.ask [.run "first-shipped"]
          let (echo, _) ← session.scene
          let lines ← session.lines
          return committed == ("".quote, #[viewLine "hello" 5]) &&
              own == ("".quote, #[viewLine "hello" 1]) &&
              echo == "".quote &&
              lines.contains "reload 1: installed, 1 files, 2 commands" &&
              lines.contains "run own: ok" &&
              lines.contains "run first-shipped: ok" },
    { name :=
        "config names the operators the editor ships and hands them, with the motions, to evil's operate command: a command of config's that runs it with the arguments of d w from the line's start deletes a word; one that hands the repeat command the same change deletes the next, with the operate command the host was handed as compiled code; and one that runs evil's undo gives that word back"
      run :=
        withHost context [("init.lean", operatorsText)]
          (fun session => do
            session.ask [.reload]
            unless ← Event.post (.commit "one two three") do
              return false
            session.ask [.run "delete-word"]
            let deleted ← session.scene
            session.ask [.run "again"]
            let again ← session.scene
            session.ask [.run "back"]
            let back ← session.scene
            let lines ← session.lines
            return deleted == ("".quote, #[viewLine "two three" 0]) &&
                again == ("".quote, #[viewLine "three" 0]) &&
                back == ("".quote, #[viewLine "two three" 0]) &&
                lines.contains "run delete-word: ok" &&
                lines.contains "run again: ok" &&
                lines.contains "run back: ok")
          { commands := Evil.package.registered.commands } },
    { name :=
        "the repeat command replays a change with the command the registry holds for its name: with config's operate command registered over the operators that ship and one of config's own, in place of the compiled one, a change made with config's operator is replayed with it, and deletes the next word"
      run :=
        withHost context [("init.lean", ownOperatorText)]
          (fun session => do
            session.ask [.reload]
            unless ← Event.post (.commit "one two three") do
              return false
            session.ask [.run "erase-word"]
            let erased ← session.scene
            session.ask [.run "again"]
            let again ← session.scene
            let lines ← session.lines
            return erased == ("".quote, #[viewLine "two three" 0]) &&
                again == ("".quote, #[viewLine "three" 0]) &&
                lines.contains "run erase-word: ok" &&
                lines.contains "run again: ok")
          { commands := Evil.package.registered.commands } }]

end ConfigTest
