import Editor.Evil.Operators
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

`Evil.repeat changes` is the command, a function of the table it looks the
change's command up in (`Evil.changes`, the compiled table: `operate`, `x`,
the two puts, the two commands that open a line, and the four that begin an
insert).

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
- **A count typed before `.`** has already replaced the change's count in
  the arguments (the scheme's rule). For a change that begins an insert
  with a key (`i a I A o O`) it replaces a count those commands ignore.
- **What is not replayed gives the command up**, with nothing changed: no
  change, which is the command run by its name (`nothingToRepeat`); a
  command the table does not have, which is a command of config's bound as
  changing text (`notRepeated`); and a change over a visual selection,
  which Vim repeats over the same amount of text from the cursor
  (`notRepeated overSelection`).
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

/-- The changes the repeat command replays: the name a change compiles to,
with the command evil registers under that name
(`Editor/Evil/Compiled.lean`). -/
def changes : Array (String × (Call → EditorM Unit)) :=
  #[(Vim.operateCommand, operate operators motions), ("delete-char", deleteChar),
    ("put-after", putAfter), ("put-before", putBefore), ("open-below", openBelow),
    ("open-above", openAbove), ("insert", insert), ("append", append),
    ("insert-line-start", insertLineStart), ("append-line-end", appendLineEnd)]

/-- The repeat command over the table `changes`, as it is called ("The
repeat command", in the module docs): its arguments are whether the change
began an insert session, the text typed in it, the name of the command the
change compiles to, and then that command's own arguments. The change is
run again from where the cursor is, with the text typed after it, as one
command. A call that hands it no change, a command the table does not
have, and a change over a selection each give it up.

Its name is written `«repeat»` because `repeat` is a keyword of Lean's: it
is `Evil.repeat` to whoever calls it. -/
def «repeat» (changes : Array (String × (Call → EditorM Unit))) (call : Call) : EditorM Unit := do
  let .bool session :: .str text :: .str command :: arguments :=
    call.arguments | giveUp nothingToRepeat
  let some (_, change) := changes.find? (·.1 == command) | giveUp (notRepeated command)
  if command == Vim.operateCommand then
    if let _ :: .str "selection" :: _ := arguments then
      giveUp (notRepeated overSelection)
  if session then
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
  else
    change { call with arguments }

end Editor.Evil
