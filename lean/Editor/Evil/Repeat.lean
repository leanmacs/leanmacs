import Editor.Evil.Registers
import Editor.InputScheme.Vim

/-!
# Evil's dot repeat

`.` replays the last change (`docs/design/keymaps-and-modes.md`, "The last
change"). The last change is the Vim scheme's, which keeps it with the text
typed in the insert session it began (`Editor/InputScheme/Vim.lean`, "The
last change"). A command cannot read the scheme, so the scheme hands the
change to the command in the invocation its repeat key yields: whether the
change began an insert session, the text typed in it, the name of the
command the change compiles to, and then that command's own arguments.

## The repeat command

`Evil.repeat` is the command. It names no command it replays and holds no
table of them.

- **The change's command is the one the registry holds for its name**,
  which is the one the change's own keys ran: the repeat command has the
  loop run it inside itself (`runCommand`, `Editor/Api.lean`), and the
  loop looks the name up as it looks up a key's invocation
  (`Editor/Loop.lean`, "A command run inside another"). So config's
  command of a name evil registers, such as `operate` registered again
  over a vocabulary with operators of config's own, is what `.` replays,
  and so is a command of config's that a scheme's table binds as changing
  text. A command cannot hold the registry and no reply of the loop's can
  hold a command, which is why the loop runs it.
- **Which commands are changes is the scheme's to say**
  (`Vim.Command.changes`, `Vim.Operator.changes`): a change is whatever
  edit the scheme kept as the last change.
- **A change with no insert session** is run with the repeat's call, with
  the change's arguments in place of the call's.
- **A change with an insert session** is three things in one command: the
  change, told of an exclusive selection that no motion extends, so it
  leaves its bar; the typed text, inserted at the bar
  (`Target.insertAtSelections`) when it is not empty; and `Evil.enter` with
  the call's own report, which is normal state's and steps the head back as
  `<Escape>` does.
- **It is one command in normal state**, so it is one step of the history
  and is rolled back whole when any part of it gives up or is refused.
- **The clipboard is written last** (`Editor/Evil/Registers.lean`, "The
  clipboard is written last"). A change with no insert session is the
  replay's last request, and its own store writes the clipboard. A change
  with an insert session is not: the typed text and the leaving of the
  insert come after it, and an interrupt or a refusal there rolls the
  text back, which a write of the clipboard would survive. So where the
  change names the clipboard register, which is the last of its
  arguments in both layouts the scheme compiles a change to
  (`Editor/InputScheme/Vim.lean`, "Edits"), the replay runs it with the
  name `clipboardLater` in that place, under which a store keeps what it
  would write, and writes what was kept once the insert is left
  (`writeKept`), as its last request. A change's command that does not
  know that name gives the replay up, by its own rule for a register it
  has none of.
- **A change that breaks off breaks the replay off**: an operator whose
  motion failed after it moved leaves the cursor where the motion got to
  (`Editor/Evil/Operators.lean`, "What an operator takes") and ends the
  command there, so no typed text is inserted, as Vim's `.` does.
- **A count typed before `.`** has already replaced the change's count in
  the arguments (the scheme's rule). For a change that begins an insert
  with a key (`i a I A o O`) it replaces a count those commands ignore.
- **What is not replayed gives the command up**, with nothing changed: no
  change, which is the command run by its name (`nothingToRepeat`); a
  name no command is registered under (`notRepeated`); the repeat
  command's own name, since a replay is no change and would run for ever;
  and a change over a visual selection, which Vim repeats over the same
  amount of text from the cursor (`notRepeated overSelection`). A change
  whose command asks for a store to be written gives it up too, by the
  loop's rule for a command run inside another.
- **A yank is not repeated**: its operator changes no text, so it never is
  the last change.

Pinned by `ModelTest.evilRepeatChecks`, by key.
-/

namespace Editor.Evil

/-- What the repeat command gives up with when it is handed no change:
when it is run by its name, which hands a command no argument. -/
def nothingToRepeat : String :=
  "nothing to repeat"

/-- What the repeat command gives up with for a change it does not replay,
`what` naming it. -/
def notRepeated (what : String) : String :=
  s!"{what} is not repeated"

/-- How the repeat command names a change over a visual selection, which it
does not replay. -/
def overSelection : String :=
  "a change over a selection"

/-- The repeat command, as it is called ("The repeat command", in the
module docs): its arguments are whether the change began an insert session,
the text typed in it, the name of the command the change compiles to, and
then that command's own arguments. The change is run again from where the
cursor is, by the command the registry holds for that name, with the text
typed after it, as one command. A call that hands it no change, a name no
command is registered under, its own name and a change over a selection
each give it up.

Its name is written `«repeat»` because `repeat` is a keyword of Lean's: it
is `Evil.repeat` to whoever calls it. -/
def «repeat» (call : Call) : EditorM Unit := do
  let .bool session :: .str text :: .str command :: arguments :=
    call.arguments | giveUp nothingToRepeat
  if command == Vim.repeatCommand then
    giveUp (notRepeated command)
  if command == Vim.operateCommand then
    if let _ :: .str "selection" :: _ := arguments then
      giveUp (notRepeated overSelection)
  -- The change's command, as the registry has it: the one its keys ran.
  let change (call : Call) : EditorM Unit := do
    unless ← runCommand command call do
      giveUp (notRepeated command)
  if session then
    -- A change that names the clipboard is not this command's last request:
    -- it is told to keep what it would write, which is written below.
    let later := arguments.getLast? == some (.str clipboard)
    let arguments := if later then arguments.dropLast ++ [.str clipboardLater] else arguments
    if later then
      keepClipboard
    -- The change, as a key that enters insert state runs it: told of an
    -- exclusive selection that no motion extends, which is all a command
    -- that begins an insert reads of insert state's report.
    change
        { call with
          arguments,
          report :=
            { call.report with
              shape := .exclusive, selecting := false } }
    unless text.isEmpty do
      call.target.insertAtSelections text
    -- The session ends as `<Escape>` ends one, for the state the view is in.
    enter call
    if later then
      writeKept
  else
    change { call with arguments }

end Editor.Evil
