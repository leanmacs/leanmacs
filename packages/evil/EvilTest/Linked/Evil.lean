import Editor.Completion
import Editor.Config.Packages
import Editor.Event
import Editor.Ex.Line
import Editor.Face
import Editor.Language
import Editor.Mode
import Editor.Test.Linked.Host
import Editor.Test.Linked.Keys
import Editor.Test.Linked.Lines
import Evil.Compiled
import EvilTest.Check
import EvilTest.Linked.Support.Vim

/-!
# Linked tests: `Evil.lean`

The tests of `Evil.lean`: `evilChecks`, through the headless host, and
`evilLeaderChecks`, the Vim scheme's leader through a host of the Vim scheme
that ships. The root module `EvilTest.Linked` runs them; its module doc says what
each shows.
-/

namespace EvilTest.Linked

open Editor
open Editor.Test.Linked

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
real elaborator, with the test scheme: what the set's base, `Editor` and
this package's entry module (`Evil/EditorPackage.lean`), lets config name
of evil (`Evil.lean`, `Evil/Motions.lean`,
`Evil/Operators.lean`, `Evil/Repeat.lean`,
`Evil/Undo.lean`). Where a motion leads and what an operator takes
are evil's, pinned by `EvilTest.evilMotionChecks` and
`EvilTest.evilOperatorChecks`, and are not said here. -/
def evilChecks (context : HostContext) : List Check :=
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

/-- A config whose `setup` registers `leader-find`, which says `leader find`
in the echo area, and `other`, which says `other`, binds `<leader> f f` to
`leader-find`, described as `Find file`, names the prefix `<leader> f`
`file` when `named`, sets the key hint delay to 0 when `hinted`, so the
hints are in the scene after the prefix with no move of the clock, and,
given `leader`, sets the leader to the key string `leader`. -/
def vimLeaderText (leader : Option String := none) (hinted : Bool := false) (named : Bool := true) :
    String :=
  "def setup : SetupM Unit := do
  command \"leader-find\" (message \"leader find\")
  command \"other\" (message \"other\")
  bindKey \"<leader> f f\" \"leader-find\" (desc := \"Find file\")
" ++
    (if hinted then "  keyHintDelay 0\n" else "") ++
    (if hinted && named then "  prefixName \"<leader> f\" \"file\"\n" else "") ++
    (leader.map fun keys => s!"  leaderKey {keys.quote}\n").getD ""

/-- The checks of the Vim scheme's leader through a host of the Vim scheme
that ships (`withVimHost`), with the real elaborator and the recorder: a
config's binding written with `<leader>` is reached under the scheme's
leader, `SPC`, in normal state, under the leader config sets once it is
reloaded, and is kept out of insert state, where `SPC` types a space; and
the key hints after `SPC` list what config described and named
(`Evil/Vim/Default.lean`, the leader;
`docs/design/keymaps-and-modes.md`, "Extending from config"). What a
scheme's leader reaches and what the hints list under any scheme are the
core's, pinned by `ConfigTest.leaderChecks` and `ConfigTest.hintChecks` on
the test scheme. -/
def evilLeaderChecks (context : HostContext) : List Check :=
  [{  name :=
        "under the Vim scheme with no leader set by config, a config binding of <leader> f f runs its command on SPC f f in normal state"
      run :=
        withVimHost context [("init.lean", vimLeaderText)] fun session => do
          session.ask [.reload]
          session.typed "SPC f f"
          return (← session.echo) == "leader find".quote },
    { name :=
        "a config that sets the leader to \\ reaches its <leader> f f binding on \\ f f after a reload, and SPC f f no longer runs it"
      run :=
        withVimHost context [("init.lean", vimLeaderText)] fun session => do
          session.ask [.reload]
          session.write "init.lean" (vimLeaderText (some "\\"))
          session.ask [.reload]
          session.typed "\\ f f"
          let moved ← session.echo
          session.ask [.run "other"]
          session.typed "SPC f f"
          let spaced ← session.echo
          return moved == "leader find".quote && spaced != "leader find".quote },
    { name :=
        "SPC typed in insert state inserts a space in a config that binds keys under <leader>, and SPC f f after <Escape> still runs the binding"
      run :=
        withVimHost context [("init.lean", vimLeaderText)] fun session => do
          session.ask [.reload]
          session.typed "i a SPC b <Escape>"
          let line := lastViewLine (← session.sceneLines)
          let before ← session.echo
          session.typed "SPC f f"
          let after ← session.echo
          return (line.splitOn s!"{"a b".quote}, scroll").length == 2 &&
              before != "leader find".quote &&
              after == "leader find".quote },
    { name :=
        "criterion 4: after a reload, SPC lists f as the prefix config named, SPC f lists f as the binding config described, and SPC f f runs it and lists nothing"
      run :=
        withVimHost context [("init.lean", vimLeaderText (hinted := true))] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let afterLeader ← session.hints
          session.typed "<Escape>"
          session.typed "SPC f"
          let afterPrefix ← session.hints
          session.typed "f"
          let afterBinding ← session.hints
          return afterLeader.contains "hint f: prefix \"file\" 1" &&
              afterPrefix == #["hint f: binding \"Find file\""] &&
              afterBinding.isEmpty &&
              (← session.echo) == "leader find".quote },
    { name :=
        "criterion 5: a reload that drops a config's prefix name drops it from the hints, and the prefix is listed unnamed"
      run :=
        withVimHost context [("init.lean", vimLeaderText (hinted := true))] fun session => do
          session.ask [.reload]
          session.typed "SPC"
          let named ← session.hints
          session.typed "<Escape>"
          session.write "init.lean" (vimLeaderText (hinted := true) (named := false))
          session.ask [.reload]
          session.typed "SPC"
          let unnamed ← session.hints
          return named.contains "hint f: prefix \"file\" 1" &&
              unnamed.contains "hint f: prefix - 1" &&
              !unnamed.any (·.startsWith "hint f: prefix \"file\"") }]

end EvilTest.Linked
